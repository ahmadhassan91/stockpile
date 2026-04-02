"""Sidebar component for pipeline parameters."""

import streamlit as st

from stockpile.config import DENSITY_PRESETS, DENSITY_RANGES, PipelineConfig

PRESET_NAMES = list(DENSITY_PRESETS.keys())
MATERIAL_OPTIONS = PRESET_NAMES + ["Custom"]

DEFAULT_SETTING_STATE = {
    "sidebar_material_select": MATERIAL_OPTIONS[0],
    "sidebar_density_input": 1600.0,
    "sidebar_cone_height": 0.75,
    "sidebar_camera_height": 1.6,
    "sidebar_manual_scale_enabled": False,
    "sidebar_manual_scale_value": 1.0,
    "sidebar_frame_interval": 0.25,
    "sidebar_max_frames": 800,
    "sidebar_colmap_quality": "medium",
    "sidebar_above_ground": 0.10,
    "sidebar_grid_resolution": 0.05,
    "sidebar_admin_mode": False,
}

SIDEBAR_SETTING_KEYS = tuple(DEFAULT_SETTING_STATE.keys())
PIPELINE_SIGNATURE_KEYS = tuple(
    key for key in SIDEBAR_SETTING_KEYS if key != "sidebar_admin_mode"
)
PENDING_SIDEBAR_OVERRIDES_KEY = "pending_sidebar_setting_overrides"


def ensure_pipeline_setting_state():
    """Seed Streamlit session state with stable pipeline defaults."""
    for key, value in DEFAULT_SETTING_STATE.items():
        if key not in st.session_state:
            st.session_state[key] = value


def queue_sidebar_setting_overrides(overrides: dict):
    """Queue sidebar widget value updates for the next safe rerun."""
    pending = dict(st.session_state.get(PENDING_SIDEBAR_OVERRIDES_KEY, {}))
    for key, value in overrides.items():
        if key in DEFAULT_SETTING_STATE:
            pending[key] = value
    st.session_state[PENDING_SIDEBAR_OVERRIDES_KEY] = pending


def apply_pending_sidebar_setting_overrides():
    """Apply queued sidebar widget updates before widgets are instantiated."""
    pending = st.session_state.pop(PENDING_SIDEBAR_OVERRIDES_KEY, None)
    if not pending:
        return
    ensure_pipeline_setting_state()
    for key, value in pending.items():
        if key in DEFAULT_SETTING_STATE:
            st.session_state[key] = value


def get_density_selection() -> tuple[str, float, str]:
    """Resolve the currently selected material and effective density."""
    material = st.session_state.get("sidebar_material_select", MATERIAL_OPTIONS[0])
    if material == "Custom":
        density = float(st.session_state.get("sidebar_density_input", 1600.0))
        density_display = f"{density:.0f} kg/m³"
    else:
        density = float(DENSITY_PRESETS[material])
        density_display = f"{density/1000:.2f} MT/m³ (max)"
    return material, density, density_display


def build_pipeline_config_from_state() -> PipelineConfig:
    """Build a PipelineConfig from the persisted sidebar state."""
    ensure_pipeline_setting_state()
    material, density, _ = get_density_selection()

    config = PipelineConfig(
        material_density=density,
        material_name=material if material != "Custom" else "custom",
    )
    config.scale_calibration.known_cone_height_m = float(st.session_state["sidebar_cone_height"])
    config.scale_calibration.assumed_camera_height_m = float(st.session_state["sidebar_camera_height"])
    config.frame_extraction.interval_sec = float(st.session_state["sidebar_frame_interval"])
    config.frame_extraction.max_frames = int(st.session_state["sidebar_max_frames"])
    config.colmap.quality = st.session_state["sidebar_colmap_quality"]
    config.volume.grid_resolution = float(st.session_state["sidebar_grid_resolution"])
    config.ground_plane.above_ground_threshold = float(st.session_state["sidebar_above_ground"])
    return config


def persist_pipeline_selection_metadata():
    """Store the user-facing selection summary for other pages."""
    material, density, density_display = get_density_selection()
    st.session_state["manual_scale_override"] = (
        float(st.session_state["sidebar_manual_scale_value"])
        if st.session_state.get("sidebar_manual_scale_enabled")
        else None
    )
    st.session_state["selected_material"] = material
    st.session_state["selected_density"] = density
    st.session_state["selected_density_display"] = density_display


def get_pipeline_setting_signature() -> tuple:
    """Return a stable signature for the current sidebar settings."""
    ensure_pipeline_setting_state()
    return tuple((key, st.session_state.get(key)) for key in PIPELINE_SIGNATURE_KEYS)


def render_parameter_sidebar() -> PipelineConfig:
    """Render the parameter sidebar and return a PipelineConfig."""
    ensure_pipeline_setting_state()
    apply_pending_sidebar_setting_overrides()

    st.sidebar.header("⚙️ Pipeline Settings")
    st.sidebar.caption(
        "Client mode keeps the measurement knobs on safe auto-pilot. "
        "Switch on admin mode only when we need to override the defaults."
    )
    st.sidebar.toggle(
        "Admin mode",
        key="sidebar_admin_mode",
        help="Show the full pipeline controls for internal testing and calibration work.",
    )
    admin_mode = bool(st.session_state.get("sidebar_admin_mode"))

    # ── Material ──────────────────────────────────────────────────────────
    st.sidebar.subheader("🪨 Material")

    material = st.sidebar.selectbox(
        "Material type",
        options=MATERIAL_OPTIONS,
        key="sidebar_material_select",
        help="Select the material being measured. Density is set to the maximum value "
        "from the site density table. You can also choose Custom to enter any density.",
    )

    if material == "Custom":
        density = st.sidebar.number_input(
            "Density (kg/m³)",
            min_value=100.0,
            max_value=5000.0,
            step=50.0,
            key="sidebar_density_input",
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

    recommended_profile = st.session_state.get("recommended_processing_profile")
    recommended_notes = st.session_state.get("recommended_processing_notes", [])
    ai_preflight = st.session_state.get("ai_preflight_result")
    if recommended_profile:
        st.sidebar.success(f"Auto processing profile: {recommended_profile}")
        if recommended_notes:
            st.sidebar.caption(recommended_notes[0])
    if ai_preflight is not None:
        st.sidebar.caption(
            f"AI preflight: cone visibility {ai_preflight.cone_visibility_score:.0%} "
            f"via {ai_preflight.provider} {ai_preflight.model}"
        )
        if ai_preflight.retake_required:
            st.sidebar.warning(f"AI retake suggestion: {ai_preflight.retake_reason}")

    if not admin_mode:
        st.sidebar.info(
            "Advanced capture and reconstruction settings are managed automatically "
            "for client-facing runs. Turn on admin mode if we need to tune them."
        )

    # ── Scale Calibration ─────────────────────────────────────────────────
    if admin_mode:
        st.sidebar.subheader("📏 Scale Calibration")

        st.sidebar.number_input(
            "Cone height (m)",
            min_value=0.1,
            max_value=2.0,
            step=0.05,
            key="sidebar_cone_height",
            help="Height of the traffic cones placed around the stockpile. "
            "Standard cone = 0.75 m. Mini cone = 0.50 m. Measure yours if unsure.",
        )
        st.sidebar.number_input(
            "Camera height above ground (m)",
            min_value=0.5,
            max_value=3.0,
            step=0.1,
            key="sidebar_camera_height",
            help="Height of the phone/camera during filming. "
            "Used as fallback when cone detection fails.",
        )

        st.sidebar.markdown("**Manual scale override**")
        st.sidebar.checkbox(
            "Override auto-detected scale",
            key="sidebar_manual_scale_enabled",
            help="If the auto-calibration is wrong, enter the scale factor here. "
            "Increase the value to make the volume larger.",
        )
        if st.session_state.get("sidebar_manual_scale_enabled"):
            st.sidebar.number_input(
                "Scale factor (m / COLMAP unit)",
                min_value=0.001,
                max_value=200.0,
                step=0.1,
                key="sidebar_manual_scale_value",
                help="Metres per COLMAP unit. "
                "Tip: if reported volume is 4× too small, multiply current factor by 4.",
            )
            st.sidebar.info(
                "💡 **How to estimate:** measure the real-world distance between two "
                "visible points, divide by their 3D COLMAP distance, and enter the result."
            )

    # ── Frame Extraction ──────────────────────────────────────────────────
    if admin_mode:
        st.sidebar.subheader("🎞️ Frame Extraction")
        st.sidebar.slider(
            "Frame interval (sec)",
            min_value=0.1,
            max_value=2.0,
            step=0.05,
            key="sidebar_frame_interval",
            help="Sample one frame every N seconds. Lower = more frames = better 3D model, "
            "but longer processing time.",
        )
        st.sidebar.number_input(
            "Max frames",
            min_value=100,
            max_value=2000,
            step=100,
            key="sidebar_max_frames",
            help="Cap on number of frames sent to COLMAP. Larger piles need more frames.",
        )

    # ── COLMAP Reconstruction ─────────────────────────────────────────────
    if admin_mode:
        st.sidebar.subheader("🏗️ 3D Reconstruction")
        st.sidebar.select_slider(
            "COLMAP quality",
            options=["low", "medium", "high"],
            key="sidebar_colmap_quality",
            help="Higher quality = better 3D model but longer processing time.",
        )

    # ── Ground Plane ──────────────────────────────────────────────────────
    if admin_mode:
        st.sidebar.subheader("🌍 Ground Plane")
        st.sidebar.slider(
            "Min pile height above ground (m)",
            min_value=0.01,
            max_value=0.5,
            step=0.01,
            key="sidebar_above_ground",
            help="Points below this height are classified as ground, not pile. "
            "Increase if ground noise is being counted as pile material.",
        )

    # ── Volume ────────────────────────────────────────────────────────────
    if admin_mode:
        st.sidebar.subheader("📐 Volume Computation")
        st.sidebar.slider(
            "Grid resolution (m)",
            min_value=0.01,
            max_value=0.5,
            step=0.01,
            key="sidebar_grid_resolution",
            help="Cell size for 2.5D grid integration. Smaller = more detail "
            "but slower. 0.05 m is recommended for most piles.",
        )

    config = build_pipeline_config_from_state()
    st.session_state["manual_scale_override"] = (
        float(st.session_state["sidebar_manual_scale_value"])
        if st.session_state.get("sidebar_manual_scale_enabled")
        else None
    )
    st.session_state["selected_material"] = material
    st.session_state["selected_density"] = density
    st.session_state["selected_density_display"] = density_display
    return config
