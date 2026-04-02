"""Page 2: Pipeline execution with progress tracking."""

import threading
import time
from pathlib import Path
from queue import Queue

import streamlit as st

LOG_FILE = "/tmp/stockpile_app.log"


def _read_log_tail(lines: int = 60) -> str:
    try:
        with open(LOG_FILE) as f:
            all_lines = f.readlines()
        tail = all_lines[-lines:] if len(all_lines) > lines else all_lines
        return "".join(tail) if tail else "(no log entries yet)"
    except FileNotFoundError:
        return "(log file not found)"
    except Exception as e:
        return f"(error: {e})"

from stockpile.config import PipelineConfig
from stockpile.pipeline import Pipeline, PipelineResult

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))
from components.session_init import init_session_state

init_session_state()
st.header("2. Processing")

STAGE_LABELS = {
    "frame_extraction": "Extracting frames from video",
    "cone_detection": "Detecting red cones in frames",
    "colmap_reconstruction": "Running COLMAP 3D reconstruction",
    "scale_calibration": "Calibrating scale from cones",
    "ground_plane": "Fitting ground plane & segmenting pile",
    "volume_computation": "Computing volume",
    "complete": "Done!",
}


def run_pipeline_thread(video_path: str, config: PipelineConfig, queue: Queue):
    """Run the pipeline in a background thread, posting progress to queue."""
    def progress_callback(stage, progress, message=""):
        queue.put(("progress", stage, progress, message))

    config.progress_callback = progress_callback
    pipeline = Pipeline(config)
    result = pipeline.run(video_path)
    queue.put(("done", result))


if st.session_state.get("video_path") is None:
    st.warning("No video uploaded. Go to the Upload page first.")
    st.stop()

config = st.session_state.get("pipeline_config") or PipelineConfig()

# Apply manual scale override from sidebar
manual_scale = st.session_state.get("manual_scale_override")
config.manual_scale_override = manual_scale

# Show current settings
with st.expander("Current Settings"):
    st.write(f"- **Material**: {config.material_name} ({config.material_density:.0f} kg/m³)")
    st.write(f"- **Cone height**: {config.scale_calibration.known_cone_height_m:.2f} m")
    st.write(f"- **Frame interval**: {config.frame_extraction.interval_sec:.1f}s")
    st.write(f"- **COLMAP quality**: {config.colmap.quality}")
    st.write(f"- **Grid resolution**: {config.volume.grid_resolution:.2f} m")

# Run button
if not st.session_state.get("pipeline_running", False):
    if st.button("Start Processing", type="primary", width="stretch"):
        st.session_state.pipeline_running = True
        st.session_state.pipeline_result = None

        queue = Queue()
        st.session_state.progress_queue = queue

        thread = threading.Thread(
            target=run_pipeline_thread,
            args=(st.session_state.video_path, config, queue),
            daemon=True,
        )
        thread.start()
        st.session_state.pipeline_thread = thread
        st.rerun()

# Progress display
if st.session_state.get("pipeline_running", False):
    queue = st.session_state.get("progress_queue")
    if queue is None:
        st.session_state.pipeline_running = False
        st.rerun()

    progress_bar = st.progress(0)
    status_text = st.empty()
    stage_text = st.empty()

    # Overall stage tracking
    stages = list(STAGE_LABELS.keys())
    current_stage_idx = 0

    log_box = st.expander("Live logs", expanded=False)
    log_placeholder = log_box.empty()

    while True:
        # Check for messages
        try:
            while not queue.empty():
                msg = queue.get_nowait()
                if msg[0] == "progress":
                    _, stage, progress, message = msg
                    if stage in stages:
                        current_stage_idx = stages.index(stage)
                    overall = (current_stage_idx + progress) / len(stages)
                    progress_bar.progress(min(overall, 1.0))
                    stage_label = STAGE_LABELS.get(stage, stage)
                    status_text.markdown(f"**{stage_label}**")
                    if message:
                        stage_text.text(message)

                elif msg[0] == "done":
                    result = msg[1]
                    st.session_state.pipeline_result = result
                    st.session_state.pipeline_running = False
                    progress_bar.progress(1.0)

                    if result.error:
                        st.error(f"Pipeline failed: {result.error}")
                    else:
                        st.success("Processing complete! Go to the Results page.")
                    st.rerun()

        except Exception:
            pass

        # Update log tail every cycle
        log_placeholder.code(_read_log_tail(60), language=None)

        # Check if thread is still alive
        thread = st.session_state.get("pipeline_thread")
        if thread and not thread.is_alive():
            if st.session_state.get("pipeline_running"):
                st.session_state.pipeline_running = False
                if st.session_state.pipeline_result is None:
                    st.error("Pipeline thread ended unexpectedly")
                st.rerun()
            break

        time.sleep(0.5)

# Show previous result if available
result = st.session_state.get("pipeline_result")
if result and not st.session_state.get("pipeline_running"):
    if result.error:
        st.error(f"Last run failed at stage '{result.stage}': {result.error}")
    else:
        st.success("✅ Processing complete! Navigate to the **Results** page to review the output.")
        st.divider()

        # Row 1: reconstruction stats
        col1, col2, col3, col4 = st.columns(4)
        col1.metric("Frames Extracted", f"{result.num_frames:,}")
        col2.metric("Frames w/ Cones", f"{result.num_frames_with_cones:,}")
        col3.metric("COLMAP 3D Points", f"{result.num_colmap_points:,}")
        col4.metric("Pile Points", f"{len(result.pile_cloud.points):,}" if result.pile_cloud else "0")

        # Row 2: calibration summary
        if result.calibration:
            cal = result.calibration
            conf_pct = cal.confidence * 100
            conf_icon = "🟢" if conf_pct >= 70 else ("🟡" if conf_pct >= 40 else "🔴")
            col1, col2, col3, col4 = st.columns(4)
            col1.metric("Scale Factor", f"{cal.scale_factor:.4f} m/unit")
            col2.metric("Cal. Confidence", f"{conf_pct:.0f}%")
            col3.metric("Cones Used", str(cal.num_cones_used))
            if result.volume:
                col4.metric("Volume (Grid)", f"{result.volume.recommended_m3:.1f} m³")

            if conf_pct < 40:
                st.error(
                    f"{conf_icon} **Low calibration confidence ({conf_pct:.0f}%).** "
                    "Volume results may be inaccurate. Consider enabling the manual scale override "
                    "in the sidebar before re-running."
                )
            elif conf_pct < 70:
                st.warning(
                    f"{conf_icon} **Medium calibration confidence ({conf_pct:.0f}%).** "
                    "Results are indicative — verify against a reference measurement."
                )
        else:
            st.error(
                "🔴 **No scale calibration** — cones were not detected in any frame. "
                "Volume is in arbitrary COLMAP units and is not usable. "
                "Check that red traffic cones are clearly visible in the video, or use manual scale override."
            )
