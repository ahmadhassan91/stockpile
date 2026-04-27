"""Tests for the LiDAR-relevant quality gates."""

from __future__ import annotations

from datetime import datetime, timezone

import numpy as np
import open3d as o3d
import pytest

from stockpile_lidar.config import QualityGateConfig
from stockpile_lidar.manifest import CaptureManifest, LidarFrameManifest
from stockpile_lidar.quality import assess_quality
from stockpile_lidar.volume import VolumeResult


def _make_manifest(
    *,
    tracking_state_summary=None,
    poses=None,
    capture_id: str = "cap_q",
) -> object:
    """Build a duck-typed manifest carrying the LiDAR-specific fields.

    The legacy ``CaptureManifest`` dataclass is frozen and does not include
    tracking-state or pose-continuity fields, so we use a lightweight stand-in
    that exposes the same attribute surface plus the new fields.
    """

    class _Manifest:
        pass

    m = _Manifest()
    m.capture_id = capture_id
    m.device_id = "device_test"
    m.captured_at = datetime(2026, 4, 26, tzinfo=timezone.utc)
    m.frame_count = 0
    m.frames = ()
    m.tracking_state_summary = tracking_state_summary
    m.poses = poses
    return m


def _make_pile_cloud(num_points: int, peak_height: float) -> o3d.geometry.PointCloud:
    """Create a synthetic pile point cloud with the given peak height."""
    rng = np.random.default_rng(num_points + int(peak_height * 100))
    n_ground = max(50, num_points // 4)
    ground = np.column_stack([
        rng.uniform(-3.0, 3.0, n_ground),
        rng.uniform(-3.0, 3.0, n_ground),
        rng.uniform(0.001, 0.05, n_ground),
    ])
    n_pile = max(0, num_points - n_ground)
    if n_pile > 0:
        u = rng.uniform(0.0, 1.0, n_pile)
        theta = rng.uniform(0.0, 2 * np.pi, n_pile)
        phi = np.arccos(u)
        r = 1.5
        pile = np.column_stack([
            r * np.sin(phi) * np.cos(theta),
            r * np.sin(phi) * np.sin(theta),
            0.1 + peak_height * np.cos(phi),
        ])
        points = np.vstack([ground, pile])
    else:
        points = ground

    pcd = o3d.geometry.PointCloud()
    pcd.points = o3d.utility.Vector3dVector(np.ascontiguousarray(points, dtype=float))
    return pcd


def _healthy_volume(grid_to_hull_ratio: float = 1.2) -> VolumeResult:
    """A volume result that triggers no warnings or blockers."""
    return VolumeResult(
        convex_hull_m3=20.0,
        alpha_shape_m3=18.0,
        grid_integration_m3=20.0 * grid_to_hull_ratio,
        recommended_m3=20.0,
        recommended_method="grid_integration",
        recommended_note=None,
        grid_resolution=0.05,
        num_points=10000,
        grid_occupancy_pct=40.0,
        grid_cells_observed=400,
        grid_cells_total=1000,
        grid_interpolated=True,
        grid_to_hull_ratio=grid_to_hull_ratio,
        footprint_area_m2=12.0,
        footprint_source="toe_slope_break",
        toe_candidate_points=300,
        toe_height_upper_m=0.35,
    )


def test_healthy_capture_is_publishable_and_not_review_grade():
    pile = _make_pile_cloud(num_points=10_000, peak_height=2.0)
    volume = _healthy_volume()
    manifest = _make_manifest(tracking_state_summary={"normal": 1.0})

    result = assess_quality(pile, volume, manifest)

    assert result.publishable is True
    assert result.review_grade is False
    assert result.warnings == []
    assert result.blockers == []


def test_sparse_pile_is_review_grade_with_warning():
    # Few enough points to trip min_pile_points_warn (5000) but above the
    # block threshold (1500).
    pile = _make_pile_cloud(num_points=3_000, peak_height=2.0)
    volume = _healthy_volume()
    manifest = _make_manifest(tracking_state_summary={"normal": 1.0})

    result = assess_quality(pile, volume, manifest)

    assert result.publishable is True
    assert result.review_grade is True
    assert any("pile points" in w.lower() for w in result.warnings)
    assert result.blockers == []


def test_very_tall_pile_is_blocked():
    # Peak height 18m exceeds tall_pile_block_m=15m.
    pile = _make_pile_cloud(num_points=10_000, peak_height=18.0)
    volume = _healthy_volume()
    manifest = _make_manifest(tracking_state_summary={"normal": 1.0})

    result = assess_quality(pile, volume, manifest)

    assert result.publishable is False
    assert result.review_grade is False
    assert any("pile height" in b.lower() for b in result.blockers)


def test_tracking_not_available_above_threshold_blocks():
    pile = _make_pile_cloud(num_points=10_000, peak_height=2.0)
    volume = _healthy_volume()
    manifest = _make_manifest(
        tracking_state_summary={"normal": 0.7, "notavailable": 0.3},
    )

    result = assess_quality(pile, volume, manifest)

    assert result.publishable is False
    assert any("tracking" in b.lower() for b in result.blockers)


def test_tracking_limited_above_threshold_is_review_grade():
    pile = _make_pile_cloud(num_points=10_000, peak_height=2.0)
    volume = _healthy_volume()
    manifest = _make_manifest(
        tracking_state_summary={"normal": 0.7, "limited": 0.3},
    )

    result = assess_quality(pile, volume, manifest)

    assert result.publishable is True
    assert result.review_grade is True
    assert any("limited" in w.lower() for w in result.warnings)
    assert result.blockers == []
