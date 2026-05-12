from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


@dataclass(frozen=True)
class BackendSettings:
    service_name: str = "stockpile-lidar-backend"
    version: str = "0.1.0"
    environment: str = "development"
    storage_root: Path = Path("/tmp/stockpile-lidar")


@lru_cache(maxsize=1)
def get_settings() -> BackendSettings:
    return BackendSettings(
        environment=os.getenv("STOCKPILE_LIDAR_ENV", "development"),
        storage_root=Path(os.getenv("STOCKPILE_LIDAR_STORAGE_ROOT", "/tmp/stockpile-lidar")),
    )


# ---------------------------------------------------------------------------
# Geometry / quality configs ported from the legacy COLMAP backend.
#
# The LiDAR pipeline reuses the same volume / ground-plane / quality-gate math
# as the legacy backend, so the configurable thresholds carry over verbatim
# for the gates that still apply. Cone-/COLMAP-specific fields are dropped.
# ---------------------------------------------------------------------------


@dataclass
class VolumeConfig:
    grid_resolution: float = 0.05  # meters per cell for 2.5D method
    alpha: float = 0.3  # alpha shape parameter
    footprint_buffer_m: float = 0.75
    toe_footprint_buffer_m: float = 0.15
    toe_footprint_height_fraction: float = 0.18
    toe_footprint_max_height_m: float = 0.35
    toe_footprint_min_points: int = 250
    toe_footprint_sector_count: int = 48
    toe_footprint_radius_percentile: float = 82.0
    toe_footprint_outer_percentile: float = 97.0
    toe_footprint_blend_factor: float = 0.40
    toe_footprint_min_sector_coverage: float = 0.55
    toe_slope_break_bins: int = 28
    toe_slope_break_surface_percentile: float = 82.0
    toe_slope_break_height_m: float = 0.10
    toe_slope_break_consecutive_bins: int = 2
    min_toe_contour_area_ratio: float = 0.78
    min_toe_footprint_area_ratio: float = 0.55
    min_cone_footprint_area_ratio: float = 0.7
    recommended_min_grid_occupancy_pct: float = 3.0
    recommended_max_grid_to_hull_ratio: float = 4.0


@dataclass
class GroundPlaneConfig:
    ransac_distance_threshold: float = 0.02  # meters after scaling
    ransac_n: int = 3
    ransac_iterations: int = 1000
    above_ground_threshold: float = 0.10  # meters — raised from 0.05 to reduce ground noise misclassification
    # Optional ground-anchor crop margin (e.g. ARKit horizontal-plane anchors).
    # Field name kept generic since LiDAR captures may not have any cones.
    anchor_crop_margin_m: float = 0.75
    # Maximum allowed disagreement (in meters) between RANSAC ground Z and the
    # anchor-derived ground Z before the anchor prior is rejected.
    max_anchor_ground_disagreement_m: float = 0.50
    statistical_nb_neighbors: int = 20
    statistical_std_ratio: float = 2.0
    random_seed: int = 7


@dataclass
class QualityGateConfig:
    """LiDAR-relevant quality gates.

    Cone- and COLMAP-specific fields from the legacy backend have been
    removed; only the 9 gates that make sense for a LiDAR-native capture
    remain. Threshold values are unchanged from the legacy backend so the
    operational signal (warnings vs blockers) is preserved.
    """

    # 1. Pile-point density gate
    min_pile_points_warn: int = 5000
    min_pile_points_block: int = 1500

    # 2. Tall-pile gate
    tall_pile_warn_m: float = 12.0
    tall_pile_block_m: float = 15.0

    # 3. Peak-relief (spiky-reconstruction) gate
    peak_relief_warn_m: float = 1.0
    peak_relief_block_m: float = 2.0
    peak_relief_warn_ratio: float = 1.08
    peak_relief_block_ratio: float = 1.15

    # 4. Grid-occupancy gate
    min_grid_occupancy_warn_pct: float = 5.0
    min_grid_occupancy_block_pct: float = 1.0

    # 5. Grid-to-hull ratio gate
    min_grid_to_hull_warn_ratio: float = 0.25
    min_grid_to_hull_block_ratio: float = 0.10
    max_grid_to_hull_warn_ratio: float = 2.5
    max_grid_to_hull_block_ratio: float = 5.0

    # 6. Combined tall-pile + grid/hull inflation gate
    tall_pile_grid_to_hull_block_ratio: float = 2.5

    # 7. Volume.recommended_note passthrough — no thresholds, just enabled.

    # 8. Tracking-state-summary gate (LiDAR-specific)
    max_tracking_not_available_block_fraction: float = 0.10
    max_tracking_limited_warn_fraction: float = 0.25

    # 9. Frame-pose-continuity gate (LiDAR-specific)
    max_consecutive_missing_pose_frames_block: int = 5

    # 10. Backend-vs-device sanity gate. The phone quick estimate is not the
    # reported value, but large disagreement means the reconstruction is not
    # stable enough for client-facing release.
    quick_estimate_volume_warn_ratio: float = 1.75
    quick_estimate_volume_block_ratio: float = 3.00

    # 11. Small-pile mode. Office / sample piles are orders of magnitude
    # smaller than yard stockpiles, so stockpile-scale geometry is a hard sign
    # that the scan included ground, wall, background, or a LiDAR height spike.
    small_pile_volume_warn_m3: float = 0.08
    small_pile_volume_block_m3: float = 0.25
    small_pile_footprint_warn_m2: float = 0.50
    small_pile_footprint_block_m2: float = 1.25
    small_pile_height_warn_m: float = 0.45
    small_pile_height_block_m: float = 0.85
    small_pile_quick_estimate_volume_block_m3: float = 0.30
    small_pile_quick_estimate_volume_warn_m3: float = 0.10
    small_pile_quick_estimate_volume_warn_ratio: float = 1.35
    small_pile_quick_estimate_volume_block_ratio: float = 1.75
