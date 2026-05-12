from stockpile.mobile_api_models import (
    CaptureQualityInputPayload,
    ConfidencePayload,
    DeviceSensorInputPayload,
    MobileFirstCapturePayload,
    MobileFirstCaptureStage,
    OnDeviceVisionPayload,
    ProvisionalMeasurementPayload,
    ReconstructionPayload,
    ReconstructionPointPayload,
    ReconstructionTrianglePayload,
    ReferenceMarkerQuality,
    ResultPayload,
    RunOutcome,
    UploadRequest,
    Vector3Payload,
)


def test_upload_request_accepts_richer_mobile_first_observation_payloads():
    request = UploadRequest.from_dict(
        {
            "sessionId": "session_123",
            "fileName": "north-yard.mov",
            "byteCount": 2048,
            "contentType": "video/quicktime",
            "poseSamples": [
                {
                    "timestampSeconds": 1.25,
                    "positionXYZM": [0.0, 1.5, 2.0],
                    "yawPitchRollDeg": [90.0, -4.0, 1.0],
                    "horizontalAccuracyM": 0.4,
                    "verticalAccuracyM": 0.8,
                    "headingDegrees": 87.0,
                    "trackingState": "normal",
                },
            ],
            "referenceEvidenceJPEGFrames": [
                {
                    "frameId": "evidence_0001",
                    "timeOffsetSec": 1.2,
                    "poseSampleIndex": 0,
                    "capturedAt": "2026-04-23T08:45:00Z",
                    "widthPx": 640,
                    "heightPx": 360,
                    "jpegBase64": "ZmFrZS1qcGVn",
                },
            ],
            "referenceObservations": [
                {
                    "markerId": "QPMC-01",
                    "frameId": "frame_0010",
                    "pixelArea": 1800.0,
                    "confidence": 0.92,
                    "estimatedDistanceM": 4.2,
                    "state": "confirmed",
                },
            ],
        }
    )

    assert len(request.pose_samples) == 1
    pose = request.pose_samples[0]
    assert pose.sample_index == 0
    assert pose.time_offset_sec == 1.25
    assert pose.position_m == Vector3Payload(x=0.0, y=1.5, z=2.0)
    assert pose.yaw_pitch_roll_deg == Vector3Payload(x=90.0, y=-4.0, z=1.0)
    assert pose.horizontal_accuracy_m == 0.4
    assert pose.vertical_accuracy_m == 0.8
    assert pose.heading_degrees == 87.0
    assert pose.tracking_state == "normal"

    assert len(request.reference_evidence_jpeg_frames) == 1
    evidence_frame = request.reference_evidence_jpeg_frames[0]
    assert evidence_frame.frame_id == "evidence_0001"
    assert evidence_frame.time_offset_sec == 1.2
    assert evidence_frame.pose_sample_index == 0
    assert evidence_frame.width_px == 640
    assert evidence_frame.height_px == 360
    assert evidence_frame.jpeg_base64 == "ZmFrZS1qcGVn"

    assert len(request.reference_observations) == 1
    observation = request.reference_observations[0]
    assert observation.reference_id == "QPMC-01"
    assert observation.family == "unspecified"
    assert observation.frame_id == "frame_0010"
    assert observation.pixel_area_px == 1800.0
    assert observation.confidence == 0.92
    assert observation.estimated_distance_m == 4.2
    assert observation.state == ReferenceMarkerQuality.CONFIRMED

    encoded = request.to_dict()
    assert encoded["poseSamples"][0]["sampleIndex"] == 0
    assert encoded["poseSamples"][0]["yawPitchRollDeg"] == {"x": 90.0, "y": -4.0, "z": 1.0}
    assert encoded["referenceEvidenceJPEGFrames"][0]["frameId"] == "evidence_0001"
    assert encoded["referenceEvidenceJPEGFrames"][0]["widthPx"] == 640
    assert encoded["referenceObservations"][0]["referenceId"] == "QPMC-01"
    assert encoded["referenceObservations"][0]["state"] == "confirmed"


def test_mobile_first_capture_payload_round_trips_phone_quick_estimate():
    payload = CaptureQualityInputPayload(
        reference_visibility_score=0.81,
        coverage_score=0.77,
        motion_stability_score=0.74,
        overall_guidance_score=0.79,
        device_sensors=DeviceSensorInputPayload(
            motion_signals_included=True,
            gravity_vector_included=True,
            heading_signals_included=False,
            camera_calibration_included=True,
        ),
        mobile_first_capture=MobileFirstCapturePayload(
            stage=MobileFirstCaptureStage.WALKING_PERIMETER,
            pile_segmentation_score=0.74,
            toe_segmentation_score=0.69,
            segmentation_confidence_score=0.72,
            quick_volume_m3=19.64,
            quick_footprint_area_m2=11.8,
            quick_peak_height_m=2.3,
            quick_confidence_score=0.68,
            quick_geometry_point_count=155_551,
            quick_camera_path_distance_m=18.2,
        ),
    )

    encoded = payload.to_dict()
    mobile_first_capture = encoded["mobileFirstCapture"]
    assert mobile_first_capture["pileSegmentationScore"] == 0.74
    assert mobile_first_capture["toeSegmentationScore"] == 0.69
    assert mobile_first_capture["segmentationConfidenceScore"] == 0.72
    assert mobile_first_capture["quickVolumeM3"] == 19.64
    assert mobile_first_capture["quickFootprintAreaM2"] == 11.8
    assert mobile_first_capture["quickPeakHeightM"] == 2.3
    assert mobile_first_capture["quickConfidenceScore"] == 0.68
    assert mobile_first_capture["quickGeometryPointCount"] == 155_551
    assert mobile_first_capture["quickCameraPathDistanceM"] == 18.2

    decoded = CaptureQualityInputPayload.from_dict(encoded)
    assert decoded.mobile_first_capture is not None
    assert decoded.mobile_first_capture.pile_segmentation_score == 0.74
    assert decoded.mobile_first_capture.toe_segmentation_score == 0.69
    assert decoded.mobile_first_capture.segmentation_confidence_score == 0.72
    assert decoded.mobile_first_capture.quick_volume_m3 == 19.64
    assert decoded.mobile_first_capture.quick_footprint_area_m2 == 11.8
    assert decoded.mobile_first_capture.quick_peak_height_m == 2.3
    assert decoded.mobile_first_capture.quick_confidence_score == 0.68
    assert decoded.mobile_first_capture.quick_geometry_point_count == 155_551
    assert decoded.mobile_first_capture.quick_camera_path_distance_m == 18.2


def test_mobile_first_capture_payload_round_trips_on_device_vision():
    payload = MobileFirstCapturePayload(
        stage=MobileFirstCaptureStage.WALKING_PERIMETER,
        on_device_vision=OnDeviceVisionPayload(
            source="vision_foreground_instance_mask",
            uses_machine_learning=True,
            pile_segmentation_score=0.83,
            toe_segmentation_score=0.77,
            segmentation_confidence_score=0.8,
            foreground_coverage_ratio=0.41,
            lower_frame_occupancy_ratio=0.58,
            material_family_code="aggregate_rock",
            material_family_label="Coarse aggregate / rock",
            material_confidence_score=0.69,
            guidance_hint="Keep the segmented pile toe in the lower third.",
        ),
    )

    encoded = payload.to_dict()
    on_device_vision = encoded["onDeviceVision"]
    assert on_device_vision["source"] == "vision_foreground_instance_mask"
    assert on_device_vision["usesMachineLearning"] is True
    assert on_device_vision["pileSegmentationScore"] == 0.83
    assert on_device_vision["materialFamilyCode"] == "aggregate_rock"

    decoded = MobileFirstCapturePayload.from_dict(encoded)
    assert decoded.on_device_vision is not None
    assert decoded.on_device_vision.source == "vision_foreground_instance_mask"
    assert decoded.on_device_vision.uses_machine_learning is True
    assert decoded.on_device_vision.material_family_label == "Coarse aggregate / rock"


def test_provisional_measurement_payload_round_trips_quick_segmentation_intelligence():
    payload = ProvisionalMeasurementPayload(
        status="review",
        basis="mobile_first_review",
        volume_m3=2528.43,
        weight_tonnes=5309.703,
        confidence_score=68,
        reason="Backend verification is still pending release.",
        quick_volume_m3=1642.1,
        quick_footprint_area_m2=14.4,
        quick_peak_height_m=2.1,
        quick_confidence_score=0.72,
        quick_geometry_point_count=320,
        quick_camera_path_distance_m=18.2,
    )

    encoded = payload.to_dict()
    assert encoded["quickVolumeM3"] == 1642.1
    assert encoded["quickFootprintAreaM2"] == 14.4
    assert encoded["quickPeakHeightM"] == 2.1
    assert encoded["quickConfidenceScore"] == 0.72
    assert encoded["quickGeometryPointCount"] == 320
    assert encoded["quickCameraPathDistanceM"] == 18.2

    decoded = ProvisionalMeasurementPayload.from_dict(encoded)
    assert decoded.quick_volume_m3 == 1642.1
    assert decoded.quick_footprint_area_m2 == 14.4
    assert decoded.quick_peak_height_m == 2.1
    assert decoded.quick_confidence_score == 0.72
    assert decoded.quick_geometry_point_count == 320
    assert decoded.quick_camera_path_distance_m == 18.2


def test_upload_request_keeps_existing_observation_payload_shapes_compatible():
    request = UploadRequest.from_dict(
        {
            "sessionId": "session_123",
            "fileName": "north-yard.mov",
            "byteCount": 2048,
            "contentType": "video/quicktime",
            "poseSamples": [
                {
                    "sampleIndex": 7,
                    "timeOffsetSec": 2.5,
                    "positionM": {"x": 3.0, "y": 4.0, "z": 5.0},
                    "orientationQuaternion": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
                    "gravityVector": {"x": 0.0, "y": -1.0, "z": 0.0},
                    "headingDegrees": 12.0,
                    "trackingState": "running",
                },
            ],
            "referenceObservations": [
                {
                    "referenceId": "tag-01",
                    "family": "apriltag",
                    "frameTimeSec": 2.5,
                    "capturedAt": "2026-04-23T08:45:00Z",
                    "poseSampleIndex": 7,
                    "decisionMargin": 92.5,
                    "hamming": 0,
                    "edgeLengthPx": 144.0,
                },
            ],
        }
    )

    pose = request.pose_samples[0]
    assert pose.sample_index == 7
    assert pose.time_offset_sec == 2.5
    assert pose.position_m == Vector3Payload(x=3.0, y=4.0, z=5.0)
    assert pose.yaw_pitch_roll_deg is None
    assert pose.horizontal_accuracy_m is None

    observation = request.reference_observations[0]
    assert observation.reference_id == "tag-01"
    assert observation.family == "apriltag"
    assert observation.frame_time_sec == 2.5
    assert observation.pose_sample_index == 7
    assert observation.edge_length_px == 144.0
    assert observation.frame_id is None
    assert observation.state is None


def test_result_payload_round_trips_reconstruction_preview():
    payload = ResultPayload(
        run_id="run_mesh_123",
        pile_name="North Yard 03",
        outcome=RunOutcome.REVIEW_ONLY,
        confidence=ConfidencePayload(score=58, label="Moderate", summary="Needs cross-check."),
        measurement=None,
        warnings=[],
        blockers=[],
        recommended_action="Review before release.",
        reconstruction=ReconstructionPayload(
            summary="Preview mesh from 320 reconstructed pile points.",
            footprint_area_m2=843.2,
            peak_height_m=5.3,
            default_mode="toe",
            vertices=[
                ReconstructionPointPayload(x=0.0, y=0.0, z=0.0),
                ReconstructionPointPayload(x=1.0, y=0.0, z=0.5),
                ReconstructionPointPayload(x=0.0, y=1.0, z=0.4),
            ],
            triangles=[ReconstructionTrianglePayload(a=0, b=1, c=2)],
            point_cloud=[ReconstructionPointPayload(x=0.5, y=0.4, z=0.2)],
            toe_markers=[ReconstructionPointPayload(x=1.0, y=1.0, z=0.1)],
            surface_risk_markers=[ReconstructionPointPayload(x=0.2, y=0.2, z=0.9)],
        ),
    )

    encoded = payload.to_dict()
    assert encoded["reconstruction"]["defaultMode"] == "toe"
    assert encoded["reconstruction"]["triangles"][0] == {"a": 0, "b": 1, "c": 2}

    decoded = ResultPayload.from_dict(encoded)
    assert decoded.reconstruction is not None
    assert decoded.reconstruction.summary.startswith("Preview mesh")
    assert decoded.reconstruction.default_mode == "toe"
    assert len(decoded.reconstruction.vertices) == 3
    assert len(decoded.reconstruction.triangles) == 1
