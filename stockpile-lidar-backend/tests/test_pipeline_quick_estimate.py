from pathlib import Path
from types import SimpleNamespace

import numpy as np
import open3d as o3d
import pytest

from stockpile_lidar.fusion import TSDFFusionResult
from stockpile_lidar.ingestion import StockpileCaptureBundle
from stockpile_lidar.pipeline import (
    JOB_STORE,
    RESULT_STORE,
    LidarPipeline,
    reset_state,
)
from stockpile_lidar.quality import QualityAssessment
from stockpile_lidar.volume import VolumeResult


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


def _make_pcd(points: np.ndarray) -> o3d.geometry.PointCloud:
    pcd = o3d.geometry.PointCloud()
    pcd.points = o3d.utility.Vector3dVector(np.ascontiguousarray(points, dtype=float))
    return pcd


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


def test_process_capture_prefers_backend_tsdf_volume_when_available(tmp_path, monkeypatch):
    bundle = _build_bundle(
        tmp_path,
        tracking_state_summary={"normal": 9, "limited": 1, "notAvailable": 0},
    )
    fused_cloud = _make_pcd(
        np.array(
            [
                [0.0, 0.0, 0.0],
                [1.0, 0.0, 0.2],
                [0.0, 1.0, 0.3],
                [1.0, 1.0, 0.4],
            ]
        )
    )
    pile_cloud = _make_pcd(
        np.array(
            [
                [0.0, 0.0, 0.2],
                [1.0, 0.0, 0.3],
                [0.0, 1.0, 0.4],
            ]
        )
    )
    ground_cloud = _make_pcd(np.array([[0.0, 0.0, 0.0]]))

    def fake_fuse_capture_bundle(captured_bundle, config):
        assert captured_bundle is bundle
        return TSDFFusionResult(
            point_cloud=fused_cloud,
            fused_frame_count=2,
            skipped_frame_count=1,
            voxel_size=0.02,
            sdf_trunc=0.04,
        )

    def fake_segment_pile(point_cloud, config, ground_anchor_positions=None):
        assert point_cloud is fused_cloud
        assert ground_anchor_positions == []
        return SimpleNamespace(
            pile_cloud=pile_cloud,
            ground_cloud=ground_cloud,
            full_cloud_transformed=fused_cloud,
            inlier_ratio=0.75,
        )

    def fake_compute_volume(point_cloud, config, *, full_scene_cloud=None, footprint_points=None):
        assert point_cloud is pile_cloud
        assert full_scene_cloud is fused_cloud
        assert footprint_points == []
        return VolumeResult(
            convex_hull_m3=4.0,
            alpha_shape_m3=None,
            grid_integration_m3=4.2,
            recommended_m3=4.2,
            recommended_method="grid_integration",
            recommended_note=None,
            grid_resolution=0.05,
            num_points=3,
            grid_occupancy_pct=77.0,
            grid_cells_observed=77,
            grid_cells_total=100,
            grid_interpolated=True,
            grid_to_hull_ratio=1.05,
            footprint_area_m2=2.5,
            footprint_source="toe_hybrid",
        )

    def fake_assess_quality(point_cloud, volume, manifest, config):
        assert point_cloud is pile_cloud
        assert volume.recommended_m3 == pytest.approx(4.2)
        assert manifest["tracking_state_summary"] == {
            "normal": 9,
            "limited": 1,
            "notAvailable": 0,
        }
        assert manifest["poses"] == []
        return QualityAssessment(
            publishable=True,
            review_grade=True,
            warnings=["review backend fused capture"],
            blockers=[],
        )

    monkeypatch.setattr(
        "stockpile_lidar.pipeline.fuse_capture_bundle", fake_fuse_capture_bundle
    )
    monkeypatch.setattr("stockpile_lidar.pipeline.segment_pile", fake_segment_pile)
    monkeypatch.setattr("stockpile_lidar.pipeline.compute_volume", fake_compute_volume)
    monkeypatch.setattr("stockpile_lidar.pipeline.assess_quality", fake_assess_quality)

    submission = LidarPipeline().process_capture(bundle)
    result = submission.result

    assert result["weight_kg"] == pytest.approx(4.2 * 1500.0)
    assert result["publishable"] is True
    assert result["review_grade"] is True
    assert result["num_colmap_points"] == 4
    assert result["num_colmap_images"] == 2
    assert result["volume"]["recommended_m3"] == pytest.approx(4.2)
    assert result["volume"]["recommended_method"] == "grid_integration"
    assert result["calibration"]["selected_method"] == "lidar_tsdf_fusion"
    assert result["quality_warnings"] == ["review backend fused capture"]
    diagnostics = result["diagnostics"]
    assert diagnostics["backend_volume_source"] == "tsdf_fusion"
    assert diagnostics["fused_frame_count"] == 2
    assert diagnostics["skipped_frame_count"] == 1
    assert diagnostics["fused_point_count"] == 4
    assert diagnostics["pile_point_count"] == 3
    assert diagnostics["ground_point_count"] == 1
