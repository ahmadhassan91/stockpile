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
    recommended_m3: float
    recommended_method: str
    recommended_note: str | None
    grid_resolution: float
    num_points: int
    grid_occupancy_pct: float
    grid_cells_observed: int
    grid_cells_total: int
    grid_interpolated: bool
    grid_to_hull_ratio: float | None


@dataclass
class GridIntegrationResult:
    volume_m3: float
    occupancy_pct: float
    observed_cells: int
    total_cells: int
    interpolated: bool


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
) -> GridIntegrationResult:
    """2.5D grid integration: project onto XY grid, sum cell_area × max_height.

    Most appropriate for stockpiles which are fundamentally 2.5D surfaces.
    """
    if len(points) < 3:
        return GridIntegrationResult(
            volume_m3=0.0,
            occupancy_pct=0.0,
            observed_cells=0,
            total_cells=0,
            interpolated=False,
        )

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
        return GridIntegrationResult(
            volume_m3=0.0,
            occupancy_pct=0.0,
            observed_cells=0,
            total_cells=0,
            interpolated=False,
        )

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
    observed_cells = int(valid.sum())
    total_cells = int(valid.size)
    occupancy_pct = 100 * observed_cells / total_cells if total_cells else 0.0
    used_interpolation = observed_cells >= 4 and observed_cells < total_cells

    if valid.sum() >= 4:
        from scipy.interpolate import griddata
        from scipy.spatial import ConvexHull

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
        interpolated_grid = griddata(aug_ij, aug_vals, all_ij, method="linear")
        interpolated_grid = interpolated_grid.reshape(height_grid.shape)

        # Step 2: nearest-neighbour for any remaining NaNs outside augmented hull
        still_nan = np.isnan(interpolated_grid)
        if still_nan.any():
            nearest = griddata(aug_ij, aug_vals, all_ij, method="nearest")
            nearest = nearest.reshape(height_grid.shape)
            interpolated_grid[still_nan] = nearest[still_nan]

        height_grid_filled = np.maximum(interpolated_grid, 0)
    else:
        height_grid_filled = np.where(valid, np.maximum(height_grid, 0), 0)

    # Sum volume: cell_area * height
    cell_area = resolution * resolution
    volume = float(np.sum(height_grid_filled) * cell_area)

    logger.info(
        "Grid integration: %.2f m³ (grid %dx%d, %.1f%% cells had data%s)",
        volume,
        height_grid.shape[0],
        height_grid.shape[1],
        occupancy_pct,
        ", interpolated" if used_interpolation else "",
    )

    return GridIntegrationResult(
        volume_m3=max(0.0, volume),
        occupancy_pct=occupancy_pct,
        observed_cells=observed_cells,
        total_cells=total_cells,
        interpolated=used_interpolation,
    )


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
            recommended_method="grid_integration",
            recommended_note=None,
            grid_resolution=config.grid_resolution,
            num_points=0,
            grid_occupancy_pct=0.0,
            grid_cells_observed=0,
            grid_cells_total=0,
            grid_interpolated=False,
            grid_to_hull_ratio=None,
        )

    hull_vol = volume_convex_hull(points)
    alpha_vol = volume_alpha_shape(pile_cloud, config.alpha)
    grid_stats = volume_grid_integration(points, config.grid_resolution)
    grid_vol = grid_stats.volume_m3
    grid_to_hull_ratio = (grid_vol / hull_vol) if hull_vol > 0 else None

    recommended_m3 = grid_vol
    recommended_method = "grid_integration"
    recommended_note = None

    if (
        hull_vol > 0
        and grid_stats.occupancy_pct < config.recommended_min_grid_occupancy_pct
        and grid_vol > hull_vol
    ):
        recommended_m3 = hull_vol
        recommended_method = "convex_hull_fallback"
        recommended_note = (
            "Grid occupancy is too sparse for a stable interpolation; using convex hull as a safer fallback."
        )
    elif (
        hull_vol > 0
        and grid_to_hull_ratio is not None
        and grid_to_hull_ratio > config.recommended_max_grid_to_hull_ratio
    ):
        recommended_m3 = hull_vol
        recommended_method = "convex_hull_fallback"
        recommended_note = (
            "Grid estimate diverged too far from the observed hull; using convex hull as a safer fallback."
        )

    logger.info(
        "Volume estimates — Convex hull: %.2f m³, Alpha shape: %s m³, Grid: %.2f m³, Recommended: %.2f m³ (%s)",
        hull_vol,
        f"{alpha_vol:.2f}" if alpha_vol is not None else "N/A",
        grid_vol,
        recommended_m3,
        recommended_method,
    )

    return VolumeResult(
        convex_hull_m3=hull_vol,
        alpha_shape_m3=alpha_vol,
        grid_integration_m3=grid_vol,
        recommended_m3=recommended_m3,
        recommended_method=recommended_method,
        recommended_note=recommended_note,
        grid_resolution=config.grid_resolution,
        num_points=len(points),
        grid_occupancy_pct=grid_stats.occupancy_pct,
        grid_cells_observed=grid_stats.observed_cells,
        grid_cells_total=grid_stats.total_cells,
        grid_interpolated=grid_stats.interpolated,
        grid_to_hull_ratio=grid_to_hull_ratio,
    )
