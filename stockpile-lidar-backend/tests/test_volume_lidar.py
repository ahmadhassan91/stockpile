"""Tests for the ported LiDAR volume module."""

from __future__ import annotations

import math

import numpy as np
import open3d as o3d
import pytest

from stockpile_lidar.config import VolumeConfig
from stockpile_lidar.volume import compute_volume


def _make_pcd(points: np.ndarray) -> o3d.geometry.PointCloud:
    pcd = o3d.geometry.PointCloud()
    pcd.points = o3d.utility.Vector3dVector(np.ascontiguousarray(points, dtype=float))
    return pcd


def test_hemisphere_volume_within_30pct_of_analytic():
    """Segmented hemisphere pile of radius 2m peaking at z=2.

    Analytic hemisphere volume = (2/3) * pi * r^3 ≈ 16.76 m³ for r=2.
    """
    r = 2.0
    theta = np.linspace(0.0, 2 * np.pi, 160, endpoint=False)
    phi = np.linspace(0.0, np.pi / 2.0, 80)
    theta_grid, phi_grid = np.meshgrid(theta, phi, indexing="ij")
    points = np.column_stack(
        [
            r * np.sin(phi_grid).ravel() * np.cos(theta_grid).ravel(),
            r * np.sin(phi_grid).ravel() * np.sin(theta_grid).ravel(),
            r * np.cos(phi_grid).ravel(),
        ]
    )
    pcd = _make_pcd(points)

    result = compute_volume(pcd, VolumeConfig())

    analytic = (2.0 / 3.0) * math.pi * (r ** 3)
    assert result.recommended_m3 > 0
    # Within 30% of the analytic hemisphere volume.
    assert abs(result.recommended_m3 - analytic) / analytic < 0.30, (
        f"recommended={result.recommended_m3:.2f} m³, analytic={analytic:.2f} m³"
    )


def test_degenerate_cloud_does_not_crash():
    """A 3-point cloud should produce a defined result without raising."""
    points = np.array(
        [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.5, 1.0, 0.0]], dtype=float
    )
    pcd = _make_pcd(points)

    result = compute_volume(pcd, VolumeConfig())

    # 3 points cannot form a 3D convex hull, so the hull volume is 0 and the
    # grid path should fall back to the "no recommended fallback" case. The
    # result must still be a defined VolumeResult and not raise.
    assert result is not None
    assert result.num_points == 3
    assert result.convex_hull_m3 == 0.0
    assert result.recommended_m3 >= 0.0
    assert result.recommended_method in {"grid_integration", "convex_hull_fallback"}


def test_random_cube_returns_finite_positive_volume():
    """A 1000-point random unit cube should yield finite, positive estimates."""
    rng = np.random.default_rng(13)
    points = rng.uniform(0.0, 1.0, size=(1000, 3))
    pcd = _make_pcd(points)

    result = compute_volume(pcd, VolumeConfig())

    assert math.isfinite(result.convex_hull_m3)
    assert math.isfinite(result.grid_integration_m3)
    assert math.isfinite(result.recommended_m3)
    assert result.recommended_m3 > 0.0
    assert result.convex_hull_m3 > 0.0
    assert result.grid_integration_m3 > 0.0
