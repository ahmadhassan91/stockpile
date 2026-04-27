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

from stockpile_lidar.config import GroundPlaneConfig, QualityGateConfig, VolumeConfig
from stockpile_lidar.fusion import TSDFFusionConfig, TSDFFusionResult, fuse_capture_bundle
from stockpile_lidar.ingestion import StockpileCaptureBundle
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
                return None

            anchor_positions = _ground_anchor_positions(bundle)
            ground = segment_pile(
                fusion.point_cloud,
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
            logger.warning("LiDAR TSDF pipeline failed; falling back to quick estimate: %s", exc)
            return None

        return self._build_tsdf_result(
            result_id=result_id,
            manifest=manifest,
            bundle=bundle,
            fusion=fusion,
            ground=ground,
            volume=volume,
            quality=quality,
            anchor_positions=anchor_positions,
        )

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

        return {
            "result_id": result_id,
            "stage": "complete",
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
            "diagnostics": {
                "capture_id": capture_id,
                "site_id": site_id,
                "material_code": material_code,
                "frame_count": frame_count,
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
            },
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
            "publishable": True,
            "review_grade": False,
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
            "quality_warnings": [],
            "diagnostics": {
                "capture_id": capture_id,
                "site_id": site_id,
                "material_code": material_code,
                "frame_count": frame_count,
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


def _point_count(point_cloud: Any) -> int:
    if point_cloud is None or not hasattr(point_cloud, "points"):
        return 0
    return len(point_cloud.points)


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
