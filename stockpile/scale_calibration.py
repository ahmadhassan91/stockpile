"""Scale calibration: compute real-world scale from cone detections + COLMAP data."""

import logging
import re
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import open3d as o3d
from sklearn.cluster import DBSCAN

from .colmap_runner import ColmapCamera, ColmapImage, ColmapPoint3D
from .cone_detection import ConeDetection
from .config import ScaleCalibrationConfig

logger = logging.getLogger(__name__)


def _frame_index(name: str) -> int | None:
    """Extract numeric frame index from a filename like frame_00123.jpg."""
    m = re.search(r"(\d+)", Path(name).stem)
    return int(m.group(1)) if m else None


@dataclass
class CalibrationResult:
    scale_factor: float  # meters per COLMAP unit
    confidence: float  # 0-1
    num_cones_used: int
    per_cone_scales: list[float]
    cone_3d_positions: list[np.ndarray]
    detected_cone_frames: int = 0
    registered_cone_frames: int = 0
    total_cone_detections: int = 0
    max_detections_in_frame: int = 0
    frames_with_multiple_detections: int = 0
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


def _select_projection_scale_value(
    scales: np.ndarray,
    pixel_heights: np.ndarray,
    config: ScaleCalibrationConfig,
) -> tuple[float, str]:
    """Pick a robust projection scale while compensating for far-cone bias.

    Small distant detections tend to inflate scale. When we see a strong
    negative correlation between pixel height and per-frame scale, bias
    toward closer/larger detections with a capped height-weighted average.
    """
    median_scale = float(np.median(scales))
    if len(scales) < 6:
        return median_scale, "median"

    height_std = float(np.std(pixel_heights))
    scale_std = float(np.std(scales))
    if height_std < 1e-6 or scale_std < 1e-6:
        return median_scale, "median"

    corr = float(np.corrcoef(pixel_heights, scales)[0, 1])
    if not np.isfinite(corr) or corr > config.projection_height_bias_corr_threshold:
        return median_scale, "median"

    median_height = float(np.median(pixel_heights))
    if median_height < 1e-6:
        return median_scale, "median"

    weights = np.clip(
        pixel_heights / median_height,
        0.5,
        max(0.5, config.projection_height_weight_cap),
    )
    weighted_scale = float(np.average(scales, weights=weights))
    if not np.isfinite(weighted_scale):
        return median_scale, "median"
    return weighted_scale, "height_weighted"


def _select_cone_position_points(
    matched_positions: list[np.ndarray],
    matched_distances: list[float],
    percentile: float,
    min_points: int,
) -> np.ndarray:
    """Prefer the nearest matched 3D points when estimating a cone centroid."""
    points = np.asarray(matched_positions, dtype=float)
    distances = np.asarray(matched_distances, dtype=float)
    if len(points) == 0:
        return points

    cutoff = float(np.percentile(distances, percentile))
    subset = points[distances <= cutoff]
    if len(subset) >= min_points:
        return subset

    keep = min(len(points), max(min_points, int(np.ceil(len(points) * percentile / 100.0))))
    nearest_indices = np.argsort(distances)[:keep]
    return points[nearest_indices]


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

    When a cone frame is not directly registered in COLMAP, we fall back to
    the nearest registered frame (by frame index) and use its camera pose
    and keypoints instead (Fix C: frame interpolation).
    """
    name_to_image = {img.name: img for img in images.values()}

    # Build frame-index → COLMAP image lookup for nearest-neighbor fallback
    _idx_to_colmap: dict[int, ColmapImage] = {}
    for img in images.values():
        idx = _frame_index(img.name)
        if idx is not None:
            _idx_to_colmap[idx] = img
    _sorted_registered_indices = sorted(_idx_to_colmap.keys()) if _idx_to_colmap else []

    def _resolve_colmap_image(frame_name: str) -> ColmapImage | None:
        """Return the COLMAP image for frame_name, falling back to the nearest
        registered frame when the exact name is not in the reconstruction."""
        direct = name_to_image.get(frame_name)
        if direct is not None:
            return direct
        if not _sorted_registered_indices:
            return None
        idx = _frame_index(frame_name)
        if idx is None:
            return None
        # Binary search for the closest registered frame index
        import bisect
        pos = bisect.bisect_left(_sorted_registered_indices, idx)
        candidates = []
        if pos < len(_sorted_registered_indices):
            candidates.append(_sorted_registered_indices[pos])
        if pos > 0:
            candidates.append(_sorted_registered_indices[pos - 1])
        best = min(candidates, key=lambda c: abs(c - idx))
        # Only use the neighbor if it's within 5 frames (to limit pose drift)
        if abs(best - idx) > 5:
            return None
        return _idx_to_colmap[best]

    per_frame_scales = []
    per_frame_pixel_heights = []
    cone_positions = []
    notes: list[str] = []
    fallback_count = 0

    for frame_name, detections in cone_detections.items():
        colmap_img = _resolve_colmap_image(frame_name)
        if colmap_img is None:
            continue
        is_fallback = (colmap_img.name != frame_name)
        if is_fallback:
            fallback_count += 1

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

            # Reject background points that land inside the cone bbox but sit
            # materially deeper than the cone itself in COLMAP space.
            dists_arr = np.asarray(matched_distances, dtype=float)
            med_dist = float(np.median(dists_arr))
            depth_mask = dists_arr <= 2.0 * med_dist
            if depth_mask.sum() < 1:
                continue
            matched_distances = list(dists_arr[depth_mask])
            matched_positions = [p for p, keep in zip(matched_positions, depth_mask) if keep]

            # Use the CLOSEST keypoints — they're most likely on the cone
            # surface, not background objects that happen to project inside
            # the bounding box. Use 25th percentile for robustness.
            close_dist = np.percentile(matched_distances, 25)

            if close_dist > config.max_projection_distance:
                continue

            # Projection: pixel_height / focal = real_height / distance
            # real_height (in COLMAP units) = pixel_height * distance / focal
            # scale = known_height_m / real_height_colmap
            real_height_colmap = pixel_height * close_dist / focal
            scale = config.known_cone_height_m / real_height_colmap

            cone_points = _select_cone_position_points(
                matched_positions,
                matched_distances,
                percentile=config.cone_position_percentile,
                min_points=config.cone_position_min_points,
            )

            if scale < config.min_plausible_scale or scale > config.max_plausible_scale:
                continue

            per_frame_scales.append(scale)
            per_frame_pixel_heights.append(float(pixel_height))
            # Store a trimmed 3D position estimate as the cone location.
            cone_positions.append(np.median(cone_points, axis=0))

    if not per_frame_scales:
        raise ValueError("No cone-camera projection matches found for calibration")

    if fallback_count > 0:
        notes.append(
            f"Used nearest-neighbor COLMAP frames for {fallback_count} "
            f"cone detections whose exact frames were not in the reconstruction."
        )
        logger.info(
            "Frame interpolation: %d cone frames matched via nearest registered neighbor",
            fallback_count,
        )

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
    filtered_pixel_heights = np.asarray(per_frame_pixel_heights, dtype=float)[inlier_mask]
    filtered_positions = raw_positions[inlier_mask] if len(raw_positions) else raw_positions

    scale_factor, scale_method = _select_projection_scale_value(
        filtered_scales,
        filtered_pixel_heights,
        config,
    )
    if scale_method == "height_weighted":
        notes.append(
            "Projection scale was height-weighted because smaller distant cone detections were inflating the median scale."
        )
        logger.info(
            "Projection scale adjusted from median %.4f to height-weighted %.4f to reduce far-cone bias",
            float(np.median(filtered_scales)),
            scale_factor,
        )

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
    # Also gather positions from a RELAXED pixel-height threshold (half the
    # strict minimum) — these extra positions don't contribute to scale but
    # help count distinct cones for multi-reference cross-checking.
    relaxed_min_px = max(40, config.min_cone_pixel_height // 2)
    relaxed_extra_positions: list[np.ndarray] = []
    if relaxed_min_px < config.min_cone_pixel_height:
        for frame_name, detections in cone_detections.items():
            colmap_img = _resolve_colmap_image(frame_name)
            if colmap_img is None:
                continue
            camera = cameras.get(colmap_img.camera_id)
            if camera is None:
                continue
            cam_center = _camera_center(colmap_img)
            for det in detections:
                x, y, w, h = det.bbox
                if h >= config.min_cone_pixel_height or h < relaxed_min_px:
                    continue  # already counted, or too small even for relaxed
                margin = 5
                x1, y1 = x - margin, y - margin
                x2, y2 = x + w + margin, y + h + margin
                mpos = []
                mdist = []
                for idx2 in range(len(colmap_img.xys)):
                    kx, ky = colmap_img.xys[idx2]
                    p3d_id = int(colmap_img.point3d_ids[idx2])
                    if p3d_id < 0 or p3d_id not in points3d:
                        continue
                    if not (x1 <= kx <= x2 and y1 <= ky <= y2):
                        continue
                    pt3d = points3d[p3d_id].xyz
                    d = np.linalg.norm(pt3d - cam_center)
                    mpos.append(pt3d)
                    mdist.append(d)
                if mpos:
                    relaxed_extra_positions.append(np.median(np.asarray(mpos), axis=0))

    all_positions_for_dedup = list(filtered_positions) + relaxed_extra_positions
    unique_positions = _deduplicate_positions(
        all_positions_for_dedup,
        threshold=config.dbscan_eps,
        min_samples=config.dbscan_min_samples,
    )
    if relaxed_extra_positions:
        logger.info(
            "Relaxed cone pass added %d extra position samples for deduplication",
            len(relaxed_extra_positions),
        )
    if len(filtered_positions) >= config.min_cones_for_confidence and len(unique_positions) < 2:
        notes.append(
            "Many cone detections collapsed into a single 3D reference, which usually means only one cone "
            "triangulated cleanly enough for scale calibration."
        )

    if len(unique_positions) >= 2:
        dists_m = []
        for i in range(len(unique_positions)):
            for j in range(i + 1, len(unique_positions)):
                d = float(np.linalg.norm(
                    np.asarray(unique_positions[i]) - np.asarray(unique_positions[j])
                )) * scale_factor
                dists_m.append(d)
        med_spacing = float(np.median(dists_m))
        notes.append(f"Inter-cone spacing (median): {med_spacing:.1f} m")
        if med_spacing < 1.0 or med_spacing > 200.0:
            notes.append(
                f"WARNING: median inter-cone distance {med_spacing:.1f} m "
                "is outside the plausible 1-200 m range."
            )
            confidence *= 0.5

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
    min_samples: int,
) -> list[np.ndarray]:
    """Merge nearby 3D positions into unique cone locations using DBSCAN.

    DBSCAN is deterministic and order-invariant, unlike the previous greedy
    single-linkage approach which produced different results depending on the
    order cone detections arrived from frame processing.
    """
    if not positions:
        return []

    pts = np.asarray(positions, dtype=float)
    if len(pts) == 1:
        # Single point always returned regardless of min_samples
        return [pts[0]]

    labels = DBSCAN(eps=threshold, min_samples=min_samples, metric="euclidean").fit_predict(pts)

    clusters: list[np.ndarray] = []
    unique_labels = set(labels)
    unique_labels.discard(-1)  # noise points

    for label in sorted(unique_labels):
        member_mask = labels == label
        clusters.append(pts[member_mask].mean(axis=0))

    if clusters:
        return clusters

    # All points were noise (too sparse) — fall back to the global centroid so
    # at least one reference is available for scale calibration.
    logger.debug(
        "DBSCAN found no clusters in %d positions (eps=%.3f, min_samples=%d); "
        "falling back to global centroid",
        len(pts), threshold, min_samples,
    )
    return [pts.mean(axis=0)]


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
        ratio = max(
            projection_result.scale_factor / camera_result.scale_factor,
            camera_result.scale_factor / projection_result.scale_factor,
        )

        if camera_result.confidence < config.min_camera_height_confidence_for_crosscheck:
            # Camera-height plane fit was not stable — don't let its ratio penalise
            # the quality gates.  scale_disagreement_ratio stays None so downstream
            # warnings and review-grade checks are unaffected by a noisy cross-check.
            projection_result.notes.append(
                "Camera-height cross-check was ignored because the fitted ground plane was not stable enough "
                f"(confidence {camera_result.confidence:.2f} < {config.min_camera_height_confidence_for_crosscheck:.2f})."
            )
            logger.info(
                "Using projection scale %.4f without camera-height cross-check "
                "(camera-height confidence %.2f < threshold %.2f, raw ratio %.2f — ratio NOT stored)",
                projection_result.scale_factor,
                camera_result.confidence,
                config.min_camera_height_confidence_for_crosscheck,
                ratio,
            )
            return projection_result

        # Camera-height is stable enough — record ratio so quality gates can act on it.
        projection_result.scale_disagreement_ratio = ratio
        projection_result.notes.append(
            "Projection and camera-height scale checks disagree"
            if ratio >= config.max_method_disagreement_ratio
            else "Projection and camera-height scale checks are broadly aligned"
        )
        if ratio < config.max_method_disagreement_ratio:
            # Methods broadly agree — blend with confidence-weighted average
            # when projection confidence is modest (< 0.7) and camera-height
            # confidence is non-trivial (>= 0.20).
            p_conf = projection_result.confidence
            c_conf = camera_result.confidence
            if p_conf < 0.70 and c_conf >= config.min_camera_height_confidence_for_crosscheck:
                total = p_conf + c_conf
                w_proj = p_conf / total
                w_cam = c_conf / total
                blended = w_proj * projection_result.scale_factor + w_cam * camera_result.scale_factor
                projection_result.notes.append(
                    f"Blended scale: {blended:.4f} (projection {w_proj:.0%} × {projection_result.scale_factor:.4f} "
                    f"+ camera-height {w_cam:.0%} × {camera_result.scale_factor:.4f})"
                )
                logger.info(
                    "Blending projection (%.4f, conf=%.2f) with camera-height (%.4f, conf=%.2f) → %.4f",
                    projection_result.scale_factor, p_conf,
                    camera_result.scale_factor, c_conf,
                    blended,
                )
                projection_result.scale_factor = blended
                projection_result.confidence = min(1.0, p_conf + 0.1 * c_conf)
            else:
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
