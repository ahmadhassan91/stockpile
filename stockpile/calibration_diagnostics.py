"""Helpers for turning cone visibility into calibration readiness diagnostics."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping, Sequence

from .cone_detection import ConeDetection


@dataclass(frozen=True)
class ConeObservationStats:
    """Summary of raw cone visibility and what survived reconstruction."""

    detected_cone_frames: int = 0
    registered_cone_frames: int = 0
    total_cone_detections: int = 0
    max_detections_in_frame: int = 0
    frames_with_multiple_detections: int = 0

    @property
    def registration_coverage_pct(self) -> float | None:
        """Return the share of cone-bearing frames that registered in COLMAP."""
        if self.detected_cone_frames == 0:
            return None
        return (self.registered_cone_frames / self.detected_cone_frames) * 100.0


def summarize_cone_observations(
    cone_detections: Mapping[str, Sequence[ConeDetection]],
    registered_image_names: set[str] | None = None,
) -> ConeObservationStats:
    """Summarize cone visibility and reconstruction coverage for a run."""
    counts_by_frame = {
        frame_name: len(detections)
        for frame_name, detections in cone_detections.items()
        if detections
    }
    if not counts_by_frame:
        return ConeObservationStats()

    detected_frames = len(counts_by_frame)
    total_detections = sum(counts_by_frame.values())
    max_in_frame = max(counts_by_frame.values())
    multi_frames = sum(1 for count in counts_by_frame.values() if count >= 2)

    if registered_image_names is None:
        registered_frames = detected_frames
    else:
        registered_frames = sum(
            1 for frame_name in counts_by_frame
            if frame_name in registered_image_names
        )

    return ConeObservationStats(
        detected_cone_frames=detected_frames,
        registered_cone_frames=registered_frames,
        total_cone_detections=total_detections,
        max_detections_in_frame=max_in_frame,
        frames_with_multiple_detections=multi_frames,
    )


def build_capture_readiness_notes(
    stats: ConeObservationStats,
    unique_cones_used: int,
) -> list[str]:
    """Return notes that explain whether capture or registration limited scale."""
    if stats.detected_cone_frames == 0:
        return []

    notes: list[str] = []
    if stats.max_detections_in_frame <= 1:
        notes.append(
            "The analyzed frames never showed more than 1 cone at a time. Keep 2-3 cones visible together through most of the walkaround for verified client-facing scale."
        )
    elif unique_cones_used < 2:
        notes.append(
            "Multiple cones were visible in the raw video, but fewer than 2 unique 3D references survived calibration."
        )

    if stats.registered_cone_frames < stats.detected_cone_frames:
        notes.append(
            f"Only {stats.registered_cone_frames} of {stats.detected_cone_frames} cone-bearing frames registered into COLMAP."
        )
    return notes


def describe_reference_constraint(
    stats: ConeObservationStats,
    unique_cones_used: int,
) -> str:
    """Explain why a run is stuck below verified multi-cone calibration."""
    if stats.detected_cone_frames > 0 and stats.max_detections_in_frame <= 1:
        return (
            "The analyzed frames never showed more than 1 cone at a time, so verified multi-reference "
            "calibration was not possible. Keep 2-3 cones visible together through most of the walkaround."
        )

    if stats.frames_with_multiple_detections > 0 and unique_cones_used < 2:
        if stats.registered_cone_frames < stats.detected_cone_frames:
            return (
                f"Multiple cones were visible in the raw video, but only {stats.registered_cone_frames} "
                f"of {stats.detected_cone_frames} cone-bearing frames registered into COLMAP, so the "
                "extra references did not survive reconstruction."
            )
        return (
            "Multiple cones were visible in the raw video, but calibration still collapsed to fewer than 2 "
            "usable 3D references. Review cone placement and registration quality."
        )

    return f"Only {unique_cones_used} unique cone reference(s) were recovered; more physical references are needed."
