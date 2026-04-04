from __future__ import annotations

import json
import sys
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "app"))

from components.client_test_log import (  # noqa: E402
    CLIENT_RUN_ATTEMPT_KEY,
    CLIENT_RUN_ID_KEY,
    CLIENT_SESSION_ID_KEY,
    CLIENT_UPLOAD_ID_KEY,
    append_client_test_event,
    start_new_run_tracking,
    start_new_upload_tracking,
)
from stockpile.config import PipelineConfig  # noqa: E402


def test_tracking_ids_progress_from_session_to_upload_to_run():
    session_state = {}

    upload_id = start_new_upload_tracking(session_state)
    run_id = start_new_run_tracking(session_state)

    assert session_state[CLIENT_SESSION_ID_KEY]
    assert session_state[CLIENT_UPLOAD_ID_KEY] == upload_id
    assert session_state[CLIENT_RUN_ID_KEY] == run_id
    assert session_state[CLIENT_RUN_ATTEMPT_KEY] == 1


def test_append_client_test_event_writes_structured_jsonl(tmp_path, monkeypatch):
    log_path = tmp_path / "client-events.jsonl"
    monkeypatch.setenv("STOCKPILE_CLIENT_EVENT_LOG", str(log_path))

    session_state = {
        "last_uploaded_name": "AGGREGATE 5-14MM V1.mp4",
        "last_uploaded_signature": "AGGREGATE 5-14MM V1.mp4:12345",
        "selected_material": "Aggregates 5–14 mm",
        "selected_density": 1650.0,
        "recommended_processing_profile": "Standard",
        "sidebar_admin_mode": False,
        "manual_scale_override": None,
        "ai_preflight_result": None,
    }
    start_new_upload_tracking(session_state)
    start_new_run_tracking(session_state)

    config = PipelineConfig(material_density=1650.0, material_name="Aggregates 5–14 mm")
    config.frame_extraction.interval_sec = 0.25
    config.frame_extraction.max_frames = 800
    config.colmap.quality = "medium"
    config.volume.grid_resolution = 0.04

    result = SimpleNamespace(
        error=None,
        publishable=True,
        review_grade=True,
        stage="complete",
        weight_kg=139969.0,
        num_frames=290,
        num_frames_with_cones=33,
        num_colmap_points=102025,
        num_colmap_images=140,
        pile_cloud=SimpleNamespace(points=[0] * 35567),
        scale_source="projection",
        scale_factor_m_per_unit=1.872,
        quality_blockers=[],
        quality_warnings=["example warning"],
        calibration=SimpleNamespace(
            confidence=0.70,
            num_cones_used=1,
            detected_cone_frames=33,
            registered_cone_frames=21,
            max_detections_in_frame=1,
            frames_with_multiple_detections=0,
            scale_disagreement_ratio=1.53,
        ),
        volume=SimpleNamespace(
            recommended_m3=84.83,
            recommended_method="grid_integration",
        ),
    )

    append_client_test_event(
        session_state,
        "processing_completed",
        config=config,
        uploaded_file=SimpleNamespace(name="AGGREGATE 5-14MM V1.mp4", size=12345),
        video_info={"duration": 67.7, "fps": 30.0, "width": 1080, "height": 1920},
        detections=[1],
        result=result,
        extra={"source": "test"},
    )

    payload = json.loads(log_path.read_text(encoding="utf-8").splitlines()[0])

    assert payload["event_type"] == "processing_completed"
    assert payload["session_id"] == session_state[CLIENT_SESSION_ID_KEY]
    assert payload["upload_id"] == session_state[CLIENT_UPLOAD_ID_KEY]
    assert payload["run_id"] == session_state[CLIENT_RUN_ID_KEY]
    assert payload["run_attempt"] == 1
    assert payload["upload"]["file_name"] == "AGGREGATE 5-14MM V1.mp4"
    assert payload["config"]["processing_profile"] == "Standard"
    assert payload["result"]["status"] == "review_grade"
    assert payload["result"]["recommended_volume_m3"] == 84.83
    assert payload["result"]["registered_cone_frames"] == 21
    assert payload["extra"]["source"] == "test"
