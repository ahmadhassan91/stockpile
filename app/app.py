"""Streamlit entry point for the Stockpile Weight Estimation app."""

import logging
import os
from logging.handlers import RotatingFileHandler

import streamlit as st

# ── Logging setup ──────────────────────────────────────────────────────────────
LOG_FILE = "/tmp/stockpile_app.log"
LOG_LEVEL = os.getenv("STOCKPILE_LOG_LEVEL", "INFO").upper()

def _setup_logging():
    root = logging.getLogger()
    if any(isinstance(h, logging.FileHandler) and getattr(h, 'baseFilename', '') == LOG_FILE
           for h in root.handlers):
        return  # already set up
    level = getattr(logging, LOG_LEVEL, logging.INFO)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s",
                            datefmt="%H:%M:%S")
    fh = RotatingFileHandler(LOG_FILE, maxBytes=1_000_000, backupCount=3)
    fh.setFormatter(fmt)
    fh.setLevel(level)
    root.setLevel(level)
    root.addHandler(fh)
    logging.getLogger("watchdog").setLevel(logging.WARNING)
    logging.getLogger("watchdog.observers.inotify_buffer").setLevel(logging.WARNING)

_setup_logging()

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
