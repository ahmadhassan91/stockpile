from __future__ import annotations

import hashlib
import math
from pathlib import Path
from types import SimpleNamespace

import pytest

from stockpile.mobile_api_models import (
    CaptureSensorMetadataPayload,
    CaptureMetadataPayload,
    CaptureMode,
    CaptureQualityInputPayload,
    CaptureSessionCreateRequest,
    CaptureSource,
    DevicePoseSamplePayload,
    DeviceSensorInputPayload,
    JobPhase,
    MobileFirstCapturePayload,
    MobileFirstCaptureStage,
    OnDeviceVisionPayload,
    ReferenceEvidenceFramePayload,
    ReferenceMarkerQuality,
    ReferenceObservationPayload,
    TaggedReferenceStrategyMode,
    TaggedReferenceStrategyPayload,
    UploadRequest,
    Vector3Payload,
)
from stockpile.mobile_api_service import ResultNotFoundError, StockpileMobileAPIService
from stockpile.mobile_job_runtime import (
    StockpileMobileJobRuntime,
    StockpileMobileJobRuntimeConfiguration,
    _mobile_capture_prior_from_upload_context,
)


def _tagged_reference_strategy() -> TaggedReferenceStrategyPayload:
    return TaggedReferenceStrategyPayload(
        mode=TaggedReferenceStrategyMode.CONCURRENT_VISIBILITY,
        reference_count_goal=3,
        minimum_visible_reference_count=2,
        preferred_visible_reference_count=3,
    )


def _capture_metadata(
    *,
    sensor_metadata: CaptureSensorMetadataPayload | None = None,
) -> CaptureMetadataPayload:
    return CaptureMetadataPayload(
        source=CaptureSource.LIVE_RECORDED_VIDEO,
        mode=CaptureMode.GUIDED_WALKAROUND,
        time_zone_identifier="Asia/Karachi",
        active_device_name="iPhone",
        capture_phase="guided_capture",
        session_lifecycle="ready",
        recording_lifecycle="recorded",
        sensor_metadata=sensor_metadata,
    )


def _quality_input() -> CaptureQualityInputPayload:
    return CaptureQualityInputPayload(
        reference_visibility_score=0.83,
        coverage_score=0.88,
        motion_stability_score=0.92,
        overall_guidance_score=0.86,
        device_sensors=DeviceSensorInputPayload(
            motion_signals_included=True,
            gravity_vector_included=True,
            heading_signals_included=True,
            camera_calibration_included=False,
        ),
    )


def _sha256_hex(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _pose_sample(
    *,
    sample_index: int = 0,
    time_offset_sec: float = 0.0,
    tracking_state: str | None = "normal",
    horizontal_accuracy_m: float | None = 0.05,
    vertical_accuracy_m: float | None = 0.05,
    include_pose: bool = True,
) -> DevicePoseSamplePayload:
    return DevicePoseSamplePayload(
        sample_index=sample_index,
        time_offset_sec=time_offset_sec,
        position_m=Vector3Payload(0.0, 0.0, 0.0) if include_pose else None,
        yaw_pitch_roll_deg=Vector3Payload(0.0, 0.0, 0.0) if include_pose else None,
        tracking_state=tracking_state,
        horizontal_accuracy_m=horizontal_accuracy_m,
        vertical_accuracy_m=vertical_accuracy_m,
    )


def _reference_observation(marker_id: str, frame_id: str) -> ReferenceObservationPayload:
    return ReferenceObservationPayload(
        reference_id=marker_id,
        family="tag36h11",
        frame_id=frame_id,
        pose_sample_index=0,
        pixel_area_px=1440.0,
        confidence=0.94,
        state=ReferenceMarkerQuality.CONFIRMED,
    )


def _reference_evidence_frame(frame_id: str, time_offset_sec: float) -> ReferenceEvidenceFramePayload:
    return ReferenceEvidenceFramePayload(
        frame_id=frame_id,
        time_offset_sec=time_offset_sec,
        jpeg_base64="ZmFrZS1qcGVn",
    )


class FakePipeline:
    def __init__(self, config):
        self.config = config

    def run(self, video_path: str | Path):
        assert Path(video_path).exists()
        self.config.progress_callback("frame_extraction", 0.15, "Extracting frames for alpha test.")
        self.config.progress_callback("cone_detection", 0.35, "Detecting tagged references.")
        self.config.progress_callback("colmap_reconstruction", 0.6, "Reconstructing geometry.")
        self.config.progress_callback("scale_calibration", 0.8, "Calibrating scale.")
        self.config.progress_callback("volume_computation", 1.0, "Computing final volume.")
        return SimpleNamespace(
            publishable=True,
            review_grade=False,
            quality_warnings=[],
            quality_blockers=[],
            weight_kg=3_868_200.0,
            volume=SimpleNamespace(recommended_m3=1842.0),
            calibration=SimpleNamespace(
                confidence=0.91,
                selected_method="tagged_reference_projection",
                frames_with_multiple_detections=42,
                registered_cone_frames=58,
                detected_cone_frames=63,
                num_cones_used=3,
                num_references_used=3,
                reference_family="tag36h11",
            ),
            reference_strategy="tagged_references",
        )


def test_mobile_job_runtime_processes_uploaded_capture(tmp_path):
    upload_bytes = b"alpha-bytes"
    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    session = service.create_capture_session(
        request=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 03",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    upload = service.create_upload_authorization(
        UploadRequest(
            session_id=session.session_id,
            file_name="north-yard-03.mov",
            byte_count=len(upload_bytes),
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(upload_bytes),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    artifact = service.save_upload_bytes(upload.upload_id, upload_bytes, finalize=True)
    assert artifact.storage_path.exists()

    runtime = StockpileMobileJobRuntime(
        service,
        configuration=StockpileMobileJobRuntimeConfiguration(
            workspace_root=tmp_path / "workspaces",
        ),
        pipeline_factory=FakePipeline,
    )

    job_id = runtime.start_processing_for_upload(upload.upload_id)
    assert job_id == upload.job_id
    assert runtime.wait_for_job(job_id, timeout=5.0) is True

    status = service.fetch_processing_job(job_id)
    result = service.fetch_result(upload.run_id or upload.upload_id)

    assert status.phase.value == "verified"
    assert result.outcome.value == "verified"
    assert result.measurement is not None
    assert result.measurement.volume_m3 == 1842.0
    assert result.reference_diagnostics is not None
    assert result.reference_diagnostics.reference_strategy == "tagged_references"


def test_mobile_job_runtime_filters_mobile_capture_priors_from_upload_context(tmp_path):
    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    session = service.create_capture_session(
        request=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 05",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(
                sensor_metadata=CaptureSensorMetadataPayload(
                    pose_sampling_hz=4.0,
                    depth_data_included=True,
                )
            ),
            quality_input=_quality_input(),
        )
    )
    upload = service.create_upload_authorization(
        UploadRequest(
            session_id=session.session_id,
            file_name="north-yard-05.mov",
            byte_count=128,
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(b"mobile-prior-filtering"),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(
                sensor_metadata=CaptureSensorMetadataPayload(
                    pose_sampling_hz=4.0,
                    depth_data_included=True,
                )
            ),
            quality_input=_quality_input(),
            pose_samples=(
                _pose_sample(sample_index=0, time_offset_sec=0.10),
                _pose_sample(sample_index=1, time_offset_sec=0.80, tracking_state="limited"),
                _pose_sample(sample_index=2, time_offset_sec=0.90),
                _pose_sample(sample_index=3, time_offset_sec=1.00),
                _pose_sample(sample_index=4, time_offset_sec=1.40, horizontal_accuracy_m=1.5),
                _pose_sample(sample_index=5, time_offset_sec=1.60, include_pose=False),
                _pose_sample(sample_index=6, time_offset_sec=1.90),
                _pose_sample(sample_index=7, time_offset_sec=2.20, tracking_state="tracking"),
                _pose_sample(sample_index=8, time_offset_sec=2.60, tracking_state="tracking"),
            ),
            reference_evidence_frames=(
                _reference_evidence_frame("frame-0001", 0.55),
                _reference_evidence_frame("frame-0002", 1.90),
                _reference_evidence_frame("frame-0003", 1.90),
            ),
        )
    )

    context = service.fetch_upload_context(upload.upload_id)
    prior = _mobile_capture_prior_from_upload_context(context)

    assert prior.reference_evidence_timestamps_sec == (0.55, 1.9)
    assert prior.useful_pose_sample_timestamps_sec == (0.9, 1.9, 2.6)
    assert prior.reference_evidence_count == 3
    assert prior.pose_sample_count == 9
    assert prior.useful_pose_sample_count == 3
    assert prior.depth_data_included is True


def test_mobile_job_runtime_uses_on_device_vision_segmentation_scores_when_top_level_scores_are_nil(tmp_path):
    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    session = service.create_capture_session(
        request=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard Vision",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    vision_quality_input = CaptureQualityInputPayload(
        reference_visibility_score=0.89,
        coverage_score=0.91,
        motion_stability_score=0.87,
        overall_guidance_score=0.9,
        device_sensors=DeviceSensorInputPayload(
            motion_signals_included=True,
            gravity_vector_included=True,
            heading_signals_included=True,
            camera_calibration_included=False,
        ),
        mobile_first_capture=MobileFirstCapturePayload(
            stage=MobileFirstCaptureStage.WALKING_PERIMETER,
            on_device_vision=OnDeviceVisionPayload(
                source="vision_foreground_instance_mask",
                uses_machine_learning=True,
                pile_segmentation_score=0.83,
                toe_segmentation_score=0.77,
                segmentation_confidence_score=0.8,
            ),
        ),
    )
    upload = service.create_upload_authorization(
        UploadRequest(
            session_id=session.session_id,
            file_name="north-yard-vision.mov",
            byte_count=128,
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(b"on-device-vision-priors"),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=vision_quality_input,
        )
    )

    context = service.fetch_upload_context(upload.upload_id)
    prior = _mobile_capture_prior_from_upload_context(context)

    assert prior.pile_segmentation_score == pytest.approx(0.83)
    assert prior.toe_segmentation_score == pytest.approx(0.77)
    assert prior.segmentation_confidence_score == pytest.approx(0.8)


def test_mobile_job_runtime_passes_mobile_upload_priors_into_pipeline_config(tmp_path):
    upload_bytes = b"alpha-bytes-with-mobile-priors"
    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    session = service.create_capture_session(
        request=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 09",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    prior_quality_input = CaptureQualityInputPayload(
        reference_visibility_score=0.89,
        coverage_score=0.91,
        motion_stability_score=0.87,
        overall_guidance_score=0.9,
        toe_coverage_score=0.76,
        estimated_concurrent_reference_count=2,
        device_sensors=DeviceSensorInputPayload(
            motion_signals_included=True,
            gravity_vector_included=True,
            heading_signals_included=True,
            camera_calibration_included=False,
        ),
        mobile_first_capture=MobileFirstCapturePayload(
            stage=MobileFirstCaptureStage.WALKING_PERIMETER,
            toe_coverage_score=0.76,
            pile_segmentation_score=0.73,
            toe_segmentation_score=0.68,
            segmentation_confidence_score=0.71,
            estimated_concurrent_reference_count=2,
            quick_volume_m3=19.64,
            quick_footprint_area_m2=11.8,
            quick_peak_height_m=2.3,
            quick_confidence_score=0.82,
            quick_geometry_point_count=155_551,
            quick_camera_path_distance_m=18.2,
        ),
    )
    upload_request = UploadRequest(
        session_id=session.session_id,
        file_name="north-yard-09.mov",
        byte_count=len(upload_bytes),
        content_type="video/quicktime",
        checksum_sha256=_sha256_hex(upload_bytes),
        tagged_reference_strategy=_tagged_reference_strategy(),
        capture_metadata=_capture_metadata(),
        quality_input=prior_quality_input,
        pose_samples=(_pose_sample(),),
        reference_observations=(_reference_observation("tag36h11:7", "frame-0001"),),
    )
    upload = service.create_upload_authorization(upload_request)
    service.save_upload_bytes(upload.upload_id, upload_bytes, finalize=True)

    recorded = {}

    class RecordingPipeline:
        def __init__(self, config):
            recorded["config"] = config

        def run(self, video_path: str | Path):
            assert Path(video_path).exists()
            return SimpleNamespace(
                publishable=True,
                review_grade=False,
                quality_warnings=[],
                quality_blockers=[],
                weight_kg=3_868_200.0,
                volume=SimpleNamespace(recommended_m3=1842.0),
                calibration=SimpleNamespace(
                    confidence=0.91,
                    selected_method="tagged_reference_projection",
                    frames_with_multiple_detections=42,
                    registered_cone_frames=58,
                    detected_cone_frames=63,
                    num_cones_used=3,
                    num_references_used=3,
                    reference_family="tag36h11",
                    mobile_pose_scale_factor=1.12,
                    mobile_pose_confidence=0.66,
                ),
                reference_strategy="tagged_references",
            )

    runtime = StockpileMobileJobRuntime(
        service,
        configuration=StockpileMobileJobRuntimeConfiguration(
            workspace_root=tmp_path / "workspaces",
        ),
        pipeline_factory=RecordingPipeline,
    )

    job_id = runtime.start_processing_for_upload(upload.upload_id)
    assert runtime.wait_for_job(job_id, timeout=5.0) is True

    config = recorded["config"]
    assert config.workspace == tmp_path / "workspaces" / upload.job_id
    assert config.material_density == pytest.approx(2100.0)
    assert config.material_name == "backfill-0-75-mm"
    assert getattr(config, "tagged_reference_strategy", None) == upload_request.tagged_reference_strategy
    assert getattr(config, "capture_metadata", None) == upload_request.capture_metadata
    assert getattr(config, "quality_input", None) == upload_request.quality_input
    assert getattr(config, "pose_samples", None) == upload_request.pose_samples
    assert getattr(config, "reference_observations", None) == upload_request.reference_observations
    assert config.quality_input.mobile_first_capture is not None
    assert config.quality_input.mobile_first_capture.stage is MobileFirstCaptureStage.WALKING_PERIMETER
    assert config.quality_input.mobile_first_capture.toe_coverage_score == pytest.approx(0.76)
    assert config.mobile_capture_prior is not None
    assert config.mobile_capture_prior.pile_segmentation_score == pytest.approx(0.73)
    assert config.mobile_capture_prior.toe_segmentation_score == pytest.approx(0.68)
    assert config.mobile_capture_prior.segmentation_confidence_score == pytest.approx(0.71)
    assert config.mobile_capture_prior.quick_volume_m3 == pytest.approx(19.64)
    assert config.mobile_capture_prior.quick_confidence_score == pytest.approx(0.82)
    assert config.mobile_capture_prior.quick_geometry_point_count == 155_551
    assert config.mobile_capture_prior.quick_camera_path_distance_m == pytest.approx(18.2)


def test_mobile_job_runtime_preserves_pose_anchored_capture_metadata_for_pipeline_cross_check(tmp_path):
    upload_bytes = b"alpha-bytes-for-pose-cross-check"
    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    capture_metadata = _capture_metadata(
        sensor_metadata=CaptureSensorMetadataPayload(
            device_model_identifier="iPhone17,2",
            video_width=1920,
            video_height=1080,
            video_frame_rate=30.0,
            pose_sampling_hz=6.0,
            depth_data_included=True,
            world_alignment="gravityAndHeading",
            video_stabilization_mode="standard",
        )
    )
    session = service.create_capture_session(
        request=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard Pose",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=capture_metadata,
            quality_input=_quality_input(),
        )
    )

    pose_samples = (
        DevicePoseSamplePayload(
            sample_index=2,
            time_offset_sec=1.01,
            position_m=Vector3Payload(0.0, 0.0, 0.0),
            yaw_pitch_roll_deg=Vector3Payload(2.0, -1.5, 0.0),
            tracking_state="tracking",
            horizontal_accuracy_m=0.05,
            vertical_accuracy_m=0.08,
        ),
        DevicePoseSamplePayload(
            sample_index=5,
            time_offset_sec=1.46,
            position_m=Vector3Payload(0.42, 0.03, 0.01),
            yaw_pitch_roll_deg=Vector3Payload(6.0, -1.0, 0.5),
            tracking_state="tracking",
            horizontal_accuracy_m=0.06,
            vertical_accuracy_m=0.09,
        ),
        DevicePoseSamplePayload(
            sample_index=9,
            time_offset_sec=1.93,
            position_m=Vector3Payload(0.93, 0.06, 0.02),
            yaw_pitch_roll_deg=Vector3Payload(12.0, -0.5, 1.0),
            tracking_state="tracking",
            horizontal_accuracy_m=0.07,
            vertical_accuracy_m=0.11,
        ),
    )
    reference_observations = (
        ReferenceObservationPayload(
            reference_id="tag36h11:7",
            family="tag36h11",
            frame_time_sec=1.03,
            pose_sample_index=2,
            frame_id="frame-0001",
            pixel_area_px=1880.0,
            confidence=0.95,
            state=ReferenceMarkerQuality.CONFIRMED,
        ),
        ReferenceObservationPayload(
            reference_id="tag36h11:9",
            family="tag36h11",
            frame_time_sec=1.49,
            pose_sample_index=5,
            frame_id="frame-0002",
            pixel_area_px=1760.0,
            confidence=0.94,
            state=ReferenceMarkerQuality.CONFIRMED,
        ),
        ReferenceObservationPayload(
            reference_id="tag36h11:11",
            family="tag36h11",
            frame_time_sec=1.95,
            pose_sample_index=9,
            frame_id="frame-0003",
            pixel_area_px=1690.0,
            confidence=0.93,
            state=ReferenceMarkerQuality.CONFIRMED,
        ),
    )
    upload_request = UploadRequest(
        session_id=session.session_id,
        file_name="north-yard-pose.mov",
        byte_count=len(upload_bytes),
        content_type="video/quicktime",
        checksum_sha256=_sha256_hex(upload_bytes),
        tagged_reference_strategy=_tagged_reference_strategy(),
        capture_metadata=capture_metadata,
        quality_input=_quality_input(),
        pose_samples=pose_samples,
        reference_observations=reference_observations,
    )
    upload = service.create_upload_authorization(upload_request)
    service.save_upload_bytes(upload.upload_id, upload_bytes, finalize=True)

    durable_context = service.fetch_upload_context(upload.upload_id)
    assert durable_context.upload_request.capture_metadata == capture_metadata
    assert durable_context.upload_request.pose_samples == pose_samples
    assert durable_context.upload_request.reference_observations == reference_observations

    recorded = {}

    class PoseCrossCheckPipeline:
        def __init__(self, config):
            self.config = config

        def run(self, video_path: str | Path):
            assert Path(video_path).exists()
            assert callable(self.config.progress_callback)

            runtime_capture_metadata = getattr(self.config, "capture_metadata", None)
            assert runtime_capture_metadata == capture_metadata
            assert runtime_capture_metadata is not None
            assert runtime_capture_metadata.capture_phase == "guided_capture"
            assert runtime_capture_metadata.recording_lifecycle == "recorded"

            sensor_metadata = runtime_capture_metadata.sensor_metadata
            assert sensor_metadata is not None
            assert sensor_metadata.pose_sampling_hz == pytest.approx(6.0)
            assert sensor_metadata.world_alignment == "gravityAndHeading"
            assert sensor_metadata.depth_data_included is True

            runtime_pose_samples = getattr(self.config, "pose_samples", ())
            runtime_observations = getattr(self.config, "reference_observations", ())
            assert runtime_pose_samples == pose_samples
            assert runtime_observations == reference_observations

            pose_by_index = {sample.sample_index: sample for sample in runtime_pose_samples}
            matched_positions: list[tuple[float, float, float]] = []
            matched_indices: list[int] = []
            for observation in runtime_observations:
                assert observation.pose_sample_index is not None
                pose_sample = pose_by_index.get(observation.pose_sample_index)
                assert pose_sample is not None
                assert pose_sample.position_m is not None
                assert pose_sample.yaw_pitch_roll_deg is not None
                assert observation.frame_time_sec is not None
                assert (
                    abs(float(observation.frame_time_sec) - float(pose_sample.time_offset_sec))
                    <= self.config.scale_calibration.max_mobile_pose_time_offset_sec
                )
                matched_positions.append(
                    (
                        float(pose_sample.position_m.x),
                        float(pose_sample.position_m.y),
                        float(pose_sample.position_m.z),
                    )
                )
                matched_indices.append(int(pose_sample.sample_index))

            assert len(matched_positions) >= self.config.scale_calibration.min_mobile_pose_matches
            max_pair_span_m = 0.0
            for index, origin in enumerate(matched_positions):
                for candidate in matched_positions[index + 1 :]:
                    max_pair_span_m = max(max_pair_span_m, math.dist(origin, candidate))
            assert max_pair_span_m >= self.config.scale_calibration.min_mobile_pose_pair_span_m

            recorded["matched_pose_sample_indices"] = tuple(matched_indices)
            recorded["max_pair_span_m"] = max_pair_span_m
            self.config.progress_callback(
                "scale_calibration",
                0.5,
                "Mobile pose cross-check matched anchored observations.",
            )
            return SimpleNamespace(
                publishable=True,
                review_grade=False,
                quality_warnings=[],
                quality_blockers=[],
                weight_kg=3_868_200.0,
                volume=SimpleNamespace(recommended_m3=1842.0),
                calibration=SimpleNamespace(
                    confidence=0.91,
                    selected_method="tagged_reference_projection",
                    frames_with_multiple_detections=42,
                    registered_cone_frames=58,
                    detected_cone_frames=63,
                    num_cones_used=3,
                    num_references_used=3,
                    reference_family="tag36h11",
                ),
                reference_strategy="tagged_references",
            )

    runtime = StockpileMobileJobRuntime(
        service,
        configuration=StockpileMobileJobRuntimeConfiguration(
            workspace_root=tmp_path / "workspaces",
        ),
        pipeline_factory=PoseCrossCheckPipeline,
    )

    job_id = runtime.start_processing_for_upload(upload.upload_id)
    assert runtime.wait_for_job(job_id, timeout=5.0) is True

    status = service.fetch_processing_job(job_id)
    result = service.fetch_result(upload.run_id or upload.upload_id)

    assert status.phase is JobPhase.VERIFIED
    assert result.outcome.value == "verified"
    assert recorded["matched_pose_sample_indices"] == (2, 5, 9)
    assert recorded["max_pair_span_m"] >= 0.35
    assert result.reference_diagnostics is not None
    assert (
        result.reference_diagnostics.calibration_basis
        == "tag36h11_plus_camera_pose_plus_mobile_pose_provenance"
    )


def test_mobile_job_runtime_marks_pipeline_error_result_as_failed_job(tmp_path):
    upload_bytes = b"alpha-bytes"
    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    session = service.create_capture_session(
        request=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 04",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    upload = service.create_upload_authorization(
        UploadRequest(
            session_id=session.session_id,
            file_name="north-yard-04.mov",
            byte_count=len(upload_bytes),
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(upload_bytes),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    service.save_upload_bytes(upload.upload_id, upload_bytes, finalize=True)

    class ErrorResultPipeline:
        def __init__(self, config):
            self.config = config

        def run(self, video_path: str | Path):
            self.config.progress_callback("colmap_reconstruction", 0.6, "Reconstructing geometry.")
            return SimpleNamespace(
                publishable=False,
                review_grade=False,
                quality_warnings=[],
                quality_blockers=["Sparse reconstruction failed to register enough frames."],
                weight_kg=0.0,
                volume=None,
                calibration=None,
                reference_strategy="tagged_references",
                stage="colmap_reconstruction",
                error="COLMAP produced no usable sparse model.",
            )

    runtime = StockpileMobileJobRuntime(
        service,
        configuration=StockpileMobileJobRuntimeConfiguration(
            workspace_root=tmp_path / "workspaces",
        ),
        pipeline_factory=ErrorResultPipeline,
    )

    job_id = runtime.start_processing_for_upload(upload.upload_id)
    assert runtime.wait_for_job(job_id, timeout=5.0) is True

    status = service.fetch_processing_job(job_id)

    assert status.phase is JobPhase.FAILED
    assert "colmap reconstruction" in status.detail.lower()
    assert "Sparse reconstruction failed to register enough frames." in status.detail
    with pytest.raises(ResultNotFoundError):
        service.fetch_result(upload.run_id or upload.upload_id)


def test_mobile_job_runtime_resumes_pending_jobs_from_durable_uploads(tmp_path):
    upload_bytes = b"resumable-alpha-bytes"
    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    session = service.create_capture_session(
        request=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 06",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    upload = service.create_upload_authorization(
        UploadRequest(
            session_id=session.session_id,
            file_name="north-yard-06.mov",
            byte_count=len(upload_bytes),
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(upload_bytes),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    service.save_upload_bytes(upload.upload_id, upload_bytes, finalize=True)

    runtime = StockpileMobileJobRuntime(
        service,
        configuration=StockpileMobileJobRuntimeConfiguration(
            workspace_root=tmp_path / "workspaces",
        ),
        pipeline_factory=FakePipeline,
    )

    resumed = runtime.resume_pending_jobs()
    assert resumed == [upload.job_id]
    assert runtime.wait_for_job(upload.job_id, timeout=5.0) is True

    status = service.fetch_processing_job(upload.job_id)
    assert status.phase is JobPhase.VERIFIED


def test_mobile_job_runtime_start_processing_for_upload_finalizes_authorized_upload(tmp_path):
    upload_bytes = b"authorized-upload-bytes"
    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    session = service.create_capture_session(
        request=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 07",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    upload = service.create_upload_authorization(
        UploadRequest(
            session_id=session.session_id,
            file_name="north-yard-07.mov",
            byte_count=len(upload_bytes),
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(upload_bytes),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    service.save_upload_file(upload.upload_id, source_path=_write_temp_upload(tmp_path, upload_bytes), finalize=False)

    runtime = StockpileMobileJobRuntime(
        service,
        configuration=StockpileMobileJobRuntimeConfiguration(
            workspace_root=tmp_path / "workspaces",
        ),
        pipeline_factory=FakePipeline,
    )

    job_id = runtime.start_processing_for_upload(upload.upload_id)
    assert runtime.wait_for_job(job_id, timeout=5.0) is True

    status = service.fetch_processing_job(job_id)
    assert status.phase is JobPhase.VERIFIED


def test_mobile_job_runtime_downgrades_publishable_result_when_mobile_reference_recovery_is_weak(tmp_path):
    upload_bytes = b"weak-mobile-references"
    service = StockpileMobileAPIService(
        root_dir=tmp_path / "mobile_api",
        api_base_url="http://testserver/api/mobile",
    )
    session = service.create_capture_session(
        request=CaptureSessionCreateRequest(
            site_id="qpmc-north-yard",
            pile_name="North Yard 08",
            material_code="backfill-0-75-mm",
            density_kg_per_m3=2100,
            reference_count_goal=3,
            client_build="ios-alpha",
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
        )
    )
    upload = service.create_upload_authorization(
        UploadRequest(
            session_id=session.session_id,
            file_name="north-yard-08.mov",
            byte_count=len(upload_bytes),
            content_type="video/quicktime",
            checksum_sha256=_sha256_hex(upload_bytes),
            tagged_reference_strategy=_tagged_reference_strategy(),
            capture_metadata=_capture_metadata(),
            quality_input=_quality_input(),
            pose_samples=(_pose_sample(),),
            reference_observations=(_reference_observation("tag36h11:7", "frame-0001"),),
        )
    )
    service.save_upload_bytes(upload.upload_id, upload_bytes, finalize=True)

    class WeakReferencePipeline:
        def __init__(self, config):
            self.config = config

        def run(self, video_path: str | Path):
            assert Path(video_path).exists()
            self.config.progress_callback("frame_extraction", 0.15, "Extracting frames.")
            self.config.progress_callback("cone_detection", 0.35, "Detecting references.")
            self.config.progress_callback("colmap_reconstruction", 0.6, "Reconstructing geometry.")
            self.config.progress_callback("scale_calibration", 0.8, "Calibrating scale.")
            self.config.progress_callback("volume_computation", 1.0, "Computing final volume.")
            return SimpleNamespace(
                publishable=True,
                review_grade=False,
                quality_warnings=[],
                quality_blockers=[],
                weight_kg=2_400_000.0,
                volume=SimpleNamespace(recommended_m3=1142.0),
                calibration=SimpleNamespace(
                    confidence=0.84,
                    selected_method="tagged_reference_projection",
                    frames_with_multiple_detections=4,
                    registered_cone_frames=12,
                    detected_cone_frames=15,
                    num_cones_used=1,
                    num_references_used=1,
                    reference_family="tag36h11",
                    scale_disagreement_ratio=1.05,
                ),
                reference_strategy="tagged_references",
            )

    runtime = StockpileMobileJobRuntime(
        service,
        configuration=StockpileMobileJobRuntimeConfiguration(
            workspace_root=tmp_path / "workspaces",
        ),
        pipeline_factory=WeakReferencePipeline,
    )

    job_id = runtime.start_processing_for_upload(upload.upload_id)
    assert runtime.wait_for_job(job_id, timeout=5.0) is True

    status = service.fetch_processing_job(job_id)
    result = service.fetch_result(upload.run_id or upload.upload_id)

    assert status.phase is JobPhase.BLOCKED
    assert result.outcome.value == "blocked"
    assert result.reference_diagnostics is not None
    assert result.reference_diagnostics.observation_summary is not None
    assert result.reference_diagnostics.observation_summary.observed_reference_count == 1
    assert any("Too few tagged references were recovered" in item for item in result.blockers)


def _write_temp_upload(tmp_path: Path, payload: bytes) -> Path:
    source_path = tmp_path / "temp-upload.mov"
    source_path.write_bytes(payload)
    return source_path
