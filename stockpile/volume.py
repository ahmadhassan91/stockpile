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
    footprint_area_m2: float | None
    footprint_source: str | None


@dataclass
class GridIntegrationResult:
    volume_m3: float
    occupancy_pct: float
    observed_cells: int
    total_cells: int
    interpolated: bool
    footprint_area_m2: float | None
    footprint_source: str | None


def _convex_polygon(points_xy: np.ndarray) -> np.ndarray | None:
    """Build a convex polygon from XY samples."""
    if len(points_xy) < 3:
        return None

    unique_xy = np.unique(np.round(points_xy, decimals=6), axis=0)
    if len(unique_xy) < 3:
        return None

    try:
        hull = ConvexHull(unique_xy)
    except Exception:
        return None

    return unique_xy[hull.vertices]


def _expand_polygon_radially(polygon_xy: np.ndarray, margin_m: float) -> np.ndarray:
    """Approximate polygon buffer by moving vertices away from the centroid."""
    if margin_m <= 0:
        return polygon_xy

    centroid = polygon_xy.mean(axis=0)
    directions = polygon_xy - centroid
    norms = np.linalg.norm(directions, axis=1)
    expanded = polygon_xy.copy()

    nonzero = norms > 1e-6
    expanded[nonzero] = centroid + directions[nonzero] * ((norms[nonzero] + margin_m) / norms[nonzero])[:, None]
    return expanded


def _sample_polygon_boundary(polygon_xy: np.ndarray, spacing_m: float) -> np.ndarray:
    """Sample evenly-spaced points along a closed polygon boundary."""
    if len(polygon_xy) < 2:
        return polygon_xy

    spacing_m = max(spacing_m, 1e-3)
    samples = []
    closed = np.vstack([polygon_xy, polygon_xy[0]])
    for start, end in zip(closed[:-1], closed[1:]):
        edge = end - start
        length = np.linalg.norm(edge)
        if length < 1e-8:
            continue
        count = max(2, int(np.ceil(length / spacing_m)))
        for t in np.linspace(0.0, 1.0, count, endpoint=False):
            samples.append(start + edge * t)

    return np.array(samples) if samples else polygon_xy


def _polygon_area(polygon_xy: np.ndarray | None) -> float | None:
    """Compute polygon area from a convex vertex list."""
    if polygon_xy is None or len(polygon_xy) < 3:
        return None
    try:
        return float(ConvexHull(polygon_xy).volume)
    except Exception:
        return None


def _build_footprint_polygon(
    points_xy: np.ndarray,
    footprint_xy: np.ndarray | None,
    buffer_m: float,
    min_cone_area_ratio: float,
) -> tuple[np.ndarray | None, str | None]:
    """Choose a footprint polygon from cones when available, otherwise observed pile points."""
    cone_polygon = None
    cone_area = None
    if footprint_xy is not None and len(footprint_xy) >= 3:
        cone_polygon = _convex_polygon(np.asarray(footprint_xy))
        cone_area = _polygon_area(cone_polygon)

    observed_polygon = _convex_polygon(points_xy)
    observed_area = _polygon_area(observed_polygon)

    if cone_polygon is not None and observed_polygon is not None and cone_area and observed_area:
        if cone_area >= observed_area * min_cone_area_ratio:
            return _expand_polygon_radially(cone_polygon, buffer_m), "cone_hull"
        logger.info(
            "Cone footprint area %.2f m² is smaller than %.0f%% of observed hull area %.2f m²; "
            "using observed hull footprint instead.",
            cone_area,
            min_cone_area_ratio * 100,
            observed_area,
        )
        return _expand_polygon_radially(observed_polygon, buffer_m), "observed_hull_fallback"

    if cone_polygon is not None:
        return _expand_polygon_radially(cone_polygon, buffer_m), "cone_hull"

    if observed_polygon is not None:
        return _expand_polygon_radially(observed_polygon, buffer_m), "observed_hull"

    return None, None


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
    footprint_xy: np.ndarray | None = None,
    footprint_buffer_m: float = 0.75,
    min_cone_footprint_area_ratio: float = 0.7,
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
            footprint_area_m2=None,
            footprint_source=None,
        )

    x, y, z = points[:, 0], points[:, 1], points[:, 2]
    points_xy = np.column_stack([x, y])
    footprint_polygon, footprint_source = _build_footprint_polygon(
        points_xy,
        footprint_xy,
        footprint_buffer_m,
        min_cone_footprint_area_ratio,
    )

    if footprint_polygon is not None:
        x_min, y_min = footprint_polygon.min(axis=0)
        x_max, y_max = footprint_polygon.max(axis=0)
    else:
        x_min, x_max = x.min(), x.max()
        y_min, y_max = y.min(), y.max()

    x_bins = np.arange(x_min, x_max + resolution, resolution)
    y_bins = np.arange(y_min, y_max + resolution, resolution)

    if len(x_bins) < 2 or len(y_bins) < 2:
        return GridIntegrationResult(
            volume_m3=0.0,
            occupancy_pct=0.0,
            observed_cells=0,
            total_cells=0,
            interpolated=False,
            footprint_area_m2=None,
            footprint_source=footprint_source,
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

    if footprint_polygon is not None:
        from matplotlib.path import Path as MplPath

        x_centers = 0.5 * (x_bins[:-1] + x_bins[1:])
        y_centers = 0.5 * (y_bins[:-1] + y_bins[1:])
        cx, cy = np.meshgrid(x_centers, y_centers, indexing="ij")
        cell_centers = np.column_stack([cx.ravel(), cy.ravel()])
        footprint_path = MplPath(footprint_polygon)
        inside_footprint = footprint_path.contains_points(cell_centers, radius=resolution)
        inside_footprint = inside_footprint.reshape(height_grid.shape)
        footprint_area_m2 = float(ConvexHull(footprint_polygon).volume)
    else:
        x_centers = 0.5 * (x_bins[:-1] + x_bins[1:])
        y_centers = 0.5 * (y_bins[:-1] + y_bins[1:])
        cx, cy = np.meshgrid(x_centers, y_centers, indexing="ij")
        inside_footprint = np.ones(height_grid.shape, dtype=bool)
        footprint_area_m2 = None

    # Interpolate missing cells from sparse data
    valid = (~np.isnan(height_grid)) & inside_footprint
    observed_cells = int(valid.sum())
    total_cells = int(inside_footprint.sum())
    occupancy_pct = 100 * observed_cells / total_cells if total_cells else 0.0
    used_interpolation = observed_cells >= 4 and observed_cells < total_cells

    if valid.sum() >= 4:
        from scipy.interpolate import griddata

        # Get coordinates of known cells
        known_ij = np.argwhere(valid)
        known_vals = height_grid[valid]
        known_xy = np.column_stack([cx[valid], cy[valid]])

        boundary_xy = None
        if footprint_polygon is not None:
            boundary_xy = _sample_polygon_boundary(
                footprint_polygon,
                spacing_m=max(resolution * 2.0, footprint_buffer_m / 2 if footprint_buffer_m > 0 else resolution),
            )

        if boundary_xy is not None and len(boundary_xy) > 0:
            aug_xy = np.vstack([known_xy, boundary_xy])
            aug_vals = np.concatenate([known_vals, np.zeros(len(boundary_xy))])
        else:
            aug_xy = known_xy
            aug_vals = known_vals

        query_xy = np.column_stack([cx[inside_footprint], cy[inside_footprint]])
        try:
            interpolated_vals = griddata(aug_xy, aug_vals, query_xy, method="linear")
            if np.isnan(interpolated_vals).any():
                nearest_vals = griddata(aug_xy, aug_vals, query_xy, method="nearest")
                interpolated_vals[np.isnan(interpolated_vals)] = nearest_vals[np.isnan(interpolated_vals)]

            height_grid_filled = np.zeros_like(height_grid)
            height_grid_filled[inside_footprint] = np.maximum(interpolated_vals, 0)
            height_grid_filled[valid] = np.maximum(height_grid_filled[valid], np.maximum(height_grid[valid], 0))
        except Exception as e:
            logger.warning("Footprint-bounded interpolation failed: %s", e)
            height_grid_filled = np.zeros_like(height_grid)
            height_grid_filled[valid] = np.maximum(height_grid[valid], 0)
    else:
        height_grid_filled = np.zeros_like(height_grid)
        height_grid_filled[valid] = np.maximum(height_grid[valid], 0)

    # Sum volume: cell_area * height
    cell_area = resolution * resolution
    volume = float(np.sum(height_grid_filled[inside_footprint]) * cell_area)

    logger.info(
        "Grid integration: %.2f m³ (grid %dx%d, %.1f%% footprint cells had data%s, footprint=%s)",
        volume,
        height_grid.shape[0],
        height_grid.shape[1],
        occupancy_pct,
        ", interpolated" if used_interpolation else "",
        footprint_source or "bounding_box",
    )

    return GridIntegrationResult(
        volume_m3=max(0.0, volume),
        occupancy_pct=occupancy_pct,
        observed_cells=observed_cells,
        total_cells=total_cells,
        interpolated=used_interpolation,
        footprint_area_m2=footprint_area_m2,
        footprint_source=footprint_source,
    )


def compute_volume(
    pile_cloud: o3d.geometry.PointCloud,
    config: VolumeConfig | None = None,
    footprint_points: list[np.ndarray] | np.ndarray | None = None,
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
            footprint_area_m2=None,
            footprint_source=None,
        )

    hull_vol = volume_convex_hull(points)
    alpha_vol = volume_alpha_shape(pile_cloud, config.alpha)
    footprint_xy = None
    if footprint_points is not None:
        footprint_arr = np.asarray(footprint_points)
        if footprint_arr.ndim == 2 and footprint_arr.shape[0] >= 3:
            footprint_xy = footprint_arr[:, :2]
    grid_stats = volume_grid_integration(
        points,
        config.grid_resolution,
        footprint_xy=footprint_xy,
        footprint_buffer_m=config.footprint_buffer_m,
        min_cone_footprint_area_ratio=config.min_cone_footprint_area_ratio,
    )
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
        footprint_area_m2=grid_stats.footprint_area_m2,
        footprint_source=grid_stats.footprint_source,
    )
