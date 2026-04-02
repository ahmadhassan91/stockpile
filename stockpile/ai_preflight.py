"""OpenAI-backed upload preflight for safer client-facing defaults."""

from __future__ import annotations

import base64
import json
import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import cv2
import numpy as np
try:
    from openai import OpenAI
except ImportError:  # pragma: no cover - handled gracefully at runtime
    OpenAI = None

logger = logging.getLogger(__name__)

KNOWN_MATERIALS = (
    "Backfill 0–75 mm",
    "Aggregates 5–14 mm",
    "Aggregates 10–20 mm",
)
KNOWN_PROFILES = (
    "fast_review",
    "standard",
    "high_accuracy",
    "cone_recovery",
)


@dataclass
class AIPreflightResult:
    suggested_material: str | None
    material_confidence: float
    processing_profile: str | None
    profile_confidence: float
    cone_visibility_score: float
    retake_required: bool
    retake_reason: str
    notes: list[str] = field(default_factory=list)
    provider: str = "OpenAI"
    model: str = "gpt-4.1"


def openai_preflight_enabled() -> bool:
    """Return True when the OpenAI API key is present."""
    return OpenAI is not None and bool(os.getenv("OPENAI_API_KEY"))


def _sample_video_frames(
    video_path: str | Path,
    sample_ratios: tuple[float, ...] = (0.05, 0.35, 0.65, 0.92),
    max_dim: int = 1024,
) -> list[np.ndarray]:
    """Sample a handful of representative frames from the uploaded video."""
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise ValueError(f"Cannot open video for AI preflight: {video_path}")

    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if total_frames <= 0:
        cap.release()
        raise ValueError("Video has no readable frames for AI preflight.")

    sampled_frames: list[np.ndarray] = []
    sampled_indexes = sorted(
        {
            min(max(int(total_frames * ratio), 0), max(total_frames - 1, 0))
            for ratio in sample_ratios
        }
    )

    for frame_idx in sampled_indexes:
        cap.set(cv2.CAP_PROP_POS_FRAMES, frame_idx)
        ok, frame = cap.read()
        if not ok or frame is None:
            continue

        height, width = frame.shape[:2]
        longest_side = max(height, width)
        if longest_side > max_dim:
            scale = max_dim / float(longest_side)
            frame = cv2.resize(
                frame,
                (int(width * scale), int(height * scale)),
                interpolation=cv2.INTER_AREA,
            )
        sampled_frames.append(frame)

    cap.release()
    return sampled_frames


def _frame_to_data_url(frame_bgr: np.ndarray, quality: int = 85) -> str:
    """Encode a BGR frame as a JPEG data URL."""
    ok, encoded = cv2.imencode(".jpg", frame_bgr, [cv2.IMWRITE_JPEG_QUALITY, quality])
    if not ok:
        raise ValueError("Failed to encode frame for AI preflight.")
    payload = base64.b64encode(encoded.tobytes()).decode("ascii")
    return f"data:image/jpeg;base64,{payload}"


def _clamp_score(value: Any) -> float:
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return 0.0
    return max(0.0, min(1.0, numeric))


def _normalize_material(value: Any) -> str | None:
    if value in KNOWN_MATERIALS:
        return str(value)
    return None


def _normalize_profile(value: Any) -> str | None:
    if value in KNOWN_PROFILES:
        return str(value)
    return None


def run_openai_preflight(
    video_path: str | Path,
    video_info: dict[str, Any] | None,
    filename: str,
    first_frame_cones: int | None = None,
) -> AIPreflightResult | None:
    """Ask OpenAI for a conservative preflight recommendation from sampled frames."""
    api_key = os.getenv("OPENAI_API_KEY")
    if OpenAI is None or not api_key:
        return None

    model = os.getenv("OPENAI_PREFLIGHT_MODEL", "gpt-4.1")
    try:
        sampled_frames = _sample_video_frames(video_path)
        if not sampled_frames:
            return None

        metadata_summary = {
            "filename": filename,
            "duration_sec": round(float(video_info.get("duration", 0.0)), 2) if video_info else None,
            "resolution": (
                f"{int(video_info.get('width', 0))}x{int(video_info.get('height', 0))}"
                if video_info
                else None
            ),
            "first_frame_cones_detected_by_cv": first_frame_cones,
        }

        schema = {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "suggested_material": {
                    "anyOf": [
                        {"type": "string", "enum": list(KNOWN_MATERIALS)},
                        {"type": "null"},
                    ]
                },
                "material_confidence": {"type": "number"},
                "processing_profile": {
                    "type": "string",
                    "enum": list(KNOWN_PROFILES),
                },
                "profile_confidence": {"type": "number"},
                "cone_visibility_score": {"type": "number"},
                "retake_required": {"type": "boolean"},
                "retake_reason": {"type": "string"},
                "notes": {
                    "type": "array",
                    "items": {"type": "string"},
                },
            },
            "required": [
                "suggested_material",
                "material_confidence",
                "processing_profile",
                "profile_confidence",
                "cone_visibility_score",
                "retake_required",
                "retake_reason",
                "notes",
            ],
        }

        prompt = (
            "Review these stockpile-upload frames as a conservative preflight assistant for a "
            "measurement app. Do not estimate volume, scale, or weight. Only classify what is visible.\n\n"
            "Allowed material labels: Backfill 0–75 mm, Aggregates 5–14 mm, Aggregates 10–20 mm, or null when unsure.\n"
            "Allowed processing profiles: fast_review, standard, high_accuracy, cone_recovery.\n"
            "Use cone_recovery when cone visibility is weak and a denser reconstruction is likely needed.\n"
            "Set retake_required=true only when the capture quality looks too weak for a trustworthy measurement run.\n"
            "Keep notes short, concrete, and operational.\n\n"
            f"Upload metadata: {json.dumps(metadata_summary, ensure_ascii=True)}"
        )

        content = [{"type": "text", "text": prompt}]
        for index, frame in enumerate(sampled_frames, start=1):
            content.append(
                {
                    "type": "image_url",
                    "image_url": {
                        "url": _frame_to_data_url(frame),
                        "detail": "low",
                    },
                }
            )
            content.append({"type": "text", "text": f"Frame {index}"})

        client = OpenAI(api_key=api_key, timeout=20.0)
        response = client.chat.completions.create(
            model=model,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You are an imaging preflight assistant for a stockpile measurement system. "
                        "Be conservative, avoid guessing, and return only valid JSON."
                    ),
                },
                {
                    "role": "user",
                    "content": content,
                },
            ],
            response_format={
                "type": "json_schema",
                "json_schema": {
                    "name": "stockpile_preflight",
                    "strict": True,
                    "schema": schema,
                },
            },
            max_tokens=450,
        )

        raw_content = response.choices[0].message.content or "{}"
        payload = json.loads(raw_content)

        return AIPreflightResult(
            suggested_material=_normalize_material(payload.get("suggested_material")),
            material_confidence=_clamp_score(payload.get("material_confidence")),
            processing_profile=_normalize_profile(payload.get("processing_profile")),
            profile_confidence=_clamp_score(payload.get("profile_confidence")),
            cone_visibility_score=_clamp_score(payload.get("cone_visibility_score")),
            retake_required=bool(payload.get("retake_required", False)),
            retake_reason=str(payload.get("retake_reason", "")).strip(),
            notes=[str(item).strip() for item in payload.get("notes", []) if str(item).strip()],
            model=model,
        )
    except Exception as exc:
        logger.warning("OpenAI preflight failed: %s", exc)
        return None
