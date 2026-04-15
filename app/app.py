"""Streamlit entry point for the Stockpile Weight Estimation app."""

import logging
import os

import streamlit as st
from components.sidebar_nav import render_sidebar_nav

# ── Logging setup ──────────────────────────────────────────────────────────────
LOG_FILE = "/tmp/stockpile_app.log"
DEFAULT_LOG_LEVEL = os.environ.get("STOCKPILE_LOG_LEVEL", "INFO").strip().upper() or "INFO"


def _resolve_log_level() -> int:
    return getattr(logging, DEFAULT_LOG_LEVEL, logging.INFO)

def _setup_logging():
    root = logging.getLogger()
    if any(isinstance(h, logging.FileHandler) and getattr(h, 'baseFilename', '') == LOG_FILE
           for h in root.handlers):
        return  # already set up
    level = _resolve_log_level()
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s",
                            datefmt="%H:%M:%S")
    fh = logging.FileHandler(LOG_FILE)
    fh.setFormatter(fmt)
    fh.setLevel(level)
    root.setLevel(level)
    root.addHandler(fh)
    logging.getLogger("watchdog").setLevel(logging.WARNING)

_setup_logging()

st.set_page_config(
    page_title="Stockpile Weight Estimator",
    page_icon="⛰️",
    layout="wide",
    initial_sidebar_state="expanded",
)

render_sidebar_nav("app")

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
