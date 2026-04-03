"""Page 4: Debug — intermediate results inspection."""

from pathlib import Path

import cv2
import numpy as np
import streamlit as st

LOG_FILE = "/tmp/stockpile_app.log"


def render_log_viewer(lines: int = 100, key_prefix: str = "debug"):
    """Render a live log viewer section."""
    st.subheader("Live Logs")
    col_refresh, col_lines, col_clear = st.columns([1, 2, 1])
    with col_lines:
        lines = st.slider("Lines to show", 20, 500, lines, key=f"{key_prefix}_log_lines")
    with col_clear:
        if st.button("Clear log", key=f"{key_prefix}_clear_log"):
            try:
                open(LOG_FILE, "w").close()
            except Exception:
                pass
    with col_refresh:
        st.button("Refresh", key=f"{key_prefix}_refresh_log")

    try:
        with open(LOG_FILE) as f:
            all_lines = f.readlines()
        tail = all_lines[-lines:] if len(all_lines) > lines else all_lines
        log_text = "".join(tail) if tail else "(no log entries yet)"
    except FileNotFoundError:
        log_text = "(log file not found — run the app first)"
    except Exception as e:
        log_text = f"(error reading log: {e})"

    st.code(log_text, language=None)

from stockpile.colmap_runner import get_reconstruction_stats
from stockpile.cone_detection import ConeDetection, detect_cones, draw_cone_overlays
from stockpile.config import PipelineConfig

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from components.reliability_status import classify_result_status
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
                    width="stretch",
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
    crosscheck_min_conf = config.scale_calibration.min_camera_height_confidence_for_crosscheck
    st.write(f"**Scale factor used**: {(result.scale_factor_m_per_unit or cal.scale_factor):.6f} m/COLMAP unit")
    st.write(f"**Scale source**: {result.scale_source}")
    st.write(f"**Confidence**: {cal.confidence:.2%}")
    st.write(f"**Cones used**: {cal.num_cones_used}")
    if cal.projection_scale_factor is not None:
        st.write(f"**Projection scale**: {cal.projection_scale_factor:.6f} m/unit")
    if cal.camera_height_scale_factor is not None:
        st.write(f"**Camera-height scale**: {cal.camera_height_scale_factor:.6f} m/unit")
    if cal.camera_height_confidence is not None:
        st.write(f"**Camera-height confidence**: {cal.camera_height_confidence:.2%}")
    if (
        cal.camera_height_scale_factor is not None
        and cal.camera_height_confidence is not None
        and cal.camera_height_confidence < crosscheck_min_conf
    ):
        st.write("**Cross-check status**: skipped (ground-plane fit was not stable enough)")
    elif cal.scale_disagreement_ratio is not None:
        st.write(f"**Scale disagreement**: {cal.scale_disagreement_ratio:.2f}x")
    else:
        st.write("**Cross-check status**: aligned or unavailable")

    if cal.per_cone_scales:
        st.write("**Per-cone scale factors:**")
        for i, s in enumerate(cal.per_cone_scales):
            st.write(f"  - Cone {i+1}: {s:.6f} m/unit")

        mean_s = np.mean(cal.per_cone_scales)
        std_s = np.std(cal.per_cone_scales)
        st.write(f"  - Mean: {mean_s:.6f}, Std: {std_s:.6f}, CV: {std_s/mean_s:.2%}" if mean_s > 0 else "")

    if cal.notes:
        st.write("**Calibration notes:**")
        for note in cal.notes:
            st.write(f"  - {note}")
else:
    st.info("No calibration data available.")

# Section 4: Ground Plane Fit
st.subheader("Ground Plane Fit")


if result and result.pile_cloud:
    pile_pts = np.asarray(result.pile_cloud.points)
    if len(pile_pts) > 0:
        st.write(f"**Pile points**: {len(pile_pts)}")
        st.write(f"**Height range**: {pile_pts[:, 2].min():.3f} — {pile_pts[:, 2].max():.3f} m")
        if len(pile_pts) >= 100:
            p99 = float(np.percentile(pile_pts[:, 2], 99))
            st.write(f"**99th percentile height**: {p99:.3f} m")
            st.write(f"**Peak relief over P99**: {pile_pts[:, 2].max() - p99:.3f} m")
        st.write(f"**XY extent**: {np.ptp(pile_pts[:, 0]):.2f} × {np.ptp(pile_pts[:, 1]):.2f} m")

    if result.ground_cloud:
        ground_pts = np.asarray(result.ground_cloud.points)
        st.write(f"**Ground points**: {len(ground_pts)}")
else:
    st.info("No segmentation data available.")

st.subheader("Measurement Reliability")
if result:
    status = classify_result_status(result)
    st.write(f"**Status**: {status.title}")
    st.write(f"**Publishable**: {'Yes' if result.publishable else 'No'}")
    st.write(f"**Review grade**: {'Yes' if getattr(result, 'review_grade', False) else 'No'}")
    if result.volume:
        st.write(f"**Grid occupancy**: {result.volume.grid_occupancy_pct:.2f}%")
        if result.volume.grid_to_hull_ratio is not None:
            st.write(f"**Grid / hull ratio**: {result.volume.grid_to_hull_ratio:.2f}x")
        if result.volume.footprint_area_m2 is not None:
            st.write(
                f"**Footprint**: {result.volume.footprint_area_m2:.2f} m² "
                f"({result.volume.footprint_source})"
            )
        if getattr(result.volume, "toe_candidate_points", 0):
            toe_label = f"{result.volume.toe_height_upper_m:.2f} m" if result.volume.toe_height_upper_m is not None else "n/a"
            st.write(
                f"**Toe candidates**: {result.volume.toe_candidate_points:,} "
                f"(upper toe band {toe_label})"
            )
        st.write(f"**Recommended volume method**: {result.volume.recommended_method}")

    if result.quality_blockers:
        st.write("**Blockers:**")
        for blocker in result.quality_blockers:
            st.write(f"  - {blocker}")

    if result.quality_warnings:
        st.write("**Warnings:**")
        for warning in result.quality_warnings:
            st.write(f"  - {warning}")

st.divider()
render_log_viewer(lines=150, key_prefix="debug")
