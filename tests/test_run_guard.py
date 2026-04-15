from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "app"))

from components.run_guard import (  # noqa: E402
    describe_active_run,
    heartbeat_run_lock,
    read_active_run_lock,
    release_run_lock,
    try_acquire_run_lock,
)


def test_run_guard_acquire_heartbeat_and_release(tmp_path, monkeypatch):
    lock_path = tmp_path / "active-run.json"
    monkeypatch.setenv("STOCKPILE_ACTIVE_RUN_LOCK_PATH", str(lock_path))

    acquired = try_acquire_run_lock(
        session_id="session-1",
        upload_id="upload-1",
        run_id="run-1",
        run_attempt=1,
        file_name="clip.mp4",
        stage="queued",
        message="Queued",
    )

    assert acquired.acquired is True
    assert acquired.token

    active = read_active_run_lock()
    assert active is not None
    assert active.file_name == "clip.mp4"
    assert active.stage == "queued"

    assert heartbeat_run_lock(acquired.token, stage="colmap_reconstruction", progress=0.5, message="Running")

    refreshed = read_active_run_lock()
    assert refreshed is not None
    assert refreshed.stage == "colmap_reconstruction"
    assert refreshed.progress == 0.5
    assert refreshed.message == "Running"
    assert "clip.mp4" in describe_active_run(refreshed)

    assert release_run_lock(acquired.token) is True
    assert read_active_run_lock() is None


def test_run_guard_reports_busy_active_run(tmp_path, monkeypatch):
    lock_path = tmp_path / "active-run.json"
    monkeypatch.setenv("STOCKPILE_ACTIVE_RUN_LOCK_PATH", str(lock_path))

    first = try_acquire_run_lock(
        session_id="session-1",
        upload_id="upload-1",
        run_id="run-1",
        run_attempt=1,
        file_name="first.mp4",
    )
    second = try_acquire_run_lock(
        session_id="session-2",
        upload_id="upload-2",
        run_id="run-2",
        run_attempt=1,
        file_name="second.mp4",
    )

    assert first.acquired is True
    assert second.acquired is False
    assert second.active_run is not None
    assert second.active_run.file_name == "first.mp4"


def test_run_guard_clears_stale_lock_before_acquiring(tmp_path, monkeypatch):
    lock_path = tmp_path / "active-run.json"
    monkeypatch.setenv("STOCKPILE_ACTIVE_RUN_LOCK_PATH", str(lock_path))
    monkeypatch.setenv("STOCKPILE_ACTIVE_RUN_STALE_SECONDS", "120")

    stale_payload = {
        "token": "stale-token",
        "session_id": "old-session",
        "upload_id": "old-upload",
        "run_id": "old-run",
        "run_attempt": 1,
        "file_name": "stale.mp4",
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "heartbeat_at_utc": (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat(),
        "stage": "colmap_reconstruction",
        "progress": 0.8,
        "message": "Stuck",
        "pid": 123,
    }
    lock_path.write_text(json.dumps(stale_payload), encoding="utf-8")

    acquired = try_acquire_run_lock(
        session_id="session-2",
        upload_id="upload-2",
        run_id="run-2",
        run_attempt=2,
        file_name="fresh.mp4",
    )

    assert acquired.acquired is True
    assert acquired.stale_cleared is True

    active = read_active_run_lock()
    assert active is not None
    assert active.file_name == "fresh.mp4"


def test_run_guard_clears_dead_pid_lock_before_acquiring(tmp_path, monkeypatch):
    lock_path = tmp_path / "active-run.json"
    monkeypatch.setenv("STOCKPILE_ACTIVE_RUN_LOCK_PATH", str(lock_path))

    dead_pid_payload = {
        "token": "dead-token",
        "session_id": "old-session",
        "upload_id": "old-upload",
        "run_id": "old-run",
        "run_attempt": 1,
        "file_name": "stale.mp4",
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "heartbeat_at_utc": datetime.now(timezone.utc).isoformat(),
        "stage": "colmap_reconstruction",
        "progress": 0.45,
        "message": "Waiting",
        "pid": 999999,
    }
    lock_path.write_text(json.dumps(dead_pid_payload), encoding="utf-8")

    acquired = try_acquire_run_lock(
        session_id="session-3",
        upload_id="upload-3",
        run_id="run-3",
        run_attempt=1,
        file_name="fresh-again.mp4",
    )

    assert acquired.acquired is True
    assert acquired.stale_cleared is True

    active = read_active_run_lock()
    assert active is not None
    assert active.file_name == "fresh-again.mp4"
