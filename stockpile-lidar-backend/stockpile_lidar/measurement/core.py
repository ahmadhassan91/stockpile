"""NumPy-first LiDAR measurement core.

The functions in this module intentionally avoid importing Open3D at module
load time. Callers can pass Open3D point clouds when the package is available,
but depth unprojection, filtering, ground estimation, and volume integration
all work with plain NumPy arrays.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, Sequence

import numpy as np


@dataclass(frozen=True)
class CameraIntrinsics:
    """Pinhole camera intrinsics in depth-image pixel coordinates."""

    fx: float
    fy: float
    cx: float
    cy: float
    width: int | None = None
    height: int | None = None

    @classmethod
    def from_matrix(
        cls,
        matrix: Sequence[float] | np.ndarray,
        *,
        width: int | None = None,
        height: int | None = None,
    ) -> "CameraIntrinsics":
        values = np.asarray(matrix, dtype=float).reshape(-1)
        if values.size != 9:
            raise ValueError(f"expected 9 intrinsics values, got {values.size}")
        mat = values.reshape((3, 3))
        return cls(
            fx=float(mat[0, 0]),
            fy=float(mat[1, 1]),
            cx=float(mat[0, 2]),
            cy=float(mat[1, 2]),
            width=width,
            height=height,
        )


@dataclass(frozen=True)
class GroundPlane:
    """Plane represented as ``normal.dot(point) + offset == 0``."""

    normal: tuple[float, float, float] = (0.0, 0.0, 1.0)
    offset: float = 0.0
    source: str = "estimated"
    inlier_ratio: float | None = None

    @classmethod
    def from_ground_z(cls, ground_z: float, *, source: str = "prior") -> "GroundPlane":
        return cls(normal=(0.0, 0.0, 1.0), offset=-float(ground_z), source=source)

    @property
    def ground_z(self) -> float:
        normal = np.asarray(self.normal, dtype=float)
        if abs(float(normal[2])) < 1e-9:
            return 0.0
        return float(-self.offset / normal[2])


@dataclass(frozen=True)
class MeasurementConfig:
    """Tunables for backend measurement."""

    min_depth_m: float = 0.05
    max_depth_m: float = 6.0
    confidence_min: int = 1
    sample_stride: int = 1
    ground_distance_threshold_m: float = 0.025
    ground_ransac_iterations: int = 160
    ground_low_percentile: float = 5.0
    above_ground_threshold_m: float = 0.03
    grid_resolution_m: float = 0.10
    hull_min_points: int = 4
    random_seed: int = 31


@dataclass(frozen=True)
class DepthFusionResult:
    points: np.ndarray
    frame_count: int
    skipped_frame_count: int
    warnings: tuple[str, ...] = ()


@dataclass(frozen=True)
class MeasurementDiagnostics:
    point_count: int
    pile_point_count: int
    ground_z: float
    grid_area_m2: float
    volume_method: str
    warnings: tuple[str, ...] = ()
    ground_inlier_ratio: float | None = None
    hull_volume_m3: float | None = None


@dataclass(frozen=True)
class MeasurementResult:
    volume_m3: float
    ground_plane: GroundPlane
    grid_area_m2: float
    grid_resolution_m: float
    method: str
    diagnostics: MeasurementDiagnostics


def unproject_depth(
    depth: np.ndarray,
    pose: Sequence[float] | np.ndarray,
    intrinsics: CameraIntrinsics | Sequence[float] | np.ndarray,
    *,
    confidence: np.ndarray | None = None,
    config: MeasurementConfig | None = None,
) -> np.ndarray:
    """Convert one depth map into world-space point samples.

    ``pose`` is expected to be an ARKit-style camera-to-world 4x4 transform.
    Invalid, out-of-range, and low-confidence samples are removed before
    unprojection.
    """

    cfg = config or MeasurementConfig()
    depth_array = np.asarray(depth, dtype=np.float32)
    if depth_array.ndim != 2:
        raise ValueError("depth must be a 2D array")

    intr = _coerce_intrinsics(intrinsics, depth_array.shape[1], depth_array.shape[0])
    if intr.fx <= 0 or intr.fy <= 0:
        raise ValueError("intrinsics fx/fy must be positive")

    transform = _coerce_pose(pose)
    stride = max(1, int(cfg.sample_stride))
    rows = np.arange(0, depth_array.shape[0], stride)
    cols = np.arange(0, depth_array.shape[1], stride)
    uu, vv = np.meshgrid(cols, rows)
    sampled_depth = depth_array[vv, uu]

    mask = (
        np.isfinite(sampled_depth)
        & (sampled_depth >= cfg.min_depth_m)
        & (sampled_depth <= cfg.max_depth_m)
    )
    if confidence is not None:
        conf = np.asarray(confidence)
        if conf.shape != depth_array.shape:
            raise ValueError("confidence shape must match depth shape")
        mask &= conf[vv, uu] >= cfg.confidence_min

    if not np.any(mask):
        return np.empty((0, 3), dtype=np.float64)

    z = sampled_depth[mask].astype(np.float64)
    x = (uu[mask].astype(np.float64) - intr.cx) * z / intr.fx
    y = (vv[mask].astype(np.float64) - intr.cy) * z / intr.fy
    camera_points = np.column_stack([x, y, z, np.ones_like(z)])
    world = (transform @ camera_points.T).T[:, :3]
    return np.ascontiguousarray(world, dtype=np.float64)


def fuse_depth_frames(
    depth_frames: Iterable[np.ndarray],
    poses: Iterable[Sequence[float] | np.ndarray],
    intrinsics: CameraIntrinsics | Sequence[float] | np.ndarray | Iterable[Any],
    *,
    confidences: Iterable[np.ndarray | None] | None = None,
    config: MeasurementConfig | None = None,
) -> DepthFusionResult:
    """Fuse several depth frames by unprojecting and concatenating samples."""

    cfg = config or MeasurementConfig()
    depth_list = list(depth_frames)
    pose_list = list(poses)
    confidence_list = (
        list(confidences)
        if confidences is not None
        else [None for _ in depth_list]
    )
    intrinsics_list = _expand_intrinsics(intrinsics, len(depth_list))

    points: list[np.ndarray] = []
    skipped = 0
    warnings: list[str] = []
    for index, depth in enumerate(depth_list):
        if index >= len(pose_list) or index >= len(intrinsics_list):
            skipped += 1
            warnings.append(f"frame {index} skipped: missing pose or intrinsics")
            continue
        try:
            frame_points = unproject_depth(
                depth,
                pose_list[index],
                intrinsics_list[index],
                confidence=(
                    confidence_list[index] if index < len(confidence_list) else None
                ),
                config=cfg,
            )
        except (TypeError, ValueError, np.linalg.LinAlgError) as exc:
            skipped += 1
            warnings.append(f"frame {index} skipped: {exc}")
            continue
        if frame_points.size == 0:
            warnings.append(f"frame {index} produced no usable depth samples")
        points.append(frame_points)

    populated_frames = [frame for frame in points if len(frame) > 0]
    fused = (
        np.vstack(populated_frames)
        if populated_frames
        else np.empty((0, 3), dtype=np.float64)
    )
    return DepthFusionResult(
        points=fused,
        frame_count=len(depth_list) - skipped,
        skipped_frame_count=skipped,
        warnings=tuple(warnings),
    )


def estimate_ground_plane(
    points: Any,
    *,
    ground_prior: GroundPlane | float | None = None,
    config: MeasurementConfig | None = None,
) -> GroundPlane:
    """Estimate a ground plane or coerce an explicit prior."""

    cfg = config or MeasurementConfig()
    if isinstance(ground_prior, GroundPlane):
        return ground_prior
    if ground_prior is not None:
        return GroundPlane.from_ground_z(float(ground_prior), source="prior")

    pts = _coerce_points(points)
    if len(pts) == 0:
        return GroundPlane.from_ground_z(0.0, source="empty_fallback")
    if len(pts) < 3:
        return GroundPlane.from_ground_z(
            float(np.min(pts[:, 2])),
            source="min_z_fallback",
        )

    rng = np.random.default_rng(cfg.random_seed)
    best_normal: np.ndarray | None = None
    best_offset = 0.0
    best_count = -1
    iterations = max(1, int(cfg.ground_ransac_iterations))

    for _ in range(iterations):
        sample_idx = rng.choice(len(pts), size=3, replace=False)
        sample = pts[sample_idx]
        normal = np.cross(sample[1] - sample[0], sample[2] - sample[0])
        norm = float(np.linalg.norm(normal))
        if norm < 1e-9:
            continue
        normal = normal / norm
        if normal[2] < 0:
            normal = -normal
        offset = -float(np.dot(normal, sample[0]))
        distances = np.abs(pts @ normal + offset)
        inliers = int(np.count_nonzero(distances <= cfg.ground_distance_threshold_m))
        if inliers > best_count:
            best_count = inliers
            best_normal = normal
            best_offset = offset

    if best_normal is None or best_count < 3:
        ground_z = float(np.percentile(pts[:, 2], cfg.ground_low_percentile))
        return GroundPlane.from_ground_z(ground_z, source="percentile_fallback")

    distances = np.abs(pts @ best_normal + best_offset)
    inlier_mask = distances <= cfg.ground_distance_threshold_m
    inliers = pts[inlier_mask]
    if len(inliers) >= 3:
        centroid = np.mean(inliers, axis=0)
        _, _, vh = np.linalg.svd(inliers - centroid, full_matrices=False)
        normal = vh[-1]
        if normal[2] < 0:
            normal = -normal
        best_normal = normal / max(float(np.linalg.norm(normal)), 1e-9)
        best_offset = -float(np.dot(best_normal, centroid))

    return GroundPlane(
        normal=tuple(float(x) for x in best_normal),
        offset=float(best_offset),
        source="ransac",
        inlier_ratio=float(best_count / len(pts)),
    )


def compute_stockpile_measurement(
    points: Any,
    *,
    ground_prior: GroundPlane | float | None = None,
    config: MeasurementConfig | None = None,
) -> MeasurementResult:
    """Compute stockpile volume and diagnostics from world-space samples."""

    cfg = config or MeasurementConfig()
    pts = _coerce_points(points)
    warnings: list[str] = []
    if len(pts) == 0:
        warnings.append("no points available for measurement")
        ground = estimate_ground_plane(pts, ground_prior=ground_prior, config=cfg)
        diagnostics = MeasurementDiagnostics(
            point_count=0,
            pile_point_count=0,
            ground_z=ground.ground_z,
            grid_area_m2=0.0,
            volume_method="grid_integration",
            warnings=tuple(warnings),
            ground_inlier_ratio=ground.inlier_ratio,
        )
        return MeasurementResult(
            volume_m3=0.0,
            ground_plane=ground,
            grid_area_m2=0.0,
            grid_resolution_m=cfg.grid_resolution_m,
            method="grid_integration",
            diagnostics=diagnostics,
        )

    ground = estimate_ground_plane(pts, ground_prior=ground_prior, config=cfg)
    normal = np.asarray(ground.normal, dtype=float)
    normal = normal / max(float(np.linalg.norm(normal)), 1e-9)
    signed_height = pts @ normal + ground.offset
    pile_mask = signed_height > cfg.above_ground_threshold_m
    pile_points = pts[pile_mask]
    pile_heights = signed_height[pile_mask]

    if len(pile_points) == 0:
        warnings.append("no points above ground threshold")
        grid_volume = 0.0
        grid_area = 0.0
    else:
        grid_volume, grid_area = _grid_integrate(
            pile_points[:, :2],
            pile_heights,
            cfg.grid_resolution_m,
        )

    hull_volume = _convex_hull_volume(pile_points)
    if hull_volume is None and len(pile_points) >= cfg.hull_min_points:
        warnings.append("convex hull volume unavailable")

    diagnostics = MeasurementDiagnostics(
        point_count=int(len(pts)),
        pile_point_count=int(len(pile_points)),
        ground_z=ground.ground_z,
        grid_area_m2=float(grid_area),
        volume_method="grid_integration",
        warnings=tuple(warnings),
        ground_inlier_ratio=ground.inlier_ratio,
        hull_volume_m3=hull_volume,
    )
    return MeasurementResult(
        volume_m3=float(grid_volume),
        ground_plane=ground,
        grid_area_m2=float(grid_area),
        grid_resolution_m=cfg.grid_resolution_m,
        method="grid_integration",
        diagnostics=diagnostics,
    )


def points_from_open3d(point_cloud: Any) -> np.ndarray:
    """Return ``Nx3`` points from an Open3D-like point cloud."""

    return _coerce_points(point_cloud)


def _grid_integrate(
    points_xy: np.ndarray,
    heights: np.ndarray,
    resolution: float,
) -> tuple[float, float]:
    if len(points_xy) == 0:
        return 0.0, 0.0
    cell_size = max(float(resolution), 1e-6)
    origin = np.min(points_xy, axis=0)
    ij = np.floor(((points_xy - origin) / cell_size) + 1e-9).astype(np.int64)
    cell_heights: dict[tuple[int, int], float] = {}
    for cell, height in zip(ij, heights):
        key = (int(cell[0]), int(cell[1]))
        cell_heights[key] = max(cell_heights.get(key, 0.0), float(height))
    area_per_cell = cell_size * cell_size
    volume = sum(cell_heights.values()) * area_per_cell
    area = len(cell_heights) * area_per_cell
    return float(volume), float(area)


def _convex_hull_volume(points: np.ndarray) -> float | None:
    if len(points) < 4:
        return None
    try:
        from scipy.spatial import ConvexHull

        hull = ConvexHull(points)
    except Exception:
        return None
    return float(hull.volume)


def _coerce_points(points: Any) -> np.ndarray:
    if hasattr(points, "points"):
        points = points.points
    array = np.asarray(points, dtype=np.float64)
    if array.size == 0:
        return np.empty((0, 3), dtype=np.float64)
    array = array.reshape((-1, 3))
    finite = np.all(np.isfinite(array), axis=1)
    return np.ascontiguousarray(array[finite], dtype=np.float64)


def _coerce_pose(pose: Sequence[float] | np.ndarray) -> np.ndarray:
    matrix = np.asarray(pose, dtype=np.float64)
    if matrix.size != 16:
        raise ValueError(f"expected 16 pose values, got {matrix.size}")
    return matrix.reshape((4, 4))


def _coerce_intrinsics(
    intrinsics: CameraIntrinsics | Sequence[float] | np.ndarray,
    width: int,
    height: int,
) -> CameraIntrinsics:
    if isinstance(intrinsics, CameraIntrinsics):
        return intrinsics
    return CameraIntrinsics.from_matrix(intrinsics, width=width, height=height)


def _expand_intrinsics(intrinsics: Any, count: int) -> list[Any]:
    if isinstance(intrinsics, CameraIntrinsics):
        return [intrinsics for _ in range(count)]
    if isinstance(intrinsics, np.ndarray):
        if intrinsics.size == 9:
            return [intrinsics for _ in range(count)]
        return list(intrinsics)
    if isinstance(intrinsics, Sequence) and len(intrinsics) == 9:
        return [intrinsics for _ in range(count)]
    return list(intrinsics)
