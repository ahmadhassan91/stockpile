from __future__ import annotations

from dataclasses import dataclass
import io
import json
from pathlib import Path, PurePosixPath
import zipfile

import numpy as np


SUPPORTED_SCHEMA_VERSION = 1
SUPPORTED_MATERIAL_CODES = frozenset(
    {"sand", "gravel", "backfill", "aggregate", "soil", "other"}
)
MIN_DENSITY_KG_PER_M3 = 300
MAX_DENSITY_KG_PER_M3 = 3000


class BundleValidationError(ValueError):
    """Raised when a .stockpilecapture bundle does not match the ingest spec."""


@dataclass(frozen=True)
class StockpileCaptureBundle:
    root: Path
    manifest: dict
    poses: list
    rgb_frames: list[Path]
    depth_frames: list[Path]
    validation_warnings: list[str]


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

        validation_warnings = _validate_manifest(
            manifest,
            len(rgb_members),
            len(depth_members),
            len(poses),
        )
        _validate_depth_frames(archive, depth_members)
        _extract_members(archive, members, output_dir)

    return StockpileCaptureBundle(
        root=output_dir,
        manifest=manifest,
        poses=poses,
        rgb_frames=[output_dir / name for name, _ in rgb_members],
        depth_frames=[output_dir / name for name, _ in depth_members],
        validation_warnings=validation_warnings,
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
) -> list[str]:
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

    return _validate_material_fields(manifest)


def _validate_material_fields(manifest: dict) -> list[str]:
    material_code = manifest.get("material_code")
    if not isinstance(material_code, str) or not material_code.strip():
        raise BundleValidationError(
            "manifest.json material_code is required and must be user-selected"
        )

    normalized_material_code = material_code.strip().lower()
    if material_code != normalized_material_code:
        manifest["material_code"] = normalized_material_code

    if normalized_material_code not in SUPPORTED_MATERIAL_CODES:
        supported = ", ".join(sorted(SUPPORTED_MATERIAL_CODES))
        raise BundleValidationError(
            f"manifest.json material_code must be one of: {supported}"
        )

    density = manifest.get("density_kg_per_m3")
    if isinstance(density, bool) or not isinstance(density, int):
        raise BundleValidationError("manifest.json density_kg_per_m3 must be an integer")
    if density < MIN_DENSITY_KG_PER_M3 or density > MAX_DENSITY_KG_PER_M3:
        raise BundleValidationError(
            "manifest.json density_kg_per_m3 must be between "
            f"{MIN_DENSITY_KG_PER_M3} and {MAX_DENSITY_KG_PER_M3}"
        )

    return _validate_vision_material_suggestion(manifest, normalized_material_code)


def _validate_vision_material_suggestion(
    manifest: dict,
    material_code: str,
) -> list[str]:
    suggestion = manifest.get("vision_material_suggestion")
    if suggestion is None:
        return []
    if not isinstance(suggestion, dict):
        raise BundleValidationError("manifest.json vision_material_suggestion must be an object")

    warnings: list[str] = []
    suggested_code = suggestion.get("suggested_material_code")
    if not isinstance(suggested_code, str) or not suggested_code.strip():
        warnings.append(
            "manifest.json vision_material_suggestion.suggested_material_code is missing"
        )
        return warnings

    normalized_suggested_code = suggested_code.strip().lower()
    if suggested_code != normalized_suggested_code:
        suggestion["suggested_material_code"] = normalized_suggested_code

    if normalized_suggested_code not in SUPPORTED_MATERIAL_CODES:
        warnings.append(
            "manifest.json vision_material_suggestion.suggested_material_code "
            f"is unknown: {normalized_suggested_code}"
        )
    elif normalized_suggested_code != material_code:
        warnings.append(
            "manifest.json vision_material_suggestion differs from material_code; "
            "user-selected material_code remains authoritative"
        )
    return warnings


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
            "normal": _first_present(tracking_summary, "tracked_frame_count", "trackedFrameCount"),
            "limited": _first_present(tracking_summary, "limited_frame_count", "limitedFrameCount"),
            "notAvailable": _first_present(tracking_summary, "lost_frame_count", "lostFrameCount"),
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


def _first_present(payload: dict, *keys: str, default=0):
    for key in keys:
        if key in payload:
            return payload[key]
    return default


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
