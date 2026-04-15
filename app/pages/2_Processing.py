"""Page 2: Pipeline execution with progress tracking."""

import copy
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
sys.path.insert(0, str(Path(__file__).parent.parent))
from components.client_test_log import (
    CLIENT_RUN_ATTEMPT_KEY,
    CLIENT_RUN_ID_KEY,
    CLIENT_SESSION_ID_KEY,
    CLIENT_UPLOAD_ID_KEY,
    append_client_test_event,
    start_new_run_tracking,
)
from components.parameter_sidebar import SIDEBAR_SETTING_KEYS
from components.persisted_session import clear_session_snapshot, persist_session_snapshot
from components.reliability_status import (
    classify_preflight_status,
    classify_result_status,
    render_status_callout,
)
from components.run_guard import (
    describe_active_run,
    heartbeat_run_lock,
    read_active_run_lock,
    release_run_lock,
    try_acquire_run_lock,
)
from components.session_init import init_session_state
from components.sidebar_nav import render_sidebar_nav

init_session_state()
render_sidebar_nav("Processing")
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


def run_pipeline_thread(video_path: str, config: PipelineConfig, queue: Queue, lock_token: str | None):
    """Run the pipeline in a background thread, posting progress to queue."""
    heartbeat_stop = threading.Event()
    heartbeat_state = {
        "stage": "starting",
        "progress": 0.0,
        "message": "Preparing processing workspace...",
    }

    def heartbeat_loop():
        while not heartbeat_stop.wait(10.0):
            heartbeat_run_lock(
                lock_token,
                stage=heartbeat_state["stage"],
                progress=heartbeat_state["progress"],
                message=heartbeat_state["message"],
            )

    def progress_callback(stage, progress, message=""):
        heartbeat_state["stage"] = stage
        heartbeat_state["progress"] = progress
        heartbeat_state["message"] = message
        heartbeat_run_lock(lock_token, stage=stage, progress=progress, message=message)
        queue.put(("progress", stage, progress, message))

    config.progress_callback = progress_callback
    heartbeat_thread = threading.Thread(target=heartbeat_loop, daemon=True)
    heartbeat_thread.start()
    heartbeat_run_lock(lock_token, stage="starting", progress=0.0, message="Starting reconstruction...")
    try:
        pipeline = Pipeline(config)
        result = pipeline.run(video_path)
        queue.put(("done", result))
    except Exception as exc:
        queue.put(("error", str(exc)))
    finally:
        heartbeat_stop.set()
        heartbeat_thread.join(timeout=1.0)
        release_run_lock(lock_token)


if st.session_state.get("video_path") is None:
    st.warning("No video uploaded. Go to the Upload page first.")
    st.stop()

if not st.session_state.get("settings_confirmed"):
    st.warning(
        "Settings for this upload have not been confirmed yet. "
        "Go back to the Upload page, review the suggested settings, and continue from there."
    )
    st.stop()

confirmed_config = st.session_state.get("confirmed_pipeline_config")
if confirmed_config is None:
    current_signature = tuple(
        (key, st.session_state.get(key))
        for key in SIDEBAR_SETTING_KEYS
        if key != "sidebar_admin_mode"
    )
    confirmed_signature = st.session_state.get("confirmed_settings_signature")
    if confirmed_signature not in (None, current_signature):
        st.session_state.settings_confirmed = False
        st.session_state["confirmed_pipeline_config"] = None
        st.error(
            "Settings changed after the last confirmation. "
            "Please return to Upload, review the current settings, and confirm again."
        )
        st.stop()

if confirmed_config is not None:
    config = copy.deepcopy(confirmed_config)
    config_source = "confirmed_pipeline_config"
else:
    config = copy.deepcopy(st.session_state.get("pipeline_config") or PipelineConfig())
    config_source = "pipeline_config_fallback"
    manual_scale = st.session_state.get("manual_scale_override")
    config.manual_scale_override = manual_scale

if not st.session_state.get("pipeline_running") and st.session_state.get("processing_lock_token"):
    release_run_lock(st.session_state.get("processing_lock_token"))
    st.session_state["processing_lock_token"] = None

preflight_status = classify_preflight_status(
    st.session_state.get("ai_preflight_result"),
    st.session_state.get("_cone_detections"),
    st.session_state.get("recommended_processing_profile"),
)
active_run = read_active_run_lock()
own_lock_token = st.session_state.get("processing_lock_token")
other_active_run = active_run is not None and active_run.token != own_lock_token

# Show current settings
with st.expander("Current Settings"):
    st.write(f"- **Material**: {config.material_name} ({config.material_density:.0f} kg/m³)")
    if st.session_state.get("recommended_processing_profile"):
        st.write(f"- **Processing profile**: {st.session_state['recommended_processing_profile']}")
    st.write(f"- **Cone height**: {config.scale_calibration.known_cone_height_m:.2f} m")
    st.write(f"- **Camera height**: {config.scale_calibration.assumed_camera_height_m:.2f} m")
    st.write(f"- **Frame interval**: {config.frame_extraction.interval_sec:.1f}s")
    st.write(f"- **Max frames**: {config.frame_extraction.max_frames}")
    st.write(f"- **COLMAP quality**: {config.colmap.quality}")
    st.write(f"- **Grid resolution**: {config.volume.grid_resolution:.2f} m")
    if config.manual_scale_override is not None:
        st.write(f"- **Manual scale override**: {config.manual_scale_override:.4f} m/unit")

render_status_callout(
    preflight_status,
    prefix="**Capture preflight.** This is the trust level before the full reconstruction starts.",
)
if preflight_status.key == "retake_needed":
    st.error(
        "Client-facing safe mode is blocking this run before reconstruction. "
        "Please upload a stronger clip or re-capture with clearer references and perimeter coverage."
    )
elif other_active_run:
    st.info(
        "Processing is temporarily busy. "
        + describe_active_run(active_run)
        + " We only allow one heavy reconstruction at a time so client sessions do not interfere with each other."
    )

# Run button
result = st.session_state.get("pipeline_result")
run_button_label = "Start Processing" if result is None else "Run Again"
if not st.session_state.get("pipeline_running", False):
    if st.button(run_button_label, type="primary", use_container_width=True):
        start_new_run_tracking(st.session_state)
        if preflight_status.key == "retake_needed":
            append_client_test_event(
                st.session_state,
                "processing_blocked_preflight",
                config=config,
                video_info=st.session_state.get("_video_info"),
                detections=st.session_state.get("_cone_detections"),
                extra={"config_source": config_source, "preflight_status": preflight_status.key},
            )
            st.error(
                "This upload is blocked in client-facing safe mode. Please fix the capture quality before processing."
            )
        else:
            acquisition = try_acquire_run_lock(
                session_id=st.session_state.get(CLIENT_SESSION_ID_KEY),
                upload_id=st.session_state.get(CLIENT_UPLOAD_ID_KEY),
                run_id=st.session_state.get(CLIENT_RUN_ID_KEY),
                run_attempt=st.session_state.get(CLIENT_RUN_ATTEMPT_KEY, 0),
                file_name=st.session_state.get("last_uploaded_name"),
                stage="queued",
                message="Waiting to start reconstruction...",
            )
            if not acquisition.acquired:
                append_client_test_event(
                    st.session_state,
                    "processing_blocked_busy",
                    config=config,
                    video_info=st.session_state.get("_video_info"),
                    detections=st.session_state.get("_cone_detections"),
                    extra={
                        "config_source": config_source,
                        "active_run": acquisition.active_run.to_payload() if acquisition.active_run else None,
                        "stale_lock_cleared": acquisition.stale_cleared,
                    },
                )
                st.warning(
                    "Another client run is already in progress. "
                    + describe_active_run(acquisition.active_run)
                )
            else:
                st.session_state.pipeline_running = True
                st.session_state.pipeline_result = None
                st.session_state.progress_queue = None
                st.session_state.pipeline_thread = None
                st.session_state["processing_lock_token"] = acquisition.token
                append_client_test_event(
                    st.session_state,
                    "processing_started",
                    config=config,
                    video_info=st.session_state.get("_video_info"),
                    detections=st.session_state.get("_cone_detections"),
                    extra={
                        "config_source": config_source,
                        "lock_token": acquisition.token,
                        "stale_lock_cleared": acquisition.stale_cleared,
                    },
                )
                clear_session_snapshot(config.workspace)

                queue = Queue()
                st.session_state.progress_queue = queue

                thread = threading.Thread(
                    target=run_pipeline_thread,
                    args=(st.session_state.video_path, config, queue, acquisition.token),
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
                    st.session_state.progress_queue = None
                    st.session_state.pipeline_thread = None
                    release_run_lock(st.session_state.get("processing_lock_token"))
                    st.session_state["processing_lock_token"] = None
                    persist_session_snapshot(st.session_state, result=result, config=config)
                    append_client_test_event(
                        st.session_state,
                        "processing_failed" if result.error else "processing_completed",
                        config=config,
                        video_info=st.session_state.get("_video_info"),
                        detections=st.session_state.get("_cone_detections"),
                        result=result,
                        extra={"config_source": config_source},
                    )
                    progress_bar.progress(1.0)

                    if result.error:
                        st.error(f"Pipeline failed: {result.error}")
                    else:
                        st.success("Processing complete! Go to the Results page.")
                    st.rerun()

                elif msg[0] == "error":
                    error_msg = msg[1]
                    st.session_state.pipeline_running = False
                    st.session_state.progress_queue = None
                    st.session_state.pipeline_thread = None
                    release_run_lock(st.session_state.get("processing_lock_token"))
                    st.session_state["processing_lock_token"] = None
                    append_client_test_event(
                        st.session_state,
                        "processing_crashed",
                        config=config,
                        video_info=st.session_state.get("_video_info"),
                        detections=st.session_state.get("_cone_detections"),
                        extra={"config_source": config_source, "error": error_msg},
                    )
                    st.error(f"Pipeline crashed: {error_msg}")
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
                st.session_state.progress_queue = None
                st.session_state.pipeline_thread = None
                release_run_lock(st.session_state.get("processing_lock_token"))
                st.session_state["processing_lock_token"] = None
                if st.session_state.pipeline_result is None:
                    append_client_test_event(
                        st.session_state,
                        "processing_crashed",
                        config=config,
                        video_info=st.session_state.get("_video_info"),
                        detections=st.session_state.get("_cone_detections"),
                        extra={"config_source": config_source, "error": "Pipeline thread ended unexpectedly"},
                    )
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
        render_status_callout(classify_result_status(result))
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
            col1.metric("Scale Factor", f"{(result.scale_factor_m_per_unit or cal.scale_factor):.4f} m/unit")
            col2.metric("Cal. Confidence", f"{conf_pct:.0f}%")
            col3.metric("Unique Cones Used", str(cal.num_cones_used))
            if result.volume:
                col4.metric("Volume (Grid)", f"{result.volume.recommended_m3:.1f} m³")

            if cal.detected_cone_frames:
                st.caption(
                    f"Cone-bearing frames: {cal.detected_cone_frames} detected, "
                    f"{cal.registered_cone_frames} registered into COLMAP, "
                    f"max {cal.max_detections_in_frame} cone(s) in one frame."
                )

            if cal.num_cones_used == 1:
                clip_guidance = ""
                if cal.max_detections_in_frame <= 1:
                    clip_guidance = (
                        " This clip never showed more than one cone at a time, so verified scale was not possible."
                    )
                if getattr(result, "review_grade", False):
                    st.warning(
                        f"{conf_icon} **Projection consistency is {conf_pct:.0f}%,** but only one unique cone was recovered. "
                        f"Treat this as a review-grade scale and cross-check it before client reporting.{clip_guidance}"
                    )
                else:
                    st.warning(
                        f"{conf_icon} **Projection consistency is {conf_pct:.0f}%,** but only one unique cone was recovered. "
                        f"The run remains blocked until more physical references are visible.{clip_guidance}"
                    )
            elif conf_pct < 40:
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
            if result.scale_source == "manual_override" and result.scale_factor_m_per_unit is not None:
                st.info(
                    f"ℹ️ Manual scale override was used at {result.scale_factor_m_per_unit:.4f} m/unit. "
                    "Auto-calibration diagnostics are not available for this run."
                )
            else:
                st.error(
                    "🔴 **No scale calibration** — cones were not detected in any frame. "
                    "Volume is in arbitrary COLMAP units and is not usable. "
                    "Check that red traffic cones are clearly visible in the video, or use manual scale override."
                )

        if result.quality_blockers:
            st.markdown("**Reliability blockers**")
            for blocker in result.quality_blockers:
                st.write(f"- {blocker}")

        if result.quality_warnings:
            st.markdown("**Reliability warnings**")
            for warning in result.quality_warnings:
                st.write(f"- {warning}")
