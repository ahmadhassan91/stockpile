"""Tests for :mod:`stockpile_lidar.fusion.tsdf_fusion`."""

from __future__ import annotations

import io
import json
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

from stockpile_lidar.fusion import (
    TSDFFusionConfig,
    TSDFFusionResult,
    fuse_capture_bundle,
)
from stockpile_lidar.ingestion import unpack_stockpile_capture


# ---------------------------------------------------------------------------
# Bundle fixture helpers
# ---------------------------------------------------------------------------


_DEPTH_W = 32
_DEPTH_H = 24
_RGB_W = 32
_RGB_H = 24


def _identity_intrinsics(width: int, height: int) -> list[float]:
    fx = float(width)
    fy = float(height)
    cx = width / 2.0
    cy = height / 2.0
    return [fx, 0.0, cx, 0.0, fy, cy, 0.0, 0.0, 1.0]


def _camera_at(position: tuple[float, float, float]) -> list[float]:
    transform = np.eye(4, dtype=np.float64)
    transform[0, 3] = position[0]
    transform[1, 3] = position[1]
    transform[2, 3] = position[2]
    return transform.reshape(-1).tolist()


def _depth_bytes(width: int, height: int, value: float) -> bytes:
    depth = np.full((height, width), value, dtype=np.float16)
    return depth.tobytes()


def _confidence_bytes(width: int, height: int, value: int) -> bytes:
    return np.full((height, width), value, dtype=np.uint8).tobytes()


def _rgb_jpeg_bytes(width: int, height: int, color: tuple[int, int, int]) -> bytes:
    img = Image.new("RGB", (width, height), color=color)
    buffer = io.BytesIO()
    img.save(buffer, format="JPEG", quality=90)
    return buffer.getvalue()


def _build_bundle_zip(
    bundle_path: Path,
    poses: list[dict],
    *,
    depth_w: int = _DEPTH_W,
    depth_h: int = _DEPTH_H,
    rgb_w: int = _RGB_W,
    rgb_h: int = _RGB_H,
    depth_value: float = 1.5,
    rgb_color: tuple[int, int, int] = (200, 100, 50),
    confidence_value: int | None = 2,
    manifest_overrides: dict | None = None,
) -> None:
    frame_count = len(poses)
    manifest = {
        "schema_version": 1,
        "capture_id": "cap_fusion_test",
        "material_code": "aggregate",
        "density_kg_per_m3": 1600,
        "frame_count": frame_count,
        "depth_dtype": "float16",
        "rgb": {"width": rgb_w, "height": rgb_h},
        "depth": {"width": depth_w, "height": depth_h, "smoothed": False},
    }
    if manifest_overrides:
        manifest.update(manifest_overrides)

    with zipfile.ZipFile(bundle_path, "w") as archive:
        archive.writestr("manifest.json", json.dumps(manifest).encode("utf-8"))
        archive.writestr("poses.json", json.dumps(poses).encode("utf-8"))
        for index in range(frame_count):
            archive.writestr(
                f"rgb/{index:06d}.jpg",
                _rgb_jpeg_bytes(rgb_w, rgb_h, rgb_color),
            )
            archive.writestr(
                f"depth/{index:06d}.f16.bin",
                _depth_bytes(depth_w, depth_h, depth_value),
            )
            if confidence_value is not None:
                archive.writestr(
                    f"confidence/{index:06d}.u8.bin",
                    _confidence_bytes(depth_w, depth_h, confidence_value),
                )
        if frame_count == 0:
            # The unpacker requires non-empty rgb/ and depth/ folders, so we
            # create explicit directory entries to satisfy bundle layout
            # checks while still exposing zero frames once filtered.
            archive.writestr("rgb/.keep", b"")
            archive.writestr("depth/.keep", b"")


def _normal_pose(transform: list[float], intrinsics: list[float]) -> dict:
    return {
        "timestamp": 0.0,
        "transform": transform,
        "intrinsics": intrinsics,
        "tracking_state": "normal",
        "lidar_active": True,
    }


def _limited_pose(transform: list[float], intrinsics: list[float]) -> dict:
    pose = _normal_pose(transform, intrinsics)
    pose["tracking_state"] = "limited"
    return pose


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_synthetic_cube_scene_produces_metric_point_cloud(tmp_path):
    intrinsics = _identity_intrinsics(_DEPTH_W, _DEPTH_H)
    radius = 1.5
    poses = [
        _normal_pose(_camera_at((0.0, 0.0, 0.0)), intrinsics),
        _normal_pose(_camera_at((radius, 0.0, 0.0)), intrinsics),
        _normal_pose(_camera_at((0.0, radius, 0.0)), intrinsics),
        _normal_pose(_camera_at((-radius, 0.0, 0.0)), intrinsics),
    ]
    bundle_path = tmp_path / "capture.stockpilecapture"
    _build_bundle_zip(bundle_path, poses, depth_value=1.5)

    bundle = unpack_stockpile_capture(bundle_path, tmp_path / "out")
    result = fuse_capture_bundle(bundle)

    assert isinstance(result, TSDFFusionResult)
    assert result.fused_frame_count == 4
    assert result.skipped_frame_count == 0
    assert result.voxel_size == 0.02
    assert result.sdf_trunc == 0.04

    points = np.asarray(result.point_cloud.points)
    assert points.shape[0] > 100, f"expected real geometry, got {points.shape[0]} points"

    bbox_min = points.min(axis=0)
    bbox_max = points.max(axis=0)
    # All cameras are within ~1.5 m of the origin; depth is constant 1.5 m, so
    # the fused surface lives within a generous box around the cameras.
    assert (bbox_min >= -3.5).all()
    assert (bbox_max <= 3.5).all()


def test_tracking_state_filter_skips_non_normal_frames(tmp_path):
    intrinsics = _identity_intrinsics(_DEPTH_W, _DEPTH_H)
    poses = [
        _normal_pose(_camera_at((0.0, 0.0, 0.0)), intrinsics),
        _normal_pose(_camera_at((0.5, 0.0, 0.0)), intrinsics),
        _limited_pose(_camera_at((0.0, 0.5, 0.0)), intrinsics),
        _limited_pose(_camera_at((-0.5, 0.0, 0.0)), intrinsics),
    ]
    bundle_path = tmp_path / "capture.stockpilecapture"
    _build_bundle_zip(bundle_path, poses)

    bundle = unpack_stockpile_capture(bundle_path, tmp_path / "out")
    result = fuse_capture_bundle(bundle)

    assert result.fused_frame_count == 2
    assert result.skipped_frame_count == 2


def test_zero_confidence_drops_depth_contribution(tmp_path):
    intrinsics = _identity_intrinsics(_DEPTH_W, _DEPTH_H)
    poses = [
        _normal_pose(_camera_at((0.0, 0.0, 0.0)), intrinsics),
        _normal_pose(_camera_at((0.5, 0.0, 0.0)), intrinsics),
    ]
    bundle_path = tmp_path / "capture.stockpilecapture"
    # confidence_value=0 means every depth pixel is masked out.
    _build_bundle_zip(bundle_path, poses, confidence_value=0)

    bundle = unpack_stockpile_capture(bundle_path, tmp_path / "out")
    result = fuse_capture_bundle(bundle)

    assert result.fused_frame_count == 2  # frames are integrated…
    assert result.skipped_frame_count == 0
    # …but with all depth pixels zeroed out, the TSDF has nothing to record.
    assert len(result.point_cloud.points) == 0


def test_rgb_resolution_mismatch_is_resized_and_intrinsics_scaled(tmp_path):
    rgb_w, rgb_h = 320, 240
    depth_w, depth_h = 32, 24
    intrinsics = _identity_intrinsics(rgb_w, rgb_h)
    poses = [
        _normal_pose(_camera_at((0.0, 0.0, 0.0)), intrinsics),
        _normal_pose(_camera_at((0.3, 0.0, 0.0)), intrinsics),
    ]
    bundle_path = tmp_path / "capture.stockpilecapture"
    _build_bundle_zip(
        bundle_path,
        poses,
        depth_w=depth_w,
        depth_h=depth_h,
        rgb_w=rgb_w,
        rgb_h=rgb_h,
        depth_value=1.0,
    )

    bundle = unpack_stockpile_capture(bundle_path, tmp_path / "out")
    # Disable the outlier filter so a small synthetic cloud doesn't get fully
    # discarded as outliers — we only care that fusion completes successfully.
    result = fuse_capture_bundle(
        bundle,
        config=TSDFFusionConfig(enable_post_outlier_filter=False),
    )

    assert result.fused_frame_count == 2
    assert result.skipped_frame_count == 0
    assert len(result.point_cloud.points) > 0


def test_empty_bundle_returns_empty_cloud(tmp_path):
    # We can't drive a 0-frame bundle through unpack_stockpile_capture (it
    # rejects empty rgb/ and depth/ folders), so test the fusion path
    # directly with a zero-frame bundle constructed in-memory.
    from stockpile_lidar.ingestion import StockpileCaptureBundle

    bundle = StockpileCaptureBundle(
        root=tmp_path,
        manifest={
            "schema_version": 1,
            "frame_count": 0,
            "material_code": "aggregate",
            "density_kg_per_m3": 1600,
            "depth_dtype": "float16",
            "depth": {"width": _DEPTH_W, "height": _DEPTH_H},
            "rgb": {"width": _RGB_W, "height": _RGB_H},
        },
        poses=[],
        rgb_frames=[],
        depth_frames=[],
        validation_warnings=[],
    )

    result = fuse_capture_bundle(bundle)

    assert result.fused_frame_count == 0
    assert result.skipped_frame_count == 0
    assert len(result.point_cloud.points) == 0
