from __future__ import annotations

from dataclasses import dataclass
import io
import json
from pathlib import Path, PurePosixPath
import zipfile

import numpy as np


SUPPORTED_SCHEMA_VERSION = 1


class BundleValidationError(ValueError):
    """Raised when a .stockpilecapture bundle does not match the ingest spec."""


@dataclass(frozen=True)
class StockpileCaptureBundle:
    root: Path
    manifest: dict
    poses: list
    rgb_frames: list[Path]
    depth_frames: list[Path]


def unpack_stockpile_capture(bundle_path: str | Path, output_dir: str | Path) -> StockpileCaptureBundle:
    bundle_path = Path(bundle_path)
    output_dir = Path(output_dir)

    with zipfile.ZipFile(bundle_path) as archive:
        members = _normalized_members(archive)
        _require_bundle_layout(members)

        manifest = _load_json(archive, members, "manifest.json")
        if isinstance(manifest, dict):
            _normalize_manifest(manifest)
        poses = _load_poses(archive, members)
        rgb_members = _frame_members(members, "rgb")
        depth_members = _frame_members(members, "depth")

        _validate_manifest(manifest, len(rgb_members), len(depth_members), len(poses))
        _validate_depth_frames(archive, depth_members)
        _extract_members(archive, members, output_dir)

    return StockpileCaptureBundle(
        root=output_dir,
        manifest=manifest,
        poses=poses,
        rgb_frames=[output_dir / name for name, _ in rgb_members],
        depth_frames=[output_dir / name for name, _ in depth_members],
    )


def _normalized_members(archive: zipfile.ZipFile) -> dict[str, zipfile.ZipInfo]:
    members: dict[str, zipfile.ZipInfo] = {}
    for info in archive.infolist():
        member_name = _safe_member_name(info.filename)
        members[member_name] = info
    return members


def _safe_member_name(name: str) -> str:
    normalized = name.replace("\\", "/")
    path = PurePosixPath(normalized)
    if (
        not normalized
        or normalized.startswith("/")
        or path.is_absolute()
        or any(part in {"", ".", ".."} for part in path.parts)
        or (path.parts and path.parts[0].endswith(":"))
    ):
        raise BundleValidationError(f"ZIP entry has path traversal risk: {name}")
    return path.as_posix()


def _require_bundle_layout(members: dict[str, zipfile.ZipInfo]) -> None:
    for required_file in ("manifest.json", "poses.json"):
        if required_file not in members:
            raise BundleValidationError(f"bundle is missing {required_file}")
    for required_folder in ("rgb", "depth"):
        if not _frame_members(members, required_folder):
            raise BundleValidationError(f"bundle is missing {required_folder}/ frames")


def _load_json(
    archive: zipfile.ZipFile,
    members: dict[str, zipfile.ZipInfo],
    name: str,
) -> object:
    try:
        return json.loads(archive.read(members[name]).decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise BundleValidationError(f"{name} is not valid JSON") from exc


def _load_poses(
    archive: zipfile.ZipFile,
    members: dict[str, zipfile.ZipInfo],
) -> list:
    poses_payload = _load_json(archive, members, "poses.json")
    if isinstance(poses_payload, list):
        return _normalize_poses(poses_payload)
    if isinstance(poses_payload, dict) and isinstance(poses_payload.get("poses"), list):
        return _normalize_poses(poses_payload["poses"])
    raise BundleValidationError("poses.json must be a list or contain a poses list")


def _frame_members(
    members: dict[str, zipfile.ZipInfo],
    folder: str,
) -> list[tuple[str, zipfile.ZipInfo]]:
    prefix = f"{folder}/"
    return sorted(
        (name, info)
        for name, info in members.items()
        if name.startswith(prefix) and not info.is_dir()
    )


def _validate_manifest(
    manifest: object,
    rgb_count: int,
    depth_count: int,
    pose_count: int,
) -> None:
    if not isinstance(manifest, dict):
        raise BundleValidationError("manifest.json must contain an object")

    schema_version = manifest.get("schema_version")
    if schema_version not in {SUPPORTED_SCHEMA_VERSION, "1.0"}:
        raise BundleValidationError(
            f"manifest.json schema_version must be {SUPPORTED_SCHEMA_VERSION} or 1.0"
        )

    frame_count = manifest.get("frame_count")
    if not isinstance(frame_count, int) or frame_count < 0:
        raise BundleValidationError("manifest.json frame_count must be a non-negative integer")
    if frame_count != rgb_count or frame_count != depth_count:
        raise BundleValidationError(
            "manifest.json frame_count must match rgb/ and depth/ frame counts"
        )
    if frame_count != pose_count:
        raise BundleValidationError("poses.json pose count must match manifest frame_count")

    if manifest.get("depth_dtype") != "float16":
        raise BundleValidationError("manifest.json depth_dtype must be float16")


def _normalize_manifest(manifest: dict) -> None:
    """Accept the richer iOS bundle manifest while preserving v1 fields."""

    frame_index = manifest.get("frame_index")
    if isinstance(frame_index, list):
        manifest.setdefault("frame_count", len(frame_index))

        first_rgb = _first_nested_dict(frame_index, "rgb")
        if first_rgb is not None:
            manifest.setdefault(
                "rgb",
                {
                    "width": first_rgb.get("width"),
                    "height": first_rgb.get("height"),
                    "format": "jpeg",
                    "quality": 85,
                },
            )

        first_depth = _first_nested_dict(frame_index, "depth")
        if first_depth is not None:
            manifest.setdefault(
                "depth",
                {
                    "width": first_depth.get("width"),
                    "height": first_depth.get("height"),
                    "dtype": "float16",
                    "smoothed": first_depth.get("is_smoothed"),
                },
            )
            manifest.setdefault("depth_dtype", "float16")

    tracking_summary = manifest.get("tracking_summary")
    if (
        "tracking_state_summary" not in manifest
        and isinstance(tracking_summary, dict)
    ):
        manifest["tracking_state_summary"] = {
            "normal": tracking_summary.get("tracked_frame_count", 0),
            "limited": tracking_summary.get("limited_frame_count", 0),
            "notAvailable": tracking_summary.get("lost_frame_count", 0),
        }

    quick_estimate = manifest.get("on_device_quick_estimate")
    if isinstance(quick_estimate, dict):
        _normalize_quick_estimate(quick_estimate)


def _normalize_quick_estimate(payload: dict) -> None:
    aliases = {
        "volume_m3": "volumeM3",
        "footprint_area_m2": "footprintAreaM2",
        "peak_height_m": "peakHeightM",
        "confidence_score": "confidenceScore",
        "sampled_point_count": "sampledPointCount",
        "camera_path_distance_m": "cameraPathDistanceM",
    }
    for canonical, legacy in aliases.items():
        if canonical not in payload and legacy in payload:
            payload[canonical] = payload[legacy]


def _first_nested_dict(items: list, key: str) -> dict | None:
    for item in items:
        if isinstance(item, dict) and isinstance(item.get(key), dict):
            return item[key]
    return None


def _normalize_poses(poses: list) -> list:
    normalized: list = []
    for pose in poses:
        if not isinstance(pose, dict):
            normalized.append(pose)
            continue
        entry = dict(pose)
        if "timestamp" not in entry and "timestamp_sec" in entry:
            entry["timestamp"] = entry["timestamp_sec"]

        transform = entry.get("transform")
        if isinstance(transform, dict) and "matrix_4x4" in transform:
            entry["transform"] = transform["matrix_4x4"]

        if "lidar_active" not in entry and "lidarActive" in entry:
            entry["lidar_active"] = entry["lidarActive"]

        normalized.append(entry)
    return normalized


def _validate_depth_frames(
    archive: zipfile.ZipFile,
    depth_members: list[tuple[str, zipfile.ZipInfo]],
) -> None:
    for name, info in depth_members:
        if not name.endswith(".npy"):
            continue
        frame = np.load(io.BytesIO(archive.read(info)), allow_pickle=False)
        if frame.dtype != np.float16:
            raise BundleValidationError(f"{name} must contain float16 depth data")


def _extract_members(
    archive: zipfile.ZipFile,
    members: dict[str, zipfile.ZipInfo],
    output_dir: Path,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    for name, info in members.items():
        target = output_dir / name
        if info.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(archive.read(info))
