"""Volume computation using three methods."""

import logging
from dataclasses import dataclass

import numpy as np
import open3d as o3d
from scipy.spatial import ConvexHull

from .config import VolumeConfig

logger = logging.getLogger(__name__)


@dataclass
class VolumeResult:
    convex_hull_m3: float
    alpha_shape_m3: float | None
    grid_integration_m3: float
    recommended_m3: float  # grid integration
    grid_resolution: float
    num_points: int


def volume_convex_hull(points: np.ndarray) -> float:
    """Compute volume using 3D convex hull."""
    if len(points) < 4:
        return 0.0
    try:
        hull = ConvexHull(points)
        return float(hull.volume)
    except Exception as e:
        logger.warning("Convex hull failed: %s", e)
        return 0.0


def volume_alpha_shape(pcd: o3d.geometry.PointCloud, alpha: float) -> float | None:
    """Compute volume using alpha shape (watertight mesh)."""
    if len(pcd.points) < 4:
        return None
    try:
        mesh = o3d.geometry.TriangleMesh.create_from_point_cloud_alpha_shape(pcd, alpha)
        if not mesh.is_watertight():
            logger.warning("Alpha shape mesh is not watertight, volume may be inaccurate")
        mesh.orient_triangles()
        volume = mesh.get_volume()
        return float(volume) if volume > 0 else None
    except Exception as e:
        logger.warning("Alpha shape failed: %s", e)
        return None


def volume_grid_integration(
    points: np.ndarray,
    resolution: float = 0.05,
) -> float:
    """2.5D grid integration: project onto XY grid, sum cell_area × max_height.

    Most appropriate for stockpiles which are fundamentally 2.5D surfaces.
    """
    if len(points) < 3:
        return 0.0

    x, y, z = points[:, 0], points[:, 1], points[:, 2]

    # Estimate pile height to compute base extension (angle of repose ~37°)
    max_z = float(z.max()) if len(z) > 0 else 0.0
    base_extension_m = max(resolution * 5, max_z * 1.33)  # tan(37°) ≈ 0.75 → base = height / 0.75

    # Extend grid beyond data extent so virtual boundary points fall within it
    x_min, x_max = x.min() - base_extension_m, x.max() + base_extension_m
    y_min, y_max = y.min() - base_extension_m, y.max() + base_extension_m

    x_bins = np.arange(x_min, x_max + resolution, resolution)
    y_bins = np.arange(y_min, y_max + resolution, resolution)

    if len(x_bins) < 2 or len(y_bins) < 2:
        return 0.0

    # Digitize points into grid cells
    x_idx = np.digitize(x, x_bins) - 1
    y_idx = np.digitize(y, y_bins) - 1

    # Clamp to valid range
    x_idx = np.clip(x_idx, 0, len(x_bins) - 2)
    y_idx = np.clip(y_idx, 0, len(y_bins) - 2)

    # For each cell, find max Z (height above ground)
    height_grid = np.full((len(x_bins) - 1, len(y_bins) - 1), np.nan)

    for xi, yi, zi in zip(x_idx, y_idx, z):
        if np.isnan(height_grid[xi, yi]) or zi > height_grid[xi, yi]:
            height_grid[xi, yi] = zi

    # Interpolate missing cells from sparse data
    valid = ~np.isnan(height_grid)
    occupancy_pct = 100 * valid.sum() / valid.size

    if valid.sum() >= 4:
        from scipy.interpolate import griddata
        from scipy.spatial import ConvexHull
        from matplotlib.path import Path as MplPath

        # Get coordinates of known cells
        known_ij = np.argwhere(valid)
        known_vals = height_grid[valid]

        # Expand pile data with virtual zero-height boundary points at the
        # expected base of the pile. A natural aggregate heap has an angle of
        # repose of ~37°, so the base extends (max_height / tan(37°)) meters
        # beyond where we last see pile points. This ensures the grid
        # integration captures the full base, not just the COLMAP-visible top.
        max_height = float(np.max(known_vals)) if len(known_vals) > 0 else 0.0
        base_extension_cells = max(5, int(max_height * 1.33 / resolution))  # tan(37°) ≈ 0.75

        boundary_ij = []
        boundary_vals = []
        try:
            hull = ConvexHull(known_ij.astype(float))
            hull_pts = known_ij[hull.vertices].astype(float)
            centroid = hull_pts.mean(axis=0)
            for pt in hull_pts:
                direction = pt - centroid
                norm = np.linalg.norm(direction)
                if norm < 1e-8:
                    continue
                boundary_pt = pt + direction / norm * base_extension_cells
                boundary_ij.append(boundary_pt)
                boundary_vals.append(0.0)
        except Exception:
            pass

        if boundary_ij:
            aug_ij = np.vstack([known_ij, boundary_ij])
            aug_vals = np.concatenate([known_vals, boundary_vals])
        else:
            aug_ij = known_ij
            aug_vals = known_vals

        # All cell coordinates
        all_i, all_j = np.meshgrid(
            np.arange(height_grid.shape[0]),
            np.arange(height_grid.shape[1]),
            indexing="ij",
        )
        all_ij = np.column_stack([all_i.ravel(), all_j.ravel()])

        # Step 1: linear interpolation using augmented points (tapers to 0 at base)
        interpolated = griddata(aug_ij, aug_vals, all_ij, method="linear")
        interpolated = interpolated.reshape(height_grid.shape)

        # Step 2: nearest-neighbour for any remaining NaNs outside augmented hull
        still_nan = np.isnan(interpolated)
        if still_nan.any():
            nearest = griddata(aug_ij, aug_vals, all_ij, method="nearest")
            nearest = nearest.reshape(height_grid.shape)
            interpolated[still_nan] = nearest[still_nan]

        height_grid_filled = np.maximum(interpolated, 0)
    else:
        height_grid_filled = np.where(valid, np.maximum(height_grid, 0), 0)

    # Sum volume: cell_area * height
    cell_area = resolution * resolution
    volume = float(np.sum(height_grid_filled) * cell_area)

    logger.info(
        "Grid integration: %.2f m³ (grid %dx%d, %.0f%% cells had data, interpolated)",
        volume, height_grid.shape[0], height_grid.shape[1], occupancy_pct,
    )

    return max(0.0, volume)


def compute_volume(
    pile_cloud: o3d.geometry.PointCloud,
    config: VolumeConfig | None = None,
) -> VolumeResult:
    """Compute volume using all three methods."""
    config = config or VolumeConfig()
    points = np.asarray(pile_cloud.points)

    if len(points) == 0:
        return VolumeResult(
            convex_hull_m3=0.0,
            alpha_shape_m3=None,
            grid_integration_m3=0.0,
            recommended_m3=0.0,
            grid_resolution=config.grid_resolution,
            num_points=0,
        )

    hull_vol = volume_convex_hull(points)
    alpha_vol = volume_alpha_shape(pile_cloud, config.alpha)
    grid_vol = volume_grid_integration(points, config.grid_resolution)

    logger.info(
        "Volume estimates — Convex hull: %.2f m³, Alpha shape: %s m³, Grid: %.2f m³",
        hull_vol,
        f"{alpha_vol:.2f}" if alpha_vol is not None else "N/A",
        grid_vol,
    )

    return VolumeResult(
        convex_hull_m3=hull_vol,
        alpha_shape_m3=alpha_vol,
        grid_integration_m3=grid_vol,
        recommended_m3=grid_vol,
        grid_resolution=config.grid_resolution,
        num_points=len(points),
    )
