"""COLMAP subprocess wrapper and binary file parsers."""

import logging
import os
import re
import signal
import sqlite3
import struct
import subprocess
import time
from collections import namedtuple
from pathlib import Path

import numpy as np

from .config import ColmapConfig

logger = logging.getLogger(__name__)

_COLMAP_MODEL_FILESETS = (
    ("cameras.bin", "images.bin", "points3D.bin"),
    ("cameras.txt", "images.txt", "points3D.txt"),
)
_COLMAP_PAIR_ID_PRIME = 2147483647
_INIT_PAIR_SCAN_LIMIT = 5000

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


def _count_images(images_dir: Path) -> int:
    """Return the number of JPG/PNG images in a directory."""
    return len(sorted(images_dir.glob("*.jpg")) + sorted(images_dir.glob("*.png")))


def _read_step_log(workspace_dir: Path, step_name: str, stream: str) -> str:
    """Read a captured step log stream if present."""
    log_path = Path(workspace_dir) / f"{step_name}.{stream}.log"
    if not log_path.exists():
        return ""
    try:
        return log_path.read_text()
    except Exception:
        return ""


def _is_unsuitable_init_pair_failure(workspace_dir: Path, step_name: str) -> bool:
    """Return True when mapper failed specifically due to an unusable init pair."""
    stderr_text = _read_step_log(workspace_dir, step_name, "stderr")
    return "provided pair is unsuitable for initialization" in stderr_text.lower()


def _quality_to_sift_settings(quality: str) -> tuple[int, int]:
    """Map quality presets to extraction image-size/features."""
    normalized = str(quality).strip().lower()
    if normalized == "low":
        return 1600, 4096
    if normalized == "high":
        return 3200, 12288
    return 2400, 8192


def _run_colmap_command(
    cmd: list[str],
    workspace_dir: Path,
    step_name: str,
    timeout: int,
) -> subprocess.CompletedProcess[str]:
    """Run a COLMAP command and persist stdout/stderr for debugging."""
    logger.info("Running COLMAP step %s: %s", step_name, " ".join(cmd))
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={**os.environ, "QT_QPA_PLATFORM": "offscreen"},
        start_new_session=True,
    )
    stdout_text = ""
    stderr_text = ""
    try:
        stdout_text, stderr_text = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        stdout_text = _coerce_subprocess_text(exc.output)
        stderr_text = _coerce_subprocess_text(exc.stderr)
        logger.error(
            "COLMAP step %s exceeded %ss; terminating process tree and workspace-specific stragglers.",
            step_name,
            timeout,
        )
        _terminate_process_group(process, grace_seconds=5.0)
        _cleanup_lingering_workspace_processes(cmd, current_pid=os.getpid())
        if stdout_text:
            (workspace_dir / f"{step_name}.stdout.log").write_text(stdout_text)
        if stderr_text:
            (workspace_dir / f"{step_name}.stderr.log").write_text(stderr_text)
        raise subprocess.TimeoutExpired(
            cmd=cmd,
            timeout=timeout,
            output=stdout_text,
            stderr=stderr_text,
        ) from None

    result = subprocess.CompletedProcess(
        args=cmd,
        returncode=process.returncode,
        stdout=stdout_text,
        stderr=stderr_text,
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


def _coerce_subprocess_text(value: str | bytes | None) -> str:
    """Normalize subprocess output values to text for logging and errors."""
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def _terminate_process_group(process: subprocess.Popen[str], grace_seconds: float = 5.0) -> None:
    """Terminate a subprocess and its process group as aggressively as needed."""
    if process.poll() is not None:
        return

    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except Exception:
        process.terminate()

    deadline = time.time() + max(0.1, float(grace_seconds))
    while process.poll() is None and time.time() < deadline:
        time.sleep(0.1)

    if process.poll() is not None:
        return

    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    except Exception:
        process.kill()

    deadline = time.time() + 2.0
    while process.poll() is None and time.time() < deadline:
        time.sleep(0.1)


def _cleanup_markers_for_command(cmd: list[str]) -> set[str]:
    """Extract unique path markers that identify lingering step-specific processes."""
    markers: set[str] = set()
    for arg in cmd[1:]:
        if not isinstance(arg, str):
            continue
        candidate = arg.strip()
        if not candidate or candidate.startswith("--"):
            continue
        if "/" not in candidate and "\\" not in candidate:
            continue
        markers.add(candidate)
        normalized = candidate.replace("\\", "/")
        if "/data/" in normalized:
            suffix = normalized.split("/data/", 1)[1]
            markers.add(f"/data/{suffix}")
    return {marker for marker in markers if len(marker) >= 12}


def _matching_process_ids(markers: set[str], *, current_pid: int | None = None) -> list[int]:
    """Return process ids whose command lines contain any of the provided markers."""
    if not markers:
        return []
    try:
        result = subprocess.run(
            ["ps", "-eo", "pid=,args="],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except Exception:
        return []
    if result.returncode != 0:
        return []

    blocked_pids = {os.getpid()}
    if current_pid is not None:
        blocked_pids.add(int(current_pid))

    matches: list[int] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        pid_text, _, args = line.partition(" ")
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        if pid in blocked_pids or not args:
            continue
        if any(marker in args for marker in markers):
            matches.append(pid)
    return matches


def _signal_processes(process_ids: list[int], sig: int) -> None:
    """Best-effort signal dispatch for a batch of process ids."""
    for pid in process_ids:
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            continue
        except Exception:
            continue


def _cleanup_lingering_workspace_processes(cmd: list[str], *, current_pid: int | None = None) -> None:
    """Kill any lingering workspace-scoped processes that outlived the main timeout."""
    markers = _cleanup_markers_for_command(cmd)
    if not markers:
        return

    process_ids = _matching_process_ids(markers, current_pid=current_pid)
    if not process_ids:
        return

    logger.warning("Killing lingering COLMAP-related processes for markers: %s", sorted(markers))
    _signal_processes(process_ids, signal.SIGTERM)
    time.sleep(1.0)

    remaining = _matching_process_ids(markers, current_pid=current_pid)
    if remaining:
        _signal_processes(remaining, signal.SIGKILL)


def _count_database_geometric_matches(database_path: Path) -> int:
    """Return the number of verified image pairs in the COLMAP database."""
    if not database_path.exists():
        return 0
    try:
        with sqlite3.connect(str(database_path)) as conn:
            row = conn.execute("SELECT COUNT(*) FROM two_view_geometries WHERE rows > 0").fetchone()
    except Exception:
        return 0
    return int(row[0]) if row else 0


def _decode_colmap_pair_id(pair_id: int) -> tuple[int, int]:
    """Decode COLMAP pair_id back into (image_id1, image_id2)."""
    image_id2 = int(pair_id % _COLMAP_PAIR_ID_PRIME)
    image_id1 = int((pair_id - image_id2) // _COLMAP_PAIR_ID_PRIME)
    if image_id1 <= 0 or image_id2 <= 0:
        return (0, 0)
    return (image_id1, image_id2)


def _frame_index_from_image_name(image_name: str) -> int | None:
    """Extract a frame index from a COLMAP image name when available."""
    stem = Path(str(image_name)).stem
    match = re.search(r"(\d+)$", stem)
    if not match:
        return None
    try:
        return int(match.group(1))
    except Exception:
        return None


def _choose_mapper_init_pair(
    database_path: Path,
    min_inliers: int,
    min_frame_gap: int = 0,
) -> tuple[int, int] | None:
    """Choose a deterministic mapper init pair from verified matches.

    When frame indices are available, prefer wide-baseline pairs by enforcing
    an optional minimum frame gap.
    """
    if not database_path.exists():
        return None

    query = (
        "SELECT pair_id, rows "
        "FROM two_view_geometries "
        "WHERE rows >= ? "
        "ORDER BY rows DESC, pair_id ASC "
        f"LIMIT {_INIT_PAIR_SCAN_LIMIT}"
    )
    try:
        with sqlite3.connect(str(database_path)) as conn:
            rows = conn.execute(query, (int(min_inliers),)).fetchall()
            frame_idx_by_image_id: dict[int, int] = {}
            if int(min_frame_gap) > 0:
                try:
                    image_rows = conn.execute("SELECT image_id, name FROM images").fetchall()
                    for image_id, image_name in image_rows:
                        idx = _frame_index_from_image_name(str(image_name))
                        if idx is not None:
                            frame_idx_by_image_id[int(image_id)] = idx
                except Exception:
                    frame_idx_by_image_id = {}
    except Exception:
        return None

    if not rows:
        return None

    first_valid_pair: tuple[int, int] | None = None
    requested_gap = max(0, int(min_frame_gap))

    for row in rows:
        image_id1, image_id2 = _decode_colmap_pair_id(int(row[0]))
        if image_id1 <= 0 or image_id2 <= 0:
            continue
        if first_valid_pair is None:
            first_valid_pair = (image_id1, image_id2)
        if requested_gap <= 0:
            return (image_id1, image_id2)
        idx1 = frame_idx_by_image_id.get(image_id1)
        idx2 = frame_idx_by_image_id.get(image_id2)
        if idx1 is None or idx2 is None:
            continue
        if abs(idx1 - idx2) >= requested_gap:
            return (image_id1, image_id2)

    return first_valid_pair


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


def _run_matcher_with_fallback(
    matcher_kind: str,
    *,
    database_path: Path,
    workspace_dir: Path,
    config: ColmapConfig,
    random_seed: int,
    overlap: int,
    step_name: str,
) -> None:
    """Run a matcher, retrying on CPU if GPU matching fails."""
    def build_cmd(use_gpu: bool) -> list[str]:
        cmd = [
            config.colmap_binary,
            matcher_kind,
            "--database_path", str(database_path.resolve()),
            "--default_random_seed", str(random_seed),
            "--FeatureMatching.num_threads", str(config.matching_num_threads),
            "--FeatureMatching.use_gpu", "1" if use_gpu else "0",
            "--FeatureMatching.guided_matching", "1",
            "--FeatureMatching.max_num_matches", str(config.max_num_matches),
            "--TwoViewGeometry.random_seed", str(random_seed),
        ]
        if matcher_kind == "sequential_matcher":
            cmd.extend(
                [
                    "--SequentialMatching.overlap", str(overlap),
                    "--SequentialMatching.quadratic_overlap", "1",
                    "--SequentialMatching.loop_detection", "0",
                    "--SequentialMatching.num_threads", str(config.matching_num_threads),
                ]
            )
        return cmd

    try:
        _run_colmap_command(
            build_cmd(use_gpu=config.use_gpu and config.use_gpu_matching),
            workspace_dir,
            step_name,
            timeout=7200,
        )
    except RuntimeError:
        if config.use_gpu and config.use_gpu_matching:
            logger.warning(
                "COLMAP %s failed with GPU matching; retrying on CPU to preserve stability.",
                step_name,
            )
            _run_colmap_command(build_cmd(use_gpu=False), workspace_dir, f"{step_name}_cpu_retry", timeout=7200)
        else:
            raise


def run_colmap_reconstruction(
    images_dir: Path,
    workspace_dir: Path,
    config: ColmapConfig | None = None,
    progress_callback=None,
) -> Path:
    """Run an explicit COLMAP sparse reconstruction and return the model directory."""
    config = config or ColmapConfig()
    workspace_dir = Path(workspace_dir)
    workspace_dir.mkdir(parents=True, exist_ok=True)

    images_dir = _subsample_images_dir(Path(images_dir), config.max_colmap_frames)
    selected_image_count = _count_images(images_dir)

    sparse_dir = workspace_dir / "sparse"
    database_path = workspace_dir / "database.db"
    if database_path.exists():
        database_path.unlink()
    if sparse_dir.exists():
        import shutil

        shutil.rmtree(sparse_dir)
    sparse_dir.mkdir(parents=True, exist_ok=True)

    random_seed = int(config.random_seed)
    max_image_size, max_num_features = _quality_to_sift_settings(config.quality)
    max_num_features = min(max_num_features, int(config.max_num_features_cap))

    if progress_callback:
        progress_callback(0.05)

    try:
        feature_cmd = [
            config.colmap_binary,
            "feature_extractor",
            "--database_path", str(database_path.resolve()),
            "--image_path", str(images_dir.resolve()),
            "--default_random_seed", str(random_seed),
            "--ImageReader.camera_model", str(config.camera_model),
            "--ImageReader.single_camera", "1" if config.single_camera else "0",
            "--FeatureExtraction.num_threads", str(config.feature_num_threads),
            "--FeatureExtraction.use_gpu", "1" if config.use_gpu else "0",
            "--FeatureExtraction.max_image_size", str(max_image_size),
            "--SiftExtraction.max_num_features", str(max_num_features),
        ]
        _run_colmap_command(feature_cmd, workspace_dir, "feature_extractor", timeout=3600)

        if progress_callback:
            progress_callback(0.2)

        prefer_sequential = config.use_sequential_matching and selected_image_count > 300
        if prefer_sequential:
            _run_matcher_with_fallback(
                "sequential_matcher",
                database_path=database_path,
                workspace_dir=workspace_dir,
                config=config,
                random_seed=random_seed,
                overlap=15,
                step_name="sequential_matcher",
            )
        else:
            _run_matcher_with_fallback(
                "exhaustive_matcher",
                database_path=database_path,
                workspace_dir=workspace_dir,
                config=config,
                random_seed=random_seed,
                overlap=15,
                step_name="exhaustive_matcher",
            )

        geometric_matches = _count_database_geometric_matches(database_path)
        if geometric_matches < int(config.min_geometric_matches_for_mapper) and prefer_sequential:
            logger.warning(
                "Sequential matcher produced only %d verified pairs; retrying with exhaustive matcher.",
                geometric_matches,
            )
            _run_matcher_with_fallback(
                "exhaustive_matcher",
                database_path=database_path,
                workspace_dir=workspace_dir,
                config=config,
                random_seed=random_seed,
                overlap=15,
                step_name="exhaustive_matcher_retry",
            )
            geometric_matches = _count_database_geometric_matches(database_path)

        if geometric_matches < int(config.min_geometric_matches_for_mapper):
            raise RuntimeError(
                f"COLMAP matching produced only {geometric_matches} verified image pairs, below the mapper floor "
                f"({config.min_geometric_matches_for_mapper})."
            )

        if progress_callback:
            progress_callback(0.45)

        mapper_cmd = [
            config.colmap_binary,
            "mapper",
            "--database_path", str(database_path.resolve()),
            "--image_path", str(images_dir.resolve()),
            "--output_path", str(sparse_dir.resolve()),
            "--default_random_seed", str(random_seed),
            "--Mapper.random_seed", str(random_seed),
            "--Mapper.num_threads", str(config.mapper_num_threads),
            "--Mapper.multiple_models", "0",
            "--Mapper.min_model_size", "3",
            "--Mapper.init_num_trials", str(config.mapper_init_num_trials),
            "--Mapper.max_runtime_seconds", str(config.mapper_max_runtime_seconds),
            "--Mapper.init_min_num_inliers", str(config.mapper_init_min_num_inliers),
            "--Mapper.ba_use_gpu", "1" if config.use_gpu else "0",
        ]
        mapper_timeout_seconds = max(120, int(config.mapper_max_runtime_seconds) + 90)
        init_pair = _choose_mapper_init_pair(
            database_path,
            int(config.min_init_pair_inliers),
            min_frame_gap=int(config.min_init_pair_frame_gap),
        )
        mapper_cmd_with_pair = list(mapper_cmd)
        if init_pair:
            mapper_cmd_with_pair.extend(
                [
                    "--Mapper.init_image_id1", str(init_pair[0]),
                    "--Mapper.init_image_id2", str(init_pair[1]),
                ]
            )
        try:
            _run_colmap_command(
                mapper_cmd_with_pair,
                workspace_dir,
                "mapper",
                timeout=mapper_timeout_seconds,
            )
        except RuntimeError:
            if not init_pair:
                raise
            if not _is_unsuitable_init_pair_failure(workspace_dir, "mapper"):
                raise
            logger.warning(
                "Mapper failed with fixed init pair %s; retrying without forced pair.",
                init_pair,
            )
            _run_colmap_command(
                mapper_cmd,
                workspace_dir,
                "mapper_retry_without_fixed_pair",
                timeout=mapper_timeout_seconds,
            )

        model_dir = _find_sparse_model_dir(sparse_dir)
        registered_images = len(_registered_image_names(model_dir))
        if selected_image_count > 0:
            registered_ratio = registered_images / selected_image_count
            if registered_ratio < float(config.min_registered_image_ratio) and init_pair:
                logger.warning(
                    "Mapper registered only %d/%d images (%.1f%%) with fixed init pair %s; "
                    "retrying without forced pair.",
                    registered_images,
                    selected_image_count,
                    registered_ratio * 100,
                    init_pair,
                )
                import shutil

                if sparse_dir.exists():
                    shutil.rmtree(sparse_dir)
                sparse_dir.mkdir(parents=True, exist_ok=True)

                _run_colmap_command(
                    mapper_cmd,
                    workspace_dir,
                    "mapper_retry_low_registration",
                    timeout=mapper_timeout_seconds,
                )
                model_dir = _find_sparse_model_dir(sparse_dir)
                registered_images = len(_registered_image_names(model_dir))
                registered_ratio = registered_images / selected_image_count

            if registered_ratio < float(config.min_registered_image_ratio):
                raise RuntimeError(
                    f"Only {registered_images}/{selected_image_count} images registered "
                    f"({registered_ratio:.1%}), below the stability floor "
                    f"({config.min_registered_image_ratio:.0%})."
                )
            logger.info(
                "COLMAP registered %d/%d images (%.1f%%) with %d verified pairs.",
                registered_images,
                selected_image_count,
                registered_ratio * 100,
                geometric_matches,
            )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("COLMAP timed out during sparse reconstruction") from exc

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
