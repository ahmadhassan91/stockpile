"""Verification and review gating for the mobile-first path."""

from __future__ import annotations

from .models import CaptureQualityState, ReviewDecision, ReviewPacket, VerificationOutcome


def evaluate_review_packet(packet: ReviewPacket) -> ReviewDecision:
    reasons: list[str] = list(packet.provisional.reasons)

    if packet.tagged_reference_count < packet.minimum_expected_reference_count:
        reasons.append("Too few tagged references were recovered for verified release.")

    if packet.benchmark_delta_ratio is not None and packet.benchmark_delta_ratio > 0.1:
        reasons.append("Benchmark delta is still outside the pilot release tolerance.")

    if packet.scale_agreement_ratio is not None and packet.scale_agreement_ratio > 1.2:
        reasons.append("Scale agreement is not tight enough for verified release.")

    reasons.extend(packet.verifier_notes)

    if packet.provisional.state == CaptureQualityState.RETAKE:
        return ReviewDecision(
            outcome=VerificationOutcome.RECAPTURE_REQUIRED,
            summary="Capture should be retaken before the result is used.",
            reasons=tuple(reasons),
        )

    if reasons:
        outcome = (
            VerificationOutcome.RECAPTURE_REQUIRED
            if any("Too few tagged references" in reason for reason in reasons)
            else VerificationOutcome.REVIEW_ONLY
        )
        summary = (
            "Capture requires a retake before release."
            if outcome == VerificationOutcome.RECAPTURE_REQUIRED
            else "Result can be reviewed, but should not be treated as verified yet."
        )
        return ReviewDecision(
            outcome=outcome,
            summary=summary,
            reasons=tuple(reasons),
        )

    return ReviewDecision(
        outcome=VerificationOutcome.VERIFIED,
        summary="Result passed the mobile-first verification gates.",
        reasons=(),
    )

