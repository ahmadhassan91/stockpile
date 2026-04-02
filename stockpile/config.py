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


@dataclass
class ColmapConfig:
    colmap_binary: str = "colmap-gpu"
    quality: str = "medium"  # low, medium, high
    single_camera: bool = True
    camera_model: str = "SIMPLE_RADIAL"
    use_sequential_matching: bool = True
    use_gpu: bool = True
    max_colmap_frames: int = 150  # subsample frames before COLMAP to avoid dense-center bias


@dataclass
class ScaleCalibrationConfig:
    known_cone_height_m: float = 0.75  # Standard 750mm traffic cone
    assumed_camera_height_m: float = 1.6  # Handheld phone height above ground
    dbscan_eps: float = 0.5  # In COLMAP units, tuned during calibration
    dbscan_min_samples: int = 3
    min_cones_for_confidence: int = 3
    max_method_disagreement_ratio: float = 1.75


@dataclass
class GroundPlaneConfig:
    ransac_distance_threshold: float = 0.02  # meters after scaling
    ransac_n: int = 3
    ransac_iterations: int = 1000
    above_ground_threshold: float = 0.10  # meters — raised from 0.05 to reduce ground noise misclassification
    statistical_nb_neighbors: int = 20
    statistical_std_ratio: float = 2.0


@dataclass
class VolumeConfig:
    grid_resolution: float = 0.05  # meters per cell for 2.5D method
    alpha: float = 0.3  # alpha shape parameter
    recommended_min_grid_occupancy_pct: float = 3.0
    recommended_max_grid_to_hull_ratio: float = 4.0


@dataclass
class QualityGateConfig:
    min_calibration_confidence_warn: float = 0.40
    min_calibration_confidence_block: float = 0.25
    min_unique_cones_warn: int = 3
    min_unique_cones_block: int = 2
    max_scale_disagreement_warn: float = 1.5
    max_scale_disagreement_block: float = 2.0
    min_pile_points_warn: int = 5000
    min_pile_points_block: int = 1500
    min_grid_occupancy_warn_pct: float = 5.0
    min_grid_occupancy_block_pct: float = 1.0
    max_grid_to_hull_warn_ratio: float = 2.5
    max_grid_to_hull_block_ratio: float = 5.0
    max_pile_height_warn_m: float = 8.0
    max_pile_height_block_m: float = 12.0


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
