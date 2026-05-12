"""Lean LiDAR pipeline.

The pipeline prefers backend-side TSDF fusion from the captured RGB + depth +
pose bundle, then reuses the legacy ground-plane, volume, and quality-gate
math on the fused metric point cloud. The on-device LiDAR quick estimate stays
as a compatibility fallback for malformed, partial, or tiny test bundles.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Any
from uuid import uuid4

import numpy as np
import open3d as o3d

from stockpile_lidar.config import GroundPlaneConfig, QualityGateConfig, VolumeConfig
from stockpile_lidar.fusion import TSDFFusionConfig, TSDFFusionResult, fuse_capture_bundle
from stockpile_lidar.ingestion import StockpileCaptureBundle
from stockpile_lidar.measurement import (
    CameraIntrinsics,
    MeasurementConfig,
    MeasurementResult,
    compute_stockpile_measurement,
    fuse_depth_frames,
)
from stockpile_lidar.quality import QualityAssessment, assess_quality
from stockpile_lidar.segmentation import GroundPlaneResult, segment_pile
from stockpile_lidar.volume import VolumeResult, compute_volume


logger = logging.getLogger(__name__)


# Module-level in-memory stores. Throwaway state is fine for this slice — the
# next slice will move them behind a real persistence layer (Postgres).
JOB_STORE: dict[str, dict[str, Any]] = {}
RESULT_STORE: dict[str, dict[str, Any]] = {}


def reset_state() -> None:
    """Clear in-memory stores (used by tests)."""

    JOB_STORE.clear()
    RESULT_STORE.clear()


_QUICK_ESTIMATE_NOTE = (
    "Volume from on-device LiDAR quick estimate because backend fusion was unavailable for this bundle."
)
_TSDF_FUSION_NOTE = "Volume from backend TSDF-fused LiDAR depth."
_NUMPY_FUSION_NOTE = "Volume from backend NumPy-fused LiDAR depth."
_RESULT_LABEL_VERIFIED = "verified"
_RESULT_LABEL_REVIEW_ONLY = "review_only"
_RESULT_LABEL_REJECTED = "rejected"


@dataclass(frozen=True)
class _NumpyPointCloud:
    points: np.ndarray


@dataclass(frozen=True)
class PipelineSubmission:
    """Lightweight envelope returned by :meth:`LidarPipeline.process_capture`."""

    capture_id: str
    job_id: str
    result_id: str
    status: str
    result: dict[str, Any]


class LidarPipeline:
    """Synchronous orchestrator for markerless LiDAR captures."""

    def __init__(
        self,
        *,
        fusion_config: TSDFFusionConfig | None = None,
        ground_config: GroundPlaneConfig | None = None,
        volume_config: VolumeConfig | None = None,
        quality_config: QualityGateConfig | None = None,
        enable_backend_fusion: bool = True,
    ) -> None:
        self.fusion_config = fusion_config or TSDFFusionConfig()
        self.ground_config = ground_config or GroundPlaneConfig()
        self.volume_config = volume_config or VolumeConfig()
        self.quality_config = quality_config or QualityGateConfig()
        self.enable_backend_fusion = enable_backend_fusion

    def process_capture(self, bundle: StockpileCaptureBundle) -> PipelineSubmission:
        manifest = bundle.manifest
        capture_id = _coerce_str(manifest.get("capture_id"), default="unknown")
        result_id = str(uuid4())
        job_id = str(uuid4())

        result_payload = None
        if self.enable_backend_fusion:
            result_payload = self._try_backend_fusion(bundle, result_id)

        if result_payload is None:
            result_payload = self._build_quick_estimate_result(result_id, manifest)

        RESULT_STORE[result_id] = result_payload
        JOB_STORE[job_id] = {
            "job_id": job_id,
            "status": "completed",
            "result_id": result_id,
        }

        return PipelineSubmission(
            capture_id=capture_id,
            job_id=job_id,
            result_id=result_id,
            status="completed",
            result=result_payload,
        )

    def _try_backend_fusion(
        self,
        bundle: StockpileCaptureBundle,
        result_id: str,
    ) -> dict[str, Any] | None:
        manifest = bundle.manifest
        try:
            fusion = fuse_capture_bundle(bundle, self.fusion_config)
            fused_point_count = _point_count(fusion.point_cloud)
            if fusion.fused_frame_count <= 0 or fused_point_count <= 0:
                return self._try_numpy_measurement(
                    bundle,
                    result_id,
                    fallback_reason="TSDF fusion produced no usable geometry.",
                )
            working_cloud, roi_diagnostics = _crop_point_cloud_to_capture_roi(
                fusion.point_cloud,
                manifest,
            )

            anchor_positions = _ground_anchor_positions(bundle)
            ground = segment_pile(
                working_cloud,
                self.ground_config,
                ground_anchor_positions=anchor_positions,
            )
            volume = compute_volume(
                ground.pile_cloud,
                self.volume_config,
                footprint_points=_transform_anchor_positions(
                    anchor_positions,
                    getattr(ground, "transform_matrix", np.eye(4)),
                ),
                full_scene_cloud=ground.full_cloud_transformed,
            )
            quality_manifest = dict(manifest)
            quality_manifest["poses"] = bundle.poses
            quality = assess_quality(
                ground.pile_cloud,
                volume,
                quality_manifest,
                self.quality_config,
            )
        except Exception as exc:
            logger.warning("LiDAR TSDF pipeline failed; trying NumPy depth fusion: %s", exc)
            return self._try_numpy_measurement(
                bundle,
                result_id,
                fallback_reason=f"TSDF pipeline failed: {exc}",
            )

        return self._build_tsdf_result(
            result_id=result_id,
            manifest=manifest,
            bundle=bundle,
            fusion=fusion,
            ground=ground,
            volume=volume,
            quality=quality,
            anchor_positions=anchor_positions,
            roi_diagnostics=roi_diagnostics,
        )

    def _try_numpy_measurement(
        self,
        bundle: StockpileCaptureBundle,
        result_id: str,
        *,
        fallback_reason: str,
    ) -> dict[str, Any] | None:
        manifest = bundle.manifest
        try:
            depth_w, depth_h = _depth_dimensions(manifest)
            rgb_w, rgb_h = _rgb_dimensions(manifest)
            depths: list[np.ndarray] = []
            poses: list[np.ndarray] = []
            intrinsics: list[CameraIntrinsics] = []
            confidences: list[np.ndarray | None] = []
            skipped = 0

            for index, pose in enumerate(bundle.poses):
                if not _is_pose_usable(pose) or index >= len(bundle.depth_frames):
                    skipped += 1
                    continue
                try:
                    depths.append(_load_depth_frame(bundle.depth_frames[index], depth_w, depth_h))
                    poses.append(_coerce_matrix(pose.get("transform"), 16).reshape((4, 4)))
                    intrinsics.append(_camera_intrinsics(pose, depth_w, depth_h, rgb_w, rgb_h))
                    confidences.append(
                        _load_confidence_frame(bundle.root / "confidence", index, depth_w, depth_h)
                    )
                except (OSError, TypeError, ValueError):
                    skipped += 1

            fusion = fuse_depth_frames(
                depths,
                poses,
                intrinsics,
                confidences=confidences,
                config=MeasurementConfig(
                    max_depth_m=self.fusion_config.depth_trunc,
                    confidence_min=self.fusion_config.confidence_min,
                    grid_resolution_m=max(self.volume_config.grid_resolution, 0.01),
                ),
            )
            if len(fusion.points) == 0:
                return None

            anchor_positions = _ground_anchor_positions(bundle)
            ground_prior = _ground_prior_z(anchor_positions)
            measurement = compute_stockpile_measurement(
                fusion.points,
                ground_prior=ground_prior,
                config=MeasurementConfig(
                    max_depth_m=self.fusion_config.depth_trunc,
                    confidence_min=self.fusion_config.confidence_min,
                    grid_resolution_m=max(self.volume_config.grid_resolution, 0.01),
                ),
            )
            if measurement.volume_m3 <= 0 and measurement.diagnostics.pile_point_count <= 0:
                return None

            return self._build_numpy_result(
                result_id=result_id,
                manifest=manifest,
                bundle=bundle,
                measurement=measurement,
                points=fusion.points,
                fused_frame_count=fusion.frame_count,
                skipped_frame_count=skipped + fusion.skipped_frame_count,
                warnings=(*fusion.warnings, fallback_reason),
                anchor_positions=anchor_positions,
            )
        except Exception as exc:
            logger.warning("LiDAR NumPy measurement fallback failed: %s", exc)
            return None

    def _build_numpy_result(
        self,
        *,
        result_id: str,
        manifest: dict,
        bundle: StockpileCaptureBundle,
        measurement: MeasurementResult,
        points: np.ndarray,
        fused_frame_count: int,
        skipped_frame_count: int,
        warnings: tuple[str, ...],
        anchor_positions: list[np.ndarray],
    ) -> dict[str, Any]:
        volume = _volume_result_from_measurement(measurement)
        pile_points = _pile_points_from_measurement(points, measurement)
        quality_manifest = dict(manifest)
        quality_manifest["poses"] = bundle.poses
        quality = assess_quality(
            _NumpyPointCloud(pile_points),
            volume,
            quality_manifest,
            self.quality_config,
        )
        for warning in (*warnings, *measurement.diagnostics.warnings):
            if warning and warning not in quality.warnings:
                quality.warnings.append(warning)

        capture_id = _coerce_str(manifest.get("capture_id"), default="unknown")
        site_id = _coerce_str(manifest.get("site_id"), default=None)
        material_code = _coerce_str(manifest.get("material_code"), default=None)
        density = _coerce_float(manifest.get("density_kg_per_m3"), default=0.0) or 0.0
        frame_count = _coerce_int(manifest.get("frame_count"), default=len(bundle.poses))
        tracking_state_summary = manifest.get("tracking_state_summary")
        quick_estimate = _quick_estimate(manifest)

        return {
            "result_id": result_id,
            "stage": "complete",
            "result_label": _label_for_quality(quality),
            "measurement_status": _label_for_quality(quality),
            "provisional": bool(quality.warnings),
            "publishable": quality.publishable,
            "review_grade": quality.review_grade,
            "weight_kg": volume.recommended_m3 * density,
            "scale_factor_m_per_unit": 1.0,
            "scale_source": "lidar_native",
            "num_frames": frame_count,
            "num_colmap_points": len(points),
            "num_colmap_images": fused_frame_count,
            "calibration": {
                "scale_factor_m_per_unit": 1.0,
                "confidence": 1.0,
                "num_cones_used": 0,
                "selected_method": "lidar_numpy_fusion",
                "notes": [_NUMPY_FUSION_NOTE],
            },
            "volume": {
                "convex_hull_m3": volume.convex_hull_m3,
                "alpha_shape_m3": volume.alpha_shape_m3,
                "grid_integration_m3": volume.grid_integration_m3,
                "recommended_m3": volume.recommended_m3,
                "recommended_method": volume.recommended_method,
                "recommended_note": volume.recommended_note,
                "grid_resolution": volume.grid_resolution,
                "num_points": volume.num_points,
                "grid_occupancy_pct": volume.grid_occupancy_pct,
                "grid_cells_observed": volume.grid_cells_observed,
                "grid_cells_total": volume.grid_cells_total,
                "grid_interpolated": volume.grid_interpolated,
                "grid_to_hull_ratio": volume.grid_to_hull_ratio,
                "footprint_area_m2": volume.footprint_area_m2,
                "footprint_source": volume.footprint_source,
                "toe_candidate_points": volume.toe_candidate_points,
                "toe_height_upper_m": volume.toe_height_upper_m,
            },
            "quality_blockers": quality.blockers,
            "quality_warnings": quality.warnings,
            "diagnostics": {
                "capture_id": capture_id,
                "site_id": site_id,
                "material_code": material_code,
                "density_kg_per_m3": density,
                "pile_size_mode": manifest.get("pile_size_mode"),
                "frame_count": frame_count,
                "tracking_normal_pct": _tracking_normal_pct(tracking_state_summary),
                "depth_confidence_pct": _depth_confidence_pct(manifest),
                "uncertainty": _optional_mapping(
                    manifest,
                    "uncertainty",
                    "uncertainty_estimate",
                    "measurement_uncertainty",
                ),
                "repeatability": _optional_mapping(
                    manifest,
                    "repeatability",
                    "repeatability_estimate",
                    "repeatability_metrics",
                ),
                "tracking_state_summary": tracking_state_summary,
                "on_device_quick_estimate": quick_estimate,
                "backend_volume_source": "numpy_depth_fusion",
                "fused_frame_count": fused_frame_count,
                "skipped_frame_count": skipped_frame_count,
                "fused_point_count": int(len(points)),
                "pile_point_count": measurement.diagnostics.pile_point_count,
                "ground_point_count": int(max(0, len(points) - measurement.diagnostics.pile_point_count)),
                "ground_z": measurement.diagnostics.ground_z,
                "ground_inlier_ratio": measurement.diagnostics.ground_inlier_ratio,
                "ground_anchor_count": len(anchor_positions),
            },
            "error": None,
        }

    def _build_tsdf_result(
        self,
        *,
        result_id: str,
        manifest: dict,
        bundle: StockpileCaptureBundle,
        fusion: TSDFFusionResult,
        ground: GroundPlaneResult,
        volume: VolumeResult,
        quality: QualityAssessment,
        anchor_positions: list[np.ndarray],
        roi_diagnostics: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        capture_id = _coerce_str(manifest.get("capture_id"), default="unknown")
        site_id = _coerce_str(manifest.get("site_id"), default=None)
        material_code = _coerce_str(manifest.get("material_code"), default=None)
        density = _coerce_float(manifest.get("density_kg_per_m3"), default=0.0) or 0.0
        frame_count = _coerce_int(manifest.get("frame_count"), default=len(bundle.poses))
        tracking_state_summary = manifest.get("tracking_state_summary")
        quick_estimate = _quick_estimate(manifest)

        fused_point_count = _point_count(fusion.point_cloud)
        pile_point_count = _point_count(ground.pile_cloud)
        ground_point_count = _point_count(ground.ground_cloud)
        weight_kg = volume.recommended_m3 * density

        diagnostics = {
            "capture_id": capture_id,
            "site_id": site_id,
            "material_code": material_code,
            "density_kg_per_m3": density,
            "pile_size_mode": manifest.get("pile_size_mode"),
            "persisted_bundle_path": manifest.get("persisted_bundle_path"),
            "frame_count": frame_count,
            "tracking_normal_pct": _tracking_normal_pct(tracking_state_summary),
            "depth_confidence_pct": _depth_confidence_pct(manifest),
            "uncertainty": _optional_mapping(
                manifest,
                "uncertainty",
                "uncertainty_estimate",
                "measurement_uncertainty",
            ),
            "repeatability": _optional_mapping(
                manifest,
                "repeatability",
                "repeatability_estimate",
                "repeatability_metrics",
            ),
            "tracking_state_summary": tracking_state_summary,
            "on_device_quick_estimate": quick_estimate,
            "backend_volume_source": "tsdf_fusion",
            "tsdf_voxel_size_m": fusion.voxel_size,
            "tsdf_sdf_trunc_m": fusion.sdf_trunc,
            "fused_frame_count": fusion.fused_frame_count,
            "skipped_frame_count": fusion.skipped_frame_count,
            "fused_point_count": fused_point_count,
            "pile_point_count": pile_point_count,
            "ground_point_count": ground_point_count,
            "ground_inlier_ratio": ground.inlier_ratio,
            "ground_anchor_count": len(anchor_positions),
        }
        if roi_diagnostics:
            diagnostics.update(roi_diagnostics)

        return {
            "result_id": result_id,
            "stage": "complete",
            "result_label": _label_for_quality(quality),
            "measurement_status": _label_for_quality(quality),
            "provisional": False,
            "publishable": quality.publishable,
            "review_grade": quality.review_grade,
            "weight_kg": weight_kg,
            "scale_factor_m_per_unit": 1.0,
            "scale_source": "lidar_native",
            "num_frames": frame_count,
            "num_colmap_points": fused_point_count,
            "num_colmap_images": fusion.fused_frame_count,
            "calibration": {
                "scale_factor_m_per_unit": 1.0,
                "confidence": 1.0,
                "num_cones_used": 0,
                "selected_method": "lidar_tsdf_fusion",
                "notes": [_TSDF_FUSION_NOTE],
            },
            "volume": {
                "convex_hull_m3": volume.convex_hull_m3,
                "alpha_shape_m3": volume.alpha_shape_m3,
                "grid_integration_m3": volume.grid_integration_m3,
                "recommended_m3": volume.recommended_m3,
                "recommended_method": volume.recommended_method,
                "recommended_note": volume.recommended_note,
                "grid_resolution": volume.grid_resolution,
                "num_points": volume.num_points,
                "grid_occupancy_pct": volume.grid_occupancy_pct,
                "grid_cells_observed": volume.grid_cells_observed,
                "grid_cells_total": volume.grid_cells_total,
                "grid_interpolated": volume.grid_interpolated,
                "grid_to_hull_ratio": volume.grid_to_hull_ratio,
                "footprint_area_m2": volume.footprint_area_m2,
                "footprint_source": volume.footprint_source,
                "toe_candidate_points": volume.toe_candidate_points,
                "toe_height_upper_m": volume.toe_height_upper_m,
            },
            "quality_blockers": quality.blockers,
            "quality_warnings": quality.warnings,
            "diagnostics": diagnostics,
            "error": None,
        }

    def _build_quick_estimate_result(
        self,
        result_id: str,
        manifest: dict,
    ) -> dict[str, Any]:
        capture_id = _coerce_str(manifest.get("capture_id"), default="unknown")
        site_id = _coerce_str(manifest.get("site_id"), default=None)
        material_code = _coerce_str(manifest.get("material_code"), default=None)
        density = _coerce_float(manifest.get("density_kg_per_m3"), default=0.0)
        frame_count = _coerce_int(manifest.get("frame_count"), default=0)
        tracking_state_summary = manifest.get("tracking_state_summary")

        quick_estimate = _quick_estimate(manifest)
        volume_m3 = quick_estimate["volume_m3"]
        footprint_area_m2 = quick_estimate["footprint_area_m2"]
        peak_height_m = quick_estimate["peak_height_m"]
        confidence_score = quick_estimate["confidence_score"]

        weight_kg = volume_m3 * density

        return {
            "result_id": result_id,
            "stage": "complete",
            "result_label": _RESULT_LABEL_REVIEW_ONLY,
            "measurement_status": _RESULT_LABEL_REVIEW_ONLY,
            "provisional": True,
            "publishable": False,
            "review_grade": True,
            "weight_kg": weight_kg,
            "scale_factor_m_per_unit": 1.0,
            "scale_source": "lidar_native",
            "num_frames": frame_count,
            "num_colmap_points": 0,
            "num_colmap_images": frame_count,
            "calibration": {
                "scale_factor_m_per_unit": 1.0,
                "confidence": confidence_score,
                "num_cones_used": 0,
                "selected_method": "lidar_quick_estimate",
                "notes": [_QUICK_ESTIMATE_NOTE],
            },
            "volume": {
                "convex_hull_m3": None,
                "alpha_shape_m3": None,
                "grid_integration_m3": volume_m3,
                "recommended_m3": volume_m3,
                "recommended_method": "lidar_quick_estimate",
                "recommended_note": "On-device estimate used because backend fusion did not produce usable geometry.",
                "grid_resolution": 0.0,
                "num_points": 0,
                "grid_occupancy_pct": 100.0,
                "grid_to_hull_ratio": None,
                "footprint_area_m2": footprint_area_m2,
                "footprint_source": "lidar_quick_estimate",
            },
            "quality_blockers": [],
            "quality_warnings": [
                "Backend fusion did not produce verified geometry; this result is review-only."
            ],
            "diagnostics": {
                "capture_id": capture_id,
                "site_id": site_id,
                "material_code": material_code,
                "density_kg_per_m3": density,
                "pile_size_mode": manifest.get("pile_size_mode"),
                "frame_count": frame_count,
                "tracking_normal_pct": _tracking_normal_pct(tracking_state_summary),
                "depth_confidence_pct": _depth_confidence_pct(manifest),
                "fused_frame_count": 0,
                "skipped_frame_count": 0,
                "fused_point_count": 0,
                "pile_point_count": 0,
                "ground_point_count": 0,
                "uncertainty": _optional_mapping(
                    manifest,
                    "uncertainty",
                    "uncertainty_estimate",
                    "measurement_uncertainty",
                ),
                "repeatability": _optional_mapping(
                    manifest,
                    "repeatability",
                    "repeatability_estimate",
                    "repeatability_metrics",
                ),
                "tracking_state_summary": tracking_state_summary,
                "on_device_quick_estimate": {
                    "volume_m3": volume_m3,
                    "footprint_area_m2": footprint_area_m2,
                    "peak_height_m": peak_height_m,
                    "confidence_score": confidence_score,
                },
                "backend_volume_source": "quick_estimate_fallback",
            },
            "error": None,
        }


def _crop_point_cloud_to_capture_roi(
    point_cloud: Any,
    manifest: dict,
    *,
    min_points: int = 1000,
) -> tuple[Any, dict[str, Any]]:
    """Crop far scene geometry using the phone's footprint estimate as a soft ROI."""

    points = _points_array(point_cloud)
    input_count = int(len(points))
    diagnostics: dict[str, Any] = {
        "roi_crop_applied": False,
        "roi_crop_input_points": input_count,
        "roi_crop_output_points": input_count,
    }
    if input_count < min_points:
        return point_cloud, diagnostics

    quick_estimate = _quick_estimate(manifest)
    footprint_area_m2 = quick_estimate.get("footprint_area_m2")
    if footprint_area_m2 is None or footprint_area_m2 <= 0:
        return point_cloud, diagnostics

    xy = points[:, :2]
    finite_mask = np.isfinite(xy).all(axis=1)
    if finite_mask.sum() < min_points:
        return point_cloud, diagnostics

    finite_xy = xy[finite_mask]
    center = np.median(finite_xy, axis=0)
    footprint_radius = float(np.sqrt(float(footprint_area_m2) / np.pi))
    crop_radius = _capture_roi_crop_radius(footprint_radius, manifest)
    distances = np.linalg.norm(xy - center, axis=1)
    keep_mask = finite_mask & np.isfinite(distances) & (distances <= crop_radius)
    output_count = int(keep_mask.sum())
    if output_count < min_points or output_count >= input_count:
        diagnostics.update(
            {
                "roi_crop_radius_m": crop_radius,
                "roi_crop_center_x": float(center[0]),
                "roi_crop_center_y": float(center[1]),
            }
        )
        return point_cloud, diagnostics

    cropped = _select_point_cloud_points(point_cloud, np.flatnonzero(keep_mask))
    diagnostics.update(
        {
            "roi_crop_applied": True,
            "roi_crop_output_points": output_count,
            "roi_crop_removed_points": input_count - output_count,
            "roi_crop_radius_m": crop_radius,
            "roi_crop_center_x": float(center[0]),
            "roi_crop_center_y": float(center[1]),
            "roi_crop_footprint_area_m2": float(footprint_area_m2),
        }
    )
    return cropped, diagnostics


def _capture_roi_crop_radius(footprint_radius: float, manifest: dict) -> float:
    """Convert the phone footprint hint into a bounded crop radius."""

    mode = _coerce_str(manifest.get("pile_size_mode"), default="").strip().lower()
    quick_estimate = _quick_estimate(manifest)
    inflated_quick_estimate = (
        (quick_estimate.get("volume_m3") or 0.0) > 100.0
        or (quick_estimate.get("peak_height_m") or 0.0) > 6.0
        or (quick_estimate.get("footprint_area_m2") or 0.0) > 35.0
    )
    if inflated_quick_estimate:
        return 3.5
    max_radius = 4.5 if mode in {"small", "small_pile", "office", "sample", "sample_pile"} else 6.5
    return min(max(footprint_radius * 1.35 + 1.0, 4.0), max_radius)


def _points_array(point_cloud: Any) -> np.ndarray:
    if point_cloud is None or not hasattr(point_cloud, "points"):
        return np.empty((0, 3), dtype=float)
    points = np.asarray(point_cloud.points, dtype=float)
    if points.ndim != 2 or points.shape[1] < 3:
        return np.empty((0, 3), dtype=float)
    return points


def _select_point_cloud_points(point_cloud: Any, indices: np.ndarray) -> Any:
    if hasattr(point_cloud, "select_by_index"):
        return point_cloud.select_by_index(indices.astype(int).tolist())
    points = _points_array(point_cloud)
    cropped = o3d.geometry.PointCloud()
    cropped.points = o3d.utility.Vector3dVector(np.ascontiguousarray(points[indices], dtype=float))
    return cropped


def _coerce_str(value: Any, default: str | None) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return default


def _coerce_float(value: Any, default: float | None) -> float | None:
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return float(value)
    return default


def _coerce_int(value: Any, default: int) -> int:
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return default


def _quick_estimate(manifest: dict) -> dict[str, float | None]:
    quick_estimate = manifest.get("on_device_quick_estimate") or {}
    if not isinstance(quick_estimate, dict):
        quick_estimate = {}
    return {
        "volume_m3": _coerce_float(quick_estimate.get("volume_m3"), default=0.0),
        "footprint_area_m2": _coerce_float(
            quick_estimate.get("footprint_area_m2"), default=None
        ),
        "peak_height_m": _coerce_float(
            quick_estimate.get("peak_height_m"), default=None
        ),
        "confidence_score": _coerce_float(
            quick_estimate.get("confidence_score"), default=0.0
        ),
    }


def _label_for_quality(quality: QualityAssessment) -> str:
    if quality.blockers or not quality.publishable:
        return _RESULT_LABEL_REJECTED
    if quality.review_grade or quality.warnings:
        return _RESULT_LABEL_REVIEW_ONLY
    return _RESULT_LABEL_VERIFIED


def _tracking_normal_pct(payload: Any) -> float | None:
    fractions = _tracking_state_fractions(payload)
    if fractions is None:
        return None
    return fractions.get("normal", 0.0) * 100.0


def _tracking_state_fractions(payload: Any) -> dict[str, float] | None:
    if payload is None:
        return None
    if isinstance(payload, str):
        state = _normalize_tracking_state(payload)
        return {state: 1.0} if state else None
    if isinstance(payload, dict):
        items: dict[str, float] = {}
        total = 0.0
        for key, value in payload.items():
            state = _normalize_tracking_state(str(key))
            if state is None:
                continue
            try:
                numeric = float(value)
            except (TypeError, ValueError):
                continue
            if numeric < 0:
                continue
            items[state] = numeric
            total += numeric
        if not items:
            return None
        if total > 1.0 + 1e-6:
            return {key: value / total for key, value in items.items()}
        return items
    if isinstance(payload, list):
        counts: dict[str, int] = {}
        total = 0
        for entry in payload:
            state = None
            if isinstance(entry, str):
                state = _normalize_tracking_state(entry)
            elif isinstance(entry, dict):
                raw_state = entry.get("state") or entry.get("tracking_state")
                if raw_state is not None:
                    state = _normalize_tracking_state(str(raw_state))
            if state is None:
                continue
            counts[state] = counts.get(state, 0) + 1
            total += 1
        if total <= 0:
            return None
        return {state: count / total for state, count in counts.items()}
    return None


def _normalize_tracking_state(value: str) -> str | None:
    raw = value.strip().lower().replace("_", "").replace("-", "").replace(" ", "")
    if raw in {"normal", "ok", "tracking"}:
        return "normal"
    if raw == "limited":
        return "limited"
    if raw in {"notavailable", "unavailable", "lost"}:
        return "notavailable"
    return None


def _depth_confidence_pct(manifest: dict) -> float | None:
    for key in (
        "depth_confidence_pct",
        "depth_confidence_percent",
        "mean_depth_confidence_pct",
    ):
        value = _coerce_float(manifest.get(key), default=None)
        if value is not None:
            return value

    summary = manifest.get("depth_confidence_summary")
    if isinstance(summary, dict):
        for key in ("mean_pct", "average_pct", "confidence_pct"):
            value = _coerce_float(summary.get(key), default=None)
            if value is not None:
                return value
        high = _coerce_float(summary.get("high"), default=None)
        medium = _coerce_float(summary.get("medium"), default=None)
        low = _coerce_float(summary.get("low"), default=None)
        if high is not None or medium is not None or low is not None:
            high = high or 0.0
            medium = medium or 0.0
            low = low or 0.0
            total = high + medium + low
            if total > 0:
                return ((high + 0.5 * medium) / total) * 100.0

    quick_estimate = _quick_estimate(manifest)
    confidence_score = quick_estimate["confidence_score"]
    if confidence_score is None:
        return None
    if confidence_score <= 1.0:
        return confidence_score * 100.0
    return confidence_score


def _optional_mapping(manifest: dict, *keys: str) -> Any:
    for key in keys:
        value = manifest.get(key)
        if value is not None:
            return value
    return None


def _point_count(point_cloud: Any) -> int:
    if point_cloud is None or not hasattr(point_cloud, "points"):
        return 0
    return len(point_cloud.points)


def _depth_dimensions(manifest: dict) -> tuple[int, int]:
    return _dimensions_or_default(_section(manifest, "depth"), default=(256, 192))


def _rgb_dimensions(manifest: dict) -> tuple[int, int]:
    return _dimensions_or_default(_section(manifest, "rgb"), default=(0, 0))


def _section(manifest: dict, key: str) -> dict:
    section = manifest.get(key)
    return section if isinstance(section, dict) else {}


def _dimensions_or_default(section: dict, *, default: tuple[int, int]) -> tuple[int, int]:
    width = section.get("width")
    height = section.get("height")
    if isinstance(width, int) and isinstance(height, int) and width > 0 and height > 0:
        return width, height
    return default


def _is_pose_usable(pose: Any) -> bool:
    if not isinstance(pose, dict):
        return False
    tracking_state = pose.get("tracking_state")
    if tracking_state is not None and tracking_state != "normal":
        return False
    return pose.get("lidar_active") is not False


def _load_depth_frame(path: Any, width: int, height: int) -> np.ndarray:
    if path.suffix.lower() == ".npy":
        depth = np.load(path, allow_pickle=False)
    else:
        raw = path.read_bytes()
        expected = width * height * np.dtype(np.float16).itemsize
        if len(raw) != expected:
            raise ValueError("depth frame byte count mismatch")
        depth = np.frombuffer(raw, dtype=np.float16).reshape((height, width))
    if depth.shape != (height, width):
        raise ValueError("depth frame shape mismatch")
    depth32 = depth.astype(np.float32, copy=False)
    return np.where(np.isfinite(depth32) & (depth32 > 0), depth32, 0.0)


def _load_confidence_frame(
    confidence_dir: Any,
    index: int,
    width: int,
    height: int,
) -> np.ndarray | None:
    if not confidence_dir.is_dir():
        return None
    candidates = [
        confidence_dir / f"{index:06d}.u8.bin",
        confidence_dir / f"{index:06d}.bin",
        confidence_dir / f"frame_{index:06d}.u8.bin",
    ]
    path = next((candidate for candidate in candidates if candidate.is_file()), None)
    if path is None:
        files = sorted(p for p in confidence_dir.iterdir() if p.is_file())
        path = files[index] if index < len(files) else None
    if path is None:
        return None
    raw = path.read_bytes()
    if len(raw) != width * height:
        return None
    return np.frombuffer(raw, dtype=np.uint8).reshape((height, width))


def _camera_intrinsics(
    pose: dict,
    depth_w: int,
    depth_h: int,
    rgb_w: int,
    rgb_h: int,
) -> CameraIntrinsics:
    matrix = _coerce_matrix(pose.get("intrinsics"), 9).reshape((3, 3))
    fx, fy = float(matrix[0, 0]), float(matrix[1, 1])
    cx, cy = float(matrix[0, 2]), float(matrix[1, 2])
    if rgb_w > 0 and rgb_h > 0 and (rgb_w != depth_w or rgb_h != depth_h):
        fx *= depth_w / rgb_w
        fy *= depth_h / rgb_h
        cx *= depth_w / rgb_w
        cy *= depth_h / rgb_h
    return CameraIntrinsics(fx=fx, fy=fy, cx=cx, cy=cy, width=depth_w, height=depth_h)


def _coerce_matrix(value: Any, expected_count: int) -> np.ndarray:
    if value is None:
        raise ValueError("missing matrix")
    if isinstance(value, np.ndarray):
        flat = np.asarray(value, dtype=np.float64).reshape(-1)
    else:
        flattened: list[float] = []
        for item in value:
            if isinstance(item, (list, tuple, np.ndarray)):
                flattened.extend(float(x) for x in np.asarray(item).reshape(-1))
            else:
                flattened.append(float(item))
        flat = np.asarray(flattened, dtype=np.float64)
    if flat.size != expected_count:
        raise ValueError(f"expected {expected_count} matrix values, got {flat.size}")
    return flat


def _ground_prior_z(anchor_positions: list[np.ndarray]) -> float | None:
    if not anchor_positions:
        return None
    z_values = [
        float(position[2])
        for position in anchor_positions
        if len(position) >= 3 and np.isfinite(position[2])
    ]
    if not z_values:
        return None
    return float(np.median(z_values))


def _volume_result_from_measurement(measurement: MeasurementResult) -> VolumeResult:
    diagnostics = measurement.diagnostics
    hull_volume = diagnostics.hull_volume_m3
    grid_cells = int(round(measurement.grid_area_m2 / max(measurement.grid_resolution_m ** 2, 1e-9)))
    grid_to_hull_ratio = (
        measurement.volume_m3 / hull_volume
        if hull_volume is not None and hull_volume > 1e-9
        else None
    )
    return VolumeResult(
        convex_hull_m3=float(hull_volume or measurement.volume_m3),
        alpha_shape_m3=None,
        grid_integration_m3=measurement.volume_m3,
        recommended_m3=measurement.volume_m3,
        recommended_method=measurement.method,
        recommended_note=None,
        grid_resolution=measurement.grid_resolution_m,
        num_points=diagnostics.pile_point_count,
        grid_occupancy_pct=100.0 if grid_cells > 0 else 0.0,
        grid_cells_observed=grid_cells,
        grid_cells_total=grid_cells,
        grid_interpolated=False,
        grid_to_hull_ratio=grid_to_hull_ratio,
        footprint_area_m2=measurement.grid_area_m2,
        footprint_source="numpy_depth_grid",
    )


def _pile_points_from_measurement(
    points: np.ndarray,
    measurement: MeasurementResult,
) -> np.ndarray:
    normal = np.asarray(measurement.ground_plane.normal, dtype=float)
    normal = normal / max(float(np.linalg.norm(normal)), 1e-9)
    signed_height = points @ normal + measurement.ground_plane.offset
    return points[signed_height > MeasurementConfig().above_ground_threshold_m]


def _ground_anchor_positions(bundle: StockpileCaptureBundle) -> list[np.ndarray]:
    anchors_path = bundle.root / "anchors.json"
    if not anchors_path.is_file():
        return []
    try:
        payload = json.loads(anchors_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(payload, dict):
        return []

    positions: list[np.ndarray] = []
    planes = payload.get("planes")
    if isinstance(planes, list):
        for plane in planes:
            if not isinstance(plane, dict):
                continue
            alignment = _coerce_str(plane.get("alignment"), default="")
            if alignment and alignment.lower() != "horizontal":
                continue
            center = plane.get("center")
            if not isinstance(center, (list, tuple)) or len(center) < 3:
                continue
            try:
                positions.append(np.asarray(center[:3], dtype=float))
            except (TypeError, ValueError):
                continue

    anchors = payload.get("anchors")
    if isinstance(anchors, list):
        for anchor in anchors:
            if not isinstance(anchor, dict):
                continue
            anchor_type = _coerce_str(anchor.get("anchor_type"), default="")
            if anchor_type and anchor_type not in {"ground_plane", "pile_toe"}:
                continue
            transform = anchor.get("transform")
            if not isinstance(transform, dict):
                continue
            translation = transform.get("translation_meters")
            if not isinstance(translation, dict):
                continue
            try:
                positions.append(
                    np.asarray(
                        [
                            translation["x"],
                            translation["y"],
                            translation["z"],
                        ],
                        dtype=float,
                    )
                )
            except (KeyError, TypeError, ValueError):
                continue

    return positions


def _transform_anchor_positions(
    positions: list[np.ndarray],
    transform_matrix: np.ndarray,
) -> list[np.ndarray]:
    transformed: list[np.ndarray] = []
    for position in positions:
        try:
            homogeneous = np.append(np.asarray(position, dtype=float), 1.0)
            transformed.append((transform_matrix @ homogeneous)[:3])
        except (TypeError, ValueError):
            continue
    return transformed
