"""Pipeline orchestrator wiring all stages together."""

import inspect
import logging
import math
import random
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

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
from .frame_extraction import extract_frames, get_video_info
from .tagged_reference_detection import detect_tagged_references_in_frames
from .ground_plane import load_and_scale_point_cloud, segment_pile
from .scale_calibration import CalibrationResult, calibrate_scale
from .volume import VolumeResult, compute_volume

logger = logging.getLogger(__name__)


@dataclass
class PipelineResult:
    num_frames: int = 0
    num_frames_with_cones: int = 0
    num_frames_with_tagged_references: int = 0
    num_colmap_points: int = 0
    num_colmap_images: int = 0
    num_colmap_images_submitted: int = 0
    colmap_registration_ratio: float | None = None
    calibration: CalibrationResult | None = None
    volume: VolumeResult | None = None
    weight_kg: float = 0.0
    scale_factor_m_per_unit: float | None = None
    scale_source: str = "auto"
    reference_strategy: str = "cones"
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


@dataclass(frozen=True)
class MobileCapturePriorHints:
    """Resolved mobile-capture priors used to bias the pipeline."""

    source_label: str = "mobile priors"
    frame_names: tuple[str, ...] = ()
    preferred_timestamps_sec: tuple[float, ...] = ()
    extraction_interval_sec: float | None = None
    max_frames: int | None = None
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
    calibration_note: str | None = None
    result_note: str | None = None

    @property
    def active(self) -> bool:
        return bool(
            self.frame_names
            or self.preferred_timestamps_sec
            or self.extraction_interval_sec is not None
            or self.max_frames is not None
            or self.reference_evidence_count
            or self.pose_sample_count
            or self.useful_pose_sample_count
            or self.depth_data_included is not None
            or self.pile_segmentation_score is not None
            or self.toe_segmentation_score is not None
            or self.segmentation_confidence_score is not None
            or self.quick_volume_m3 is not None
            or self.quick_footprint_area_m2 is not None
            or self.quick_peak_height_m is not None
            or self.quick_confidence_score is not None
            or self.quick_geometry_point_count is not None
            or self.quick_camera_path_distance_m is not None
            or self.calibration_note
            or self.result_note
        )


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

    def _mobile_priors_payload(self) -> Any | None:
        for attr in (
            "mobile_capture_priors",
            "mobile_priors",
            "capture_priors",
            "mobile_capture_prior",
        ):
            payload = getattr(self.config, attr, None)
            if payload:
                return payload
        return None

    def _payload_mapping(self, payload: Any) -> dict[str, Any]:
        if payload is None:
            return {}
        if isinstance(payload, dict):
            return dict(payload)
        if hasattr(payload, "_asdict"):
            try:
                return dict(payload._asdict())
            except Exception:
                pass
        try:
            return dict(vars(payload))
        except Exception:
            return {}

    def _first_payload_value(self, payload: dict[str, Any], *keys: str) -> Any | None:
        for key in keys:
            if key in payload and payload[key] is not None:
                value = payload[key]
                if isinstance(value, str):
                    value = value.strip()
                    if not value:
                        continue
                return value
        return None

    def _float_tuple_from_payload(self, payload: dict[str, Any], *keys: str) -> tuple[float, ...]:
        raw = self._first_payload_value(payload, *keys)
        if raw is None:
            return ()
        if isinstance(raw, (str, bytes)):
            candidates = [raw]
        else:
            try:
                candidates = list(raw)
            except TypeError:
                candidates = [raw]

        normalized: list[float] = []
        for candidate in candidates:
            try:
                value = float(candidate)
            except (TypeError, ValueError):
                continue
            if value < 0:
                continue
            if value not in normalized:
                normalized.append(value)
        return tuple(sorted(normalized))

    def _int_from_payload(
        self,
        payload: dict[str, Any],
        *keys: str,
    ) -> int | None:
        value = self._first_payload_value(payload, *keys)
        if value is None:
            return None
        try:
            return max(0, int(value))
        except (TypeError, ValueError):
            return None

    def _ratio_from_payload(self, payload: dict[str, Any], *keys: str) -> float | None:
        value = self._first_payload_value(payload, *keys)
        if value is None:
            return None
        try:
            parsed = float(value)
        except (TypeError, ValueError):
            return None
        if not math.isfinite(parsed):
            return None
        return max(0.0, min(1.0, parsed))

    def _positive_float_from_payload(self, payload: dict[str, Any], *keys: str) -> float | None:
        value = self._first_payload_value(payload, *keys)
        if value is None:
            return None
        try:
            parsed = float(value)
        except (TypeError, ValueError):
            return None
        if not math.isfinite(parsed) or parsed <= 0:
            return None
        return parsed

    def _coerce_mobile_prior_hints(self) -> MobileCapturePriorHints | None:
        payload = self._mobile_priors_payload()
        if payload is None:
            return None

        mapping = self._payload_mapping(payload)
        if not mapping:
            return MobileCapturePriorHints()

        raw_names = self._first_payload_value(
            mapping,
            "priority_frame_names",
            "priorityFrames",
            "priority_frames",
            "frame_names",
            "frameNames",
            "preferred_frame_names",
            "preferredFrameNames",
            "colmap_priority_frame_names",
            "colmapPriorityFrameNames",
        )
        frame_names: tuple[str, ...] = ()
        if raw_names is not None:
            if isinstance(raw_names, (str, bytes)):
                candidates = [raw_names]
            else:
                candidates = list(raw_names)
            normalized_names = []
            for candidate in candidates:
                name = Path(str(candidate)).name.strip()
                if name and name not in normalized_names:
                    normalized_names.append(name)
            frame_names = tuple(normalized_names)

        reference_evidence_timestamps_sec = self._float_tuple_from_payload(
            mapping,
            "reference_evidence_timestamps_sec",
            "referenceEvidenceTimestampsSec",
        )
        useful_pose_sample_timestamps_sec = self._float_tuple_from_payload(
            mapping,
            "useful_pose_sample_timestamps_sec",
            "usefulPoseSampleTimestampsSec",
        )
        preferred_timestamps_sec = tuple(
            sorted(
                set(reference_evidence_timestamps_sec).union(
                    useful_pose_sample_timestamps_sec,
                )
            )
        )

        interval_value = self._first_payload_value(
            mapping,
            "frame_extraction_interval_sec",
            "frameExtractionIntervalSec",
            "extraction_interval_sec",
            "extractionIntervalSec",
            "frame_interval_sec",
            "frameIntervalSec",
            "preferred_frame_interval_sec",
            "preferredFrameIntervalSec",
        )
        extraction_interval_sec: float | None = None
        if interval_value is not None:
            try:
                extraction_interval_sec = float(interval_value)
            except (TypeError, ValueError):
                extraction_interval_sec = None
            if extraction_interval_sec is not None and extraction_interval_sec <= 0:
                extraction_interval_sec = None

        max_frames_value = self._first_payload_value(
            mapping,
            "frame_extraction_max_frames",
            "frameExtractionMaxFrames",
            "extraction_max_frames",
            "extractionMaxFrames",
            "max_frames",
            "maxFrames",
            "preferred_max_frames",
            "preferredMaxFrames",
        )
        max_frames: int | None = None
        if max_frames_value is not None:
            try:
                max_frames = max(1, int(max_frames_value))
            except (TypeError, ValueError):
                max_frames = None

        note = self._first_payload_value(
            mapping,
            "note",
            "notes",
            "result_note",
            "resultNote",
            "calibration_note",
            "calibrationNote",
            "message",
            "summary",
        )
        if isinstance(note, (list, tuple, set)):
            note = "; ".join(str(item).strip() for item in note if str(item).strip())
        if note is not None:
            note = str(note).strip() or None

        calibration_note = self._first_payload_value(
            mapping,
            "calibration_note",
            "calibrationNote",
        )
        if calibration_note is not None:
            calibration_note = str(calibration_note).strip() or None

        result_note = self._first_payload_value(
            mapping,
            "result_note",
            "resultNote",
        )
        if result_note is not None:
            result_note = str(result_note).strip() or None

        if note and calibration_note is None:
            calibration_note = note
        if note and result_note is None:
            result_note = note

        reference_evidence_count = self._int_from_payload(
            mapping,
            "reference_evidence_count",
            "referenceEvidenceCount",
        )
        if reference_evidence_count is None:
            reference_evidence_count = len(reference_evidence_timestamps_sec)

        pose_sample_count = self._int_from_payload(
            mapping,
            "pose_sample_count",
            "poseSampleCount",
        )
        if pose_sample_count is None:
            pose_sample_count = len(useful_pose_sample_timestamps_sec)

        useful_pose_sample_count = self._int_from_payload(
            mapping,
            "useful_pose_sample_count",
            "usefulPoseSampleCount",
        )
        if useful_pose_sample_count is None:
            useful_pose_sample_count = len(useful_pose_sample_timestamps_sec)

        depth_data_included = self._first_payload_value(
            mapping,
            "depth_data_included",
            "depthDataIncluded",
        )
        if depth_data_included is not None:
            depth_data_included = bool(depth_data_included)

        pile_segmentation_score = self._ratio_from_payload(
            mapping,
            "pile_segmentation_score",
            "pileSegmentationScore",
        )
        toe_segmentation_score = self._ratio_from_payload(
            mapping,
            "toe_segmentation_score",
            "toeSegmentationScore",
        )
        segmentation_confidence_score = self._ratio_from_payload(
            mapping,
            "segmentation_confidence_score",
            "segmentationConfidenceScore",
        )
        quick_volume_m3 = self._positive_float_from_payload(
            mapping,
            "quick_volume_m3",
            "quickVolumeM3",
        )
        quick_footprint_area_m2 = self._positive_float_from_payload(
            mapping,
            "quick_footprint_area_m2",
            "quickFootprintAreaM2",
        )
        quick_peak_height_m = self._positive_float_from_payload(
            mapping,
            "quick_peak_height_m",
            "quickPeakHeightM",
        )
        quick_confidence_score = self._ratio_from_payload(
            mapping,
            "quick_confidence_score",
            "quickConfidenceScore",
        )
        quick_geometry_point_count = self._int_from_payload(
            mapping,
            "quick_geometry_point_count",
            "quickGeometryPointCount",
        )
        quick_camera_path_distance_m = self._positive_float_from_payload(
            mapping,
            "quick_camera_path_distance_m",
            "quickCameraPathDistanceM",
        )

        if not (
            frame_names
            or preferred_timestamps_sec
            or extraction_interval_sec is not None
            or max_frames is not None
            or reference_evidence_count
            or pose_sample_count
            or useful_pose_sample_count
            or depth_data_included is not None
            or pile_segmentation_score is not None
            or toe_segmentation_score is not None
            or segmentation_confidence_score is not None
            or quick_volume_m3 is not None
            or quick_footprint_area_m2 is not None
            or quick_peak_height_m is not None
            or quick_confidence_score is not None
            or quick_geometry_point_count is not None
            or quick_camera_path_distance_m is not None
            or calibration_note
            or result_note
        ):
            return None

        return MobileCapturePriorHints(
            source_label=str(self._first_payload_value(mapping, "source_label", "sourceLabel", "basis", "source") or "mobile priors"),
            frame_names=frame_names,
            preferred_timestamps_sec=preferred_timestamps_sec,
            extraction_interval_sec=extraction_interval_sec,
            max_frames=max_frames,
            reference_evidence_count=reference_evidence_count,
            pose_sample_count=pose_sample_count,
            useful_pose_sample_count=useful_pose_sample_count,
            depth_data_included=depth_data_included,
            pile_segmentation_score=pile_segmentation_score,
            toe_segmentation_score=toe_segmentation_score,
            segmentation_confidence_score=segmentation_confidence_score,
            quick_volume_m3=quick_volume_m3,
            quick_footprint_area_m2=quick_footprint_area_m2,
            quick_peak_height_m=quick_peak_height_m,
            quick_confidence_score=quick_confidence_score,
            quick_geometry_point_count=quick_geometry_point_count,
            quick_camera_path_distance_m=quick_camera_path_distance_m,
            calibration_note=calibration_note,
            result_note=result_note,
        )

    def _resolve_frame_extraction_config(
        self,
        priors: MobileCapturePriorHints | None,
    ):
        base = self.config.frame_extraction
        if priors is None:
            return base

        interval_sec = base.interval_sec
        max_frames = base.max_frames

        if priors.extraction_interval_sec is not None:
            interval_sec = priors.extraction_interval_sec
        if priors.max_frames is not None:
            max_frames = priors.max_frames

        return type(base)(
            interval_sec=interval_sec,
            max_frames=max_frames,
            output_format=base.output_format,
            jpeg_quality=base.jpeg_quality,
        )

    def _mobile_prior_bias_factor(self, priors: MobileCapturePriorHints | None) -> float:
        if priors is None:
            return 1.0
        if priors.extraction_interval_sec is not None or priors.max_frames is not None:
            return 1.0

        payload = self._payload_mapping(self._mobile_priors_payload())
        if not payload:
            return 1.0

        scores: list[float] = []
        for key in (
            "motion_stability_score",
            "motionStabilityScore",
            "toe_coverage_score",
            "toeCoverageScore",
            "pile_segmentation_score",
            "pileSegmentationScore",
            "toe_segmentation_score",
            "toeSegmentationScore",
            "segmentation_confidence_score",
            "segmentationConfidenceScore",
            "quick_confidence_score",
            "quickConfidenceScore",
            "perimeter_coverage_score",
            "perimeterCoverageScore",
        ):
            value = payload.get(key)
            if value is None:
                continue
            try:
                scores.append(max(0.0, min(1.0, float(value))))
            except (TypeError, ValueError):
                continue

        if not scores:
            return 1.0

        average_score = sum(scores) / len(scores)
        # Low-confidence mobile capture priors get a mild extraction-density boost.
        return 1.0 + max(0.0, 0.75 - average_score) * 0.35

    def _mobile_prior_note(self, priors: MobileCapturePriorHints | None) -> str | None:
        if priors is None:
            return None

        parts: list[str] = []
        if priors.preferred_timestamps_sec:
            anchors: list[str] = []
            if priors.reference_evidence_count:
                anchors.append(
                    f"{priors.reference_evidence_count} evidence frame(s)"
                )
            if priors.useful_pose_sample_count:
                anchors.append(
                    f"{priors.useful_pose_sample_count} stable ARKit pose anchor(s)"
                )
            if anchors:
                parts.append(
                    "biased frame extraction toward "
                    + " and ".join(anchors)
                )
            else:
                parts.append(
                    f"biased frame extraction toward {len(priors.preferred_timestamps_sec)} mobile timestamp anchor(s)"
                )
        if priors.frame_names:
            preview = ", ".join(priors.frame_names[:5])
            if len(priors.frame_names) > 5:
                preview += f", +{len(priors.frame_names) - 5} more"
            parts.append(f"prioritized {len(priors.frame_names)} frame(s) for COLMAP ({preview})")
        if priors.extraction_interval_sec is not None:
            parts.append(f"set frame extraction interval to {priors.extraction_interval_sec:.3f}s")
        if priors.max_frames is not None:
            parts.append(f"capped extracted frames at {priors.max_frames}")
        if priors.depth_data_included is True:
            parts.append("capture reported on-device depth support")
        segmentation_scores: list[str] = []
        if priors.pile_segmentation_score is not None:
            segmentation_scores.append(f"pile={priors.pile_segmentation_score:.2f}")
        if priors.toe_segmentation_score is not None:
            segmentation_scores.append(f"toe={priors.toe_segmentation_score:.2f}")
        if priors.segmentation_confidence_score is not None:
            segmentation_scores.append(f"confidence={priors.segmentation_confidence_score:.2f}")
        if segmentation_scores:
            parts.append("used on-device segmentation priors (" + ", ".join(segmentation_scores) + ")")
        if priors.quick_volume_m3 is not None:
            quick_parts = [f"quick volume={priors.quick_volume_m3:.2f} m³"]
            if priors.quick_confidence_score is not None:
                quick_parts.append(f"confidence={priors.quick_confidence_score:.2f}")
            if priors.quick_geometry_point_count is not None:
                quick_parts.append(f"{priors.quick_geometry_point_count:,} depth points")
            parts.append("received phone quick solve (" + ", ".join(quick_parts) + ")")

        if not parts:
            payload = self._payload_mapping(self._mobile_priors_payload())
            if not payload:
                return None
            scores: list[str] = []
            for key, label in (
                ("motion_stability_score", "motion stability"),
                ("motionStabilityScore", "motion stability"),
                ("toe_coverage_score", "toe coverage"),
                ("toeCoverageScore", "toe coverage"),
                ("perimeter_coverage_score", "perimeter coverage"),
                ("perimeterCoverageScore", "perimeter coverage"),
            ):
                value = payload.get(key)
                if value is None:
                    continue
                try:
                    scores.append(f"{label}={float(value):.2f}")
                except (TypeError, ValueError):
                    continue
            if scores:
                parts.append("used capture-quality priors (" + ", ".join(scores) + ")")

        if not parts:
            return None
        return f"Mobile capture priors applied: {'; '.join(parts)}."

    def _mobile_priority_frame_names(
        self,
        priors: MobileCapturePriorHints | None,
        *,
        video_path: Path,
        extracted_frame_paths: list[Path],
        output_format: str,
    ) -> set[str]:
        if priors is None or not priors.preferred_timestamps_sec:
            return set()

        try:
            fps = float(get_video_info(video_path).get("fps") or 0.0)
        except Exception:
            logger.warning("Unable to derive video FPS for mobile-prior frame mapping", exc_info=True)
            return set()
        if fps <= 0:
            return set()

        extracted_names = {path.name for path in extracted_frame_paths}
        priority_names: set[str] = set()
        for timestamp_sec in priors.preferred_timestamps_sec:
            frame_index = int(math.floor(float(timestamp_sec) * fps + 0.5))
            frame_name = f"frame_{frame_index:05d}.{output_format}"
            if frame_name in extracted_names:
                priority_names.add(frame_name)
        return priority_names

    def _mobile_prior_result_note(self, priors: MobileCapturePriorHints | None) -> str | None:
        if priors is None:
            return None
        if priors.result_note:
            return priors.result_note
        if priors.calibration_note:
            return priors.calibration_note
        return self._mobile_prior_note(priors)

    def _mobile_prior_note_for_calibration(self, priors: MobileCapturePriorHints | None) -> str | None:
        if priors is None:
            return None
        if priors.calibration_note:
            return priors.calibration_note
        if priors.result_note:
            return priors.result_note
        return self._mobile_prior_note(priors)

    def _coerce_positive_float(self, value: Any) -> float | None:
        try:
            parsed = float(value)
        except (TypeError, ValueError):
            return None
        if not math.isfinite(parsed) or parsed <= 0:
            return None
        return parsed

    def _capture_video_frame_rate(self) -> float | None:
        capture_metadata = getattr(self.config, "capture_metadata", None)
        sensor_metadata = (
            None if capture_metadata is None else getattr(capture_metadata, "sensor_metadata", None)
        )
        if sensor_metadata is None:
            return None
        return self._coerce_positive_float(getattr(sensor_metadata, "video_frame_rate", None))

    def _calibration_video_frame_rate(self, video_path: Path) -> float | None:
        capture_fps = self._capture_video_frame_rate()
        if capture_fps is not None:
            return capture_fps

        try:
            video_info = get_video_info(video_path)
        except Exception:
            logger.warning(
                "Unable to derive video FPS for mobile calibration context",
                exc_info=True,
            )
            return None
        return self._coerce_positive_float(video_info.get("fps"))

    def _mobile_calibration_context(self, *, video_path: Path) -> dict[str, Any] | None:
        pose_samples = getattr(self.config, "pose_samples", None)
        if pose_samples is None:
            normalized_pose_samples: tuple[Any, ...] = ()
        else:
            try:
                normalized_pose_samples = tuple(pose_samples)
            except TypeError:
                normalized_pose_samples = ()

        capture_metadata = getattr(self.config, "capture_metadata", None)
        video_frame_rate = self._calibration_video_frame_rate(video_path)
        mobile_capture_prior = getattr(self.config, "mobile_capture_prior", None)
        reference_evidence_frames = getattr(self.config, "reference_evidence_frames", None)
        reference_observations = getattr(self.config, "reference_observations", None)

        if (
            not normalized_pose_samples
            and capture_metadata is None
            and video_frame_rate is None
            and mobile_capture_prior is None
            and reference_evidence_frames is None
            and reference_observations is None
        ):
            return None

        context: dict[str, Any] = {
            "pose_samples": normalized_pose_samples,
            "capture_metadata": capture_metadata,
            "video_frame_rate": video_frame_rate,
            "mobile_capture_prior": mobile_capture_prior,
        }
        if reference_evidence_frames is not None:
            try:
                context["reference_evidence_frames"] = tuple(reference_evidence_frames)
            except TypeError:
                context["reference_evidence_frames"] = ()
        if reference_observations is not None:
            try:
                context["reference_observations"] = tuple(reference_observations)
            except TypeError:
                context["reference_observations"] = ()
        return context

    def _supported_calibration_kwargs(self, calibration_kwargs: dict[str, Any]) -> dict[str, Any]:
        if not calibration_kwargs:
            return {}
        try:
            signature = inspect.signature(calibrate_scale)
        except (TypeError, ValueError):
            return {}

        accepts_var_kwargs = any(
            parameter.kind == inspect.Parameter.VAR_KEYWORD
            for parameter in signature.parameters.values()
        )
        if accepts_var_kwargs:
            return {
                key: value
                for key, value in calibration_kwargs.items()
                if value is not None
            }
        return {
            key: value
            for key, value in calibration_kwargs.items()
            if key in signature.parameters and value is not None
        }

    def _run_scale_calibration(
        self,
        cone_detections: dict[str, list],
        images: dict[int, Any],
        points3d: dict[int, Any],
        cameras: dict[int, Any] | None,
        tagged_reference_detections: dict[str, list] | None,
        *,
        video_path: Path,
    ) -> CalibrationResult:
        mobile_calibration_context = self._mobile_calibration_context(video_path=video_path)
        extra_kwargs: dict[str, Any] = {}
        if mobile_calibration_context is not None:
            extra_kwargs.update(mobile_calibration_context)
            extra_kwargs["mobile_upload_context"] = dict(mobile_calibration_context)

        return calibrate_scale(
            cone_detections,
            images,
            points3d,
            self.config.scale_calibration,
            cameras,
            tagged_reference_detections,
            self.config.tagged_references,
            **self._supported_calibration_kwargs(extra_kwargs),
        )

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

    def _resolved_mobile_segmentation_confidence(
        self,
        priors: MobileCapturePriorHints | None,
    ) -> float | None:
        if priors is None:
            return None
        if priors.segmentation_confidence_score is not None:
            return priors.segmentation_confidence_score
        scores = [
            score
            for score in (
                priors.pile_segmentation_score,
                priors.toe_segmentation_score,
            )
            if score is not None
        ]
        if not scores:
            return None
        return sum(scores) / len(scores)

    def _apply_mobile_segmentation_consistency(
        self,
        result: PipelineResult,
        priors: MobileCapturePriorHints | None,
    ):
        if priors is None:
            return

        if priors.toe_segmentation_score is not None and priors.toe_segmentation_score < 0.42:
            self._add_warning(
                result,
                "On-device toe segmentation was weak, so the pile edge should be reviewed against the capture video before reporting.",
            )

        if priors.pile_segmentation_score is not None and priors.pile_segmentation_score < 0.38:
            self._add_warning(
                result,
                "On-device pile segmentation was weak, so the reconstructed pile surface should be reviewed before reporting.",
            )

        if result.volume is None or priors.quick_volume_m3 is None:
            return

        backend_volume_m3 = self._coerce_positive_float(result.volume.recommended_m3)
        phone_volume_m3 = self._coerce_positive_float(priors.quick_volume_m3)
        if backend_volume_m3 is None or phone_volume_m3 is None:
            return

        quick_confidence = priors.quick_confidence_score or 0.0
        segmentation_confidence = self._resolved_mobile_segmentation_confidence(priors) or 0.0
        if quick_confidence < 0.65 or segmentation_confidence < 0.60:
            return

        disagreement = abs(backend_volume_m3 - phone_volume_m3) / max(
            backend_volume_m3,
            phone_volume_m3,
            1e-6,
        )
        message = (
            "Backend volume and on-device segmentation quick volume disagrees by "
            f"{disagreement:.0%} (backend {backend_volume_m3:.2f} m³ vs phone "
            f"{phone_volume_m3:.2f} m³) despite strong native confidence; review the "
            "segmentation/scale before releasing this measurement."
        )
        if disagreement > 0.45:
            self._add_blocker(result, message)
        elif disagreement > 0.25:
            self._add_warning(result, message)

    def _assess_measurement_quality(
        self,
        result: PipelineResult,
        mobile_priors: MobileCapturePriorHints | None = None,
    ):
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

            footprint_source = getattr(vol, "footprint_source", None)
            if footprint_source in gates.weak_footprint_warn_sources:
                footprint_label = footprint_source.replace("_", " ")
                toe_candidate_points = int(getattr(vol, "toe_candidate_points", 0) or 0)
                if toe_candidate_points > 0:
                    self._add_warning(
                        result,
                        f"Volume footprint fell back to {footprint_label} instead of a toe-constrained outline; "
                        f"only {toe_candidate_points:,} low-height toe candidates were available, so the pile edge should be reviewed before reporting.",
                    )
                else:
                    self._add_warning(
                        result,
                        f"Volume footprint fell back to {footprint_label} instead of a toe-constrained outline; "
                        "the pile edge should be reviewed before reporting.",
                    )

        if mobile_priors is None:
            mobile_priors = self._coerce_mobile_prior_hints()
        self._apply_mobile_segmentation_consistency(result, mobile_priors)

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
        result.reference_strategy = (
            "tagged_references"
            if self.config.tagged_references.enabled
            else "cones"
        )
        mobile_priors = self._coerce_mobile_prior_hints()
        mobile_prior_note = self._mobile_prior_result_note(mobile_priors)
        mobile_prior_calibration_note = self._mobile_prior_note_for_calibration(mobile_priors)
        mobile_priority_frame_names: set[str] = set()

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

            frame_extraction_config = self._resolve_frame_extraction_config(mobile_priors)
            if mobile_priors is not None:
                bias_factor = self._mobile_prior_bias_factor(mobile_priors)
                if bias_factor != 1.0 and mobile_priors.extraction_interval_sec is None and mobile_priors.max_frames is None:
                    frame_extraction_config = type(frame_extraction_config)(
                        interval_sec=max(1e-3, frame_extraction_config.interval_sec / bias_factor),
                        max_frames=max(1, int(round(frame_extraction_config.max_frames * bias_factor))),
                        output_format=frame_extraction_config.output_format,
                        jpeg_quality=frame_extraction_config.jpeg_quality,
                    )

            frame_paths = extract_frames(
                video_path,
                self.config.images_dir,
                frame_extraction_config,
                progress_callback=lambda p: self._report("frame_extraction", p * 0.9),
                preferred_timestamps_sec=(
                    mobile_priors.preferred_timestamps_sec if mobile_priors else None
                ),
            )
            mobile_priority_frame_names = self._mobile_priority_frame_names(
                mobile_priors,
                video_path=video_path,
                extracted_frame_paths=frame_paths,
                output_format=frame_extraction_config.output_format,
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

            tagged_reference_detections: dict[str, list] = {}
            if self.config.tagged_references.enabled:
                tagged_reference_detections = detect_tagged_references_in_frames(
                    frame_paths,
                    self.config.tagged_references,
                )
                result.num_frames_with_tagged_references = len(tagged_reference_detections)
                if tagged_reference_detections:
                    logger.info(
                        "Found tagged references in %d frames using family=%s",
                        len(tagged_reference_detections),
                        self.config.tagged_references.family,
                    )
                else:
                    self._add_warning(
                        result,
                        "Tagged references were enabled for this run, but none were recovered from the capture.",
                    )

            if not cone_detections and not tagged_reference_detections:
                logger.warning("No cones or tagged references detected — scale calibration will not be possible")

            # Stage 3: COLMAP Reconstruction
            result.stage = "colmap_reconstruction"
            self._report("colmap_reconstruction", 0, "Running COLMAP sparse reconstruction...")
            self._check_cancel()

            # Clear stale COLMAP workspace so we always do a fresh reconstruction
            if self.config.colmap_dir.exists():
                shutil.rmtree(self.config.colmap_dir)
            self.config.colmap_dir.mkdir(parents=True)

            priority_frame_names = set(cone_detections.keys()) if cone_detections else set()
            if tagged_reference_detections:
                priority_frame_names.update(tagged_reference_detections.keys())
            if mobile_priority_frame_names:
                priority_frame_names.update(mobile_priority_frame_names)
            if mobile_priors and mobile_priors.frame_names:
                priority_frame_names.update(mobile_priors.frame_names)

            model_dir = run_colmap_reconstruction(
                self.config.images_dir,
                self.config.colmap_dir,
                self.config.colmap,
                progress_callback=lambda p: self._report("colmap_reconstruction", p),
                priority_frame_names=priority_frame_names or None,
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
                if cone_detections or tagged_reference_detections:
                    try:
                        calibration = self._run_scale_calibration(
                            cone_detections, images, points3d,
                            cameras,
                            tagged_reference_detections,
                            video_path=video_path,
                        )
                        self._populate_calibration_diagnostics(calibration, cone_stats)
                        result.calibration = calibration
                        result.cone_3d_positions = calibration.cone_3d_positions
                    except Exception:
                        pass
                result.scale_factor_m_per_unit = scale_factor
                self._report("scale_calibration", 1.0,
                             f"Manual scale override: {scale_factor:.4f} m/unit")
            elif cone_detections or tagged_reference_detections:
                calibration = self._run_scale_calibration(
                    cone_detections, images, points3d,
                    cameras,
                    tagged_reference_detections,
                    video_path=video_path,
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

            if mobile_prior_calibration_note and result.calibration:
                self._append_calibration_note(result.calibration, mobile_prior_calibration_note)

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
            self._assess_measurement_quality(result, mobile_priors)

            if mobile_prior_note:
                logger.info("%s", mobile_prior_note)

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
