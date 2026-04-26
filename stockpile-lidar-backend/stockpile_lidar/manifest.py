from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping


class ManifestValidationError(ValueError):
    """Raised when a LiDAR capture manifest is missing required structure."""


@dataclass(frozen=True)
class LidarFrameManifest:
    file_name: str
    timestamp_ms: int
    format: str


@dataclass(frozen=True)
class CaptureManifest:
    capture_id: str
    device_id: str
    captured_at: datetime
    frame_count: int
    frames: tuple[LidarFrameManifest, ...]


def validate_capture_manifest(payload: Mapping[str, Any]) -> CaptureManifest:
    if not isinstance(payload, Mapping):
        raise ManifestValidationError("manifest must be an object")

    capture_id = _required_str(payload, "captureId")
    device_id = _required_str(payload, "deviceId")
    captured_at = _parse_datetime(_required_str(payload, "capturedAt"), "capturedAt")
    lidar = _required_mapping(payload, "lidar")
    frame_count = _required_int(lidar, "frameCount", "lidar.frameCount")
    frames_payload = _required_list(lidar, "frames", "lidar.frames")

    if frame_count < 1:
        raise ManifestValidationError("lidar.frameCount must be at least 1")
    if frame_count != len(frames_payload):
        raise ManifestValidationError("lidar.frameCount must match number of lidar.frames")

    frames = tuple(
        _parse_frame(frame_payload, index)
        for index, frame_payload in enumerate(frames_payload)
    )

    return CaptureManifest(
        capture_id=capture_id,
        device_id=device_id,
        captured_at=captured_at,
        frame_count=frame_count,
        frames=frames,
    )


def _parse_frame(payload: Any, index: int) -> LidarFrameManifest:
    path = f"lidar.frames[{index}]"
    if not isinstance(payload, Mapping):
        raise ManifestValidationError(f"{path} must be an object")

    file_name = _required_str(payload, "fileName", f"{path}.fileName")
    timestamp_ms = _required_int(payload, "timestampMs", f"{path}.timestampMs")
    frame_format = _required_str(payload, "format", f"{path}.format").lower()

    if timestamp_ms < 0:
        raise ManifestValidationError(f"{path}.timestampMs must be greater than or equal to 0")
    if frame_format not in {"ply", "pcd", "xyz", "las", "laz"}:
        raise ManifestValidationError(f"{path}.format is not supported")

    return LidarFrameManifest(
        file_name=file_name,
        timestamp_ms=timestamp_ms,
        format=frame_format,
    )


def _required_mapping(payload: Mapping[str, Any], key: str, path: str | None = None) -> Mapping[str, Any]:
    value = payload.get(key)
    resolved_path = path or key
    if not isinstance(value, Mapping):
        raise ManifestValidationError(f"{resolved_path} is required")
    return value


def _required_list(payload: Mapping[str, Any], key: str, path: str) -> list[Any]:
    value = payload.get(key)
    if not isinstance(value, list):
        raise ManifestValidationError(f"{path} is required")
    return value


def _required_str(payload: Mapping[str, Any], key: str, path: str | None = None) -> str:
    value = payload.get(key)
    resolved_path = path or key
    if not isinstance(value, str) or not value.strip():
        raise ManifestValidationError(f"{resolved_path} is required")
    return value.strip()


def _required_int(payload: Mapping[str, Any], key: str, path: str) -> int:
    value = payload.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ManifestValidationError(f"{path} is required")
    return value


def _parse_datetime(value: str, path: str) -> datetime:
    normalized = value.replace("Z", "+00:00") if value.endswith("Z") else value
    try:
        return datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ManifestValidationError(f"{path} must be an ISO 8601 timestamp") from exc
