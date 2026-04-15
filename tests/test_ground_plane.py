from __future__ import annotations

from stockpile.config import GroundPlaneConfig
from stockpile.ground_plane import _resolve_ground_z


def test_resolve_ground_z_keeps_ransac_when_cone_ground_disagrees_too_much():
    config = GroundPlaneConfig(max_cone_ground_disagreement_m=0.5)

    resolved = _resolve_ground_z(-2.80, -0.90, config)

    assert resolved == -2.80


def test_resolve_ground_z_blends_when_cone_ground_is_close():
    config = GroundPlaneConfig(max_cone_ground_disagreement_m=0.5)

    resolved = _resolve_ground_z(-2.80, -2.60, config)

    assert resolved == -2.70
