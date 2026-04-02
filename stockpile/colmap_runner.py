"""COLMAP subprocess wrapper and binary file parsers."""

import logging
import os
import struct
import subprocess
from collections import namedtuple
from pathlib import Path

import numpy as np

from .config import ColmapConfig

logger = logging.getLogger(__name__)

_COLMAP_MODEL_FILESETS = (
    ("cameras.bin", "images.bin", "points3D.bin"),
    ("cameras.txt", "images.txt", "points3D.txt"),
)

# COLMAP binary format structures
CameraModel = namedtuple("CameraModel", ["model_id", "model_name", "num_params"])

CAMERA_MODELS = {
    0: CameraModel(0, "SIMPLE_PINHOLE", 3),
    1: CameraModel(1, "PINHOLE", 4),
    2: CameraModel(2, "SIMPLE_RADIAL", 4),
    3: CameraModel(3, "RADIAL", 5),
    4: CameraModel(4, "OPENCV", 8),
    5: CameraModel(5, "OPENCV_FISHEYE", 8),
    6: CameraModel(6, "FULL_OPENCV", 14),
    7: CameraModel(7, "FOV", 5),
    8: CameraModel(8, "SIMPLE_RADIAL_FISHEYE", 4),
    9: CameraModel(9, "RADIAL_FISHEYE", 5),
    10: CameraModel(10, "THIN_PRISM_FISHEYE", 12),
}


class ColmapCamera:
    """Parsed COLMAP camera entry."""
    def __init__(self, camera_id, model_id, width, height, params):
        self.camera_id = camera_id
        self.model_id = model_id
        self.width = width
        self.height = height
        self.params = params  # numpy array of intrinsic parameters

    @property
    def focal_length(self) -> float:
        """Get focal length in pixels (first parameter for all models)."""
        return float(self.params[0])


class ColmapImage:
    """Parsed COLMAP image entry."""
    def __init__(self, image_id, qw, qx, qy, qz, tx, ty, tz, camera_id, name, xys, point3d_ids):
        self.image_id = image_id
        self.qvec = np.array([qw, qx, qy, qz])
        self.tvec = np.array([tx, ty, tz])
        self.camera_id = camera_id
        self.name = name
        self.xys = xys  # (N, 2) array of 2D keypoint positions
        self.point3d_ids = point3d_ids  # (N,) array, -1 if no 3D point


class ColmapPoint3D:
    """Parsed COLMAP 3D point entry."""
    def __init__(self, point3d_id, xyz, rgb, error, image_ids, point2d_idxs):
        self.point3d_id = point3d_id
        self.xyz = xyz
        self.rgb = rgb
        self.error = error
        self.image_ids = image_ids
        self.point2d_idxs = point2d_idxs


def _subsample_images_dir(images_dir: Path, max_frames: int) -> Path:
    """If images_dir has more than max_frames images, copy an evenly-spaced
    subset into a sibling directory and return that path instead."""
    import shutil
    all_images = sorted(images_dir.glob("*.jpg")) + sorted(images_dir.glob("*.png"))
    if len(all_images) <= max_frames:
        return images_dir

    selected_idx = np.linspace(0, len(all_images) - 1, max_frames, dtype=int)
    selected = [all_images[idx] for idx in selected_idx]

    subset_dir = images_dir.parent / "images_colmap_subset"
    if subset_dir.exists():
        shutil.rmtree(subset_dir)
    subset_dir.mkdir(parents=True)

    for img in selected:
        shutil.copy2(img, subset_dir / img.name)

    logger.info(
        "Subsampled %d → %d frames for COLMAP (even spacing)",
        len(all_images), len(selected),
    )
    return subset_dir


def _is_colmap_model_dir(path: Path) -> bool:
    """Return True when the path contains a valid COLMAP sparse model."""
    if not path.exists() or not path.is_dir():
        return False
    return any(all((path / name).exists() for name in fileset) for fileset in _COLMAP_MODEL_FILESETS)


def _find_sparse_model_dir(sparse_dir: Path) -> Path:
    """Locate a COLMAP sparse model directory under sparse_dir."""
    sparse_dir = Path(sparse_dir)

    if _is_colmap_model_dir(sparse_dir):
        return sparse_dir

    if not sparse_dir.exists():
        raise RuntimeError(f"COLMAP sparse directory was not created: {sparse_dir}")

    direct_subdirs = sorted(path for path in sparse_dir.iterdir() if path.is_dir())
    for candidate in direct_subdirs:
        if _is_colmap_model_dir(candidate):
            return candidate

    recursive_candidates = sorted(
        {
            parent
            for marker in ("cameras.bin", "cameras.txt")
            for parent in (path.parent for path in sparse_dir.rglob(marker))
        }
    )
    for candidate in recursive_candidates:
        if _is_colmap_model_dir(candidate):
            return candidate

    raise RuntimeError(
        "COLMAP completed but produced no sparse model files "
        f"under {sparse_dir}. Expected cameras/images/points3D outputs."
    )


def run_colmap_reconstruction(
    images_dir: Path,
    workspace_dir: Path,
    config: ColmapConfig | None = None,
    progress_callback=None,
) -> Path:
    """Run COLMAP automatic_reconstructor and return the sparse model directory."""
    config = config or ColmapConfig()
    workspace_dir = Path(workspace_dir)
    workspace_dir.mkdir(parents=True, exist_ok=True)

    # Subsample frames to avoid over-dense central reconstruction
    images_dir = _subsample_images_dir(Path(images_dir), config.max_colmap_frames)

    sparse_dir = workspace_dir / "sparse"
    database_path = workspace_dir / "database.db"

    cmd = [
        config.colmap_binary,
        "automatic_reconstructor",
        "--workspace_path", str(workspace_dir.resolve()),
        "--image_path", str(images_dir.resolve()),
        "--data_type", "video",
        "--quality", config.quality,
        "--single_camera", "1" if config.single_camera else "0",
        "--dense", "0",
        "--use_gpu", "1" if config.use_gpu else "0",
    ]

    logger.info("Running COLMAP: %s", " ".join(cmd))
    if progress_callback:
        progress_callback(0.1)

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=14400,  # 4 hours timeout
            env={**os.environ, "QT_QPA_PLATFORM": "offscreen"},
        )

        if result.returncode != 0:
            logger.error("COLMAP stdout: %s", result.stdout[-2000:] if result.stdout else "")
            logger.error("COLMAP stderr: %s", result.stderr[-2000:] if result.stderr else "")
            raise RuntimeError(f"COLMAP failed with return code {result.returncode}")

        if result.stdout:
            (workspace_dir / "automatic_reconstructor.stdout.log").write_text(result.stdout)
        if result.stderr:
            (workspace_dir / "automatic_reconstructor.stderr.log").write_text(result.stderr)

        logger.info("COLMAP reconstruction complete")

    except subprocess.TimeoutExpired:
        raise RuntimeError("COLMAP timed out after 4 hours")

    if progress_callback:
        progress_callback(0.8)

    model_dir = _find_sparse_model_dir(sparse_dir)

    if progress_callback:
        progress_callback(1.0)

    return model_dir


def export_to_ply(
    model_dir: Path,
    output_path: Path,
    colmap_binary: str = "colmap",
) -> Path:
    """Export COLMAP sparse model to PLY file."""
    if not _is_colmap_model_dir(Path(model_dir)):
        raise RuntimeError(f"Cannot export PLY because no valid COLMAP model was found at {model_dir}")

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    cmd = [
        colmap_binary,
        "model_converter",
        "--input_path", str(model_dir),
        "--output_path", str(output_path),
        "--output_type", "PLY",
    ]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=600,
            env={**os.environ, "QT_QPA_PLATFORM": "offscreen"},
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(
            f"PLY export timed out after 10 minutes for sparse model at {model_dir}"
        ) from exc

    if result.returncode != 0:
        raise RuntimeError(f"PLY export failed: {result.stderr}")

    logger.info("Exported PLY to %s", output_path)
    return output_path


# ─── Binary File Parsers ─────────────────────────────────────────────


def read_cameras_binary(path: Path) -> dict[int, ColmapCamera]:
    """Parse COLMAP cameras.bin file."""
    cameras = {}
    with open(path, "rb") as f:
        num_cameras = struct.unpack("<Q", f.read(8))[0]
        for _ in range(num_cameras):
            camera_id = struct.unpack("<I", f.read(4))[0]
            model_id = struct.unpack("<i", f.read(4))[0]
            width = struct.unpack("<Q", f.read(8))[0]
            height = struct.unpack("<Q", f.read(8))[0]

            model = CAMERA_MODELS.get(model_id)
            num_params = model.num_params if model else 0
            params = np.array(struct.unpack(f"<{num_params}d", f.read(8 * num_params)))

            cameras[camera_id] = ColmapCamera(camera_id, model_id, width, height, params)

    logger.info("Parsed %d cameras from cameras.bin", len(cameras))
    return cameras


def read_images_binary(path: Path) -> dict[int, ColmapImage]:
    """Parse COLMAP images.bin file."""
    images = {}
    with open(path, "rb") as f:
        num_images = struct.unpack("<Q", f.read(8))[0]
        for _ in range(num_images):
            # Image header
            image_id = struct.unpack("<I", f.read(4))[0]
            qw, qx, qy, qz = struct.unpack("<4d", f.read(32))
            tx, ty, tz = struct.unpack("<3d", f.read(24))
            camera_id = struct.unpack("<I", f.read(4))[0]

            # Image name (null-terminated)
            name_bytes = b""
            while True:
                ch = f.read(1)
                if ch == b"\x00":
                    break
                name_bytes += ch
            name = name_bytes.decode("utf-8")

            # 2D points
            num_points2d = struct.unpack("<Q", f.read(8))[0]
            xys = np.zeros((num_points2d, 2), dtype=np.float64)
            point3d_ids = np.full(num_points2d, -1, dtype=np.int64)

            for j in range(num_points2d):
                x, y = struct.unpack("<2d", f.read(16))
                p3d_id = struct.unpack("<q", f.read(8))[0]
                xys[j] = [x, y]
                point3d_ids[j] = p3d_id

            images[image_id] = ColmapImage(
                image_id, qw, qx, qy, qz, tx, ty, tz,
                camera_id, name, xys, point3d_ids,
            )

    logger.info("Parsed %d images from images.bin", len(images))
    return images


def read_points3d_binary(path: Path) -> dict[int, ColmapPoint3D]:
    """Parse COLMAP points3D.bin file."""
    points = {}
    with open(path, "rb") as f:
        num_points = struct.unpack("<Q", f.read(8))[0]
        for _ in range(num_points):
            point3d_id = struct.unpack("<Q", f.read(8))[0]
            xyz = np.array(struct.unpack("<3d", f.read(24)))
            rgb = np.array(struct.unpack("<3B", f.read(3)), dtype=np.uint8)
            error = struct.unpack("<d", f.read(8))[0]

            track_length = struct.unpack("<Q", f.read(8))[0]
            image_ids = np.zeros(track_length, dtype=np.int32)
            point2d_idxs = np.zeros(track_length, dtype=np.int32)
            for j in range(track_length):
                img_id, p2d_idx = struct.unpack("<2I", f.read(8))
                image_ids[j] = img_id
                point2d_idxs[j] = p2d_idx

            points[point3d_id] = ColmapPoint3D(
                point3d_id, xyz, rgb, error, image_ids, point2d_idxs,
            )

    logger.info("Parsed %d 3D points from points3D.bin", len(points))
    return points


def get_reconstruction_stats(model_dir: Path) -> dict:
    """Get basic stats about a COLMAP reconstruction."""
    images = read_images_binary(model_dir / "images.bin")
    points = read_points3d_binary(model_dir / "points3D.bin")

    all_xyz = np.array([p.xyz for p in points.values()])

    return {
        "num_images": len(images),
        "num_points": len(points),
        "bbox_min": all_xyz.min(axis=0).tolist() if len(all_xyz) > 0 else None,
        "bbox_max": all_xyz.max(axis=0).tolist() if len(all_xyz) > 0 else None,
        "mean_reprojection_error": np.mean([p.error for p in points.values()]) if points else None,
    }
