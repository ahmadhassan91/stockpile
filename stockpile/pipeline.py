"""Pipeline orchestrator wiring all stages together."""

import logging
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import open3d as o3d

from .colmap_runner import (
    export_to_ply,
    read_cameras_binary,
    read_images_binary,
    read_points3d_binary,
    run_colmap_reconstruction,
)
from .cone_detection import detect_cones_in_frames
from .config import PipelineConfig
from .frame_extraction import extract_frames
from .ground_plane import load_and_scale_point_cloud, segment_pile
from .scale_calibration import CalibrationResult, calibrate_scale
from .volume import VolumeResult, compute_volume

logger = logging.getLogger(__name__)


@dataclass
class PipelineResult:
    num_frames: int = 0
    num_frames_with_cones: int = 0
    num_colmap_points: int = 0
    num_colmap_images: int = 0
    calibration: CalibrationResult | None = None
    volume: VolumeResult | None = None
    weight_kg: float = 0.0
    pile_cloud: o3d.geometry.PointCloud | None = None
    ground_cloud: o3d.geometry.PointCloud | None = None
    cone_3d_positions: list[np.ndarray] = field(default_factory=list)
    sparse_model_dir: Path | None = None
    ply_path: Path | None = None
    stage: str = ""
    error: str | None = None


class Pipeline:
    """Orchestrates the full stockpile estimation pipeline."""

    def __init__(self, config: PipelineConfig):
        self.config = config
        self._cancelled = False

    def cancel(self):
        self._cancelled = True

    def _check_cancel(self):
        if self._cancelled:
            raise RuntimeError("Pipeline cancelled by user")

    def _report(self, stage: str, progress: float, message: str = ""):
        if self.config.progress_callback:
            self.config.progress_callback(stage, progress, message)
        logger.info("[%s] %.0f%% %s", stage, progress * 100, message)

    def run(self, video_path: str | Path) -> PipelineResult:
        """Run the full pipeline on a video file."""
        video_path = Path(video_path)
        result = PipelineResult()

        try:
            # Setup workspace
            self.config.workspace.mkdir(parents=True, exist_ok=True)
            self.config.images_dir.mkdir(parents=True, exist_ok=True)
            self.config.output_dir.mkdir(parents=True, exist_ok=True)

            # Stage 1: Frame Extraction
            result.stage = "frame_extraction"
            self._report("frame_extraction", 0, "Extracting frames from video...")
            self._check_cancel()

            frame_paths = extract_frames(
                video_path,
                self.config.images_dir,
                self.config.frame_extraction,
                progress_callback=lambda p: self._report("frame_extraction", p * 0.9),
            )
            result.num_frames = len(frame_paths)
            self._report("frame_extraction", 1.0, f"Extracted {len(frame_paths)} frames")

            if not frame_paths:
                raise RuntimeError("No frames extracted from video")

            # Stage 2: Cone Detection
            result.stage = "cone_detection"
            self._report("cone_detection", 0, "Detecting cones...")
            self._check_cancel()

            cone_detections = detect_cones_in_frames(
                frame_paths,
                self.config.cone_detection,
                progress_callback=lambda p: self._report("cone_detection", p * 0.9),
            )
            result.num_frames_with_cones = len(cone_detections)
            self._report("cone_detection", 1.0,
                         f"Found cones in {len(cone_detections)} frames")

            if not cone_detections:
                logger.warning("No cones detected — scale calibration will not be possible")

            # Stage 3: COLMAP Reconstruction
            result.stage = "colmap_reconstruction"
            self._report("colmap_reconstruction", 0, "Running COLMAP sparse reconstruction...")
            self._check_cancel()

            # Clear stale COLMAP workspace so we always do a fresh reconstruction
            if self.config.colmap_dir.exists():
                shutil.rmtree(self.config.colmap_dir)
            self.config.colmap_dir.mkdir(parents=True)

            model_dir = run_colmap_reconstruction(
                self.config.images_dir,
                self.config.colmap_dir,
                self.config.colmap,
                progress_callback=lambda p: self._report("colmap_reconstruction", p),
            )
            result.sparse_model_dir = model_dir

            # Export PLY
            ply_path = self.config.output_dir / "sparse.ply"
            export_to_ply(model_dir, ply_path, self.config.colmap.colmap_binary)
            result.ply_path = ply_path

            # Parse COLMAP binary files
            cameras = read_cameras_binary(model_dir / "cameras.bin")
            images = read_images_binary(model_dir / "images.bin")
            points3d = read_points3d_binary(model_dir / "points3D.bin")
            result.num_colmap_points = len(points3d)
            result.num_colmap_images = len(images)

            self._report("colmap_reconstruction", 1.0,
                         f"{len(points3d)} 3D points, {len(images)} images registered")

            if not points3d:
                raise RuntimeError("COLMAP produced no 3D points")

            # Stage 4: Scale Calibration
            result.stage = "scale_calibration"
            self._report("scale_calibration", 0, "Calibrating scale from cones...")
            self._check_cancel()

            if self.config.manual_scale_override is not None:
                scale_factor = self.config.manual_scale_override
                if cone_detections:
                    try:
                        calibration = calibrate_scale(
                            cone_detections, images, points3d,
                            self.config.scale_calibration, cameras,
                        )
                        result.calibration = calibration
                        result.cone_3d_positions = calibration.cone_3d_positions
                    except Exception:
                        pass
                self._report("scale_calibration", 1.0,
                             f"Manual scale override: {scale_factor:.4f} m/unit")
            elif cone_detections:
                calibration = calibrate_scale(
                    cone_detections, images, points3d,
                    self.config.scale_calibration, cameras,
                )
                result.calibration = calibration
                result.cone_3d_positions = calibration.cone_3d_positions
                scale_factor = calibration.scale_factor
                self._report("scale_calibration", 1.0,
                             f"Scale: {scale_factor:.4f} m/unit, confidence: {calibration.confidence:.2f}")
            else:
                scale_factor = 1.0
                self._report("scale_calibration", 1.0,
                             "No cones — using unit scale (results in COLMAP units)")

            # Stage 5: Ground Plane & Segmentation
            result.stage = "ground_plane"
            self._report("ground_plane", 0, "Fitting ground plane...")
            self._check_cancel()

            all_xyz = np.array([p.xyz for p in points3d.values()])
            all_rgb = np.array([p.rgb for p in points3d.values()])

            pcd = load_and_scale_point_cloud(all_xyz, all_rgb, scale_factor)

            # Transform cone positions to scaled coordinates
            scaled_cone_positions = [
                pos * scale_factor for pos in result.cone_3d_positions
            ]

            gp_result = segment_pile(pcd, self.config.ground_plane, scaled_cone_positions)
            result.pile_cloud = gp_result.pile_cloud
            result.ground_cloud = gp_result.ground_cloud

            # Update cone positions to transformed coordinates
            if scaled_cone_positions:
                T = gp_result.transform_matrix
                result.cone_3d_positions = []
                for pos in scaled_cone_positions:
                    p = np.append(pos, 1.0)
                    result.cone_3d_positions.append((T @ p)[:3])

            self._report("ground_plane", 1.0,
                         f"{len(gp_result.pile_cloud.points)} pile points segmented")

            # Stage 6: Volume Computation
            result.stage = "volume_computation"
            self._report("volume_computation", 0, "Computing volume...")
            self._check_cancel()

            vol = compute_volume(gp_result.pile_cloud, self.config.volume)
            result.volume = vol
            result.weight_kg = vol.recommended_m3 * self.config.material_density

            self._report("volume_computation", 1.0,
                         f"Volume: {vol.recommended_m3:.2f} m³, Weight: {result.weight_kg:.0f} kg")

            result.stage = "complete"

        except Exception as e:
            result.error = str(e)
            logger.exception("Pipeline failed at stage '%s'", result.stage)

        return result
