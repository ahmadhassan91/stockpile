from __future__ import annotations

from types import SimpleNamespace

import numpy as np
import open3d as o3d
import pytest

import stockpile.pipeline as pipeline_module
from stockpile.config import MobileCapturePrior, PipelineConfig, TaggedReferenceConfig
from stockpile.cone_detection import ConeDetection
from stockpile.pipeline import Pipeline
from stockpile.scale_calibration import CalibrationResult
from stockpile.volume import VolumeResult


def _cone_detection() -> ConeDetection:
    contour = np.array([[[0, 0]], [[8, 0]], [[8, 18]], [[0, 18]]], dtype=np.int32)
    return ConeDetection(
        bbox=(0, 0, 8, 18),
        centroid=(4.0, 9.0),
        tip=(4.0, 0.0),
        base_center=(4.0, 18.0),
        area=144.0,
        solidity=0.92,
        contour=contour,
    )


def _pile_cloud(point_count: int = 6400) -> o3d.geometry.PointCloud:
    xs, ys = np.meshgrid(np.linspace(-6.0, 6.0, 80), np.linspace(-6.0, 6.0, 80))
    z = np.maximum(0.0, 2.5 - 0.04 * (xs**2 + ys**2))
    points = np.column_stack([xs.ravel(), ys.ravel(), z.ravel()])[:point_count]
    cloud = o3d.geometry.PointCloud()
    cloud.points = o3d.utility.Vector3dVector(points)
    return cloud


def _run_pipeline(tmp_path, monkeypatch, mobile_capture_prior: MobileCapturePrior | None):
    records: dict[str, object] = {}
    video_path = tmp_path / "input.mov"
    video_path.write_bytes(b"fake-video")

    def fake_get_video_info(video_path_arg):
        assert video_path_arg == video_path
        return {"fps": 2.0, "frame_count": 6, "width": 1920, "height": 1080, "duration": 3.0}

    def fake_extract_frames(
        video_path_arg,
        images_dir,
        config,
        progress_callback=None,
        preferred_timestamps_sec=None,
        preferred_frame_indices=None,
    ):
        assert video_path_arg == video_path
        records["preferred_timestamps_sec"] = tuple(preferred_timestamps_sec or ())
        records["preferred_frame_indices"] = tuple(preferred_frame_indices or ())
        return [
            images_dir / "frame_00001.jpg",
            images_dir / "frame_00002.jpg",
            images_dir / "frame_00004.jpg",
        ]

    def fake_detect_cones_in_frames(frame_paths, config, progress_callback=None):
        return {"frame_00002.jpg": [_cone_detection()]}

    def fake_detect_tagged_references_in_frames(frame_paths, config):
        return {}

    def fake_run_colmap_reconstruction(
        images_dir,
        colmap_dir,
        config,
        progress_callback=None,
        priority_frame_names=None,
    ):
        records["priority_frame_names"] = None if priority_frame_names is None else set(priority_frame_names)
        model_dir = colmap_dir / "sparse" / "0"
        model_dir.mkdir(parents=True, exist_ok=True)
        return model_dir

    def fake_export_to_ply(model_dir, ply_path, colmap_binary):
        ply_path.parent.mkdir(parents=True, exist_ok=True)
        ply_path.write_text("ply")

    def fake_read_cameras_binary(path):
        return {1: SimpleNamespace(camera_id=1)}

    def fake_read_images_binary(path):
        return {
            1: SimpleNamespace(name="frame_00001.jpg", camera_id=1),
            2: SimpleNamespace(name="frame_00002.jpg", camera_id=1),
            3: SimpleNamespace(name="frame_00004.jpg", camera_id=1),
        }

    def fake_read_points3d_binary(path):
        return {
            1: SimpleNamespace(xyz=np.array([0.0, 0.0, 0.0]), rgb=np.array([120, 120, 120])),
            2: SimpleNamespace(xyz=np.array([1.0, 0.5, 0.2]), rgb=np.array([140, 140, 140])),
            3: SimpleNamespace(xyz=np.array([-0.5, 0.25, 0.4]), rgb=np.array([150, 150, 150])),
        }

    def fake_calibrate_scale(
        cone_detections,
        images,
        points3d,
        config=None,
        cameras=None,
        tagged_reference_detections_arg=None,
        tagged_reference_config=None,
    ):
        return CalibrationResult(
            scale_factor=1.25,
            confidence=0.91,
            num_cones_used=3,
            per_cone_scales=[1.25],
            cone_3d_positions=[],
            reference_family="cone",
            reference_source="cone_projection",
            num_references_used=3,
            detected_cone_frames=1,
            registered_cone_frames=1,
            total_cone_detections=1,
            max_detections_in_frame=1,
            frames_with_multiple_detections=0,
            selected_method="projection",
        )

    def fake_load_and_scale_point_cloud(all_xyz, all_rgb, scale_factor):
        return _pile_cloud()

    def fake_segment_pile(pcd, config, cone_positions=None):
        return SimpleNamespace(
            pile_cloud=_pile_cloud(),
            ground_cloud=o3d.geometry.PointCloud(),
            full_cloud_transformed=_pile_cloud(),
            transform_matrix=np.eye(4),
        )

    def fake_compute_volume(pile_cloud, config, cone_positions=None, full_cloud_transformed=None):
        return VolumeResult(
            convex_hull_m3=15.0,
            alpha_shape_m3=14.5,
            grid_integration_m3=12.5,
            recommended_m3=12.5,
            recommended_method="grid",
            recommended_note=None,
            grid_resolution=0.05,
            num_points=len(pile_cloud.points),
            grid_occupancy_pct=18.0,
            grid_cells_observed=180,
            grid_cells_total=300,
            grid_interpolated=False,
            grid_to_hull_ratio=0.83,
            footprint_area_m2=9.5,
            footprint_source="toe slope break",
        )

    monkeypatch.setattr(pipeline_module, "get_video_info", fake_get_video_info)
    monkeypatch.setattr(pipeline_module, "extract_frames", fake_extract_frames)
    monkeypatch.setattr(pipeline_module, "detect_cones_in_frames", fake_detect_cones_in_frames)
    monkeypatch.setattr(
        pipeline_module,
        "detect_tagged_references_in_frames",
        fake_detect_tagged_references_in_frames,
    )
    monkeypatch.setattr(pipeline_module, "run_colmap_reconstruction", fake_run_colmap_reconstruction)
    monkeypatch.setattr(pipeline_module, "export_to_ply", fake_export_to_ply)
    monkeypatch.setattr(pipeline_module, "read_cameras_binary", fake_read_cameras_binary)
    monkeypatch.setattr(pipeline_module, "read_images_binary", fake_read_images_binary)
    monkeypatch.setattr(pipeline_module, "read_points3d_binary", fake_read_points3d_binary)
    monkeypatch.setattr(pipeline_module, "calibrate_scale", fake_calibrate_scale)
    monkeypatch.setattr(pipeline_module, "load_and_scale_point_cloud", fake_load_and_scale_point_cloud)
    monkeypatch.setattr(pipeline_module, "segment_pile", fake_segment_pile)
    monkeypatch.setattr(pipeline_module, "compute_volume", fake_compute_volume)

    config = PipelineConfig(
        workspace=tmp_path / "workspace",
        tagged_references=TaggedReferenceConfig(enabled=False),
        material_density=2100.0,
        material_name="Backfill 0-75 mm",
        mobile_capture_prior=mobile_capture_prior,
    )
    result = Pipeline(config).run(video_path)
    return result, records


def test_pipeline_uses_mobile_capture_prior_timestamps_for_extraction_and_colmap(tmp_path, monkeypatch):
    baseline_result, baseline_records = _run_pipeline(tmp_path, monkeypatch, mobile_capture_prior=None)

    prior_result, prior_records = _run_pipeline(
        tmp_path,
        monkeypatch,
        mobile_capture_prior=MobileCapturePrior(
            reference_evidence_timestamps_sec=(0.5, 2.0),
            useful_pose_sample_timestamps_sec=(1.0,),
            reference_evidence_count=2,
            pose_sample_count=8,
            useful_pose_sample_count=1,
            depth_data_included=True,
        ),
    )

    assert baseline_result.publishable is True
    assert prior_result.publishable is True
    assert baseline_result.stage == "complete"
    assert prior_result.stage == "complete"
    assert baseline_result.reference_strategy == "cones"
    assert prior_result.reference_strategy == "cones"
    assert baseline_result.num_frames == prior_result.num_frames == 3
    assert baseline_result.num_frames_with_cones == prior_result.num_frames_with_cones == 1
    assert baseline_result.weight_kg == pytest.approx(prior_result.weight_kg)
    assert baseline_result.volume is not None
    assert prior_result.volume is not None
    assert baseline_result.volume.recommended_m3 == pytest.approx(prior_result.volume.recommended_m3)

    assert baseline_records["preferred_timestamps_sec"] == ()
    assert baseline_records["priority_frame_names"] == {"frame_00002.jpg"}

    assert prior_records["preferred_timestamps_sec"] == (0.5, 1.0, 2.0)
    assert prior_records["priority_frame_names"] == {
        "frame_00001.jpg",
        "frame_00002.jpg",
        "frame_00004.jpg",
    }
    assert prior_result.calibration is not None
    assert any(
        "stable ARKit pose anchor" in note for note in prior_result.calibration.notes
    )
    assert all(
        "Mobile capture priors applied:" not in warning
        for warning in prior_result.quality_warnings
    )


def test_pipeline_blocks_publish_when_strong_phone_segmentation_disagrees_with_backend_volume(
    tmp_path,
    monkeypatch,
):
    result, _records = _run_pipeline(
        tmp_path,
        monkeypatch,
        mobile_capture_prior=MobileCapturePrior(
            pile_segmentation_score=0.82,
            toe_segmentation_score=0.76,
            segmentation_confidence_score=0.79,
            quick_volume_m3=28.0,
            quick_confidence_score=0.86,
            quick_geometry_point_count=155_551,
            quick_camera_path_distance_m=18.2,
        ),
    )

    assert result.publishable is False
    assert any(
        "on-device segmentation quick volume disagrees" in blocker
        for blocker in result.quality_blockers
    )
