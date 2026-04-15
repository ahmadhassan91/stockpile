"""Pipeline configuration dataclasses."""

from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class FrameExtractionConfig:
    interval_sec: float = 0.25   # Increased from 0.5 — more frames = denser COLMAP reconstruction
    max_frames: int = 800        # Increased from 500 for large-pile videos
    output_format: str = "jpg"
    jpeg_quality: int = 95


@dataclass
class ConeDetectionConfig:
    # HSV ranges for red/orange (two ranges to wrap hue circle)
    red_hue_low1: int = 0
    red_hue_high1: int = 25
    red_hue_low2: int = 160
    red_hue_high2: int = 180
    saturation_min: int = 60
    value_min: int = 60
    # Contour filtering
    min_area: int = 2000
    max_area: int = 200000
    min_aspect_ratio: float = 1.0
    max_aspect_ratio: float = 5.0
    min_solidity: float = 0.4
    min_fill_ratio: float = 0.18
    max_bbox_width_ratio: float = 0.22
    max_bbox_height_ratio: float = 0.32


@dataclass
class ColmapConfig:
    colmap_binary: str = "colmap-gpu"
    quality: str = "medium"  # low, medium, high
    single_camera: bool = True
    camera_model: str = "SIMPLE_RADIAL"
    use_sequential_matching: bool = True
    sequential_matching_min_frames: int = 120  # prefer video-aware matching once we have enough ordered frames
    use_gpu: bool = True
    use_gpu_matching: bool = True  # Falls back to CPU automatically if GPU matching fails.
    feature_num_threads: int = -1
    matching_num_threads: int = -1
    mapper_num_threads: int = -1
    random_seed: int = 7
    max_num_matches: int = 8192
    max_num_features_cap: int = 8192
    min_geometric_matches_for_mapper: int = 20
    min_registered_image_ratio: float = 0.70
    min_init_pair_inliers: int = 40
    min_init_pair_frame_gap: int = 12
    mapper_init_num_trials: int = 300
    mapper_max_runtime_seconds: int = 900
    mapper_init_min_num_inliers: int = 30
    max_colmap_frames: int = 300  # use more frames on GPU-backed deployments for better pile coverage


@dataclass
class ScaleCalibrationConfig:
    known_cone_height_m: float = 0.75  # Standard 750mm traffic cone
    assumed_camera_height_m: float = 1.6  # Handheld phone height above ground
    dbscan_eps: float = 0.20  # In COLMAP units, clusters trimmed cone centroids across frames
    dbscan_min_samples: int = 2
    min_cones_for_confidence: int = 3
    projection_outlier_mad_multiplier: float = 2.5
    min_plausible_scale: float = 0.5
    max_plausible_scale: float = 20.0
    max_projection_distance: float = 1.0  # COLMAP units — reject far-field samples with inflated distances
    min_cone_pixel_height: int = 100  # reject small detections with noisy scale
    projection_height_weight_cap: float = 3.0
    projection_height_bias_corr_threshold: float = -0.5
    cone_position_percentile: float = 50.0
    cone_position_min_points: int = 3
    camera_height_ground_std_rel_max: float = 0.10
    camera_height_cone_cv_max: float = 0.75
    min_camera_height_confidence_for_crosscheck: float = 0.20
    max_method_disagreement_ratio: float = 1.75
    random_seed: int = 7


@dataclass
class GroundPlaneConfig:
    ransac_distance_threshold: float = 0.02  # meters after scaling
    ransac_n: int = 3
    ransac_iterations: int = 1000
    above_ground_threshold: float = 0.10  # meters — raised from 0.05 to reduce ground noise misclassification
    cone_crop_margin_m: float = 0.75
    max_cone_ground_disagreement_m: float = 0.50
    statistical_nb_neighbors: int = 20
    statistical_std_ratio: float = 2.0
    random_seed: int = 7


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
class QualityGateConfig:
    min_calibration_confidence_warn: float = 0.40
    min_calibration_confidence_block: float = 0.35
    min_unique_cones_warn: int = 3
    min_unique_cones_block: int = 2
    min_verified_calibration_confidence: float = 0.55
    max_verified_scale_disagreement: float = 1.8
    max_review_grade_unique_cones: int = 2
    max_scale_disagreement_warn: float = 1.5
    max_scale_disagreement_block: float = 3.0
    max_detected_cones_per_frame_warn: int = 4
    max_detected_cones_per_frame_block: int = 6
    dense_cone_scale_disagreement_block: float = 2.25
    min_pile_points_warn: int = 5000
    min_pile_points_block: int = 1500
    min_grid_occupancy_warn_pct: float = 5.0
    min_grid_occupancy_block_pct: float = 1.0
    max_grid_to_hull_warn_ratio: float = 2.5
    max_grid_to_hull_block_ratio: float = 5.0
    tall_pile_warn_m: float = 12.0
    tall_pile_block_m: float = 15.0
    tall_pile_grid_to_hull_block_ratio: float = 2.5
    peak_relief_warn_m: float = 1.0
    peak_relief_block_m: float = 2.0
    peak_relief_warn_ratio: float = 1.08
    peak_relief_block_ratio: float = 1.15
    single_cone_review_min_confidence: float = 0.65
    single_cone_review_min_pile_points: int = 10000
    single_cone_review_min_grid_occupancy_pct: float = 10.0
    single_cone_review_max_scale_disagreement: float = 2.0


# Material presets — names and max bulk densities from the site density table.
# Keys are display names; values are max density in kg/m³ (= MT/m³ × 1000).
DENSITY_PRESETS = {
    "Backfill 0\u201375 mm":    2100,   # 1.80 \u2013 2.10 MT/m\u00b3  — use max
    "Aggregates 5\u201314 mm":  1650,   # 1.50 \u2013 1.65 MT/m\u00b3  — use max
    "Aggregates 10\u201320 mm": 1600,   # 1.45 \u2013 1.60 MT/m\u00b3  — use max
}

# Density range metadata (min, max) in kg/m\u00b3 for display purposes
DENSITY_RANGES = {
    "Backfill 0\u201375 mm":    (1800, 2100),
    "Aggregates 5\u201314 mm":  (1500, 1650),
    "Aggregates 10\u201320 mm": (1450, 1600),
}


@dataclass
class PipelineConfig:
    workspace: Path = field(default_factory=lambda: Path("data/workspace"))
    frame_extraction: FrameExtractionConfig = field(default_factory=FrameExtractionConfig)
    cone_detection: ConeDetectionConfig = field(default_factory=ConeDetectionConfig)
    colmap: ColmapConfig = field(default_factory=ColmapConfig)
    scale_calibration: ScaleCalibrationConfig = field(default_factory=ScaleCalibrationConfig)
    ground_plane: GroundPlaneConfig = field(default_factory=GroundPlaneConfig)
    volume: VolumeConfig = field(default_factory=VolumeConfig)
    quality_gates: QualityGateConfig = field(default_factory=QualityGateConfig)
    material_density: float = 2100.0  # kg/m3 — default: Backfill 0-75mm max density
    material_name: str = "Backfill 0\u201375 mm"
    manual_scale_override: Optional[float] = None  # If set, bypass auto calibration
    progress_callback: Optional[object] = field(default=None, repr=False)

    def __post_init__(self):
        self.workspace = Path(self.workspace)

    @property
    def images_dir(self) -> Path:
        return self.workspace / "images"

    @property
    def colmap_dir(self) -> Path:
        return self.workspace / "colmap"

    @property
    def sparse_dir(self) -> Path:
        return self.colmap_dir / "sparse" / "0"

    @property
    def output_dir(self) -> Path:
        return self.workspace / "output"
