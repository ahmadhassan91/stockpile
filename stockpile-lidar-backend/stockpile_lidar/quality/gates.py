"""LiDAR-relevant measurement-quality gates.

Ported from the legacy COLMAP backend's ``_assess_measurement_quality`` method.
Only the 9 gates that still apply to a LiDAR-native capture are kept; the
COLMAP-/cone-specific gates have been dropped.

The 9 gates:
    1. ``min_pile_points``
    2. ``pile_height``
    3. ``peak_relief``
    4. ``grid_occupancy_pct``
    5. ``grid_to_hull_ratio``
    6. ``tall_pile_with_grid_to_hull`` (combined)
    7. ``volume_recommended_note`` (informational warning passthrough)
    8. ``tracking_state_summary`` (LiDAR-specific)
    9. ``frame_pose_continuity`` (LiDAR-specific)
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable, Mapping

import numpy as np
import open3d as o3d

from ..config import QualityGateConfig
from ..manifest import CaptureManifest
from ..volume import VolumeResult


@dataclass
class QualityAssessment:
    publishable: bool
    review_grade: bool
    blockers: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def assess_quality(
    pile_cloud: o3d.geometry.PointCloud,
    volume: VolumeResult,
    manifest: CaptureManifest | Mapping[str, Any] | Any,
    config: QualityGateConfig | None = None,
) -> QualityAssessment:
    """Run all LiDAR-relevant quality gates against a measurement.

    The result-grading rule mirrors the legacy backend:

    * ``result.publishable = not blockers``
    * ``result.review_grade = bool(warnings) and not blockers``

    ``manifest`` may be a :class:`CaptureManifest`, a dict, or any duck-typed
    object exposing ``tracking_state_summary`` / ``poses`` fields.
    """
    gates = config or QualityGateConfig()

    blockers: list[str] = []
    warnings: list[str] = []
    small_pile_mode = _is_small_pile_mode(manifest)
    small_pile_manual_review = False

    def add_warning(message: str) -> None:
        if message not in warnings:
            warnings.append(message)

    def add_blocker(message: str) -> None:
        if message not in blockers:
            blockers.append(message)

    def add_small_pile_warning(message: str) -> None:
        nonlocal small_pile_manual_review
        small_pile_manual_review = True
        add_warning(message)

    # --- 1. Pile-point density --------------------------------------------------
    pile_pts = (
        np.asarray(pile_cloud.points)
        if pile_cloud is not None and len(pile_cloud.points) > 0
        else np.empty((0, 3))
    )
    pile_count = len(pile_pts)
    if pile_count < gates.min_pile_points_block:
        add_blocker(
            f"Only {pile_count:,} pile points were reconstructed; the pile surface "
            "is too sparse for a reliable measurement.",
        )
    elif pile_count < gates.min_pile_points_warn:
        add_warning(
            f"Only {pile_count:,} pile points were reconstructed; the estimate "
            "should be reviewed against a reference.",
        )

    # --- 2. Pile height ---------------------------------------------------------
    pile_height = float(np.max(pile_pts[:, 2])) if pile_count else 0.0
    pile_height_p99 = (
        float(np.percentile(pile_pts[:, 2], 99)) if pile_count >= 100 else pile_height
    )
    if pile_height > gates.tall_pile_warn_m:
        add_warning(
            f"Pile height reached {pile_height:.2f} m; verify that the "
            "reconstructed shape is consistent with site conditions.",
        )
    if pile_height > gates.tall_pile_block_m:
        add_blocker(
            f"Pile height reached {pile_height:.2f} m, which exceeds the "
            f"stability ceiling ({gates.tall_pile_block_m:.2f} m).",
        )

    # --- 3. Peak relief (spiky-reconstruction) ---------------------------------
    peak_relief_m = max(0.0, pile_height - pile_height_p99)
    peak_relief_ratio = (
        (pile_height / pile_height_p99) if pile_height_p99 > 1e-6 else None
    )
    if peak_relief_ratio is not None:
        if (
            peak_relief_m > gates.peak_relief_block_m
            and peak_relief_ratio > gates.peak_relief_block_ratio
        ):
            add_blocker(
                f"The highest part of the pile rises {peak_relief_m:.2f} m above "
                f"the 99th-percentile surface level ({peak_relief_ratio:.2f}x), "
                "which suggests a spiky reconstruction artifact.",
            )
        elif (
            peak_relief_m > gates.peak_relief_warn_m
            and peak_relief_ratio > gates.peak_relief_warn_ratio
        ):
            add_warning(
                f"The top surface shows a pronounced spike: {peak_relief_m:.2f} m "
                f"above the 99th-percentile height ({peak_relief_ratio:.2f}x).",
            )

    # --- 4 / 5 / 6 / 7. Volume gates -------------------------------------------
    if volume is not None:
        # 4. Grid occupancy
        if volume.grid_occupancy_pct < gates.min_grid_occupancy_block_pct:
            add_blocker(
                f"Only {volume.grid_occupancy_pct:.1f}% of grid cells had observed "
                "pile data; the volume is dominated by interpolation.",
            )
        elif volume.grid_occupancy_pct < gates.min_grid_occupancy_warn_pct:
            add_warning(
                f"Only {volume.grid_occupancy_pct:.1f}% of grid cells had observed "
                "pile data; the volume should be cross-checked.",
            )

        # 5. Grid-to-hull ratio (and 6. combined tall-pile + ratio block)
        if volume.grid_to_hull_ratio is not None:
            if volume.grid_to_hull_ratio < gates.min_grid_to_hull_block_ratio:
                message = (
                    f"Grid volume is only {volume.grid_to_hull_ratio:.2f}x the "
                    "convex hull volume, which indicates the fused surface, "
                    "ground plane, or toe boundary is inconsistent."
                )
                if small_pile_mode:
                    add_small_pile_warning(message)
                else:
                    add_blocker(message)
            elif volume.grid_to_hull_ratio < gates.min_grid_to_hull_warn_ratio:
                add_warning(
                    f"Grid volume is only {volume.grid_to_hull_ratio:.2f}x the "
                    "convex hull volume; cross-check the reconstructed shape "
                    "before reporting.",
                )
            elif volume.grid_to_hull_ratio > gates.max_grid_to_hull_block_ratio:
                add_blocker(
                    f"Grid volume is {volume.grid_to_hull_ratio:.1f}x the convex "
                    "hull volume, which indicates runaway extrapolation.",
                )
            elif volume.grid_to_hull_ratio > gates.max_grid_to_hull_warn_ratio:
                add_warning(
                    f"Grid volume is {volume.grid_to_hull_ratio:.1f}x the convex "
                    "hull volume; edge interpolation may be inflating the estimate.",
                )
                # 6. Combined tall-pile + grid/hull inflation
                if (
                    pile_height > gates.tall_pile_warn_m
                    and volume.grid_to_hull_ratio
                    >= gates.tall_pile_grid_to_hull_block_ratio
                ):
                    add_blocker(
                        "The reconstruction shows a tall pile together with strong "
                        "grid/hull inflation, which is a high-risk instability "
                        "pattern.",
                    )

        # 7. Volume recommended-note passthrough (e.g. fallback to convex hull)
        if volume.recommended_note:
            add_warning(volume.recommended_note)

        quick_volume = _quick_estimate_volume_m3(
            _lookup(manifest, "on_device_quick_estimate", "quick_estimate"),
        )
        quick_payload = _lookup(manifest, "on_device_quick_estimate", "quick_estimate")
        if _is_small_pile_mode(manifest):
            if volume.recommended_m3 > gates.small_pile_volume_block_m3:
                add_small_pile_warning(
                    f"Small pile mode expected a compact sample pile, but backend "
                    f"volume is {volume.recommended_m3:.2f} m3. Retake with only "
                    "the pile inside the scan area.",
                )
            elif volume.recommended_m3 > gates.small_pile_volume_warn_m3:
                add_small_pile_warning(
                    f"Small pile mode backend volume is {volume.recommended_m3:.2f} "
                    "m3; confirm this is not ground or background included in the "
                    "pile.",
                )

            if volume.footprint_area_m2 > gates.small_pile_footprint_block_m2:
                add_small_pile_warning(
                    f"Small pile mode measured a {volume.footprint_area_m2:.2f} m2 "
                    "footprint, which is too large for an office/sample pile. "
                    "Retake closer and keep surrounding ground out of the pile area.",
                )
            elif volume.footprint_area_m2 > gates.small_pile_footprint_warn_m2:
                add_small_pile_warning(
                    f"Small pile mode measured a {volume.footprint_area_m2:.2f} m2 "
                    "footprint; confirm the toe boundary is tight.",
                )

            small_height = max(pile_height_p99, _quick_estimate_peak_height_m(quick_payload) or 0.0)
            if small_height > gates.small_pile_height_block_m:
                add_small_pile_warning(
                    f"Small pile mode saw {small_height:.2f} m height, which is too "
                    "tall for a compact test pile. Step back, retake, and avoid "
                    "walls, edges, or background surfaces in the pile region.",
                )
            elif small_height > gates.small_pile_height_warn_m:
                add_small_pile_warning(
                    f"Small pile mode saw {small_height:.2f} m height; inspect for "
                    "a LiDAR spike before reporting.",
                )

            if quick_volume is not None:
                if quick_volume > gates.small_pile_quick_estimate_volume_block_m3:
                    add_small_pile_warning(
                        f"Small pile mode phone LiDAR estimate is {quick_volume:.2f} "
                        "m3, which is too large for a compact test pile. Retake "
                        "with a tighter scan of the pile only.",
                    )
                elif quick_volume > gates.small_pile_quick_estimate_volume_warn_m3:
                    add_small_pile_warning(
                        f"Small pile mode phone LiDAR estimate is {quick_volume:.2f} "
                        "m3; confirm the scan did not include surrounding ground.",
                    )

        if quick_volume is not None and volume.recommended_m3 > 1e-6:
            disagreement = max(
                quick_volume / volume.recommended_m3,
                volume.recommended_m3 / quick_volume,
            )
            block_ratio = (
                gates.small_pile_quick_estimate_volume_block_ratio
                if _is_small_pile_mode(manifest)
                else gates.quick_estimate_volume_block_ratio
            )
            warn_ratio = (
                gates.small_pile_quick_estimate_volume_warn_ratio
                if _is_small_pile_mode(manifest)
                else gates.quick_estimate_volume_warn_ratio
            )
            if disagreement > block_ratio:
                message = (
                    f"Backend volume ({volume.recommended_m3:.2f} m3) disagrees "
                    f"with the phone LiDAR estimate ({quick_volume:.2f} m3) by "
                    f"{disagreement:.1f}x; retake or review with a reference."
                )
                if small_pile_mode:
                    add_small_pile_warning(message)
                else:
                    add_blocker(message)
            elif disagreement > warn_ratio:
                message = (
                    f"Backend volume ({volume.recommended_m3:.2f} m3) differs "
                    f"from the phone LiDAR estimate ({quick_volume:.2f} m3) by "
                    f"{disagreement:.1f}x; review before reporting."
                )
                if small_pile_mode:
                    add_small_pile_warning(message)
                else:
                    add_warning(message)

    # --- 8. Tracking-state summary (LiDAR-specific) ----------------------------
    tracking_summary = _coerce_tracking_state_fractions(
        _lookup(manifest, "tracking_state_summary"),
    )
    if tracking_summary is not None:
        if sum(tracking_summary.values()) <= 1e-9:
            add_blocker(
                "ARKit tracking summary contains no usable tracked frames; the "
                "capture metadata is incomplete.",
            )
        not_available_fraction = tracking_summary.get("notavailable", 0.0)
        limited_fraction = tracking_summary.get("limited", 0.0)
        if not_available_fraction > gates.max_tracking_not_available_block_fraction:
            add_blocker(
                f"ARKit tracking was unavailable for {not_available_fraction:.0%} "
                "of frames; the pose timeline is unreliable.",
            )
        if limited_fraction > gates.max_tracking_limited_warn_fraction:
            add_warning(
                f"ARKit tracking was in a limited state for {limited_fraction:.0%} "
                "of frames; the reconstruction should be cross-checked.",
            )

    # --- 9. Frame-pose continuity (LiDAR-specific) -----------------------------
    pose_payload = _lookup(manifest, "poses", "pose_timeline", "pose_continuity")
    consecutive_missing = _max_consecutive_missing_poses(pose_payload)
    if consecutive_missing > gates.max_consecutive_missing_pose_frames_block:
        add_blocker(
            f"The pose timeline has {consecutive_missing} consecutive missing "
            f"frames (limit {gates.max_consecutive_missing_pose_frames_block}); "
            "the capture has a tracking gap that prevents reliable fusion.",
        )

    if small_pile_manual_review:
        note = (
            "Manual review required: backend LiDAR volume is shown for comparison, "
            "but this small-pile run should be checked against a known reference "
            "before reporting."
        )
        if note not in warnings:
            warnings.insert(0, note)

    publishable = not blockers
    review_grade = bool(warnings) and publishable

    return QualityAssessment(
        publishable=publishable,
        review_grade=review_grade,
        blockers=blockers,
        warnings=warnings,
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _lookup(source: Any, *keys: str) -> Any:
    """Look up the first present field on a CaptureManifest / dict / object."""
    for key in keys:
        if source is None:
            return None
        if isinstance(source, Mapping):
            if key in source:
                value = source[key]
                if value is not None:
                    return value
            continue
        if hasattr(source, key):
            value = getattr(source, key)
            if value is not None:
                return value
    return None


def _coerce_tracking_state_fractions(payload: Any) -> dict[str, float] | None:
    """Normalise a tracking-state-summary payload into ``{state: fraction}``.

    Accepts:
    * ``None`` → returns ``None``
    * a string state ("normal", "limited", "notavailable") → ``{state: 1.0}``
    * a mapping of state→fraction (already counts, fractions, or percentages)
    * an iterable of per-frame states → counted into fractions
    """
    if payload is None:
        return None
    if isinstance(payload, str):
        state = _normalize_tracking_state(payload)
        if state is None:
            return None
        return {state: 1.0}
    if isinstance(payload, Mapping):
        # Mapping of state → fraction OR state → count.
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
        # Looks like already-normalised fractions if total ≈ 1.0; keep as-is.
        # Otherwise treat as counts and normalise. Percentages (total > ~1.5)
        # are also normalised — divide by total.
        if total > 1.0 + 1e-6:
            items = {k: v / total for k, v in items.items()}
        return items
    if isinstance(payload, Iterable):
        counts: dict[str, int] = {}
        total = 0
        for entry in payload:
            state: str | None
            if isinstance(entry, str):
                state = _normalize_tracking_state(entry)
            elif isinstance(entry, Mapping):
                raw_state = entry.get("state") or entry.get("tracking_state")
                state = (
                    _normalize_tracking_state(str(raw_state))
                    if raw_state is not None
                    else None
                )
            else:
                state = None
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
    if not raw:
        return None
    if raw in {"normal", "ok", "tracking"}:
        return "normal"
    if raw == "limited":
        return "limited"
    if raw in {"notavailable", "unavailable", "lost"}:
        return "notavailable"
    return None


def _quick_estimate_volume_m3(payload: Any) -> float | None:
    if payload is None:
        return None
    value: Any
    if isinstance(payload, Mapping):
        value = (
            payload.get("volume_m3")
            or payload.get("volumeM3")
            or payload.get("recommended_m3")
        )
    else:
        value = getattr(payload, "volume_m3", None)
        if value is None:
            value = getattr(payload, "volumeM3", None)
    try:
        volume = float(value)
    except (TypeError, ValueError):
        return None
    if volume <= 1e-6:
        return None
    return volume


def _quick_estimate_peak_height_m(payload: Any) -> float | None:
    if payload is None:
        return None
    if isinstance(payload, Mapping):
        value = payload.get("peak_height_m") or payload.get("peakHeightM")
    else:
        value = getattr(payload, "peak_height_m", None)
        if value is None:
            value = getattr(payload, "peakHeightM", None)
    try:
        height = float(value)
    except (TypeError, ValueError):
        return None
    if height <= 1e-6:
        return None
    return height


def _is_small_pile_mode(manifest: Any) -> bool:
    raw = _lookup(
        manifest,
        "pile_size_mode",
        "pileSizeMode",
        "capture_profile",
        "captureProfile",
        "measurement_mode",
        "measurementMode",
    )
    if raw is None:
        return False
    normalized = str(raw).strip().lower().replace("-", "_").replace(" ", "_")
    return normalized in {"small", "small_pile", "office", "sample", "sample_pile"}


def _max_consecutive_missing_poses(payload: Any) -> int:
    """Compute the largest run of consecutive missing pose frames.

    The payload may be:
    * ``None`` → 0
    * an integer (already-precomputed max gap)
    * a mapping with a ``max_consecutive_missing`` key
    * an iterable of poses, where a pose is "missing" if it is ``None``,
      an empty mapping, or has a falsy ``valid`` / ``has_pose`` flag
    """
    if payload is None:
        return 0
    if isinstance(payload, bool):
        return 0
    if isinstance(payload, int):
        return max(0, payload)
    if isinstance(payload, Mapping):
        for key in (
            "max_consecutive_missing",
            "max_consecutive_missing_frames",
            "longest_gap",
        ):
            if key in payload:
                try:
                    return max(0, int(payload[key]))
                except (TypeError, ValueError):
                    return 0
        if "frames" in payload and isinstance(payload["frames"], Iterable):
            return _max_consecutive_missing_poses(payload["frames"])
        return 0
    if isinstance(payload, Iterable):
        longest = 0
        current = 0
        for entry in payload:
            if _is_missing_pose(entry):
                current += 1
                if current > longest:
                    longest = current
            else:
                current = 0
        return longest
    return 0


def _is_missing_pose(entry: Any) -> bool:
    if entry is None:
        return True
    if isinstance(entry, Mapping):
        if not entry:
            return True
        for flag_key in ("valid", "has_pose", "is_valid"):
            if flag_key in entry:
                return not bool(entry[flag_key])
        for missing_key in ("missing", "is_missing", "dropped"):
            if missing_key in entry and bool(entry[missing_key]):
                return True
        return False
    return False
