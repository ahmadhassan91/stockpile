"""Page 1: Video upload and configuration."""

import tempfile
from pathlib import Path

import cv2
import numpy as np
import streamlit as st

from stockpile.cone_detection import detect_cones, draw_cone_overlays
from stockpile.frame_extraction import get_first_frame, get_video_info

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from components.parameter_sidebar import render_parameter_sidebar
from components.session_init import init_session_state

init_session_state()
st.header("1. Upload Video")

# Sidebar config
config = render_parameter_sidebar()
st.session_state.pipeline_config = config

# Video upload
uploaded = st.file_uploader(
    "Upload a walkaround video of the stockpile",
    type=["mp4", "avi", "mov", "mkv"],
)

if uploaded is not None:
    # Save to temp file
    suffix = Path(uploaded.name).suffix
    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
    tmp.write(uploaded.read())
    tmp.flush()
    st.session_state.video_path = tmp.name

    # Show video info
    try:
        info = get_video_info(tmp.name)
        col1, col2, col3, col4 = st.columns(4)
        col1.metric("Duration", f"{info['duration']:.1f}s")
        col2.metric("FPS", f"{info['fps']:.1f}")
        col3.metric("Resolution", f"{info['width']}x{info['height']}")
        estimated_frames = int(info["duration"] / config.frame_extraction.interval_sec)
        col4.metric("Est. Frames", str(min(estimated_frames, config.frame_extraction.max_frames)))
    except Exception as e:
        st.error(f"Could not read video info: {e}")

    # Preview first frame with cone detection
    st.subheader("First Frame Preview")
    try:
        frame = get_first_frame(tmp.name)
        detections = detect_cones(frame, config.cone_detection)

        col1, col2 = st.columns(2)
        with col1:
            st.image(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB), caption="Original Frame")
        with col2:
            if detections:
                overlay = draw_cone_overlays(frame, detections)
                st.image(cv2.cvtColor(overlay, cv2.COLOR_BGR2RGB),
                         caption=f"Cone Detection ({len(detections)} cones)")
            else:
                st.image(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB),
                         caption="No cones detected")
                st.warning("No red cones detected in the first frame. "
                           "Adjust HSV parameters in the sidebar or check your video.")

        if detections:
            st.success(f"Detected {len(detections)} cone(s) in the first frame. "
                       "Proceed to the Processing page.")
    except Exception as e:
        st.error(f"Could not read first frame: {e}")

elif st.session_state.get("video_path"):
    st.info(f"Video already loaded: {st.session_state.video_path}")
else:
    st.info("Please upload a video to get started.")
