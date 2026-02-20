"""2D red cone detection using HSV color filtering and contour analysis."""

import logging
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

from .config import ConeDetectionConfig

logger = logging.getLogger(__name__)


@dataclass
class ConeDetection:
    """A single detected cone in an image."""
    bbox: tuple[int, int, int, int]  # x, y, w, h
    centroid: tuple[float, float]
    tip: tuple[float, float]  # top-center of bounding box (cone tip)
    base_center: tuple[float, float]  # bottom-center (cone base)
    area: float
    solidity: float
    contour: np.ndarray


def create_red_mask(image_bgr: np.ndarray, config: ConeDetectionConfig) -> np.ndarray:
    """Create a binary mask for red regions in the image."""
    hsv = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2HSV)

    # Red wraps around hue=0, so two ranges
    lower1 = np.array([config.red_hue_low1, config.saturation_min, config.value_min])
    upper1 = np.array([config.red_hue_high1, 255, 255])
    mask1 = cv2.inRange(hsv, lower1, upper1)

    lower2 = np.array([config.red_hue_low2, config.saturation_min, config.value_min])
    upper2 = np.array([config.red_hue_high2, 255, 255])
    mask2 = cv2.inRange(hsv, lower2, upper2)

    mask = cv2.bitwise_or(mask1, mask2)

    # Morphological cleanup
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=2)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel, iterations=1)

    return mask


def detect_cones(
    image_bgr: np.ndarray,
    config: ConeDetectionConfig | None = None,
) -> list[ConeDetection]:
    """Detect red traffic cones in a BGR image."""
    config = config or ConeDetectionConfig()
    mask = create_red_mask(image_bgr, config)

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    # First pass: collect all red blobs with a low area threshold (for merge)
    pre_merge_min_area = 200
    candidates = []
    for contour in contours:
        area = cv2.contourArea(contour)
        if area < pre_merge_min_area or area > config.max_area:
            continue

        x, y, w, h = cv2.boundingRect(contour)

        hull = cv2.convexHull(contour)
        hull_area = cv2.contourArea(hull)
        solidity = area / hull_area if hull_area > 0 else 0

        moments = cv2.moments(contour)
        if moments["m00"] == 0:
            continue
        cx = moments["m10"] / moments["m00"]
        cy = moments["m01"] / moments["m00"]

        tip = (float(x + w / 2), float(y))
        base_center = (float(x + w / 2), float(y + h))

        candidates.append(ConeDetection(
            bbox=(x, y, w, h),
            centroid=(cx, cy),
            tip=tip,
            base_center=base_center,
            area=area,
            solidity=solidity,
            contour=contour,
        ))

    # Merge vertically aligned parts (cone tip + body split by white band)
    merged = _merge_vertically_aligned(candidates)

    # Second pass: apply strict filters on merged detections
    detections = []
    for det in merged:
        if det.area < config.min_area or det.area > config.max_area:
            continue
        x, y, w, h = det.bbox
        aspect_ratio = h / w if w > 0 else 0
        if aspect_ratio < config.min_aspect_ratio or aspect_ratio > config.max_aspect_ratio:
            continue
        if det.solidity < config.min_solidity:
            continue
        detections.append(det)

    logger.debug("Detected %d cones in image", len(detections))
    return detections


def _merge_vertically_aligned(detections: list[ConeDetection]) -> list[ConeDetection]:
    """Merge detections that are vertically aligned (same cone split by white band)."""
    if len(detections) < 2:
        return detections

    # Sort by Y position (top to bottom)
    detections = sorted(detections, key=lambda d: d.bbox[1])
    merged = []
    used = set()

    for i, d1 in enumerate(detections):
        if i in used:
            continue
        x1, y1, w1, h1 = d1.bbox
        cx1 = x1 + w1 / 2
        best_j = None

        for j, d2 in enumerate(detections):
            if j <= i or j in used:
                continue
            x2, y2, w2, h2 = d2.bbox
            cx2 = x2 + w2 / 2

            # Check horizontal alignment: centers within the wider bbox width
            max_w = max(w1, w2)
            if abs(cx1 - cx2) > max_w:
                continue

            # Check vertical gap: d2 is below d1, gap < 2x the taller bbox height
            gap = y2 - (y1 + h1)
            max_h = max(h1, h2)
            if 0 <= gap <= max_h * 2:
                best_j = j
                break  # merge with nearest below

        if best_j is not None:
            d2 = detections[best_j]
            used.add(best_j)
            # Combine bounding boxes
            x2, y2, w2, h2 = d2.bbox
            nx = min(x1, x2)
            ny = min(y1, y2)
            nx2 = max(x1 + w1, x2 + w2)
            ny2 = max(y1 + h1, y2 + h2)
            nw, nh = nx2 - nx, ny2 - ny
            combined_contour = np.vstack([d1.contour, d2.contour])
            total_area = d1.area + d2.area
            # Weighted centroid
            wcx = (d1.centroid[0] * d1.area + d2.centroid[0] * d2.area) / total_area
            wcy = (d1.centroid[1] * d1.area + d2.centroid[1] * d2.area) / total_area

            merged.append(ConeDetection(
                bbox=(nx, ny, nw, nh),
                centroid=(wcx, wcy),
                tip=(float(nx + nw / 2), float(ny)),
                base_center=(float(nx + nw / 2), float(ny + nh)),
                area=total_area,
                solidity=max(d1.solidity, d2.solidity),
                contour=combined_contour,
            ))
        else:
            merged.append(d1)

    return merged


def detect_cones_in_frames(
    frame_paths: list[Path],
    config: ConeDetectionConfig | None = None,
    progress_callback=None,
) -> dict[str, list[ConeDetection]]:
    """Detect cones across multiple frames.

    Returns dict mapping filename → list of ConeDetection.
    """
    config = config or ConeDetectionConfig()
    results = {}

    for i, path in enumerate(frame_paths):
        image = cv2.imread(str(path))
        if image is None:
            logger.warning("Cannot read image: %s", path)
            continue

        detections = detect_cones(image, config)
        if detections:
            results[path.name] = detections

        if progress_callback:
            progress_callback((i + 1) / len(frame_paths))

    logger.info("Found cones in %d / %d frames", len(results), len(frame_paths))
    return results


def draw_cone_overlays(
    image_bgr: np.ndarray,
    detections: list[ConeDetection],
) -> np.ndarray:
    """Draw cone detection overlays on an image. Returns a copy."""
    vis = image_bgr.copy()
    for det in detections:
        x, y, w, h = det.bbox
        cv2.rectangle(vis, (x, y), (x + w, y + h), (0, 255, 0), 2)
        cv2.circle(vis, (int(det.centroid[0]), int(det.centroid[1])), 5, (0, 255, 255), -1)
        cv2.circle(vis, (int(det.tip[0]), int(det.tip[1])), 5, (255, 0, 0), -1)
        cv2.circle(vis, (int(det.base_center[0]), int(det.base_center[1])), 5, (0, 0, 255), -1)
    return vis
