"""Sidebar component for pipeline parameters."""

import streamlit as st

from stockpile.config import DENSITY_PRESETS, PipelineConfig


def render_parameter_sidebar() -> PipelineConfig:
    """Render the parameter sidebar and return a PipelineConfig."""
    st.sidebar.header("Pipeline Settings")

    # Material
    st.sidebar.subheader("Material")
    material = st.sidebar.selectbox(
        "Material type",
        options=list(DENSITY_PRESETS.keys()) + ["custom"],
        index=0,
    )
    if material == "custom":
        density = st.sidebar.number_input("Density (kg/m³)", value=1500.0, min_value=100.0, max_value=5000.0)
    else:
        density = float(DENSITY_PRESETS[material])
        st.sidebar.info(f"Density: {density:.0f} kg/m³")

    # Cone settings
    st.sidebar.subheader("Scale Calibration")
    cone_height = st.sidebar.number_input(
        "Cone height (m)", value=0.75, min_value=0.1, max_value=2.0, step=0.05,
    )
    camera_height = st.sidebar.number_input(
        "Camera height (m)", value=1.6, min_value=0.5, max_value=3.0, step=0.1,
        help="Height of the phone/camera above ground during filming",
    )

    use_manual_scale = st.sidebar.checkbox("Override scale manually", value=False)
    manual_scale = None
    if use_manual_scale:
        manual_scale = st.sidebar.number_input(
            "Scale factor (m/COLMAP unit)",
            value=1.0, min_value=0.01, max_value=100.0, step=0.1,
            help="If auto-calibration is inaccurate, set this manually. "
                 "Increase to make the model larger, decrease to shrink.",
        )

    # Frame extraction
    st.sidebar.subheader("Frame Extraction")
    interval = st.sidebar.slider(
        "Frame interval (sec)", min_value=0.1, max_value=2.0, value=0.5, step=0.1,
    )

    # COLMAP quality
    st.sidebar.subheader("Reconstruction")
    quality = st.sidebar.select_slider(
        "COLMAP quality", options=["low", "medium", "high"], value="medium",
    )

    # Volume
    st.sidebar.subheader("Volume")
    grid_res = st.sidebar.slider(
        "Grid resolution (m)", min_value=0.01, max_value=0.2, value=0.05, step=0.01,
    )

    config = PipelineConfig(
        material_density=density,
        material_name=material if material != "custom" else "custom",
    )
    config.scale_calibration.known_cone_height_m = cone_height
    config.scale_calibration.assumed_camera_height_m = camera_height
    config.frame_extraction.interval_sec = interval
    config.colmap.quality = quality
    config.volume.grid_resolution = grid_res

    # Store manual scale in session state for the pipeline to use
    st.session_state["manual_scale_override"] = manual_scale

    return config
