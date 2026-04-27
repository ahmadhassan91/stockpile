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

    def add_warning(message: str) -> None:
        if message not in warnings:
            warnings.append(message)

    def add_blocker(message: str) -> None:
        if message not in blockers:
            blockers.append(message)

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
            if volume.grid_to_hull_ratio > gates.max_grid_to_hull_block_ratio:
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

    # --- 8. Tracking-state summary (LiDAR-specific) ----------------------------
    tracking_summary = _coerce_tracking_state_fractions(
        _lookup(manifest, "tracking_state_summary"),
    )
    if tracking_summary is not None:
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
