"""Plotly 3D visualization helpers for Streamlit."""

import numpy as np
import open3d as o3d
import plotly.graph_objects as go


def point_cloud_to_plotly(
    pcd: o3d.geometry.PointCloud,
    name: str = "Point Cloud",
    colorby: str = "height",
    point_size: float = 2.0,
    colorscale: str = "Viridis",
) -> go.Scatter3d:
    """Convert Open3D point cloud to a Plotly Scatter3d trace."""
    points = np.asarray(pcd.points)
    if len(points) == 0:
        return go.Scatter3d(x=[], y=[], z=[], mode="markers", name=name)

    if colorby == "height":
        color = points[:, 2]
    elif colorby == "rgb" and pcd.has_colors():
        colors = (np.asarray(pcd.colors) * 255).astype(int)
        color = [f"rgb({r},{g},{b})" for r, g, b in colors]
        colorscale = None
    else:
        color = points[:, 2]

    marker = dict(size=point_size)
    if colorscale:
        marker["color"] = color
        marker["colorscale"] = colorscale
        marker["colorbar"] = dict(title="Height (m)")
    else:
        marker["color"] = color

    return go.Scatter3d(
        x=points[:, 0],
        y=points[:, 1],
        z=points[:, 2],
        mode="markers",
        marker=marker,
        name=name,
    )


def create_ground_plane_mesh(
    x_range: tuple[float, float],
    y_range: tuple[float, float],
    z: float = 0.0,
    opacity: float = 0.3,
) -> go.Mesh3d:
    """Create a semi-transparent ground plane mesh at z=0."""
    x0, x1 = x_range
    y0, y1 = y_range
    return go.Mesh3d(
        x=[x0, x1, x1, x0],
        y=[y0, y0, y1, y1],
        z=[z, z, z, z],
        i=[0, 0],
        j=[1, 2],
        k=[2, 3],
        color="lightgray",
        opacity=opacity,
        name="Ground Plane",
    )


def create_cone_markers(
    positions: list[np.ndarray],
    name: str = "Cones",
) -> go.Scatter3d:
    """Create markers for detected cone positions."""
    if not positions:
        return go.Scatter3d(x=[], y=[], z=[], mode="markers", name=name)

    pts = np.array(positions)
    return go.Scatter3d(
        x=pts[:, 0],
        y=pts[:, 1],
        z=pts[:, 2],
        mode="markers",
        marker=dict(size=8, color="red", symbol="diamond"),
        name=name,
    )


def build_3d_figure(
    pile_cloud: o3d.geometry.PointCloud,
    ground_cloud: o3d.geometry.PointCloud | None = None,
    cone_positions: list[np.ndarray] | None = None,
    title: str = "Stockpile 3D View",
) -> go.Figure:
    """Build a complete 3D figure with pile, ground, and cones."""
    fig = go.Figure()

    # Pile points colored by height
    fig.add_trace(point_cloud_to_plotly(pile_cloud, name="Pile", colorby="height"))

    # Ground plane
    if ground_cloud is not None and len(ground_cloud.points) > 0:
        pts = np.asarray(ground_cloud.points)
        subsample = pts[::max(1, len(pts) // 5000)]  # Limit ground points for performance
        fig.add_trace(go.Scatter3d(
            x=subsample[:, 0],
            y=subsample[:, 1],
            z=subsample[:, 2],
            mode="markers",
            marker=dict(size=1, color="gray", opacity=0.3),
            name="Ground",
        ))

    # Ground plane mesh
    pile_pts = np.asarray(pile_cloud.points)
    if len(pile_pts) > 0:
        margin = 0.5
        x_range = (pile_pts[:, 0].min() - margin, pile_pts[:, 0].max() + margin)
        y_range = (pile_pts[:, 1].min() - margin, pile_pts[:, 1].max() + margin)
        fig.add_trace(create_ground_plane_mesh(x_range, y_range))

    # Cone markers
    if cone_positions:
        fig.add_trace(create_cone_markers(cone_positions))

    fig.update_layout(
        title=title,
        scene=dict(
            xaxis_title="X (m)",
            yaxis_title="Y (m)",
            zaxis_title="Z (m)",
            aspectmode="data",
        ),
        width=800,
        height=600,
    )

    return fig
