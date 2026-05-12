from __future__ import annotations

import base64
import hashlib
import json
from types import SimpleNamespace

from fastapi.testclient import TestClient

from stockpile.mobile_api_app import create_app
from stockpile.mobile_api_models import (
    CaptureMetadataPayload,
    CaptureMode,
    MobileFirstCapturePayload,
    MobileFirstCaptureStage,
    CaptureQualityInputPayload,
    CaptureQualityPayload,
    CaptureSessionCreateRequest,
    CaptureSource,
    ConfidencePayload,
    DeviceSensorInputPayload,
    MeasurementPayload,
    ProvisionalMeasurementPayload,
    OnDeviceVisionPayload,
    ReferenceDiagnosticsPayload,
    ReferenceEvidenceFramePayload,
    ReferenceMarkerQuality,
    ReferenceObservationPayload,
    ResultPayload,
    RunOutcome,
    TaggedReferenceStrategyMode,
    TaggedReferenceStrategyPayload,
    UploadRequest,
    parse_datetime,
)
from stockpile.mobile_first.models import CaptureQualityState, VerificationOutcome
from stockpile.mobile_api_service import StockpileMobileAPIService


class StubRuntime:
    def __init__(self):
        self.started_uploads: list[str] = []
        self.started_jobs: set[str] = set()

    def start_processing_for_upload(self, upload_id: str) -> str:
        self.started_uploads.append(upload_id)
        return "job_stub"

    def ensure_processing_for_job(self, job_id: str) -> bool:
        if job_id in self.started_jobs:
            return False
        self.started_jobs.add(job_id)
        return True


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
        time_zone_identifier="Asia/Karachi",
        active_device_name="iPhone",
        capture_phase="guided_capture",
        session_lifecycle="ready",
        recording_lifecycle="recorded",
    )


def _quality_input(*, quick_volume_m3: float | None = None) -> CaptureQualityInputPayload:
    return CaptureQualityInputPayload(
        reference_visibility_score=0.78,
        coverage_score=0.8,
        motion_stability_score=0.91,
        overall_guidance_score=0.84,
        device_sensors=DeviceSensorInputPayload(
            motion_signals_included=True,
            gravity_vector_included=True,
            heading_signals_included=True,
            camera_calibration_included=False,
        ),
        mobile_first_capture=(
            None
            if quick_volume_m3 is None
            else MobileFirstCapturePayload(
                stage=MobileFirstCaptureStage.WALKING_PERIMETER,
                quick_volume_m3=quick_volume_m3,
                quick_confidence_score=0.72,
                quick_footprint_area_m2=14.4,
                quick_peak_height_m=2.1,
                quick_geometry_point_count=320,
                quick_camera_path_distance_m=18.2,
            )
        ),
    )


def _quality_input_with_on_device_vision(
    *,
    explicit_toe_coverage_score: float | None = None,
    explicit_quick_confidence_score: float | None = None,
) -> CaptureQualityInputPayload:
    return CaptureQualityInputPayload(
        reference_visibility_score=0.41,
        coverage_score=0.42,
        motion_stability_score=0.9,
        overall_guidance_score=0.43,
        mobile_first_capture=MobileFirstCapturePayload(
            stage=MobileFirstCaptureStage.WALKING_PERIMETER,
            on_device_vision=OnDeviceVisionPayload(
                source="vision_foreground_instance_mask",
                uses_machine_learning=True,
                pile_segmentation_score=0.87,
                toe_segmentation_score=0.79,
                segmentation_confidence_score=0.86,
                material_family_code="aggregate_rock",
                material_family_label="Coarse aggregate / rock",
                material_confidence_score=0.74,
            ),
            toe_coverage_score=explicit_toe_coverage_score,
            quick_volume_m3=1642.1,
            quick_confidence_score=explicit_quick_confidence_score,
        ),
    )


def _sha256_hex(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _reference_evidence_frame_payload(
    *,
    frame_id: str,
    time_offset_sec: float,
    pose_sample_index: int,
) -> dict[str, object]:
    return {
        "frameId": frame_id,
        "timeOffsetSec": time_offset_sec,
        "poseSampleIndex": pose_sample_index,
        "capturedAt": "2026-04-23T08:45:00Z",
        "widthPx": 1440,
        "heightPx": 810,
        "jpegBase64": base64.b64encode(f"{frame_id}-jpeg".encode("utf-8")).decode("ascii"),
    }


def _fake_reference_observation(
    frame_id: str,
    time_offset_sec: float,
    pose_sample_index: int,
) -> ReferenceObservationPayload:
    return ReferenceObservationPayload(
        reference_id="tag36h11:11",
        family="tag36h11",
        frame_time_sec=time_offset_sec,
        pose_sample_index=pose_sample_index,
        frame_id=frame_id,
        edge_length_px=72.0,
        pixel_area_px=5184.0,
        confidence=0.91,
        state=ReferenceMarkerQuality.CONFIRMED,
    )


def _complete_terminal_run(
    client: TestClient,
    service: StockpileMobileAPIService,
    *,
    site_id: str,
    pile_name: str,
    upload_bytes: bytes,
) -> dict[str, str]:
    capture_response = client.post(
        "/api/mobile/capture-sessions",
        json=CaptureSessionCreateRequest(
            site_id=site_id,
            pile_name=pile_name,
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    assert capture_response.status_code == 201
    session_id = capture_response.json()["sessionId"]

    upload_response = client.post(
        "/api/mobile/uploads",
        json=UploadRequest(
            session_id=session_id,
            file_name=f"{pile_name.lower().replace(' ', '-')}.mov",
            byte_count=len(upload_bytes),
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(upload_bytes),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    assert upload_response.status_code == 201
    upload_payload = upload_response.json()

    content_response = client.put(
        f"/api/mobile/uploads/{upload_payload['uploadId']}/content",
        content=upload_bytes,
        headers={"Content-Type": "video/quicktime"},
    )
    assert content_response.status_code == 202

    service.store_result(
        upload_payload["jobId"],
        ResultPayload(
            run_id=upload_payload["runId"],
            pile_name=pile_name,
            outcome=RunOutcome.REVIEW_ONLY,
            confidence=ConfidencePayload(
                score=61,
                label="Moderate",
                summary="Processing completed, but it still needs benchmark review.",
            ),
            measurement=MeasurementPayload(
                volume_m3=2528.43,
                weight_tonnes=5309.70,
                density_kg_per_m3=2100,
            ),
            warnings=["Benchmark cross-check advised."],
            blockers=[],
            recommended_action="Review against the latest site benchmark before release.",
            capture_quality=CaptureQualityPayload(
                reference_visibility_score=0.78,
                perimeter_coverage_score=0.8,
                motion_stability_score=0.91,
                overall_guidance_score=0.84,
            ),
            reference_diagnostics=ReferenceDiagnosticsPayload(
                target_count=3,
                minimum_visible_together=2,
                preferred_visible_count=3,
                frames_meeting_visibility_goal=41,
                frames_checked=63,
                calibration_basis="tagged_references_plus_camera_pose",
                calibration_status="needs_review",
                reference_strategy="tagged_references",
                references_used=3,
            ),
            report_url=f"https://example.com/report/{upload_payload['runId']}",
        ),
    )
    return {
        "sessionId": session_id,
        "uploadId": upload_payload["uploadId"],
        "jobId": upload_payload["jobId"],
        "runId": upload_payload["runId"],
        "siteId": site_id,
    }


def test_mobile_api_app_supports_capture_upload_and_result_flow(tmp_path, monkeypatch):
    monkeypatch.delenv("STOCKPILE_MOBILE_API_BEARER_TOKEN", raising=False)
    monkeypatch.delenv("STOCKPILE_MOBILE_API_KEY", raising=False)

    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    runtime = StubRuntime()
    client = TestClient(create_app(service=service, runtime=runtime))
    upload_bytes = b"real-alpha-video-bytes"

    capture_response = client.post(
        "/api/mobile/capture-sessions",
        json=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 03",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    assert capture_response.status_code == 201
    session_id = capture_response.json()["sessionId"]

    upload_response = client.post(
        "/api/mobile/uploads",
        json=UploadRequest(
            session_id=session_id,
            file_name="north-yard-03.mov",
            byte_count=len(upload_bytes),
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(upload_bytes),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    assert upload_response.status_code == 201
    upload_payload = upload_response.json()
    upload_id = upload_payload["uploadId"]
    job_id = upload_payload["jobId"]
    run_id = upload_payload["runId"]

    content_response = client.put(
        f"/api/mobile/uploads/{upload_id}/content",
        content=upload_bytes,
        headers={"Content-Type": "video/quicktime"},
    )
    assert content_response.status_code == 202
    assert runtime.started_jobs == {job_id}
    assert content_response.headers["x-stockpile-receipt-id"] == upload_id
    assert content_response.headers["x-stockpile-server-upload-id"] == upload_id
    assert content_response.json()["receiptId"] == upload_id
    assert content_response.json()["upload"]["bytesReceived"] == len(upload_bytes)

    job_response = client.get(f"/api/mobile/jobs/{job_id}")
    assert job_response.status_code == 200
    assert job_response.json()["phase"] == "upload_received"

    service.store_result(
        job_id,
        ResultPayload(
            run_id=run_id,
            pile_name="North Yard 03",
            outcome=RunOutcome.REVIEW_ONLY,
            confidence=ConfidencePayload(
                score=58,
                label="Moderate",
                summary="Processing completed, but it still needs benchmark review.",
            ),
            measurement=MeasurementPayload(
                volume_m3=2528.43,
                weight_tonnes=5309.70,
                density_kg_per_m3=2100,
            ),
            warnings=["Benchmark cross-check advised."],
            blockers=[],
            recommended_action="Review against the latest site benchmark before release.",
            capture_quality=CaptureQualityPayload(
                reference_visibility_score=0.78,
                perimeter_coverage_score=0.8,
                motion_stability_score=0.91,
                overall_guidance_score=0.84,
            ),
            reference_diagnostics=ReferenceDiagnosticsPayload(
                target_count=3,
                minimum_visible_together=2,
                preferred_visible_count=3,
                frames_meeting_visibility_goal=41,
                frames_checked=63,
                calibration_basis="tagged_references_plus_camera_pose",
                calibration_status="needs_review",
                reference_strategy="tagged_references",
                references_used=3,
            ),
            report_url="https://example.com/report/run_123",
        ),
    )

    result_path = service._result_path(run_id)
    legacy_payload = json.loads(result_path.read_text(encoding="utf-8"))
    legacy_payload.pop("updatedAt", None)
    legacy_payload.pop("siteId", None)
    legacy_payload.pop("sessionId", None)
    legacy_payload.pop("jobId", None)
    result_path.write_text(
        json.dumps(legacy_payload, ensure_ascii=True, indent=2, sort_keys=True),
        encoding="utf-8",
    )

    result_response = client.get(f"/api/mobile/results/{run_id}")
    assert result_response.status_code == 200
    assert result_response.json()["outcome"] == "review_only"
    assert result_response.json()["measurement"]["volumeM3"] == 2528.43
    assert result_response.json()["updatedAt"] is not None
    assert result_response.json()["siteId"] == "qpmc-north-yard"
    assert result_response.json()["sessionId"] == session_id
    assert result_response.json()["jobId"] == job_id
    terminal_job_status = service.fetch_processing_job(job_id)
    assert parse_datetime(result_response.json()["updatedAt"]) == terminal_job_status.updated_at
    refreshed_result_payload = json.loads(result_path.read_text(encoding="utf-8"))
    assert refreshed_result_payload["updatedAt"] == result_response.json()["updatedAt"]
    assert refreshed_result_payload["siteId"] == "qpmc-north-yard"
    assert refreshed_result_payload["sessionId"] == session_id
    assert refreshed_result_payload["jobId"] == job_id

    recent_runs_response = client.get(
        f"/api/mobile/runs/recent?limit=5&siteId=qpmc-north-yard&sessionId={session_id}"
    )
    assert recent_runs_response.status_code == 200
    recent_runs_payload = recent_runs_response.json()
    assert len(recent_runs_payload) == 1
    assert recent_runs_payload[0]["runId"] == run_id
    assert recent_runs_payload[0]["updatedAt"] == result_response.json()["updatedAt"]
    assert recent_runs_payload[0]["siteId"] == "qpmc-north-yard"
    assert recent_runs_payload[0]["sessionId"] == session_id
    assert recent_runs_payload[0]["jobId"] == job_id


def test_mobile_api_app_uses_enriched_reference_observations_for_provisional_and_review(
    tmp_path,
    monkeypatch,
):
    monkeypatch.delenv("STOCKPILE_MOBILE_API_BEARER_TOKEN", raising=False)
    monkeypatch.delenv("STOCKPILE_MOBILE_API_KEY", raising=False)
    monkeypatch.setattr(
        StockpileMobileAPIService,
        "_reference_observations_from_evidence_frames",
        lambda self, frames: tuple(
            _fake_reference_observation(
                frame.frame_id,
                frame.time_offset_sec,
                frame.pose_sample_index or 0,
            )
            for frame in frames
        ),
    )

    provisional_counts: list[int] = []
    provisional_volumes: list[float | None] = []
    review_counts: list[int] = []

    def fake_provisional(input_):
        provisional_counts.append(len(input_.capture.reference_observations))
        provisional_volumes.append(input_.quick_volume_m3)
        return SimpleNamespace(
            state=CaptureQualityState.REVIEW,
            provisional_volume_m3=input_.quick_volume_m3,
            confidence_score=0.01 * len(input_.capture.reference_observations),
            reasons=(),
            operator_action="",
        )

    def fake_review(packet):
        review_counts.append(packet.tagged_reference_count)
        return SimpleNamespace(
            outcome=VerificationOutcome.REVIEW_ONLY,
            summary="review",
            reasons=("stub",),
        )

    monkeypatch.setattr("stockpile.mobile_api_service.evaluate_provisional_measurement", fake_provisional)
    monkeypatch.setattr("stockpile.mobile_api_service.evaluate_review_packet", fake_review)

    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    runtime = StubRuntime()
    client = TestClient(create_app(service=service, runtime=runtime))

    capture_response = client.post(
        "/api/mobile/capture-sessions",
        json=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 03",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    assert capture_response.status_code == 201
    session_id = capture_response.json()["sessionId"]

    upload_response = client.post(
        "/api/mobile/uploads",
        json={
            "sessionId": session_id,
            "fileName": "north-yard-03.mov",
            "byteCount": 18,
            "contentType": "video/quicktime",
            "checksumSha256": _sha256_hex(b"alpha-bytes"),
            "taggedReferenceStrategy": _tagged_reference_strategy().to_dict(),
            "captureMetadata": _capture_metadata().to_dict(),
            "qualityInput": _quality_input(quick_volume_m3=1642.1).to_dict(),
            "referenceEvidenceJPEGFrames": [
                {
                    "frameId": "frame_0010",
                    "timeOffsetSec": 2.5,
                    "poseSampleIndex": 7,
                    "capturedAt": "2026-04-23T08:45:00Z",
                    "widthPx": 1440,
                    "heightPx": 810,
                    "jpegBase64": base64.b64encode(b"frame-0010").decode("ascii"),
                },
            ],
        },
    )
    assert upload_response.status_code == 201
    upload_payload = upload_response.json()

    upload_context = service.fetch_upload_context(upload_payload["uploadId"])
    assert len(upload_context.upload_request.reference_observations) == 1

    job_status = service.fetch_processing_job(upload_payload["jobId"])
    assert job_status.provisional_measurement is not None
    assert job_status.provisional_measurement.confidence_score == 1
    assert job_status.provisional_measurement.volume_m3 == 1642.1
    assert job_status.provisional_measurement.weight_tonnes == 3448.41

    fake_pipeline_result = SimpleNamespace(
        pile_name="North Yard 03",
        publishable=True,
        review_grade=False,
        calibration=SimpleNamespace(
            confidence=0.88,
            scale_disagreement_ratio=None,
            reference_family="tag36h11",
            selected_method="projection",
            num_references_used=1,
        ),
        volume=SimpleNamespace(recommended_m3=2528.43),
        weight_kg=5309700.0,
        reference_strategy="tagged_references",
    )
    stored_result = service.store_result_from_pipeline(upload_payload["jobId"], fake_pipeline_result)
    assert stored_result.outcome is RunOutcome.REVIEW_ONLY
    assert stored_result.reference_diagnostics.observation_summary is not None
    assert stored_result.reference_diagnostics.observation_summary.observed_reference_count == 1
    assert provisional_counts == [1, 1]
    assert provisional_volumes == [1642.1, 2528.43]
    assert review_counts == [1]


def test_mobile_api_app_uses_on_device_vision_as_provisional_fallback(
    tmp_path,
    monkeypatch,
):
    monkeypatch.delenv("STOCKPILE_MOBILE_API_BEARER_TOKEN", raising=False)
    monkeypatch.delenv("STOCKPILE_MOBILE_API_KEY", raising=False)

    captured_inputs: list[SimpleNamespace] = []

    def fake_provisional(input_):
        captured_inputs.append(
            SimpleNamespace(
                toe_coverage_score=input_.capture.toe_coverage_score,
                toe_confidence_score=input_.toe_confidence_score,
                geometry_confidence_score=input_.geometry_confidence_score,
            )
        )
        return SimpleNamespace(
            state=CaptureQualityState.REVIEW,
            provisional_volume_m3=input_.quick_volume_m3,
            confidence_score=0.71,
            reasons=(),
            operator_action="",
        )

    monkeypatch.setattr("stockpile.mobile_api_service.evaluate_provisional_measurement", fake_provisional)

    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    runtime = StubRuntime()
    client = TestClient(create_app(service=service, runtime=runtime))

    capture_response = client.post(
        "/api/mobile/capture-sessions",
        json=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 03",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input_with_on_device_vision(),
        ).to_dict(),
    )
    assert capture_response.status_code == 201
    session_id = capture_response.json()["sessionId"]

    upload_response = client.post(
        "/api/mobile/uploads",
        json=UploadRequest(
            session_id=session_id,
            file_name="north-yard-03.mov",
            byte_count=18,
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(b"alpha-bytes"),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input_with_on_device_vision(),
        ).to_dict(),
    )
    assert upload_response.status_code == 201

    assert captured_inputs
    assert captured_inputs[0].toe_coverage_score == 0.79
    assert captured_inputs[0].toe_confidence_score == 0.79
    assert captured_inputs[0].geometry_confidence_score == 0.86

    job_status = service.fetch_processing_job(upload_response.json()["jobId"])
    assert job_status.provisional_measurement is not None
    assert job_status.provisional_measurement.material_suggestion is not None
    assert job_status.provisional_measurement.material_suggestion.material_code == "aggregate_rock"
    assert job_status.provisional_measurement.material_suggestion.label == "Coarse aggregate / rock"
    assert job_status.provisional_measurement.material_suggestion.confidence == 0.74


def test_mobile_api_app_keeps_explicit_mobile_first_values_over_on_device_vision(
    tmp_path,
    monkeypatch,
):
    monkeypatch.delenv("STOCKPILE_MOBILE_API_BEARER_TOKEN", raising=False)
    monkeypatch.delenv("STOCKPILE_MOBILE_API_KEY", raising=False)

    captured_inputs: list[SimpleNamespace] = []

    def fake_provisional(input_):
        captured_inputs.append(
            SimpleNamespace(
                toe_coverage_score=input_.capture.toe_coverage_score,
                toe_confidence_score=input_.toe_confidence_score,
                geometry_confidence_score=input_.geometry_confidence_score,
            )
        )
        return SimpleNamespace(
            state=CaptureQualityState.REVIEW,
            provisional_volume_m3=input_.quick_volume_m3,
            confidence_score=0.71,
            reasons=(),
            operator_action="",
        )

    monkeypatch.setattr("stockpile.mobile_api_service.evaluate_provisional_measurement", fake_provisional)

    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    runtime = StubRuntime()
    client = TestClient(create_app(service=service, runtime=runtime))

    quality_input = _quality_input_with_on_device_vision(
        explicit_toe_coverage_score=0.66,
        explicit_quick_confidence_score=0.69,
    )
    capture_response = client.post(
        "/api/mobile/capture-sessions",
        json=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 03",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=quality_input,
        ).to_dict(),
    )
    assert capture_response.status_code == 201
    session_id = capture_response.json()["sessionId"]

    upload_response = client.post(
        "/api/mobile/uploads",
        json=UploadRequest(
            session_id=session_id,
            file_name="north-yard-03.mov",
            byte_count=18,
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(b"alpha-bytes"),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=quality_input,
        ).to_dict(),
    )
    assert upload_response.status_code == 201

    assert captured_inputs
    assert captured_inputs[0].toe_coverage_score == 0.66
    assert captured_inputs[0].toe_confidence_score == 0.66
    assert captured_inputs[0].geometry_confidence_score == 0.69


def test_store_result_merges_quick_segmentation_intelligence_into_terminal_provisional_payload(
    tmp_path,
    monkeypatch,
):
    monkeypatch.delenv("STOCKPILE_MOBILE_API_BEARER_TOKEN", raising=False)
    monkeypatch.delenv("STOCKPILE_MOBILE_API_KEY", raising=False)

    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    runtime = StubRuntime()
    client = TestClient(create_app(service=service, runtime=runtime))

    capture_response = client.post(
        "/api/mobile/capture-sessions",
        json=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 03",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    assert capture_response.status_code == 201
    session_id = capture_response.json()["sessionId"]

    upload_response = client.post(
        "/api/mobile/uploads",
        json=UploadRequest(
            session_id=session_id,
            file_name="north-yard-03.mov",
            byte_count=18,
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(b"alpha-bytes"),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(quick_volume_m3=1642.1),
        ).to_dict(),
    )
    assert upload_response.status_code == 201
    upload_payload = upload_response.json()

    stored_result = service.store_result(
        upload_payload["jobId"],
        ResultPayload(
            run_id=upload_payload["runId"],
            pile_name="North Yard 03",
            outcome=RunOutcome.REVIEW_ONLY,
            confidence=ConfidencePayload(
                score=68,
                label="Moderate",
                summary="Backend verification is still pending release.",
            ),
            measurement=MeasurementPayload(
                volume_m3=2528.43,
                weight_tonnes=5309.703,
                density_kg_per_m3=2100,
            ),
            warnings=[],
            blockers=[],
            recommended_action="Wait for the backend verification to finish.",
            provisional_measurement=ProvisionalMeasurementPayload(
                status="review",
                basis="mobile_first_review",
                volume_m3=2528.43,
                weight_tonnes=5309.703,
                confidence_score=68,
                reason="Backend verification is still pending release.",
            ),
        ),
    )

    assert stored_result.provisional_measurement is not None
    assert stored_result.provisional_measurement.volume_m3 == 2528.43
    assert stored_result.provisional_measurement.quick_volume_m3 == 1642.1
    assert stored_result.provisional_measurement.quick_footprint_area_m2 == 14.4
    assert stored_result.provisional_measurement.quick_peak_height_m == 2.1
    assert stored_result.provisional_measurement.quick_confidence_score == 0.72
    assert stored_result.provisional_measurement.quick_geometry_point_count == 320
    assert stored_result.provisional_measurement.quick_camera_path_distance_m == 18.2

    fetched_result = service.fetch_result(upload_payload["runId"])
    assert fetched_result.provisional_measurement is not None
    assert fetched_result.provisional_measurement.volume_m3 == 2528.43
    assert fetched_result.provisional_measurement.quick_volume_m3 == 1642.1
    assert fetched_result.provisional_measurement.quick_footprint_area_m2 == 14.4
    assert fetched_result.provisional_measurement.quick_peak_height_m == 2.1
    assert fetched_result.provisional_measurement.quick_confidence_score == 0.72
    assert fetched_result.provisional_measurement.quick_geometry_point_count == 320
    assert fetched_result.provisional_measurement.quick_camera_path_distance_m == 18.2


def test_mobile_api_app_scopes_recent_runs_and_capture_sessions_by_site(tmp_path, monkeypatch):
    monkeypatch.delenv("STOCKPILE_MOBILE_API_BEARER_TOKEN", raising=False)
    monkeypatch.delenv("STOCKPILE_MOBILE_API_KEY", raising=False)

    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    runtime = StubRuntime()
    client = TestClient(create_app(service=service, runtime=runtime))

    north_run = _complete_terminal_run(
        client,
        service,
        site_id="qpmc-north-yard",
        pile_name="North Yard 08",
        upload_bytes=b"north-yard-terminal-run",
    )
    south_run = _complete_terminal_run(
        client,
        service,
        site_id="qpmc-south-yard",
        pile_name="South Yard 02",
        upload_bytes=b"south-yard-terminal-run",
    )

    north_session_response = client.get(
        f"/api/mobile/capture-sessions/{north_run['sessionId']}?siteId=qpmc-north-yard"
    )
    assert north_session_response.status_code == 200
    north_session_payload = north_session_response.json()
    assert north_session_payload["siteId"] == "qpmc-north-yard"
    assert north_session_payload["latestRunId"] == north_run["runId"]
    assert north_session_payload["latestJobId"] == north_run["jobId"]
    assert north_session_payload["latestUploadId"] == north_run["uploadId"]
    assert north_session_payload["updatedAt"] is not None

    wrong_site_session_response = client.get(
        f"/api/mobile/capture-sessions/{north_run['sessionId']}?siteId=qpmc-south-yard"
    )
    assert wrong_site_session_response.status_code == 404

    recent_sessions_response = client.get(
        "/api/mobile/capture-sessions/recent?siteId=qpmc-north-yard&limit=5"
    )
    assert recent_sessions_response.status_code == 200
    recent_sessions_payload = recent_sessions_response.json()
    assert len(recent_sessions_payload) == 1
    assert recent_sessions_payload[0]["sessionId"] == north_run["sessionId"]
    assert recent_sessions_payload[0]["siteId"] == "qpmc-north-yard"

    recent_runs_response = client.get("/api/mobile/runs/recent?siteId=qpmc-north-yard&limit=5")
    assert recent_runs_response.status_code == 200
    recent_runs_payload = recent_runs_response.json()
    assert len(recent_runs_payload) == 1
    assert recent_runs_payload[0]["runId"] == north_run["runId"]
    assert recent_runs_payload[0]["siteId"] == "qpmc-north-yard"
    assert recent_runs_payload[0]["sessionId"] == north_run["sessionId"]
    assert recent_runs_payload[0]["jobId"] == north_run["jobId"]

    right_site_result_response = client.get(
        f"/api/mobile/results/{north_run['runId']}?siteId=qpmc-north-yard&sessionId={north_run['sessionId']}"
    )
    assert right_site_result_response.status_code == 200
    assert right_site_result_response.json()["siteId"] == "qpmc-north-yard"
    assert right_site_result_response.json()["sessionId"] == north_run["sessionId"]

    wrong_site_result_response = client.get(
        f"/api/mobile/results/{north_run['runId']}?siteId=qpmc-south-yard"
    )
    assert wrong_site_result_response.status_code == 404

    south_result_response = client.get(
        f"/api/mobile/results/{south_run['runId']}?siteId=qpmc-south-yard"
    )
    assert south_result_response.status_code == 200
    assert south_result_response.json()["siteId"] == "qpmc-south-yard"


def test_mobile_api_app_rejects_upload_when_checksum_mismatches(tmp_path, monkeypatch):
    monkeypatch.delenv("STOCKPILE_MOBILE_API_BEARER_TOKEN", raising=False)
    monkeypatch.delenv("STOCKPILE_MOBILE_API_KEY", raising=False)

    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    runtime = StubRuntime()
    client = TestClient(create_app(service=service, runtime=runtime))
    upload_bytes = b"12345"

    capture_response = client.post(
        "/api/mobile/capture-sessions",
        json=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 05",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    assert capture_response.status_code == 201
    session_id = capture_response.json()["sessionId"]

    upload_response = client.post(
        "/api/mobile/uploads",
        json=UploadRequest(
            session_id=session_id,
            file_name="north-yard-05.mov",
            byte_count=len(upload_bytes),
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(b"54321"),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    assert upload_response.status_code == 201
    upload_payload = upload_response.json()

    content_response = client.put(
        f"/api/mobile/uploads/{upload_payload['uploadId']}/content",
        content=upload_bytes,
        headers={"Content-Type": "video/quicktime"},
    )
    assert content_response.status_code == 422
    assert runtime.started_uploads == []

    job_response = client.get(f"/api/mobile/jobs/{upload_payload['jobId']}")
    assert job_response.status_code == 200
    assert job_response.json()["phase"] == "failed"
    assert "checksum" in job_response.json()["detail"].lower()


def test_mobile_api_app_result_poll_returns_pending_job_state_until_result_is_ready(tmp_path, monkeypatch):
    monkeypatch.delenv("STOCKPILE_MOBILE_API_BEARER_TOKEN", raising=False)
    monkeypatch.delenv("STOCKPILE_MOBILE_API_KEY", raising=False)

    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    runtime = StubRuntime()
    client = TestClient(create_app(service=service, runtime=runtime))
    upload_bytes = b"pending-run-bytes"

    capture_response = client.post(
        "/api/mobile/capture-sessions",
        json=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard Pending",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    session_id = capture_response.json()["sessionId"]

    upload_response = client.post(
        "/api/mobile/uploads",
        json=UploadRequest(
            session_id=session_id,
            file_name="north-yard-pending.mov",
            byte_count=len(upload_bytes),
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(upload_bytes),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    upload_payload = upload_response.json()

    client.put(
        f"/api/mobile/uploads/{upload_payload['uploadId']}/content",
        content=upload_bytes,
        headers={"Content-Type": "video/quicktime"},
    )

    result_response = client.get(f"/api/mobile/results/{upload_payload['runId']}")
    assert result_response.status_code == 404
    assert result_response.headers["x-stockpile-run-state"] == "pending"
    assert result_response.json()["state"] == "pending"
    assert result_response.json()["status"]["phase"] == "upload_received"


def test_mobile_api_app_result_poll_returns_failed_job_state_when_processing_failed(tmp_path, monkeypatch):
    monkeypatch.delenv("STOCKPILE_MOBILE_API_BEARER_TOKEN", raising=False)
    monkeypatch.delenv("STOCKPILE_MOBILE_API_KEY", raising=False)

    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    runtime = StubRuntime()
    client = TestClient(create_app(service=service, runtime=runtime))
    upload_bytes = b"12345"

    capture_response = client.post(
        "/api/mobile/capture-sessions",
        json=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard Failed",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    session_id = capture_response.json()["sessionId"]

    upload_response = client.post(
        "/api/mobile/uploads",
        json=UploadRequest(
            session_id=session_id,
            file_name="north-yard-failed.mov",
            byte_count=len(upload_bytes),
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(b"wrong-checksum"),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    upload_payload = upload_response.json()

    client.put(
        f"/api/mobile/uploads/{upload_payload['uploadId']}/content",
        content=upload_bytes,
        headers={"Content-Type": "video/quicktime"},
    )

    result_response = client.get(f"/api/mobile/results/{upload_payload['runId']}")
    assert result_response.status_code == 404
    assert result_response.headers["x-stockpile-run-state"] == "failed"
    assert result_response.json()["state"] == "failed"
    assert result_response.json()["status"]["phase"] == "failed"


def test_mobile_api_app_finalize_is_idempotent_after_upload_content_handoff(tmp_path, monkeypatch):
    monkeypatch.delenv("STOCKPILE_MOBILE_API_BEARER_TOKEN", raising=False)
    monkeypatch.delenv("STOCKPILE_MOBILE_API_KEY", raising=False)

    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    runtime = StubRuntime()
    client = TestClient(create_app(service=service, runtime=runtime))
    upload_bytes = b"idempotent-finalize-bytes"

    capture_response = client.post(
        "/api/mobile/capture-sessions",
        json=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard Retry",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    session_id = capture_response.json()["sessionId"]

    upload_response = client.post(
        "/api/mobile/uploads",
        json=UploadRequest(
            session_id=session_id,
            file_name="north-yard-retry.mov",
            byte_count=len(upload_bytes),
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(upload_bytes),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    upload_payload = upload_response.json()

    first_content = client.put(
        f"/api/mobile/uploads/{upload_payload['uploadId']}/content",
        content=upload_bytes,
        headers={"Content-Type": "video/quicktime"},
    )
    assert first_content.status_code == 202

    finalize_response = client.post(f"/api/mobile/uploads/{upload_payload['uploadId']}/finalize")
    assert finalize_response.status_code == 204
    assert runtime.started_jobs == {upload_payload["jobId"]}


def test_mobile_api_app_persists_evidence_derived_reference_observations(tmp_path, monkeypatch):
    monkeypatch.delenv("STOCKPILE_MOBILE_API_BEARER_TOKEN", raising=False)
    monkeypatch.delenv("STOCKPILE_MOBILE_API_KEY", raising=False)

    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    monkeypatch.setattr(
        service,
        "_reference_observations_from_evidence_frames",
        lambda frames: (
            ReferenceObservationPayload(
                reference_id="tag36h11:42",
                family="tag36h11",
                frame_time_sec=1.2,
                pose_sample_index=0,
                frame_id="evidence_0001",
                edge_length_px=144.0,
                pixel_area_px=4096.0,
                confidence=0.91,
                state=ReferenceMarkerQuality.CONFIRMED,
            ),
        ),
    )
    runtime = StubRuntime()
    client = TestClient(create_app(service=service, runtime=runtime))

    capture_response = client.post(
        "/api/mobile/capture-sessions",
        json=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard Evidence",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        ).to_dict(),
    )
    session_id = capture_response.json()["sessionId"]

    upload_response = client.post(
        "/api/mobile/uploads",
        json=UploadRequest(
            session_id=session_id,
            file_name="north-yard-evidence.mov",
            byte_count=5,
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(b"12345"),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
            reference_evidence_frames=(
                ReferenceEvidenceFramePayload(
                    frame_id="evidence_0001",
                    time_offset_sec=1.2,
                    pose_sample_index=0,
                    width_px=640,
                    height_px=360,
                    jpeg_base64="ZmFrZS1qcGVn",
                ),
            ),
        ).to_dict(),
    )
    assert upload_response.status_code == 201
    upload_payload = upload_response.json()

    context = service.fetch_upload_context(upload_payload["uploadId"])
    assert len(context.upload_request.reference_evidence_jpeg_frames) == 1
    assert context.upload_request.reference_observations[0].reference_id == "tag36h11:42"
    assert context.upload_request.reference_observations[0].frame_id == "evidence_0001"
