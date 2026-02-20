"""Page 3: Results — volume, weight, and 3D viewer."""

import io

import numpy as np
import open3d as o3d
import streamlit as st

from stockpile.visualization import build_3d_figure

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))
from components.session_init import init_session_state

init_session_state()
st.header("3. Results")

result = st.session_state.get("pipeline_result")
if result is None or result.error:
    st.warning("No results available. Run the pipeline on the Processing page first.")
    if result and result.error:
        st.error(f"Last run failed: {result.error}")
    st.stop()

# Big numbers
st.subheader("Estimated Weight & Volume")

vol = result.volume
col1, col2, col3 = st.columns(3)
col1.metric("Volume (recommended)", f"{vol.recommended_m3:.2f} m³")
col2.metric("Weight", f"{result.weight_kg:.0f} kg")
col3.metric("Weight", f"{result.weight_kg / 1000:.2f} tonnes")

# Calibration info
if result.calibration:
    cal = result.calibration
    st.info(
        f"Scale: {cal.scale_factor:.4f} m/unit | "
        f"Confidence: {cal.confidence:.0%} | "
        f"Cones used: {cal.num_cones_used}"
    )

# Volume method comparison tabs
st.subheader("Volume Methods")
tab1, tab2, tab3 = st.tabs(["Grid Integration (Recommended)", "Convex Hull", "Alpha Shape"])

with tab1:
    st.metric("2.5D Grid Integration", f"{vol.grid_integration_m3:.2f} m³")
    st.caption(f"Grid resolution: {vol.grid_resolution:.2f}m, {vol.num_points} pile points")

with tab2:
    st.metric("Convex Hull", f"{vol.convex_hull_m3:.2f} m³")
    st.caption("Upper bound — wraps all points in a convex shape")

with tab3:
    if vol.alpha_shape_m3 is not None:
        st.metric("Alpha Shape", f"{vol.alpha_shape_m3:.2f} m³")
    else:
        st.warning("Alpha shape computation failed or produced non-watertight mesh")

# 3D Viewer
st.subheader("3D Point Cloud")
if result.pile_cloud and len(result.pile_cloud.points) > 0:
    fig = build_3d_figure(
        result.pile_cloud,
        result.ground_cloud,
        result.cone_3d_positions if result.cone_3d_positions else None,
    )
    st.plotly_chart(fig, use_container_width=True)
else:
    st.warning("No pile points to display.")

# Download PLY
st.subheader("Download")
if result.ply_path and result.ply_path.exists():
    with open(result.ply_path, "rb") as f:
        st.download_button(
            label="Download Sparse Point Cloud (PLY)",
            data=f.read(),
            file_name="stockpile_sparse.ply",
            mime="application/octet-stream",
        )
