"""Page 4: Debug — intermediate results inspection."""

from pathlib import Path

import cv2
import numpy as np
import streamlit as st

from stockpile.colmap_runner import get_reconstruction_stats
from stockpile.cone_detection import ConeDetection, detect_cones, draw_cone_overlays
from stockpile.config import PipelineConfig

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from components.session_init import init_session_state

init_session_state()

st.header("4. Debug & Inspection")

result = st.session_state.get("pipeline_result")
config = st.session_state.get("pipeline_config", PipelineConfig())

# Section 1: Frame Gallery with Cone Overlays
st.subheader("Cone Detection Gallery")

if config.images_dir.exists():
    frame_paths = sorted(config.images_dir.glob("*.jpg")) + sorted(config.images_dir.glob("*.png"))

    if frame_paths:
        # Frame selector
        num_cols = 3
        total_to_show = st.slider("Frames to display", 3, min(30, len(frame_paths)), 9)
        step = max(1, len(frame_paths) // total_to_show)
        selected_frames = frame_paths[::step][:total_to_show]

        cols = st.columns(num_cols)
        for i, fp in enumerate(selected_frames):
            frame = cv2.imread(str(fp))
            if frame is None:
                continue
            dets = detect_cones(frame, config.cone_detection)
            overlay = draw_cone_overlays(frame, dets) if dets else frame
            with cols[i % num_cols]:
                st.image(
                    cv2.cvtColor(overlay, cv2.COLOR_BGR2RGB),
                    caption=f"{fp.name} ({len(dets)} cones)",
                    use_container_width=True,
                )
    else:
        st.info("No frames found. Run the pipeline first.")
else:
    st.info("No workspace found. Run the pipeline first.")

# Section 2: COLMAP Stats
st.subheader("COLMAP Reconstruction Stats")

if result and result.sparse_model_dir and result.sparse_model_dir.exists():
    try:
        stats = get_reconstruction_stats(result.sparse_model_dir)
        col1, col2 = st.columns(2)
        col1.metric("Registered Images", stats["num_images"])
        col2.metric("3D Points", stats["num_points"])

        if stats["bbox_min"] and stats["bbox_max"]:
            bbox_min = np.array(stats["bbox_min"])
            bbox_max = np.array(stats["bbox_max"])
            extent = bbox_max - bbox_min
            st.write(f"**Bounding box extent**: {extent[0]:.2f} × {extent[1]:.2f} × {extent[2]:.2f} (COLMAP units)")

        if stats["mean_reprojection_error"]:
            st.metric("Mean Reprojection Error", f"{stats['mean_reprojection_error']:.3f} px")
    except Exception as e:
        st.error(f"Could not read COLMAP stats: {e}")
else:
    st.info("No COLMAP reconstruction available.")

# Section 3: Scale Calibration Details
st.subheader("Scale Calibration Details")

if result and result.calibration:
    cal = result.calibration
    st.write(f"**Scale factor**: {cal.scale_factor:.6f} m/COLMAP unit")
    st.write(f"**Confidence**: {cal.confidence:.2%}")
    st.write(f"**Cones used**: {cal.num_cones_used}")

    if cal.per_cone_scales:
        st.write("**Per-cone scale factors:**")
        for i, s in enumerate(cal.per_cone_scales):
            st.write(f"  - Cone {i+1}: {s:.6f} m/unit")

        mean_s = np.mean(cal.per_cone_scales)
        std_s = np.std(cal.per_cone_scales)
        st.write(f"  - Mean: {mean_s:.6f}, Std: {std_s:.6f}, CV: {std_s/mean_s:.2%}" if mean_s > 0 else "")
else:
    st.info("No calibration data available.")

# Section 4: Ground Plane Fit
st.subheader("Ground Plane Fit")

if result and result.pile_cloud:
    pile_pts = np.asarray(result.pile_cloud.points)
    if len(pile_pts) > 0:
        st.write(f"**Pile points**: {len(pile_pts)}")
        st.write(f"**Height range**: {pile_pts[:, 2].min():.3f} — {pile_pts[:, 2].max():.3f} m")
        st.write(f"**XY extent**: {pile_pts[:, 0].ptp():.2f} × {pile_pts[:, 1].ptp():.2f} m")

    if result.ground_cloud:
        ground_pts = np.asarray(result.ground_cloud.points)
        st.write(f"**Ground points**: {len(ground_pts)}")
else:
    st.info("No segmentation data available.")
