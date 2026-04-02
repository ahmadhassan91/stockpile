"""Page 3: Results — volume, weight, calibration diagnostics, and 3D viewer."""

import numpy as np
import streamlit as st

from stockpile.visualization import build_3d_figure

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))
from components.session_init import init_session_state

init_session_state()
st.header("3. Results")

result = st.session_state.get("pipeline_result")
if result is None or result.error:
    st.warning("No results available. Run the pipeline on the Processing page first.")
    if result and result.error:
        st.error(f"Last run failed: {result.error}")
    st.stop()

vol = result.volume
config = st.session_state.get("pipeline_config")

if not result.publishable:
    st.error(
        "🚫 **Review only — this run failed one or more reliability checks.** "
        "Do not use the reported tonnage for client-facing reporting until the blockers below are addressed."
    )
elif result.quality_warnings:
    st.warning(
        "⚠️ **This run completed with reliability warnings.** "
        "Treat the result as indicative and cross-check it against a survey or weighbridge reference."
    )

if result.quality_blockers:
    st.markdown("**Reliability blockers**")
    for blocker in result.quality_blockers:
        st.write(f"- {blocker}")

if result.quality_warnings:
    st.markdown("**Reliability warnings**")
    for warning in result.quality_warnings:
        st.write(f"- {warning}")

st.divider()

# ── Scale Calibration Diagnostics ─────────────────────────────────────────────
st.subheader("📏 Scale Calibration")

if result.calibration:
    cal = result.calibration
    scale_factor = result.scale_factor_m_per_unit or cal.scale_factor
    conf_pct = cal.confidence * 100

    # Classify confidence level
    if conf_pct >= 70:
        conf_color = "🟢"
        conf_label = "High"
    elif conf_pct >= 40:
        conf_color = "🟡"
        conf_label = "Medium"
    else:
        conf_color = "🔴"
        conf_label = "Low — consider using manual scale override"

    col1, col2, col3, col4 = st.columns(4)
    col1.metric("Scale Factor", f"{scale_factor:.4f} m/unit")
    col2.metric("Confidence", f"{conf_pct:.0f}%", help="Based on cone detection consistency across frames")
    col3.metric("Cones Detected", str(cal.num_cones_used))
    col4.metric("Scale Source", result.scale_source.replace("_", " ").title())

    if conf_pct < 70:
        st.warning(
            f"{conf_color} **Calibration confidence is {conf_label}.** "
            "This may cause the volume to be significantly over- or under-estimated. "
            "**Recommended:** go to the Upload page, enable 'Override auto-detected scale' in the sidebar, "
            "and enter a scale factor based on a known reference distance."
        )
    else:
        st.success(f"{conf_color} Calibration confidence is **{conf_label}** ({conf_pct:.0f}%).")

    if len(cal.per_cone_scales) > 1:
        import statistics
        cv = statistics.stdev(cal.per_cone_scales) / statistics.mean(cal.per_cone_scales) * 100
        with st.expander("Scale factor spread across frames"):
            st.caption(
                f"Min: {min(cal.per_cone_scales):.4f} | "
                f"Median: {cal.scale_factor:.4f} | "
                f"Max: {max(cal.per_cone_scales):.4f} | "
                f"CV: {cv:.1f}%"
            )
            if cv > 30:
                st.warning(
                    "⚠️ High variation (CV > 30%) across cone measurements. "
                    "Cones may have been partially occluded or the wrong size was configured."
                )

    if cal.scale_disagreement_ratio:
        st.caption(
            f"Cross-check ratio: {cal.scale_disagreement_ratio:.2f}x "
            f"(projection {cal.projection_scale_factor:.4f} vs camera-height {cal.camera_height_scale_factor:.4f} m/unit)"
        )
        if cal.scale_disagreement_ratio > 1.5:
            st.warning(
                "⚠️ The cone-based scale and the camera-height cross-check disagree materially. "
                "This is a strong signal that the geometry or cone matches need review."
            )
else:
    if result.scale_source == "manual_override" and result.scale_factor_m_per_unit is not None:
        st.info(
            f"ℹ️ **Manual scale override was used** at {result.scale_factor_m_per_unit:.4f} m/unit. "
            "Cone-based auto-calibration diagnostics are not available for this run."
        )
    else:
        st.error(
            "🔴 **No scale calibration was performed** — no cones were detected in the video. "
            "The volume is in raw COLMAP units and is **not meaningful**. "
            "\n\nTo fix: upload a video with visible red traffic cones, or enable the "
            "'Override auto-detected scale' option in the sidebar and enter a known scale factor."
        )

st.divider()

# ── Point Cloud Quality ────────────────────────────────────────────────────────
pile_pts = len(result.pile_cloud.points) if result.pile_cloud else 0
ground_pts = len(result.ground_cloud.points) if result.ground_cloud else 0
total_pts = pile_pts + ground_pts
pile_arr = np.asarray(result.pile_cloud.points) if result.pile_cloud and len(result.pile_cloud.points) else np.empty((0, 3))
pile_height_p99 = float(np.percentile(pile_arr[:, 2], 99)) if len(pile_arr) >= 100 else None
peak_relief = (float(np.max(pile_arr[:, 2])) - pile_height_p99) if pile_height_p99 is not None else None

col1, col2, col3, col4 = st.columns(4)
col1.metric("COLMAP 3D Points", f"{result.num_colmap_points:,}")
col2.metric("Pile Points", f"{pile_pts:,}")
col3.metric("Ground Points", f"{ground_pts:,}")
col4.metric("P99 Height", f"{pile_height_p99:.2f} m" if pile_height_p99 is not None else "N/A")

if pile_pts < 500:
    st.warning(
        f"⚠️ Only **{pile_pts} pile points** were segmented — this is very sparse. "
        "Volume accuracy will be limited. Try reducing the frame interval or using higher COLMAP quality."
    )

if peak_relief is not None and peak_relief > 1.0:
    st.warning(
        f"⚠️ The very top of the reconstructed pile rises {peak_relief:.2f} m above the 99th-percentile surface height. "
        "Review the 3D shape for ridge or spike artifacts."
    )

if vol:
    col1, col2, col3, col4 = st.columns(4)
    col1.metric("Grid Occupancy", f"{vol.grid_occupancy_pct:.1f}%")
    if vol.grid_to_hull_ratio is not None:
        col2.metric("Grid / Hull Ratio", f"{vol.grid_to_hull_ratio:.2f}x")
    else:
        col2.metric("Grid / Hull Ratio", "N/A")
    col3.metric("Recommended Method", vol.recommended_method.replace("_", " ").title())
    col4.metric("Footprint", (vol.footprint_source or "bounding_box").replace("_", " ").title())

st.divider()

# ── Volume Results ─────────────────────────────────────────────────────────────
st.subheader("📦 Volume & Weight")

col1, col2, col3 = st.columns(3)
col1.metric(
    "Volume (recommended)" if result.publishable else "Volume (review only)",
    f"{vol.recommended_m3:.2f} m³",
    help="The selected output after applying volume sanity checks",
)
col2.metric(
    "Weight",
    f"{result.weight_kg / 1000:.2f} tonnes",
)
if config:
    col3.metric(
        "Weight (kg)",
        f"{result.weight_kg:,.0f} kg",
        help=f"Density used: {config.material_density:.0f} kg/m³ ({config.material_name})",
    )
else:
    col3.metric("Weight (kg)", f"{result.weight_kg:,.0f} kg")

# All three volume methods side-by-side
st.subheader("Volume Method Comparison")
st.caption(
    "All three methods are shown so you can cross-check. "
    "Convex Hull is typically an upper bound; Grid Integration is the preferred value when coverage is strong."
)

c1, c2, c3 = st.columns(3)
with c1:
    st.metric(
        "🔵 Grid Integration",
        f"{vol.grid_integration_m3:.2f} m³",
    )
    st.caption(
        f"Grid: {vol.grid_resolution:.2f} m cells, {vol.num_points:,} pile points, "
        f"{vol.grid_occupancy_pct:.1f}% occupancy"
    )
    if vol.footprint_area_m2 is not None:
        st.caption(f"Footprint area: {vol.footprint_area_m2:.1f} m² via {vol.footprint_source.replace('_', ' ')}")

with c2:
    st.metric(
        "🟣 Convex Hull (Upper Bound)",
        f"{vol.convex_hull_m3:.2f} m³",
    )
    st.caption("Wraps all points — typically overestimates")

with c3:
    if vol.alpha_shape_m3 is not None:
        st.metric(
            "🟢 Alpha Shape",
            f"{vol.alpha_shape_m3:.2f} m³",
        )
        st.caption("Watertight mesh — accurate for dense point clouds")
    else:
        st.metric("🟢 Alpha Shape", "N/A")
        st.caption("Failed or non-watertight — insufficient point density")

if vol.recommended_note:
    st.info(f"Using {vol.recommended_method.replace('_', ' ')}: {vol.recommended_note}")

# Sanity check: flag if convex hull is > 3× grid integration (indicates volume loss)
if vol.convex_hull_m3 > 0 and vol.grid_integration_m3 > 0:
    ratio = vol.convex_hull_m3 / vol.grid_integration_m3
    if ratio > 3.0:
        st.warning(
            f"⚠️ **Convex Hull ({vol.convex_hull_m3:.1f} m³) is {ratio:.1f}× larger than "
            f"Grid Integration ({vol.grid_integration_m3:.1f} m³).** "
            "This suggests significant edge volume is being lost due to sparse point coverage. "
            "Consider: smaller frame interval, higher COLMAP quality, or using the Convex Hull value as a check."
        )

st.divider()

# ── 3D Viewer ─────────────────────────────────────────────────────────────────
st.subheader("🌐 3D Point Cloud")
if result.pile_cloud and len(result.pile_cloud.points) > 0:
    fig = build_3d_figure(
        result.pile_cloud,
        result.ground_cloud,
        result.cone_3d_positions if result.cone_3d_positions else None,
    )
    st.plotly_chart(fig, use_container_width=True)
else:
    st.warning("No pile points to display.")

# ── Download ──────────────────────────────────────────────────────────────────
st.subheader("⬇️ Download")
if result.ply_path and result.ply_path.exists():
    with open(result.ply_path, "rb") as f:
        st.download_button(
            label="Download Sparse Point Cloud (PLY)",
            data=f.read(),
            file_name="stockpile_sparse.ply",
            mime="application/octet-stream",
        )
