"""Structured event logging for client demo trials."""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

logger = logging.getLogger(__name__)

CLIENT_EVENT_LOG_ENV_VAR = "STOCKPILE_CLIENT_EVENT_LOG"
DEFAULT_CLIENT_EVENT_LOG_PATH = Path("data/client_test_events.jsonl")

CLIENT_SESSION_ID_KEY = "client_session_id"
CLIENT_UPLOAD_ID_KEY = "client_upload_id"
CLIENT_RUN_ID_KEY = "client_run_id"
CLIENT_RUN_ATTEMPT_KEY = "client_run_attempt"


def _event_log_path() -> Path:
    raw = os.environ.get(CLIENT_EVENT_LOG_ENV_VAR, "").strip()
    return Path(raw) if raw else DEFAULT_CLIENT_EVENT_LOG_PATH


def ensure_client_session_id(session_state: Any) -> str:
    """Ensure the current Streamlit session has a stable tracking id."""
    session_id = session_state.get(CLIENT_SESSION_ID_KEY)
    if not session_id:
        session_id = uuid4().hex
        session_state[CLIENT_SESSION_ID_KEY] = session_id
    return session_id


def start_new_upload_tracking(session_state: Any) -> str:
    """Create a new upload id and reset run tracking for the current session."""
    ensure_client_session_id(session_state)
    upload_id = uuid4().hex
    session_state[CLIENT_UPLOAD_ID_KEY] = upload_id
    session_state[CLIENT_RUN_ID_KEY] = None
    session_state[CLIENT_RUN_ATTEMPT_KEY] = 0
    return upload_id


def start_new_run_tracking(session_state: Any) -> str:
    """Create a new processing attempt id under the current upload."""
    ensure_client_session_id(session_state)
    if not session_state.get(CLIENT_UPLOAD_ID_KEY):
        start_new_upload_tracking(session_state)
    attempt = int(session_state.get(CLIENT_RUN_ATTEMPT_KEY, 0)) + 1
    run_id = uuid4().hex
    session_state[CLIENT_RUN_ATTEMPT_KEY] = attempt
    session_state[CLIENT_RUN_ID_KEY] = run_id
    return run_id


def _maybe_float(value: Any) -> float | None:
    if value in (None, ""):
        return None
    return float(value)


def _ai_preflight_snapshot(ai_preflight: Any) -> dict[str, Any] | None:
    if ai_preflight is None:
        return None
    return {
        "suggested_material": getattr(ai_preflight, "suggested_material", None),
        "material_confidence": _maybe_float(getattr(ai_preflight, "material_confidence", None)),
        "processing_profile": getattr(ai_preflight, "processing_profile", None),
        "profile_confidence": _maybe_float(getattr(ai_preflight, "profile_confidence", None)),
        "cone_visibility_score": _maybe_float(getattr(ai_preflight, "cone_visibility_score", None)),
        "retake_required": bool(getattr(ai_preflight, "retake_required", False)),
        "retake_reason": getattr(ai_preflight, "retake_reason", None),
        "provider": getattr(ai_preflight, "provider", None),
        "model": getattr(ai_preflight, "model", None),
    }


def _upload_snapshot(
    session_state: Any,
    uploaded_file: Any | None = None,
    video_info: dict[str, Any] | None = None,
    detections: list[Any] | None = None,
) -> dict[str, Any]:
    return {
        "file_name": getattr(uploaded_file, "name", None) or session_state.get("last_uploaded_name"),
        "file_size_bytes": getattr(uploaded_file, "size", None),
        "upload_signature": session_state.get("last_uploaded_signature"),
        "duration_sec": _maybe_float(video_info.get("duration")) if video_info else None,
        "fps": _maybe_float(video_info.get("fps")) if video_info else None,
        "width": int(video_info["width"]) if video_info and "width" in video_info else None,
        "height": int(video_info["height"]) if video_info and "height" in video_info else None,
        "first_frame_cones": len(detections or []),
        "ai_preflight": _ai_preflight_snapshot(session_state.get("ai_preflight_result")),
    }


def _config_snapshot(session_state: Any, config: Any | None = None) -> dict[str, Any] | None:
    if config is None:
        config = session_state.get("pipeline_config")
    if config is None:
        return None
    return {
        "material_name": getattr(config, "material_name", None),
        "material_density": _maybe_float(getattr(config, "material_density", None)),
        "selected_material": session_state.get("selected_material"),
        "selected_density": _maybe_float(session_state.get("selected_density")),
        "processing_profile": session_state.get("recommended_processing_profile"),
        "admin_mode": bool(session_state.get("sidebar_admin_mode", False)),
        "manual_scale_override": _maybe_float(session_state.get("manual_scale_override")),
        "frame_interval_sec": _maybe_float(getattr(getattr(config, "frame_extraction", None), "interval_sec", None)),
        "frame_max_frames": getattr(getattr(config, "frame_extraction", None), "max_frames", None),
        "colmap_quality": getattr(getattr(config, "colmap", None), "quality", None),
        "grid_resolution": _maybe_float(getattr(getattr(config, "volume", None), "grid_resolution", None)),
        "cone_height_m": _maybe_float(getattr(getattr(config, "scale_calibration", None), "known_cone_height_m", None)),
        "camera_height_m": _maybe_float(getattr(getattr(config, "scale_calibration", None), "assumed_camera_height_m", None)),
    }


def _status_from_result(result: Any) -> str:
    if result is None:
        return "error"
    if getattr(result, "error", None):
        return "error"
    if bool(getattr(result, "publishable", False)) and bool(getattr(result, "review_grade", False)):
        return "review_grade"
    if bool(getattr(result, "publishable", False)):
        return "verified"
    return "blocked"


def _result_snapshot(result: Any) -> dict[str, Any] | None:
    if result is None:
        return None
    calibration = getattr(result, "calibration", None)
    volume = getattr(result, "volume", None)
    pile_cloud = getattr(result, "pile_cloud", None)
    pile_points = len(pile_cloud.points) if pile_cloud is not None else 0
    return {
        "status": _status_from_result(result),
        "stage": getattr(result, "stage", None),
        "error": getattr(result, "error", None),
        "review_grade": bool(getattr(result, "review_grade", False)),
        "publishable": bool(getattr(result, "publishable", False)),
        "recommended_volume_m3": _maybe_float(getattr(volume, "recommended_m3", None)),
        "recommended_method": getattr(volume, "recommended_method", None) if volume is not None else None,
        "weight_kg": _maybe_float(getattr(result, "weight_kg", None)),
        "num_frames": getattr(result, "num_frames", None),
        "num_frames_with_cones": getattr(result, "num_frames_with_cones", None),
        "num_colmap_points": getattr(result, "num_colmap_points", None),
        "num_colmap_images": getattr(result, "num_colmap_images", None),
        "pile_points": pile_points,
        "scale_source": getattr(result, "scale_source", None),
        "scale_factor_m_per_unit": _maybe_float(getattr(result, "scale_factor_m_per_unit", None)),
        "calibration_confidence": _maybe_float(getattr(calibration, "confidence", None)) if calibration else None,
        "num_cones_used": getattr(calibration, "num_cones_used", None) if calibration else None,
        "detected_cone_frames": getattr(calibration, "detected_cone_frames", None) if calibration else None,
        "registered_cone_frames": getattr(calibration, "registered_cone_frames", None) if calibration else None,
        "max_detections_in_frame": getattr(calibration, "max_detections_in_frame", None) if calibration else None,
        "frames_with_multiple_detections": getattr(calibration, "frames_with_multiple_detections", None) if calibration else None,
        "scale_disagreement_ratio": _maybe_float(getattr(calibration, "scale_disagreement_ratio", None)) if calibration else None,
        "quality_blockers": list(getattr(result, "quality_blockers", []) or []),
        "quality_warnings": list(getattr(result, "quality_warnings", []) or []),
    }


def append_client_test_event(
    session_state: Any,
    event_type: str,
    *,
    config: Any | None = None,
    uploaded_file: Any | None = None,
    video_info: dict[str, Any] | None = None,
    detections: list[Any] | None = None,
    result: Any | None = None,
    extra: dict[str, Any] | None = None,
) -> Path:
    """Append a structured client-test event to the JSONL event log."""
    ensure_client_session_id(session_state)
    payload = {
        "event_at_utc": datetime.now(timezone.utc).isoformat(),
        "event_type": event_type,
        "session_id": session_state.get(CLIENT_SESSION_ID_KEY),
        "upload_id": session_state.get(CLIENT_UPLOAD_ID_KEY),
        "run_id": session_state.get(CLIENT_RUN_ID_KEY),
        "run_attempt": int(session_state.get(CLIENT_RUN_ATTEMPT_KEY, 0) or 0),
        "upload": _upload_snapshot(session_state, uploaded_file=uploaded_file, video_info=video_info, detections=detections),
        "config": _config_snapshot(session_state, config=config),
        "result": _result_snapshot(result),
    }
    if extra:
        payload["extra"] = extra

    log_path = _event_log_path()
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=True) + "\n")
    except Exception as exc:  # pragma: no cover - defensive production logging
        logger.warning("Could not append client test event to %s: %s", log_path, exc)
    return log_path
