"""Sidebar component for pipeline parameters."""

import streamlit as st

from stockpile.config import DENSITY_PRESETS, DENSITY_RANGES, PipelineConfig


def render_parameter_sidebar() -> PipelineConfig:
    """Render the parameter sidebar and return a PipelineConfig."""
    st.sidebar.header("⚙️ Pipeline Settings")

    # ── Material ──────────────────────────────────────────────────────────
    st.sidebar.subheader("🪨 Material")

    preset_names = list(DENSITY_PRESETS.keys())
    material = st.sidebar.selectbox(
        "Material type",
        options=preset_names + ["Custom"],
        index=0,
        help="Select the material being measured. Density is set to the maximum value "
             "from the site density table. You can also choose Custom to enter any density.",
    )

    if material == "Custom":
        density = st.sidebar.number_input(
            "Density (kg/m³)",
            value=1600.0, min_value=100.0, max_value=5000.0, step=50.0,
        )
        density_display = f"{density:.0f} kg/m³"
    else:
        lo, hi = DENSITY_RANGES[material]
        density = float(DENSITY_PRESETS[material])
        st.sidebar.info(
            f"**Bulk density range:** {lo/1000:.2f} – {hi/1000:.2f} MT/m³  \n"
            f"**Using max value:** {density/1000:.2f} MT/m³ ({density:.0f} kg/m³)"
        )
        density_display = f"{density/1000:.2f} MT/m³ (max)"

    # ── Scale Calibration ─────────────────────────────────────────────────
    st.sidebar.subheader("📏 Scale Calibration")
    cone_height = st.sidebar.number_input(
        "Cone height (m)",
        value=0.75, min_value=0.1, max_value=2.0, step=0.05,
        help="Height of the traffic cones placed around the stockpile. "
             "Standard cone = 0.75 m. Mini cone = 0.50 m. Measure yours if unsure.",
    )
    camera_height = st.sidebar.number_input(
        "Camera height above ground (m)",
        value=1.6, min_value=0.5, max_value=3.0, step=0.1,
        help="Height of the phone/camera during filming. "
             "Used as fallback when cone detection fails.",
    )

    st.sidebar.markdown("**Manual scale override**")
    use_manual_scale = st.sidebar.checkbox(
        "Override auto-detected scale",
        value=False,
        help="If the auto-calibration is wrong, enter the scale factor here. "
             "Increase the value to make the volume larger.",
    )
    manual_scale = None
    if use_manual_scale:
        manual_scale = st.sidebar.number_input(
            "Scale factor (m / COLMAP unit)",
            value=1.0, min_value=0.001, max_value=200.0, step=0.1,
            help="Metres per COLMAP unit. "
                 "Tip: if reported volume is 4× too small, multiply current factor by 4.",
        )
        st.sidebar.info(
            "💡 **How to estimate:** measure the real-world distance between two "
            "visible points, divide by their 3D COLMAP distance, and enter the result."
        )

    # ── Frame Extraction ──────────────────────────────────────────────────
    st.sidebar.subheader("🎞️ Frame Extraction")
    interval = st.sidebar.slider(
        "Frame interval (sec)",
        min_value=0.1, max_value=2.0, value=0.25, step=0.05,
        help="Sample one frame every N seconds. Lower = more frames = better 3D model, "
             "but longer processing time.",
    )
    max_frames = st.sidebar.number_input(
        "Max frames",
        value=800, min_value=100, max_value=2000, step=100,
        help="Cap on number of frames sent to COLMAP. Larger piles need more frames.",
    )

    # ── COLMAP Reconstruction ─────────────────────────────────────────────
    st.sidebar.subheader("🏗️ 3D Reconstruction")
    quality = st.sidebar.select_slider(
        "COLMAP quality",
        options=["low", "medium", "high"],
        value="medium",
        help="Higher quality = better 3D model but longer processing time.",
    )

    # ── Ground Plane ──────────────────────────────────────────────────────
    st.sidebar.subheader("🌍 Ground Plane")
    above_ground = st.sidebar.slider(
        "Min pile height above ground (m)",
        min_value=0.01, max_value=0.5, value=0.10, step=0.01,
        help="Points below this height are classified as ground, not pile. "
             "Increase if ground noise is being counted as pile material.",
    )

    # ── Volume ────────────────────────────────────────────────────────────
    st.sidebar.subheader("📐 Volume Computation")
    grid_res = st.sidebar.slider(
        "Grid resolution (m)",
        min_value=0.01, max_value=0.5, value=0.05, step=0.01,
        help="Cell size for 2.5D grid integration. Smaller = more detail "
             "but slower. 0.05 m is recommended for most piles.",
    )

    # ── Build config ──────────────────────────────────────────────────────
    config = PipelineConfig(
        material_density=density,
        material_name=material if material != "Custom" else "custom",
    )
    config.scale_calibration.known_cone_height_m = cone_height
    config.scale_calibration.assumed_camera_height_m = camera_height
    config.frame_extraction.interval_sec = interval
    config.frame_extraction.max_frames = int(max_frames)
    config.colmap.quality = quality
    config.volume.grid_resolution = grid_res
    config.ground_plane.above_ground_threshold = above_ground

    # Store for pipeline page
    st.session_state["manual_scale_override"] = manual_scale
    st.session_state["selected_material"] = material
    st.session_state["selected_density"] = density
    st.session_state["selected_density_display"] = density_display

    return config
