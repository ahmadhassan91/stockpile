"""Experimental single-frame depth-guided stockpile rescue diagnostics.

This module is intentionally isolated from the production measurement path.
It provides an optional, low-confidence fallback that can be used to inspect
whether a monocular depth prior helps recover a more realistic pile contour
when COLMAP registration fails.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass, field
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from .cone_detection import ConeDetection, create_red_mask, draw_cone_overlays
from .config import ConeDetectionConfig, FrameExtractionConfig
from .frame_extraction import extract_frames

logger = logging.getLogger(__name__)


@dataclass
class DepthRescueConfig:
    model_name: str = "depth-anything/Depth-Anything-V2-Small-hf"
    cone_height_m: float = 0.75
    material_density_t_per_m3: float = 2.1
    frame_interval_sec: float = 0.25
    max_frames: int = 180
    min_candidate_row_ratio: float = 0.18
    max_candidate_row_ratio: float = 0.93
    min_mask_area_ratio: float = 0.01


@dataclass
class DepthRescueResult:
    success: bool = False
    frame_path: str | None = None
    cone_bbox: tuple[int, int, int, int] | None = None
    cone_height_px: float | None = None
    pile_mask_area_px: int = 0
    pile_mask_ratio: float = 0.0
    pile_top_y_px: int | None = None
    estimated_height_m: float | None = None
    estimated_volume_m3: float | None = None
    estimated_weight_tonnes: float | None = None
    confidence: float = 0.0
    overlay_path: str | None = None
    contour_path: str | None = None
    notes: list[str] = field(default_factory=list)
    error: str | None = None

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2)


def _load_depth_pipeline(model_name: str):
    try:
        import torch
        from transformers import pipeline
    except ImportError as exc:
        raise RuntimeError(
            "Depth rescue requires optional dependencies: torch and transformers."
        ) from exc

    device = 0 if torch.cuda.is_available() else -1
    logger.info("Loading depth pipeline %s on device %s", model_name, device)
    return pipeline(task="depth-estimation", model=model_name, device=device)


def _predict_depth_map(image_bgr: np.ndarray, depth_pipe) -> np.ndarray:
    rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
    output = depth_pipe(Image.fromarray(rgb))

    if "predicted_depth" in output:
        pred = output["predicted_depth"]
        if hasattr(pred, "detach"):
            pred = pred.detach().cpu().numpy()
        depth_map = np.asarray(pred, dtype=np.float32)
    elif "depth" in output:
        depth_img = output["depth"]
        if isinstance(depth_img, Image.Image):
            depth_map = np.asarray(depth_img, dtype=np.float32)
        else:
            depth_map = np.asarray(depth_img, dtype=np.float32)
    else:
        raise RuntimeError("Depth model returned no usable depth map.")

    h, w = image_bgr.shape[:2]
    if depth_map.shape[:2] != (h, w):
        depth_map = cv2.resize(depth_map, (w, h), interpolation=cv2.INTER_CUBIC)
    return depth_map.astype(np.float32)


def _candidate_frame_score(image_shape: tuple[int, int, int], det: ConeDetection) -> float:
    h, w = image_shape[:2]
    _, _, _, bh = det.bbox
    area_ratio = det.area / max(1.0, float(h * w))
    base_ratio = det.base_center[1] / max(1.0, float(h))
    bottomness = max(0.0, 1.0 - (abs(base_ratio - 0.80) / 0.22))
    centeredness = 1.0 - min(1.0, abs(det.centroid[0] - (w / 2.0)) / max(1.0, w / 2.0))
    height_ratio = bh / max(1.0, float(h))
    return (area_ratio * 8.0) + (bottomness * 0.6) + (centeredness * 0.5) + (height_ratio * 4.5)


def _detect_depth_rescue_cones(
    image_bgr: np.ndarray,
    cone_detection_config: ConeDetectionConfig,
) -> list[ConeDetection]:
    """Experimental cone detector tuned for a single clear reference cone.

    The production detector intentionally merges red+white cone parts, but that
    can over-merge into bright aggregate regions for the rescue path. Here we
    use the red mask only and keep the geometry constraints much tighter.
    """
    h, w = image_bgr.shape[:2]
    mask = create_red_mask(image_bgr, cone_detection_config)
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    detections: list[ConeDetection] = []
    for contour in contours:
        area = float(cv2.contourArea(contour))
        if area < 120 or area > (h * w * 0.04):
            continue

        x, y, bw, bh = cv2.boundingRect(contour)
        if bw <= 0 or bh <= 0:
            continue
        aspect_ratio = bh / max(1.0, float(bw))
        if aspect_ratio < 1.1 or aspect_ratio > 5.5:
            continue
        if bh < h * 0.03 or bh > h * 0.35:
            continue
        if bw > w * 0.12:
            continue
        if (y + bh) < h * 0.45:
            continue

        hull = cv2.convexHull(contour)
        hull_area = float(cv2.contourArea(hull))
        solidity = area / hull_area if hull_area > 0 else 0.0
        if solidity < 0.35:
            continue

        moments = cv2.moments(contour)
        if moments["m00"] == 0:
            continue
        cx = moments["m10"] / moments["m00"]
        cy = moments["m01"] / moments["m00"]
        detections.append(
            ConeDetection(
                bbox=(x, y, bw, bh),
                centroid=(cx, cy),
                tip=(float(x + bw / 2), float(y)),
                base_center=(float(x + bw / 2), float(y + bh)),
                area=area,
                solidity=solidity,
                contour=contour,
            )
        )

    return detections


def select_best_depth_frame(
    frame_paths: list[Path],
    cone_detection_config: ConeDetectionConfig | None = None,
) -> tuple[Path, ConeDetection]:
    """Select the strongest cone-bearing frame for the depth rescue experiment."""
    cone_detection_config = cone_detection_config or ConeDetectionConfig()

    best: tuple[float, Path, ConeDetection] | None = None
    for path in frame_paths:
        image = cv2.imread(str(path))
        if image is None:
            continue
        detections = _detect_depth_rescue_cones(image, cone_detection_config)
        if not detections:
            continue
        det = max(detections, key=lambda d: _candidate_frame_score(image.shape, d))
        score = _candidate_frame_score(image.shape, det)
        if best is None or score > best[0]:
            best = (score, path, det)

    if best is None:
        raise RuntimeError("No suitable cone-bearing frame was found for depth rescue.")
    return best[1], best[2]


def _smooth_row_baseline(depth_map: np.ndarray) -> np.ndarray:
    h, w = depth_map.shape
    x0 = int(w * 0.15)
    x1 = int(w * 0.85)
    per_row = np.percentile(depth_map[:, x0:x1], 35, axis=1)
    kernel = np.ones(31, dtype=np.float32) / 31.0
    smoothed = np.convolve(per_row, kernel, mode="same")
    return smoothed.astype(np.float32)


def _cone_exclusion_mask(shape: tuple[int, int], det: ConeDetection) -> np.ndarray:
    h, w = shape
    x, y, bw, bh = det.bbox
    pad_x = int(max(12, bw * 0.35))
    pad_y = int(max(12, bh * 0.15))
    mask = np.zeros((h, w), dtype=np.uint8)
    x0 = max(0, x - pad_x)
    y0 = max(0, y - pad_y)
    x1 = min(w, x + bw + pad_x)
    y1 = min(h, y + bh + pad_y)
    mask[y0:y1, x0:x1] = 1
    return mask


def _largest_component(mask: np.ndarray, target_xy: tuple[int, int] | None = None) -> np.ndarray:
    num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), connectivity=8)
    if num_labels <= 1:
        return np.zeros_like(mask, dtype=np.uint8)

    if target_xy is not None:
        tx, ty = target_xy
        if 0 <= ty < labels.shape[0] and 0 <= tx < labels.shape[1]:
            label = labels[ty, tx]
            if label > 0:
                return (labels == label).astype(np.uint8)

    best_label = 0
    best_area = 0
    for label in range(1, num_labels):
        area = int(stats[label, cv2.CC_STAT_AREA])
        if area > best_area:
            best_area = area
            best_label = label
    return (labels == best_label).astype(np.uint8)


def _build_pile_mask(depth_map: np.ndarray, det: ConeDetection, config: DepthRescueConfig) -> tuple[np.ndarray, np.ndarray]:
    h, w = depth_map.shape
    row_baseline = _smooth_row_baseline(depth_map).reshape(-1, 1)
    relief = np.maximum(depth_map - row_baseline, 0.0)

    candidate = np.zeros((h, w), dtype=np.uint8)
    y0 = int(h * config.min_candidate_row_ratio)
    y1 = int(h * config.max_candidate_row_ratio)
    candidate[y0:y1, :] = 1
    candidate[: int(h * 0.10), :] = 0
    candidate[int(h * 0.96):, :] = 0
    candidate *= (1 - _cone_exclusion_mask((h, w), det))

    candidate_relief = relief[candidate.astype(bool)]
    if candidate_relief.size == 0:
        return np.zeros((h, w), dtype=np.uint8), relief

    threshold = max(
        float(np.percentile(candidate_relief, 82)),
        float(np.max(candidate_relief) * 0.22),
    )
    mask = ((relief >= threshold) & candidate.astype(bool)).astype(np.uint8)

    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (21, 21))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=2)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel, iterations=1)

    peak_y, peak_x = np.unravel_index(np.argmax(relief * candidate), relief.shape)
    mask = _largest_component(mask, target_xy=(int(peak_x), int(peak_y)))
    return mask.astype(np.uint8), relief


def _estimate_depth_rescue_volume(
    depth_map: np.ndarray,
    relief: np.ndarray,
    pile_mask: np.ndarray,
    det: ConeDetection,
    config: DepthRescueConfig,
) -> tuple[float | None, float | None]:
    pile_pixels = int(np.count_nonzero(pile_mask))
    if pile_pixels == 0:
        return None, None

    h, w = depth_map.shape
    cone_height_px = max(1.0, float(det.bbox[3]))
    m_per_px_fg = float(config.cone_height_m) / cone_height_px

    ys, xs = np.where(pile_mask > 0)
    pile_top_y = int(np.min(ys))
    visible_pile_height_px = max(1.0, float(det.base_center[1] - pile_top_y))
    # Experimental: use the visible front-face rise as a loose height prior.
    visible_pile_height_m = visible_pile_height_px * m_per_px_fg

    relief_masked = relief * pile_mask
    relief_peak = float(np.max(relief_masked))
    if relief_peak <= 1e-6:
        return None, None

    normalized_relief = np.clip(relief_masked / relief_peak, 0.0, 1.0)
    real_height_m = normalized_relief * visible_pile_height_m

    ground_base = float(np.percentile(depth_map[int(h * 0.85):, :], 50))
    expansion_input = (depth_map + 1e-6) / (ground_base + 1e-6)
    expansion_input = np.clip(expansion_input, 1e-3, 1e3)
    expansion = expansion_input ** -2.2
    expansion = np.clip(expansion, 0.25, 16.0)
    pixel_area_map = (m_per_px_fg ** 2) / expansion

    volume_m3 = float(np.sum(real_height_m * pixel_area_map * pile_mask))
    if not np.isfinite(volume_m3):
        return None, visible_pile_height_m
    return volume_m3, visible_pile_height_m


def _render_depth_overlay(
    image_bgr: np.ndarray,
    det: ConeDetection,
    pile_mask: np.ndarray,
    relief: np.ndarray,
    output_dir: Path,
) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)

    contour_image = draw_cone_overlays(image_bgr, [det])
    contours, _ = cv2.findContours(pile_mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    cv2.drawContours(contour_image, contours, -1, (255, 255, 0), 3)

    relief_norm = relief.copy()
    max_relief = float(np.max(relief_norm))
    if max_relief > 1e-6:
        relief_norm = relief_norm / max_relief
    relief_u8 = np.clip(relief_norm * 255.0, 0, 255).astype(np.uint8)
    heatmap = cv2.applyColorMap(relief_u8, cv2.COLORMAP_TURBO)
    heatmap[pile_mask == 0] = (18, 18, 32)
    cv2.drawContours(heatmap, contours, -1, (255, 255, 255), 2)

    overlay_path = output_dir / "depth_rescue_overlay.jpg"
    contour_path = output_dir / "depth_rescue_relief.jpg"
    cv2.imwrite(str(overlay_path), contour_image)
    cv2.imwrite(str(contour_path), heatmap)
    return overlay_path, contour_path


def run_depth_rescue_from_frames(
    frame_paths: list[Path],
    output_dir: Path,
    config: DepthRescueConfig | None = None,
    cone_detection_config: ConeDetectionConfig | None = None,
) -> DepthRescueResult:
    """Run the experimental depth rescue on extracted frames."""
    config = config or DepthRescueConfig()
    result = DepthRescueResult()

    try:
        frame_path, det = select_best_depth_frame(frame_paths, cone_detection_config)
        result.frame_path = str(frame_path)
        result.cone_bbox = det.bbox
        result.cone_height_px = float(det.bbox[3])

        image = cv2.imread(str(frame_path))
        if image is None:
            raise RuntimeError(f"Cannot read rescue frame {frame_path}")

        depth_pipe = _load_depth_pipeline(config.model_name)
        depth_map = _predict_depth_map(image, depth_pipe)
        pile_mask, relief = _build_pile_mask(depth_map, det, config)

        h, w = pile_mask.shape
        result.pile_mask_area_px = int(np.count_nonzero(pile_mask))
        result.pile_mask_ratio = float(result.pile_mask_area_px) / max(1.0, float(h * w))
        if result.pile_mask_ratio < config.min_mask_area_ratio:
            raise RuntimeError(
                f"Depth rescue pile mask is too small ({result.pile_mask_ratio:.2%}) to be meaningful."
            )

        ys, _ = np.where(pile_mask > 0)
        if ys.size:
            result.pile_top_y_px = int(np.min(ys))

        volume_m3, height_m = _estimate_depth_rescue_volume(depth_map, relief, pile_mask, det, config)
        result.estimated_height_m = height_m
        result.estimated_volume_m3 = volume_m3
        if volume_m3 is not None:
            result.estimated_weight_tonnes = volume_m3 * config.material_density_t_per_m3

        overlay_path, contour_path = _render_depth_overlay(image, det, pile_mask, relief, output_dir)
        result.overlay_path = str(overlay_path)
        result.contour_path = str(contour_path)

        # Keep confidence intentionally conservative: this is a qualitative rescue.
        confidence = 0.25
        confidence += min(0.20, max(0.0, result.pile_mask_ratio * 2.0))
        confidence += min(0.20, max(0.0, (result.cone_height_px or 0.0) / 1200.0))
        result.confidence = float(min(confidence, 0.55))
        result.notes.extend(
            [
                "Experimental single-frame monocular depth rescue.",
                "Use this to inspect contour realism and rough order-of-magnitude only.",
                "Do not treat the estimated volume as delivery-grade without an external benchmark.",
            ]
        )
        result.success = True
        return result
    except Exception as exc:
        result.error = str(exc)
        result.notes.append(
            "Depth rescue failed before producing a reliable contour or estimate."
        )
        return result


def run_depth_rescue_from_video(
    video_path: str | Path,
    workspace_dir: str | Path,
    config: DepthRescueConfig | None = None,
    cone_detection_config: ConeDetectionConfig | None = None,
) -> DepthRescueResult:
    """Extract frames and run the depth rescue experiment."""
    config = config or DepthRescueConfig()
    workspace_dir = Path(workspace_dir)
    frames_dir = workspace_dir / "frames"
    output_dir = workspace_dir / "output"
    frame_paths = extract_frames(
        video_path,
        frames_dir,
        config=FrameExtractionConfig(
            interval_sec=config.frame_interval_sec,
            max_frames=config.max_frames,
        ),
        progress_callback=None,
    )

    return run_depth_rescue_from_frames(
        frame_paths,
        output_dir=output_dir,
        config=config,
        cone_detection_config=cone_detection_config,
    )
