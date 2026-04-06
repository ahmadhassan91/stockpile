"""Shared processing presets for app and offline benchmarking."""

from __future__ import annotations

from typing import Any

from .config import PipelineConfig

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


def material_defaults(material: str) -> dict[str, Any]:
    """Return a copy of the default overrides for the selected material."""
    return dict(MATERIAL_PROCESSING_DEFAULTS.get(material, MATERIAL_PROCESSING_DEFAULTS["Custom"]))


def build_profile_overrides(material: str, profile_key: str) -> dict[str, Any]:
    """Return the merged sidebar-style overrides for a material/profile pair."""
    overrides = material_defaults(material)
    overrides.update(PROCESSING_PROFILE_OVERRIDES.get(profile_key, {}))
    return overrides


def apply_profile_overrides(config: PipelineConfig, material: str, profile_key: str) -> None:
    """Apply shared profile overrides directly to a PipelineConfig."""
    overrides = build_profile_overrides(material, profile_key)

    if "sidebar_frame_interval" in overrides:
        config.frame_extraction.interval_sec = float(overrides["sidebar_frame_interval"])
    if "sidebar_max_frames" in overrides:
        config.frame_extraction.max_frames = int(overrides["sidebar_max_frames"])
    if "sidebar_colmap_quality" in overrides:
        config.colmap.quality = str(overrides["sidebar_colmap_quality"])
    if "sidebar_above_ground" in overrides:
        config.ground_plane.above_ground_threshold = float(overrides["sidebar_above_ground"])
    if "sidebar_grid_resolution" in overrides:
        config.volume.grid_resolution = float(overrides["sidebar_grid_resolution"])
