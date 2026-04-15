from __future__ import annotations

import numpy as np
import open3d as o3d

from stockpile.config import PipelineConfig
from stockpile.pipeline import Pipeline, PipelineResult
from stockpile.scale_calibration import CalibrationResult
from stockpile.volume import VolumeResult


def _pile_cloud() -> o3d.geometry.PointCloud:
    xs, ys = np.meshgrid(np.linspace(-5.0, 5.0, 110), np.linspace(-5.0, 5.0, 110))
    z = np.maximum(0.0, 3.0 - 0.08 * (xs**2 + ys**2))
    points = np.column_stack([xs.ravel(), ys.ravel(), z.ravel()])
    cloud = o3d.geometry.PointCloud()
    cloud.points = o3d.utility.Vector3dVector(points)
    return cloud


def test_assess_measurement_quality_blocks_false_positive_dense_cone_pattern():
    pipeline = Pipeline(PipelineConfig())
    result = PipelineResult(
        calibration=CalibrationResult(
            scale_factor=6.2199,
            confidence=0.51,
            num_cones_used=36,
            per_cone_scales=[6.2199],
            cone_3d_positions=[],
            detected_cone_frames=206,
            registered_cone_frames=122,
            total_cone_detections=476,
            max_detections_in_frame=10,
            frames_with_multiple_detections=68,
            scale_disagreement_ratio=3.31,
            selected_method="projection",
        ),
        volume=VolumeResult(
            convex_hull_m3=3697.56,
            alpha_shape_m3=None,
            grid_integration_m3=3180.72,
            recommended_m3=3180.72,
            recommended_method="grid",
            recommended_note=None,
            grid_resolution=0.04,
            num_points=166198,
            grid_occupancy_pct=29.9,
            grid_cells_observed=100,
            grid_cells_total=335,
            grid_interpolated=True,
            grid_to_hull_ratio=0.86,
            footprint_area_m2=93.9,
            footprint_source="toe slope break",
        ),
        pile_cloud=_pile_cloud(),
    )

    pipeline._assess_measurement_quality(result)

    assert not result.publishable
    assert any("false-positive cone calibration" in message for message in result.quality_blockers)


def test_should_use_cone_positions_for_segmentation_rejects_unstable_calibration():
    pipeline = Pipeline(PipelineConfig())
    calibration = CalibrationResult(
        scale_factor=4.7283,
        confidence=0.34,
        num_cones_used=28,
        per_cone_scales=[4.7283],
        cone_3d_positions=[np.array([0.0, 0.0, 0.0])],
        detected_cone_frames=218,
        registered_cone_frames=95,
        total_cone_detections=470,
        max_detections_in_frame=7,
        frames_with_multiple_detections=58,
        scale_disagreement_ratio=2.26,
        selected_method="projection",
    )

    assert not pipeline._should_use_cone_positions_for_segmentation(calibration)
