"""Smart preset selection for client-facing upload flows."""

from __future__ import annotations

from typing import Any


PROCESSING_PROFILE_LABELS = {
    "fast_review": "Fast Review",
    "standard": "Standard",
    "high_accuracy": "High Accuracy",
    "cone_recovery": "Cone Recovery",
}


MATERIAL_PROCESSING_DEFAULTS = {
    "Backfill 0–75 mm": {
        "sidebar_above_ground": 0.10,
        "sidebar_grid_resolution": 0.05,
    },
    "Aggregates 5–14 mm": {
        "sidebar_above_ground": 0.08,
        "sidebar_grid_resolution": 0.04,
    },
    "Aggregates 10–20 mm": {
        "sidebar_above_ground": 0.09,
        "sidebar_grid_resolution": 0.04,
    },
    "Custom": {
        "sidebar_above_ground": 0.10,
        "sidebar_grid_resolution": 0.05,
    },
}


PROCESSING_PROFILE_OVERRIDES = {
    "fast_review": {
        "sidebar_frame_interval": 0.30,
        "sidebar_max_frames": 700,
        "sidebar_colmap_quality": "medium",
    },
    "standard": {
        "sidebar_frame_interval": 0.25,
        "sidebar_max_frames": 800,
        "sidebar_colmap_quality": "medium",
    },
    "high_accuracy": {
        "sidebar_frame_interval": 0.20,
        "sidebar_max_frames": 1000,
        "sidebar_colmap_quality": "high",
    },
    "cone_recovery": {
        "sidebar_frame_interval": 0.15,
        "sidebar_max_frames": 1000,
        "sidebar_colmap_quality": "high",
    },
}


def _material_defaults(material: str) -> dict[str, Any]:
    return dict(MATERIAL_PROCESSING_DEFAULTS.get(material, MATERIAL_PROCESSING_DEFAULTS["Custom"]))


def choose_processing_profile(
    material: str,
    video_info: dict[str, Any] | None,
    detections: list | None,
) -> tuple[str, list[str]]:
    """Choose a safe processing profile from upload metadata."""
    reasons: list[str] = []
    cone_count = len(detections or [])

    if video_info is None:
        reasons.append("Using the standard profile until the upload metadata is available.")
        return "standard", reasons

    duration = float(video_info.get("duration", 0.0))
    width = int(video_info.get("width", 0))
    height = int(video_info.get("height", 0))
    shortest_edge = min(width, height) if width and height else 0
    high_resolution = width >= 1920 or shortest_edge >= 1080
    long_clip = duration >= 120
    short_clip = duration <= 45

    if cone_count <= 1:
        reasons.append("Only one cone is visible in the first frame, so the preset biases toward stronger cone recovery.")
        if long_clip:
            reasons.append("The clip is long, so we still keep the frame budget practical.")
            return "standard", reasons
        return "cone_recovery", reasons

    if high_resolution and short_clip:
        reasons.append("This is a short, high-resolution clip, so a denser reconstruction is worth the extra compute.")
        return "high_accuracy", reasons

    if long_clip:
        reasons.append("This is a longer clip, so the preset balances coverage and processing time.")
        return "fast_review", reasons

    if material.startswith("Aggregates"):
        reasons.append("Aggregate stockpiles benefit from slightly finer default surface settings.")
    else:
        reasons.append("Backfill profiles use the standard coverage and surface thresholds.")
    return "standard", reasons


def build_recommended_sidebar_overrides(
    material: str,
    video_info: dict[str, Any] | None,
    detections: list | None,
    ai_profile_key: str | None = None,
    ai_notes: list[str] | None = None,
) -> tuple[dict[str, Any], str, list[str]]:
    """Return sidebar-compatible overrides plus a user-facing profile label."""
    if ai_profile_key in PROCESSING_PROFILE_OVERRIDES:
        profile_key = ai_profile_key
        reasons = list(ai_notes or [])
        if not reasons:
            reasons = ["AI preflight recommended this profile from the sampled upload frames."]
    else:
        profile_key, reasons = choose_processing_profile(material, video_info, detections)
    overrides = _material_defaults(material)
    overrides.update(PROCESSING_PROFILE_OVERRIDES[profile_key])
    return overrides, PROCESSING_PROFILE_LABELS[profile_key], reasons
