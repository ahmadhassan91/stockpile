"""Durable mobile processing runtime for uploaded stockpile captures."""

from __future__ import annotations

import argparse
import logging
import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .config import build_mobile_job_pipeline_config
from .mobile_api_models import JobPhase, ResultPayload
from .mobile_api_service import StockpileMobileAPIService

logger = logging.getLogger(__name__)


class MobileProcessingRuntimeError(RuntimeError):
    """Raised when a mobile processing job cannot complete successfully."""


@dataclass(frozen=True)
class StagePhaseMapping:
    phase: JobPhase
    progress_floor: float
    progress_ceiling: float
    headline: str
    fallback_detail: str


@dataclass(frozen=True)
class StageProgressUpdate:
    phase: JobPhase
    progress: float
    headline: str
    detail: str


_PIPELINE_STAGE_MAP: dict[str, StagePhaseMapping] = {
    "frame_extraction": StagePhaseMapping(
        phase=JobPhase.EXTRACTING_FRAMES,
        progress_floor=0.12,
        progress_ceiling=0.30,
        headline="Extracting frames",
        fallback_detail="Breaking the uploaded walkaround into frames and checking basic coverage.",
    ),
    "cone_detection": StagePhaseMapping(
        phase=JobPhase.DETECTING_REFERENCES,
        progress_floor=0.32,
        progress_ceiling=0.50,
        headline="Detecting tagged references",
        fallback_detail="Finding tagged references and other scale anchors across the uploaded walkaround.",
    ),
    "colmap_reconstruction": StagePhaseMapping(
        phase=JobPhase.RECONSTRUCTING,
        progress_floor=0.58,
        progress_ceiling=0.76,
        headline="Reconstructing stockpile geometry",
        fallback_detail="Building the sparse 3D reconstruction from the uploaded frames.",
    ),
    "scale_calibration": StagePhaseMapping(
        phase=JobPhase.CALIBRATING,
        progress_floor=0.76,
        progress_ceiling=0.90,
        headline="Calibrating scale",
        fallback_detail="Cross-checking tagged references and camera pose before release.",
    ),
    "ground_plane": StagePhaseMapping(
        phase=JobPhase.COMPUTING_VOLUME,
        progress_floor=0.90,
        progress_ceiling=0.95,
        headline="Preparing volume computation",
        fallback_detail="Aligning the ground plane and isolating the pile surface.",
    ),
    "volume_computation": StagePhaseMapping(
        phase=JobPhase.COMPUTING_VOLUME,
        progress_floor=0.95,
        progress_ceiling=0.99,
        headline="Computing volume",
        fallback_detail="Finalizing pile segmentation and integrating the measured surface.",
    ),
    "complete": StagePhaseMapping(
        phase=JobPhase.COMPUTING_VOLUME,
        progress_floor=0.99,
        progress_ceiling=0.99,
        headline="Finalizing result",
        fallback_detail="Persisting the final result for operator review.",
    ),
}


def _clamp_progress(value: float) -> float:
    return max(0.0, min(1.0, float(value)))


def _trimmed(message: str | None) -> str | None:
    if message is None:
        return None
    stripped = str(message).strip()
    return stripped or None


def _map_pipeline_stage(stage: str, progress: float, message: str = "") -> StageProgressUpdate | None:
    mapping = _PIPELINE_STAGE_MAP.get(str(stage).strip())
    if mapping is None:
        return None

    local_progress = _clamp_progress(progress)
    overall_progress = mapping.progress_floor + (
        (mapping.progress_ceiling - mapping.progress_floor) * local_progress
    )
    return StageProgressUpdate(
        phase=mapping.phase,
        progress=_clamp_progress(overall_progress),
        headline=mapping.headline,
        detail=_trimmed(message) or mapping.fallback_detail,
    )


class _DurableStageReporter:
    def __init__(self, service: StockpileMobileAPIService, job_id: str):
        self.service = service
        self.job_id = job_id
        self._last_signature: tuple[str, int, str] | None = None

    def __call__(self, stage: str, progress: float, message: str = ""):
        update = _map_pipeline_stage(stage, progress, message)
        if update is None:
            return

        bucket = int(update.progress * 20)
        signature = (update.phase.value, bucket, update.detail)
        if signature == self._last_signature and update.progress not in {0.0, 1.0}:
            return

        self._last_signature = signature
        self.service.update_job_processing(
            self.job_id,
            phase=update.phase,
            progress=update.progress,
            headline=update.headline,
            detail=update.detail,
        )


def _default_pipeline_factory(config):
    from .pipeline import Pipeline

    return Pipeline(config)


class StockpileMobileJobRunner:
    """Run the stockpile pipeline for a finalized mobile upload."""

    def __init__(
        self,
        *,
        service: StockpileMobileAPIService,
        workspace_root: str | Path,
        pipeline_factory: Any | None = None,
        pipeline_config_builder: Any = build_mobile_job_pipeline_config,
    ):
        self.service = service
        self.workspace_root = Path(workspace_root)
        self.pipeline_factory = pipeline_factory or _default_pipeline_factory
        self.pipeline_config_builder = pipeline_config_builder

    @classmethod
    def from_environment(cls) -> "StockpileMobileJobRunner":
        service = StockpileMobileAPIService.from_environment()
        workspace_root = Path(
            os.environ.get(
                "STOCKPILE_MOBILE_RUNTIME_ROOT",
                str(service.root_dir / "processing_runtime"),
            )
        )
        return cls(service=service, workspace_root=workspace_root)

    def run_job(self, job_id: str) -> ResultPayload:
        context = self.service.fetch_job_context(job_id)
        status = self.service.fetch_processing_job(job_id)
        return self._run(job_id=job_id, run_id=context.run_id, storage_path=context.storage_path, status=status)

    def run_upload(self, upload_id: str) -> ResultPayload:
        context = self.service.fetch_upload_context(upload_id)
        status = self.service.fetch_processing_job(context.job_id)
        return self._run(
            job_id=context.job_id,
            run_id=context.run_id,
            storage_path=context.storage_path,
            status=status,
        )

    def _run(
        self,
        *,
        job_id: str,
        run_id: str,
        storage_path: Path,
        status,
    ) -> ResultPayload:
        if status.phase.is_terminal and status.phase is not JobPhase.FAILED:
            return self.service.fetch_result(run_id)

        resolved_bytes = self._resolve_upload_size(job_id, storage_path, status)
        if resolved_bytes <= 0:
            detail = (
                f"Upload for job {job_id} is empty or missing at {storage_path}; "
                "processing cannot begin."
            )
            self.service.fail_job(job_id, detail)
            raise MobileProcessingRuntimeError(detail)

        upload_context = self.service.fetch_job_context(job_id)
        self.service.mark_upload_received(upload_context.upload_id, bytes_received=resolved_bytes)

        workspace = self._prepare_workspace(job_id)
        reporter = _DurableStageReporter(self.service, job_id)
        self.service.update_job_processing(
            job_id,
            phase=JobPhase.EXTRACTING_FRAMES,
            progress=0.12,
            headline="Preparing processing",
            detail="Processing worker claimed the uploaded video and is preparing frame extraction.",
        )

        config = self.pipeline_config_builder(
            workspace=workspace,
            material_density_kg_per_m3=upload_context.session.density_kg_per_m3,
            material_name=upload_context.session.material_code,
            progress_callback=reporter,
        )
        pipeline = self.pipeline_factory(config)

        try:
            pipeline_result = pipeline.run(storage_path)
        except Exception as exc:
            detail = f"Pipeline execution crashed before completion: {exc}"
            self.service.fail_job(job_id, detail)
            raise MobileProcessingRuntimeError(detail) from exc

        if getattr(pipeline_result, "error", None):
            detail = self._failure_detail(pipeline_result)
            self.service.fail_job(job_id, detail)
            raise MobileProcessingRuntimeError(detail)

        reporter(
            "complete",
            1.0,
            "Pipeline completed successfully. Writing the final result for operator review.",
        )
        return self.service.store_result_from_pipeline(job_id, pipeline_result)

    def _prepare_workspace(self, job_id: str) -> Path:
        workspace = self.workspace_root / job_id
        if workspace.exists():
            shutil.rmtree(workspace)
        workspace.mkdir(parents=True, exist_ok=True)
        return workspace

    def _resolve_upload_size(self, job_id: str, storage_path: Path, status) -> int:
        bytes_received = 0
        if status.upload is not None:
            bytes_received = int(status.upload.bytes_received)
        if storage_path.exists():
            return max(bytes_received, int(storage_path.stat().st_size))
        return max(0, bytes_received)

    def _failure_detail(self, pipeline_result: Any) -> str:
        stage = str(getattr(pipeline_result, "stage", "") or "unknown")
        blockers = [
            str(message).strip()
            for message in getattr(pipeline_result, "quality_blockers", [])
            if str(message).strip()
        ]
        primary_reason = blockers[0] if blockers else str(
            getattr(pipeline_result, "error", "") or "Unknown pipeline failure"
        )
        return f"Pipeline failed during {stage.replace('_', ' ')}. {primary_reason}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run the durable mobile stockpile processing worker.")
    parser.add_argument("--job-id", help="Durable mobile processing job ID to execute.")
    parser.add_argument("--upload-id", help="Upload ID to resolve into a processing job.")
    args = parser.parse_args(argv)

    if bool(args.job_id) == bool(args.upload_id):
        parser.error("Provide exactly one of --job-id or --upload-id.")

    runner = StockpileMobileJobRunner.from_environment()
    try:
        if args.job_id:
            result = runner.run_job(args.job_id)
        else:
            result = runner.run_upload(args.upload_id)
    except MobileProcessingRuntimeError as exc:
        logger.error("Mobile processing failed: %s", exc)
        return 1

    logger.info(
        "Mobile processing finished with outcome=%s run_id=%s",
        result.outcome.value,
        result.run_id,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
