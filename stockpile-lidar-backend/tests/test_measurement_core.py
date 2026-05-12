from __future__ import annotations

import math

import numpy as np

from stockpile_lidar.measurement import (
    CameraIntrinsics,
    GroundPlane,
    MeasurementConfig,
    compute_stockpile_measurement,
    estimate_ground_plane,
    fuse_depth_frames,
    unproject_depth,
)


def _identity_pose(z: float = 0.0) -> np.ndarray:
    pose = np.eye(4, dtype=float)
    pose[2, 3] = z
    return pose


def _intrinsics(width: int, height: int) -> CameraIntrinsics:
    return CameraIntrinsics(
        fx=float(width),
        fy=float(height),
        cx=(width - 1) / 2.0,
        cy=(height - 1) / 2.0,
        width=width,
        height=height,
    )


def test_unproject_depth_filters_confidence_and_depth_range():
    depth = np.array(
        [
            [0.02, 1.0, 1.5],
            [2.0, 8.0, np.nan],
        ],
        dtype=np.float32,
    )
    confidence = np.array(
        [
            [2, 0, 2],
            [2, 2, 2],
        ],
        dtype=np.uint8,
    )
    cfg = MeasurementConfig(min_depth_m=0.05, max_depth_m=3.0, confidence_min=1)

    points = unproject_depth(depth, _identity_pose(), _intrinsics(3, 2), confidence=confidence, config=cfg)

    assert points.shape == (2, 3)
    assert np.allclose(points[:, 2], [1.5, 2.0])


def test_fuse_depth_frames_concatenates_world_space_samples():
    depth_frames = [
        np.ones((2, 2), dtype=np.float32),
        np.ones((2, 2), dtype=np.float32) * 2.0,
    ]
    poses = [_identity_pose(0.0), _identity_pose(3.0)]

    result = fuse_depth_frames(
        depth_frames,
        poses,
        _intrinsics(2, 2),
        config=MeasurementConfig(sample_stride=1),
    )

    assert result.frame_count == 2
    assert result.skipped_frame_count == 0
    assert result.points.shape == (8, 3)
    assert math.isclose(float(result.points[:4, 2].mean()), 1.0)
    assert math.isclose(float(result.points[4:, 2].mean()), 5.0)


def test_estimate_ground_plane_finds_flat_ground_under_pile():
    rng = np.random.default_rng(7)
    ground = np.column_stack(
        [
            rng.uniform(-2.0, 2.0, 900),
            rng.uniform(-2.0, 2.0, 900),
            rng.normal(0.2, 0.003, 900),
        ]
    )
    pile = np.column_stack(
        [
            rng.uniform(-0.8, 0.8, 300),
            rng.uniform(-0.8, 0.8, 300),
            rng.uniform(0.35, 1.2, 300),
        ]
    )

    plane = estimate_ground_plane(np.vstack([ground, pile]))

    assert plane.source == "ransac"
    assert abs(plane.ground_z - 0.2) < 0.03
    assert plane.inlier_ratio is not None
    assert plane.inlier_ratio > 0.6


def test_compute_stockpile_measurement_uses_prior_and_grid_volume():
    xs = np.linspace(-0.95, 0.95, 20)
    ys = np.linspace(-0.95, 0.95, 20)
    xx, yy = np.meshgrid(xs, ys, indexing="xy")
    top = np.column_stack([xx.ravel(), yy.ravel(), np.ones(xx.size)])
    ground = np.column_stack([xx.ravel(), yy.ravel(), np.zeros(xx.size)])
    points = np.vstack([ground, top])

    result = compute_stockpile_measurement(
        points,
        ground_prior=GroundPlane.from_ground_z(0.0),
        config=MeasurementConfig(grid_resolution_m=0.1, above_ground_threshold_m=0.01),
    )

    assert result.method == "grid_integration"
    assert result.diagnostics.point_count == 800
    assert result.diagnostics.pile_point_count == 400
    assert result.diagnostics.ground_z == 0.0
    assert abs(result.volume_m3 - 4.0) < 0.35
    assert abs(result.grid_area_m2 - 4.0) < 0.35
    assert "convex hull volume unavailable" in result.diagnostics.warnings


def test_compute_stockpile_measurement_empty_cloud_is_defined():
    result = compute_stockpile_measurement(np.empty((0, 3)))

    assert result.volume_m3 == 0.0
    assert result.diagnostics.point_count == 0
    assert "no points available for measurement" in result.diagnostics.warnings
