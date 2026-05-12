"""Background job runtime for the native mobile API flow."""

from __future__ import annotations

import logging
import os
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

from .config import MobileCapturePrior, PipelineConfig, build_mobile_job_pipeline_config
from .mobile_api_models import JobPhase
from .mobile_api_service import MobileAPIValidationError, StockpileMobileAPIService, UploadContext
from .processing_runtime import MobileProcessingRuntimeError, StockpileMobileJobRunner

logger = logging.getLogger(__name__)


class PipelineRunner(Protocol):
    def run(self, video_path: str | Path): ...


PipelineFactory = Callable[[PipelineConfig], PipelineRunner]
PipelineConfigFactory = Callable[[UploadContext], PipelineConfig]


@dataclass(frozen=True)
class StockpileMobileJobRuntimeConfiguration:
    workspace_root: Path

    @classmethod
    def from_environment(cls) -> "StockpileMobileJobRuntimeConfiguration":
        return cls(
            workspace_root=Path(
                os.environ.get(
                    "STOCKPILE_MOBILE_PIPELINE_WORKSPACE_ROOT",
                    "data/mobile_runs",
                )
            )
        )


def _tracking_state_is_stable(state: str | None) -> bool:
    if state is None:
        return True
    normalized = str(state).strip().lower()
    if not normalized:
        return True
    if normalized in {"normal", "tracking", "tracked", "stable"}:
        return True
    return not any(
        token in normalized
        for token in (
            "limited",
            "unavailable",
            "not_available",
            "not available",
            "initializing",
            "relocalizing",
            "lost",
        )
    )


def _evenly_spaced_subset(values: list[float], *, max_count: int) -> tuple[float, ...]:
    if max_count <= 0 or not values:
        return ()
    if len(values) <= max_count:
        return tuple(values)
    if max_count == 1:
        return (float(values[0]),)

    selected: list[float] = []
    limit = len(values) - 1
    for index in range(max_count):
        raw = round(index * limit / (max_count - 1))
        candidate = float(values[raw])
        if not selected or candidate != selected[-1]:
            selected.append(candidate)
    return tuple(selected)


def _stable_pose_sample_timestamps_sec(context: UploadContext) -> tuple[float, ...]:
    upload_request = context.upload_request
    sensor_metadata = (
        None
        if upload_request.capture_metadata is None
        else upload_request.capture_metadata.sensor_metadata
    )
    pose_sampling_hz = (
        None if sensor_metadata is None else sensor_metadata.pose_sampling_hz
    )
    min_spacing_sec = 0.75
    if pose_sampling_hz is not None and pose_sampling_hz > 0:
        min_spacing_sec = max(0.15, 2.0 / float(pose_sampling_hz))

    accepted: list[float] = []
    last_kept: float | None = None
    sorted_samples = sorted(
        upload_request.pose_samples,
        key=lambda sample: (float(sample.time_offset_sec), int(sample.sample_index)),
    )
    for sample in sorted_samples:
        time_offset_sec = float(sample.time_offset_sec)
        if time_offset_sec < 0.75:
            continue
        if sample.position_m is None or sample.yaw_pitch_roll_deg is None:
            continue
        if not _tracking_state_is_stable(sample.tracking_state):
            continue
        if (
            sample.horizontal_accuracy_m is not None
            and float(sample.horizontal_accuracy_m) > 1.0
        ):
            continue
        if (
            sample.vertical_accuracy_m is not None
            and float(sample.vertical_accuracy_m) > 2.0
        ):
            continue
        if last_kept is not None and (time_offset_sec - last_kept) < min_spacing_sec:
            continue
        accepted.append(time_offset_sec)
        last_kept = time_offset_sec

    return _evenly_spaced_subset(accepted, max_count=12)


def _mobile_first_segmentation_score(mobile_first_capture, field_name: str) -> float | None:
    if mobile_first_capture is None:
        return None
    score = getattr(mobile_first_capture, field_name)
    if score is not None:
        return score
    on_device_vision = mobile_first_capture.on_device_vision
    if on_device_vision is None:
        return None
    return getattr(on_device_vision, field_name)


def _attach_upload_context_to_pipeline_config(
    config: PipelineConfig,
    context: UploadContext,
) -> PipelineConfig:
    upload_request = context.upload_request
    config.tagged_reference_strategy = upload_request.tagged_reference_strategy
    config.capture_metadata = upload_request.capture_metadata
    config.quality_input = upload_request.quality_input
    config.pose_samples = upload_request.pose_samples
    config.reference_evidence_frames = upload_request.reference_evidence_frames
    config.reference_observations = upload_request.reference_observations
    return config


def _mobile_capture_prior_from_upload_context(context: UploadContext) -> MobileCapturePrior:
    upload_request = context.upload_request
    reference_evidence_timestamps_sec = tuple(
        sorted(
            {
                float(frame.time_offset_sec)
                for frame in upload_request.reference_evidence_jpeg_frames
                if frame.time_offset_sec >= 0
            }
        )
    )
    useful_pose_sample_timestamps_sec = _stable_pose_sample_timestamps_sec(context)
    sensor_metadata = (
        None
        if upload_request.capture_metadata is None
        else upload_request.capture_metadata.sensor_metadata
    )
    mobile_first_capture = (
        None
        if upload_request.quality_input is None
        else upload_request.quality_input.mobile_first_capture
    )
    return MobileCapturePrior(
        reference_evidence_timestamps_sec=reference_evidence_timestamps_sec,
        useful_pose_sample_timestamps_sec=useful_pose_sample_timestamps_sec,
        reference_evidence_count=len(upload_request.reference_evidence_jpeg_frames),
        pose_sample_count=len(upload_request.pose_samples),
        useful_pose_sample_count=len(useful_pose_sample_timestamps_sec),
        depth_data_included=(
            None if sensor_metadata is None else sensor_metadata.depth_data_included
        ),
        pile_segmentation_score=_mobile_first_segmentation_score(
            mobile_first_capture,
            "pile_segmentation_score",
        ),
        toe_segmentation_score=_mobile_first_segmentation_score(
            mobile_first_capture,
            "toe_segmentation_score",
        ),
        segmentation_confidence_score=_mobile_first_segmentation_score(
            mobile_first_capture,
            "segmentation_confidence_score",
        ),
        quick_volume_m3=(
            None if mobile_first_capture is None else mobile_first_capture.quick_volume_m3
        ),
        quick_footprint_area_m2=(
            None if mobile_first_capture is None else mobile_first_capture.quick_footprint_area_m2
        ),
        quick_peak_height_m=(
            None if mobile_first_capture is None else mobile_first_capture.quick_peak_height_m
        ),
        quick_confidence_score=(
            None if mobile_first_capture is None else mobile_first_capture.quick_confidence_score
        ),
        quick_geometry_point_count=(
            None if mobile_first_capture is None else mobile_first_capture.quick_geometry_point_count
        ),
        quick_camera_path_distance_m=(
            None
            if mobile_first_capture is None
            else mobile_first_capture.quick_camera_path_distance_m
        ),
    )


class StockpileMobileJobRuntime:
    """Runs uploaded mobile captures through the existing stockpile pipeline."""

    def __init__(
        self,
        service: StockpileMobileAPIService,
        *,
        configuration: StockpileMobileJobRuntimeConfiguration | None = None,
        pipeline_config_factory: PipelineConfigFactory | None = None,
        pipeline_factory: PipelineFactory | None = None,
    ):
        self.service = service
        self.configuration = configuration or StockpileMobileJobRuntimeConfiguration.from_environment()
        self.pipeline_config_factory = pipeline_config_factory or self._default_pipeline_config
        self.pipeline_factory = pipeline_factory or self._default_pipeline_factory
        self._lock = threading.Lock()
        self._threads: dict[str, threading.Thread] = {}

    def start_processing_for_upload(self, upload_id: str) -> str:
        context = self.service.fetch_upload_context(upload_id)
        status = self.service.fetch_processing_job(context.job_id)
        if status.phase.is_terminal:
            return context.job_id

        if status.phase is JobPhase.UPLOAD_AUTHORIZED:
            if not context.storage_path.exists():
                raise MobileAPIValidationError(
                    f"Upload {upload_id} has not been received yet; processing cannot begin.",
                )
            byte_count = context.storage_path.stat().st_size
            if byte_count <= 0:
                raise MobileAPIValidationError(
                    f"Upload {upload_id} is empty; processing cannot begin.",
                )
            self.service.mark_upload_received(context.upload_id, bytes_received=byte_count)

        with self._lock:
            active = self._threads.get(context.job_id)
            if active and active.is_alive():
                return context.job_id

            worker = threading.Thread(
                target=self._run_job,
                name=f"stockpile-mobile-job-{context.job_id}",
                args=(context,),
                daemon=True,
            )
            self._threads[context.job_id] = worker
            worker.start()
        return context.job_id

    def start_processing_for_job(self, job_id: str) -> str:
        context = self.service.fetch_job_context(job_id)
        return self.start_processing_for_upload(context.upload_id)

    def is_job_active(self, job_id: str) -> bool:
        with self._lock:
            thread = self._threads.get(job_id)
            return bool(thread and thread.is_alive())

    def ensure_processing_for_job(self, job_id: str) -> bool:
        status = self.service.fetch_processing_job(job_id)
        if status.phase.is_terminal or self.is_job_active(job_id):
            return False

        context = self.service.fetch_job_context(job_id)
        if not context.storage_path.exists():
            return False
        if context.storage_path.stat().st_size <= 0:
            return False
        if status.phase is JobPhase.UPLOAD_AUTHORIZED:
            self.service.mark_upload_received(
                context.upload_id,
                bytes_received=context.storage_path.stat().st_size,
            )

        self.start_processing_for_upload(context.upload_id)
        return True

    def resume_pending_jobs(self) -> list[str]:
        resumed: list[str] = []
        for job_id in self.service.list_restartable_job_ids():
            if self.ensure_processing_for_job(job_id):
                resumed.append(job_id)
        return resumed

    def wait_for_job(self, job_id: str, timeout: float | None = None) -> bool:
        with self._lock:
            thread = self._threads.get(job_id)
        if thread is None:
            return True
        thread.join(timeout=timeout)
        return not thread.is_alive()

    def _run_job(self, context: UploadContext):
        job_id = context.job_id
        try:
            runner = StockpileMobileJobRunner(
                service=self.service,
                workspace_root=self.configuration.workspace_root,
                pipeline_factory=self.pipeline_factory,
                pipeline_config_builder=self._make_pipeline_config_builder(context),
            )
            runner.run_upload(context.upload_id)
        except MobileProcessingRuntimeError:
            logger.warning("Mobile processing job %s finished with a durable failure state", job_id)
        except Exception as exc:  # pragma: no cover - defensive runtime path
            logger.exception("Mobile processing job %s failed", job_id)
            self.service.fail_job(job_id, str(exc))
        finally:
            with self._lock:
                self._threads.pop(job_id, None)

    def _default_pipeline_config(self, context: UploadContext) -> PipelineConfig:
        config = build_mobile_job_pipeline_config(
            workspace=self.configuration.workspace_root / context.job_id,
            material_density_kg_per_m3=context.session.density_kg_per_m3,
            material_name=context.session.material_code,
            mobile_capture_prior=_mobile_capture_prior_from_upload_context(context),
        )
        return _attach_upload_context_to_pipeline_config(config, context)

    @staticmethod
    def _default_pipeline_factory(config: PipelineConfig) -> PipelineRunner:
        from .pipeline import Pipeline

        return Pipeline(config)

    def _make_pipeline_config_builder(self, context: UploadContext):
        def builder(*, workspace, material_density_kg_per_m3, material_name, progress_callback=None):
            config = self.pipeline_config_factory(context)
            config.workspace = Path(workspace)
            config.material_density = float(material_density_kg_per_m3)
            config.material_name = str(material_name)
            config.mobile_capture_prior = _mobile_capture_prior_from_upload_context(context)
            config.progress_callback = progress_callback
            return _attach_upload_context_to_pipeline_config(config, context)

        return builder
