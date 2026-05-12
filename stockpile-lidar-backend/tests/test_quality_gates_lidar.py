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
    on_device_quick_estimate=None,
    pile_size_mode: str | None = None,
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
    m.on_device_quick_estimate = on_device_quick_estimate
    m.pile_size_mode = pile_size_mode
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


def _healthy_volume(
    grid_to_hull_ratio: float = 1.2,
    *,
    recommended_m3: float = 20.0,
    footprint_area_m2: float = 12.0,
) -> VolumeResult:
    """A volume result that triggers no warnings or blockers."""
    return VolumeResult(
        convex_hull_m3=recommended_m3,
        alpha_shape_m3=max(0.0, recommended_m3 * 0.9),
        grid_integration_m3=recommended_m3 * grid_to_hull_ratio,
        recommended_m3=recommended_m3,
        recommended_method="grid_integration",
        recommended_note=None,
        grid_resolution=0.05,
        num_points=10000,
        grid_occupancy_pct=40.0,
        grid_cells_observed=400,
        grid_cells_total=1000,
        grid_interpolated=True,
        grid_to_hull_ratio=grid_to_hull_ratio,
        footprint_area_m2=footprint_area_m2,
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


def test_backend_device_volume_disagreement_blocks_latest_field_failure_pattern():
    pile = _make_pile_cloud(num_points=170_000, peak_height=2.3)
    volume = VolumeResult(
        convex_hull_m3=83.95,
        alpha_shape_m3=None,
        grid_integration_m3=4.94,
        recommended_m3=4.94,
        recommended_method="grid_integration",
        recommended_note=None,
        grid_resolution=0.05,
        num_points=170_165,
        grid_occupancy_pct=63.4,
        grid_cells_observed=1687,
        grid_cells_total=2658,
        grid_interpolated=True,
        grid_to_hull_ratio=0.0588,
        footprint_area_m2=6.52,
        footprint_source="toe_hull",
        toe_candidate_points=5031,
        toe_height_upper_m=0.35,
    )
    manifest = _make_manifest(
        tracking_state_summary={"normal": 1.0},
        on_device_quick_estimate={"volume_m3": 21.14},
    )

    result = assess_quality(pile, volume, manifest)

    assert result.publishable is False
    assert any("disagrees with the phone" in blocker for blocker in result.blockers)
    assert any("only 0.06x" in blocker for blocker in result.blockers)


def test_empty_tracking_summary_blocks_incomplete_capture_metadata():
    pile = _make_pile_cloud(num_points=10_000, peak_height=2.0)
    volume = _healthy_volume()
    manifest = _make_manifest(tracking_state_summary={"normal": 0, "limited": 0, "notAvailable": 0})

    result = assess_quality(pile, volume, manifest)

    assert result.publishable is False
    assert any("no usable tracked frames" in blocker for blocker in result.blockers)


def test_small_pile_mode_surfaces_backend_volume_for_manual_review_when_geometry_exists():
    pile = _make_pile_cloud(num_points=63_093, peak_height=4.84)
    volume = VolumeResult(
        convex_hull_m3=16.36,
        alpha_shape_m3=None,
        grid_integration_m3=8.03,
        recommended_m3=8.03,
        recommended_method="grid_integration",
        recommended_note=None,
        grid_resolution=0.05,
        num_points=63_093,
        grid_occupancy_pct=54.2,
        grid_cells_observed=542,
        grid_cells_total=1000,
        grid_interpolated=True,
        grid_to_hull_ratio=0.49,
        footprint_area_m2=10.33,
        footprint_source="toe_slope_break",
        toe_candidate_points=300,
        toe_height_upper_m=0.35,
    )
    manifest = _make_manifest(
        tracking_state_summary={"normal": 51, "limited": 2, "notAvailable": 0},
        pile_size_mode="small",
        on_device_quick_estimate={
            "volume_m3": 31.11,
            "footprint_area_m2": 10.31,
            "peak_height_m": 4.84,
            "confidence_score": 0.83,
        },
    )

    result = assess_quality(pile, volume, manifest)

    assert result.publishable is True
    assert result.review_grade is True
    assert result.blockers == []
    assert any("Manual review required" in warning for warning in result.warnings)
    assert any("Small pile mode" in warning and "backend volume" in warning for warning in result.warnings)
    assert any("Small pile mode" in warning and "footprint" in warning for warning in result.warnings)
    assert any("Small pile mode" in warning and "height" in warning for warning in result.warnings)
    assert any("Small pile mode" in warning and "phone LiDAR estimate" in warning for warning in result.warnings)


def test_small_pile_mode_downgrades_low_grid_to_hull_to_manual_review_warning():
    pile = _make_pile_cloud(num_points=170_000, peak_height=2.3)
    volume = VolumeResult(
        convex_hull_m3=102.66,
        alpha_shape_m3=None,
        grid_integration_m3=7.56,
        recommended_m3=7.56,
        recommended_method="grid_integration",
        recommended_note=None,
        grid_resolution=0.05,
        num_points=179_781,
        grid_occupancy_pct=68.7,
        grid_cells_observed=2396,
        grid_cells_total=3485,
        grid_interpolated=True,
        grid_to_hull_ratio=0.073,
        footprint_area_m2=8.56,
        footprint_source="toe_hull",
        toe_candidate_points=7645,
        toe_height_upper_m=0.35,
    )
    manifest = _make_manifest(
        tracking_state_summary={"normal": 70, "limited": 2, "notAvailable": 0},
        pile_size_mode="small",
        on_device_quick_estimate={"volume_m3": 13.49, "peak_height_m": 5.62},
    )

    result = assess_quality(pile, volume, manifest)

    assert result.publishable is True
    assert result.review_grade is True
    assert result.blockers == []
    assert any("Grid volume is only 0.07x" in warning for warning in result.warnings)


def test_small_pile_mode_allows_compact_office_pile_with_consistent_volume():
    pile = _make_pile_cloud(num_points=10_000, peak_height=0.28)
    volume = _healthy_volume(
        recommended_m3=0.035,
        footprint_area_m2=0.22,
        grid_to_hull_ratio=1.05,
    )
    manifest = _make_manifest(
        tracking_state_summary={"normal": 1.0},
        pile_size_mode="small",
        on_device_quick_estimate={
            "volume_m3": 0.038,
            "footprint_area_m2": 0.24,
            "peak_height_m": 0.30,
            "confidence_score": 0.84,
        },
    )

    result = assess_quality(pile, volume, manifest)

    assert result.publishable is True
    assert result.blockers == []
