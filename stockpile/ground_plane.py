"""Ground plane detection and pile point segmentation."""

import logging
from dataclasses import dataclass

import numpy as np
import open3d as o3d

from .config import GroundPlaneConfig

logger = logging.getLogger(__name__)


@dataclass
class GroundPlaneResult:
    plane_equation: np.ndarray
    plane_normal: np.ndarray
    inlier_ratio: float
    pile_cloud: o3d.geometry.PointCloud
    ground_cloud: o3d.geometry.PointCloud
    full_cloud_transformed: o3d.geometry.PointCloud
    transform_matrix: np.ndarray


def load_and_scale_point_cloud(
    points_xyz: np.ndarray,
    points_rgb: np.ndarray | None,
    scale_factor: float,
) -> o3d.geometry.PointCloud:
    """Create an Open3D point cloud, applying the scale factor."""
    pcd = o3d.geometry.PointCloud()
    pcd.points = o3d.utility.Vector3dVector(points_xyz * scale_factor)
    if points_rgb is not None:
        pcd.colors = o3d.utility.Vector3dVector(points_rgb / 255.0)
    return pcd


def remove_outliers(
    pcd: o3d.geometry.PointCloud,
    config: GroundPlaneConfig,
) -> o3d.geometry.PointCloud:
    """Statistical outlier removal."""
    cleaned, _ = pcd.remove_statistical_outlier(
        nb_neighbors=config.statistical_nb_neighbors,
        std_ratio=config.statistical_std_ratio,
    )
    logger.info("Outlier removal: %d → %d points", len(pcd.points), len(cleaned.points))
    return cleaned


def _align_to_dominant_plane(pcd: o3d.geometry.PointCloud, config: GroundPlaneConfig):
    """Align cloud so the dominant plane (likely ground or pile base) is horizontal.

    Returns (transformed_cloud, plane_eq, inliers, transform_matrix).
    """
    o3d.utility.random.seed(config.random_seed)
    plane_model, inliers = pcd.segment_plane(
        distance_threshold=config.ransac_distance_threshold,
        ransac_n=config.ransac_n,
        num_iterations=config.ransac_iterations,
    )
    a, b, c, d = plane_model
    normal = np.array([a, b, c])
    normal = normal / np.linalg.norm(normal)

    # Make normal point "up" — toward the side with fewer points (pile sticks up)
    pts = np.asarray(pcd.points)
    signed_dist = pts @ normal + d / np.linalg.norm([a, b, c])
    above = (signed_dist > 0).sum()
    below = (signed_dist <= 0).sum()
    # The side with MORE points at extreme distances is "up" (pile)
    # Use the 90th percentile distance on each side
    if above > 0 and below > 0:
        above_extent = np.percentile(signed_dist[signed_dist > 0], 90)
        below_extent = np.percentile(-signed_dist[signed_dist <= 0], 90)
        if below_extent > above_extent:
            normal = -normal
            d = -d

    # Rotation to align normal with Z
    z_axis = np.array([0, 0, 1.0])
    v = np.cross(normal, z_axis)
    s = np.linalg.norm(v)
    c_val = np.dot(normal, z_axis)

    if s < 1e-8:
        R = np.eye(3) if c_val > 0 else np.diag([1, -1, -1])
    else:
        vx = np.array([
            [0, -v[2], v[1]],
            [v[2], 0, -v[0]],
            [-v[1], v[0], 0],
        ])
        R = np.eye(3) + vx + vx @ vx * (1 - c_val) / (s * s)

    t = np.array([0, 0, d / np.linalg.norm([a, b, c])])

    T = np.eye(4)
    T[:3, :3] = R
    T[:3, 3] = R @ t

    transformed = o3d.geometry.PointCloud(pcd)
    transformed.transform(T)

    return transformed, np.array(plane_model), inliers, T


def _find_ground_z_ransac(pts: np.ndarray, config: GroundPlaneConfig) -> float:
    """Find the true ground level by fitting a RANSAC plane to the lowest points.

    This is more robust than a simple percentile because a walkaround video
    produces far more points on the pile surface than on flat ground, meaning
    a naive percentile will land on the lower pile flank — not the floor.

    Strategy:
    1. Take the lowest 10% of Z values (most likely to include ground points)
    2. Fit an Open3D RANSAC plane to those points
    3. Use the median Z of inlier points as ground_z

    Falls back to the 2nd percentile if RANSAC fails.
    """
    z = pts[:, 2]
    low_thresh = np.percentile(z, 10)
    low_mask = z <= low_thresh
    low_pts = pts[low_mask]

    if len(low_pts) < 10:
        # not enough points — degenerate fallback
        ground_z = np.percentile(z, 2)
        logger.warning("Too few low points for RANSAC ground fit; using 2nd percentile: %.3f", ground_z)
        return ground_z

    pcd_low = o3d.geometry.PointCloud()
    pcd_low.points = o3d.utility.Vector3dVector(low_pts)

    try:
        o3d.utility.random.seed(config.random_seed)
        plane_model, inliers = pcd_low.segment_plane(
            distance_threshold=config.ransac_distance_threshold,
            ransac_n=3,
            num_iterations=500,
        )
        a, b, c, d = plane_model
        norm = np.sqrt(a * a + b * b + c * c)
        if norm < 1e-8:
            raise ValueError("Degenerate plane normal")

        # Use median Z of the inlier ground points as the ground reference
        inlier_pts = low_pts[inliers]
        ground_z = float(np.median(inlier_pts[:, 2]))
        inlier_ratio = len(inliers) / len(low_pts)
        logger.info(
            "RANSAC ground plane: %.3f m (inlier ratio %.0f%%, plane normal [%.2f,%.2f,%.2f])",
            ground_z, inlier_ratio * 100, a / norm, b / norm, c / norm,
        )
        return ground_z

    except Exception as e:
        ground_z = float(np.percentile(z, 2))
        logger.warning("RANSAC ground plane failed (%s); falling back to 2nd percentile: %.3f", e, ground_z)
        return ground_z


def _cone_footprint_mask(
    pts_xy: np.ndarray,
    cone_positions: list[np.ndarray],
    transform_matrix: np.ndarray,
    margin_m: float,
) -> np.ndarray | None:
    """Return a mask for points inside the transformed cone footprint."""
    if len(cone_positions) < 3:
        return None

    try:
        from matplotlib.path import Path as MplPath
        from scipy.spatial import ConvexHull

        transformed_cones = []
        for cp in cone_positions:
            p = np.append(cp, 1.0)
            transformed_cones.append((transform_matrix @ p)[:2])

        cone_xy = np.array(transformed_cones)
        hull = ConvexHull(cone_xy)
        if hull.volume < 1.0:
            logger.warning(
                "Cone bounding area is too small (%.2f m²). Cones may be placed in a line. "
                "Skipping spatial crop to avoid cutting off the pile.",
                hull.volume,
            )
            return None

        hull_vertices = cone_xy[hull.vertices]
        hull_path = MplPath(hull_vertices)
        inside = hull_path.contains_points(pts_xy, radius=2 * margin_m if margin_m > 0 else 0.0)
        logger.info(
            "Cone footprint crop: keeping %d / %d points within %.2f m margin",
            int(inside.sum()),
            len(inside),
            margin_m,
        )
        return inside
    except Exception as e:
        logger.warning("Could not compute cone boundary hull: %s", e)
        return None


def segment_pile(
    pcd: o3d.geometry.PointCloud,
    config: GroundPlaneConfig,
    cone_positions: list[np.ndarray] | None = None,
) -> GroundPlaneResult:
    """Segment pile points from ground.

    Strategy:
    1. Remove statistical outliers
    2. Align cloud so the dominant plane is horizontal (RANSAC rotation)
    3. Find the true ground level using RANSAC on the lowest-Z cluster
       (NOT a simple percentile, which lands on the pile flank for walkarounds)
    4. Shift so ground = 0; classify pile vs ground points
    5. Optionally crop to cone bounding polygon
    """
    # 1. Remove outliers
    cleaned = remove_outliers(pcd, config)

    # 2. Align to dominant plane
    transformed, plane_eq, inliers, T = _align_to_dominant_plane(cleaned, config)
    inlier_ratio = len(inliers) / len(cleaned.points)
    pts = np.asarray(transformed.points)

    # 3. Find TRUE ground level via RANSAC on lowest-Z cluster
    ground_z = _find_ground_z_ransac(pts, config)
    logger.info("Ground Z level: %.3f (RANSAC on lowest 10%%)", ground_z)

    if cone_positions and len(cone_positions) >= 3:
        cone_zs = []
        for cone_pos in cone_positions:
            cone_h = np.append(np.asarray(cone_pos, dtype=float), 1.0)
            cone_zs.append(float((T @ cone_h)[2]))
        cone_ground_z = float(np.median(cone_zs))
        logger.info(
            "Cone-based ground Z: %.3f m (from %d cones, RANSAC ground Z: %.3f)",
            cone_ground_z, len(cone_zs), ground_z,
        )
        if abs(cone_ground_z - ground_z) > 0.5:
            logger.warning(
                "Cone ground Z (%.3f) and RANSAC ground Z (%.3f) disagree by %.2f m — "
                "preferring cone-based value",
                cone_ground_z, ground_z, abs(cone_ground_z - ground_z),
            )
            ground_z = cone_ground_z

    # Shift so ground = 0
    pts[:, 2] -= ground_z
    transformed.points = o3d.utility.Vector3dVector(pts)

    # Update transform to include the Z shift
    T_shift = np.eye(4)
    T_shift[2, 3] = -ground_z
    T = T_shift @ T

    # 4. Separate ground vs pile
    above_mask = pts[:, 2] > config.above_ground_threshold
    ground_mask = ~above_mask

    logger.info(
        "Segmentation: %d above threshold (%.2fm), %d at/below ground",
        above_mask.sum(), config.above_ground_threshold, ground_mask.sum(),
    )

    # 5. Optional: spatial crop using cone positions
    if cone_positions and len(cone_positions) >= 3:
        inside = _cone_footprint_mask(pts[:, :2], cone_positions, T, config.cone_crop_margin_m)
        if inside is not None:
            above_mask = above_mask & inside
            ground_mask = ground_mask & inside

    pile_cloud = transformed.select_by_index(np.where(above_mask)[0].tolist())
    ground_cloud = transformed.select_by_index(np.where(ground_mask)[0].tolist())

    logger.info(
        "Final: %d pile points, %d ground points, pile height range: %.2f - %.2f m",
        len(pile_cloud.points), len(ground_cloud.points),
        np.asarray(pile_cloud.points)[:, 2].min() if len(pile_cloud.points) > 0 else 0,
        np.asarray(pile_cloud.points)[:, 2].max() if len(pile_cloud.points) > 0 else 0,
    )

    return GroundPlaneResult(
        plane_equation=plane_eq,
        plane_normal=plane_eq[:3] / np.linalg.norm(plane_eq[:3]),
        inlier_ratio=inlier_ratio,
        pile_cloud=pile_cloud,
        ground_cloud=ground_cloud,
        full_cloud_transformed=transformed,
        transform_matrix=T,
    )
