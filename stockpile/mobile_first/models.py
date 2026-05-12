"""Core models for the mobile-first stockpile measurement path."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


def _clamp_ratio(value: float) -> float:
    return max(0.0, min(1.0, float(value)))


class ReferenceObservationState(str, Enum):
    CONFIRMED = "confirmed"
    WEAK = "weak"
    MISSING = "missing"


class CaptureQualityState(str, Enum):
    READY = "ready"
    REVIEW = "review"
    RETAKE = "retake"


class VerificationOutcome(str, Enum):
    VERIFIED = "verified"
    REVIEW_ONLY = "review_only"
    RECAPTURE_REQUIRED = "recapture_required"


@dataclass(frozen=True)
class ReferenceObservation:
    marker_id: str
    frame_id: str
    pixel_area: float
    confidence: float
    estimated_distance_m: float | None = None
    state: ReferenceObservationState = ReferenceObservationState.CONFIRMED

    def __post_init__(self):
        object.__setattr__(self, "confidence", _clamp_ratio(self.confidence))


@dataclass(frozen=True)
class DevicePoseSample:
    timestamp_seconds: float
    position_xyz_m: tuple[float, float, float]
    yaw_pitch_roll_deg: tuple[float, float, float]
    horizontal_accuracy_m: float | None = None
    vertical_accuracy_m: float | None = None


@dataclass(frozen=True)
class MobileFirstCaptureEnvelope:
    session_id: str
    site_id: str
    pile_name: str
    material_code: str
    density_kg_per_m3: int
    reference_count_goal: int
    reference_observations: tuple[ReferenceObservation, ...] = ()
    device_pose_samples: tuple[DevicePoseSample, ...] = ()
    toe_coverage_score: float = 0.0
    motion_stability_score: float = 0.0
    perimeter_coverage_score: float = 0.0
    lidar_assist_enabled: bool = False

    def __post_init__(self):
        object.__setattr__(self, "toe_coverage_score", _clamp_ratio(self.toe_coverage_score))
        object.__setattr__(self, "motion_stability_score", _clamp_ratio(self.motion_stability_score))
        object.__setattr__(self, "perimeter_coverage_score", _clamp_ratio(self.perimeter_coverage_score))


@dataclass(frozen=True)
class ProvisionalMeasurementInput:
    capture: MobileFirstCaptureEnvelope
    quick_volume_m3: float | None = None
    tagged_reference_recovery_ratio: float = 0.0
    scale_agreement_ratio: float | None = None
    toe_confidence_score: float = 0.0
    geometry_confidence_score: float = 0.0

    def __post_init__(self):
        object.__setattr__(
            self,
            "tagged_reference_recovery_ratio",
            _clamp_ratio(self.tagged_reference_recovery_ratio),
        )
        object.__setattr__(self, "toe_confidence_score", _clamp_ratio(self.toe_confidence_score))
        object.__setattr__(self, "geometry_confidence_score", _clamp_ratio(self.geometry_confidence_score))


@dataclass(frozen=True)
class ProvisionalMeasurementOutput:
    state: CaptureQualityState
    provisional_volume_m3: float | None
    confidence_score: float
    reasons: tuple[str, ...] = ()
    operator_action: str = ""

    def __post_init__(self):
        object.__setattr__(self, "confidence_score", _clamp_ratio(self.confidence_score))


@dataclass(frozen=True)
class ReviewPacket:
    provisional: ProvisionalMeasurementOutput
    benchmark_delta_ratio: float | None = None
    tagged_reference_count: int = 0
    minimum_expected_reference_count: int = 2
    scale_agreement_ratio: float | None = None
    verifier_notes: tuple[str, ...] = field(default_factory=tuple)


@dataclass(frozen=True)
class ReviewDecision:
    outcome: VerificationOutcome
    summary: str
    reasons: tuple[str, ...] = ()

