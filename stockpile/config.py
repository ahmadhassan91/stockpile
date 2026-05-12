"""Pipeline configuration dataclasses."""

from dataclasses import dataclass, field
import math
import os
from pathlib import Path
from typing import Optional

from .tagged_references import TaggedReferenceCatalog, TaggedReferenceSpec


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
    red_hue_high1: int = 15       # P6: narrowed from 25 — excludes brownish-orange aggregate
    red_hue_low2: int = 165       # P6: narrowed from 160 — excludes pinkish rock tones
    red_hue_high2: int = 180
    saturation_min: int = 85      # P6: raised from 60 — real cones are vivid (85-100%), aggregate is duller (40-70%)
    value_min: int = 60
    # Contour filtering
    min_area: int = 2000
    max_area: int = 200000
    min_aspect_ratio: float = 1.5  # P6: raised from 1.0 — real cones are tall/narrow (2:1-3.5:1), aggregate is squatter
    max_aspect_ratio: float = 5.0
    min_solidity: float = 0.65     # P6: raised from 0.4 — real cones are compact (0.7-0.95), aggregate has rougher edges
    min_fill_ratio: float = 0.25   # P6: raised from 0.18 — real cones fill their bbox better than scattered texture
    max_bbox_width_ratio: float = 0.22
    max_bbox_height_ratio: float = 0.32
    # P1 reliability: frames with more detections than this are treated as
    # texture saturation (e.g. reddish aggregate) and their detections dropped.
    # Real walkarounds rarely expose more than 2-3 cones to the camera at once.
    max_detections_per_frame_cap: int = 3
    # P5: if the dedup step produces more unique 3D cones than this ceiling,
    # the entire detection is treated as false-positive saturation. Real sites
    # have 2-6 physical cones; 29 "unique cones" means the detector is eating
    # the pile's aggregate texture.
    max_unique_cones_ceiling: int = 8


@dataclass
class TaggedReferenceConfig:
    """Configuration for known tag-based physical references."""

    enabled: bool = False
    detector_backend: str = "apriltag"
    family: str = "tag36h11"
    default_tag_size_m: float = 0.18
    min_tag_edge_px: int = 24
    max_hamming: int = 0
    min_detections_per_tag: int = 2
    allowed_tag_ids: tuple[int, ...] = ()
    require_catalog_match: bool = False
    prefer_tagged_scale_when_available: bool = True
    catalog: tuple[TaggedReferenceSpec, ...] = field(default_factory=tuple)

    def __post_init__(self):
        if self.default_tag_size_m <= 0:
            raise ValueError("default_tag_size_m must be positive")
        if self.min_tag_edge_px <= 0:
            raise ValueError("min_tag_edge_px must be positive")
        if self.min_detections_per_tag <= 0:
            raise ValueError("min_detections_per_tag must be positive")
        if self.max_hamming < 0:
            raise ValueError("max_hamming must be non-negative")

        self.allowed_tag_ids = tuple(sorted(set(self.allowed_tag_ids)))
        self.catalog = tuple(self.catalog)

        mismatched_families = sorted({reference.family for reference in self.catalog if reference.family != self.family})
        if mismatched_families:
            raise ValueError(
                "catalog contains tagged references for unexpected families: "
                f"{mismatched_families}; expected only {self.family!r}",
            )

        if self.allowed_tag_ids and self.require_catalog_match:
            missing_ids = sorted(set(self.allowed_tag_ids) - set(self.catalog_tag_ids))
            if missing_ids:
                raise ValueError(
                    "allowed_tag_ids must exist in catalog when require_catalog_match=True; "
                    f"missing ids: {missing_ids}",
                )

    @property
    def catalog_view(self) -> TaggedReferenceCatalog:
        return TaggedReferenceCatalog(references=self.catalog)

    @property
    def catalog_tag_ids(self) -> tuple[int, ...]:
        return self.catalog_view.tag_ids

    def spec_for_tag(self, tag_id: int) -> TaggedReferenceSpec | None:
        if tag_id < 0:
            return None
        if self.allowed_tag_ids and tag_id not in self.allowed_tag_ids:
            return None

        catalog_match = self.catalog_view.get(tag_id, self.family)
        if catalog_match is not None:
            return catalog_match
        if self.require_catalog_match:
            return None

        return TaggedReferenceSpec(
            tag_id=tag_id,
            family=self.family,
            tag_size_m=self.default_tag_size_m,
        )


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
    # Registration ratio thresholds for the COLMAP sparse reconstruction.
    # P9: split into a hard block floor + a soft warn floor. Previously a single
    # 0.70 floor caused hard failures on borderline videos where the sparse
    # model was still usable (e.g. 138 / 300 = 46 % registered gives a complete
    # pile reconstruction). Below min_registered_image_ratio_block (0.35) the
    # model is genuinely too incomplete to trust; between the two thresholds we
    # surface a quality warning and let the downstream calibration gates decide.
    min_registered_image_ratio: float = 0.70
    min_registered_image_ratio_block: float = 0.35
    min_init_pair_inliers: int = 40
    min_init_pair_frame_gap: int = 12
    # P2 reliability: the forced-pair mapper has been failing ~4x/day with
    # "Provided pair is unsuitable for initialization". Each attempt burns
    # num_trials * ~300ms before giving up. Previous values of 300/900 came
    # from a well-matched corpus; they were too generous for client videos
    # where init-pair geometry is often degenerate.
    # init_num_trials lowered from 300 → 80 to reduce wasted time.
    # max_runtime_seconds stays at 900 for the UNFORCED retry — client
    # videos (like the Backfill 0-75mm) can need 10+ min to map 300 frames.
    # The forced-pair attempt uses forced_pair_max_runtime_seconds instead.
    mapper_init_num_trials: int = 80
    mapper_max_runtime_seconds: int = 900
    mapper_init_min_num_inliers: int = 30
    # Budget for the forced-pair attempt specifically. If the pair cannot
    # initialise within this window we skip straight to unforced mapping
    # rather than waiting out the full mapper_max_runtime_seconds.
    forced_pair_max_runtime_seconds: int = 120
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
    min_mobile_pose_confidence_for_crosscheck: float = 0.25
    max_mobile_pose_time_offset_sec: float = 0.35
    min_mobile_pose_matches: int = 3
    min_mobile_pose_pair_span_m: float = 0.35
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
    # P0 reliability tightening (2026-04-15): the 19:40 aggregate run surfaced a
    # 4.5x scale disagreement with 39% confidence and 6 cones/frame as a
    # "review only" estimate; these stricter gates block that shape of failure.
    min_calibration_confidence_warn: float = 0.50
    min_calibration_confidence_block: float = 0.50
    min_unique_cones_warn: int = 3
    min_unique_cones_block: int = 2
    min_verified_calibration_confidence: float = 0.60
    max_verified_scale_disagreement: float = 1.6
    max_review_grade_unique_cones: int = 2
    max_scale_disagreement_warn: float = 1.5
    max_scale_disagreement_block: float = 2.0
    max_detected_cones_per_frame_warn: int = 4
    max_detected_cones_per_frame_block: int = 5
    dense_cone_scale_disagreement_block: float = 1.8
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
    # Footprint provenance is now one of the highest-signal post-scale risk
    # indicators. If the volume falls back to a cone hull or observed convex
    # hull instead of a toe-aware footprint, keep the run review-grade even if
    # scale calibration looks stable.
    weak_footprint_warn_sources: tuple[str, ...] = (
        "cone_hull",
        "observed_hull",
        "observed_hull_fallback",
    )


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


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return bool(default)
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    return bool(default)


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return float(default)
    try:
        return float(raw)
    except ValueError:
        return float(default)


def _env_optional_float(name: str) -> float | None:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def _env_int(name: str, default: int, *, minimum: int = 0) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return max(minimum, int(default))
    try:
        parsed = int(raw)
    except ValueError:
        return max(minimum, int(default))
    return max(minimum, parsed)


def _env_int_tuple(name: str, default: tuple[int, ...] = ()) -> tuple[int, ...]:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return tuple(default)

    values: list[int] = []
    seen: set[int] = set()
    for chunk in raw.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            parsed = int(chunk)
        except ValueError:
            continue
        if parsed < 0 or parsed in seen:
            continue
        seen.add(parsed)
        values.append(parsed)
    return tuple(sorted(values))


def _optional_ratio(value: float | int | None) -> float | None:
    if value is None:
        return None
    parsed = float(value)
    if not math.isfinite(parsed):
        raise ValueError("ratio values must be finite")
    return max(0.0, min(1.0, parsed))


def _optional_non_negative_float(name: str, value: float | int | None) -> float | None:
    if value is None:
        return None
    parsed = float(value)
    if not math.isfinite(parsed) or parsed < 0:
        raise ValueError(f"{name} must be non-negative")
    return parsed


@dataclass
class PipelineConfig:
    workspace: Path = field(default_factory=lambda: Path("data/workspace"))
    frame_extraction: FrameExtractionConfig = field(default_factory=FrameExtractionConfig)
    cone_detection: ConeDetectionConfig = field(default_factory=ConeDetectionConfig)
    tagged_references: TaggedReferenceConfig = field(default_factory=TaggedReferenceConfig)
    colmap: ColmapConfig = field(default_factory=ColmapConfig)
    scale_calibration: ScaleCalibrationConfig = field(default_factory=ScaleCalibrationConfig)
    ground_plane: GroundPlaneConfig = field(default_factory=GroundPlaneConfig)
    volume: VolumeConfig = field(default_factory=VolumeConfig)
    quality_gates: QualityGateConfig = field(default_factory=QualityGateConfig)
    material_density: float = 2100.0  # kg/m3 — default: Backfill 0-75mm max density
    material_name: str = "Backfill 0\u201375 mm"
    mobile_capture_prior: "MobileCapturePrior | None" = None
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


@dataclass(frozen=True)
class MobileCapturePrior:
    reference_evidence_timestamps_sec: tuple[float, ...] = ()
    useful_pose_sample_timestamps_sec: tuple[float, ...] = ()
    reference_evidence_count: int = 0
    pose_sample_count: int = 0
    useful_pose_sample_count: int = 0
    depth_data_included: bool | None = None
    pile_segmentation_score: float | None = None
    toe_segmentation_score: float | None = None
    segmentation_confidence_score: float | None = None
    quick_volume_m3: float | None = None
    quick_footprint_area_m2: float | None = None
    quick_peak_height_m: float | None = None
    quick_confidence_score: float | None = None
    quick_geometry_point_count: int | None = None
    quick_camera_path_distance_m: float | None = None

    def __post_init__(self):
        object.__setattr__(
            self,
            "reference_evidence_timestamps_sec",
            tuple(float(timestamp) for timestamp in self.reference_evidence_timestamps_sec),
        )
        object.__setattr__(
            self,
            "useful_pose_sample_timestamps_sec",
            tuple(float(timestamp) for timestamp in self.useful_pose_sample_timestamps_sec),
        )
        if self.reference_evidence_count < 0:
            raise ValueError("reference_evidence_count must be non-negative")
        if self.pose_sample_count < 0:
            raise ValueError("pose_sample_count must be non-negative")
        if self.useful_pose_sample_count < 0:
            raise ValueError("useful_pose_sample_count must be non-negative")
        object.__setattr__(self, "pile_segmentation_score", _optional_ratio(self.pile_segmentation_score))
        object.__setattr__(self, "toe_segmentation_score", _optional_ratio(self.toe_segmentation_score))
        object.__setattr__(
            self,
            "segmentation_confidence_score",
            _optional_ratio(self.segmentation_confidence_score),
        )
        object.__setattr__(
            self,
            "quick_volume_m3",
            _optional_non_negative_float("quick_volume_m3", self.quick_volume_m3),
        )
        object.__setattr__(
            self,
            "quick_footprint_area_m2",
            _optional_non_negative_float("quick_footprint_area_m2", self.quick_footprint_area_m2),
        )
        object.__setattr__(
            self,
            "quick_peak_height_m",
            _optional_non_negative_float("quick_peak_height_m", self.quick_peak_height_m),
        )
        object.__setattr__(self, "quick_confidence_score", _optional_ratio(self.quick_confidence_score))
        if self.quick_geometry_point_count is not None and self.quick_geometry_point_count < 0:
            raise ValueError("quick_geometry_point_count must be non-negative")
        object.__setattr__(
            self,
            "quick_camera_path_distance_m",
            _optional_non_negative_float(
                "quick_camera_path_distance_m",
                self.quick_camera_path_distance_m,
            ),
        )


def build_mobile_job_pipeline_config(
    *,
    workspace: str | Path,
    material_density_kg_per_m3: int | float,
    material_name: str,
    progress_callback=None,
    mobile_capture_prior: MobileCapturePrior | None = None,
) -> PipelineConfig:
    """Build a pipeline config for the durable mobile job runner."""
    config = PipelineConfig(
        workspace=Path(workspace),
        material_density=float(material_density_kg_per_m3),
        material_name=str(material_name),
        mobile_capture_prior=mobile_capture_prior,
        progress_callback=progress_callback,
    )

    tagged_defaults = config.tagged_references
    config.tagged_references = TaggedReferenceConfig(
        enabled=_env_bool("STOCKPILE_MOBILE_TAGGED_REFERENCES_ENABLED", True),
        detector_backend=os.environ.get(
            "STOCKPILE_MOBILE_TAG_DETECTOR_BACKEND",
            tagged_defaults.detector_backend,
        ),
        family=os.environ.get(
            "STOCKPILE_MOBILE_TAG_FAMILY",
            tagged_defaults.family,
        ),
        default_tag_size_m=_env_float(
            "STOCKPILE_MOBILE_TAG_SIZE_M",
            tagged_defaults.default_tag_size_m,
        ),
        min_tag_edge_px=_env_int(
            "STOCKPILE_MOBILE_MIN_TAG_EDGE_PX",
            tagged_defaults.min_tag_edge_px,
            minimum=1,
        ),
        max_hamming=_env_int(
            "STOCKPILE_MOBILE_TAG_MAX_HAMMING",
            tagged_defaults.max_hamming,
            minimum=0,
        ),
        min_detections_per_tag=_env_int(
            "STOCKPILE_MOBILE_MIN_DETECTIONS_PER_TAG",
            tagged_defaults.min_detections_per_tag,
            minimum=1,
        ),
        allowed_tag_ids=_env_int_tuple(
            "STOCKPILE_MOBILE_ALLOWED_TAG_IDS",
            tagged_defaults.allowed_tag_ids,
        ),
        require_catalog_match=_env_bool(
            "STOCKPILE_MOBILE_REQUIRE_CATALOG_MATCH",
            tagged_defaults.require_catalog_match,
        ),
        prefer_tagged_scale_when_available=_env_bool(
            "STOCKPILE_MOBILE_PREFER_TAGGED_SCALE",
            tagged_defaults.prefer_tagged_scale_when_available,
        ),
        catalog=tagged_defaults.catalog,
    )
    config.manual_scale_override = _env_optional_float("STOCKPILE_MOBILE_MANUAL_SCALE_OVERRIDE")
    return config
