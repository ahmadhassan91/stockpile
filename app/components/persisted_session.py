"""Persist and restore the latest upload/run across Streamlit session resets."""

from __future__ import annotations

import gzip
import logging
import os
import pickle
from pathlib import Path
from typing import Any

import numpy as np
import open3d as o3d

from components.parameter_sidebar import SIDEBAR_SETTING_KEYS
from stockpile.ai_preflight import AIPreflightResult
from stockpile.config import PipelineConfig
from stockpile.pipeline import PipelineResult
from stockpile.scale_calibration import CalibrationResult
from stockpile.volume import VolumeResult

logger = logging.getLogger(__name__)

PERSISTED_SESSION_RESTORED_KEY = "_persisted_session_restored"
PERSISTED_SESSION_KEYS = tuple(SIDEBAR_SETTING_KEYS) + (
    "video_path",
    "settings_confirmed",
    "settings_dialog_dismissed",
    "confirmed_settings_signature",
    "upload_inferred_material",
    "upload_inferred_material_source",
    "recommended_processing_profile",
    "recommended_processing_notes",
    "ai_preflight_result",
    "ai_preflight_source",
    "last_uploaded_name",
    "last_uploaded_signature",
    "_upload_processed",
    "_video_info",
    "selected_material",
    "selected_density",
    "selected_density_display",
    "manual_scale_override",
)
SNAPSHOT_FILENAME = "last_session_snapshot.pkl.gz"
SNAPSHOT_ENV_VAR = "STOCKPILE_ENABLE_SESSION_SNAPSHOT"


def snapshot_persistence_enabled() -> bool:
    """Return whether disk-backed session snapshots are enabled."""
    value = os.environ.get(SNAPSHOT_ENV_VAR, "").strip().lower()
    return value in {"1", "true", "yes", "on"}


def _snapshot_path(workspace: str | Path | None = None) -> Path:
    workspace_path = Path(workspace) if workspace is not None else Path("data/workspace")
    return workspace_path / "output" / SNAPSHOT_FILENAME


def _point_cloud_to_payload(point_cloud: o3d.geometry.PointCloud | None) -> dict[str, Any] | None:
    if point_cloud is None:
        return None
    points = np.asarray(point_cloud.points)
    colors = np.asarray(point_cloud.colors) if point_cloud.has_colors() else None
    return {
        "points": points,
        "colors": colors,
    }


def _point_cloud_from_payload(payload: dict[str, Any] | None) -> o3d.geometry.PointCloud | None:
    if not payload:
        return None
    points = np.asarray(payload.get("points", []), dtype=float)
    if len(points) == 0:
        return o3d.geometry.PointCloud()
    point_cloud = o3d.geometry.PointCloud()
    point_cloud.points = o3d.utility.Vector3dVector(points)
    colors = payload.get("colors")
    if colors is not None:
        colors_arr = np.asarray(colors, dtype=float)
        if len(colors_arr) == len(points):
            point_cloud.colors = o3d.utility.Vector3dVector(colors_arr)
    return point_cloud


def _calibration_to_payload(calibration: CalibrationResult | None) -> dict[str, Any] | None:
    if calibration is None:
        return None
    return {
        "scale_factor": calibration.scale_factor,
        "confidence": calibration.confidence,
        "num_cones_used": calibration.num_cones_used,
        "per_cone_scales": list(calibration.per_cone_scales),
        "cone_3d_positions": [np.asarray(pos, dtype=float) for pos in calibration.cone_3d_positions],
        "detected_cone_frames": calibration.detected_cone_frames,
        "registered_cone_frames": calibration.registered_cone_frames,
        "total_cone_detections": calibration.total_cone_detections,
        "max_detections_in_frame": calibration.max_detections_in_frame,
        "frames_with_multiple_detections": calibration.frames_with_multiple_detections,
        "selected_method": calibration.selected_method,
        "projection_scale_factor": calibration.projection_scale_factor,
        "projection_confidence": calibration.projection_confidence,
        "camera_height_scale_factor": calibration.camera_height_scale_factor,
        "camera_height_confidence": calibration.camera_height_confidence,
        "scale_disagreement_ratio": calibration.scale_disagreement_ratio,
        "notes": list(calibration.notes),
    }


def _calibration_from_payload(payload: dict[str, Any] | None) -> CalibrationResult | None:
    if not payload:
        return None
    return CalibrationResult(
        scale_factor=float(payload["scale_factor"]),
        confidence=float(payload["confidence"]),
        num_cones_used=int(payload["num_cones_used"]),
        per_cone_scales=[float(value) for value in payload.get("per_cone_scales", [])],
        cone_3d_positions=[np.asarray(pos, dtype=float) for pos in payload.get("cone_3d_positions", [])],
        detected_cone_frames=int(payload.get("detected_cone_frames", 0)),
        registered_cone_frames=int(payload.get("registered_cone_frames", 0)),
        total_cone_detections=int(payload.get("total_cone_detections", 0)),
        max_detections_in_frame=int(payload.get("max_detections_in_frame", 0)),
        frames_with_multiple_detections=int(payload.get("frames_with_multiple_detections", 0)),
        selected_method=str(payload.get("selected_method", "projection")),
        projection_scale_factor=payload.get("projection_scale_factor"),
        projection_confidence=payload.get("projection_confidence"),
        camera_height_scale_factor=payload.get("camera_height_scale_factor"),
        camera_height_confidence=payload.get("camera_height_confidence"),
        scale_disagreement_ratio=payload.get("scale_disagreement_ratio"),
        notes=list(payload.get("notes", [])),
    )


def _volume_to_payload(volume: VolumeResult | None) -> dict[str, Any] | None:
    if volume is None:
        return None
    return {
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
    }


def _volume_from_payload(payload: dict[str, Any] | None) -> VolumeResult | None:
    if not payload:
        return None
    return VolumeResult(
        convex_hull_m3=float(payload["convex_hull_m3"]),
        alpha_shape_m3=payload.get("alpha_shape_m3"),
        grid_integration_m3=float(payload["grid_integration_m3"]),
        recommended_m3=float(payload["recommended_m3"]),
        recommended_method=str(payload["recommended_method"]),
        recommended_note=payload.get("recommended_note"),
        grid_resolution=float(payload["grid_resolution"]),
        num_points=int(payload["num_points"]),
        grid_occupancy_pct=float(payload["grid_occupancy_pct"]),
        grid_cells_observed=int(payload["grid_cells_observed"]),
        grid_cells_total=int(payload["grid_cells_total"]),
        grid_interpolated=bool(payload["grid_interpolated"]),
        grid_to_hull_ratio=payload.get("grid_to_hull_ratio"),
        footprint_area_m2=payload.get("footprint_area_m2"),
        footprint_source=payload.get("footprint_source"),
        toe_candidate_points=int(payload.get("toe_candidate_points", 0)),
        toe_height_upper_m=payload.get("toe_height_upper_m"),
    )


def _config_to_payload(config: PipelineConfig | None) -> dict[str, Any] | None:
    if config is None:
        return None
    return {
        "workspace": str(config.workspace),
        "material_density": config.material_density,
        "material_name": config.material_name,
        "manual_scale_override": config.manual_scale_override,
        "frame_interval_sec": config.frame_extraction.interval_sec,
        "frame_max_frames": config.frame_extraction.max_frames,
        "colmap_quality": config.colmap.quality,
        "cone_height_m": config.scale_calibration.known_cone_height_m,
        "camera_height_m": config.scale_calibration.assumed_camera_height_m,
        "camera_crosscheck_min_conf": config.scale_calibration.min_camera_height_confidence_for_crosscheck,
        "above_ground_threshold": config.ground_plane.above_ground_threshold,
        "grid_resolution": config.volume.grid_resolution,
    }


def _config_from_payload(payload: dict[str, Any] | None) -> PipelineConfig | None:
    if not payload:
        return None
    config = PipelineConfig(
        workspace=payload.get("workspace", "data/workspace"),
        material_density=float(payload.get("material_density", 2100.0)),
        material_name=str(payload.get("material_name", "Backfill 0–75 mm")),
        manual_scale_override=payload.get("manual_scale_override"),
    )
    config.frame_extraction.interval_sec = float(payload.get("frame_interval_sec", config.frame_extraction.interval_sec))
    config.frame_extraction.max_frames = int(payload.get("frame_max_frames", config.frame_extraction.max_frames))
    config.colmap.quality = str(payload.get("colmap_quality", config.colmap.quality))
    config.scale_calibration.known_cone_height_m = float(payload.get("cone_height_m", config.scale_calibration.known_cone_height_m))
    config.scale_calibration.assumed_camera_height_m = float(payload.get("camera_height_m", config.scale_calibration.assumed_camera_height_m))
    config.scale_calibration.min_camera_height_confidence_for_crosscheck = float(
        payload.get(
            "camera_crosscheck_min_conf",
            config.scale_calibration.min_camera_height_confidence_for_crosscheck,
        )
    )
    config.ground_plane.above_ground_threshold = float(
        payload.get("above_ground_threshold", config.ground_plane.above_ground_threshold)
    )
    config.volume.grid_resolution = float(payload.get("grid_resolution", config.volume.grid_resolution))
    return config


def _ai_preflight_to_payload(ai_preflight: AIPreflightResult | None) -> dict[str, Any] | None:
    if ai_preflight is None:
        return None
    return {
        "suggested_material": ai_preflight.suggested_material,
        "material_confidence": ai_preflight.material_confidence,
        "processing_profile": ai_preflight.processing_profile,
        "profile_confidence": ai_preflight.profile_confidence,
        "cone_visibility_score": ai_preflight.cone_visibility_score,
        "retake_required": ai_preflight.retake_required,
        "retake_reason": ai_preflight.retake_reason,
        "notes": list(ai_preflight.notes),
        "provider": ai_preflight.provider,
        "model": ai_preflight.model,
    }


def _ai_preflight_from_payload(payload: dict[str, Any] | None) -> AIPreflightResult | None:
    if not payload:
        return None
    return AIPreflightResult(
        suggested_material=payload.get("suggested_material"),
        material_confidence=float(payload.get("material_confidence", 0.0)),
        processing_profile=payload.get("processing_profile"),
        profile_confidence=float(payload.get("profile_confidence", 0.0)),
        cone_visibility_score=float(payload.get("cone_visibility_score", 0.0)),
        retake_required=bool(payload.get("retake_required", False)),
        retake_reason=str(payload.get("retake_reason", "")),
        notes=list(payload.get("notes", [])),
        provider=str(payload.get("provider", "OpenAI")),
        model=str(payload.get("model", "gpt-4.1")),
    )


def _result_to_payload(result: PipelineResult | None) -> dict[str, Any] | None:
    if result is None:
        return None
    return {
        "num_frames": result.num_frames,
        "num_frames_with_cones": result.num_frames_with_cones,
        "num_colmap_points": result.num_colmap_points,
        "num_colmap_images": result.num_colmap_images,
        "calibration": _calibration_to_payload(result.calibration),
        "volume": _volume_to_payload(result.volume),
        "weight_kg": result.weight_kg,
        "scale_factor_m_per_unit": result.scale_factor_m_per_unit,
        "scale_source": result.scale_source,
        "pile_cloud": _point_cloud_to_payload(result.pile_cloud),
        "ground_cloud": _point_cloud_to_payload(result.ground_cloud),
        "cone_3d_positions": [np.asarray(pos, dtype=float) for pos in result.cone_3d_positions],
        "sparse_model_dir": str(result.sparse_model_dir) if result.sparse_model_dir else None,
        "ply_path": str(result.ply_path) if result.ply_path else None,
        "stage": result.stage,
        "quality_blockers": list(result.quality_blockers),
        "quality_warnings": list(result.quality_warnings),
        "review_grade": result.review_grade,
        "publishable": result.publishable,
        "error": result.error,
    }


def _result_from_payload(payload: dict[str, Any] | None) -> PipelineResult | None:
    if not payload:
        return None
    return PipelineResult(
        num_frames=int(payload.get("num_frames", 0)),
        num_frames_with_cones=int(payload.get("num_frames_with_cones", 0)),
        num_colmap_points=int(payload.get("num_colmap_points", 0)),
        num_colmap_images=int(payload.get("num_colmap_images", 0)),
        calibration=_calibration_from_payload(payload.get("calibration")),
        volume=_volume_from_payload(payload.get("volume")),
        weight_kg=float(payload.get("weight_kg", 0.0)),
        scale_factor_m_per_unit=payload.get("scale_factor_m_per_unit"),
        scale_source=str(payload.get("scale_source", "auto")),
        pile_cloud=_point_cloud_from_payload(payload.get("pile_cloud")),
        ground_cloud=_point_cloud_from_payload(payload.get("ground_cloud")),
        cone_3d_positions=[np.asarray(pos, dtype=float) for pos in payload.get("cone_3d_positions", [])],
        sparse_model_dir=Path(payload["sparse_model_dir"]) if payload.get("sparse_model_dir") else None,
        ply_path=Path(payload["ply_path"]) if payload.get("ply_path") else None,
        stage=str(payload.get("stage", "")),
        quality_blockers=list(payload.get("quality_blockers", [])),
        quality_warnings=list(payload.get("quality_warnings", [])),
        review_grade=bool(payload.get("review_grade", False)),
        publishable=bool(payload.get("publishable", True)),
        error=payload.get("error"),
    )


def persist_session_snapshot(
    session_state: Any,
    *,
    result: PipelineResult | None = None,
    config: PipelineConfig | None = None,
    workspace: str | Path | None = None,
) -> Path:
    """Write the latest recoverable app state to disk."""
    snapshot_path = _snapshot_path(workspace or getattr(config, "workspace", None))
    if not snapshot_persistence_enabled():
        logger.debug(
            "Skipping session snapshot persistence because %s is disabled",
            SNAPSHOT_ENV_VAR,
        )
        return snapshot_path
    snapshot_path.parent.mkdir(parents=True, exist_ok=True)

    session_payload: dict[str, Any] = {}
    for key in PERSISTED_SESSION_KEYS:
        if key not in session_state:
            continue
        value = session_state.get(key)
        if key == "ai_preflight_result":
            session_payload[key] = _ai_preflight_to_payload(value)
        else:
            session_payload[key] = value

    snapshot = {
        "session": session_payload,
        "pipeline_result": _result_to_payload(result if result is not None else session_state.get("pipeline_result")),
        "pipeline_config": _config_to_payload(config if config is not None else session_state.get("pipeline_config")),
    }

    with gzip.open(snapshot_path, "wb") as handle:
        pickle.dump(snapshot, handle, protocol=pickle.HIGHEST_PROTOCOL)

    logger.info("Persisted session snapshot to %s", snapshot_path)
    return snapshot_path


def restore_session_snapshot(session_state: Any, workspace: str | Path | None = None) -> bool:
    """Restore the latest recoverable app state into the current Streamlit session."""
    if not snapshot_persistence_enabled():
        return False
    snapshot_path = _snapshot_path(workspace)
    if not snapshot_path.exists():
        return False

    try:
        with gzip.open(snapshot_path, "rb") as handle:
            snapshot = pickle.load(handle)
    except Exception as exc:
        logger.warning("Could not restore persisted session snapshot from %s: %s", snapshot_path, exc)
        return False

    for key, value in snapshot.get("session", {}).items():
        if key == "ai_preflight_result":
            session_state[key] = _ai_preflight_from_payload(value)
        else:
            session_state[key] = value

    session_state["pipeline_result"] = _result_from_payload(snapshot.get("pipeline_result"))
    session_state["pipeline_config"] = _config_from_payload(snapshot.get("pipeline_config"))
    session_state["pipeline_running"] = False
    session_state["progress_queue"] = None
    session_state["pipeline_thread"] = None
    logger.info("Restored session snapshot from %s", snapshot_path)
    return True


def clear_session_snapshot(workspace: str | Path | None = None) -> None:
    """Remove the persisted session snapshot, if it exists."""
    snapshot_path = _snapshot_path(workspace)
    if snapshot_path.exists():
        snapshot_path.unlink()
