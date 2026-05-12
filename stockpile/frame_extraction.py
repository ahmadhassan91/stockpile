"""Video → frames extraction using OpenCV."""

import logging
import math
from pathlib import Path
from collections.abc import Iterable

import cv2
import numpy as np

from .config import FrameExtractionConfig

logger = logging.getLogger(__name__)


def extract_frames(
    video_path: str | Path,
    output_dir: str | Path,
    config: FrameExtractionConfig | None = None,
    progress_callback=None,
    preferred_timestamps_sec: Iterable[float] | None = None,
    preferred_frame_indices: Iterable[int] | None = None,
) -> list[Path]:
    """Extract frames from video at regular intervals.

    Returns list of saved frame paths.
    """
    config = config or FrameExtractionConfig()
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise ValueError(f"Cannot open video: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    frame_interval = max(1, int(fps * config.interval_sec))
    duration = total_frames / fps if fps > 0 else 0
    max_frame_index = max(0, total_frames - 1)

    def _select_evenly_spaced(indices: list[int], target_count: int) -> list[int]:
        if target_count <= 0 or not indices:
            return []
        if target_count >= len(indices):
            return list(indices)
        sampled = np.linspace(0, len(indices) - 1, target_count, dtype=int)
        return [indices[i] for i in sampled]

    regular_frame_indices = list(range(0, total_frames, frame_interval))

    preferred_indices: list[int] = []
    if preferred_frame_indices is not None:
        for raw_index in preferred_frame_indices:
            index = int(raw_index)
            if 0 <= index <= max_frame_index:
                preferred_indices.append(index)
    if preferred_timestamps_sec is not None and fps > 0:
        for raw_timestamp in preferred_timestamps_sec:
            timestamp = float(raw_timestamp)
            if timestamp < 0:
                continue
            index = int(math.floor(timestamp * fps + 0.5))
            if index <= max_frame_index:
                preferred_indices.append(index)

    preferred_frame_indices_sorted = sorted(set(preferred_indices))

    if len(regular_frame_indices) > config.max_frames and config.max_frames > 0:
        regular_budget = max(1, config.max_frames // 2)
        selected_regular = _select_evenly_spaced(regular_frame_indices, regular_budget)
    else:
        selected_regular = list(regular_frame_indices)

    remaining_budget = max(0, config.max_frames - len(selected_regular))
    preferred_only = [index for index in preferred_frame_indices_sorted if index not in selected_regular]
    selected_preferred = _select_evenly_spaced(preferred_only, remaining_budget)

    selected_indices = sorted(set(selected_regular).union(selected_preferred))

    if len(selected_indices) < config.max_frames:
        remaining_regular = [index for index in regular_frame_indices if index not in selected_indices]
        top_up_budget = config.max_frames - len(selected_indices)
        selected_indices = sorted(set(selected_indices).union(_select_evenly_spaced(remaining_regular, top_up_budget)))

    logger.info(
        "Video: %.1f FPS, %d frames, %.1fs duration, extracting every %d frames "
        "(%d regular + %d preferred, final %d)",
        fps,
        total_frames,
        duration,
        frame_interval,
        len(selected_regular),
        len(selected_preferred),
        len(selected_indices),
    )

    saved_paths = []
    target_indices = set(selected_indices)
    frame_idx = 0

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        if frame_idx in target_indices and len(saved_paths) < config.max_frames:
            filename = f"frame_{frame_idx:05d}.{config.output_format}"
            out_path = output_dir / filename

            if config.output_format == "jpg":
                cv2.imwrite(str(out_path), frame, [cv2.IMWRITE_JPEG_QUALITY, config.jpeg_quality])
            else:
                cv2.imwrite(str(out_path), frame)

            saved_paths.append(out_path)

            if progress_callback and total_frames > 0:
                progress_callback(frame_idx / total_frames)

        frame_idx += 1

    cap.release()
    logger.info("Extracted %d frames to %s", len(saved_paths), output_dir)
    return saved_paths


def get_video_info(video_path: str | Path) -> dict:
    """Get basic video metadata."""
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise ValueError(f"Cannot open video: {video_path}")

    info = {
        "fps": cap.get(cv2.CAP_PROP_FPS),
        "frame_count": int(cap.get(cv2.CAP_PROP_FRAME_COUNT)),
        "width": int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
        "height": int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
    }
    info["duration"] = info["frame_count"] / info["fps"] if info["fps"] > 0 else 0
    cap.release()
    return info


def get_first_frame(video_path: str | Path) -> np.ndarray:
    """Read the first frame from a video as BGR numpy array."""
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise ValueError(f"Cannot open video: {video_path}")
    ret, frame = cap.read()
    cap.release()
    if not ret:
        raise ValueError(f"Cannot read first frame from: {video_path}")
    return frame
