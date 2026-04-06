import numpy as np

from stockpile.volume import _build_footprint_polygon


def _sample_points() -> np.ndarray:
    return np.array(
        [
            [-1.0, -1.0, 0.05],
            [1.0, -1.0, 0.05],
            [1.0, 1.0, 0.05],
            [-1.0, 1.0, 0.05],
            [0.0, 0.0, 1.00],
            [0.2, 0.1, 0.90],
        ],
        dtype=float,
    )


def _run_build_footprint(monkeypatch, toe_polygon: np.ndarray):
    points_xyz = _sample_points()
    observed_polygon = np.array([[0.0, 0.0], [2.0, 0.0], [2.0, 2.0], [0.0, 2.0]], dtype=float)

    def fake_convex_polygon(points_xy):
        if len(points_xy) == len(points_xyz):
            return observed_polygon
        if len(points_xy) == 4:
            return toe_polygon
        return None

    monkeypatch.setattr("stockpile.volume._convex_polygon", fake_convex_polygon)
    monkeypatch.setattr("stockpile.volume._radial_blended_polygon", lambda *args, **kwargs: None)

    return _build_footprint_polygon(
        points_xyz=points_xyz,
        footprint_xy=None,
        full_scene_points_xyz=None,
        buffer_m=0.0,
        toe_buffer_m=0.0,
        toe_height_fraction=0.2,
        toe_max_height_m=0.5,
        toe_min_points=4,
        toe_sector_count=8,
        toe_radius_percentile=80.0,
        toe_outer_percentile=95.0,
        toe_blend_factor=0.4,
        toe_min_sector_coverage=0.5,
        toe_slope_break_bins=8,
        toe_slope_break_surface_percentile=80.0,
        toe_slope_break_height_m=0.1,
        toe_slope_break_consecutive_bins=2,
        min_toe_contour_area_ratio=0.78,
        min_toe_area_ratio=0.55,
        max_toe_area_ratio=1.6,
        min_cone_area_ratio=0.7,
    )


def test_build_footprint_polygon_rejects_too_small_toe_polygon(monkeypatch):
    toe_polygon = np.array([[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]], dtype=float)

    polygon, source, toe_candidates, toe_height_upper = _run_build_footprint(monkeypatch, toe_polygon)

    assert polygon is not None
    assert source == "observed_hull"
    assert toe_candidates == 4
    assert toe_height_upper is not None


def test_build_footprint_polygon_rejects_overly_large_toe_polygon(monkeypatch):
    toe_polygon = np.array([[0.0, 0.0], [4.0, 0.0], [4.0, 4.0], [0.0, 4.0]], dtype=float)

    polygon, source, *_ = _run_build_footprint(monkeypatch, toe_polygon)

    assert polygon is not None
    assert source == "observed_hull"


def test_build_footprint_polygon_keeps_reasonable_toe_polygon(monkeypatch):
    toe_polygon = np.array([[0.0, 0.0], [2.3, 0.0], [2.3, 2.3], [0.0, 2.3]], dtype=float)

    polygon, source, *_ = _run_build_footprint(monkeypatch, toe_polygon)

    assert polygon is not None
    assert source == "toe_hull"
