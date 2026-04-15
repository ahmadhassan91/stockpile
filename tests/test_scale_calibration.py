from __future__ import annotations

import pytest

import stockpile.scale_calibration as scale_calibration_module
from stockpile.config import ScaleCalibrationConfig
from stockpile.scale_calibration import (
    CalibrationResult,
    _select_projection_scale_value,
    calibrate_scale,
)


def _calibration_result(
    *,
    scale_factor: float,
    confidence: float,
    selected_method: str,
) -> CalibrationResult:
    return CalibrationResult(
        scale_factor=scale_factor,
        confidence=confidence,
        num_cones_used=4 if selected_method == "projection" else 0,
        per_cone_scales=[scale_factor],
        cone_3d_positions=[],
        selected_method=selected_method,
    )


def test_calibrate_scale_keeps_disagreement_ratio_even_when_camera_cross_check_is_low_confidence(
    monkeypatch,
):
    projection = _calibration_result(
        scale_factor=6.2199,
        confidence=0.51,
        selected_method="projection",
    )
    camera = _calibration_result(
        scale_factor=1.8757,
        confidence=0.05,
        selected_method="camera_height",
    )

    monkeypatch.setattr(
        scale_calibration_module,
        "calibrate_scale_projection",
        lambda *args, **kwargs: projection,
    )
    monkeypatch.setattr(
        scale_calibration_module,
        "calibrate_scale_from_camera_height",
        lambda *args, **kwargs: camera,
    )

    result = calibrate_scale(
        {"frame_00000.jpg": [object()]},
        {},
        {},
        ScaleCalibrationConfig(),
        {1: object()},
    )

    assert result.scale_disagreement_ratio == pytest.approx(6.2199 / 1.8757, rel=1e-6)
    assert any("ignored because the fitted ground plane was not stable enough" in note for note in result.notes)


def test_select_projection_scale_value_uses_height_weighting_when_small_cones_inflate_scale():
    config = ScaleCalibrationConfig()
    scales = scale_calibration_module.np.array([6.6, 6.4, 6.2, 5.9, 5.5, 2.3, 2.2, 2.1], dtype=float)
    heights = scale_calibration_module.np.array([110, 120, 130, 140, 150, 380, 410, 450], dtype=float)

    scale, method = _select_projection_scale_value(scales, heights, config)

    assert method == "height_weighted"
    assert scale < float(scale_calibration_module.np.median(scales))
    assert scale == pytest.approx(4.81, abs=0.25)
