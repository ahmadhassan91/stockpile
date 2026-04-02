"""Scale calibration: compute real-world scale from cone detections + COLMAP data."""

import logging
from dataclasses import dataclass, field

import numpy as np
import open3d as o3d

from .colmap_runner import ColmapCamera, ColmapImage, ColmapPoint3D
from .cone_detection import ConeDetection
from .config import ScaleCalibrationConfig

logger = logging.getLogger(__name__)


@dataclass
class CalibrationResult:
    scale_factor: float  # meters per COLMAP unit
    confidence: float  # 0-1
    num_cones_used: int
    per_cone_scales: list[float]
    cone_3d_positions: list[np.ndarray]
    selected_method: str = "projection"
    projection_scale_factor: float | None = None
    projection_confidence: float | None = None
    camera_height_scale_factor: float | None = None
    camera_height_confidence: float | None = None
    scale_disagreement_ratio: float | None = None
    notes: list[str] = field(default_factory=list)


def _qvec_to_rotmat(qvec: np.ndarray) -> np.ndarray:
    """Convert COLMAP quaternion (w, x, y, z) to 3x3 rotation matrix."""
    w, x, y, z = qvec
    return np.array([
        [1 - 2*(y*y + z*z), 2*(x*y - w*z), 2*(x*z + w*y)],
        [2*(x*y + w*z), 1 - 2*(x*x + z*z), 2*(y*z - w*x)],
        [2*(x*z - w*y), 2*(y*z + w*x), 1 - 2*(x*x + y*y)],
    ])


def _camera_center(image: ColmapImage) -> np.ndarray:
    """Get camera center in world coordinates: C = -R^T @ t."""
    R = _qvec_to_rotmat(image.qvec)
    return -R.T @ image.tvec


def _mad_inlier_mask(values: np.ndarray, mad_multiplier: float) -> np.ndarray:
    """Return a robust inlier mask using median absolute deviation."""
    if len(values) < 5:
        return np.ones(len(values), dtype=bool)

    median = float(np.median(values))
    mad = float(np.median(np.abs(values - median)))
    if mad < 1e-9:
        return np.ones(len(values), dtype=bool)

    robust_z = 0.6745 * (values - median) / mad
    mask = np.abs(robust_z) <= mad_multiplier
    if int(mask.sum()) < 3:
        return np.ones(len(values), dtype=bool)
    return mask


def calibrate_scale_projection(
    cone_detections: dict[str, list[ConeDetection]],
    images: dict[int, ColmapImage],
    points3d: dict[int, ColmapPoint3D],
    cameras: dict[int, ColmapCamera],
    config: ScaleCalibrationConfig,
) -> CalibrationResult:
    """Compute scale using projection geometry.

    For each cone detection in each frame:
    1. Get the cone's pixel height from the bounding box
    2. Get the camera focal length from COLMAP
    3. Find a COLMAP keypoint inside the cone bbox that has a 3D point
    4. Compute distance from camera center to that 3D point
    5. scale = known_height_m * focal_length_px / (pixel_height * distance)

    This is much more reliable than measuring 3D point spread because it
    only needs ONE good 3D point per cone (not a cluster), and uses the
    well-calibrated camera model.
    """
    name_to_image = {img.name: img for img in images.values()}
    per_frame_scales = []
    cone_positions = []
    notes: list[str] = []

    for frame_name, detections in cone_detections.items():
        colmap_img = name_to_image.get(frame_name)
        if colmap_img is None:
            continue

        camera = cameras.get(colmap_img.camera_id)
        if camera is None:
            continue

        focal = camera.focal_length
        cam_center = _camera_center(colmap_img)

        for det in detections:
            x, y, w, h = det.bbox
            pixel_height = h  # cone height in pixels

            if pixel_height < 20:  # too small to be reliable
                continue

            # Find COLMAP keypoints inside the cone bbox with valid 3D points
            margin = 5
            x1, y1 = x - margin, y - margin
            x2, y2 = x + w + margin, y + h + margin

            matched_distances = []
            matched_positions = []

            for idx in range(len(colmap_img.xys)):
                kx, ky = colmap_img.xys[idx]
                p3d_id = int(colmap_img.point3d_ids[idx])
                if p3d_id < 0:
                    continue
                if not (x1 <= kx <= x2 and y1 <= ky <= y2):
                    continue
                if p3d_id not in points3d:
                    continue

                pt3d = points3d[p3d_id].xyz
                dist = np.linalg.norm(pt3d - cam_center)
                matched_distances.append(dist)
                matched_positions.append(pt3d)

            if not matched_distances:
                continue

            # Use the CLOSEST keypoints — they're most likely on the cone
            # surface, not background objects that happen to project inside
            # the bounding box. Use 25th percentile for robustness.
            close_dist = np.percentile(matched_distances, 25)

            # Projection: pixel_height / focal = real_height / distance
            # real_height (in COLMAP units) = pixel_height * distance / focal
            # scale = known_height_m / real_height_colmap
            real_height_colmap = pixel_height * close_dist / focal
            scale = config.known_cone_height_m / real_height_colmap

            per_frame_scales.append(scale)
            # Store median 3D position as cone location
            cone_positions.append(np.median(matched_positions, axis=0))

    if not per_frame_scales:
        raise ValueError("No cone-camera projection matches found for calibration")

    raw_scales = np.asarray(per_frame_scales, dtype=float)
    raw_positions = np.asarray(cone_positions, dtype=float)
    inlier_mask = _mad_inlier_mask(raw_scales, config.projection_outlier_mad_multiplier)
    if not np.all(inlier_mask):
        dropped = int((~inlier_mask).sum())
        notes.append(f"Discarded {dropped} projection scale outlier(s) before computing the final scale.")
        logger.info(
            "Projection scale trimming removed %d / %d outlier samples",
            dropped,
            len(raw_scales),
        )
    filtered_scales = raw_scales[inlier_mask]
    filtered_positions = raw_positions[inlier_mask] if len(raw_positions) else raw_positions

    # Use median across all frames for robustness
    scale_factor = float(np.median(filtered_scales))

    # Confidence based on consistency and sample count
    if len(filtered_scales) >= 3:
        cv = np.std(filtered_scales) / np.mean(filtered_scales)
        consistency = max(0.0, 1.0 - cv)
    else:
        consistency = 0.5

    count_factor = min(1.0, len(filtered_scales) / 10)  # more frames = more confident
    retention_factor = len(filtered_scales) / len(raw_scales)
    confidence = consistency * count_factor * retention_factor

    # Deduplicate cone positions with a scene-scale radius, since the median
    # 3D point inside each bbox can drift noticeably between frames.
    unique_positions = _deduplicate_positions(list(filtered_positions), threshold=config.dbscan_eps)

    logger.info(
        "Projection-based scale: %.4f m/unit (from %d/%d frame-cone pairs, "
        "%d unique cones, confidence=%.2f)",
        scale_factor, len(filtered_scales), len(raw_scales), len(unique_positions), confidence,
    )

    return CalibrationResult(
        scale_factor=scale_factor,
        confidence=confidence,
        num_cones_used=len(unique_positions),
        per_cone_scales=list(filtered_scales),
        cone_3d_positions=unique_positions,
        selected_method="projection",
        projection_scale_factor=scale_factor,
        projection_confidence=confidence,
        notes=notes,
    )


def _deduplicate_positions(
    positions: list[np.ndarray],
    threshold: float,
) -> list[np.ndarray]:
    """Merge nearby 3D positions into unique cone locations."""
    if not positions:
        return []

    unique = [positions[0]]
    for pos in positions[1:]:
        is_new = True
        for u in unique:
            if np.linalg.norm(pos - u) < threshold:
                is_new = False
                break
        if is_new:
            unique.append(pos)
    return unique


def calibrate_scale_from_camera_height(
    images: dict[int, ColmapImage],
    points3d: dict[int, ColmapPoint3D],
    config: ScaleCalibrationConfig,
    cone_positions: list[np.ndarray] | None = None,
) -> CalibrationResult:
    """Estimate scale using camera height above the ground plane.

    COLMAP camera positions are its most reliable output. For a handheld
    walkaround, cameras are ~1.5m above ground. We fit a ground plane to
    the lowest points, compute camera distances to it, and derive scale.
    """
    all_xyz = np.array([p.xyz for p in points3d.values()])

    # Get camera positions
    cam_centers = []
    for img in images.values():
        cam_centers.append(_camera_center(img))
    cam_centers = np.array(cam_centers)

    # Fit ground plane to the lowest points using RANSAC
    # The lowest 15% of points along each axis — try all 3 and pick best
    pcd = o3d.geometry.PointCloud()
    pcd.points = o3d.utility.Vector3dVector(all_xyz)

    best_scale = None
    best_score = -1.0
    best_metrics: dict[str, float | int | str | None] | None = None

    o3d.utility.random.seed(config.random_seed)

    for axis in range(3):
        for use_low in [True, False]:
            pct = 15 if use_low else 85
            threshold = np.percentile(all_xyz[:, axis], pct)
            if use_low:
                mask = all_xyz[:, axis] <= threshold
            else:
                mask = all_xyz[:, axis] >= threshold

            indices = np.where(mask)[0].tolist()
            if len(indices) < 20:
                continue

            sub_cloud = pcd.select_by_index(indices)
            try:
                plane_model, _ = sub_cloud.segment_plane(
                    distance_threshold=0.02, ransac_n=3, num_iterations=500,
                )
            except Exception:
                continue

            a, b, c, d = plane_model
            norm = np.sqrt(a*a + b*b + c*c)

            # Camera distances to this plane (signed)
            cam_dists = (cam_centers @ np.array([a, b, c]) + d) / norm

            # Ground points distances
            ground_dists = (all_xyz[mask] @ np.array([a, b, c]) + d) / norm

            # Cameras should be consistently on one side (above ground)
            # and the ground points should be near zero
            cam_abs = np.abs(cam_dists)
            cam_median = np.median(cam_abs)
            ground_std = np.std(ground_dists)

            if cam_median < 0.01:  # cameras too close to plane
                continue

            scale_est = config.assumed_camera_height_m / cam_median

            # Scale-invariant plane score:
            # - camera heights should be consistent
            # - candidate ground points should lie close to the plane
            # - cone centers should sit at a broadly similar offset from the plane
            cam_cv = np.std(cam_abs) / cam_median if cam_median > 0 else 999
            ground_std_rel = ground_std / cam_median if cam_median > 0 else 999
            camera_score = 1.0 / (1.0 + cam_cv)
            ground_score = 1.0 / (1.0 + (ground_std_rel / max(config.camera_height_ground_std_rel_max, 1e-6)))

            cone_cv = None
            cone_score = 1.0
            if cone_positions and len(cone_positions) >= 3:
                cone_arr = np.asarray(cone_positions)
                cone_abs = np.abs((cone_arr @ np.array([a, b, c]) + d) / norm)
                cone_median = np.median(cone_abs)
                if cone_median > 1e-6:
                    cone_cv = float(np.std(cone_abs) / cone_median)
                    cone_score = 1.0 / (
                        1.0 + (cone_cv / max(config.camera_height_cone_cv_max, 1e-6))
                    )

            candidate_score = camera_score * ground_score * cone_score

            if candidate_score > best_score:
                best_score = candidate_score
                best_scale = scale_est
                best_metrics = {
                    "axis": axis,
                    "subset": "low" if use_low else "high",
                    "cam_cv": float(cam_cv),
                    "ground_std_rel": float(ground_std_rel),
                    "cone_cv": cone_cv,
                    "score": float(candidate_score),
                }

                logger.info(
                    "Camera-height axis %d (%s): scale=%.4f, cam_height=%.4f units, "
                    "cam_cv=%.2f, ground_rel_std=%.3f, cone_cv=%s, score=%.2f",
                    axis,
                    "low" if use_low else "high",
                    scale_est,
                    cam_median,
                    cam_cv,
                    ground_std_rel,
                    "n/a" if cone_cv is None else f"{cone_cv:.2f}",
                    candidate_score,
                )

    if best_scale is None:
        raise ValueError("Could not estimate scale from camera height")

    logger.info(
        "Camera-height scale: %.4f m/unit (score=%.2f, candidate=%s/%s)",
        best_scale,
        best_score,
        best_metrics["axis"] if best_metrics else "n/a",
        best_metrics["subset"] if best_metrics else "n/a",
    )

    notes = []
    if best_metrics is not None:
        notes.append(
            "Camera-height cross-check candidate "
            f"axis {best_metrics['axis']} ({best_metrics['subset']}) "
            f"score={best_metrics['score']:.2f}"
        )

    return CalibrationResult(
        scale_factor=best_scale,
        confidence=max(0.0, min(best_score, 1.0)) * 0.6,  # cap because it remains an assumption
        num_cones_used=0,
        per_cone_scales=[best_scale],
        cone_3d_positions=[],
        selected_method="camera_height",
        camera_height_scale_factor=best_scale,
        camera_height_confidence=max(0.0, min(best_score, 1.0)) * 0.6,
        notes=notes,
    )


def calibrate_scale(
    cone_detections: dict[str, list[ConeDetection]],
    images: dict[int, ColmapImage],
    points3d: dict[int, ColmapPoint3D],
    config: ScaleCalibrationConfig | None = None,
    cameras: dict[int, ColmapCamera] | None = None,
) -> CalibrationResult:
    """Main calibration entry point.

    Tries projection-based (cone pixel height + distance), then cross-checks
    with camera-height method. Uses the method with better confidence.
    """
    config = config or ScaleCalibrationConfig()

    projection_result = None
    camera_result = None

    # Try projection-based calibration
    if cameras and cone_detections:
        try:
            projection_result = calibrate_scale_projection(
                cone_detections, images, points3d, cameras, config,
            )
            logger.info("Projection scale: %.4f (confidence %.2f)",
                        projection_result.scale_factor, projection_result.confidence)
        except Exception as e:
            logger.warning("Projection calibration failed: %s", e)

    # Always try camera-height method as cross-check
    try:
        camera_result = calibrate_scale_from_camera_height(
            images,
            points3d,
            config,
            projection_result.cone_3d_positions if projection_result else None,
        )
        logger.info("Camera-height scale: %.4f (confidence %.2f)",
                    camera_result.scale_factor, camera_result.confidence)
    except Exception as e:
        logger.warning("Camera-height calibration failed: %s", e)

    # Choose best result — always prefer projection when we have cone detections,
    # since it uses real physical measurements (cone height in pixels + distance).
    # Camera-height is only a fallback assumption (1.6m handheld) and introduces
    # systematic bias when the actual camera height differs.
    if projection_result and camera_result:
        projection_result.camera_height_scale_factor = camera_result.scale_factor
        projection_result.camera_height_confidence = camera_result.confidence
        projection_result.notes.extend(camera_result.notes)

        if camera_result.confidence < config.min_camera_height_confidence_for_crosscheck:
            projection_result.notes.append(
                "Camera-height cross-check was ignored because the fitted ground plane was not stable enough."
            )
            logger.info(
                "Using projection scale %.4f without camera-height cross-check "
                "(camera-height confidence %.2f < %.2f)",
                projection_result.scale_factor,
                camera_result.confidence,
                config.min_camera_height_confidence_for_crosscheck,
            )
            return projection_result

        ratio = max(
            projection_result.scale_factor / camera_result.scale_factor,
            camera_result.scale_factor / projection_result.scale_factor,
        )
        projection_result.scale_disagreement_ratio = ratio
        projection_result.notes.append(
            "Projection and camera-height scale checks disagree"
            if ratio >= config.max_method_disagreement_ratio
            else "Projection and camera-height scale checks are broadly aligned"
        )
        if ratio < config.max_method_disagreement_ratio:
            logger.info(
                "Using projection scale %.4f (camera-height was %.4f, ratio %.2f)",
                projection_result.scale_factor, camera_result.scale_factor, ratio,
            )
        else:
            logger.warning(
                "Projection (%.4f) and camera-height (%.4f) disagree by %.1fx — "
                "still using projection (physical measurement preferred over assumption)",
                projection_result.scale_factor, camera_result.scale_factor, ratio,
            )
        return projection_result
    if projection_result:
        return projection_result
    if camera_result:
        if camera_result.confidence < config.min_camera_height_confidence_for_crosscheck:
            camera_result.notes.append(
                "Camera-height fallback is low-confidence. Capture visible cones or use a manual scale override when possible."
            )
        camera_result.notes.append("Using camera-height fallback because projection calibration was unavailable")
        return camera_result
    raise ValueError("All calibration methods failed")
