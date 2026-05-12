from __future__ import annotations

import hashlib
from pathlib import Path
from types import SimpleNamespace

import pytest

from stockpile.config import build_mobile_job_pipeline_config
from stockpile.mobile_api_models import (
    CaptureMetadataPayload,
    CaptureMode,
    CaptureQualityInputPayload,
    CaptureSessionCreateRequest,
    CaptureSource,
    DeviceSensorInputPayload,
    JobPhase,
    RunOutcome,
    TaggedReferenceStrategyMode,
    TaggedReferenceStrategyPayload,
    UploadRequest,
)
from stockpile.mobile_api_service import ResultNotFoundError, StockpileMobileAPIService
from stockpile.processing_runtime import (
    MobileProcessingRuntimeError,
    StockpileMobileJobRunner,
)


class RecordingMobileAPIService(StockpileMobileAPIService):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.processing_updates = []

    def update_job_processing(self, job_id: str, **kwargs):
        status = super().update_job_processing(job_id, **kwargs)
        self.processing_updates.append(status)
        return status


def _tagged_reference_strategy() -> TaggedReferenceStrategyPayload:
    return TaggedReferenceStrategyPayload(
        mode=TaggedReferenceStrategyMode.CONCURRENT_VISIBILITY,
        reference_count_goal=3,
        minimum_visible_reference_count=2,
        preferred_visible_reference_count=3,
    )


def _capture_metadata() -> CaptureMetadataPayload:
    return CaptureMetadataPayload(
        source=CaptureSource.LIVE_RECORDED_VIDEO,
        mode=CaptureMode.GUIDED_WALKAROUND,
        time_zone_identifier="UTC",
    )


def _quality_input() -> CaptureQualityInputPayload:
    return CaptureQualityInputPayload(
        reference_visibility_score=0.9,
        coverage_score=0.85,
        motion_stability_score=0.8,
        overall_guidance_score=0.86,
        device_sensors=DeviceSensorInputPayload.reserved(),
    )


def _sha256_hex(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _create_authorized_upload(service: StockpileMobileAPIService):
    upload_bytes = b"fake-video-bytes"
    capture_session = service.create_capture_session(
        CaptureSessionCreateRequest(
            site_id="site_alpha",
            pile_name="North Yard 03",
            material_code="backfill-0-75",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha-1",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    authorization = service.create_upload_authorization(
        UploadRequest(
            session_id=capture_session.session_id,
            file_name="north-yard-03.mov",
            byte_count=len(upload_bytes),
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(upload_bytes),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    service.save_upload_bytes(authorization.upload_id, upload_bytes, finalize=True)
    return authorization


def _collapse_phases(statuses) -> list[JobPhase]:
    phases: list[JobPhase] = []
    for status in statuses:
        if not phases or phases[-1] is not status.phase:
            phases.append(status.phase)
    return phases


def test_mobile_job_runner_maps_pipeline_stages_and_persists_result(tmp_path):
    service = RecordingMobileAPIService(root_dir=tmp_path / "mobile-api")
    authorization = _create_authorized_upload(service)

    class ScriptedPipeline:
        def __init__(self, config):
            self.config = config

        def run(self, video_path):
            assert Path(video_path).exists()
            assert self.config.workspace == tmp_path / "runtime" / authorization.job_id
            self.config.progress_callback("frame_extraction", 0.0, "Extracting frames from the upload.")
            self.config.progress_callback("frame_extraction", 1.0, "Extracted 18 frames.")
            self.config.progress_callback("cone_detection", 0.5, "Reference candidates are visible in the walkaround.")
            self.config.progress_callback("colmap_reconstruction", 0.4, "Sparse reconstruction is underway.")
            self.config.progress_callback("scale_calibration", 1.0, "Tagged references established the working scale.")
            self.config.progress_callback("ground_plane", 1.0, "Ground plane stabilized and the pile was isolated.")
            self.config.progress_callback("volume_computation", 1.0, "Volume integration completed successfully.")

            result = SimpleNamespace(
                publishable=True,
                review_grade=False,
                reference_strategy="tagged_references",
                weight_kg=176_820.0,
                volume=SimpleNamespace(recommended_m3=84.2),
                calibration=SimpleNamespace(
                    confidence=0.92,
                    reference_family="tag36h11",
                    selected_method="projection",
                    num_references_used=3,
                    frames_with_multiple_detections=14,
                    registered_cone_frames=20,
                ),
                quality_warnings=[],
                quality_blockers=[],
                stage="complete",
                error=None,
            )
            return result

    runner = StockpileMobileJobRunner(
        service=service,
        workspace_root=tmp_path / "runtime",
        pipeline_factory=ScriptedPipeline,
    )

    result = runner.run_upload(authorization.upload_id)
    final_status = service.fetch_processing_job(authorization.job_id)

    assert result.outcome is RunOutcome.VERIFIED
    assert result.measurement is not None
    assert result.measurement.volume_m3 == pytest.approx(84.2)
    assert final_status.phase is JobPhase.VERIFIED
    assert service.fetch_result(result.run_id).outcome is RunOutcome.VERIFIED

    assert _collapse_phases(service.processing_updates)[:5] == [
        JobPhase.EXTRACTING_FRAMES,
        JobPhase.DETECTING_REFERENCES,
        JobPhase.RECONSTRUCTING,
        JobPhase.CALIBRATING,
        JobPhase.COMPUTING_VOLUME,
    ]
    assert any("Ground plane" in status.detail for status in service.processing_updates)


def test_mobile_job_runner_marks_failed_job_when_pipeline_crashes(tmp_path):
    service = RecordingMobileAPIService(root_dir=tmp_path / "mobile-api")
    authorization = _create_authorized_upload(service)

    class ExplodingPipeline:
        def __init__(self, config):
            self.config = config

        def run(self, video_path):
            self.config.progress_callback("frame_extraction", 0.2, "Started extracting frames.")
            raise RuntimeError("COLMAP binary is unavailable")

    runner = StockpileMobileJobRunner(
        service=service,
        workspace_root=tmp_path / "runtime",
        pipeline_factory=ExplodingPipeline,
    )

    with pytest.raises(MobileProcessingRuntimeError):
        runner.run_job(authorization.job_id)

    status = service.fetch_processing_job(authorization.job_id)
    assert status.phase is JobPhase.FAILED
    assert "COLMAP binary is unavailable" in status.detail
    with pytest.raises(ResultNotFoundError):
        service.fetch_result(authorization.run_id)


def test_build_mobile_job_pipeline_config_reads_mobile_env(monkeypatch, tmp_path):
    monkeypatch.setenv("STOCKPILE_MOBILE_TAGGED_REFERENCES_ENABLED", "1")
    monkeypatch.setenv("STOCKPILE_MOBILE_TAG_FAMILY", "tag25h9")
    monkeypatch.setenv("STOCKPILE_MOBILE_ALLOWED_TAG_IDS", "7,3,7")
    monkeypatch.setenv("STOCKPILE_MOBILE_MANUAL_SCALE_OVERRIDE", "1.25")

    config = build_mobile_job_pipeline_config(
        workspace=tmp_path / "worker-job",
        material_density_kg_per_m3=1650,
        material_name="aggregate-5-14",
    )

    assert config.workspace == tmp_path / "worker-job"
    assert config.material_density == pytest.approx(1650.0)
    assert config.material_name == "aggregate-5-14"
    assert config.tagged_references.enabled is True
    assert config.tagged_references.family == "tag25h9"
    assert config.tagged_references.allowed_tag_ids == (3, 7)
    assert config.manual_scale_override == pytest.approx(1.25)
