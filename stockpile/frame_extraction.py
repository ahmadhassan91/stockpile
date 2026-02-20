"""Video → frames extraction using OpenCV."""

import logging
from pathlib import Path

import cv2
import numpy as np

from .config import FrameExtractionConfig

logger = logging.getLogger(__name__)


def extract_frames(
    video_path: str | Path,
    output_dir: str | Path,
    config: FrameExtractionConfig | None = None,
    progress_callback=None,
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

    logger.info(
        "Video: %.1f FPS, %d frames, %.1fs duration, extracting every %d frames",
        fps, total_frames, duration, frame_interval,
    )

    saved_paths = []
    frame_idx = 0

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        if frame_idx % frame_interval == 0 and len(saved_paths) < config.max_frames:
            filename = f"frame_{len(saved_paths):05d}.{config.output_format}"
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
