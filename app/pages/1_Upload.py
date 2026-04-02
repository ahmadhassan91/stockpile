"""Page 1: Video upload and configuration."""

import shutil
import tempfile
from pathlib import Path

import cv2
import streamlit as st

from stockpile.cone_detection import detect_cones, draw_cone_overlays
from stockpile.config import DENSITY_RANGES, DENSITY_PRESETS
from stockpile.frame_extraction import get_first_frame, get_video_info

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from components.parameter_sidebar import render_parameter_sidebar
from components.session_init import init_session_state

init_session_state()
st.header("1. Upload Video")

# Sidebar config — renders sidebar and seeds session state with selected material
config = render_parameter_sidebar()
st.session_state.pipeline_config = config

PRESET_NAMES = list(DENSITY_PRESETS.keys())


def _managed_upload_path(workspace: Path, filename: str) -> Path:
    """Store uploaded videos inside the app workspace instead of /tmp."""
    input_dir = workspace / "input"
    input_dir.mkdir(parents=True, exist_ok=True)
    return input_dir / f"uploaded{Path(filename).suffix.lower()}"


def _remove_managed_upload(path_str: str | None, workspace: Path) -> None:
    """Delete uploads created in the workspace or temp dir."""
    if not path_str:
        return

    path = Path(path_str)
    try:
        resolved = path.resolve()
    except OSError:
        return

    workspace_root = workspace.resolve()
    temp_root = Path(tempfile.gettempdir()).resolve()
    if not path.is_file():
        return
    if resolved.is_relative_to(workspace_root) or resolved.is_relative_to(temp_root):
        try:
            path.unlink()
        except OSError:
            pass


# ── Material Confirmation Dialog ───────────────────────────────────────────────
@st.dialog("🪨 Confirm Material & Density", width="large")
def material_confirmation_dialog(current_material: str):
    """Dialog shown after upload. User can pick material here and confirm."""

    st.markdown(
        "Please confirm the **material type** for this stockpile. "
        "The bulk density is used to convert volume → weight."
    )
    st.divider()

    # Material selector inside the dialog
    preset_options = PRESET_NAMES + ["Custom"]
    default_idx = preset_options.index(current_material) if current_material in preset_options else 0

    chosen_material = st.selectbox(
        "Material type",
        options=preset_options,
        index=default_idx,
        key="dialog_material_select",
    )

    # Density display / input
    if chosen_material == "Custom":
        chosen_density = st.number_input(
            "Custom density (kg/m³)",
            value=float(st.session_state.get("selected_density", 1600)),
            min_value=100.0,
            max_value=5000.0,
            step=50.0,
            key="dialog_custom_density",
        )
        st.caption(f"= {chosen_density / 1000:.3f} MT/m³")
    else:
        lo, hi = DENSITY_RANGES[chosen_material]
        chosen_density = float(DENSITY_PRESETS[chosen_material])

        col1, col2, col3 = st.columns(3)
        col1.metric("Min density", f"{lo/1000:.2f} MT/m³")
        col2.metric("Max density", f"{hi/1000:.2f} MT/m³")
        col3.metric("Using (max)", f"{chosen_density/1000:.2f} MT/m³")

        st.info(
            f"ℹ️ We always use the **maximum bulk density** for the weight calculation. "
            f"If your material is at the lower end of the range, the actual weight could be "
            f"~{((hi - lo) / hi * 100):.0f}% lower."
        )

    st.divider()

    col_confirm, col_cancel = st.columns([2, 1])
    with col_confirm:
        if st.button(
            f"✅ Confirm — {chosen_material}",
            type="primary",
            width="stretch",
            key="dialog_confirm_btn",
        ):
            # Save the dialog selection back to session state
            st.session_state["selected_material"] = chosen_material
            st.session_state["selected_density"] = chosen_density
            st.session_state["sidebar_material_select"] = chosen_material
            if chosen_material == "Custom":
                st.session_state["sidebar_density_input"] = float(chosen_density)
            st.session_state["material_confirmed"] = True

            # Patch the pipeline config density with the dialog's choice
            if st.session_state.get("pipeline_config"):
                st.session_state.pipeline_config.material_density = chosen_density
                st.session_state.pipeline_config.material_name = (
                    chosen_material if chosen_material != "Custom" else "custom"
                )
            st.rerun()

    with col_cancel:
        if st.button("✖ Cancel", width="stretch", key="dialog_cancel_btn"):
            st.session_state["dialog_dismissed"] = True
            st.rerun()


# ── Video Upload ───────────────────────────────────────────────────────────────
uploaded = st.file_uploader(
    "Upload a walkaround video of the stockpile",
    type=["mp4", "avi", "mov", "mkv"],
)

if uploaded is not None:
    # Reset confirmation each time a new file is dropped
    upload_signature = (uploaded.name, uploaded.size)
    is_new_file = st.session_state.get("last_uploaded_signature") != upload_signature
    if is_new_file:
        _remove_managed_upload(st.session_state.get("video_path"), config.workspace)
        shutil.rmtree(config.workspace / "input", ignore_errors=True)
        st.session_state["material_confirmed"] = False
        st.session_state["dialog_dismissed"] = False
        st.session_state["last_uploaded_signature"] = upload_signature
        st.session_state["_upload_processed"] = False
        st.session_state["video_path"] = None
        st.session_state["_video_info"] = None
        st.session_state["_first_frame"] = None
        st.session_state["_cone_detections"] = []

    # ── Write + process only once per uploaded file ────────────────────────
    if not st.session_state.get("_upload_processed"):
        video_path = _managed_upload_path(config.workspace, uploaded.name)
        with st.status("Processing uploaded video...", expanded=True) as status:
            st.write("Saving video to disk...")
            with video_path.open("wb") as destination:
                destination.write(uploaded.getbuffer())
            st.session_state.video_path = str(video_path)

            st.write("Reading video metadata...")
            try:
                info = get_video_info(video_path)
                st.session_state["_video_info"] = info
            except Exception as e:
                st.error(f"Could not read video info: {e}")

            st.write("Extracting first frame...")
            frame = None
            try:
                frame = get_first_frame(video_path)
                st.session_state["_first_frame"] = frame
            except Exception as e:
                st.error(f"Could not read first frame: {e}")

            st.write("Running cone detection...")
            if frame is not None:
                try:
                    detections = detect_cones(frame, config.cone_detection)
                    st.session_state["_cone_detections"] = detections
                except Exception as e:
                    st.error(f"Cone detection failed: {e}")

            status.update(label="Video ready!", state="complete", expanded=False)
            st.session_state["_upload_processed"] = True
        info = st.session_state.get("_video_info")
        frame = st.session_state.get("_first_frame")
        detections = st.session_state.get("_cone_detections", [])

    # Show the dialog if material hasn't been confirmed or dismissed yet
    if not st.session_state.get("material_confirmed") and not st.session_state.get("dialog_dismissed"):
        active_material = st.session_state.get("selected_material", PRESET_NAMES[0])
        material_confirmation_dialog(active_material)

    # Prompt to open dialog if dismissed without confirming
    if not st.session_state.get("material_confirmed") and st.session_state.get("dialog_dismissed"):
        st.warning(
            "⚠️ Material not confirmed. Please select your material type before processing."
        )
        if st.button("🪨 Select Material", type="primary", key="reopen_after_dismiss_btn"):
            st.session_state["dialog_dismissed"] = False
            st.rerun()

    # ── Confirmed banner ───────────────────────────────────────────────────
    confirmed_material = st.session_state.get("selected_material", PRESET_NAMES[0])
    confirmed_density = st.session_state.get("selected_density", DENSITY_PRESETS[PRESET_NAMES[0]])

    if st.session_state.get("material_confirmed"):
        col_banner, col_change = st.columns([4, 1])
        with col_banner:
            st.success(
                f"✅ **{confirmed_material}** — "
                f"density: **{confirmed_density/1000:.2f} MT/m³** ({confirmed_density:.0f} kg/m³)"
            )
        with col_change:
            if st.button("✏️ Change", width="stretch", key="reopen_dialog_btn"):
                st.session_state["material_confirmed"] = False
                st.rerun()

    # ── Video Info ─────────────────────────────────────────────────────────
    info = st.session_state.get("_video_info")
    if info:
        col1, col2, col3, col4 = st.columns(4)
        col1.metric("Duration", f"{info['duration']:.1f}s")
        col2.metric("FPS", f"{info['fps']:.1f}")
        col3.metric("Resolution", f"{info['width']}x{info['height']}")
        estimated_frames = int(info["duration"] / config.frame_extraction.interval_sec)
        col4.metric("Est. Frames", str(min(estimated_frames, config.frame_extraction.max_frames)))

    # ── First Frame Preview + Cone Detection ───────────────────────────────
    frame = st.session_state.get("_first_frame")
    detections = st.session_state.get("_cone_detections", [])

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
                    "⚠️ No red cones detected in the first frame. "
                    "Make sure red traffic cones are clearly visible in the video. "
                    "You can adjust HSV detection parameters in the sidebar, "
                    "or use the manual scale override."
                )

        if detections:
            st.success(
                f"✅ Detected **{len(detections)} cone(s)** in the first frame. "
                "Scale calibration should work correctly. Proceed to the **Processing** page."
            )

elif st.session_state.get("video_path"):
    confirmed_material = st.session_state.get("selected_material", PRESET_NAMES[0])
    confirmed_density = st.session_state.get("selected_density", DENSITY_PRESETS[PRESET_NAMES[0]])
    st.info(
        f"Video already loaded.  \n"
        f"Current material: **{confirmed_material}** at **{confirmed_density/1000:.2f} MT/m³**"
    )
else:
    st.session_state["material_confirmed"] = False
    st.info("Please upload a video to get started.")
