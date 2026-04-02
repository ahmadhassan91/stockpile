"""Initialize session state defaults for all pages."""

import streamlit as st


def init_session_state():
    defaults = {
        "pipeline_result": None,
        "video_path": None,
        "pipeline_running": False,
        "pipeline_config": None,
        "settings_confirmed": False,
        "settings_dialog_dismissed": False,
        "confirmed_settings_signature": None,
        "upload_inferred_material": None,
        "pending_sidebar_setting_overrides": None,
        "sidebar_admin_mode": False,
        "recommended_processing_profile": None,
        "recommended_processing_notes": [],
    }
    for key, value in defaults.items():
        if key not in st.session_state:
            st.session_state[key] = value
