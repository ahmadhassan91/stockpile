"""Scale calibration: match 2D cone detections to 3D COLMAP points."""

import logging
from dataclasses import dataclass

import numpy as np
from sklearn.cluster import DBSCAN

from .colmap_runner import ColmapImage, ColmapPoint3D
from .cone_detection import ConeDetection
from .config import ScaleCalibrationConfig

logger = logging.getLogger(__name__)


@dataclass
class CalibrationResult:
    scale_factor: float  # meters per COLMAP unit
    confidence: float  # 0-1 based on consistency
    num_cones_used: int
    per_cone_scales: list[float]
    cone_3d_positions: list[np.ndarray]  # 3D centroids of each cone cluster


def find_keypoints_in_bbox(
    image: ColmapImage,
    bbox: tuple[int, int, int, int],
    margin: int = 5,
) -> list[tuple[int, int]]:
    """Find COLMAP keypoints that fall inside a bounding box.

    Returns list of (keypoint_index, point3d_id) for keypoints with valid 3D points.
    """
    x, y, w, h = bbox
    x1, y1 = x - margin, y - margin
    x2, y2 = x + w + margin, y + h + margin

    matches = []
    for idx in range(len(image.xys)):
        kx, ky = image.xys[idx]
        p3d_id = image.point3d_ids[idx]
        if p3d_id >= 0 and x1 <= kx <= x2 and y1 <= ky <= y2:
            matches.append((idx, int(p3d_id)))

    return matches


def gather_cone_3d_points(
    cone_detections: dict[str, list[ConeDetection]],
    images: dict[int, ColmapImage],
    points3d: dict[int, ColmapPoint3D],
) -> list[np.ndarray]:
    """Collect 3D points that fall inside cone bounding boxes across all frames.

    Returns list of 3D point coordinate arrays, one per detection event.
    """
    # Build name→image lookup
    name_to_image = {img.name: img for img in images.values()}

    all_cone_points = []  # list of (N, 3) arrays

    for frame_name, detections in cone_detections.items():
        colmap_img = name_to_image.get(frame_name)
        if colmap_img is None:
            continue

        for det in detections:
            matches = find_keypoints_in_bbox(colmap_img, det.bbox)
            if not matches:
                continue

            pts_3d = []
            for _, p3d_id in matches:
                if p3d_id in points3d:
                    pts_3d.append(points3d[p3d_id].xyz)

            if pts_3d:
                all_cone_points.append(np.array(pts_3d))

    logger.info("Gathered 3D points from %d cone detections", len(all_cone_points))
    return all_cone_points


def cluster_cone_points(
    cone_point_sets: list[np.ndarray],
    config: ScaleCalibrationConfig,
) -> list[np.ndarray]:
    """Cluster gathered cone 3D points into individual physical cones using DBSCAN."""
    if not cone_point_sets:
        return []

    # Combine all cone points
    all_points = np.vstack(cone_point_sets)
    if len(all_points) < config.dbscan_min_samples:
        return []

    clustering = DBSCAN(
        eps=config.dbscan_eps,
        min_samples=config.dbscan_min_samples,
    ).fit(all_points)

    labels = clustering.labels_
    unique_labels = set(labels) - {-1}

    clusters = []
    for label in sorted(unique_labels):
        mask = labels == label
        clusters.append(all_points[mask])

    logger.info("DBSCAN found %d cone clusters from %d total points",
                len(clusters), len(all_points))
    return clusters


def compute_scale_from_cones(
    clusters: list[np.ndarray],
    config: ScaleCalibrationConfig,
) -> CalibrationResult:
    """Compute scale factor from cone cluster vertical extents."""
    if not clusters:
        raise ValueError("No cone clusters found for calibration")

    per_cone_scales = []
    cone_positions = []

    for cluster in clusters:
        # Vertical extent: use the axis with greatest spread
        # (since we don't know the ground plane yet, use the principal axis)
        spread = cluster.max(axis=0) - cluster.min(axis=0)
        vertical_extent = spread.max()  # Largest dimension as proxy for height

        if vertical_extent > 1e-6:
            scale = config.known_cone_height_m / vertical_extent
            per_cone_scales.append(scale)
            cone_positions.append(cluster.mean(axis=0))

    if not per_cone_scales:
        raise ValueError("Could not compute scale from any cone cluster")

    # Use median for robustness against outliers
    scale_factor = float(np.median(per_cone_scales))

    # Confidence: based on consistency (low std/mean ratio) and number of cones
    if len(per_cone_scales) >= 2:
        cv = np.std(per_cone_scales) / np.mean(per_cone_scales)  # coefficient of variation
        consistency = max(0.0, 1.0 - cv)
    else:
        consistency = 0.5

    count_factor = min(1.0, len(per_cone_scales) / config.min_cones_for_confidence)
    confidence = consistency * count_factor

    logger.info(
        "Scale: %.6f m/unit (from %d cones, confidence=%.2f)",
        scale_factor, len(per_cone_scales), confidence,
    )

    return CalibrationResult(
        scale_factor=scale_factor,
        confidence=confidence,
        num_cones_used=len(per_cone_scales),
        per_cone_scales=per_cone_scales,
        cone_3d_positions=cone_positions,
    )


def calibrate_scale(
    cone_detections: dict[str, list],
    images: dict[int, ColmapImage],
    points3d: dict[int, ColmapPoint3D],
    config: ScaleCalibrationConfig | None = None,
) -> CalibrationResult:
    """Full scale calibration pipeline: detections → 3D matching → clustering → scale."""
    config = config or ScaleCalibrationConfig()

    cone_point_sets = gather_cone_3d_points(cone_detections, images, points3d)
    clusters = cluster_cone_points(cone_point_sets, config)
    return compute_scale_from_cones(clusters, config)
