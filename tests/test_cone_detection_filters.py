from __future__ import annotations

import numpy as np

from stockpile.cone_detection import ConeDetection, _passes_shape_filters
from stockpile.config import ConeDetectionConfig


def _make_detection(
    *,
    bbox: tuple[int, int, int, int],
    area: float,
    solidity: float = 0.9,
) -> ConeDetection:
    x, y, w, h = bbox
    contour = np.array(
        [[[x, y]], [[x + w, y]], [[x + w, y + h]], [[x, y + h]]],
        dtype=np.int32,
    )
    return ConeDetection(
        bbox=bbox,
        centroid=(x + w / 2.0, y + h / 2.0),
        tip=(x + w / 2.0, y),
        base_center=(x + w / 2.0, y + h),
        area=area,
        solidity=solidity,
        contour=contour,
    )


def test_passes_shape_filters_accepts_plausible_cone_geometry():
    det = _make_detection(bbox=(639, 979, 122, 322), area=14265.5, solidity=0.905)

    assert _passes_shape_filters(det, (1920, 1080, 3), ConeDetectionConfig())


def test_passes_shape_filters_rejects_sparse_red_blob():
    det = _make_detection(bbox=(146, 1236, 152, 302), area=2430.0, solidity=0.78)

    assert not _passes_shape_filters(det, (1920, 1080, 3), ConeDetectionConfig())


def test_passes_shape_filters_rejects_oversized_bbox_even_with_decent_fill():
    det = _make_detection(bbox=(596, 942, 361, 401), area=30685.0, solidity=0.826)

    assert not _passes_shape_filters(det, (1920, 1080, 3), ConeDetectionConfig())
