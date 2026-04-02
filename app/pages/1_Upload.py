"""Page 1: Video upload and configuration."""

import tempfile
from pathlib import Path
import re

import cv2
import streamlit as st

from stockpile.cone_detection import detect_cones, draw_cone_overlays
from stockpile.config import DENSITY_PRESETS, DENSITY_RANGES
from stockpile.frame_extraction import get_first_frame, get_video_info

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from components.parameter_sidebar import (
    build_pipeline_config_from_state,
    queue_sidebar_setting_overrides,
    render_parameter_sidebar,
    SIDEBAR_SETTING_KEYS,
)
from components.session_init import init_session_state

init_session_state()
st.header("1. Upload Video")

PRESET_NAMES = list(DENSITY_PRESETS.keys())
SETTING_KEY_MAP = {
    "dialog_material_select": "sidebar_material_select",
    "dialog_density_input": "sidebar_density_input",
    "dialog_cone_height": "sidebar_cone_height",
    "dialog_camera_height": "sidebar_camera_height",
    "dialog_manual_scale_enabled": "sidebar_manual_scale_enabled",
    "dialog_manual_scale_value": "sidebar_manual_scale_value",
    "dialog_frame_interval": "sidebar_frame_interval",
    "dialog_max_frames": "sidebar_max_frames",
    "dialog_colmap_quality": "sidebar_colmap_quality",
    "dialog_above_ground": "sidebar_above_ground",
    "dialog_grid_resolution": "sidebar_grid_resolution",
}


def seed_settings_dialog_from_sidebar(force: bool = False):
    """Copy sidebar values into the review dialog state."""
    for dialog_key, sidebar_key in SETTING_KEY_MAP.items():
        if force or dialog_key not in st.session_state:
            st.session_state[dialog_key] = st.session_state.get(sidebar_key)


def apply_dialog_settings():
    """Apply the confirmed dialog values back into the sidebar state."""
    sidebar_overrides = {
        sidebar_key: st.session_state.get(dialog_key)
        for dialog_key, sidebar_key in SETTING_KEY_MAP.items()
    }
    queue_sidebar_setting_overrides(sidebar_overrides)

    material = sidebar_overrides["sidebar_material_select"]
    if material == "Custom":
        density = float(sidebar_overrides["sidebar_density_input"])
        density_display = f"{density:.0f} kg/m³"
    else:
        density = float(DENSITY_PRESETS[material])
        density_display = f"{density/1000:.2f} MT/m³ (max)"

    st.session_state["manual_scale_override"] = (
        float(sidebar_overrides["sidebar_manual_scale_value"])
        if sidebar_overrides.get("sidebar_manual_scale_enabled")
        else None
    )
    st.session_state["selected_material"] = material
    st.session_state["selected_density"] = density
    st.session_state["selected_density_display"] = density_display
    st.session_state.settings_confirmed = True
    st.session_state.settings_dialog_dismissed = False
    st.session_state.confirmed_settings_signature = tuple(
        (key, sidebar_overrides.get(key))
        for key in SIDEBAR_SETTING_KEYS
    )


def infer_material_from_filename(filename: str) -> str | None:
    """Infer the material preset from the uploaded filename when possible."""
    normalized = re.sub(r"[^a-z0-9]+", " ", filename.lower())

    if "backfill" in normalized and re.search(r"\b0\s*75\s*mm\b", normalized):
        return "Backfill 0–75 mm"
    if "aggregate" in normalized and re.search(r"\b5\s*14\s*mm\b", normalized):
        return "Aggregates 5–14 mm"
    if "aggregate" in normalized and re.search(r"\b10\s*20\s*mm\b", normalized):
        return "Aggregates 10–20 mm"
    return None


def apply_upload_material_hint(filename: str):
    """Apply a filename-based material suggestion into sidebar and dialog state."""
    inferred_material = infer_material_from_filename(filename)
    st.session_state["upload_inferred_material"] = inferred_material
    if inferred_material is None:
        return

    st.session_state["dialog_material_select"] = inferred_material
    st.session_state["dialog_density_input"] = float(DENSITY_PRESETS[inferred_material])


def build_upload_setting_notes(video_info: dict | None, detections: list | None):
    """Generate practical notes from the uploaded video and current dialog values."""
    notes = [
        "We can read the video duration, resolution, and whether cones are visible, "
        "but material, cone size, and camera height still require user confirmation."
    ]
    warnings = []

    interval = float(st.session_state.get("dialog_frame_interval", 0.25))
    max_frames = int(st.session_state.get("dialog_max_frames", 800))
    quality = st.session_state.get("dialog_colmap_quality", "medium")
    manual_scale_enabled = bool(st.session_state.get("dialog_manual_scale_enabled", False))
    inferred_material = st.session_state.get("upload_inferred_material")

    if inferred_material:
        notes.append(
            f"Material was auto-suggested from the filename as **{inferred_material}**. "
            "Please confirm it matches the actual stockpile before continuing."
        )

    if video_info:
        estimated_frames = max(1, int(video_info["duration"] / max(interval, 0.01)))
        used_frames = min(estimated_frames, max_frames)
        notes.append(
            f"At the current {interval:.2f}s frame interval, processing will use about "
            f"{used_frames} frame(s)."
        )
        if estimated_frames > max_frames:
            warnings.append(
                f"This clip would yield about {estimated_frames} frames, so processing "
                f"will cap at {max_frames}. Increase the cap only if you need more detail."
            )
        if video_info["duration"] < 20:
            warnings.append(
                "The clip is fairly short. Make sure the full base and perimeter of the pile are visible."
            )
        if min(video_info["width"], video_info["height"]) < 720:
            warnings.append(
                "The uploaded resolution is relatively low, so reconstruction detail may be limited."
            )
        elif video_info["width"] >= 1920 and video_info["height"] >= 1080 and quality != "high":
            notes.append(
                "This is a high-resolution clip. You can switch COLMAP quality to High for a slower but denser reconstruction."
            )

    if detections is not None:
        if len(detections) == 0:
            warnings.append(
                "No red cones were detected in the first frame. Auto scale may fail unless cones become clearer later in the video."
            )
        else:
            notes.append(
                f"Detected {len(detections)} cone(s) in the first frame, so cone-based auto scale should be available."
            )

    if manual_scale_enabled:
        notes.append("Manual scale override is enabled and will take priority over auto scale.")

    return notes, warnings


@st.dialog("Review Current Settings", width="large")
def settings_review_dialog(video_info: dict | None, detections: list | None):
    """Ask the user to confirm or adjust the current pipeline settings."""
    st.markdown(
        "Please review the current pipeline settings for this upload before continuing."
    )

    material_options = PRESET_NAMES + ["Custom"]
    st.markdown("**Core settings**")

    chosen_material = st.selectbox(
        "Material type",
        options=material_options,
        key="dialog_material_select",
    )

    if chosen_material == "Custom":
        st.number_input(
            "Density (kg/m³)",
            min_value=100.0,
            max_value=5000.0,
            step=50.0,
            key="dialog_density_input",
        )
        st.caption(f"= {st.session_state['dialog_density_input'] / 1000:.3f} MT/m³")
    else:
        lo, hi = DENSITY_RANGES[chosen_material]
        st.session_state["dialog_density_input"] = float(DENSITY_PRESETS[chosen_material])
        col1, col2, col3 = st.columns(3)
        col1.metric("Min density", f"{lo/1000:.2f} MT/m³")
        col2.metric("Max density", f"{hi/1000:.2f} MT/m³")
        col3.metric("Using (max)", f"{DENSITY_PRESETS[chosen_material]/1000:.2f} MT/m³")

    col1, col2 = st.columns(2)
    with col1:
        st.number_input(
            "Cone height (m)",
            min_value=0.1,
            max_value=2.0,
            step=0.05,
            key="dialog_cone_height",
        )
    with col2:
        st.number_input(
            "Camera height above ground (m)",
            min_value=0.5,
            max_value=3.0,
            step=0.1,
            key="dialog_camera_height",
        )

    with st.expander("Advanced processing settings", expanded=False):
        st.checkbox(
            "Override auto-detected scale",
            key="dialog_manual_scale_enabled",
        )
        if st.session_state.get("dialog_manual_scale_enabled"):
            st.number_input(
                "Manual scale factor (m / COLMAP unit)",
                min_value=0.001,
                max_value=200.0,
                step=0.1,
                key="dialog_manual_scale_value",
            )

        st.slider(
            "Frame interval (sec)",
            min_value=0.1,
            max_value=2.0,
            step=0.05,
            key="dialog_frame_interval",
        )
        st.number_input(
            "Max frames",
            min_value=100,
            max_value=2000,
            step=100,
            key="dialog_max_frames",
        )
        st.select_slider(
            "COLMAP quality",
            options=["low", "medium", "high"],
            key="dialog_colmap_quality",
        )
        st.slider(
            "Min pile height above ground (m)",
            min_value=0.01,
            max_value=0.5,
            step=0.01,
            key="dialog_above_ground",
        )
        st.slider(
            "Grid resolution (m)",
            min_value=0.01,
            max_value=0.5,
            step=0.01,
            key="dialog_grid_resolution",
        )

    notes, warnings = build_upload_setting_notes(video_info, detections)
    if notes:
        st.info("\n".join(f"- {note}" for note in notes))
    if warnings:
        st.warning("\n".join(f"- {warning}" for warning in warnings))

    st.divider()
    col_confirm, col_cancel = st.columns([2, 1])
    with col_confirm:
        if st.button(
            "✅ Continue With These Settings",
            type="primary",
            use_container_width=True,
            key="dialog_confirm_settings_btn",
        ):
            apply_dialog_settings()
            st.rerun()
    with col_cancel:
        if st.button(
            "✖ Review Later",
            use_container_width=True,
            key="dialog_cancel_settings_btn",
        ):
            st.session_state.settings_dialog_dismissed = True
            st.rerun()


def render_settings_summary():
    """Render a compact summary of the confirmed settings."""
    config = st.session_state.get("pipeline_config")
    manual_scale = st.session_state.get("manual_scale_override")
    if config is None:
        return

    density_mt = config.material_density / 1000
    summary_lines = [
        f"**Material:** {st.session_state.get('selected_material', config.material_name)}",
        f"**Density:** {density_mt:.2f} MT/m³ ({config.material_density:.0f} kg/m³)",
        f"**Cone height:** {config.scale_calibration.known_cone_height_m:.2f} m",
        f"**Camera height:** {config.scale_calibration.assumed_camera_height_m:.2f} m",
        f"**Frame interval:** {config.frame_extraction.interval_sec:.2f} s",
        f"**COLMAP quality:** {config.colmap.quality.title()}",
    ]
    if manual_scale is not None:
        summary_lines.append(f"**Manual scale override:** {manual_scale:.4f} m/unit")

    st.success("✅ Settings reviewed for this upload.")
    st.markdown("  \n".join(summary_lines))


# Sidebar config — renders sidebar and seeds session state with selected material
config = render_parameter_sidebar()
current_signature = get_pipeline_setting_signature()
if (
    st.session_state.get("settings_confirmed")
    and st.session_state.get("confirmed_settings_signature") not in (None, current_signature)
):
    st.session_state.settings_confirmed = False
    st.session_state.settings_dialog_dismissed = False

st.session_state.pipeline_config = build_pipeline_config_from_state()


# ── Video Upload ───────────────────────────────────────────────────────────────
uploaded = st.file_uploader(
    "Upload a walkaround video of the stockpile",
    type=["mp4", "avi", "mov", "mkv"],
)

if uploaded is not None:
    # Reset confirmation each time a new file is dropped
    is_new_file = st.session_state.get("last_uploaded_name") != uploaded.name
    if is_new_file:
        st.session_state.settings_confirmed = False
        st.session_state.settings_dialog_dismissed = False
        st.session_state.confirmed_settings_signature = None
        st.session_state["last_uploaded_name"] = uploaded.name
        st.session_state["_upload_processed"] = False
        st.session_state["video_path"] = None
        seed_settings_dialog_from_sidebar(force=True)
        apply_upload_material_hint(uploaded.name)

    # ── Write + process only once per uploaded file ────────────────────────
    if not st.session_state.get("_upload_processed"):
        suffix = Path(uploaded.name).suffix
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
        with st.status("Processing uploaded video...", expanded=True) as status:
            st.write("Saving video to disk...")
            tmp.write(uploaded.read())
            tmp.flush()
            st.session_state.video_path = tmp.name

            st.write("Reading video metadata...")
            try:
                info = get_video_info(tmp.name)
                st.session_state["_video_info"] = info
            except Exception as e:
                st.error(f"Could not read video info: {e}")

            st.write("Extracting first frame...")
            frame = None
            try:
                frame = get_first_frame(tmp.name)
                st.session_state["_first_frame"] = frame
            except Exception as e:
                st.error(f"Could not read first frame: {e}")

            st.write("Running cone detection...")
            detections = []
            if frame is not None:
                try:
                    detections = detect_cones(frame, st.session_state.pipeline_config.cone_detection)
                    st.session_state["_cone_detections"] = detections
                except Exception as e:
                    st.error(f"Cone detection failed: {e}")
            else:
                st.session_state["_cone_detections"] = []

            status.update(label="Video ready!", state="complete", expanded=False)
            st.session_state["_upload_processed"] = True

    info = st.session_state.get("_video_info")
    frame = st.session_state.get("_first_frame")
    detections = st.session_state.get("_cone_detections", [])

    # Show the dialog if settings haven't been confirmed or dismissed yet
    if not st.session_state.get("settings_confirmed") and not st.session_state.get("settings_dialog_dismissed"):
        settings_review_dialog(info, detections)

    # Prompt to reopen dialog if dismissed without confirming
    if not st.session_state.get("settings_confirmed") and st.session_state.get("settings_dialog_dismissed"):
        st.warning("⚠️ Settings have not been confirmed for this upload yet.")
        if st.button("⚙️ Review Current Settings", type="primary", key="reopen_settings_review_btn"):
            seed_settings_dialog_from_sidebar(force=True)
            st.session_state.settings_dialog_dismissed = False
            st.rerun()

    if st.session_state.get("settings_confirmed"):
        col_banner, col_change = st.columns([4, 1])
        with col_banner:
            render_settings_summary()
        with col_change:
            if st.button("✏️ Change", use_container_width=True, key="change_settings_review_btn"):
                seed_settings_dialog_from_sidebar(force=True)
                st.session_state.settings_confirmed = False
                st.session_state.settings_dialog_dismissed = False
                st.rerun()

    # ── Video Info ─────────────────────────────────────────────────────────
    if info:
        col1, col2, col3, col4 = st.columns(4)
        col1.metric("Duration", f"{info['duration']:.1f}s")
        col2.metric("FPS", f"{info['fps']:.1f}")
        col3.metric("Resolution", f"{info['width']}x{info['height']}")
        estimated_frames = int(info["duration"] / st.session_state.pipeline_config.frame_extraction.interval_sec)
        col4.metric(
            "Est. Frames",
            str(min(estimated_frames, st.session_state.pipeline_config.frame_extraction.max_frames)),
        )

    # ── First Frame Preview + Cone Detection ───────────────────────────────
    if frame is not None:
        st.subheader("First Frame Preview")
        col1, col2 = st.columns(2)
        with col1:
            st.image(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB), caption="Original Frame")
        with col2:
            if detections:
                overlay = draw_cone_overlays(frame, detections)
                st.image(
                    cv2.cvtColor(overlay, cv2.COLOR_BGR2RGB),
                    caption=f"Cone Detection ({len(detections)} cones found)",
                )
            else:
                st.image(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB), caption="No cones detected")
                st.warning(
                    "⚠️ No cones detected in the first frame. "
                    "Scale calibration may still work if cones appear clearly later, "
                    "but manual scale override is the safer fallback."
                )

        if detections:
            st.success(
                f"✅ Detected **{len(detections)} cone(s)** in the first frame. "
                "Cone-based scaling should be available."
            )

elif st.session_state.get("video_path"):
    if st.session_state.get("settings_confirmed"):
        render_settings_summary()
    else:
        st.warning("A video is already loaded, but its settings still need confirmation.")
        if st.button("⚙️ Review Current Settings", type="primary", key="reopen_loaded_video_settings_btn"):
            seed_settings_dialog_from_sidebar(force=True)
            st.session_state.settings_dialog_dismissed = False
            st.rerun()
else:
    st.session_state.settings_confirmed = False
    st.info("Please upload a video to get started.")
