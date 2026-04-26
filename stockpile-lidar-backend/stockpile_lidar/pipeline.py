"""Lean LiDAR pipeline.

For the first end-to-end vertical slice we do not run TSDF fusion or any
backend geometry. We trust the on-device quick estimate produced by the iOS
app and surface it as a v1-compatible :class:`PipelineResult` so the existing
iOS results UI can render it unchanged. Real fusion is a follow-up slice.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from uuid import uuid4

from stockpile_lidar.ingestion import StockpileCaptureBundle


# Module-level in-memory stores. Throwaway state is fine for this slice — the
# next slice will move them behind a real persistence layer (Postgres).
JOB_STORE: dict[str, dict[str, Any]] = {}
RESULT_STORE: dict[str, dict[str, Any]] = {}


def reset_state() -> None:
    """Clear in-memory stores (used by tests)."""

    JOB_STORE.clear()
    RESULT_STORE.clear()


_QUICK_ESTIMATE_NOTE = (
    "Volume from on-device LiDAR quick estimate (TSDF fusion not yet wired)."
)


@dataclass(frozen=True)
class PipelineSubmission:
    """Lightweight envelope returned by :meth:`LidarPipeline.process_capture`."""

    capture_id: str
    job_id: str
    result_id: str
    status: str
    result: dict[str, Any]


class LidarPipeline:
    """Synchronous orchestrator for the markerless capture vertical slice."""

    def process_capture(self, bundle: StockpileCaptureBundle) -> PipelineSubmission:
        manifest = bundle.manifest
        capture_id = _coerce_str(manifest.get("capture_id"), default="unknown")
        site_id = _coerce_str(manifest.get("site_id"), default=None)
        material_code = _coerce_str(manifest.get("material_code"), default=None)
        density = _coerce_float(manifest.get("density_kg_per_m3"), default=0.0)
        frame_count = _coerce_int(manifest.get("frame_count"), default=0)
        tracking_state_summary = manifest.get("tracking_state_summary")

        quick_estimate = manifest.get("on_device_quick_estimate") or {}
        if not isinstance(quick_estimate, dict):
            quick_estimate = {}
        volume_m3 = _coerce_float(quick_estimate.get("volume_m3"), default=0.0)
        footprint_area_m2 = _coerce_float(
            quick_estimate.get("footprint_area_m2"), default=None
        )
        peak_height_m = _coerce_float(
            quick_estimate.get("peak_height_m"), default=None
        )
        confidence_score = _coerce_float(
            quick_estimate.get("confidence_score"), default=0.0
        )

        weight_kg = volume_m3 * density

        result_id = str(uuid4())
        job_id = str(uuid4())

        result_payload: dict[str, Any] = {
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
                "recommended_note": "On-device estimate; full backend fusion pending.",
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
            },
            "error": None,
        }

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
