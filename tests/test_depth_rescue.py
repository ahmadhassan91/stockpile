from __future__ import annotations

import numpy as np

from stockpile.cone_detection import ConeDetection
from stockpile.depth_rescue import (
    DepthRescueConfig,
    _candidate_frame_score,
    _estimate_depth_rescue_volume,
    _largest_component,
)


def _make_detection(x: int, y: int, w: int, h: int, area: float) -> ConeDetection:
    contour = np.array(
        [[[x, y]], [[x + w, y]], [[x + w, y + h]], [[x, y + h]]],
        dtype=np.int32,
    )
    return ConeDetection(
        bbox=(x, y, w, h),
        centroid=(x + w / 2.0, y + h / 2.0),
        tip=(x + w / 2.0, y),
        base_center=(x + w / 2.0, y + h),
        area=area,
        solidity=0.9,
        contour=contour,
    )


def test_candidate_frame_score_prefers_bigger_lower_more_centered_cone():
    shape = (1000, 1000, 3)
    stronger = _make_detection(420, 700, 120, 220, area=22000)
    weaker = _make_detection(50, 300, 60, 120, area=5000)

    assert _candidate_frame_score(shape, stronger) > _candidate_frame_score(shape, weaker)


def test_largest_component_uses_target_component_when_available():
    mask = np.zeros((12, 12), dtype=np.uint8)
    mask[1:4, 1:4] = 1
    mask[7:11, 7:11] = 1

    selected = _largest_component(mask, target_xy=(2, 2))
    assert int(selected.sum()) == 9
    assert selected[2, 2] == 1
    assert selected[8, 8] == 0


def test_estimate_depth_rescue_volume_returns_positive_values_for_simple_relief():
    depth_map = np.ones((40, 40), dtype=np.float32)
    relief = np.zeros_like(depth_map)
    relief[10:30, 12:28] = np.linspace(0.1, 1.0, 20, dtype=np.float32).reshape(20, 1)
    pile_mask = np.zeros_like(depth_map, dtype=np.uint8)
    pile_mask[10:30, 12:28] = 1
    det = _make_detection(16, 28, 8, 10, area=80)

    volume_m3, height_m = _estimate_depth_rescue_volume(
        depth_map,
        relief,
        pile_mask,
        det,
        DepthRescueConfig(cone_height_m=0.75),
    )

    assert volume_m3 is not None
    assert height_m is not None
    assert volume_m3 > 0
    assert height_m > 0
