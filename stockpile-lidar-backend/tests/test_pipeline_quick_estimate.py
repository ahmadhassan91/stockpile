from pathlib import Path

import pytest

from stockpile_lidar.ingestion import StockpileCaptureBundle
from stockpile_lidar.pipeline import (
    JOB_STORE,
    RESULT_STORE,
    LidarPipeline,
    reset_state,
)


@pytest.fixture(autouse=True)
def _clean_state():
    reset_state()
    yield
    reset_state()


def _build_bundle(tmp_path: Path, **manifest_overrides) -> StockpileCaptureBundle:
    manifest = {
        "schema_version": 1,
        "capture_id": "cap_test_quick",
        "site_id": "site_alpha",
        "pile_name": "Pile A",
        "material_code": "GRAVEL",
        "density_kg_per_m3": 1500.0,
        "frame_count": 4,
        "depth_dtype": "float16",
        "tracking_state_summary": "normal",
        "on_device_quick_estimate": {
            "volume_m3": 12.5,
            "footprint_area_m2": 8.0,
            "peak_height_m": 1.6,
            "confidence_score": 0.82,
        },
    }
    manifest.update(manifest_overrides)
    return StockpileCaptureBundle(
        root=tmp_path,
        manifest=manifest,
        poses=[],
        rgb_frames=[],
        depth_frames=[],
    )


def test_process_capture_returns_v1_compatible_result(tmp_path):
    bundle = _build_bundle(tmp_path)

    submission = LidarPipeline().process_capture(bundle)

    assert submission.capture_id == "cap_test_quick"
    assert submission.status == "completed"
    result = submission.result
    assert result["stage"] == "complete"
    assert result["publishable"] is True
    assert result["review_grade"] is False
    assert result["weight_kg"] == pytest.approx(12.5 * 1500.0)
    assert result["scale_factor_m_per_unit"] == 1.0
    assert result["scale_source"] == "lidar_native"
    assert result["num_frames"] == 4
    assert result["num_colmap_points"] == 0
    assert result["num_colmap_images"] == 4
    assert result["volume"]["recommended_m3"] == pytest.approx(12.5)
    assert result["volume"]["grid_integration_m3"] == pytest.approx(12.5)
    assert result["volume"]["recommended_method"] == "lidar_quick_estimate"
    assert result["volume"]["footprint_source"] == "lidar_quick_estimate"
    assert result["calibration"]["selected_method"] == "lidar_quick_estimate"
    assert result["calibration"]["confidence"] == pytest.approx(0.82)
    assert any(
        "quick estimate" in note.lower()
        for note in result["calibration"]["notes"]
    )
    assert result["error"] is None
    diagnostics = result["diagnostics"]
    assert diagnostics["capture_id"] == "cap_test_quick"
    assert diagnostics["site_id"] == "site_alpha"
    assert diagnostics["material_code"] == "GRAVEL"
    assert diagnostics["frame_count"] == 4
    assert diagnostics["on_device_quick_estimate"]["volume_m3"] == pytest.approx(12.5)


def test_process_capture_persists_job_and_result_in_module_state(tmp_path):
    bundle = _build_bundle(tmp_path)

    submission = LidarPipeline().process_capture(bundle)

    assert submission.result_id in RESULT_STORE
    saved_result = RESULT_STORE[submission.result_id]
    assert saved_result["result_id"] == submission.result_id

    assert submission.job_id in JOB_STORE
    saved_job = JOB_STORE[submission.job_id]
    assert saved_job == {
        "job_id": submission.job_id,
        "status": "completed",
        "result_id": submission.result_id,
    }


def test_process_capture_handles_missing_quick_estimate_safely(tmp_path):
    bundle = _build_bundle(
        tmp_path,
        density_kg_per_m3=1000.0,
        on_device_quick_estimate=None,
    )

    submission = LidarPipeline().process_capture(bundle)
    result = submission.result

    assert result["weight_kg"] == pytest.approx(0.0)
    assert result["volume"]["recommended_m3"] == pytest.approx(0.0)
    assert result["calibration"]["confidence"] == pytest.approx(0.0)
    assert result["publishable"] is True
