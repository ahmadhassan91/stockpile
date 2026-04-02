"""Client-facing reliability status labels for preflight and final results."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import streamlit as st


@dataclass(frozen=True)
class ReliabilityStatus:
    key: str
    title: str
    message: str
    tone: str


def classify_preflight_status(
    ai_preflight: Any | None,
    detections: list | None,
    profile_label: str | None = None,
) -> ReliabilityStatus:
    """Summarize the likely trust level before the pipeline runs."""
    cone_count = len(detections or [])

    if ai_preflight is not None and ai_preflight.retake_required:
        reason = ai_preflight.retake_reason or (
            "The sampled frames look too weak for a trustworthy measurement run."
        )
        return ReliabilityStatus(
            key="retake_needed",
            title="Retake needed",
            message=reason,
            tone="error",
        )

    if cone_count == 0:
        return ReliabilityStatus(
            key="retake_needed",
            title="Retake needed",
            message=(
                "No reference cone is clearly visible in the first frame. "
                "The run may still start, but we should expect scale calibration to fail unless later frames are much clearer."
            ),
            tone="error",
        )

    if cone_count == 1:
        profile_hint = f" The auto profile is **{profile_label}** to help recover more detail." if profile_label else ""
        return ReliabilityStatus(
            key="review_grade_likely",
            title="Review-grade likely",
            message=(
                "The capture looks usable, but only one physical reference is clearly visible up front. "
                "This often leads to a review-grade result rather than a fully verified one."
                f"{profile_hint}"
            ),
            tone="warning",
        )

    return ReliabilityStatus(
        key="verified_likely",
        title="Verified likely",
        message=(
            "Multiple physical references are visible, so this upload is on track for a verified-grade result "
            "if reconstruction and scale remain stable."
        ),
        tone="success",
    )


def classify_result_status(result: Any) -> ReliabilityStatus:
    """Summarize the final trust level after the pipeline completes."""
    if not result.publishable:
        detail = (
            result.quality_blockers[0]
            if getattr(result, "quality_blockers", None)
            else "One or more reliability checks failed."
        )
        return ReliabilityStatus(
            key="retake_needed",
            title="Retake needed",
            message=(
                "This run should not be used for reporting yet. "
                f"{detail}"
            ),
            tone="error",
        )

    if getattr(result, "review_grade", False):
        return ReliabilityStatus(
            key="review_grade",
            title="Review-grade result",
            message=(
                "The geometry looks usable, but scale confidence is still limited. "
                "Use this for internal review or side-by-side comparison, and cross-check before client-facing reporting."
            ),
            tone="warning",
        )

    if getattr(result, "quality_warnings", None):
        return ReliabilityStatus(
            key="verified",
            title="Verified result",
            message=(
                "This run passed the reliability gates. The remaining warnings are advisory and should be reviewed, "
                "but the result is suitable for reporting."
            ),
            tone="success",
        )

    return ReliabilityStatus(
        key="verified",
        title="Verified result",
        message="This run passed the reliability gates and is suitable for reporting.",
        tone="success",
    )


def render_status_callout(status: ReliabilityStatus, prefix: str | None = None):
    """Render a consistent status banner across pages."""
    text = f"**{status.title}.** {status.message}"
    if prefix:
        text = f"{prefix} {text}"

    if status.tone == "success":
        st.success(text)
    elif status.tone == "warning":
        st.warning(text)
    elif status.tone == "error":
        st.error(text)
    else:
        st.info(text)
