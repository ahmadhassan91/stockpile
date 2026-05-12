"""Backend-side depth fusion for Stockpile LiDAR captures."""

from dataclasses import dataclass

import numpy as np

try:
    from .tsdf_fusion import (
        TSDFFusionConfig,
        TSDFFusionError,
        TSDFFusionResult,
        fuse_capture_bundle,
    )
except ImportError:
    from stockpile_lidar.measurement import CameraIntrinsics, fuse_depth_frames

    class TSDFFusionError(RuntimeError):
        """Raised when Open3D TSDF fusion is unavailable."""

    @dataclass(frozen=True)
    class TSDFFusionConfig:  # type: ignore[no-redef]
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
    class _NumpyPointCloud:
        points: np.ndarray

    @dataclass(frozen=True)
    class TSDFFusionResult:  # type: ignore[no-redef]
        point_cloud: _NumpyPointCloud
        fused_frame_count: int
        skipped_frame_count: int
        voxel_size: float
        sdf_trunc: float

    def fuse_capture_bundle(bundle, config=None):  # type: ignore[no-redef]
        """Fallback fusion path for environments without importable Open3D."""

        cfg = config or TSDFFusionConfig()
        depth_w, depth_h = _depth_dimensions(bundle.manifest)
        rgb_w, rgb_h = _rgb_dimensions(bundle.manifest)
        depths = []
        poses = []
        intrinsics = []
        confidences = []
        skipped = 0
        for index, pose in enumerate(bundle.poses):
            if not _is_pose_usable(pose):
                skipped += 1
                continue
            if index >= len(bundle.depth_frames):
                skipped += 1
                continue
            try:
                depth = _load_depth_frame(bundle.depth_frames[index], depth_w, depth_h)
                intrinsic = _build_intrinsic(pose, depth_w, depth_h, rgb_w, rgb_h)
            except (OSError, TypeError, ValueError):
                skipped += 1
                continue
            depths.append(depth)
            poses.append(_coerce_4x4(pose.get("transform")))
            intrinsics.append(intrinsic)
            confidences.append(
                _load_confidence_frame(
                    bundle.root / "confidence",
                    index,
                    depth_w,
                    depth_h,
                )
            )

        result = fuse_depth_frames(
            depths,
            poses,
            intrinsics,
            confidences=confidences,
            config=_measurement_config(cfg),
        )
        return TSDFFusionResult(
            point_cloud=_NumpyPointCloud(result.points),
            fused_frame_count=result.frame_count,
            skipped_frame_count=skipped + result.skipped_frame_count,
            voxel_size=cfg.voxel_size,
            sdf_trunc=cfg.sdf_trunc,
        )

    def _measurement_config(cfg):
        from stockpile_lidar.measurement import MeasurementConfig

        return MeasurementConfig(
            max_depth_m=cfg.depth_trunc,
            confidence_min=cfg.confidence_min,
        )

    def _is_pose_usable(pose):
        if not isinstance(pose, dict):
            return False
        tracking_state = pose.get("tracking_state")
        if tracking_state is not None and tracking_state != "normal":
            return False
        return pose.get("lidar_active") is not False

    def _load_depth_frame(path, width, height):
        if path.suffix.lower() == ".npy":
            depth = np.load(path, allow_pickle=False)
        else:
            raw = path.read_bytes()
            expected = width * height * np.dtype(np.float16).itemsize
            if len(raw) != expected:
                raise ValueError("depth frame byte count mismatch")
            depth = np.frombuffer(raw, dtype=np.float16).reshape((height, width))
        if depth.shape != (height, width):
            raise ValueError("depth frame shape mismatch")
        depth32 = depth.astype(np.float32, copy=False)
        return np.where(np.isfinite(depth32) & (depth32 > 0), depth32, 0.0)

    def _load_confidence_frame(confidence_dir, index, width, height):
        if not confidence_dir.is_dir():
            return None
        candidates = [
            confidence_dir / f"{index:06d}.u8.bin",
            confidence_dir / f"{index:06d}.bin",
            confidence_dir / f"frame_{index:06d}.u8.bin",
        ]
        path = next((candidate for candidate in candidates if candidate.is_file()), None)
        if path is None:
            files = sorted(p for p in confidence_dir.iterdir() if p.is_file())
            path = files[index] if index < len(files) else None
        if path is None:
            return None
        raw = path.read_bytes()
        if len(raw) != width * height:
            return None
        return np.frombuffer(raw, dtype=np.uint8).reshape((height, width))

    def _build_intrinsic(pose, depth_w, depth_h, rgb_w, rgb_h):
        matrix = _coerce_3x3(pose.get("intrinsics"))
        fx, fy = float(matrix[0, 0]), float(matrix[1, 1])
        cx, cy = float(matrix[0, 2]), float(matrix[1, 2])
        if rgb_w > 0 and rgb_h > 0 and (rgb_w != depth_w or rgb_h != depth_h):
            fx *= depth_w / rgb_w
            fy *= depth_h / rgb_h
            cx *= depth_w / rgb_w
            cy *= depth_h / rgb_h
        return CameraIntrinsics(
            fx=fx,
            fy=fy,
            cx=cx,
            cy=cy,
            width=depth_w,
            height=depth_h,
        )

    def _coerce_3x3(value):
        array = _coerce_matrix(value)
        if array.size != 9:
            raise ValueError("expected 9 intrinsics values")
        return array.reshape((3, 3))

    def _coerce_4x4(value):
        array = _coerce_matrix(value)
        if array.size != 16:
            raise ValueError("expected 16 transform values")
        return array.reshape((4, 4))

    def _coerce_matrix(value):
        if value is None:
            raise ValueError("missing matrix")
        if isinstance(value, np.ndarray):
            return np.asarray(value, dtype=np.float64).reshape(-1)
        flat = []
        for item in value:
            if isinstance(item, (list, tuple, np.ndarray)):
                flat.extend(float(x) for x in np.asarray(item).reshape(-1))
            else:
                flat.append(float(item))
        return np.asarray(flat, dtype=np.float64)

    def _depth_dimensions(manifest):
        return _dimensions_or_default(_section(manifest, "depth"), default=(256, 192))

    def _rgb_dimensions(manifest):
        return _dimensions_or_default(_section(manifest, "rgb"), default=(0, 0))

    def _section(manifest, key):
        section = manifest.get(key) if isinstance(manifest, dict) else None
        return section if isinstance(section, dict) else {}

    def _dimensions_or_default(section, *, default):
        width = section.get("width")
        height = section.get("height")
        if (
            isinstance(width, int)
            and isinstance(height, int)
            and width > 0
            and height > 0
        ):
            return width, height
        return default

__all__ = [
    "TSDFFusionConfig",
    "TSDFFusionError",
    "TSDFFusionResult",
    "fuse_capture_bundle",
]
