"""TSDF depth fusion for unpacked Stockpile capture bundles.

Iterates over per-frame RGB + depth + pose data from a
:class:`~stockpile_lidar.ingestion.StockpileCaptureBundle`, integrates each
frame into a scalable TSDF volume, and extracts a metric Open3D point cloud.

Inputs are produced by the iOS capture pipeline:
* Depth maps are stored on disk as raw little-endian Float16 binaries
  (``depth/NNNNNN.f16.bin``) at the resolution declared by
  ``manifest["depth"]``. Existing test fixtures use ``.npy`` files instead;
  both are supported transparently.
* Optional confidence maps (``confidence/NNNNNN.u8.bin``) hold per-pixel
  ``uint8`` values in the range 0..2 (low / medium / high).
* RGB frames are JPEG sRGB images, typically captured at 1920x1080.
* Per-frame poses live in ``poses.json``: ARKit camera-to-world transforms
  (4x4 row-major) and 3x3 row-major intrinsics.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import numpy as np
import open3d as o3d
from PIL import Image

from stockpile_lidar.ingestion import StockpileCaptureBundle


class TSDFFusionError(RuntimeError):
    """Raised when fusion cannot proceed (e.g. malformed pose / missing fields)."""


@dataclass(frozen=True)
class TSDFFusionConfig:
    """Tunables for :func:`fuse_capture_bundle`.

    Defaults are calibrated for iPhone Pro LiDAR captures (typically 256x192
    depth at up to ~5 m of useful range).
    """

    voxel_size: float = 0.02
    sdf_trunc: float = 0.04
    depth_scale: float = 1.0
    depth_trunc: float = 6.0
    confidence_min: int = 1
    rgb_scale_to_depth: bool = True
    enable_post_outlier_filter: bool = True
    outlier_neighbours: int = 20
    outlier_std_ratio: float = 2.0


@dataclass(frozen=True)
class TSDFFusionResult:
    """Outputs of a fusion run."""

    point_cloud: o3d.geometry.PointCloud
    fused_frame_count: int
    skipped_frame_count: int
    voxel_size: float
    sdf_trunc: float


def fuse_capture_bundle(
    bundle: StockpileCaptureBundle,
    config: TSDFFusionConfig | None = None,
) -> TSDFFusionResult:
    """Fuse all frames in ``bundle`` into a single metric Open3D point cloud.

    Frames are skipped (not fused) when:
      * ``tracking_state != "normal"`` (only high-quality poses contribute),
      * ``lidar_active`` is ``False``,
      * the RGB or depth file is missing on disk,
      * the depth payload cannot be decoded,
      * pose ``transform`` / ``intrinsics`` is malformed.

    Returns the fused cloud (possibly empty) along with counts.
    """

    cfg = config or TSDFFusionConfig()
    depth_w, depth_h = _depth_dimensions(bundle.manifest)
    rgb_w, rgb_h = _rgb_dimensions(bundle.manifest)
    confidence_dir = bundle.root / "confidence"

    tsdf = o3d.pipelines.integration.ScalableTSDFVolume(
        voxel_length=cfg.voxel_size,
        sdf_trunc=cfg.sdf_trunc,
        color_type=o3d.pipelines.integration.TSDFVolumeColorType.RGB8,
    )

    fused = 0
    skipped = 0

    for index, pose in enumerate(bundle.poses):
        rgb_path = _frame_path(bundle.rgb_frames, index)
        depth_path = _frame_path(bundle.depth_frames, index)

        if rgb_path is None or depth_path is None:
            skipped += 1
            continue
        if not _is_pose_usable(pose):
            skipped += 1
            continue

        try:
            depth_array = _load_depth_frame(depth_path, depth_w, depth_h)
        except (ValueError, OSError):
            skipped += 1
            continue

        confidence_array = _load_confidence_frame(
            confidence_dir, index, depth_w, depth_h
        )
        if confidence_array is not None:
            depth_array = depth_array.copy()
            depth_array[confidence_array < cfg.confidence_min] = 0.0

        try:
            color_array = _load_color_frame(rgb_path, depth_w, depth_h, cfg)
        except (ValueError, OSError):
            skipped += 1
            continue

        try:
            intrinsic = _build_intrinsic(pose, depth_w, depth_h, rgb_w, rgb_h)
            extrinsic = _build_extrinsic(pose)
        except TSDFFusionError:
            skipped += 1
            continue

        rgbd = o3d.geometry.RGBDImage.create_from_color_and_depth(
            o3d.geometry.Image(color_array),
            o3d.geometry.Image(depth_array),
            depth_scale=cfg.depth_scale,
            depth_trunc=cfg.depth_trunc,
            convert_rgb_to_intensity=False,
        )

        tsdf.integrate(rgbd, intrinsic, extrinsic)
        fused += 1

    if fused == 0:
        cloud = o3d.geometry.PointCloud()
    else:
        cloud = tsdf.extract_point_cloud()
        if cfg.enable_post_outlier_filter and len(cloud.points) > 0:
            cloud, _ = cloud.remove_statistical_outlier(
                nb_neighbors=cfg.outlier_neighbours,
                std_ratio=cfg.outlier_std_ratio,
            )

    return TSDFFusionResult(
        point_cloud=cloud,
        fused_frame_count=fused,
        skipped_frame_count=skipped,
        voxel_size=cfg.voxel_size,
        sdf_trunc=cfg.sdf_trunc,
    )


# ---------------------------------------------------------------------------
# Frame loading helpers
# ---------------------------------------------------------------------------


def _frame_path(frames: Iterable[Path], index: int) -> Path | None:
    frame_list = list(frames)
    if index >= len(frame_list):
        return None
    candidate = frame_list[index]
    if not candidate.is_file():
        return None
    return candidate


def _load_depth_frame(path: Path, width: int, height: int) -> np.ndarray:
    """Load a depth frame as a ``float32`` array shaped ``(height, width)``."""

    suffix = path.suffix.lower()
    if suffix == ".npy":
        depth = np.load(path, allow_pickle=False)
        if depth.dtype != np.float16 and depth.dtype != np.float32:
            raise ValueError(f"depth frame {path.name} has unsupported dtype {depth.dtype}")
    else:
        raw = path.read_bytes()
        expected = width * height * np.dtype(np.float16).itemsize
        if len(raw) != expected:
            raise ValueError(
                f"depth frame {path.name} has {len(raw)} bytes, expected {expected}"
            )
        depth = np.frombuffer(raw, dtype=np.float16).reshape((height, width))

    if depth.shape != (height, width):
        raise ValueError(
            f"depth frame {path.name} has shape {depth.shape}, expected {(height, width)}"
        )
    depth32 = depth.astype(np.float32, copy=False)
    # Drop NaNs / negatives so Open3D treats them as missing samples.
    return np.where(np.isfinite(depth32) & (depth32 > 0), depth32, 0.0)


def _load_confidence_frame(
    confidence_dir: Path, index: int, width: int, height: int
) -> np.ndarray | None:
    if not confidence_dir.is_dir():
        return None
    candidate = _find_confidence_file(confidence_dir, index)
    if candidate is None:
        return None
    raw = candidate.read_bytes()
    expected = width * height
    if len(raw) != expected:
        return None
    return np.frombuffer(raw, dtype=np.uint8).reshape((height, width))


def _find_confidence_file(confidence_dir: Path, index: int) -> Path | None:
    # Match the most common iOS layouts: zero-padded 6 digits with .u8.bin
    # extension, plus a couple of fallbacks for flexibility.
    patterns = (
        f"{index:06d}.u8.bin",
        f"{index:06d}.bin",
        f"frame_{index:06d}.u8.bin",
    )
    for name in patterns:
        candidate = confidence_dir / name
        if candidate.is_file():
            return candidate
    # Fallback: pick the i-th sorted entry.
    sorted_entries = sorted(p for p in confidence_dir.iterdir() if p.is_file())
    if 0 <= index < len(sorted_entries):
        return sorted_entries[index]
    return None


def _load_color_frame(
    path: Path, depth_w: int, depth_h: int, cfg: TSDFFusionConfig
) -> np.ndarray:
    with Image.open(path) as img:
        img = img.convert("RGB")
        if cfg.rgb_scale_to_depth and img.size != (depth_w, depth_h):
            img = img.resize((depth_w, depth_h), Image.BILINEAR)
        elif img.size != (depth_w, depth_h):
            # Open3D requires colour and depth shapes to match exactly.
            img = img.resize((depth_w, depth_h), Image.BILINEAR)
        return np.ascontiguousarray(np.asarray(img, dtype=np.uint8))


# ---------------------------------------------------------------------------
# Pose helpers
# ---------------------------------------------------------------------------


def _is_pose_usable(pose: Any) -> bool:
    if not isinstance(pose, dict):
        return False
    tracking_state = pose.get("tracking_state")
    if tracking_state is not None and tracking_state != "normal":
        return False
    lidar_active = pose.get("lidar_active")
    if lidar_active is False:
        return False
    return True


def _build_intrinsic(
    pose: dict,
    depth_w: int,
    depth_h: int,
    rgb_w: int,
    rgb_h: int,
) -> o3d.camera.PinholeCameraIntrinsic:
    raw = pose.get("intrinsics")
    matrix = _coerce_3x3(raw)
    fx, fy = float(matrix[0, 0]), float(matrix[1, 1])
    cx, cy = float(matrix[0, 2]), float(matrix[1, 2])

    # If the manifest declares an RGB resolution that differs from depth, the
    # ARKit intrinsics are usually expressed in image (RGB) pixels. Re-scale to
    # depth pixels because Open3D integrates against the depth resolution.
    if rgb_w > 0 and rgb_h > 0 and (rgb_w != depth_w or rgb_h != depth_h):
        sx = depth_w / rgb_w
        sy = depth_h / rgb_h
        fx *= sx
        fy *= sy
        cx *= sx
        cy *= sy

    if fx <= 0 or fy <= 0:
        raise TSDFFusionError("intrinsics fx/fy must be positive")

    return o3d.camera.PinholeCameraIntrinsic(
        width=depth_w,
        height=depth_h,
        fx=fx,
        fy=fy,
        cx=cx,
        cy=cy,
    )


def _build_extrinsic(pose: dict) -> np.ndarray:
    raw = pose.get("transform")
    matrix = _coerce_4x4(raw)
    try:
        return np.linalg.inv(matrix)
    except np.linalg.LinAlgError as exc:
        raise TSDFFusionError("pose transform is singular") from exc


def _coerce_3x3(value: Any) -> np.ndarray:
    array = _coerce_matrix(value)
    if array.size != 9:
        raise TSDFFusionError(
            f"expected 9 intrinsics values, got {array.size}"
        )
    return array.reshape((3, 3))


def _coerce_4x4(value: Any) -> np.ndarray:
    array = _coerce_matrix(value)
    if array.size != 16:
        raise TSDFFusionError(
            f"expected 16 transform values, got {array.size}"
        )
    return array.reshape((4, 4))


def _coerce_matrix(value: Any) -> np.ndarray:
    if value is None:
        raise TSDFFusionError("pose is missing matrix data")
    try:
        if isinstance(value, np.ndarray):
            return np.asarray(value, dtype=np.float64).reshape(-1)
        if isinstance(value, (list, tuple)):
            flat: list[float] = []
            for item in value:
                if isinstance(item, (list, tuple, np.ndarray)):
                    flat.extend(float(x) for x in np.asarray(item).reshape(-1))
                else:
                    flat.append(float(item))
            return np.asarray(flat, dtype=np.float64)
    except (TypeError, ValueError) as exc:
        raise TSDFFusionError("pose matrix has non-numeric entries") from exc
    raise TSDFFusionError("pose matrix has unsupported type")


# ---------------------------------------------------------------------------
# Manifest helpers
# ---------------------------------------------------------------------------


def _depth_dimensions(manifest: Any) -> tuple[int, int]:
    section = _section(manifest, "depth")
    return _dimensions_or_default(section, default=(256, 192))


def _rgb_dimensions(manifest: Any) -> tuple[int, int]:
    section = _section(manifest, "rgb")
    # Defaulting RGB to the depth size is safe when no override is present —
    # the intrinsics rescaling step is a no-op when sizes match.
    return _dimensions_or_default(section, default=(0, 0))


def _section(manifest: Any, key: str) -> dict:
    if isinstance(manifest, dict):
        section = manifest.get(key)
        if isinstance(section, dict):
            return section
    return {}


def _dimensions_or_default(section: dict, *, default: tuple[int, int]) -> tuple[int, int]:
    width = _coerce_positive_int(section.get("width"))
    height = _coerce_positive_int(section.get("height"))
    if width is None or height is None:
        return default
    return width, height


def _coerce_positive_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int) and value > 0:
        return value
    if isinstance(value, float) and value > 0 and value.is_integer():
        return int(value)
    return None
