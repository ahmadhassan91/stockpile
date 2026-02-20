"""Streamlit entry point for the Stockpile Weight Estimation app."""

import streamlit as st

st.set_page_config(
    page_title="Stockpile Weight Estimator",
    page_icon="⛰️",
    layout="wide",
    initial_sidebar_state="expanded",
)

st.title("Stockpile Weight Estimator")
st.markdown("""
Estimate stockpile volume and weight from a ground-level walkaround video.

**How it works:**
1. **Upload** a video of the stockpile with red traffic cones placed around it for scale
2. **Processing** extracts frames, detects cones, runs 3D reconstruction (COLMAP), and computes volume
3. **Results** shows the 3D point cloud, volume, and estimated weight

Use the sidebar on each page to adjust pipeline parameters.

---

Navigate using the pages in the sidebar to get started.
""")

# Initialize session state
if "pipeline_result" not in st.session_state:
    st.session_state.pipeline_result = None
if "video_path" not in st.session_state:
    st.session_state.video_path = None
if "pipeline_running" not in st.session_state:
    st.session_state.pipeline_running = False
if "pipeline_config" not in st.session_state:
    st.session_state.pipeline_config = None
