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


def segment_pile(
    pcd: o3d.geometry.PointCloud,
    config: GroundPlaneConfig,
    cone_positions: list[np.ndarray] | None = None,
) -> GroundPlaneResult:
    """Segment pile points from ground.

    Strategy: align cloud using dominant plane, then use the lowest Z values
    as the ground reference. This works for stockpile walkarounds where
    most COLMAP points are on the pile surface.
    """
    # 1. Remove outliers
    cleaned = remove_outliers(pcd, config)

    # 2. Align to dominant plane
    transformed, plane_eq, inliers, T = _align_to_dominant_plane(cleaned, config)
    inlier_ratio = len(inliers) / len(cleaned.points)
    pts = np.asarray(transformed.points)

    # 3. Set ground level from the lowest points
    # Use 5th percentile as ground reference (robust to noise)
    ground_z = np.percentile(pts[:, 2], 5)
    logger.info("Ground Z level: %.3f (5th percentile)", ground_z)

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
        try:
            from scipy.spatial import ConvexHull
            from matplotlib.path import Path as MplPath

            cone_pos_transformed = []
            for cp in cone_positions:
                p = np.append(cp, 1.0)
                p_t = T @ p
                cone_pos_transformed.append(p_t[:2])

            cone_xy = np.array(cone_pos_transformed)
            hull = ConvexHull(cone_xy)
            hull_vertices = cone_xy[hull.vertices]
            hull_path = MplPath(hull_vertices)
            inside = hull_path.contains_points(pts[:, :2])
            above_mask = above_mask & inside
        except Exception as e:
            logger.warning("Could not compute cone boundary hull: %s", e)

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
