from __future__ import annotations

import sys
from types import ModuleType
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

fake_numpy = ModuleType("numpy")
fake_numpy.ndarray = object


def _linspace(start, stop, num, dtype=None):
    if num <= 1:
        return [int(round(start))]
    if num == 0:
        return []
    step = (stop - start) / (num - 1)
    return [int(start + step * idx) for idx in range(num)]


fake_numpy.linspace = _linspace

from stockpile.config import FrameExtractionConfig  # noqa: E402


class FakeVideoCapture:
    def __init__(self, frames: list[list[list[list[int]]]], fps: float):
        self._frames = frames
        self._fps = fps
        self._index = 0
        self._opened = True

    def isOpened(self):
        return self._opened

    def get(self, prop):
        if prop == 5:  # cv2.CAP_PROP_FPS
            return self._fps
        if prop == 7:  # cv2.CAP_PROP_FRAME_COUNT
            return len(self._frames)
        return 0

    def read(self):
        if self._index >= len(self._frames):
            return False, None
        frame = self._frames[self._index]
        self._index += 1
        return True, frame

    def release(self):
        self._opened = False


def _make_frames(count: int) -> list[list[list[list[int]]]]:
    return [[[[idx for _ in range(3)] for _ in range(2)] for _ in range(2)] for idx in range(count)]


def _install_fake_capture(monkeypatch, frames: list[list[list[list[int]]]], fps: float):
    fake_capture = FakeVideoCapture(frames, fps)

    def _factory(_video_path):
        return fake_capture

    monkeypatch.setattr("stockpile.frame_extraction.cv2.VideoCapture", _factory)
    return fake_capture


def _install_fake_imwrite(monkeypatch):
    def _imwrite(path, frame, params=None):
        Path(path).write_text(f"frame={int(frame[0][0][0])}", encoding="utf-8")
        return True

    monkeypatch.setattr("stockpile.frame_extraction.cv2.imwrite", _imwrite)


def _load_extract_frames(monkeypatch):
    fake_numpy = ModuleType("numpy")
    fake_numpy.ndarray = object
    fake_numpy.linspace = _linspace
    monkeypatch.setitem(sys.modules, "numpy", fake_numpy)

    fake_cv2 = ModuleType("cv2")
    fake_cv2.CAP_PROP_FPS = 5
    fake_cv2.CAP_PROP_FRAME_COUNT = 7
    fake_cv2.IMWRITE_JPEG_QUALITY = 1
    fake_cv2.VideoCapture = object
    fake_cv2.imwrite = lambda *args, **kwargs: True
    monkeypatch.setitem(sys.modules, "cv2", fake_cv2)

    monkeypatch.delitem(sys.modules, "stockpile.frame_extraction", raising=False)

    from stockpile.frame_extraction import extract_frames  # noqa: E402

    return extract_frames


def test_extract_frames_merges_preferred_timestamps_and_frame_indices(tmp_path, monkeypatch):
    frames = _make_frames(12)
    extract_frames = _load_extract_frames(monkeypatch)
    _install_fake_capture(monkeypatch, frames, fps=4.0)
    _install_fake_imwrite(monkeypatch)

    output_dir = tmp_path / "frames"
    saved_paths = extract_frames(
        video_path=tmp_path / "video.mp4",
        output_dir=output_dir,
        config=FrameExtractionConfig(interval_sec=1.0, max_frames=6),
        preferred_timestamps_sec=[0.49],
        preferred_frame_indices=[5, 2],
    )

    assert [path.name for path in saved_paths] == [
        "frame_00000.jpg",
        "frame_00002.jpg",
        "frame_00004.jpg",
        "frame_00005.jpg",
        "frame_00008.jpg",
    ]
    assert [path.read_text(encoding="utf-8") for path in saved_paths] == [
        "frame=0",
        "frame=2",
        "frame=4",
        "frame=5",
        "frame=8",
    ]


def test_extract_frames_preserves_regular_coverage_under_budget_pressure(tmp_path, monkeypatch):
    frames = _make_frames(20)
    extract_frames = _load_extract_frames(monkeypatch)
    _install_fake_capture(monkeypatch, frames, fps=10.0)
    _install_fake_imwrite(monkeypatch)

    output_dir = tmp_path / "frames"
    saved_paths = extract_frames(
        video_path=tmp_path / "video.mp4",
        output_dir=output_dir,
        config=FrameExtractionConfig(interval_sec=0.1, max_frames=6),
        preferred_timestamps_sec=[1.0],
        preferred_frame_indices=[2, 15],
    )

    assert [path.name for path in saved_paths] == [
        "frame_00000.jpg",
        "frame_00002.jpg",
        "frame_00009.jpg",
        "frame_00010.jpg",
        "frame_00015.jpg",
        "frame_00019.jpg",
    ]
    assert [path.read_text(encoding="utf-8") for path in saved_paths] == [
        "frame=0",
        "frame=2",
        "frame=9",
        "frame=10",
        "frame=15",
        "frame=19",
    ]
