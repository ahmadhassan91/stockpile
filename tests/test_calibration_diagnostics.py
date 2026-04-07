from stockpile.calibration_diagnostics import (
    ConeObservationStats,
    build_capture_readiness_notes,
    describe_reference_constraint,
    summarize_cone_observations,
)
from stockpile.cone_detection import ConeDetection


def _detection() -> ConeDetection:
    return ConeDetection(
        bbox=(10, 20, 30, 40),
        centroid=(25.0, 40.0),
        tip=(25.0, 20.0),
        base_center=(25.0, 60.0),
        area=1200.0,
        solidity=0.9,
        contour=[],
    )


def test_summarize_cone_observations_counts_detected_and_registered_frames():
    stats = summarize_cone_observations(
        {
            "frame_001.jpg": [_detection()],
            "frame_002.jpg": [_detection(), _detection()],
            "frame_003.jpg": [],
        },
        {"frame_002.jpg", "frame_999.jpg"},
    )

    assert stats.detected_cone_frames == 2
    assert stats.registered_cone_frames == 1
    assert stats.total_cone_detections == 3
    assert stats.max_detections_in_frame == 2
    assert stats.frames_with_multiple_detections == 1
    assert stats.registration_coverage_pct == 50.0


def test_summarize_cone_observations_defaults_to_full_registration_when_unknown():
    stats = summarize_cone_observations(
        {
            "frame_001.jpg": [_detection()],
            "frame_002.jpg": [_detection()],
        }
    )

    assert stats.detected_cone_frames == 2
    assert stats.registered_cone_frames == 2
    assert stats.max_detections_in_frame == 1
    assert stats.frames_with_multiple_detections == 0


def test_summarize_cone_observations_handles_no_detections():
    stats = summarize_cone_observations({"frame_001.jpg": []}, set())

    assert stats.detected_cone_frames == 0
    assert stats.registered_cone_frames == 0
    assert stats.total_cone_detections == 0
    assert stats.registration_coverage_pct is None


def test_build_capture_readiness_notes_flags_single_cone_capture_limit():
    notes = build_capture_readiness_notes(
        ConeObservationStats(
            detected_cone_frames=71,
            registered_cone_frames=71,
            total_cone_detections=71,
            max_detections_in_frame=1,
            frames_with_multiple_detections=0,
        ),
        unique_cones_used=1,
    )

    assert any("never showed more than 1 cone at a time" in note for note in notes)
    assert all("registered into COLMAP" not in note for note in notes)


def test_describe_reference_constraint_flags_registration_loss_when_multi_cones_exist():
    message = describe_reference_constraint(
        ConeObservationStats(
            detected_cone_frames=188,
            registered_cone_frames=3,
            total_cone_detections=412,
            max_detections_in_frame=15,
            frames_with_multiple_detections=158,
        ),
        unique_cones_used=1,
    )

    assert "only 3 of 188 cone-bearing frames registered into COLMAP" in message
