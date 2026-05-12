from stockpile.mobile_first import (
    CaptureQualityState,
    DevicePoseSample,
    MobileFirstCaptureEnvelope,
    ProvisionalMeasurementInput,
    ReferenceObservation,
    ReferenceObservationState,
    ReviewPacket,
    VerificationOutcome,
    evaluate_provisional_measurement,
    evaluate_review_packet,
)


def make_capture() -> MobileFirstCaptureEnvelope:
    return MobileFirstCaptureEnvelope(
        session_id="session_1",
        site_id="north-yard",
        pile_name="North Yard 03",
        material_code="backfill-0-75-mm",
        density_kg_per_m3=2100,
        reference_count_goal=3,
        reference_observations=(
            ReferenceObservation(
                marker_id="tag-01",
                frame_id="frame_0010",
                pixel_area=1800,
                confidence=0.92,
                estimated_distance_m=4.2,
                state=ReferenceObservationState.CONFIRMED,
            ),
        ),
        device_pose_samples=(
            DevicePoseSample(
                timestamp_seconds=1.0,
                position_xyz_m=(0.0, 0.0, 0.0),
                yaw_pitch_roll_deg=(0.0, -4.0, 0.0),
            ),
        ),
        toe_coverage_score=0.8,
        motion_stability_score=0.82,
        perimeter_coverage_score=0.78,
        lidar_assist_enabled=True,
    )


def test_provisional_measurement_ready_when_signals_are_strong():
    result = evaluate_provisional_measurement(
        ProvisionalMeasurementInput(
            capture=make_capture(),
            quick_volume_m3=1825.0,
            tagged_reference_recovery_ratio=0.8,
            scale_agreement_ratio=1.08,
            toe_confidence_score=0.79,
            geometry_confidence_score=0.76,
        )
    )

    assert result.state == CaptureQualityState.READY
    assert result.provisional_volume_m3 == 1825.0
    assert result.confidence_score > 0.7
    assert result.reasons == ()


def test_provisional_measurement_requires_retake_when_reference_recovery_is_weak():
    weak_capture = make_capture()
    result = evaluate_provisional_measurement(
        ProvisionalMeasurementInput(
            capture=weak_capture,
            quick_volume_m3=1825.0,
            tagged_reference_recovery_ratio=0.2,
            scale_agreement_ratio=1.6,
            toe_confidence_score=0.5,
            geometry_confidence_score=0.48,
        )
    )

    assert result.state == CaptureQualityState.RETAKE
    assert any("Tagged reference recovery" in reason for reason in result.reasons)
    assert any("Scale signals disagree" in reason for reason in result.reasons)


def test_provisional_measurement_can_stay_in_review_when_only_soft_signals_fail():
    result = evaluate_provisional_measurement(
        ProvisionalMeasurementInput(
            capture=make_capture(),
            quick_volume_m3=1718.0,
            tagged_reference_recovery_ratio=0.78,
            scale_agreement_ratio=1.42,
            toe_confidence_score=0.73,
            geometry_confidence_score=0.71,
        )
    )

    assert result.state == CaptureQualityState.REVIEW
    assert result.provisional_volume_m3 == 1718.0
    assert any("Scale signals disagree" in reason for reason in result.reasons)
    assert result.operator_action == "Review against the latest benchmark before release."


def test_review_packet_stays_review_only_when_benchmark_delta_is_high():
    provisional = evaluate_provisional_measurement(
        ProvisionalMeasurementInput(
            capture=make_capture(),
            quick_volume_m3=1700.0,
            tagged_reference_recovery_ratio=0.76,
            scale_agreement_ratio=1.1,
            toe_confidence_score=0.7,
            geometry_confidence_score=0.72,
        )
    )

    decision = evaluate_review_packet(
        ReviewPacket(
            provisional=provisional,
            benchmark_delta_ratio=0.14,
            tagged_reference_count=3,
            minimum_expected_reference_count=2,
            scale_agreement_ratio=1.1,
        )
    )

    assert decision.outcome == VerificationOutcome.REVIEW_ONLY
    assert any("Benchmark delta" in reason for reason in decision.reasons)


def test_review_packet_requires_recapture_when_too_few_tags_are_recovered():
    provisional = evaluate_provisional_measurement(
        ProvisionalMeasurementInput(
            capture=make_capture(),
            quick_volume_m3=1600.0,
            tagged_reference_recovery_ratio=0.25,
            scale_agreement_ratio=1.45,
            toe_confidence_score=0.55,
            geometry_confidence_score=0.51,
        )
    )

    decision = evaluate_review_packet(
        ReviewPacket(
            provisional=provisional,
            benchmark_delta_ratio=0.05,
            tagged_reference_count=1,
            minimum_expected_reference_count=2,
            scale_agreement_ratio=1.3,
        )
    )

    assert decision.outcome == VerificationOutcome.RECAPTURE_REQUIRED
    assert any("Too few tagged references" in reason for reason in decision.reasons)
