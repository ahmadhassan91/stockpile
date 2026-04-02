"""Point cloud viewer component for Streamlit."""

import streamlit as st
import open3d as o3d
import numpy as np

from stockpile.visualization import build_3d_figure


def render_point_cloud_viewer(
    pile_cloud: o3d.geometry.PointCloud,
    ground_cloud: o3d.geometry.PointCloud | None = None,
    cone_positions: list[np.ndarray] | None = None,
):
    """Render an interactive 3D point cloud viewer."""
    fig = build_3d_figure(pile_cloud, ground_cloud, cone_positions)
    st.plotly_chart(fig, width="stretch")
