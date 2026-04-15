"""Custom sidebar navigation that avoids brittle relative multipage links."""

from __future__ import annotations

import streamlit as st


_NAV_ITEMS = (
    ("app", "app", "app.py"),
    ("Upload", "Upload", "pages/1_Upload.py"),
    ("Processing", "Processing", "pages/2_Processing.py"),
    ("Results", "Results", "pages/3_Results.py"),
    ("Debug", "Debug", "pages/4_Debug.py"),
)


def render_sidebar_nav(current_page: str) -> None:
    """Render a button-based sidebar nav and hide Streamlit's default page links."""
    st.markdown(
        """
        <style>
        [data-testid="stSidebarNav"] {
            display: none;
        }
        </style>
        """,
        unsafe_allow_html=True,
    )

    with st.sidebar:
        st.markdown("app")
        for page_key, label, target in _NAV_ITEMS:
            clicked = st.button(
                label,
                key=f"sidebar_nav_{page_key}",
                use_container_width=True,
                type="primary" if page_key == current_page else "secondary",
            )
            if clicked and page_key != current_page:
                st.switch_page(target)
