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
    toe_candidate_points: int = 0
    toe_height_upper_m: float | None = None


@dataclass
class GridIntegrationResult:
    volume_m3: float
    occupancy_pct: float
    observed_cells: int
    total_cells: int
    interpolated: bool
    footprint_area_m2: float | None
    footprint_source: str | None
    toe_candidate_points: int = 0
    toe_height_upper_m: float | None = None


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


def _scale_polygon_about_centroid(polygon_xy: np.ndarray, scale_factor: float) -> np.ndarray:
    """Scale a polygon around its centroid to hit a target area more predictably."""
    if scale_factor <= 1.0:
        return polygon_xy
    centroid = polygon_xy.mean(axis=0)
    return centroid + (polygon_xy - centroid) * scale_factor


def _smooth_nan_profile(values: np.ndarray, passes: int = 1) -> np.ndarray:
    """Apply a small moving average while ignoring NaNs."""
    smoothed = values.astype(float).copy()
    for _ in range(max(1, passes)):
        updated = smoothed.copy()
        for idx, value in enumerate(smoothed):
            if np.isnan(value):
                continue
            window = smoothed[max(0, idx - 1): min(len(smoothed), idx + 2)]
            valid = window[~np.isnan(window)]
            if len(valid) >= 2:
                updated[idx] = float(np.mean(valid))
        smoothed = updated
    return smoothed


def _radial_blended_polygon(
    points_xy: np.ndarray,
    center_xy: np.ndarray,
    sector_count: int,
    inner_percentile: float,
    outer_percentile: float,
    blend_factor: float,
    min_sector_coverage: float,
) -> np.ndarray | None:
    """Build a middle-ground star-shaped footprint from radial toe bands."""
    if len(points_xy) < max(12, sector_count // 3):
        return None

    unique_xy = np.unique(np.round(points_xy, decimals=6), axis=0)
    if len(unique_xy) < max(12, sector_count // 3):
        return None

    rel = unique_xy - center_xy
    radii = np.linalg.norm(rel, axis=1)
    valid = radii > 1e-6
    if np.count_nonzero(valid) < max(12, sector_count // 3):
        return None

    rel = rel[valid]
    radii = radii[valid]
    angles = (np.arctan2(rel[:, 1], rel[:, 0]) + 2 * np.pi) % (2 * np.pi)
    sector_edges = np.linspace(0.0, 2 * np.pi, sector_count + 1)

    vertices: list[np.ndarray] = []
    populated = 0
    for sector_idx in range(sector_count):
        start = sector_edges[sector_idx]
        end = sector_edges[sector_idx + 1]
        if sector_idx == sector_count - 1:
            mask = (angles >= start) & (angles <= end)
        else:
            mask = (angles >= start) & (angles < end)
        if not np.any(mask):
            continue

        populated += 1
        sector_theta = 0.5 * (start + end)
        inner_radius = float(np.percentile(radii[mask], inner_percentile))
        outer_radius = float(np.percentile(radii[mask], outer_percentile))
        sector_radius = inner_radius + max(0.0, min(1.0, blend_factor)) * max(0.0, outer_radius - inner_radius)
        vertices.append(
            center_xy
            + np.array([np.cos(sector_theta), np.sin(sector_theta)]) * sector_radius
        )

    if populated / sector_count < min_sector_coverage or len(vertices) < 8:
        return None
    return np.asarray(vertices)


def _radial_slope_break_polygon(
    points_xyz: np.ndarray,
    center_xy: np.ndarray,
    sector_count: int,
    bin_count: int,
    surface_percentile: float,
    height_threshold_m: float,
    consecutive_bins: int,
    min_sector_coverage: float,
) -> np.ndarray | None:
    """Estimate the toe from the radial ground-to-pile transition in the full scene."""
    if len(points_xyz) < max(64, sector_count * 4):
        return None

    points_xy = points_xyz[:, :2]
    z = points_xyz[:, 2]
    rel = points_xy - center_xy
    radii = np.linalg.norm(rel, axis=1)
    valid = radii > 1e-6
    if np.count_nonzero(valid) < max(64, sector_count * 4):
        return None

    rel = rel[valid]
    radii = radii[valid]
    z = z[valid]
    angles = (np.arctan2(rel[:, 1], rel[:, 0]) + 2 * np.pi) % (2 * np.pi)
    sector_edges = np.linspace(0.0, 2 * np.pi, sector_count + 1)

    vertices: list[np.ndarray] = []
    populated = 0
    for sector_idx in range(sector_count):
        start = sector_edges[sector_idx]
        end = sector_edges[sector_idx + 1]
        if sector_idx == sector_count - 1:
            mask = (angles >= start) & (angles <= end)
        else:
            mask = (angles >= start) & (angles < end)
        if int(np.count_nonzero(mask)) < max(12, bin_count):
            continue

        sector_radii = radii[mask]
        sector_z = z[mask]
        max_radius = float(np.percentile(sector_radii, 99))
        if max_radius <= 1e-6:
            continue

        bin_edges = np.linspace(0.0, max_radius, bin_count + 1)
        bin_idx = np.digitize(sector_radii, bin_edges) - 1
        bin_idx = np.clip(bin_idx, 0, bin_count - 1)

        profile = np.full(bin_count, np.nan)
        for idx in range(bin_count):
            bin_mask = bin_idx == idx
            if int(np.count_nonzero(bin_mask)) < 4:
                continue
            profile[idx] = float(np.percentile(sector_z[bin_mask], surface_percentile))

        profile = _smooth_nan_profile(profile, passes=2)
        if np.count_nonzero(~np.isnan(profile)) < max(6, bin_count // 3):
            continue

        ground_seen = 0
        high_run = 0
        first_high_idx = None
        toe_radius = None
        for idx in range(bin_count - 1, -1, -1):
            height = profile[idx]
            if np.isnan(height):
                continue
            if height <= height_threshold_m:
                ground_seen += 1
                high_run = 0
                first_high_idx = None
                continue
            if ground_seen <= 0:
                continue
            if first_high_idx is None:
                first_high_idx = idx
            high_run += 1
            if high_run >= max(1, consecutive_bins):
                toe_radius = float(bin_edges[first_high_idx + 1])
                break

        if toe_radius is None:
            continue

        populated += 1
        sector_theta = 0.5 * (start + end)
        vertices.append(
            center_xy
            + np.array([np.cos(sector_theta), np.sin(sector_theta)]) * toe_radius
        )

    if populated / sector_count < min_sector_coverage or len(vertices) < 8:
        return None
    return np.asarray(vertices)


def _polygon_area(polygon_xy: np.ndarray | None) -> float | None:
    """Compute polygon area from a convex vertex list."""
    if polygon_xy is None or len(polygon_xy) < 3:
        return None
    try:
        return float(ConvexHull(polygon_xy).volume)
    except Exception:
        return None


def _build_footprint_polygon(
    points_xyz: np.ndarray,
    footprint_xy: np.ndarray | None,
    full_scene_points_xyz: np.ndarray | None,
    buffer_m: float,
    toe_buffer_m: float,
    toe_height_fraction: float,
    toe_max_height_m: float,
    toe_min_points: int,
    toe_sector_count: int,
    toe_radius_percentile: float,
    toe_outer_percentile: float,
    toe_blend_factor: float,
    toe_min_sector_coverage: float,
    toe_slope_break_bins: int,
    toe_slope_break_surface_percentile: float,
    toe_slope_break_height_m: float,
    toe_slope_break_consecutive_bins: int,
    min_toe_contour_area_ratio: float,
    min_toe_area_ratio: float,
    min_cone_area_ratio: float,
) -> tuple[np.ndarray | None, str | None, int, float | None]:
    """Choose a footprint polygon from cones when available, otherwise observed pile points."""
    points_xy = points_xyz[:, :2]

    toe_polygon = None
    toe_source = None
    toe_area = None
    toe_candidate_points = 0
    toe_height_upper = None
    z = points_xyz[:, 2]
    observed_polygon = _convex_polygon(points_xy)
    observed_area = _polygon_area(observed_polygon)
    footprint_center = observed_polygon.mean(axis=0) if observed_polygon is not None else points_xy.mean(axis=0)

    if len(points_xyz) >= toe_min_points:
        pile_height_p95 = float(np.percentile(z, 95))
        toe_height_upper = max(
            0.12,
            min(toe_max_height_m, pile_height_p95 * toe_height_fraction),
        )
        slope_polygon = None
        slope_area = None
        if full_scene_points_xyz is not None and len(full_scene_points_xyz) >= toe_min_points:
            slope_polygon = _radial_slope_break_polygon(
                full_scene_points_xyz,
                center_xy=footprint_center,
                sector_count=toe_sector_count,
                bin_count=toe_slope_break_bins,
                surface_percentile=toe_slope_break_surface_percentile,
                height_threshold_m=min(toe_height_upper, toe_slope_break_height_m),
                consecutive_bins=toe_slope_break_consecutive_bins,
                min_sector_coverage=toe_min_sector_coverage,
            )
            slope_area = _polygon_area(slope_polygon)

        toe_mask = z <= toe_height_upper
        toe_candidate_points = int(np.count_nonzero(toe_mask))
        if toe_candidate_points >= toe_min_points:
            toe_points_xy = points_xy[toe_mask]
            toe_contour_polygon = _radial_blended_polygon(
                toe_points_xy,
                center_xy=footprint_center,
                sector_count=toe_sector_count,
                inner_percentile=toe_radius_percentile,
                outer_percentile=toe_outer_percentile,
                blend_factor=toe_blend_factor,
                min_sector_coverage=toe_min_sector_coverage,
            )
            toe_hull_polygon = _convex_polygon(toe_points_xy)
            toe_hull_area = _polygon_area(toe_hull_polygon)
            toe_contour_area = _polygon_area(toe_contour_polygon)

            if (
                slope_polygon is not None
                and slope_area is not None
                and toe_hull_area is not None
            ):
                target_area = max(slope_area, toe_hull_area * min_toe_contour_area_ratio)
                scale_factor = np.sqrt(target_area / max(slope_area, 1e-6))
                toe_polygon = _scale_polygon_about_centroid(slope_polygon, scale_factor)
                toe_source = "toe_slope_break_guarded" if target_area > slope_area + 1e-6 else "toe_slope_break"
                toe_area = _polygon_area(toe_polygon)
            elif (
                toe_contour_polygon is not None
                and toe_contour_area is not None
                and toe_hull_polygon is not None
                and toe_hull_area is not None
            ):
                min_target_area = toe_hull_area * min_toe_contour_area_ratio
                blended_target_area = toe_contour_area + max(0.0, min(1.0, toe_blend_factor)) * max(
                    0.0, toe_hull_area - toe_contour_area
                )
                target_area = max(min_target_area, blended_target_area)
                scale_factor = np.sqrt(target_area / max(toe_hull_area, 1e-6))
                toe_polygon = _scale_polygon_about_centroid(toe_hull_polygon, scale_factor)
                toe_source = "toe_hybrid_guarded" if target_area <= min_target_area + 1e-6 else "toe_hybrid"
                toe_area = _polygon_area(toe_polygon)
            elif toe_contour_polygon is not None:
                toe_polygon = toe_contour_polygon
                toe_source = "toe_contour_only"
                toe_area = toe_contour_area
            else:
                toe_polygon = toe_hull_polygon
                toe_source = "toe_hull" if toe_polygon is not None else None
                toe_area = toe_hull_area

    cone_polygon = None
    cone_area = None
    if footprint_xy is not None and len(footprint_xy) >= 3:
        cone_polygon = _convex_polygon(np.asarray(footprint_xy))
        cone_area = _polygon_area(cone_polygon)

    if toe_polygon is not None and observed_polygon is not None and toe_area and observed_area:
        if toe_area >= observed_area * min_toe_area_ratio:
            return _expand_polygon_radially(toe_polygon, toe_buffer_m), toe_source or "toe_hull", toe_candidate_points, toe_height_upper
        logger.info(
            "Toe footprint area %.2f m² (%s) is smaller than %.0f%% of observed hull area %.2f m²; "
            "using a broader footprint instead.",
            toe_area,
            toe_source or "toe_hull",
            min_toe_area_ratio * 100,
            observed_area,
        )

    if cone_polygon is not None and observed_polygon is not None and cone_area and observed_area:
        if cone_area >= observed_area * min_cone_area_ratio:
            return _expand_polygon_radially(cone_polygon, buffer_m), "cone_hull", toe_candidate_points, toe_height_upper
        logger.info(
            "Cone footprint area %.2f m² is smaller than %.0f%% of observed hull area %.2f m²; "
            "using observed hull footprint instead.",
            cone_area,
            min_cone_area_ratio * 100,
            observed_area,
        )
        return _expand_polygon_radially(observed_polygon, buffer_m), "observed_hull_fallback", toe_candidate_points, toe_height_upper

    if toe_polygon is not None:
        return _expand_polygon_radially(toe_polygon, toe_buffer_m), toe_source or "toe_hull", toe_candidate_points, toe_height_upper
    if cone_polygon is not None:
        return _expand_polygon_radially(cone_polygon, buffer_m), "cone_hull", toe_candidate_points, toe_height_upper

    if observed_polygon is not None:
        return _expand_polygon_radially(observed_polygon, buffer_m), "observed_hull", toe_candidate_points, toe_height_upper

    return None, None, toe_candidate_points, toe_height_upper


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
    full_scene_points: np.ndarray | None = None,
    footprint_buffer_m: float = 0.75,
    toe_footprint_buffer_m: float = 0.25,
    toe_footprint_height_fraction: float = 0.18,
    toe_footprint_max_height_m: float = 0.35,
    toe_footprint_min_points: int = 250,
    toe_footprint_sector_count: int = 48,
    toe_footprint_radius_percentile: float = 82.0,
    toe_footprint_outer_percentile: float = 97.0,
    toe_footprint_blend_factor: float = 0.40,
    toe_footprint_min_sector_coverage: float = 0.55,
    toe_slope_break_bins: int = 28,
    toe_slope_break_surface_percentile: float = 82.0,
    toe_slope_break_height_m: float = 0.10,
    toe_slope_break_consecutive_bins: int = 2,
    min_toe_contour_area_ratio: float = 0.78,
    min_toe_footprint_area_ratio: float = 0.55,
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
            toe_candidate_points=0,
            toe_height_upper_m=None,
        )

    x, y, z = points[:, 0], points[:, 1], points[:, 2]
    points_xy = np.column_stack([x, y])
    footprint_polygon, footprint_source, toe_candidate_points, toe_height_upper = _build_footprint_polygon(
        points,
        footprint_xy,
        full_scene_points,
        footprint_buffer_m,
        toe_footprint_buffer_m,
        toe_footprint_height_fraction,
        toe_footprint_max_height_m,
        toe_footprint_min_points,
        toe_footprint_sector_count,
        toe_footprint_radius_percentile,
        toe_footprint_outer_percentile,
        toe_footprint_blend_factor,
        toe_footprint_min_sector_coverage,
        toe_slope_break_bins,
        toe_slope_break_surface_percentile,
        toe_slope_break_height_m,
        toe_slope_break_consecutive_bins,
        min_toe_contour_area_ratio,
        min_toe_footprint_area_ratio,
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
            toe_candidate_points=toe_candidate_points,
            toe_height_upper_m=toe_height_upper,
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
        inside_footprint = footprint_path.contains_points(cell_centers, radius=resolution * 0.5)
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
        known_vals = height_grid[valid]
        known_xy = np.column_stack([cx[valid], cy[valid]])
        query_xy = np.column_stack([cx[inside_footprint], cy[inside_footprint]])
        try:
            interpolated_vals = griddata(known_xy, known_vals, query_xy, method="linear")
            if np.isnan(interpolated_vals).any():
                nearest_vals = griddata(known_xy, known_vals, query_xy, method="nearest")
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
        "Grid integration: %.2f m³ (grid %dx%d, %.1f%% footprint cells had data%s, footprint=%s, toe candidates=%d)",
        volume,
        height_grid.shape[0],
        height_grid.shape[1],
        occupancy_pct,
        ", interpolated" if used_interpolation else "",
        footprint_source or "bounding_box",
        toe_candidate_points,
    )

    return GridIntegrationResult(
        volume_m3=max(0.0, volume),
        occupancy_pct=occupancy_pct,
        observed_cells=observed_cells,
        total_cells=total_cells,
        interpolated=used_interpolation,
        footprint_area_m2=footprint_area_m2,
        footprint_source=footprint_source,
        toe_candidate_points=toe_candidate_points,
        toe_height_upper_m=toe_height_upper,
    )


def compute_volume(
    pile_cloud: o3d.geometry.PointCloud,
    config: VolumeConfig | None = None,
    footprint_points: list[np.ndarray] | np.ndarray | None = None,
    full_scene_cloud: o3d.geometry.PointCloud | None = None,
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
    full_scene_points = None
    if full_scene_cloud is not None:
        full_scene_points = np.asarray(full_scene_cloud.points)
    grid_stats = volume_grid_integration(
        points,
        config.grid_resolution,
        footprint_xy=footprint_xy,
        full_scene_points=full_scene_points,
        footprint_buffer_m=config.footprint_buffer_m,
        toe_footprint_buffer_m=config.toe_footprint_buffer_m,
        toe_footprint_height_fraction=config.toe_footprint_height_fraction,
        toe_footprint_max_height_m=config.toe_footprint_max_height_m,
        toe_footprint_min_points=config.toe_footprint_min_points,
        toe_footprint_sector_count=config.toe_footprint_sector_count,
        toe_footprint_radius_percentile=config.toe_footprint_radius_percentile,
        toe_footprint_outer_percentile=config.toe_footprint_outer_percentile,
        toe_footprint_blend_factor=config.toe_footprint_blend_factor,
        toe_footprint_min_sector_coverage=config.toe_footprint_min_sector_coverage,
        toe_slope_break_bins=config.toe_slope_break_bins,
        toe_slope_break_surface_percentile=config.toe_slope_break_surface_percentile,
        toe_slope_break_height_m=config.toe_slope_break_height_m,
        toe_slope_break_consecutive_bins=config.toe_slope_break_consecutive_bins,
        min_toe_contour_area_ratio=config.min_toe_contour_area_ratio,
        min_toe_footprint_area_ratio=config.min_toe_footprint_area_ratio,
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
        toe_candidate_points=getattr(grid_stats, "toe_candidate_points", 0),
        toe_height_upper_m=getattr(grid_stats, "toe_height_upper_m", None),
    )
