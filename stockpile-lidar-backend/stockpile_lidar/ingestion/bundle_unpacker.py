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
        return poses_payload
    if isinstance(poses_payload, dict) and isinstance(poses_payload.get("poses"), list):
        return poses_payload["poses"]
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
    if schema_version != SUPPORTED_SCHEMA_VERSION:
        raise BundleValidationError(
            f"manifest.json schema_version must be {SUPPORTED_SCHEMA_VERSION}"
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
