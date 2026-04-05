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


def _build_priority_indices(
    all_images: list[Path],
    priority_image_names: set[str] | None,
    priority_neighbor_radius: int,
) -> list[int]:
    """Return sorted frame indices that should be preserved in the COLMAP subset."""
    if not priority_image_names:
        return []

    priority_indices: set[int] = set()
    for index, image in enumerate(all_images):
        if image.name not in priority_image_names:
            continue
        start = max(0, index - priority_neighbor_radius)
        end = min(len(all_images), index + priority_neighbor_radius + 1)
        priority_indices.update(range(start, end))
    return sorted(priority_indices)


def _count_images(images_dir: Path) -> int:
    """Return the number of JPG/PNG images in a directory."""
    return len(sorted(images_dir.glob("*.jpg")) + sorted(images_dir.glob("*.png")))


def _quality_to_sift_settings(quality: str) -> tuple[int, int]:
    """Map the high-level quality preset to SIFT extraction settings."""
    normalized = str(quality).strip().lower()
    if normalized == "low":
        return 1600, 4096
    if normalized == "high":
        return 3200, 16384
    return 2400, 8192


def _run_colmap_command(
    cmd: list[str],
    workspace_dir: Path,
    step_name: str,
    timeout: int,
) -> subprocess.CompletedProcess[str]:
    """Run a COLMAP command and persist stdout/stderr for debugging."""
    logger.info("Running COLMAP step %s: %s", step_name, " ".join(cmd))
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        env={**os.environ, "QT_QPA_PLATFORM": "offscreen"},
    )

    if result.stdout:
        (workspace_dir / f"{step_name}.stdout.log").write_text(result.stdout)
    if result.stderr:
        (workspace_dir / f"{step_name}.stderr.log").write_text(result.stderr)

    if result.returncode != 0:
        logger.error("COLMAP %s stdout: %s", step_name, result.stdout[-2000:] if result.stdout else "")
        logger.error("COLMAP %s stderr: %s", step_name, result.stderr[-2000:] if result.stderr else "")
        raise RuntimeError(f"COLMAP {step_name} failed with return code {result.returncode}")

    return result


def _registered_image_names(model_dir: Path) -> set[str]:
    """Return the registered image filenames for a sparse model."""
    model_dir = Path(model_dir)
    if (model_dir / "images.bin").exists():
        return {image.name for image in read_images_binary(model_dir / "images.bin").values()}
    if (model_dir / "images.txt").exists():
        names: set[str] = set()
        for line in (model_dir / "images.txt").read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 10 and parts[0].isdigit():
                names.add(parts[9])
        return names
    return set()


def _subsample_images_dir(
    images_dir: Path,
    max_frames: int,
    priority_image_names: set[str] | None = None,
    priority_neighbor_radius: int = 2,
) -> Path:
    """If images_dir has more than max_frames images, copy a prioritized subset.

    We preserve cone-bearing frames and nearby context first, then fill the
    remaining budget with an evenly spaced sample of the full walkthrough.
    """
    import shutil
    all_images = sorted(images_dir.glob("*.jpg")) + sorted(images_dir.glob("*.png"))
    if len(all_images) <= max_frames:
        return images_dir

    priority_indices = _build_priority_indices(
        all_images,
        priority_image_names=priority_image_names,
        priority_neighbor_radius=priority_neighbor_radius,
    )
    if len(priority_indices) >= max_frames:
        selected_idx = np.linspace(0, len(priority_indices) - 1, max_frames, dtype=int)
        selected_indices = [priority_indices[idx] for idx in selected_idx]
    else:
        selected_indices = list(priority_indices)
        remaining_budget = max_frames - len(selected_indices)
        filler_pool = [idx for idx in range(len(all_images)) if idx not in set(selected_indices)]
        if remaining_budget > 0 and filler_pool:
            filler_idx = np.linspace(0, len(filler_pool) - 1, remaining_budget, dtype=int)
            selected_indices.extend(filler_pool[idx] for idx in filler_idx)
    selected = [all_images[idx] for idx in sorted(set(selected_indices))]

    subset_dir = images_dir.parent / "images_colmap_subset"
    if subset_dir.exists():
        shutil.rmtree(subset_dir)
    subset_dir.mkdir(parents=True)

    for img in selected:
        shutil.copy2(img, subset_dir / img.name)

    logger.info(
        "Subsampled %d → %d frames for COLMAP (%d priority-preserved frames)",
        len(all_images), len(selected), len(priority_indices),
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
    priority_image_names: set[str] | None = None,
    priority_neighbor_radius: int = 2,
    progress_callback=None,
) -> Path:
    """Run COLMAP sparse reconstruction and return the sparse model directory."""
    config = config or ColmapConfig()
    workspace_dir = Path(workspace_dir)
    workspace_dir.mkdir(parents=True, exist_ok=True)

    # Subsample frames to avoid over-dense central reconstruction
    images_dir = _subsample_images_dir(
        Path(images_dir),
        config.max_colmap_frames,
        priority_image_names=priority_image_names,
        priority_neighbor_radius=priority_neighbor_radius,
    )
    selected_image_count = _count_images(images_dir)

    sparse_dir = workspace_dir / "sparse"
    database_path = workspace_dir / "database.db"
    if database_path.exists():
        database_path.unlink()
    if sparse_dir.exists():
        import shutil

        shutil.rmtree(sparse_dir)
    sparse_dir.mkdir(parents=True, exist_ok=True)

    max_image_size, max_num_features = _quality_to_sift_settings(config.quality)

    if progress_callback:
        progress_callback(0.05)

    feature_cmd = [
        config.colmap_binary,
        "feature_extractor",
        "--database_path", str(database_path.resolve()),
        "--image_path", str(images_dir.resolve()),
        "--ImageReader.camera_model", str(config.camera_model),
        "--ImageReader.single_camera", "1" if config.single_camera else "0",
        "--FeatureExtraction.use_gpu", "1" if config.use_gpu else "0",
        "--FeatureExtraction.max_image_size", str(max_image_size),
        "--SiftExtraction.max_num_features", str(max_num_features),
    ]
    try:
        _run_colmap_command(feature_cmd, workspace_dir, "feature_extractor", timeout=3600)

        if progress_callback:
            progress_callback(0.2)

        use_exhaustive_matcher = selected_image_count <= 160
        if config.use_sequential_matching and not use_exhaustive_matcher:
            matcher_cmd = [
                config.colmap_binary,
                "sequential_matcher",
                "--database_path", str(database_path.resolve()),
                "--FeatureMatching.use_gpu", "1" if config.use_gpu else "0",
                "--FeatureMatching.guided_matching", "1",
                "--SequentialMatching.overlap", "20" if priority_image_names else "15",
                "--SequentialMatching.quadratic_overlap", "1",
                "--SequentialMatching.loop_detection", "1" if priority_image_names else "0",
            ]
            matcher_step = "sequential_matcher"
        else:
            matcher_cmd = [
                config.colmap_binary,
                "exhaustive_matcher",
                "--database_path", str(database_path.resolve()),
                "--FeatureMatching.use_gpu", "1" if config.use_gpu else "0",
                "--FeatureMatching.guided_matching", "1",
            ]
            matcher_step = "exhaustive_matcher"

        _run_colmap_command(matcher_cmd, workspace_dir, matcher_step, timeout=7200)

        if progress_callback:
            progress_callback(0.45)

        mapper_cmd = [
            config.colmap_binary,
            "mapper",
            "--database_path", str(database_path.resolve()),
            "--image_path", str(images_dir.resolve()),
            "--output_path", str(sparse_dir.resolve()),
            "--Mapper.multiple_models", "0",
            "--Mapper.min_model_size", "5",
            "--Mapper.ba_use_gpu", "1" if config.use_gpu else "0",
        ]
        _run_colmap_command(mapper_cmd, workspace_dir, "mapper", timeout=7200)
        model_dir = _find_sparse_model_dir(sparse_dir)

        if progress_callback:
            progress_callback(0.75)

        if priority_image_names:
            registered_after_mapper = _registered_image_names(model_dir)
            missing_priority = sorted(
                name for name in priority_image_names if name not in registered_after_mapper
            )
            if missing_priority:
                registrator_output_dir = workspace_dir / "sparse_registered"
                triangulated_output_dir = workspace_dir / "sparse_triangulated"
                if registrator_output_dir.exists():
                    import shutil

                    shutil.rmtree(registrator_output_dir)
                if triangulated_output_dir.exists():
                    import shutil

                    shutil.rmtree(triangulated_output_dir)
                registrator_output_dir.mkdir(parents=True, exist_ok=True)
                triangulated_output_dir.mkdir(parents=True, exist_ok=True)

                registrator_cmd = [
                    config.colmap_binary,
                    "image_registrator",
                    "--database_path", str(database_path.resolve()),
                    "--input_path", str(model_dir.resolve()),
                    "--output_path", str(registrator_output_dir.resolve()),
                    "--Mapper.ba_use_gpu", "1" if config.use_gpu else "0",
                    "--Mapper.abs_pose_min_num_inliers", "20",
                ]
                _run_colmap_command(registrator_cmd, workspace_dir, "image_registrator", timeout=3600)

                triangulator_cmd = [
                    config.colmap_binary,
                    "point_triangulator",
                    "--database_path", str(database_path.resolve()),
                    "--image_path", str(images_dir.resolve()),
                    "--input_path", str(registrator_output_dir.resolve()),
                    "--output_path", str(triangulated_output_dir.resolve()),
                    "--clear_points", "1",
                    "--Mapper.ba_use_gpu", "1" if config.use_gpu else "0",
                ]
                _run_colmap_command(triangulator_cmd, workspace_dir, "point_triangulator", timeout=3600)

                triangulated_model_dir = _find_sparse_model_dir(triangulated_output_dir)
                registered_after_triangulation = _registered_image_names(triangulated_model_dir)
                if len(registered_after_triangulation) > len(registered_after_mapper):
                    logger.info(
                        "Image registrator recovered %d additional images (%d -> %d)",
                        len(registered_after_triangulation) - len(registered_after_mapper),
                        len(registered_after_mapper),
                        len(registered_after_triangulation),
                    )
                    model_dir = triangulated_model_dir
                else:
                    logger.info(
                        "Image registrator did not improve registration coverage (%d images)",
                        len(registered_after_mapper),
                    )

    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("COLMAP timed out during explicit sparse reconstruction") from exc

    logger.info("COLMAP reconstruction complete with %d selected images", selected_image_count)

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
