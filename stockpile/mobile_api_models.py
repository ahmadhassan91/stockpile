"""Durable mobile API request/response models for the iOS alpha flow."""

from __future__ import annotations

from collections.abc import Mapping as MappingABC
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Mapping


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def isoformat_utc(value: datetime | None) -> str | None:
    if value is None:
        return None
    normalized = value.astimezone(timezone.utc).replace(microsecond=0)
    return normalized.isoformat().replace("+00:00", "Z")


def parse_datetime(raw: str | None) -> datetime | None:
    if not raw:
        return None
    normalized = raw.replace("Z", "+00:00")
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _payload_value(payload: Mapping[str, Any], *keys: str, default: Any = None) -> Any:
    for key in keys:
        value = payload.get(key)
        if value is not None:
            return value
    return default


def _as_str(
    payload: Mapping[str, Any],
    key: str,
    *aliases: str,
    default: str | None = None,
) -> str | None:
    value = _payload_value(payload, key, *aliases, default=default)
    if value is None:
        return None
    return str(value)


def _clamp_ratio(value: float | None) -> float | None:
    if value is None:
        return None
    return max(0.0, min(1.0, float(value)))


def _require_non_empty(name: str, value: str):
    if not value or not value.strip():
        raise ValueError(f"{name} must be non-empty")


def _non_negative_int(name: str, value: int):
    if int(value) < 0:
        raise ValueError(f"{name} must be non-negative")


class RunOutcome(str, Enum):
    VERIFIED = "verified"
    REVIEW_ONLY = "review_only"
    BLOCKED = "blocked"


class JobPhase(str, Enum):
    QUEUED = "queued"
    UPLOAD_AUTHORIZED = "upload_authorized"
    UPLOAD_RECEIVED = "upload_received"
    EXTRACTING_FRAMES = "extracting_frames"
    DETECTING_REFERENCES = "detecting_references"
    RECONSTRUCTING = "reconstructing"
    CALIBRATING = "calibrating"
    COMPUTING_VOLUME = "computing_volume"
    VERIFIED = "verified"
    REVIEW_ONLY = "review_only"
    BLOCKED = "blocked"
    FAILED = "failed"

    @property
    def is_terminal(self) -> bool:
        return self in {
            JobPhase.VERIFIED,
            JobPhase.REVIEW_ONLY,
            JobPhase.BLOCKED,
            JobPhase.FAILED,
        }


class UploadState(str, Enum):
    AUTHORIZED = "authorized"
    RECEIVING = "receiving"
    COMPLETE = "complete"
    FAILED = "failed"


class QualityGateState(str, Enum):
    PASS = "pass"
    WATCH = "watch"
    BLOCK = "block"


class TaggedReferenceStrategyMode(str, Enum):
    CONCURRENT_VISIBILITY = "concurrent_visibility"


class CaptureSource(str, Enum):
    LIVE_RECORDED_VIDEO = "live_recorded_video"
    IMPORTED_VIDEO = "imported_video"
    FALLBACK_VIDEO = "fallback_video"


class CaptureMode(str, Enum):
    GUIDED_WALKAROUND = "guided_walkaround"


class ReferenceMarkerQuality(str, Enum):
    CONFIRMED = "confirmed"
    WEAK = "weak"
    MISSING = "missing"


class MobileFirstCaptureStage(str, Enum):
    READY = "ready"
    ACQUIRING_REFERENCES = "acquiring_references"
    WALKING_PERIMETER = "walking_perimeter"
    SEALING_CAPTURE = "sealing_capture"
    UPLOADING = "uploading"
    PROVISIONAL_RESULT = "provisional_result"
    REVIEW_QUEUE = "review_queue"
    RECAPTURE_REQUIRED = "recapture_required"


@dataclass(frozen=True)
class Vector3Payload:
    x: float
    y: float
    z: float

    def to_dict(self) -> dict[str, Any]:
        return {
            "x": self.x,
            "y": self.y,
            "z": self.z,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any] | tuple[float, float, float] | list[float]) -> "Vector3Payload":
        if isinstance(payload, MappingABC):
            return cls(
                x=float(payload["x"]),
                y=float(payload["y"]),
                z=float(payload["z"]),
            )
        if isinstance(payload, (list, tuple)) and len(payload) == 3:
            return cls(
                x=float(payload[0]),
                y=float(payload[1]),
                z=float(payload[2]),
            )
        raise TypeError("Vector3Payload requires an {x,y,z} mapping or a 3-value sequence")


@dataclass(frozen=True)
class QuaternionPayload:
    x: float
    y: float
    z: float
    w: float

    def to_dict(self) -> dict[str, Any]:
        return {
            "x": self.x,
            "y": self.y,
            "z": self.z,
            "w": self.w,
        }

    @classmethod
    def from_dict(
        cls,
        payload: Mapping[str, Any] | tuple[float, float, float, float] | list[float],
    ) -> "QuaternionPayload":
        if isinstance(payload, MappingABC):
            return cls(
                x=float(payload["x"]),
                y=float(payload["y"]),
                z=float(payload["z"]),
                w=float(payload["w"]),
            )
        if isinstance(payload, (list, tuple)) and len(payload) == 4:
            return cls(
                x=float(payload[0]),
                y=float(payload[1]),
                z=float(payload[2]),
                w=float(payload[3]),
            )
        raise TypeError("QuaternionPayload requires an {x,y,z,w} mapping or a 4-value sequence")


@dataclass(frozen=True)
class TaggedReferenceStrategyPayload:
    mode: TaggedReferenceStrategyMode
    reference_count_goal: int
    minimum_visible_reference_count: int
    preferred_visible_reference_count: int

    def __post_init__(self):
        _non_negative_int("reference_count_goal", self.reference_count_goal)
        _non_negative_int("minimum_visible_reference_count", self.minimum_visible_reference_count)
        _non_negative_int("preferred_visible_reference_count", self.preferred_visible_reference_count)
        if self.minimum_visible_reference_count > self.reference_count_goal:
            raise ValueError("minimum_visible_reference_count cannot exceed reference_count_goal")
        if self.preferred_visible_reference_count < self.minimum_visible_reference_count:
            raise ValueError(
                "preferred_visible_reference_count cannot be below minimum_visible_reference_count",
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "mode": self.mode.value,
            "referenceCountGoal": self.reference_count_goal,
            "minimumVisibleReferenceCount": self.minimum_visible_reference_count,
            "preferredVisibleReferenceCount": self.preferred_visible_reference_count,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "TaggedReferenceStrategyPayload":
        return cls(
            mode=TaggedReferenceStrategyMode(str(payload["mode"])),
            reference_count_goal=int(payload["referenceCountGoal"]),
            minimum_visible_reference_count=int(payload["minimumVisibleReferenceCount"]),
            preferred_visible_reference_count=int(payload["preferredVisibleReferenceCount"]),
        )


@dataclass(frozen=True)
class CaptureMetadataPayload:
    source: CaptureSource
    mode: CaptureMode
    started_at: datetime | None = None
    completed_at: datetime | None = None
    time_zone_identifier: str = "UTC"
    active_device_name: str | None = None
    capture_phase: str | None = None
    session_lifecycle: str | None = None
    recording_lifecycle: str | None = None
    sensor_metadata: "CaptureSensorMetadataPayload | None" = None

    def __post_init__(self):
        _require_non_empty("time_zone_identifier", self.time_zone_identifier)

    def to_dict(self) -> dict[str, Any]:
        return {
            "source": self.source.value,
            "mode": self.mode.value,
            "startedAt": isoformat_utc(self.started_at),
            "completedAt": isoformat_utc(self.completed_at),
            "timeZoneIdentifier": self.time_zone_identifier,
            "activeDeviceName": self.active_device_name,
            "capturePhase": self.capture_phase,
            "sessionLifecycle": self.session_lifecycle,
            "recordingLifecycle": self.recording_lifecycle,
            "sensorMetadata": None if self.sensor_metadata is None else self.sensor_metadata.to_dict(),
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "CaptureMetadataPayload":
        return cls(
            source=CaptureSource(str(payload["source"])),
            mode=CaptureMode(str(payload["mode"])),
            started_at=parse_datetime(_as_str(payload, "startedAt")),
            completed_at=parse_datetime(_as_str(payload, "completedAt")),
            time_zone_identifier=str(payload["timeZoneIdentifier"]),
            active_device_name=_as_str(payload, "activeDeviceName"),
            capture_phase=_as_str(payload, "capturePhase"),
            session_lifecycle=_as_str(payload, "sessionLifecycle"),
            recording_lifecycle=_as_str(payload, "recordingLifecycle"),
            sensor_metadata=(
                CaptureSensorMetadataPayload.from_dict(payload["sensorMetadata"])
                if payload.get("sensorMetadata")
                else None
            ),
        )


@dataclass(frozen=True)
class DeviceSensorInputPayload:
    motion_signals_included: bool
    gravity_vector_included: bool
    heading_signals_included: bool
    camera_calibration_included: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "motionSignalsIncluded": self.motion_signals_included,
            "gravityVectorIncluded": self.gravity_vector_included,
            "headingSignalsIncluded": self.heading_signals_included,
            "cameraCalibrationIncluded": self.camera_calibration_included,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "DeviceSensorInputPayload":
        if not payload:
            return cls.reserved()
        return cls(
            motion_signals_included=bool(payload["motionSignalsIncluded"]),
            gravity_vector_included=bool(payload["gravityVectorIncluded"]),
            heading_signals_included=bool(payload["headingSignalsIncluded"]),
            camera_calibration_included=bool(payload["cameraCalibrationIncluded"]),
        )

    @classmethod
    def reserved(cls) -> "DeviceSensorInputPayload":
        return cls(
            motion_signals_included=False,
            gravity_vector_included=False,
            heading_signals_included=False,
            camera_calibration_included=False,
        )


@dataclass(frozen=True)
class CaptureSensorMetadataPayload:
    device_model_identifier: str | None = None
    video_width: int | None = None
    video_height: int | None = None
    video_frame_rate: float | None = None
    pose_sampling_hz: float | None = None
    depth_data_included: bool | None = None
    world_alignment: str | None = None
    video_stabilization_mode: str | None = None

    def __post_init__(self):
        if self.video_width is not None:
            _non_negative_int("video_width", self.video_width)
        if self.video_height is not None:
            _non_negative_int("video_height", self.video_height)

    def to_dict(self) -> dict[str, Any]:
        return {
            "deviceModelIdentifier": self.device_model_identifier,
            "videoWidth": self.video_width,
            "videoHeight": self.video_height,
            "videoFrameRate": self.video_frame_rate,
            "poseSamplingHz": self.pose_sampling_hz,
            "depthDataIncluded": self.depth_data_included,
            "worldAlignment": self.world_alignment,
            "videoStabilizationMode": self.video_stabilization_mode,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "CaptureSensorMetadataPayload":
        return cls(
            device_model_identifier=_as_str(payload, "deviceModelIdentifier"),
            video_width=int(payload["videoWidth"]) if payload.get("videoWidth") is not None else None,
            video_height=int(payload["videoHeight"]) if payload.get("videoHeight") is not None else None,
            video_frame_rate=(
                float(payload["videoFrameRate"])
                if payload.get("videoFrameRate") is not None
                else None
            ),
            pose_sampling_hz=(
                float(payload["poseSamplingHz"])
                if payload.get("poseSamplingHz") is not None
                else None
            ),
            depth_data_included=(
                bool(payload["depthDataIncluded"])
                if payload.get("depthDataIncluded") is not None
                else None
            ),
            world_alignment=_as_str(payload, "worldAlignment"),
            video_stabilization_mode=_as_str(payload, "videoStabilizationMode"),
        )


@dataclass(frozen=True)
class DevicePoseSamplePayload:
    sample_index: int
    time_offset_sec: float
    captured_at: datetime | None = None
    position_m: Vector3Payload | None = None
    orientation_quaternion: QuaternionPayload | None = None
    gravity_vector: Vector3Payload | None = None
    heading_degrees: float | None = None
    tracking_state: str | None = None
    yaw_pitch_roll_deg: Vector3Payload | None = None
    horizontal_accuracy_m: float | None = None
    vertical_accuracy_m: float | None = None

    def __post_init__(self):
        _non_negative_int("sample_index", self.sample_index)

    def to_dict(self) -> dict[str, Any]:
        return {
            "sampleIndex": self.sample_index,
            "timeOffsetSec": self.time_offset_sec,
            "capturedAt": isoformat_utc(self.captured_at),
            "positionM": None if self.position_m is None else self.position_m.to_dict(),
            "orientationQuaternion": (
                None
                if self.orientation_quaternion is None
                else self.orientation_quaternion.to_dict()
            ),
            "gravityVector": None if self.gravity_vector is None else self.gravity_vector.to_dict(),
            "headingDegrees": self.heading_degrees,
            "trackingState": self.tracking_state,
            "yawPitchRollDeg": None if self.yaw_pitch_roll_deg is None else self.yaw_pitch_roll_deg.to_dict(),
            "horizontalAccuracyM": self.horizontal_accuracy_m,
            "verticalAccuracyM": self.vertical_accuracy_m,
        }

    @classmethod
    def from_dict(
        cls,
        payload: Mapping[str, Any],
        *,
        default_sample_index: int | None = None,
    ) -> "DevicePoseSamplePayload":
        sample_index = _payload_value(payload, "sampleIndex", "sample")
        if sample_index is None:
            sample_index = 0 if default_sample_index is None else default_sample_index

        time_offset_sec = _payload_value(payload, "timeOffsetSec", "timestampSeconds")
        if time_offset_sec is None:
            raise ValueError("DevicePoseSamplePayload requires timeOffsetSec or timestampSeconds")

        position_value = _payload_value(payload, "positionM", "positionXYZM")
        orientation_value = _payload_value(payload, "orientationQuaternion", "quaternion")
        gravity_value = _payload_value(payload, "gravityVector")
        yaw_pitch_roll_value = _payload_value(payload, "yawPitchRollDeg")

        return cls(
            sample_index=int(sample_index),
            time_offset_sec=float(time_offset_sec),
            captured_at=parse_datetime(_as_str(payload, "capturedAt")),
            position_m=(
                Vector3Payload.from_dict(position_value)
                if position_value is not None
                else None
            ),
            orientation_quaternion=(
                QuaternionPayload.from_dict(orientation_value)
                if orientation_value is not None
                else None
            ),
            gravity_vector=(
                Vector3Payload.from_dict(gravity_value)
                if gravity_value is not None
                else None
            ),
            heading_degrees=(
                float(payload["headingDegrees"])
                if payload.get("headingDegrees") is not None
                else None
            ),
            tracking_state=_as_str(payload, "trackingState"),
            yaw_pitch_roll_deg=(
                Vector3Payload.from_dict(yaw_pitch_roll_value)
                if yaw_pitch_roll_value is not None
                else None
            ),
            horizontal_accuracy_m=(
                float(payload["horizontalAccuracyM"])
                if payload.get("horizontalAccuracyM") is not None
                else None
            ),
            vertical_accuracy_m=(
                float(payload["verticalAccuracyM"])
                if payload.get("verticalAccuracyM") is not None
                else None
            ),
        )


@dataclass(frozen=True)
class ReferenceEvidenceFramePayload:
    frame_id: str
    time_offset_sec: float
    jpeg_base64: str
    pose_sample_index: int | None = None
    captured_at: datetime | None = None
    width_px: int | None = None
    height_px: int | None = None

    def __post_init__(self):
        _require_non_empty("frame_id", self.frame_id)
        if self.time_offset_sec < 0:
            raise ValueError("time_offset_sec must be non-negative")
        _require_non_empty("jpeg_base64", self.jpeg_base64)
        if self.pose_sample_index is not None:
            _non_negative_int("pose_sample_index", self.pose_sample_index)
        if self.width_px is not None and int(self.width_px) <= 0:
            raise ValueError("width_px must be positive when provided")
        if self.height_px is not None and int(self.height_px) <= 0:
            raise ValueError("height_px must be positive when provided")

    def to_dict(self) -> dict[str, Any]:
        return {
            "frameId": self.frame_id,
            "timeOffsetSec": self.time_offset_sec,
            "poseSampleIndex": self.pose_sample_index,
            "capturedAt": isoformat_utc(self.captured_at),
            "widthPx": self.width_px,
            "heightPx": self.height_px,
            "jpegBase64": self.jpeg_base64,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ReferenceEvidenceFramePayload":
        frame_id = _payload_value(payload, "frameId", "frameID")
        if frame_id is None:
            raise ValueError("ReferenceEvidenceFramePayload requires frameId")

        time_offset_sec = _payload_value(payload, "timeOffsetSec", "timestampSeconds")
        if time_offset_sec is None:
            raise ValueError(
                "ReferenceEvidenceFramePayload requires timeOffsetSec or timestampSeconds",
            )

        jpeg_base64 = _as_str(payload, "jpegBase64", "imageBase64")
        if jpeg_base64 is None:
            raise ValueError("ReferenceEvidenceFramePayload requires jpegBase64 or imageBase64")

        return cls(
            frame_id=str(frame_id),
            time_offset_sec=float(time_offset_sec),
            jpeg_base64=jpeg_base64,
            pose_sample_index=(
                int(_payload_value(payload, "poseSampleIndex", "sampleIndex"))
                if _payload_value(payload, "poseSampleIndex", "sampleIndex") is not None
                else None
            ),
            captured_at=parse_datetime(_as_str(payload, "capturedAt")),
            width_px=(
                int(_payload_value(payload, "widthPx", "imageWidthPx"))
                if _payload_value(payload, "widthPx", "imageWidthPx") is not None
                else None
            ),
            height_px=(
                int(_payload_value(payload, "heightPx", "imageHeightPx"))
                if _payload_value(payload, "heightPx", "imageHeightPx") is not None
                else None
            ),
        )


ReferenceEvidenceJPEGFramePayload = ReferenceEvidenceFramePayload


@dataclass(frozen=True)
class ReferenceObservationPayload:
    reference_id: str
    family: str = "unspecified"
    frame_time_sec: float | None = None
    captured_at: datetime | None = None
    pose_sample_index: int | None = None
    decision_margin: float | None = None
    hamming: int | None = None
    edge_length_px: float | None = None
    frame_id: str | None = None
    pixel_area_px: float | None = None
    confidence: float | None = None
    estimated_distance_m: float | None = None
    state: ReferenceMarkerQuality | None = None

    def __post_init__(self):
        _require_non_empty("reference_id", self.reference_id)
        _require_non_empty("family", self.family)
        if self.pose_sample_index is not None:
            _non_negative_int("pose_sample_index", self.pose_sample_index)
        if self.hamming is not None:
            _non_negative_int("hamming", self.hamming)
        object.__setattr__(self, "confidence", _clamp_ratio(self.confidence))

    def to_dict(self) -> dict[str, Any]:
        return {
            "referenceId": self.reference_id,
            "family": self.family,
            "frameTimeSec": self.frame_time_sec,
            "capturedAt": isoformat_utc(self.captured_at),
            "poseSampleIndex": self.pose_sample_index,
            "decisionMargin": self.decision_margin,
            "hamming": self.hamming,
            "edgeLengthPx": self.edge_length_px,
            "frameId": self.frame_id,
            "pixelAreaPx": self.pixel_area_px,
            "confidence": self.confidence,
            "estimatedDistanceM": self.estimated_distance_m,
            "state": None if self.state is None else self.state.value,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ReferenceObservationPayload":
        reference_id = _payload_value(payload, "referenceId", "markerId")
        if reference_id is None:
            raise ValueError("ReferenceObservationPayload requires referenceId or markerId")

        family = _as_str(
            payload,
            "family",
            "markerFamily",
            "referenceFamily",
            "tagFamily",
            default="unspecified",
        ) or "unspecified"
        state_value = _payload_value(payload, "state", "quality")

        return cls(
            reference_id=str(reference_id),
            family=family,
            frame_time_sec=(
                float(payload["frameTimeSec"])
                if payload.get("frameTimeSec") is not None
                else None
            ),
            captured_at=parse_datetime(_as_str(payload, "capturedAt")),
            pose_sample_index=(
                int(_payload_value(payload, "poseSampleIndex", "sampleIndex"))
                if _payload_value(payload, "poseSampleIndex", "sampleIndex") is not None
                else None
            ),
            decision_margin=(
                float(payload["decisionMargin"])
                if payload.get("decisionMargin") is not None
                else None
            ),
            hamming=(
                int(_payload_value(payload, "hamming", "hammingDistance"))
                if _payload_value(payload, "hamming", "hammingDistance") is not None
                else None
            ),
            edge_length_px=(
                float(_payload_value(payload, "edgeLengthPx", "pixelEdgeLengthPx"))
                if _payload_value(payload, "edgeLengthPx", "pixelEdgeLengthPx") is not None
                else None
            ),
            frame_id=_as_str(payload, "frameId"),
            pixel_area_px=(
                float(_payload_value(payload, "pixelAreaPx", "pixelArea"))
                if _payload_value(payload, "pixelAreaPx", "pixelArea") is not None
                else None
            ),
            confidence=(
                float(payload["confidence"])
                if payload.get("confidence") is not None
                else None
            ),
            estimated_distance_m=(
                float(payload["estimatedDistanceM"])
                if payload.get("estimatedDistanceM") is not None
                else None
            ),
            state=ReferenceMarkerQuality(str(state_value)) if state_value is not None else None,
        )


@dataclass(frozen=True)
class MaterialSuggestionPayload:
    material_code: str | None = None
    label: str | None = None
    confidence: float | None = None
    source: str | None = None

    def __post_init__(self):
        material_code = self.material_code
        if material_code is not None:
            material_code = material_code.strip() or None
        label = self.label
        if label is not None:
            label = label.strip() or None
        source = self.source
        if source is not None:
            source = source.strip() or None
        object.__setattr__(self, "material_code", material_code)
        object.__setattr__(self, "label", label)
        object.__setattr__(self, "confidence", _clamp_ratio(self.confidence))
        object.__setattr__(self, "source", source)

    def to_dict(self) -> dict[str, Any]:
        return {
            "materialCode": self.material_code,
            "label": self.label,
            "confidence": self.confidence,
            "source": self.source,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "MaterialSuggestionPayload":
        return cls(
            material_code=_as_str(payload, "materialCode", "suggestedMaterialCode"),
            label=_as_str(payload, "label", "displayName", "materialLabel", "suggestedMaterial"),
            confidence=(
                float(_payload_value(payload, "confidence", "materialConfidence"))
                if _payload_value(payload, "confidence", "materialConfidence") is not None
                else None
            ),
            source=_as_str(payload, "source", "provider"),
        )


@dataclass(frozen=True)
class ReferenceMarkerSnapshotPayload:
    marker_id: str
    visible_count: int
    confidence: float
    quality: ReferenceMarkerQuality

    def __post_init__(self):
        _require_non_empty("marker_id", self.marker_id)
        _non_negative_int("visible_count", self.visible_count)
        object.__setattr__(self, "confidence", _clamp_ratio(self.confidence) or 0.0)

    def to_dict(self) -> dict[str, Any]:
        return {
            "markerId": self.marker_id,
            "visibleCount": self.visible_count,
            "confidence": self.confidence,
            "quality": self.quality.value,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ReferenceMarkerSnapshotPayload":
        return cls(
            marker_id=str(payload["markerId"]),
            visible_count=int(payload["visibleCount"]),
            confidence=float(payload["confidence"]),
            quality=ReferenceMarkerQuality(str(payload["quality"])),
        )


@dataclass(frozen=True)
class DevicePoseTelemetryPayload:
    sample_count: int | None = None
    motion_stable: bool | None = None
    heading_stable: bool | None = None
    lidar_assist_available: bool | None = None
    tracking_state: str | None = None

    def __post_init__(self):
        if self.sample_count is not None:
            _non_negative_int("sample_count", self.sample_count)

    def to_dict(self) -> dict[str, Any]:
        return {
            "sampleCount": self.sample_count,
            "motionStable": self.motion_stable,
            "headingStable": self.heading_stable,
            "lidarAssistAvailable": self.lidar_assist_available,
            "trackingState": self.tracking_state,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "DevicePoseTelemetryPayload":
        return cls(
            sample_count=int(payload["sampleCount"]) if payload.get("sampleCount") is not None else None,
            motion_stable=bool(payload["motionStable"]) if payload.get("motionStable") is not None else None,
            heading_stable=bool(payload["headingStable"]) if payload.get("headingStable") is not None else None,
            lidar_assist_available=bool(payload["lidarAssistAvailable"]) if payload.get("lidarAssistAvailable") is not None else None,
            tracking_state=_as_str(payload, "trackingState"),
        )


@dataclass(frozen=True)
class OnDeviceVisionPayload:
    source: str
    uses_machine_learning: bool
    pile_segmentation_score: float | None = None
    toe_segmentation_score: float | None = None
    segmentation_confidence_score: float | None = None
    foreground_coverage_ratio: float | None = None
    lower_frame_occupancy_ratio: float | None = None
    material_family_code: str | None = None
    material_family_label: str | None = None
    material_confidence_score: float | None = None
    guidance_hint: str | None = None

    def __post_init__(self):
        _require_non_empty("source", self.source)
        object.__setattr__(self, "pile_segmentation_score", _clamp_ratio(self.pile_segmentation_score))
        object.__setattr__(self, "toe_segmentation_score", _clamp_ratio(self.toe_segmentation_score))
        object.__setattr__(self, "segmentation_confidence_score", _clamp_ratio(self.segmentation_confidence_score))
        object.__setattr__(self, "foreground_coverage_ratio", _clamp_ratio(self.foreground_coverage_ratio))
        object.__setattr__(self, "lower_frame_occupancy_ratio", _clamp_ratio(self.lower_frame_occupancy_ratio))
        object.__setattr__(self, "material_confidence_score", _clamp_ratio(self.material_confidence_score))

    def to_dict(self) -> dict[str, Any]:
        return {
            "source": self.source,
            "usesMachineLearning": self.uses_machine_learning,
            "pileSegmentationScore": self.pile_segmentation_score,
            "toeSegmentationScore": self.toe_segmentation_score,
            "segmentationConfidenceScore": self.segmentation_confidence_score,
            "foregroundCoverageRatio": self.foreground_coverage_ratio,
            "lowerFrameOccupancyRatio": self.lower_frame_occupancy_ratio,
            "materialFamilyCode": self.material_family_code,
            "materialFamilyLabel": self.material_family_label,
            "materialConfidenceScore": self.material_confidence_score,
            "guidanceHint": self.guidance_hint,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "OnDeviceVisionPayload":
        source = _as_str(payload, "source")
        if source is None:
            raise ValueError("OnDeviceVisionPayload requires source")
        return cls(
            source=source,
            uses_machine_learning=bool(payload.get("usesMachineLearning", False)),
            pile_segmentation_score=payload.get("pileSegmentationScore"),
            toe_segmentation_score=payload.get("toeSegmentationScore"),
            segmentation_confidence_score=payload.get("segmentationConfidenceScore"),
            foreground_coverage_ratio=payload.get("foregroundCoverageRatio"),
            lower_frame_occupancy_ratio=payload.get("lowerFrameOccupancyRatio"),
            material_family_code=_as_str(payload, "materialFamilyCode"),
            material_family_label=_as_str(payload, "materialFamilyLabel"),
            material_confidence_score=payload.get("materialConfidenceScore"),
            guidance_hint=_as_str(payload, "guidanceHint"),
        )


@dataclass(frozen=True)
class MobileFirstCapturePayload:
    stage: MobileFirstCaptureStage
    reference_marker_snapshots: tuple[ReferenceMarkerSnapshotPayload, ...] = ()
    native_reference_observations: tuple[ReferenceObservationPayload, ...] = ()
    material_suggestion: MaterialSuggestionPayload | None = None
    on_device_vision: OnDeviceVisionPayload | None = None
    device_pose_telemetry: DevicePoseTelemetryPayload | None = None
    toe_coverage_score: float | None = None
    pile_segmentation_score: float | None = None
    toe_segmentation_score: float | None = None
    segmentation_confidence_score: float | None = None
    estimated_concurrent_reference_count: int | None = None
    quick_volume_m3: float | None = None
    quick_footprint_area_m2: float | None = None
    quick_peak_height_m: float | None = None
    quick_confidence_score: float | None = None
    quick_geometry_point_count: int | None = None
    quick_camera_path_distance_m: float | None = None

    def __post_init__(self):
        object.__setattr__(self, "toe_coverage_score", _clamp_ratio(self.toe_coverage_score))
        object.__setattr__(self, "pile_segmentation_score", _clamp_ratio(self.pile_segmentation_score))
        object.__setattr__(self, "toe_segmentation_score", _clamp_ratio(self.toe_segmentation_score))
        object.__setattr__(self, "segmentation_confidence_score", _clamp_ratio(self.segmentation_confidence_score))
        if self.estimated_concurrent_reference_count is not None:
            _non_negative_int(
                "estimated_concurrent_reference_count",
                self.estimated_concurrent_reference_count,
            )
        if self.quick_volume_m3 is not None and float(self.quick_volume_m3) < 0:
            raise ValueError("quick_volume_m3 must be non-negative")
        if self.quick_footprint_area_m2 is not None and float(self.quick_footprint_area_m2) < 0:
            raise ValueError("quick_footprint_area_m2 must be non-negative")
        if self.quick_peak_height_m is not None and float(self.quick_peak_height_m) < 0:
            raise ValueError("quick_peak_height_m must be non-negative")
        object.__setattr__(self, "quick_confidence_score", _clamp_ratio(self.quick_confidence_score))
        if self.quick_geometry_point_count is not None:
            _non_negative_int("quick_geometry_point_count", self.quick_geometry_point_count)
        if self.quick_camera_path_distance_m is not None and float(self.quick_camera_path_distance_m) < 0:
            raise ValueError("quick_camera_path_distance_m must be non-negative")

    def to_dict(self) -> dict[str, Any]:
        return {
            "stage": self.stage.value,
            "referenceMarkerSnapshots": [snapshot.to_dict() for snapshot in self.reference_marker_snapshots],
            "nativeReferenceObservations": [
                observation.to_dict() for observation in self.native_reference_observations
            ],
            "materialSuggestion": (
                None
                if self.material_suggestion is None
                else self.material_suggestion.to_dict()
            ),
            "onDeviceVision": (
                None
                if self.on_device_vision is None
                else self.on_device_vision.to_dict()
            ),
            "devicePoseTelemetry": None if self.device_pose_telemetry is None else self.device_pose_telemetry.to_dict(),
            "toeCoverageScore": self.toe_coverage_score,
            "pileSegmentationScore": self.pile_segmentation_score,
            "toeSegmentationScore": self.toe_segmentation_score,
            "segmentationConfidenceScore": self.segmentation_confidence_score,
            "estimatedConcurrentReferenceCount": self.estimated_concurrent_reference_count,
            "quickVolumeM3": self.quick_volume_m3,
            "quickFootprintAreaM2": self.quick_footprint_area_m2,
            "quickPeakHeightM": self.quick_peak_height_m,
            "quickConfidenceScore": self.quick_confidence_score,
            "quickGeometryPointCount": self.quick_geometry_point_count,
            "quickCameraPathDistanceM": self.quick_camera_path_distance_m,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "MobileFirstCapturePayload":
        native_reference_observations_payload = list(
            _payload_value(
                payload,
                "nativeReferenceObservations",
                "decodedReferenceObservations",
                "decodedNativeReferenceObservations",
                default=[],
            )
            or []
        )
        material_suggestion_payload = _payload_value(
            payload,
            "materialSuggestion",
            "materialClassification",
        )
        on_device_vision_payload = _payload_value(
            payload,
            "onDeviceVision",
            "onDeviceSegmentation",
            "visionSummary",
        )
        return cls(
            stage=MobileFirstCaptureStage(str(payload["stage"])),
            reference_marker_snapshots=tuple(
                ReferenceMarkerSnapshotPayload.from_dict(item)
                for item in (payload.get("referenceMarkerSnapshots") or [])
            ),
            native_reference_observations=tuple(
                ReferenceObservationPayload.from_dict(item)
                for item in native_reference_observations_payload
            ),
            material_suggestion=(
                MaterialSuggestionPayload.from_dict(material_suggestion_payload)
                if isinstance(material_suggestion_payload, MappingABC)
                else None
            ),
            on_device_vision=(
                OnDeviceVisionPayload.from_dict(on_device_vision_payload)
                if isinstance(on_device_vision_payload, MappingABC)
                else None
            ),
            device_pose_telemetry=(
                DevicePoseTelemetryPayload.from_dict(payload["devicePoseTelemetry"])
                if payload.get("devicePoseTelemetry")
                else None
            ),
            toe_coverage_score=payload.get("toeCoverageScore"),
            pile_segmentation_score=payload.get("pileSegmentationScore"),
            toe_segmentation_score=payload.get("toeSegmentationScore"),
            segmentation_confidence_score=payload.get("segmentationConfidenceScore"),
            estimated_concurrent_reference_count=(
                int(payload["estimatedConcurrentReferenceCount"])
                if payload.get("estimatedConcurrentReferenceCount") is not None
                else None
            ),
            quick_volume_m3=(
                float(payload["quickVolumeM3"])
                if payload.get("quickVolumeM3") is not None
                else None
            ),
            quick_footprint_area_m2=(
                float(payload["quickFootprintAreaM2"])
                if payload.get("quickFootprintAreaM2") is not None
                else None
            ),
            quick_peak_height_m=(
                float(payload["quickPeakHeightM"])
                if payload.get("quickPeakHeightM") is not None
                else None
            ),
            quick_confidence_score=payload.get("quickConfidenceScore"),
            quick_geometry_point_count=(
                int(payload["quickGeometryPointCount"])
                if payload.get("quickGeometryPointCount") is not None
                else None
            ),
            quick_camera_path_distance_m=(
                float(payload["quickCameraPathDistanceM"])
                if payload.get("quickCameraPathDistanceM") is not None
                else None
            ),
        )


@dataclass(frozen=True)
class CaptureQualityInputPayload:
    reference_visibility_score: float | None = None
    coverage_score: float | None = None
    motion_stability_score: float | None = None
    overall_guidance_score: float | None = None
    toe_coverage_score: float | None = None
    estimated_concurrent_reference_count: int | None = None
    device_sensors: DeviceSensorInputPayload = field(default_factory=DeviceSensorInputPayload.reserved)
    mobile_first_capture: MobileFirstCapturePayload | None = None

    def __post_init__(self):
        object.__setattr__(self, "reference_visibility_score", _clamp_ratio(self.reference_visibility_score))
        object.__setattr__(self, "coverage_score", _clamp_ratio(self.coverage_score))
        object.__setattr__(self, "motion_stability_score", _clamp_ratio(self.motion_stability_score))
        object.__setattr__(self, "overall_guidance_score", _clamp_ratio(self.overall_guidance_score))
        object.__setattr__(self, "toe_coverage_score", _clamp_ratio(self.toe_coverage_score))
        if self.estimated_concurrent_reference_count is not None:
            _non_negative_int(
                "estimated_concurrent_reference_count",
                self.estimated_concurrent_reference_count,
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "referenceVisibilityScore": self.reference_visibility_score,
            "coverageScore": self.coverage_score,
            "motionStabilityScore": self.motion_stability_score,
            "overallGuidanceScore": self.overall_guidance_score,
            "toeCoverageScore": self.toe_coverage_score,
            "estimatedConcurrentReferenceCount": self.estimated_concurrent_reference_count,
            "deviceSensors": self.device_sensors.to_dict(),
            "mobileFirstCapture": None if self.mobile_first_capture is None else self.mobile_first_capture.to_dict(),
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "CaptureQualityInputPayload":
        device_sensors_payload = payload.get("deviceSensors") or {}
        return cls(
            reference_visibility_score=payload.get("referenceVisibilityScore"),
            coverage_score=payload.get("coverageScore"),
            motion_stability_score=payload.get("motionStabilityScore"),
            overall_guidance_score=payload.get("overallGuidanceScore"),
            toe_coverage_score=payload.get("toeCoverageScore"),
            estimated_concurrent_reference_count=(
                int(payload["estimatedConcurrentReferenceCount"])
                if payload.get("estimatedConcurrentReferenceCount") is not None
                else None
            ),
            device_sensors=DeviceSensorInputPayload.from_dict(device_sensors_payload),
            mobile_first_capture=(
                MobileFirstCapturePayload.from_dict(payload["mobileFirstCapture"])
                if payload.get("mobileFirstCapture")
                else None
            ),
        )


@dataclass(frozen=True)
class CaptureSessionCreateRequest:
    site_id: str
    pile_name: str
    material_code: str
    density_kg_per_m3: int
    reference_count_goal: int
    client_build: str
    tagged_reference_strategy: TaggedReferenceStrategyPayload
    capture_metadata: CaptureMetadataPayload
    quality_input: CaptureQualityInputPayload

    def __post_init__(self):
        _require_non_empty("site_id", self.site_id)
        _require_non_empty("pile_name", self.pile_name)
        _require_non_empty("material_code", self.material_code)
        _require_non_empty("client_build", self.client_build)
        if int(self.density_kg_per_m3) <= 0:
            raise ValueError("density_kg_per_m3 must be positive")
        _non_negative_int("reference_count_goal", self.reference_count_goal)

    def to_dict(self) -> dict[str, Any]:
        return {
            "siteId": self.site_id,
            "pileName": self.pile_name,
            "materialCode": self.material_code,
            "densityKgPerM3": self.density_kg_per_m3,
            "referenceCountGoal": self.reference_count_goal,
            "clientBuild": self.client_build,
            "taggedReferenceStrategy": self.tagged_reference_strategy.to_dict(),
            "captureMetadata": self.capture_metadata.to_dict(),
            "qualityInput": self.quality_input.to_dict(),
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "CaptureSessionCreateRequest":
        return cls(
            site_id=str(payload["siteId"]),
            pile_name=str(payload["pileName"]),
            material_code=str(payload["materialCode"]),
            density_kg_per_m3=int(payload["densityKgPerM3"]),
            reference_count_goal=int(payload["referenceCountGoal"]),
            client_build=str(payload["clientBuild"]),
            tagged_reference_strategy=TaggedReferenceStrategyPayload.from_dict(payload["taggedReferenceStrategy"]),
            capture_metadata=CaptureMetadataPayload.from_dict(payload["captureMetadata"]),
            quality_input=CaptureQualityInputPayload.from_dict(payload["qualityInput"]),
        )


@dataclass(frozen=True)
class CaptureSession:
    session_id: str
    site_id: str
    pile_name: str
    material_code: str
    density_kg_per_m3: int
    reference_count_goal: int
    created_at: datetime
    expires_at: datetime
    tagged_reference_strategy: TaggedReferenceStrategyPayload
    capture_metadata: CaptureMetadataPayload
    quality_input: CaptureQualityInputPayload
    client_build: str
    updated_at: datetime | None = None
    latest_upload_id: str | None = None
    latest_job_id: str | None = None
    latest_run_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "sessionId": self.session_id,
            "siteId": self.site_id,
            "pileName": self.pile_name,
            "materialCode": self.material_code,
            "densityKgPerM3": self.density_kg_per_m3,
            "referenceCountGoal": self.reference_count_goal,
            "createdAt": isoformat_utc(self.created_at),
            "expiresAt": isoformat_utc(self.expires_at),
            "taggedReferenceStrategy": self.tagged_reference_strategy.to_dict(),
            "captureMetadata": self.capture_metadata.to_dict(),
            "qualityInput": self.quality_input.to_dict(),
            "clientBuild": self.client_build,
            "updatedAt": isoformat_utc(self.updated_at),
            "latestUploadId": self.latest_upload_id,
            "latestJobId": self.latest_job_id,
            "latestRunId": self.latest_run_id,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "CaptureSession":
        created_at = parse_datetime(str(payload["createdAt"])) or utc_now()
        return cls(
            session_id=str(payload["sessionId"]),
            site_id=str(payload["siteId"]),
            pile_name=str(payload["pileName"]),
            material_code=str(payload["materialCode"]),
            density_kg_per_m3=int(payload["densityKgPerM3"]),
            reference_count_goal=int(payload["referenceCountGoal"]),
            created_at=created_at,
            expires_at=parse_datetime(str(payload["expiresAt"])) or utc_now(),
            tagged_reference_strategy=TaggedReferenceStrategyPayload.from_dict(payload["taggedReferenceStrategy"]),
            capture_metadata=CaptureMetadataPayload.from_dict(payload["captureMetadata"]),
            quality_input=CaptureQualityInputPayload.from_dict(payload["qualityInput"]),
            client_build=str(payload["clientBuild"]),
            updated_at=parse_datetime(_as_str(payload, "updatedAt")) or created_at,
            latest_upload_id=_as_str(payload, "latestUploadId"),
            latest_job_id=_as_str(payload, "latestJobId"),
            latest_run_id=_as_str(payload, "latestRunId"),
        )


@dataclass(frozen=True)
class UploadRequest:
    session_id: str
    file_name: str
    byte_count: int
    content_type: str
    checksum_sha256: str | None
    tagged_reference_strategy: TaggedReferenceStrategyPayload | None = None
    capture_metadata: CaptureMetadataPayload | None = None
    quality_input: CaptureQualityInputPayload | None = None
    pose_samples: tuple[DevicePoseSamplePayload, ...] = ()
    reference_evidence_frames: tuple[ReferenceEvidenceFramePayload, ...] = ()
    reference_observations: tuple[ReferenceObservationPayload, ...] = ()

    def __post_init__(self):
        _require_non_empty("session_id", self.session_id)
        _require_non_empty("file_name", self.file_name)
        _require_non_empty("content_type", self.content_type)
        _non_negative_int("byte_count", self.byte_count)

    def to_dict(self) -> dict[str, Any]:
        return {
            "sessionId": self.session_id,
            "fileName": self.file_name,
            "byteCount": self.byte_count,
            "contentType": self.content_type,
            "checksumSha256": self.checksum_sha256,
            "taggedReferenceStrategy": (
                None
                if self.tagged_reference_strategy is None
                else self.tagged_reference_strategy.to_dict()
            ),
            "captureMetadata": (
                None
                if self.capture_metadata is None
                else self.capture_metadata.to_dict()
            ),
            "qualityInput": (
                None
                if self.quality_input is None
                else self.quality_input.to_dict()
            ),
            "poseSamples": [sample.to_dict() for sample in self.pose_samples],
            "referenceEvidenceJPEGFrames": [
                frame.to_dict() for frame in self.reference_evidence_frames
            ],
            "referenceObservations": [
                observation.to_dict() for observation in self.reference_observations
            ],
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "UploadRequest":
        pose_samples_payload = list(payload.get("poseSamples") or [])
        reference_evidence_frames_payload = list(
            _payload_value(
                payload,
                "referenceEvidenceJPEGFrames",
                "referenceEvidenceFrames",
                default=[],
            )
            or []
        )
        return cls(
            session_id=str(payload["sessionId"]),
            file_name=str(payload["fileName"]),
            byte_count=int(payload["byteCount"]),
            content_type=str(payload["contentType"]),
            checksum_sha256=_as_str(payload, "checksumSha256"),
            tagged_reference_strategy=(
                TaggedReferenceStrategyPayload.from_dict(payload["taggedReferenceStrategy"])
                if payload.get("taggedReferenceStrategy")
                else None
            ),
            capture_metadata=(
                CaptureMetadataPayload.from_dict(payload["captureMetadata"])
                if payload.get("captureMetadata")
                else None
            ),
            quality_input=(
                CaptureQualityInputPayload.from_dict(payload["qualityInput"])
                if payload.get("qualityInput")
                else None
            ),
            pose_samples=tuple(
                DevicePoseSamplePayload.from_dict(item, default_sample_index=index)
                for index, item in enumerate(pose_samples_payload)
            ),
            reference_evidence_frames=tuple(
                ReferenceEvidenceFramePayload.from_dict(item)
                for item in reference_evidence_frames_payload
            ),
            reference_observations=tuple(
                ReferenceObservationPayload.from_dict(item)
                for item in (payload.get("referenceObservations") or [])
            ),
        )

    @property
    def reference_evidence_jpeg_frames(self) -> tuple[ReferenceEvidenceFramePayload, ...]:
        return self.reference_evidence_frames


@dataclass(frozen=True)
class UploadAuthorization:
    upload_id: str
    session_id: str
    job_id: str
    upload_url: str
    http_method: str
    headers: dict[str, str]
    expires_at: datetime
    run_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "uploadId": self.upload_id,
            "sessionId": self.session_id,
            "jobId": self.job_id,
            "uploadUrl": self.upload_url,
            "httpMethod": self.http_method,
            "headers": dict(self.headers),
            "expiresAt": isoformat_utc(self.expires_at),
            "runId": self.run_id,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "UploadAuthorization":
        return cls(
            upload_id=str(payload["uploadId"]),
            session_id=str(payload["sessionId"]),
            job_id=str(payload["jobId"]),
            upload_url=str(payload["uploadUrl"]),
            http_method=str(payload["httpMethod"]),
            headers={str(key): str(value) for key, value in dict(payload.get("headers") or {}).items()},
            expires_at=parse_datetime(str(payload["expiresAt"])) or utc_now(),
            run_id=_as_str(payload, "runId"),
        )


@dataclass(frozen=True)
class UploadReceipt:
    receipt_id: str
    upload_id: str
    job_id: str
    run_id: str
    phase: JobPhase
    bytes_received: int
    content_type: str
    checksum_sha256: str | None
    accepted_at: datetime

    def __post_init__(self):
        _require_non_empty("receipt_id", self.receipt_id)
        _require_non_empty("upload_id", self.upload_id)
        _require_non_empty("job_id", self.job_id)
        _require_non_empty("run_id", self.run_id)
        _require_non_empty("content_type", self.content_type)
        _non_negative_int("bytes_received", self.bytes_received)

    def to_dict(self) -> dict[str, Any]:
        return {
            "receiptId": self.receipt_id,
            "uploadId": self.upload_id,
            "jobId": self.job_id,
            "runId": self.run_id,
            "phase": self.phase.value,
            "bytesReceived": self.bytes_received,
            "contentType": self.content_type,
            "checksumSha256": self.checksum_sha256,
            "acceptedAt": isoformat_utc(self.accepted_at),
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "UploadReceipt":
        return cls(
            receipt_id=str(payload["receiptId"]),
            upload_id=str(payload["uploadId"]),
            job_id=str(payload["jobId"]),
            run_id=str(payload["runId"]),
            phase=JobPhase(str(payload["phase"])),
            bytes_received=int(payload["bytesReceived"]),
            content_type=str(payload["contentType"]),
            checksum_sha256=_as_str(payload, "checksumSha256"),
            accepted_at=parse_datetime(str(payload["acceptedAt"])) or utc_now(),
        )


@dataclass(frozen=True)
class UploadProgressPayload:
    state: UploadState
    bytes_received: int
    bytes_expected: int

    def __post_init__(self):
        _non_negative_int("bytes_received", self.bytes_received)
        _non_negative_int("bytes_expected", self.bytes_expected)

    def to_dict(self) -> dict[str, Any]:
        return {
            "state": self.state.value,
            "bytesReceived": self.bytes_received,
            "bytesExpected": self.bytes_expected,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "UploadProgressPayload":
        return cls(
            state=UploadState(str(payload["state"])),
            bytes_received=int(payload["bytesReceived"]),
            bytes_expected=int(payload["bytesExpected"]),
        )


@dataclass(frozen=True)
class ProcessingStatePayload:
    phase: JobPhase
    progress: float
    headline: str
    detail: str

    def __post_init__(self):
        object.__setattr__(self, "progress", _clamp_ratio(self.progress) or 0.0)
        _require_non_empty("headline", self.headline)
        _require_non_empty("detail", self.detail)

    def to_dict(self) -> dict[str, Any]:
        return {
            "phase": self.phase.value,
            "progress": self.progress,
            "headline": self.headline,
            "detail": self.detail,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ProcessingStatePayload":
        return cls(
            phase=JobPhase(str(payload["phase"])),
            progress=float(payload["progress"]),
            headline=str(payload["headline"]),
            detail=str(payload["detail"]),
        )


@dataclass(frozen=True)
class QualityGatePayload:
    state: QualityGateState
    reference_visibility_score: float | None = None
    perimeter_coverage_score: float | None = None
    motion_stability_score: float | None = None
    overall_guidance_score: float | None = None
    primary_reason: str | None = None

    def __post_init__(self):
        object.__setattr__(self, "reference_visibility_score", _clamp_ratio(self.reference_visibility_score))
        object.__setattr__(self, "perimeter_coverage_score", _clamp_ratio(self.perimeter_coverage_score))
        object.__setattr__(self, "motion_stability_score", _clamp_ratio(self.motion_stability_score))
        object.__setattr__(self, "overall_guidance_score", _clamp_ratio(self.overall_guidance_score))

    def to_dict(self) -> dict[str, Any]:
        return {
            "state": self.state.value,
            "referenceVisibilityScore": self.reference_visibility_score,
            "perimeterCoverageScore": self.perimeter_coverage_score,
            "motionStabilityScore": self.motion_stability_score,
            "overallGuidanceScore": self.overall_guidance_score,
            "primaryReason": self.primary_reason,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "QualityGatePayload":
        return cls(
            state=QualityGateState(str(payload["state"])),
            reference_visibility_score=payload.get("referenceVisibilityScore"),
            perimeter_coverage_score=payload.get("perimeterCoverageScore"),
            motion_stability_score=payload.get("motionStabilityScore"),
            overall_guidance_score=payload.get("overallGuidanceScore"),
            primary_reason=_as_str(payload, "primaryReason"),
        )


@dataclass(frozen=True)
class ProcessingJobStatus:
    job_id: str
    run_id: str
    phase: JobPhase
    progress: float
    headline: str
    detail: str
    updated_at: datetime
    upload: UploadProgressPayload | None = None
    processing: ProcessingStatePayload | None = None
    quality_gate: QualityGatePayload | None = None
    provisional_measurement: "ProvisionalMeasurementPayload | None" = None

    @property
    def is_terminal(self) -> bool:
        return self.phase.is_terminal

    def to_dict(self) -> dict[str, Any]:
        return {
            "jobId": self.job_id,
            "runId": self.run_id,
            "phase": self.phase.value,
            "progress": self.progress,
            "headline": self.headline,
            "detail": self.detail,
            "updatedAt": isoformat_utc(self.updated_at),
            "upload": None if self.upload is None else self.upload.to_dict(),
            "processing": None if self.processing is None else self.processing.to_dict(),
            "qualityGate": None if self.quality_gate is None else self.quality_gate.to_dict(),
            "provisionalMeasurement": (
                None
                if self.provisional_measurement is None
                else self.provisional_measurement.to_dict()
            ),
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ProcessingJobStatus":
        upload_payload = payload.get("upload")
        processing_payload = payload.get("processing")
        quality_gate_payload = payload.get("qualityGate")
        provisional_measurement_payload = payload.get("provisionalMeasurement")
        return cls(
            job_id=str(payload["jobId"]),
            run_id=str(payload["runId"]),
            phase=JobPhase(str(payload["phase"])),
            progress=float(payload["progress"]),
            headline=str(payload["headline"]),
            detail=str(payload["detail"]),
            updated_at=parse_datetime(str(payload["updatedAt"])) or utc_now(),
            upload=UploadProgressPayload.from_dict(upload_payload) if upload_payload else None,
            processing=ProcessingStatePayload.from_dict(processing_payload) if processing_payload else None,
            quality_gate=QualityGatePayload.from_dict(quality_gate_payload) if quality_gate_payload else None,
            provisional_measurement=(
                ProvisionalMeasurementPayload.from_dict(provisional_measurement_payload)
                if provisional_measurement_payload
                else None
            ),
        )


@dataclass(frozen=True)
class ProvisionalMeasurementPayload:
    status: str
    basis: str | None = None
    volume_m3: float | None = None
    weight_tonnes: float | None = None
    confidence_score: int | None = None
    reason: str | None = None
    quick_volume_m3: float | None = None
    quick_footprint_area_m2: float | None = None
    quick_peak_height_m: float | None = None
    quick_confidence_score: float | None = None
    quick_geometry_point_count: int | None = None
    quick_camera_path_distance_m: float | None = None
    native_reference_observations: tuple[ReferenceObservationPayload, ...] = ()
    material_suggestion: MaterialSuggestionPayload | None = None
    updated_at: datetime | None = None

    def __post_init__(self):
        _require_non_empty("status", self.status)
        if self.confidence_score is not None:
            object.__setattr__(
                self,
                "confidence_score",
                max(0, min(100, int(self.confidence_score))),
            )
        for name in (
            "quick_volume_m3",
            "quick_footprint_area_m2",
            "quick_peak_height_m",
            "quick_camera_path_distance_m",
        ):
            value = getattr(self, name)
            if value is not None and float(value) < 0:
                raise ValueError(f"{name} must be non-negative")
        object.__setattr__(self, "quick_confidence_score", _clamp_ratio(self.quick_confidence_score))
        if self.quick_geometry_point_count is not None:
            _non_negative_int("quick_geometry_point_count", self.quick_geometry_point_count)

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "basis": self.basis,
            "volumeM3": self.volume_m3,
            "weightTonnes": self.weight_tonnes,
            "confidenceScore": self.confidence_score,
            "reason": self.reason,
            "quickVolumeM3": self.quick_volume_m3,
            "quickFootprintAreaM2": self.quick_footprint_area_m2,
            "quickPeakHeightM": self.quick_peak_height_m,
            "quickConfidenceScore": self.quick_confidence_score,
            "quickGeometryPointCount": self.quick_geometry_point_count,
            "quickCameraPathDistanceM": self.quick_camera_path_distance_m,
            "nativeReferenceObservations": [
                observation.to_dict() for observation in self.native_reference_observations
            ],
            "materialSuggestion": (
                None
                if self.material_suggestion is None
                else self.material_suggestion.to_dict()
            ),
            "updatedAt": isoformat_utc(self.updated_at),
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ProvisionalMeasurementPayload":
        native_reference_observations_payload = list(
            _payload_value(
                payload,
                "nativeReferenceObservations",
                "decodedReferenceObservations",
                "decodedNativeReferenceObservations",
                default=[],
            )
            or []
        )
        material_suggestion_payload = _payload_value(
            payload,
            "materialSuggestion",
            "materialClassification",
        )
        return cls(
            status=str(payload["status"]),
            basis=_as_str(payload, "basis"),
            volume_m3=float(payload["volumeM3"]) if payload.get("volumeM3") is not None else None,
            weight_tonnes=(
                float(payload["weightTonnes"])
                if payload.get("weightTonnes") is not None
                else None
            ),
            confidence_score=(
                int(payload["confidenceScore"])
                if payload.get("confidenceScore") is not None
                else None
            ),
            reason=_as_str(payload, "reason"),
            quick_volume_m3=(
                float(payload["quickVolumeM3"])
                if payload.get("quickVolumeM3") is not None
                else None
            ),
            quick_footprint_area_m2=(
                float(payload["quickFootprintAreaM2"])
                if payload.get("quickFootprintAreaM2") is not None
                else None
            ),
            quick_peak_height_m=(
                float(payload["quickPeakHeightM"])
                if payload.get("quickPeakHeightM") is not None
                else None
            ),
            quick_confidence_score=payload.get("quickConfidenceScore"),
            quick_geometry_point_count=(
                int(payload["quickGeometryPointCount"])
                if payload.get("quickGeometryPointCount") is not None
                else None
            ),
            quick_camera_path_distance_m=(
                float(payload["quickCameraPathDistanceM"])
                if payload.get("quickCameraPathDistanceM") is not None
                else None
            ),
            native_reference_observations=tuple(
                ReferenceObservationPayload.from_dict(item)
                for item in native_reference_observations_payload
            ),
            material_suggestion=(
                MaterialSuggestionPayload.from_dict(material_suggestion_payload)
                if isinstance(material_suggestion_payload, MappingABC)
                else None
            ),
            updated_at=parse_datetime(_as_str(payload, "updatedAt")),
        )


@dataclass(frozen=True)
class ConfidencePayload:
    score: int
    label: str
    summary: str

    def __post_init__(self):
        clamped = max(0, min(100, int(self.score)))
        object.__setattr__(self, "score", clamped)
        _require_non_empty("label", self.label)
        _require_non_empty("summary", self.summary)

    def to_dict(self) -> dict[str, Any]:
        return {
            "score": self.score,
            "label": self.label,
            "summary": self.summary,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ConfidencePayload":
        return cls(
            score=int(payload["score"]),
            label=str(payload["label"]),
            summary=str(payload["summary"]),
        )


@dataclass(frozen=True)
class MeasurementPayload:
    volume_m3: float
    weight_tonnes: float
    density_kg_per_m3: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "volumeM3": self.volume_m3,
            "weightTonnes": self.weight_tonnes,
            "densityKgPerM3": self.density_kg_per_m3,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "MeasurementPayload":
        return cls(
            volume_m3=float(payload["volumeM3"]),
            weight_tonnes=float(payload["weightTonnes"]),
            density_kg_per_m3=int(payload["densityKgPerM3"]),
        )


@dataclass(frozen=True)
class CaptureQualityPayload:
    reference_visibility_score: float | None = None
    perimeter_coverage_score: float | None = None
    motion_stability_score: float | None = None
    overall_guidance_score: float | None = None

    def __post_init__(self):
        object.__setattr__(self, "reference_visibility_score", _clamp_ratio(self.reference_visibility_score))
        object.__setattr__(self, "perimeter_coverage_score", _clamp_ratio(self.perimeter_coverage_score))
        object.__setattr__(self, "motion_stability_score", _clamp_ratio(self.motion_stability_score))
        object.__setattr__(self, "overall_guidance_score", _clamp_ratio(self.overall_guidance_score))

    def to_dict(self) -> dict[str, Any]:
        return {
            "referenceVisibilityScore": self.reference_visibility_score,
            "perimeterCoverageScore": self.perimeter_coverage_score,
            "motionStabilityScore": self.motion_stability_score,
            "overallGuidanceScore": self.overall_guidance_score,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "CaptureQualityPayload":
        return cls(
            reference_visibility_score=payload.get("referenceVisibilityScore"),
            perimeter_coverage_score=payload.get("perimeterCoverageScore"),
            motion_stability_score=payload.get("motionStabilityScore"),
            overall_guidance_score=payload.get("overallGuidanceScore"),
        )


@dataclass(frozen=True)
class ReferenceDiagnosticsPayload:
    target_count: int
    minimum_visible_together: int
    preferred_visible_count: int
    frames_meeting_visibility_goal: int | None = None
    frames_checked: int | None = None
    calibration_basis: str = "unknown"
    calibration_status: str = "unknown"
    reference_strategy: str | None = None
    references_used: int | None = None
    observation_summary: "ReferenceObservationSummaryPayload | None" = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "targetCount": self.target_count,
            "minimumVisibleTogether": self.minimum_visible_together,
            "preferredVisibleCount": self.preferred_visible_count,
            "framesMeetingVisibilityGoal": self.frames_meeting_visibility_goal,
            "framesChecked": self.frames_checked,
            "calibrationBasis": self.calibration_basis,
            "calibrationStatus": self.calibration_status,
            "referenceStrategy": self.reference_strategy,
            "referencesUsed": self.references_used,
            "observationSummary": (
                None
                if self.observation_summary is None
                else self.observation_summary.to_dict()
            ),
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ReferenceDiagnosticsPayload":
        return cls(
            target_count=int(payload["targetCount"]),
            minimum_visible_together=int(payload["minimumVisibleTogether"]),
            preferred_visible_count=int(payload.get("preferredVisibleCount") or 0),
            frames_meeting_visibility_goal=(
                None if payload.get("framesMeetingVisibilityGoal") is None
                else int(payload["framesMeetingVisibilityGoal"])
            ),
            frames_checked=(
                None if payload.get("framesChecked") is None else int(payload["framesChecked"])
            ),
            calibration_basis=str(payload.get("calibrationBasis") or "unknown"),
            calibration_status=str(payload.get("calibrationStatus") or "unknown"),
            reference_strategy=_as_str(payload, "referenceStrategy"),
            references_used=(
                None if payload.get("referencesUsed") is None else int(payload["referencesUsed"])
            ),
            observation_summary=(
                ReferenceObservationSummaryPayload.from_dict(payload["observationSummary"])
                if payload.get("observationSummary")
                else None
            ),
        )


@dataclass(frozen=True)
class ReferenceObservationSummaryPayload:
    observed_reference_count: int | None = None
    frames_with_observations: int | None = None
    max_visible_together: int | None = None
    used_for_calibration_count: int | None = None

    def __post_init__(self):
        for name in (
            "observed_reference_count",
            "frames_with_observations",
            "max_visible_together",
            "used_for_calibration_count",
        ):
            value = getattr(self, name)
            if value is not None:
                _non_negative_int(name, value)

    def to_dict(self) -> dict[str, Any]:
        return {
            "observedReferenceCount": self.observed_reference_count,
            "framesWithObservations": self.frames_with_observations,
            "maxVisibleTogether": self.max_visible_together,
            "usedForCalibrationCount": self.used_for_calibration_count,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ReferenceObservationSummaryPayload":
        return cls(
            observed_reference_count=(
                int(payload["observedReferenceCount"])
                if payload.get("observedReferenceCount") is not None
                else None
            ),
            frames_with_observations=(
                int(payload["framesWithObservations"])
                if payload.get("framesWithObservations") is not None
                else None
            ),
            max_visible_together=(
                int(payload["maxVisibleTogether"])
                if payload.get("maxVisibleTogether") is not None
                else None
            ),
            used_for_calibration_count=(
                int(payload["usedForCalibrationCount"])
                if payload.get("usedForCalibrationCount") is not None
                else None
            ),
        )


@dataclass(frozen=True)
class ReconstructionPointPayload:
    x: float
    y: float
    z: float

    def to_dict(self) -> dict[str, Any]:
        return {
            "x": float(self.x),
            "y": float(self.y),
            "z": float(self.z),
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ReconstructionPointPayload":
        return cls(
            x=float(payload["x"]),
            y=float(payload["y"]),
            z=float(payload["z"]),
        )


@dataclass(frozen=True)
class ReconstructionTrianglePayload:
    a: int
    b: int
    c: int

    def __post_init__(self):
        _non_negative_int("a", self.a)
        _non_negative_int("b", self.b)
        _non_negative_int("c", self.c)

    def to_dict(self) -> dict[str, Any]:
        return {
            "a": int(self.a),
            "b": int(self.b),
            "c": int(self.c),
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ReconstructionTrianglePayload":
        return cls(
            a=int(payload["a"]),
            b=int(payload["b"]),
            c=int(payload["c"]),
        )


@dataclass(frozen=True)
class ReconstructionPayload:
    summary: str
    footprint_area_m2: float
    peak_height_m: float
    default_mode: str = "3d"
    vertices: list[ReconstructionPointPayload] = field(default_factory=list)
    triangles: list[ReconstructionTrianglePayload] = field(default_factory=list)
    point_cloud: list[ReconstructionPointPayload] = field(default_factory=list)
    toe_markers: list[ReconstructionPointPayload] = field(default_factory=list)
    surface_risk_markers: list[ReconstructionPointPayload] = field(default_factory=list)

    def __post_init__(self):
        _require_non_empty("summary", self.summary)

    def to_dict(self) -> dict[str, Any]:
        return {
            "summary": self.summary,
            "footprintAreaM2": float(self.footprint_area_m2),
            "peakHeightM": float(self.peak_height_m),
            "defaultMode": self.default_mode,
            "vertices": [item.to_dict() for item in self.vertices],
            "triangles": [item.to_dict() for item in self.triangles],
            "pointCloud": [item.to_dict() for item in self.point_cloud],
            "toeMarkers": [item.to_dict() for item in self.toe_markers],
            "surfaceRiskMarkers": [item.to_dict() for item in self.surface_risk_markers],
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ReconstructionPayload":
        return cls(
            summary=str(payload["summary"]),
            footprint_area_m2=float(payload["footprintAreaM2"]),
            peak_height_m=float(payload["peakHeightM"]),
            default_mode=str(payload.get("defaultMode") or "3d"),
            vertices=[
                ReconstructionPointPayload.from_dict(item)
                for item in list(payload.get("vertices") or [])
            ],
            triangles=[
                ReconstructionTrianglePayload.from_dict(item)
                for item in list(payload.get("triangles") or [])
            ],
            point_cloud=[
                ReconstructionPointPayload.from_dict(item)
                for item in list(payload.get("pointCloud") or [])
            ],
            toe_markers=[
                ReconstructionPointPayload.from_dict(item)
                for item in list(payload.get("toeMarkers") or [])
            ],
            surface_risk_markers=[
                ReconstructionPointPayload.from_dict(item)
                for item in list(payload.get("surfaceRiskMarkers") or [])
            ],
        )


@dataclass(frozen=True)
class ResultPayload:
    run_id: str
    pile_name: str
    outcome: RunOutcome
    confidence: ConfidencePayload
    measurement: MeasurementPayload | None
    warnings: list[str]
    blockers: list[str]
    recommended_action: str
    capture_quality: CaptureQualityPayload | None = None
    reference_diagnostics: ReferenceDiagnosticsPayload | None = None
    provisional_measurement: ProvisionalMeasurementPayload | None = None
    reconstruction: ReconstructionPayload | None = None
    report_url: str | None = None
    updated_at: datetime | None = None
    site_id: str | None = None
    session_id: str | None = None
    job_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "runId": self.run_id,
            "pileName": self.pile_name,
            "outcome": self.outcome.value,
            "confidence": self.confidence.to_dict(),
            "measurement": None if self.measurement is None else self.measurement.to_dict(),
            "warnings": list(self.warnings),
            "blockers": list(self.blockers),
            "recommendedAction": self.recommended_action,
            "captureQuality": None if self.capture_quality is None else self.capture_quality.to_dict(),
            "referenceDiagnostics": (
                None if self.reference_diagnostics is None else self.reference_diagnostics.to_dict()
            ),
            "provisionalMeasurement": (
                None
                if self.provisional_measurement is None
                else self.provisional_measurement.to_dict()
            ),
            "reconstruction": (
                None if self.reconstruction is None else self.reconstruction.to_dict()
            ),
            "reportUrl": self.report_url,
            "updatedAt": isoformat_utc(self.updated_at),
            "siteId": self.site_id,
            "sessionId": self.session_id,
            "jobId": self.job_id,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ResultPayload":
        measurement_payload = payload.get("measurement")
        capture_quality_payload = payload.get("captureQuality")
        reference_diagnostics_payload = payload.get("referenceDiagnostics")
        provisional_measurement_payload = payload.get("provisionalMeasurement")
        reconstruction_payload = payload.get("reconstruction")
        return cls(
            run_id=str(payload["runId"]),
            pile_name=str(payload["pileName"]),
            outcome=RunOutcome(str(payload["outcome"])),
            confidence=ConfidencePayload.from_dict(payload["confidence"]),
            measurement=MeasurementPayload.from_dict(measurement_payload) if measurement_payload else None,
            warnings=[str(item) for item in list(payload.get("warnings") or [])],
            blockers=[str(item) for item in list(payload.get("blockers") or [])],
            recommended_action=str(payload["recommendedAction"]),
            capture_quality=(
                CaptureQualityPayload.from_dict(capture_quality_payload)
                if capture_quality_payload
                else None
            ),
            reference_diagnostics=(
                ReferenceDiagnosticsPayload.from_dict(reference_diagnostics_payload)
                if reference_diagnostics_payload
                else None
            ),
            provisional_measurement=(
                ProvisionalMeasurementPayload.from_dict(provisional_measurement_payload)
                if provisional_measurement_payload
                else None
            ),
            reconstruction=(
                ReconstructionPayload.from_dict(reconstruction_payload)
                if reconstruction_payload
                else None
            ),
            report_url=_as_str(payload, "reportUrl"),
            updated_at=parse_datetime(_as_str(payload, "updatedAt")),
            site_id=_as_str(payload, "siteId"),
            session_id=_as_str(payload, "sessionId"),
            job_id=_as_str(payload, "jobId"),
        )


__all__ = [
    "CaptureMetadataPayload",
    "CaptureMode",
    "CaptureQualityInputPayload",
    "CaptureQualityPayload",
    "CaptureSession",
    "CaptureSessionCreateRequest",
    "CaptureSource",
    "ConfidencePayload",
    "CaptureSensorMetadataPayload",
    "DeviceSensorInputPayload",
    "DevicePoseSamplePayload",
    "JobPhase",
    "MaterialSuggestionPayload",
    "MeasurementPayload",
    "MobileFirstCapturePayload",
    "MobileFirstCaptureStage",
    "OnDeviceVisionPayload",
    "ProcessingJobStatus",
    "ProcessingStatePayload",
    "ProvisionalMeasurementPayload",
    "QualityGatePayload",
    "QualityGateState",
    "ReconstructionPayload",
    "ReconstructionPointPayload",
    "ReconstructionTrianglePayload",
    "QuaternionPayload",
    "ReferenceEvidenceJPEGFramePayload",
    "ReferenceEvidenceFramePayload",
    "ReferenceMarkerQuality",
    "ReferenceMarkerSnapshotPayload",
    "ReferenceObservationPayload",
    "ReferenceObservationSummaryPayload",
    "ReferenceDiagnosticsPayload",
    "ResultPayload",
    "RunOutcome",
    "TaggedReferenceStrategyMode",
    "TaggedReferenceStrategyPayload",
    "UploadAuthorization",
    "UploadProgressPayload",
    "UploadRequest",
    "UploadState",
    "Vector3Payload",
    "isoformat_utc",
    "parse_datetime",
    "utc_now",
]
