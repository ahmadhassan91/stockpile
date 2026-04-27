"""Tests for the ported ground-plane segmentation module."""

from __future__ import annotations

import numpy as np
import open3d as o3d
import pytest

from stockpile_lidar.config import GroundPlaneConfig
from stockpile_lidar.segmentation import segment_pile


def _make_pcd(points: np.ndarray) -> o3d.geometry.PointCloud:
    pcd = o3d.geometry.PointCloud()
    pcd.points = o3d.utility.Vector3dVector(np.ascontiguousarray(points, dtype=float))
    return pcd


def _synthetic_scene(rng: np.random.Generator) -> np.ndarray:
    """Ground plane at z≈0 plus a pile rising to z=2."""
    # Wide ground patch 8x8m centred at origin.
    n_ground = 4000
    ground = np.column_stack([
        rng.uniform(-4.0, 4.0, n_ground),
        rng.uniform(-4.0, 4.0, n_ground),
        rng.normal(0.0, 0.005, n_ground),
    ])

    # Pile: hemisphere of radius 1.5m centred at origin, sampled top-half.
    n_pile = 3000
    u = rng.uniform(0.0, 1.0, n_pile)
    theta = rng.uniform(0.0, 2 * np.pi, n_pile)
    phi = np.arccos(u)
    r = 1.5
    pile = np.column_stack([
        r * np.sin(phi) * np.cos(theta),
        r * np.sin(phi) * np.sin(theta),
        0.5 + r * np.cos(phi) * 1.0,  # peak ≈ 2.0m
    ])

    return np.vstack([ground, pile])


def test_segment_pile_separates_ground_and_pile_without_anchors():
    rng = np.random.default_rng(11)
    points = _synthetic_scene(rng)
    pcd = _make_pcd(points)

    result = segment_pile(pcd, GroundPlaneConfig())

    assert len(result.pile_cloud.points) > 0
    assert len(result.ground_cloud.points) > 0
    pile_pts = np.asarray(result.pile_cloud.points)
    # Pile should be above the ground threshold.
    assert pile_pts[:, 2].min() > 0.0


def test_segment_pile_with_anchor_prior_lands_ground_near_zero():
    rng = np.random.default_rng(17)
    points = _synthetic_scene(rng)
    pcd = _make_pcd(points)

    # Three anchors slightly offset from true ground (z≈0.05).
    anchors = [
        np.array([2.0, 2.0, 0.05]),
        np.array([-2.0, 2.0, 0.05]),
        np.array([0.0, -2.5, 0.05]),
    ]

    result = segment_pile(pcd, GroundPlaneConfig(), ground_anchor_positions=anchors)

    assert len(result.pile_cloud.points) > 0
    assert len(result.ground_cloud.points) > 0
    ground_pts = np.asarray(result.ground_cloud.points)
    # Ground points should be clustered tightly around z=0 after the shift.
    assert abs(float(np.median(ground_pts[:, 2]))) < 0.1


def test_segment_pile_with_anchors_none_works():
    rng = np.random.default_rng(23)
    points = _synthetic_scene(rng)
    pcd = _make_pcd(points)

    # Explicitly pass ``None`` for ground_anchor_positions — should still work.
    result = segment_pile(pcd, GroundPlaneConfig(), ground_anchor_positions=None)

    assert len(result.pile_cloud.points) > 0
    assert len(result.ground_cloud.points) > 0
