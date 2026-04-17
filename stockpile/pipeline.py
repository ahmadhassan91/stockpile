"""Pipeline orchestrator wiring all stages together."""

import logging
import random
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import open3d as o3d

from .colmap_runner import (
    export_to_ply,
    read_cameras_binary,
    read_images_binary,
    read_points3d_binary,
    run_colmap_reconstruction,
)
from .calibration_diagnostics import (
    ConeObservationStats,
    build_capture_readiness_notes,
    describe_reference_constraint,
    summarize_cone_observations,
)
from .cone_detection import detect_cones_in_frames
from .config import PipelineConfig
from .frame_extraction import extract_frames
from .ground_plane import load_and_scale_point_cloud, segment_pile
from .scale_calibration import CalibrationResult, calibrate_scale
from .volume import VolumeResult, compute_volume

logger = logging.getLogger(__name__)


@dataclass
class PipelineResult:
    num_frames: int = 0
    num_frames_with_cones: int = 0
    num_colmap_points: int = 0
    num_colmap_images: int = 0
    num_colmap_images_submitted: int = 0
    colmap_registration_ratio: float | None = None
    calibration: CalibrationResult | None = None
    volume: VolumeResult | None = None
    weight_kg: float = 0.0
    scale_factor_m_per_unit: float | None = None
    scale_source: str = "auto"
    pile_cloud: o3d.geometry.PointCloud | None = None
    ground_cloud: o3d.geometry.PointCloud | None = None
    cone_3d_positions: list[np.ndarray] = field(default_factory=list)
    sparse_model_dir: Path | None = None
    ply_path: Path | None = None
    stage: str = ""
    quality_blockers: list[str] = field(default_factory=list)
    quality_warnings: list[str] = field(default_factory=list)
    review_grade: bool = False
    publishable: bool = True
    error: str | None = None


class Pipeline:
    """Orchestrates the full stockpile estimation pipeline."""

    def __init__(self, config: PipelineConfig):
        self.config = config
        self._cancelled = False

    def cancel(self):
        self._cancelled = True

    def _check_cancel(self):
        if self._cancelled:
            raise RuntimeError("Pipeline cancelled by user")

    def _report(self, stage: str, progress: float, message: str = ""):
        if self.config.progress_callback:
            self.config.progress_callback(stage, progress, message)
        # P4 log hygiene: only log on 10% boundaries (and always at 0 / 1 /
        # when a message is attached). The per-frame progress callback used
        # to emit thousands of lines per stage, burying real signal.
        pct = int(progress * 100)
        should_log = (
            bool(message)
            or progress <= 0.0
            or progress >= 1.0
            or pct % 10 == 0
        )
        if should_log:
            last_pct = getattr(self, "_last_logged_pct", {}).get(stage, -1)
            if pct != last_pct or message:
                logger.info("[%s] %d%% %s", stage, pct, message)
                if not hasattr(self, "_last_logged_pct"):
                    self._last_logged_pct = {}
                self._last_logged_pct[stage] = pct

    def _add_warning(self, result: PipelineResult, message: str):
        if message not in result.quality_warnings:
            result.quality_warnings.append(message)

    def _add_blocker(self, result: PipelineResult, message: str):
        if message not in result.quality_blockers:
            result.quality_blockers.append(message)

    def _append_calibration_note(self, calibration: CalibrationResult, message: str):
        if message not in calibration.notes:
            calibration.notes.append(message)

    def _should_use_cone_positions_for_segmentation(self, calibration: CalibrationResult | None) -> bool:
        if calibration is None or not calibration.cone_3d_positions:
            return False

        gates = self.config.quality_gates
        if calibration.confidence < gates.min_calibration_confidence_warn:
            return False
        if (
            calibration.scale_disagreement_ratio is not None
            and calibration.scale_disagreement_ratio > gates.max_scale_disagreement_warn
        ):
            return False
        if calibration.max_detections_in_frame > gates.max_detected_cones_per_frame_warn:
            return False
        return True

    def _populate_calibration_diagnostics(
        self,
        calibration: CalibrationResult,
        stats: ConeObservationStats,
    ):
        calibration.detected_cone_frames = stats.detected_cone_frames
        calibration.registered_cone_frames = stats.registered_cone_frames
        calibration.total_cone_detections = stats.total_cone_detections
        calibration.max_detections_in_frame = stats.max_detections_in_frame
        calibration.frames_with_multiple_detections = stats.frames_with_multiple_detections

        for note in build_capture_readiness_notes(stats, calibration.num_cones_used):
            self._append_calibration_note(calibration, note)

    def _assess_measurement_quality(self, result: PipelineResult):
        gates = self.config.quality_gates
        manual_scale = self.config.manual_scale_override is not None

        # P9: surface a warning when the sparse reconstruction only registered
        # a fraction of the submitted frames. The hard floor is enforced inside
        # run_colmap_reconstruction (anything below block_floor raises); here
        # we flag the soft-floor band so the user knows coverage was limited
        # even if downstream calibration passed.
        colmap_ratio = result.colmap_registration_ratio
        colmap_warn_floor = float(self.config.colmap.min_registered_image_ratio)
        if colmap_ratio is not None and colmap_ratio < colmap_warn_floor:
            self._add_warning(
                result,
                f"COLMAP registered only {result.num_colmap_images}/"
                f"{result.num_colmap_images_submitted} frames "
                f"({colmap_ratio:.0%}); the reconstruction coverage is below the "
                f"{colmap_warn_floor:.0%} soft floor. "
                "Cross-check the 3D view before reporting — parts of the pile may be under-sampled.",
            )

        pile_pts = np.asarray(result.pile_cloud.points) if result.pile_cloud else np.empty((0, 3))
        pile_count = len(pile_pts)
        pile_height = float(np.max(pile_pts[:, 2])) if pile_count else 0.0
        pile_height_p99 = float(np.percentile(pile_pts[:, 2], 99)) if pile_count >= 100 else pile_height
        peak_relief_m = max(0.0, pile_height - pile_height_p99)
        peak_relief_ratio = (pile_height / pile_height_p99) if pile_height_p99 > 1e-6 else None
        vol = result.volume

        if pile_count < gates.min_pile_points_block:
            self._add_blocker(
                result,
                f"Only {pile_count:,} pile points were reconstructed; the pile surface is too sparse for a reliable measurement.",
            )
        elif pile_count < gates.min_pile_points_warn:
            self._add_warning(
                result,
                f"Only {pile_count:,} pile points were reconstructed; the estimate should be reviewed against a reference.",
            )

        if pile_height > gates.tall_pile_warn_m:
            self._add_warning(
                result,
                f"Pile height reached {pile_height:.2f} m; verify that the reconstructed shape is consistent with site conditions.",
            )
        if pile_height > gates.tall_pile_block_m:
            self._add_blocker(
                result,
                f"Pile height reached {pile_height:.2f} m, which exceeds the stability ceiling ({gates.tall_pile_block_m:.2f} m).",
            )

        if peak_relief_ratio is not None:
            if peak_relief_m > gates.peak_relief_block_m and peak_relief_ratio > gates.peak_relief_block_ratio:
                self._add_blocker(
                    result,
                    f"The highest part of the pile rises {peak_relief_m:.2f} m above the 99th-percentile surface level "
                    f"({peak_relief_ratio:.2f}x), which suggests a spiky reconstruction artifact.",
                )
            elif peak_relief_m > gates.peak_relief_warn_m and peak_relief_ratio > gates.peak_relief_warn_ratio:
                self._add_warning(
                    result,
                    f"The top surface shows a pronounced spike: {peak_relief_m:.2f} m above the 99th-percentile height "
                    f"({peak_relief_ratio:.2f}x).",
                )

        if result.calibration and not manual_scale:
            cal = result.calibration
            if cal.confidence < gates.min_calibration_confidence_block:
                self._add_blocker(
                    result,
                    f"Calibration confidence is only {cal.confidence:.0%}; scale is too unstable for reporting.",
                )
            elif cal.confidence < gates.min_calibration_confidence_warn:
                self._add_warning(
                    result,
                    f"Calibration confidence is {cal.confidence:.0%}; scale should be verified before reporting.",
                )

            if cal.num_cones_used < gates.min_unique_cones_block:
                cone_stats = ConeObservationStats(
                    detected_cone_frames=cal.detected_cone_frames,
                    registered_cone_frames=cal.registered_cone_frames,
                    total_cone_detections=cal.total_cone_detections,
                    max_detections_in_frame=cal.max_detections_in_frame,
                    frames_with_multiple_detections=cal.frames_with_multiple_detections,
                )
                single_cone_review_eligible = (
                    cal.num_cones_used == 1
                    and cal.confidence >= gates.single_cone_review_min_confidence
                    and pile_count >= gates.single_cone_review_min_pile_points
                    and vol is not None
                    and vol.grid_occupancy_pct >= gates.single_cone_review_min_grid_occupancy_pct
                    and (
                        cal.scale_disagreement_ratio is None
                        or cal.scale_disagreement_ratio <= gates.single_cone_review_max_scale_disagreement
                    )
                )
                if single_cone_review_eligible:
                    result.review_grade = True
                    self._add_warning(
                        result,
                        describe_reference_constraint(cone_stats, cal.num_cones_used)
                        + " The reconstructed pile looks consistent enough for review-grade use, but the scale should still be cross-checked before client reporting.",
                    )
                else:
                    self._add_blocker(
                        result,
                        describe_reference_constraint(cone_stats, cal.num_cones_used),
                    )
            elif cal.num_cones_used < gates.min_unique_cones_warn:
                self._add_warning(
                    result,
                    f"Only {cal.num_cones_used} unique cone references were recovered; scale robustness is limited.",
                )

            if cal.max_detections_in_frame > gates.max_detected_cones_per_frame_warn:
                self._add_warning(
                    result,
                    f"Cone detection peaked at {cal.max_detections_in_frame} references in one frame, which is unusually high for a field walkaround and may indicate red pile texture was mistaken for cones.",
                )

            if (
                cal.max_detections_in_frame >= gates.max_detected_cones_per_frame_block
                and cal.scale_disagreement_ratio is not None
                and cal.scale_disagreement_ratio > gates.dense_cone_scale_disagreement_block
            ):
                self._add_blocker(
                    result,
                    f"Cone detection peaked at {cal.max_detections_in_frame} references in one frame and scale cross-checks still disagree by {cal.scale_disagreement_ratio:.1f}x, which is a strong sign of false-positive cone calibration.",
                )

            borderline_multi_cone_review = (
                cal.num_cones_used >= gates.min_unique_cones_block
                and cal.num_cones_used <= gates.max_review_grade_unique_cones
                and (
                    cal.confidence < gates.min_verified_calibration_confidence
                    or (
                        cal.scale_disagreement_ratio is not None
                        and cal.scale_disagreement_ratio > gates.max_verified_scale_disagreement
                    )
                )
            )
            if borderline_multi_cone_review:
                result.review_grade = True
                self._add_warning(
                    result,
                    "Scale calibration passed the minimum gates, but the confidence is still too limited for a fully "
                    "verified label. Treat this as review-grade and cross-check before client-facing reporting.",
                )

            if cal.scale_disagreement_ratio:
                if cal.scale_disagreement_ratio > gates.max_scale_disagreement_block:
                    self._add_blocker(
                        result,
                        f"Scale cross-checks disagree by {cal.scale_disagreement_ratio:.1f}x, so the run should not be trusted.",
                    )
                elif cal.scale_disagreement_ratio > gates.max_scale_disagreement_warn:
                    self._add_warning(
                        result,
                        f"Scale cross-checks disagree by {cal.scale_disagreement_ratio:.1f}x, so the result should be verified carefully.",
                    )
        elif result.calibration is None and not manual_scale:
            self._add_blocker(
                result,
                "No cone-based scale calibration was available, so the measurement is still in raw COLMAP units.",
            )
        elif manual_scale:
            self._add_warning(
                result,
                "Manual scale override was used. Confirm the reference distance before reporting the result.",
            )

        if vol:
            if vol.grid_occupancy_pct < gates.min_grid_occupancy_block_pct:
                self._add_blocker(
                    result,
                    f"Only {vol.grid_occupancy_pct:.1f}% of grid cells had observed pile data; the volume is dominated by interpolation.",
                )
            elif vol.grid_occupancy_pct < gates.min_grid_occupancy_warn_pct:
                self._add_warning(
                    result,
                    f"Only {vol.grid_occupancy_pct:.1f}% of grid cells had observed pile data; the volume should be cross-checked.",
                )

            if vol.grid_to_hull_ratio is not None:
                if vol.grid_to_hull_ratio > gates.max_grid_to_hull_block_ratio:
                    self._add_blocker(
                        result,
                        f"Grid volume is {vol.grid_to_hull_ratio:.1f}x the convex hull volume, which indicates runaway extrapolation.",
                    )
                elif vol.grid_to_hull_ratio > gates.max_grid_to_hull_warn_ratio:
                    self._add_warning(
                        result,
                        f"Grid volume is {vol.grid_to_hull_ratio:.1f}x the convex hull volume; edge interpolation may be inflating the estimate.",
                    )
                    if (
                        pile_height > gates.tall_pile_warn_m
                        and vol.grid_to_hull_ratio >= gates.tall_pile_grid_to_hull_block_ratio
                    ):
                        self._add_blocker(
                            result,
                            "The reconstruction shows a tall pile together with strong grid/hull inflation, "
                            "which is a high-risk instability pattern.",
                        )

            if vol.recommended_note:
                self._add_warning(result, vol.recommended_note)

        # Keep the verified label strict: warnings stay publishable, but are review-grade.
        if result.quality_warnings and not result.quality_blockers:
            result.review_grade = True

        if result.quality_blockers:
            result.review_grade = False

        result.publishable = not result.quality_blockers

    def run(self, video_path: str | Path) -> PipelineResult:
        """Run the full pipeline on a video file."""
        video_path = Path(video_path)
        result = PipelineResult()

        try:
            # P3 determinism: seed everything up-front so cone ordering,
            # RANSAC initialisers, and any random draws across the pipeline
            # start from the same state for a given config. Note that
            # COLMAP's CUDA kernels remain nondeterministic regardless.
            seed = int(self.config.colmap.random_seed)
            random.seed(seed)
            np.random.seed(seed)
            try:
                o3d.utility.random.seed(seed)
            except Exception:
                # Older Open3D builds may not expose random.seed; non-fatal.
                pass

            # Setup workspace
            self.config.workspace.mkdir(parents=True, exist_ok=True)
            self.config.images_dir.mkdir(parents=True, exist_ok=True)
            self.config.output_dir.mkdir(parents=True, exist_ok=True)

            # Stage 1: Frame Extraction
            result.stage = "frame_extraction"
            self._report("frame_extraction", 0, "Extracting frames from video...")
            self._check_cancel()

            frame_paths = extract_frames(
                video_path,
                self.config.images_dir,
                self.config.frame_extraction,
                progress_callback=lambda p: self._report("frame_extraction", p * 0.9),
            )
            result.num_frames = len(frame_paths)
            self._report("frame_extraction", 1.0, f"Extracted {len(frame_paths)} frames")

            if not frame_paths:
                raise RuntimeError("No frames extracted from video")

            # Stage 2: Cone Detection
            result.stage = "cone_detection"
            self._report("cone_detection", 0, "Detecting cones...")
            self._check_cancel()

            cone_detections = detect_cones_in_frames(
                frame_paths,
                self.config.cone_detection,
                progress_callback=lambda p: self._report("cone_detection", p * 0.9),
            )
            result.num_frames_with_cones = len(cone_detections)
            self._report("cone_detection", 1.0,
                         f"Found cones in {len(cone_detections)} frames")

            if not cone_detections:
                logger.warning("No cones detected — scale calibration will not be possible")

            # Stage 3: COLMAP Reconstruction
            result.stage = "colmap_reconstruction"
            self._report("colmap_reconstruction", 0, "Running COLMAP sparse reconstruction...")
            self._check_cancel()

            # Clear stale COLMAP workspace so we always do a fresh reconstruction
            if self.config.colmap_dir.exists():
                shutil.rmtree(self.config.colmap_dir)
            self.config.colmap_dir.mkdir(parents=True)

            model_dir = run_colmap_reconstruction(
                self.config.images_dir,
                self.config.colmap_dir,
                self.config.colmap,
                progress_callback=lambda p: self._report("colmap_reconstruction", p),
                priority_frame_names=set(cone_detections.keys()) if cone_detections else None,
            )
            result.sparse_model_dir = model_dir

            # Export PLY
            ply_path = self.config.output_dir / "sparse.ply"
            export_to_ply(model_dir, ply_path, self.config.colmap.colmap_binary)
            result.ply_path = ply_path

            # Parse COLMAP binary files
            cameras = read_cameras_binary(model_dir / "cameras.bin")
            images = read_images_binary(model_dir / "images.bin")
            points3d = read_points3d_binary(model_dir / "points3D.bin")
            result.num_colmap_points = len(points3d)
            result.num_colmap_images = len(images)

            # P9 reconstruction-coverage tracking. We count how many images
            # were actually submitted to COLMAP (i.e. after subsampling) so
            # the UI can warn when the sparse model registered only a
            # fraction of them.
            subset_dir = self.config.images_dir.parent / "images_colmap_subset"
            if subset_dir.exists() and subset_dir.is_dir():
                submitted = sum(
                    1 for p in subset_dir.iterdir()
                    if p.suffix.lower() in (".jpg", ".jpeg", ".png")
                )
            else:
                submitted = len(images)
            result.num_colmap_images_submitted = submitted
            if submitted > 0:
                result.colmap_registration_ratio = len(images) / submitted
            else:
                result.colmap_registration_ratio = None

            cone_stats = summarize_cone_observations(
                cone_detections,
                {image.name for image in images.values()},
            )

            self._report("colmap_reconstruction", 1.0,
                         f"{len(points3d)} 3D points, {len(images)} images registered")

            if not points3d:
                raise RuntimeError("COLMAP produced no 3D points")

            # Stage 4: Scale Calibration
            result.stage = "scale_calibration"
            self._report("scale_calibration", 0, "Calibrating scale from cones...")
            self._check_cancel()

            if self.config.manual_scale_override is not None:
                scale_factor = self.config.manual_scale_override
                result.scale_source = "manual_override"
                if cone_detections:
                    try:
                        calibration = calibrate_scale(
                            cone_detections, images, points3d,
                            self.config.scale_calibration, cameras,
                        )
                        self._populate_calibration_diagnostics(calibration, cone_stats)
                        result.calibration = calibration
                        result.cone_3d_positions = calibration.cone_3d_positions
                    except Exception:
                        pass
                result.scale_factor_m_per_unit = scale_factor
                self._report("scale_calibration", 1.0,
                             f"Manual scale override: {scale_factor:.4f} m/unit")
            elif cone_detections:
                calibration = calibrate_scale(
                    cone_detections, images, points3d,
                    self.config.scale_calibration, cameras,
                )
                self._populate_calibration_diagnostics(calibration, cone_stats)
                result.calibration = calibration
                result.cone_3d_positions = calibration.cone_3d_positions

                # P5: if the dedup step found more unique cones than the
                # ceiling, the detector is eating the pile texture (e.g.
                # reddish aggregate).  Override calibration to unit-scale
                # and let the quality gates block the result.
                cones_ceiling = int(getattr(
                    self.config.cone_detection, "max_unique_cones_ceiling", 8
                ))
                if calibration.num_cones_used > cones_ceiling:
                    logger.warning(
                        "Cone dedup produced %d unique cones (ceiling %d) — "
                        "treating entire detection as false-positive saturation.",
                        calibration.num_cones_used,
                        cones_ceiling,
                    )
                    # Keep the calibration object for diagnostics, but
                    # zero out its confidence so the gates block it.
                    calibration.confidence = 0.0
                    calibration.notes.append(
                        f"Detector saturation: {calibration.num_cones_used} unique cones "
                        f"exceed the {cones_ceiling}-cone ceiling. Scale is unreliable."
                    )

                scale_factor = calibration.scale_factor
                result.scale_factor_m_per_unit = scale_factor
                result.scale_source = calibration.selected_method
                self._report("scale_calibration", 1.0,
                             f"Scale: {scale_factor:.4f} m/unit, confidence: {calibration.confidence:.2f}")
            else:
                scale_factor = 1.0
                result.scale_factor_m_per_unit = scale_factor
                result.scale_source = "unit_scale"
                self._report("scale_calibration", 1.0,
                             "No cones — using unit scale (results in COLMAP units)")

            # Stage 5: Ground Plane & Segmentation
            result.stage = "ground_plane"
            self._report("ground_plane", 0, "Fitting ground plane...")
            self._check_cancel()

            all_xyz = np.array([p.xyz for p in points3d.values()])
            all_rgb = np.array([p.rgb for p in points3d.values()])

            pcd = load_and_scale_point_cloud(all_xyz, all_rgb, scale_factor)

            # Transform cone positions to scaled coordinates. Only use them for
            # segmentation/cropping when the calibration references themselves
            # look stable enough; otherwise they can cut away good geometry.
            scaled_cone_positions = [pos * scale_factor for pos in result.cone_3d_positions]
            segmentation_cone_positions = (
                scaled_cone_positions if self._should_use_cone_positions_for_segmentation(result.calibration) else None
            )
            if scaled_cone_positions and segmentation_cone_positions is None and result.calibration:
                self._append_calibration_note(
                    result.calibration,
                    "Cone positions were ignored for ground alignment and footprint cropping because the calibration references were not stable enough.",
                )

            gp_result = segment_pile(pcd, self.config.ground_plane, segmentation_cone_positions)
            result.pile_cloud = gp_result.pile_cloud
            result.ground_cloud = gp_result.ground_cloud

            # Update cone positions to transformed coordinates
            if segmentation_cone_positions:
                T = gp_result.transform_matrix
                result.cone_3d_positions = []
                for pos in segmentation_cone_positions:
                    p = np.append(pos, 1.0)
                    result.cone_3d_positions.append((T @ p)[:3])
            else:
                result.cone_3d_positions = []

            self._report("ground_plane", 1.0,
                         f"{len(gp_result.pile_cloud.points)} pile points segmented")

            # Stage 6: Volume Computation
            result.stage = "volume_computation"
            self._report("volume_computation", 0, "Computing volume...")
            self._check_cancel()

            vol = compute_volume(
                gp_result.pile_cloud,
                self.config.volume,
                result.cone_3d_positions if result.cone_3d_positions else None,
                gp_result.full_cloud_transformed,
            )
            result.volume = vol
            result.weight_kg = vol.recommended_m3 * self.config.material_density
            self._assess_measurement_quality(result)

            if result.publishable and result.review_grade:
                self._report(
                    "volume_computation",
                    1.0,
                    f"Review-grade volume: {vol.recommended_m3:.2f} m³, Weight: {result.weight_kg:.0f} kg",
                )
            elif result.publishable:
                self._report("volume_computation", 1.0,
                             f"Volume: {vol.recommended_m3:.2f} m³, Weight: {result.weight_kg:.0f} kg")
            else:
                self._report(
                    "volume_computation",
                    1.0,
                    "Measurement flagged for review: " + "; ".join(result.quality_blockers[:2]),
                )

            result.stage = "complete"

        except Exception as e:
            result.error = str(e)
            result.publishable = False
            result.review_grade = False
            if not result.quality_blockers:
                result.quality_blockers.append(
                    f"Pipeline failed at stage '{result.stage or 'unknown'}': {result.error}"
                )
            logger.exception("Pipeline failed at stage '%s'", result.stage)

        return result
