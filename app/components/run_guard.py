"""Cross-session guard rails for client-facing processing runs."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

ACTIVE_RUN_LOCK_ENV_VAR = "STOCKPILE_ACTIVE_RUN_LOCK_PATH"
ACTIVE_RUN_STALE_SECONDS_ENV_VAR = "STOCKPILE_ACTIVE_RUN_STALE_SECONDS"
DEFAULT_ACTIVE_RUN_LOCK_PATH = Path("data/runtime/active_processing_run.json")
DEFAULT_ACTIVE_RUN_STALE_SECONDS = 1800


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _isoformat_utc(value: datetime | None = None) -> str:
    current = value or _utc_now()
    return current.isoformat()


def _parse_utc_timestamp(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _lock_path() -> Path:
    raw = os.environ.get(ACTIVE_RUN_LOCK_ENV_VAR, "").strip()
    return Path(raw) if raw else DEFAULT_ACTIVE_RUN_LOCK_PATH


def _stale_after_seconds() -> int:
    raw = os.environ.get(ACTIVE_RUN_STALE_SECONDS_ENV_VAR, "").strip()
    try:
        return max(60, int(raw))
    except ValueError:
        return DEFAULT_ACTIVE_RUN_STALE_SECONDS


def _pid_is_alive(pid: int | None) -> bool:
    if pid is None or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


@dataclass(frozen=True)
class ActiveRunInfo:
    token: str
    session_id: str | None
    upload_id: str | None
    run_id: str | None
    run_attempt: int
    file_name: str | None
    created_at_utc: str
    heartbeat_at_utc: str
    stage: str | None = None
    progress: float | None = None
    message: str | None = None
    pid: int | None = None

    @property
    def heartbeat_at(self) -> datetime | None:
        return _parse_utc_timestamp(self.heartbeat_at_utc)

    @property
    def age_seconds(self) -> int | None:
        heartbeat = self.heartbeat_at
        if heartbeat is None:
            return None
        return max(0, int((_utc_now() - heartbeat).total_seconds()))

    def to_payload(self) -> dict[str, Any]:
        return {
            "token": self.token,
            "session_id": self.session_id,
            "upload_id": self.upload_id,
            "run_id": self.run_id,
            "run_attempt": self.run_attempt,
            "file_name": self.file_name,
            "created_at_utc": self.created_at_utc,
            "heartbeat_at_utc": self.heartbeat_at_utc,
            "stage": self.stage,
            "progress": self.progress,
            "message": self.message,
            "pid": self.pid,
        }


@dataclass(frozen=True)
class RunLockAcquireResult:
    acquired: bool
    token: str | None = None
    active_run: ActiveRunInfo | None = None
    stale_cleared: bool = False


def _read_lock_payload() -> dict[str, Any] | None:
    lock_path = _lock_path()
    if not lock_path.exists():
        return None
    try:
        return json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def read_active_run_lock() -> ActiveRunInfo | None:
    payload = _read_lock_payload()
    if not payload or not payload.get("token"):
        return None
    active_run = ActiveRunInfo(
        token=str(payload["token"]),
        session_id=payload.get("session_id"),
        upload_id=payload.get("upload_id"),
        run_id=payload.get("run_id"),
        run_attempt=int(payload.get("run_attempt", 0) or 0),
        file_name=payload.get("file_name"),
        created_at_utc=str(payload.get("created_at_utc") or ""),
        heartbeat_at_utc=str(payload.get("heartbeat_at_utc") or ""),
        stage=payload.get("stage"),
        progress=payload.get("progress"),
        message=payload.get("message"),
        pid=payload.get("pid"),
    )
    if _is_stale(active_run):
        _clear_lock_if_matches(active_run.token)
        return None
    return active_run


def _is_stale(active_run: ActiveRunInfo) -> bool:
    if active_run.pid is not None and not _pid_is_alive(active_run.pid):
        return True
    age_seconds = active_run.age_seconds
    if age_seconds is None:
        return True
    return age_seconds > _stale_after_seconds()


def _write_lock_payload(payload: dict[str, Any], *, exclusive: bool) -> bool:
    lock_path = _lock_path()
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_CREAT | os.O_WRONLY
    if exclusive:
        flags |= os.O_EXCL
    else:
        flags |= os.O_TRUNC
    fd = os.open(str(lock_path), flags, 0o644)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=True)
        return True
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        raise


def _clear_lock_if_matches(expected_token: str | None = None) -> bool:
    lock_path = _lock_path()
    payload = _read_lock_payload()
    if not payload or not payload.get("token"):
        if lock_path.exists():
            try:
                lock_path.unlink()
                return True
            except FileNotFoundError:
                return False
        return False
    token = str(payload["token"])
    if expected_token is not None and token != expected_token:
        return False
    try:
        lock_path.unlink()
        return True
    except FileNotFoundError:
        return False


def try_acquire_run_lock(
    *,
    session_id: str | None,
    upload_id: str | None,
    run_id: str | None,
    run_attempt: int,
    file_name: str | None,
    stage: str = "queued",
    message: str | None = None,
) -> RunLockAcquireResult:
    """Try to acquire the global processing run lock."""
    stale_cleared = False
    payload = {
        "token": uuid4().hex,
        "session_id": session_id,
        "upload_id": upload_id,
        "run_id": run_id,
        "run_attempt": int(run_attempt or 0),
        "file_name": file_name,
        "created_at_utc": _isoformat_utc(),
        "heartbeat_at_utc": _isoformat_utc(),
        "stage": stage,
        "progress": 0.0,
        "message": message,
        "pid": os.getpid(),
    }

    for _ in range(2):
        try:
            _write_lock_payload(payload, exclusive=True)
            return RunLockAcquireResult(
                acquired=True,
                token=str(payload["token"]),
                active_run=ActiveRunInfo(
                    token=str(payload["token"]),
                    session_id=session_id,
                    upload_id=upload_id,
                    run_id=run_id,
                    run_attempt=int(run_attempt or 0),
                    file_name=file_name,
                    created_at_utc=str(payload["created_at_utc"]),
                    heartbeat_at_utc=str(payload["heartbeat_at_utc"]),
                    stage=stage,
                    progress=0.0,
                    message=message,
                    pid=os.getpid(),
                ),
                stale_cleared=stale_cleared,
            )
        except FileExistsError:
            active_run = read_active_run_lock()
            if active_run is None and not _lock_path().exists():
                stale_cleared = True
                continue
            return RunLockAcquireResult(
                acquired=False,
                active_run=active_run,
                stale_cleared=stale_cleared,
            )

    return RunLockAcquireResult(acquired=False, active_run=read_active_run_lock(), stale_cleared=stale_cleared)


def heartbeat_run_lock(
    token: str | None,
    *,
    stage: str | None = None,
    progress: float | None = None,
    message: str | None = None,
) -> bool:
    """Refresh the heartbeat and current status for the active run."""
    if not token:
        return False
    active_run = read_active_run_lock()
    if active_run is None or active_run.token != token:
        return False
    payload = active_run.to_payload()
    payload["heartbeat_at_utc"] = _isoformat_utc()
    if stage is not None:
        payload["stage"] = stage
    if progress is not None:
        payload["progress"] = max(0.0, min(1.0, float(progress)))
    if message is not None:
        payload["message"] = message
    _write_lock_payload(payload, exclusive=False)
    return True


def release_run_lock(token: str | None) -> bool:
    """Release the active run lock if it belongs to the provided token."""
    if not token:
        return False
    return _clear_lock_if_matches(token)


def describe_active_run(active_run: ActiveRunInfo | None) -> str:
    """Build a short user-facing summary of the active processing run."""
    if active_run is None:
        return "Another processing run is active."

    age_seconds = active_run.age_seconds
    if age_seconds is None:
        age_label = "unknown age"
    elif age_seconds >= 120:
        age_label = f"{age_seconds // 60} min ago"
    else:
        age_label = f"{age_seconds} sec ago"

    details = []
    if active_run.file_name:
        details.append(f"`{active_run.file_name}`")
    if active_run.stage:
        details.append(f"stage: `{active_run.stage}`")
    details.append(f"heartbeat: {age_label}")
    return "Another processing run is already active for " + ", ".join(details) + "."
