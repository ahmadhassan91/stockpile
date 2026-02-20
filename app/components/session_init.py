"""Initialize session state defaults for all pages."""

import streamlit as st


def init_session_state():
    defaults = {
        "pipeline_result": None,
        "video_path": None,
        "pipeline_running": False,
        "pipeline_config": None,
    }
    for key, value in defaults.items():
        if key not in st.session_state:
            st.session_state[key] = value
