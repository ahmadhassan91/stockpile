"""Pipeline configuration dataclasses."""

from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class FrameExtractionConfig:
    interval_sec: float = 0.5
    max_frames: int = 500
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
    colmap_binary: str = "colmap"
    quality: str = "medium"  # low, medium, high
    single_camera: bool = True
    camera_model: str = "SIMPLE_RADIAL"
    use_sequential_matching: bool = True


@dataclass
class ScaleCalibrationConfig:
    known_cone_height_m: float = 0.75  # Standard 750mm traffic cone
    assumed_camera_height_m: float = 1.6  # Handheld phone height above ground
    dbscan_eps: float = 0.5  # In COLMAP units, tuned during calibration
    dbscan_min_samples: int = 3
    min_cones_for_confidence: int = 3


@dataclass
class GroundPlaneConfig:
    ransac_distance_threshold: float = 0.02  # meters after scaling
    ransac_n: int = 3
    ransac_iterations: int = 1000
    above_ground_threshold: float = 0.05  # meters
    statistical_nb_neighbors: int = 20
    statistical_std_ratio: float = 2.0


@dataclass
class VolumeConfig:
    grid_resolution: float = 0.05  # meters per cell for 2.5D method
    alpha: float = 0.3  # alpha shape parameter


DENSITY_PRESETS = {
    "gravel": 1600,
    "sand": 1500,
    "topsoil": 1200,
    "coal": 1100,
    "crushed_stone": 1800,
    "woodchips": 350,
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
    material_density: float = 1600.0  # kg/m3
    material_name: str = "gravel"
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
