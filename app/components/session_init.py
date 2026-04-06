"""Initialize session state defaults for all pages."""

import streamlit as st

from components.client_test_log import (
    CLIENT_RUN_ATTEMPT_KEY,
    CLIENT_RUN_ID_KEY,
    CLIENT_SESSION_ID_KEY,
    CLIENT_UPLOAD_ID_KEY,
    ensure_client_session_id,
)
from components.persisted_session import (
    PERSISTED_SESSION_RESTORED_KEY,
    restore_session_snapshot,
)


def init_session_state():
    defaults = {
        "pipeline_result": None,
        "video_path": None,
        "pipeline_running": False,
        "pipeline_config": None,
        "confirmed_pipeline_config": None,
        "settings_confirmed": False,
        "settings_dialog_dismissed": False,
        "confirmed_settings_signature": None,
        "upload_inferred_material": None,
        "upload_inferred_material_source": None,
        "pending_sidebar_setting_overrides": None,
        "sidebar_admin_mode": False,
        "recommended_processing_profile": None,
        "recommended_processing_notes": [],
        "ai_preflight_result": None,
        "ai_preflight_source": None,
        "last_uploaded_name": None,
        "last_uploaded_signature": None,
        "_upload_processed": False,
        "_video_info": None,
        "progress_queue": None,
        "pipeline_thread": None,
        "processing_lock_token": None,
        CLIENT_SESSION_ID_KEY: None,
        CLIENT_UPLOAD_ID_KEY: None,
        CLIENT_RUN_ID_KEY: None,
        CLIENT_RUN_ATTEMPT_KEY: 0,
        PERSISTED_SESSION_RESTORED_KEY: False,
    }
    for key, value in defaults.items():
        if key not in st.session_state:
            st.session_state[key] = value

    if not st.session_state.get(PERSISTED_SESSION_RESTORED_KEY):
        restore_session_snapshot(st.session_state)
        st.session_state[PERSISTED_SESSION_RESTORED_KEY] = True

    ensure_client_session_id(st.session_state)
