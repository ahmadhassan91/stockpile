"""Scale calibration: compute real-world scale from cone detections + COLMAP data."""

import logging
from dataclasses import dataclass, field

import numpy as np

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

            if pixel_height < config.min_cone_pixel_height:
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

            # --- Depth-filter: remove background 3D points that project
            # inside the cone bbox but are much farther than the cone ---
            dists_arr = np.asarray(matched_distances, dtype=float)
            pos_arr = np.asarray(matched_positions, dtype=float)
            med_dist = float(np.median(dists_arr))
            depth_mask = dists_arr <= 2.0 * med_dist
            if depth_mask.sum() >= 1:
                dists_arr = dists_arr[depth_mask]
                pos_arr = pos_arr[depth_mask]
                matched_distances = dists_arr.tolist()
                matched_positions = [pos_arr[i] for i in range(len(pos_arr))]

            # Use the CLOSEST keypoints — they're most likely on the cone
            # surface, not background objects that happen to project inside
            # the bounding box. Use 25th percentile for robustness.
            close_dist = np.percentile(matched_distances, 25)

            # Distance cap: reject far-field observations where COLMAP
            # overestimates 3D distances, dragging scale down.
            if close_dist > config.max_projection_distance:
                continue

            # Projection: pixel_height / focal = real_height / distance
            # real_height (in COLMAP units) = pixel_height * distance / focal
            # scale = known_height_m / real_height_colmap
            real_height_colmap = pixel_height * close_dist / focal
            scale = config.known_cone_height_m / real_height_colmap

            # Hard plausibility bounds — reject wildly wrong per-detection scales
            if scale < config.min_plausible_scale or scale > config.max_plausible_scale:
                continue

            per_frame_scales.append(scale)
            # Store median 3D position as cone location
            cone_positions.append(np.median(matched_positions, axis=0))

    if not per_frame_scales:
        raise ValueError("No cone-camera projection matches found for calibration")

    raw_scales = np.asarray(per_frame_scales, dtype=float)
    notes: list[str] = []

    # MAD-based outlier rejection
    inlier_mask = _mad_inlier_mask(raw_scales, config.projection_outlier_mad_multiplier)
    if not np.all(inlier_mask):
        dropped = int((~inlier_mask).sum())
        notes.append(f"Discarded {dropped} projection scale outlier(s) via MAD filtering.")
        logger.info(
            "Projection scale MAD trimming removed %d / %d outlier samples",
            dropped, len(raw_scales),
        )
    filtered_scales = raw_scales[inlier_mask]
    filtered_positions = [cone_positions[i] for i in range(len(cone_positions)) if inlier_mask[i]]

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

    # Deduplicate cone positions (cluster nearby ones)
    unique_positions = _deduplicate_positions(filtered_positions, threshold=scale_factor * 0.5)

    # --- Inter-cone distance cross-check ---
    if len(unique_positions) >= 2:
        pairwise_dists_colmap = []
        for i in range(len(unique_positions)):
            for j in range(i + 1, len(unique_positions)):
                d = float(np.linalg.norm(
                    np.asarray(unique_positions[i]) - np.asarray(unique_positions[j])
                ))
                if d > 1e-6:
                    pairwise_dists_colmap.append(d)

        if pairwise_dists_colmap:
            median_pair_colmap = float(np.median(pairwise_dists_colmap))
            median_pair_m = median_pair_colmap * scale_factor
            notes.append(
                f"Inter-cone spacing: {median_pair_m:.1f} m at projection scale "
                f"({len(pairwise_dists_colmap)} pair(s) from {len(unique_positions)} cones)."
            )
            if median_pair_m < 0.5 or median_pair_m > 100.0:
                notes.append(
                    f"WARNING: Inter-cone spacing {median_pair_m:.1f} m is outside "
                    "plausible range [0.5, 100] m — possible scale error."
                )

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
    assumed_camera_height_m: float = 1.6,
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
    import open3d as o3d

    pcd = o3d.geometry.PointCloud()
    pcd.points = o3d.utility.Vector3dVector(all_xyz)

    best_scale = None
    best_consistency = 0

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
            cam_median = np.median(np.abs(cam_dists))
            ground_std = np.std(ground_dists)

            if cam_median < 0.01:  # cameras too close to plane
                continue

            scale_est = assumed_camera_height_m / cam_median

            # Consistency: cameras should have similar heights
            cam_cv = np.std(np.abs(cam_dists)) / cam_median if cam_median > 0 else 999
            consistency = max(0.0, 1.0 - cam_cv)

            if consistency > best_consistency:
                best_consistency = consistency
                best_scale = scale_est

                logger.info(
                    "Camera-height axis %d (%s): scale=%.4f, cam_height=%.4f units, "
                    "consistency=%.2f",
                    axis, "low" if use_low else "high", scale_est, cam_median, consistency,
                )

    if best_scale is None:
        raise ValueError("Could not estimate scale from camera height")

    logger.info("Camera-height scale: %.4f m/unit (consistency=%.2f)",
                best_scale, best_consistency)

    return CalibrationResult(
        scale_factor=best_scale,
        confidence=best_consistency * 0.6,  # Cap at 60% since it's an assumption
        num_cones_used=0,
        per_cone_scales=[best_scale],
        cone_3d_positions=[],
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
            images, points3d, config.assumed_camera_height_m,
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
        ratio = projection_result.scale_factor / camera_result.scale_factor
        if 0.5 < ratio < 2.0:
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
    elif projection_result:
        return projection_result
    elif camera_result:
        return camera_result
    else:
        raise ValueError("All calibration methods failed")
