"""Fast provisional decision logic for the mobile-first path."""

from __future__ import annotations

from .models import CaptureQualityState, ProvisionalMeasurementInput, ProvisionalMeasurementOutput


def evaluate_provisional_measurement(payload: ProvisionalMeasurementInput) -> ProvisionalMeasurementOutput:
    reasons: list[str] = []

    if payload.tagged_reference_recovery_ratio < 0.34:
        reasons.append("Tagged reference recovery is too weak for a field-trustworthy estimate.")
    if payload.capture.toe_coverage_score < 0.65:
        reasons.append("Toe coverage is not complete enough for release.")
    if payload.capture.motion_stability_score < 0.55:
        reasons.append("Capture motion is too unstable for a strong provisional estimate.")
    if payload.scale_agreement_ratio is not None and payload.scale_agreement_ratio > 1.35:
        reasons.append("Scale signals disagree beyond the allowed provisional tolerance.")

    confidence_score = (
        payload.tagged_reference_recovery_ratio * 0.35
        + payload.capture.toe_coverage_score * 0.2
        + payload.capture.motion_stability_score * 0.15
        + payload.capture.perimeter_coverage_score * 0.1
        + payload.toe_confidence_score * 0.1
        + payload.geometry_confidence_score * 0.1
    )

    if reasons:
        severe = any(
            phrase in reason
            for reason in reasons
            for phrase in (
                "too weak",
                "not complete enough",
                "too unstable",
                "disagree beyond",
            )
        )
        state = CaptureQualityState.RETAKE if severe and confidence_score < 0.55 else CaptureQualityState.REVIEW
        operator_action = (
            "Retake with stronger tagged-reference visibility and fuller toe coverage."
            if state == CaptureQualityState.RETAKE
            else "Review against the latest benchmark before release."
        )
        return ProvisionalMeasurementOutput(
            state=state,
            provisional_volume_m3=payload.quick_volume_m3,
            confidence_score=confidence_score,
            reasons=tuple(reasons),
            operator_action=operator_action,
        )

    return ProvisionalMeasurementOutput(
        state=CaptureQualityState.READY,
        provisional_volume_m3=payload.quick_volume_m3,
        confidence_score=confidence_score,
        reasons=(),
        operator_action="Field result is strong enough for provisional use while verification completes.",
    )

