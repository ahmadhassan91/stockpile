from __future__ import annotations

import base64
import hashlib
from tempfile import TemporaryDirectory

from fastapi.testclient import TestClient

from stockpile.mobile_api_app import create_mobile_api_app
from stockpile.mobile_api_models import (
    CaptureMetadataPayload,
    CaptureMode,
    CaptureQualityInputPayload,
    CaptureQualityPayload,
    CaptureSource,
    DevicePoseTelemetryPayload,
    ConfidencePayload,
    DeviceSensorInputPayload,
    MeasurementPayload,
    MobileFirstCapturePayload,
    MobileFirstCaptureStage,
    ReferenceDiagnosticsPayload,
    ReferenceMarkerQuality,
    ReferenceMarkerSnapshotPayload,
    ReferenceObservationPayload,
    ResultPayload,
    RunOutcome,
    TaggedReferenceStrategyMode,
    TaggedReferenceStrategyPayload,
    parse_datetime,
)
from stockpile.mobile_api_service import StockpileMobileAPIService


class StubRuntime:
    def __init__(self):
        self.started_uploads: list[str] = []

    def start_processing_for_upload(self, upload_id: str) -> str:
        self.started_uploads.append(upload_id)
        return upload_id


def _strategy() -> TaggedReferenceStrategyPayload:
    return TaggedReferenceStrategyPayload(
        mode=TaggedReferenceStrategyMode.CONCURRENT_VISIBILITY,
        reference_count_goal=3,
        minimum_visible_reference_count=2,
        preferred_visible_reference_count=3,
    )


def _metadata() -> CaptureMetadataPayload:
    return CaptureMetadataPayload(
        source=CaptureSource.LIVE_RECORDED_VIDEO,
        mode=CaptureMode.GUIDED_WALKAROUND,
        time_zone_identifier="Asia/Karachi",
        active_device_name="iPhone 15 Pro",
    )


def _quality() -> CaptureQualityInputPayload:
    return CaptureQualityInputPayload(
        reference_visibility_score=0.82,
        coverage_score=0.74,
        motion_stability_score=0.91,
        overall_guidance_score=0.79,
        toe_coverage_score=0.76,
        estimated_concurrent_reference_count=3,
        device_sensors=DeviceSensorInputPayload.reserved(),
        mobile_first_capture=MobileFirstCapturePayload(
            stage=MobileFirstCaptureStage.WALKING_PERIMETER,
            reference_marker_snapshots=(
                ReferenceMarkerSnapshotPayload(
                    marker_id="QPMC-01",
                    visible_count=2,
                    confidence=0.94,
                    quality=ReferenceMarkerQuality.CONFIRMED,
                ),
            ),
            device_pose_telemetry=DevicePoseTelemetryPayload(
                sample_count=18,
                motion_stable=True,
                lidar_assist_available=True,
                tracking_state="running",
            ),
            toe_coverage_score=0.76,
            estimated_concurrent_reference_count=3,
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


def _build_client():
    temp_dir = TemporaryDirectory()
    service = StockpileMobileAPIService(
        root_dir=temp_dir.name,
        api_base_url="http://testserver/api/mobile",
        report_base_url="https://portal.example.com/runs",
    )
    runtime = StubRuntime()
    app = create_mobile_api_app(service, runtime)
    client = TestClient(app)
    return temp_dir, service, runtime, client


def test_mobile_api_happy_path():
    temp_dir, service, runtime, client = _build_client()
    try:
        strategy = _strategy()
        metadata = _metadata()
        quality = _quality()
        upload_bytes = b"12345"

        session_response = client.post(
            "/api/mobile/capture-sessions",
            json={
                "siteId": "qpmc-north-yard",
                "pileName": "North Yard 03",
                "materialCode": "backfill-0-75-mm",
                "densityKgPerM3": 2100,
                "referenceCountGoal": 3,
                "clientBuild": "ios-0.1.0(12)",
                "taggedReferenceStrategy": strategy.to_dict(),
                "captureMetadata": metadata.to_dict(),
                "qualityInput": quality.to_dict(),
            },
        )
        assert session_response.status_code == 201
        session_payload = session_response.json()
        assert session_payload["pileName"] == "North Yard 03"
        assert session_payload["qualityInput"]["mobileFirstCapture"]["stage"] == "walking_perimeter"
        assert session_payload["qualityInput"]["mobileFirstCapture"]["devicePoseTelemetry"]["sampleCount"] == 18

        upload_response = client.post(
            "/api/mobile/uploads",
            json={
                "sessionId": session_payload["sessionId"],
                "fileName": "north-yard-03.mov",
                "byteCount": len(upload_bytes),
                "contentType": "video/quicktime",
                "checksumSha256": _sha256_hex(upload_bytes),
                "taggedReferenceStrategy": strategy.to_dict(),
                "captureMetadata": metadata.to_dict(),
                "qualityInput": quality.to_dict(),
            },
        )
        assert upload_response.status_code == 201
        upload_payload = upload_response.json()
        assert upload_payload["uploadUrl"].endswith(
            f"/api/mobile/uploads/{upload_payload['uploadId']}/content",
        )

        upload_content_response = client.put(
            f"/api/mobile/uploads/{upload_payload['uploadId']}/content",
            content=upload_bytes,
            headers={"content-type": "video/quicktime"},
        )
        assert upload_content_response.status_code == 202
        job_payload = upload_content_response.json()
        assert job_payload["phase"] == "upload_received"
        assert job_payload["upload"]["bytesReceived"] == len(upload_bytes)
        assert job_payload["receiptId"] == upload_payload["uploadId"]
        assert upload_content_response.headers["x-stockpile-receipt-id"] == upload_payload["uploadId"]
        assert runtime.started_uploads == [upload_payload["uploadId"]]

        job_status_response = client.get(f"/api/mobile/jobs/{upload_payload['jobId']}")
        assert job_status_response.status_code == 200
        assert job_status_response.json()["runId"] == upload_payload["runId"]

        service.store_result(
            upload_payload["jobId"],
            ResultPayload(
                run_id=upload_payload["runId"],
                pile_name="North Yard 03",
                outcome=RunOutcome.REVIEW_ONLY,
                confidence=ConfidencePayload(
                    score=68,
                    label="Moderate",
                    summary="Processing completed, but the run still needs benchmark review.",
                ),
                measurement=MeasurementPayload(
                    volume_m3=2528.43,
                    weight_tonnes=5309.70,
                    density_kg_per_m3=2100,
                ),
                warnings=["Toe coverage softened on the north edge."],
                blockers=[],
                recommended_action="Review against the latest site benchmark before release.",
                capture_quality=CaptureQualityPayload(
                    reference_visibility_score=0.82,
                    perimeter_coverage_score=0.74,
                    motion_stability_score=0.91,
                    overall_guidance_score=0.79,
                ),
                reference_diagnostics=ReferenceDiagnosticsPayload(
                    target_count=3,
                    minimum_visible_together=2,
                    preferred_visible_count=3,
                    frames_meeting_visibility_goal=42,
                    frames_checked=61,
                    calibration_basis="tagged_reference_plus_camera_pose",
                    calibration_status="needs_review",
                    reference_strategy="tagged_references",
                    references_used=3,
                ),
                report_url=f"https://portal.example.com/runs/{upload_payload['runId']}",
            ),
        )

        result_response = client.get(f"/api/mobile/results/{upload_payload['runId']}")
        assert result_response.status_code == 200
        result_payload = result_response.json()
        assert result_payload["outcome"] == "review_only"
        assert result_payload["measurement"]["volumeM3"] == 2528.43
        assert result_payload["referenceDiagnostics"]["referencesUsed"] == 3
        assert result_payload["updatedAt"] is not None
        assert result_payload["siteId"] == "qpmc-north-yard"
        assert result_payload["sessionId"] == session_payload["sessionId"]
        assert result_payload["jobId"] == upload_payload["jobId"]
        terminal_job_status = service.fetch_processing_job(upload_payload["jobId"])
        assert parse_datetime(result_payload["updatedAt"]) == terminal_job_status.updated_at

        capture_session_response = client.get(
            f"/api/mobile/capture-sessions/{session_payload['sessionId']}?siteId=qpmc-north-yard"
        )
        assert capture_session_response.status_code == 200
        capture_session_payload = capture_session_response.json()
        assert capture_session_payload["latestRunId"] == upload_payload["runId"]
        assert capture_session_payload["latestJobId"] == upload_payload["jobId"]
        assert capture_session_payload["latestUploadId"] == upload_payload["uploadId"]

        recent_runs_response = client.get("/api/mobile/runs/recent?limit=2&siteId=qpmc-north-yard")
        assert recent_runs_response.status_code == 200
        recent_runs_payload = recent_runs_response.json()
        assert len(recent_runs_payload) == 1
        assert recent_runs_payload[0]["runId"] == upload_payload["runId"]
        assert recent_runs_payload[0]["updatedAt"] == result_payload["updatedAt"]
        assert recent_runs_payload[0]["siteId"] == "qpmc-north-yard"
        assert recent_runs_payload[0]["sessionId"] == session_payload["sessionId"]
        assert recent_runs_payload[0]["jobId"] == upload_payload["jobId"]
    finally:
        client.close()
        temp_dir.cleanup()


def test_mobile_api_enriches_reference_observations_from_reference_evidence_frames(
    monkeypatch,
):
    temp_dir, service, runtime, client = _build_client()
    try:
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

        session_response = client.post(
            "/api/mobile/capture-sessions",
            json={
                "siteId": "qpmc-north-yard",
                "pileName": "North Yard 03",
                "materialCode": "backfill-0-75-mm",
                "densityKgPerM3": 2100,
                "referenceCountGoal": 3,
                "clientBuild": "ios-0.1.0(12)",
                "taggedReferenceStrategy": _strategy().to_dict(),
                "captureMetadata": _metadata().to_dict(),
                "qualityInput": {
                    "referenceVisibilityScore": 0.72,
                    "coverageScore": 0.69,
                    "motionStabilityScore": 0.84,
                    "overallGuidanceScore": 0.73,
                    "toeCoverageScore": 0.71,
                    "deviceSensors": {
                        "motionSignalsIncluded": False,
                        "gravityVectorIncluded": False,
                        "headingSignalsIncluded": False,
                        "cameraCalibrationIncluded": False,
                    },
                },
            },
        )
        assert session_response.status_code == 201
        session_payload = session_response.json()

        upload_response = client.post(
            "/api/mobile/uploads",
            json={
                "sessionId": session_payload["sessionId"],
                "fileName": "north-yard-03.mov",
                "byteCount": 18,
                "contentType": "video/quicktime",
                "taggedReferenceStrategy": _strategy().to_dict(),
                "captureMetadata": _metadata().to_dict(),
                "qualityInput": {
                    "referenceVisibilityScore": 0.72,
                    "coverageScore": 0.69,
                    "motionStabilityScore": 0.84,
                    "overallGuidanceScore": 0.73,
                    "toeCoverageScore": 0.71,
                    "deviceSensors": {
                        "motionSignalsIncluded": False,
                        "gravityVectorIncluded": False,
                        "headingSignalsIncluded": False,
                        "cameraCalibrationIncluded": False,
                    },
                },
                "referenceEvidenceJPEGFrames": [
                    _reference_evidence_frame_payload(
                        frame_id="frame_0010",
                        time_offset_sec=2.5,
                        pose_sample_index=7,
                    ),
                ],
            },
        )
        assert upload_response.status_code == 201
        upload_payload = upload_response.json()

        upload_context = service.fetch_upload_context(upload_payload["uploadId"])
        assert len(upload_context.upload_request.reference_evidence_frames) == 1
        assert len(upload_context.upload_request.reference_observations) == 1

        derived_observation = upload_context.upload_request.reference_observations[0]
        assert derived_observation.reference_id == "tag36h11:11"
        assert derived_observation.family == "tag36h11"
        assert derived_observation.frame_id == "frame_0010"
        assert derived_observation.pose_sample_index == 7
        assert derived_observation.frame_time_sec == 2.5
        assert derived_observation.confidence == 0.91
        assert derived_observation.state == ReferenceMarkerQuality.CONFIRMED
        assert derived_observation.pixel_area_px == 5184.0
    finally:
        client.close()
        temp_dir.cleanup()


def test_mobile_api_missing_entities_return_404():
    temp_dir, _, _, client = _build_client()
    try:
        missing_job = client.get("/api/mobile/jobs/job_missing")
        assert missing_job.status_code == 404

        missing_result = client.get("/api/mobile/results/run_missing")
        assert missing_result.status_code == 404

        missing_upload = client.put(
            "/api/mobile/uploads/upload_missing/content",
            content=b"123",
            headers={"content-type": "video/quicktime"},
        )
        assert missing_upload.status_code == 404
    finally:
        client.close()
        temp_dir.cleanup()


def test_mobile_api_rejects_mismatched_upload_checksum():
    temp_dir, service, runtime, client = _build_client()
    try:
        strategy = _strategy()
        metadata = _metadata()
        quality = _quality()
        upload_bytes = b"abcde"

        session_response = client.post(
            "/api/mobile/capture-sessions",
            json={
                "siteId": "qpmc-north-yard",
                "pileName": "North Yard 07",
                "materialCode": "backfill-0-75-mm",
                "densityKgPerM3": 2100,
                "referenceCountGoal": 3,
                "clientBuild": "ios-0.1.0(12)",
                "taggedReferenceStrategy": strategy.to_dict(),
                "captureMetadata": metadata.to_dict(),
                "qualityInput": quality.to_dict(),
            },
        )
        assert session_response.status_code == 201
        session_payload = session_response.json()

        upload_response = client.post(
            "/api/mobile/uploads",
            json={
                "sessionId": session_payload["sessionId"],
                "fileName": "north-yard-07.mov",
                "byteCount": len(upload_bytes),
                "contentType": "video/quicktime",
                "checksumSha256": _sha256_hex(b"edcba"),
                "taggedReferenceStrategy": strategy.to_dict(),
                "captureMetadata": metadata.to_dict(),
                "qualityInput": quality.to_dict(),
            },
        )
        assert upload_response.status_code == 201
        upload_payload = upload_response.json()

        upload_content_response = client.put(
            f"/api/mobile/uploads/{upload_payload['uploadId']}/content",
            content=upload_bytes,
            headers={"content-type": "video/quicktime"},
        )
        assert upload_content_response.status_code == 422
        assert runtime.started_uploads == []

        job_status_response = client.get(f"/api/mobile/jobs/{upload_payload['jobId']}")
        assert job_status_response.status_code == 200
        assert job_status_response.json()["phase"] == "failed"
        assert "checksum" in job_status_response.json()["detail"].lower()
    finally:
        client.close()
        temp_dir.cleanup()


def test_mobile_api_upload_authorization_enriches_reference_observations_from_evidence_frames(monkeypatch):
    temp_dir, service, _, client = _build_client()
    try:
        strategy = _strategy()
        metadata = _metadata()
        quality = _quality()
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

        session_response = client.post(
            "/api/mobile/capture-sessions",
            json={
                "siteId": "qpmc-north-yard",
                "pileName": "North Yard Evidence",
                "materialCode": "backfill-0-75-mm",
                "densityKgPerM3": 2100,
                "referenceCountGoal": 3,
                "clientBuild": "ios-0.1.0(12)",
                "taggedReferenceStrategy": strategy.to_dict(),
                "captureMetadata": metadata.to_dict(),
                "qualityInput": quality.to_dict(),
            },
        )
        assert session_response.status_code == 201
        session_payload = session_response.json()

        upload_response = client.post(
            "/api/mobile/uploads",
            json={
                "sessionId": session_payload["sessionId"],
                "fileName": "north-yard-evidence.mov",
                "byteCount": 5,
                "contentType": "video/quicktime",
                "checksumSha256": _sha256_hex(b"12345"),
                "taggedReferenceStrategy": strategy.to_dict(),
                "captureMetadata": metadata.to_dict(),
                "qualityInput": quality.to_dict(),
                "referenceEvidenceJPEGFrames": [
                    {
                        "frameId": "evidence_0001",
                        "timeOffsetSec": 1.2,
                        "poseSampleIndex": 0,
                        "widthPx": 640,
                        "heightPx": 360,
                        "jpegBase64": "ZmFrZS1qcGVn",
                    },
                ],
            },
        )
        assert upload_response.status_code == 201
        upload_payload = upload_response.json()

        context = service.fetch_upload_context(upload_payload["uploadId"])
        assert len(context.upload_request.reference_evidence_jpeg_frames) == 1
        assert context.upload_request.reference_evidence_jpeg_frames[0].frame_id == "evidence_0001"
        assert len(context.upload_request.reference_observations) == 1
        assert context.upload_request.reference_observations[0].reference_id == "tag36h11:42"
        assert context.upload_request.reference_observations[0].frame_id == "evidence_0001"
    finally:
        client.close()
        temp_dir.cleanup()
