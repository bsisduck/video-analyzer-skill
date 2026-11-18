"""Unit tests for scripts/vahelper.py (standard library only).

Run: python3 -m unittest discover -s tests
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))

import vahelper  # noqa: E402


def video(index, codec="h264", rate="30/1", **disposition):
    return {"index": index, "codec_type": "video", "codec_name": codec,
            "avg_frame_rate": rate, "disposition": disposition,
            "width": 1920, "height": 1080}


class ParseTimeTest(unittest.TestCase):
    def test_formats(self):
        self.assertEqual(vahelper.parse_time("90"), 90)
        self.assertEqual(vahelper.parse_time("12.5"), 12.5)
        self.assertEqual(vahelper.parse_time("1:30"), 90)
        self.assertEqual(vahelper.parse_time("01:00:05.5"), 3605.5)

    def test_rejects_garbage(self):
        for bad in ("", "abc", "1:2:3:4", "10;rm", "-5", "1e3"):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                vahelper.parse_time(bad)

    def test_format_hms(self):
        self.assertEqual(vahelper.format_hms(3605.5), "01:00:05.500")
        self.assertEqual(vahelper.format_hms(59.9996), "00:01:00.000")
        self.assertEqual(vahelper.format_hms(3599.9999), "01:00:00.000")
        self.assertEqual(vahelper.format_hms(59.9, millis=False), "00:00:59")

    def test_num_keeps_precision_on_long_videos(self):
        self.assertEqual(vahelper.num(10000.75), "10000.75")
        self.assertEqual(vahelper.num(1080000), "1080000")
        self.assertEqual(vahelper.num(4.0), "4")
        self.assertEqual(vahelper.num(0), "0")
        self.assertEqual(vahelper.format_hms(75, millis=False), "00:01:15")


class StreamSelectionTest(unittest.TestCase):
    def test_skips_attached_picture_first(self):
        streams = [video(0, codec="mjpeg", rate="0/0", attached_pic=1), video(1)]
        self.assertEqual(vahelper.pick_video_stream(streams)["index"], 1)

    def test_skips_mjpeg_without_frame_rate(self):
        streams = [video(0, codec="mjpeg", rate="0/0"), video(2)]
        self.assertEqual(vahelper.pick_video_stream(streams)["index"], 2)

    def test_skips_still_image(self):
        streams = [video(0, still_image=1), video(1)]
        self.assertEqual(vahelper.pick_video_stream(streams)["index"], 1)

    def test_keeps_real_mjpeg_video(self):
        streams = [video(0, codec="mjpeg", rate="25/1")]
        self.assertEqual(vahelper.pick_video_stream(streams)["index"], 0)

    def test_falls_back_to_only_stream(self):
        streams = [{"index": 0, "codec_type": "audio"}, video(1, attached_pic=1)]
        self.assertEqual(vahelper.pick_video_stream(streams)["index"], 1)

    def test_no_video(self):
        self.assertIsNone(vahelper.pick_video_stream([{"index": 0, "codec_type": "audio"}]))


class GeometryTest(unittest.TestCase):
    def test_rotation_swaps_display_size(self):
        stream = video(0)
        stream["side_data_list"] = [{"rotation": -90}]
        self.assertEqual(vahelper.display_size(stream), (1080, 1920))

    def test_legacy_rotate_tag(self):
        stream = video(0)
        stream["tags"] = {"rotate": "90"}
        self.assertEqual(vahelper.display_size(stream), (1080, 1920))

    def test_unrotated(self):
        self.assertEqual(vahelper.display_size(video(0)), (1920, 1080))

    def test_grid_layouts(self):
        self.assertEqual(vahelper.choose_grid(1920, 1080), (4, 4))
        self.assertEqual(vahelper.choose_grid(1080, 1920), (5, 2))
        self.assertEqual(vahelper.choose_grid(1080, 1080), (4, 3))
        self.assertEqual(vahelper.choose_grid(0, 0), (4, 4))

    def test_grids_fit_the_downscale_limit(self):
        # Montage must stay within 2000px on both edges or it is shrunk
        # before analysis and its timestamps become unreadable.
        for width, height in ((1920, 1080), (1080, 1920), (1080, 1080), (2560, 1080), (1080, 2340)):
            cols, rows = vahelper.choose_grid(width, height)
            cell_width = min(vahelper.GRID_TARGET_WIDTH // cols, width)
            cell_height = cell_width * height / width
            self.assertLessEqual(cols * cell_width, 2000, (width, height))
            self.assertLessEqual(rows * cell_height, 2000, (width, height))


class ReadPtsTest(unittest.TestCase):
    def read(self, body, *args):
        with tempfile.TemporaryDirectory() as tmp:
            raw = os.path.join(tmp, "raw.txt")
            with open(raw, "w") as handle:
                handle.write(body)
            return vahelper.read_pts(raw, *args)

    def test_exact_time_rebuilt_from_integer_pts(self):
        # ffmpeg prints only six significant digits: 10000.04s shows as 10000
        body = "frame:0    pts:128000512  pts_time:10000\nlavfi.scene_score=0.9\n"
        self.assertAlmostEqual(self.read(body, "1/12800")[0], 10000.04, places=6)

    def test_falls_back_when_time_base_is_unknown_or_disagrees(self):
        body = "frame:0    pts:24  pts_time:12.5\n"
        self.assertEqual(self.read(body), [12.5])
        self.assertEqual(self.read(body, "1/90000"), [12.5])

    def test_container_start_offset_is_removed(self):
        body = "frame:0    pts:131130  pts_time:1.457\nframe:1    pts:491130  pts_time:5.457\n"
        values = self.read(body, "1/90000", 1.457)
        self.assertAlmostEqual(values[0], 0.0, places=6)
        self.assertAlmostEqual(values[1], 4.0, places=6)


class ScenePickTest(unittest.TestCase):
    def run_scenes(self, times, max_picks):
        with tempfile.TemporaryDirectory() as tmp:
            raw, out = os.path.join(tmp, "raw.txt"), os.path.join(tmp, "out.txt")
            with open(raw, "w") as handle:
                for index, value in enumerate(times):
                    handle.write(f"frame:{index}    pts:{index}  pts_time:{value}\n")
                    handle.write("lavfi.scene_score=0.5\n")
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                vahelper.cmd_scenes(types.SimpleNamespace(
                    raw=raw, out=out, max_picks=max_picks, time_base="0/1", offset="0"))
            with open(out) as handle:
                written = [float(line) for line in handle if line.strip()]
            picks = [float(line.split("\t")[0]) for line in buffer.getvalue().splitlines()]
            return written, picks

    def test_few_scenes_all_picked(self):
        written, picks = self.run_scenes([1.5, 3, 4.25], 20)
        self.assertEqual(written, [1.5, 3, 4.25])
        self.assertEqual(picks, written)

    def test_many_scenes_spread_over_whole_video(self):
        times = [float(i) for i in range(1, 101)]
        written, picks = self.run_scenes(times, 20)
        self.assertEqual(len(written), 100)
        self.assertEqual(len(picks), 20)
        self.assertEqual(picks[0], 1.0)
        self.assertEqual(picks[-1], 100.0)
        self.assertEqual(picks, sorted(set(picks)))

    def test_missing_raw_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out.txt")
            with contextlib.redirect_stdout(io.StringIO()):
                vahelper.cmd_scenes(types.SimpleNamespace(
                    raw=os.path.join(tmp, "absent.txt"), out=out, max_picks=20,
                    time_base="0/1", offset="0"))
            self.assertEqual(os.path.getsize(out), 0)


class TranscriptTest(unittest.TestCase):
    def test_offset_makes_times_absolute(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, out = os.path.join(tmp, "audio.json"), os.path.join(tmp, "transcript.txt")
            with open(source, "w") as handle:
                json.dump({"language": "en", "segments": [
                    {"start": 0.0, "end": 2.5, "text": " Hello there."},
                    {"start": 2.5, "end": 4.0, "text": "   "},
                    {"start": 4.0, "end": 6.0, "text": "Second line."},
                ]}, handle)
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                vahelper.cmd_transcript(types.SimpleNamespace(source=source, offset="600", out=out))
            with open(out) as handle:
                lines = handle.read().splitlines()
            self.assertEqual(lines, [
                "[00:10:00.000 - 00:10:02.500] Hello there.",
                "[00:10:04.000 - 00:10:06.000] Second line.",
            ])
            self.assertEqual(buffer.getvalue().strip(), "2\ten")


    def test_srt_and_vtt_cues(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "transcript.txt")
            srt = os.path.join(tmp, "audio.srt")
            with open(srt, "w") as handle:
                handle.write("1\n00:00:00,500 --> 00:00:02,000\nFirst <i>line</i>\nwraps here\n\n"
                             "2\n00:01:00,000 --> 00:01:01,250\nSecond\n")
            with contextlib.redirect_stdout(io.StringIO()):
                vahelper.cmd_transcript(types.SimpleNamespace(source=srt, offset="10", out=out))
            with open(out) as handle:
                self.assertEqual(handle.read().splitlines(), [
                    "[00:00:10.500 - 00:00:12.000] First line wraps here",
                    "[00:01:10.000 - 00:01:11.250] Second",
                ])
            vtt = os.path.join(tmp, "audio.vtt")
            with open(vtt, "w") as handle:
                handle.write("WEBVTT\n\n00:01.000 --> 00:02.500\nShort form\n")
            with contextlib.redirect_stdout(io.StringIO()):
                vahelper.cmd_transcript(types.SimpleNamespace(source=vtt, offset="0", out=out))
            with open(out) as handle:
                self.assertEqual(handle.read().splitlines(), ["[00:00:01.000 - 00:00:02.500] Short form"])


class JsonWriterTest(unittest.TestCase):
    def test_types_and_awkward_strings(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "meta.json")
            vahelper.cmd_json(types.SimpleNamespace(out=out, items=[
                's:source=a "quoted" = name.mp4', "b:has_audio=true", "n:segments=3",
                "n:offset=1.5", "s:number_like=123",
            ]))
            with open(out) as handle:
                data = json.load(handle)
            self.assertEqual(data, {"source": 'a "quoted" = name.mp4', "has_audio": True,
                                    "segments": 3, "offset": 1.5, "number_like": "123"})


if __name__ == "__main__":
    unittest.main()
