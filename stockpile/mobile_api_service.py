"""File-backed mobile API service for capture, upload, job, and result flow."""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import shutil
from collections import Counter
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

import numpy as np

from .mobile_first.models import (
    DevicePoseSample,
    MobileFirstCaptureEnvelope,
    ProvisionalMeasurementInput,
    ReferenceObservation,
    ReferenceObservationState,
    ReviewPacket,
    VerificationOutcome,
)
from .mobile_first.provisional import evaluate_provisional_measurement
from .mobile_first.review import evaluate_review_packet
from .mobile_api_models import (
    CaptureQualityInputPayload,
    CaptureQualityPayload,
    CaptureSession,
    CaptureSessionCreateRequest,
    ConfidencePayload,
    JobPhase,
    MaterialSuggestionPayload,
    MeasurementPayload,
    ProcessingJobStatus,
    ProcessingStatePayload,
    ProvisionalMeasurementPayload,
    QualityGatePayload,
    QualityGateState,
    ReconstructionPayload,
    ReconstructionPointPayload,
    ReconstructionTrianglePayload,
    ReferenceEvidenceFramePayload,
    ReferenceDiagnosticsPayload,
    ReferenceMarkerQuality,
    ReferenceObservationPayload,
    ReferenceObservationSummaryPayload,
    ResultPayload,
    RunOutcome,
    UploadAuthorization,
    UploadProgressPayload,
    UploadReceipt,
    UploadRequest,
    UploadState,
    isoformat_utc,
    parse_datetime,
    utc_now,
)


class MobileAPIServiceError(RuntimeError):
    """Base exception for durable mobile API operations."""


class CaptureSessionNotFoundError(MobileAPIServiceError):
    pass


class UploadNotFoundError(MobileAPIServiceError):
    pass


class ProcessingJobNotFoundError(MobileAPIServiceError):
    pass


class ResultNotFoundError(MobileAPIServiceError):
    pass


class MobileAPIValidationError(MobileAPIServiceError):
    pass


def _sanitize_filename(name: str) -> str:
    candidate = Path(name).name.replace(" ", "_")
    sanitized = "".join(ch for ch in candidate if ch.isalnum() or ch in {"-", "_", "."})
    return sanitized or "capture.bin"


def _normalize_id(value: str | None) -> str | None:
    if value is None:
        return None
    normalized = str(value).strip()
    return normalized or None


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid4().hex[:12]}"


def _env_int(name: str, default: int, *, minimum: int = 1) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return max(minimum, int(default))
    try:
        parsed = int(raw)
    except ValueError:
        return max(minimum, int(default))
    if parsed < minimum:
        return max(minimum, int(default))
    return parsed


def _dedupe_messages(messages: list[str] | tuple[str, ...] | None) -> list[str]:
    unique: list[str] = []
    seen: set[str] = set()
    for raw in messages or []:
        message = str(raw).strip()
        if not message or message in seen:
            continue
        seen.add(message)
        unique.append(message)
    return unique


def _normalize_content_type(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = str(value).strip().lower()
    if not stripped:
        return None
    return stripped.split(";", 1)[0].strip() or None


def _normalize_checksum(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = str(value).strip().lower()
    return stripped or None


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            if not chunk:
                continue
            digest.update(chunk)
    return digest.hexdigest()


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, payload: dict[str, Any]):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_suffix(f"{path.suffix}.tmp")
    temp_path.write_text(
        json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    temp_path.replace(path)


@dataclass(frozen=True)
class UploadArtifact:
    upload_id: str
    storage_path: Path
    byte_count: int


@dataclass(frozen=True)
class UploadContext:
    upload_id: str
    job_id: str
    run_id: str
    session: CaptureSession
    upload_request: UploadRequest
    storage_path: Path


@dataclass(frozen=True)
class UploadFinalization:
    receipt: UploadReceipt
    job_status: ProcessingJobStatus


class StockpileMobileAPIService:
    """Durable backend contract layer for the native iOS capture flow.

    The repo does not yet contain an HTTP server. This service provides the
    smallest real backend slice we need first: stable request/response models,
    durable IDs, upload persistence, job polling state, and final results.
    """

    def __init__(
        self,
        *,
        root_dir: str | Path = "data/mobile_api",
        api_base_url: str = "http://localhost:8000/api/mobile",
        upload_base_url: str | None = None,
        report_base_url: str | None = None,
        session_ttl_hours: int = 6,
        upload_ttl_minutes: int = 30,
    ):
        self.root_dir = Path(root_dir)
        self.api_base_url = api_base_url.rstrip("/")
        self.upload_base_url = (
            upload_base_url.rstrip("/")
            if upload_base_url
            else f"{self.api_base_url}/uploads"
        )
        self.report_base_url = report_base_url.rstrip("/") if report_base_url else None
        self.session_ttl_hours = max(1, int(session_ttl_hours))
        self.upload_ttl_minutes = max(1, int(upload_ttl_minutes))

        self.sessions_dir = self.root_dir / "capture_sessions"
        self.uploads_dir = self.root_dir / "uploads"
        self.jobs_dir = self.root_dir / "jobs"
        self.results_dir = self.root_dir / "results"
        self.objects_dir = self.root_dir / "objects"

        for directory in (
            self.sessions_dir,
            self.uploads_dir,
            self.jobs_dir,
            self.results_dir,
            self.objects_dir,
        ):
            directory.mkdir(parents=True, exist_ok=True)

    @classmethod
    def from_environment(cls) -> "StockpileMobileAPIService":
        return cls(
            root_dir=os.environ.get("STOCKPILE_MOBILE_API_ROOT", "data/mobile_api"),
            api_base_url=os.environ.get(
                "STOCKPILE_MOBILE_API_BASE_URL",
                "http://localhost:8000/api/mobile",
            ),
            upload_base_url=os.environ.get("STOCKPILE_MOBILE_UPLOAD_BASE_URL"),
            report_base_url=os.environ.get("STOCKPILE_REPORT_BASE_URL"),
            session_ttl_hours=_env_int("STOCKPILE_MOBILE_SESSION_TTL_HOURS", 6),
            upload_ttl_minutes=_env_int("STOCKPILE_MOBILE_UPLOAD_TTL_MINUTES", 30),
        )

    def create_capture_session(self, request: CaptureSessionCreateRequest) -> CaptureSession:
        created_at = utc_now()
        session = CaptureSession(
            session_id=_new_id("session"),
            site_id=request.site_id,
            pile_name=request.pile_name,
            material_code=request.material_code,
            density_kg_per_m3=request.density_kg_per_m3,
            reference_count_goal=request.reference_count_goal,
            created_at=created_at,
            expires_at=created_at + timedelta(hours=self.session_ttl_hours),
            tagged_reference_strategy=request.tagged_reference_strategy,
            capture_metadata=request.capture_metadata,
            quality_input=request.quality_input,
            client_build=request.client_build,
            updated_at=created_at,
        )
        _write_json(self._session_path(session.session_id), session.to_dict())
        return session

    def create_upload_authorization(self, request: UploadRequest) -> UploadAuthorization:
        session = self._load_session(request.session_id)
        self._validate_upload_request(session, request)
        request = self._enrich_upload_request_with_reference_evidence(request)

        created_at = utc_now()
        upload_id = _new_id("upload")
        job_id = _new_id("job")
        run_id = _new_id("run")
        file_name = _sanitize_filename(request.file_name)
        storage_path = self.objects_dir / upload_id / file_name
        authorization = UploadAuthorization(
            upload_id=upload_id,
            session_id=request.session_id,
            job_id=job_id,
            run_id=run_id,
            upload_url=f"{self.upload_base_url}/{upload_id}/content",
            http_method="PUT",
            headers={"Content-Type": request.content_type},
            expires_at=created_at + timedelta(minutes=self.upload_ttl_minutes),
        )

        upload_record = {
            "uploadId": upload_id,
            "jobId": job_id,
            "runId": run_id,
            "sessionId": request.session_id,
            "request": request.to_dict(),
            "authorization": authorization.to_dict(),
            "storagePath": str(storage_path),
            "uploadState": UploadState.AUTHORIZED.value,
            "bytesReceived": 0,
            "createdAt": isoformat_utc(created_at),
            "updatedAt": isoformat_utc(created_at),
        }
        _write_json(self._upload_path(upload_id), upload_record)

        quality_gate = self._quality_gate_from_capture_input(
            request.quality_input or session.quality_input
        )
        provisional_measurement = self._provisional_measurement_from_mobile_first_request(
            session=session,
            request=request,
            updated_at=created_at,
        )
        status = ProcessingJobStatus(
            job_id=job_id,
            run_id=run_id,
            phase=JobPhase.UPLOAD_AUTHORIZED,
            progress=0.02,
            headline="Upload authorized",
            detail=f"Ready to upload {request.file_name}.",
            updated_at=created_at,
            upload=UploadProgressPayload(
                state=UploadState.AUTHORIZED,
                bytes_received=0,
                bytes_expected=request.byte_count,
            ),
            processing=ProcessingStatePayload(
                phase=JobPhase.UPLOAD_AUTHORIZED,
                progress=0.02,
                headline="Waiting for upload",
                detail="The backend has issued an upload target and is waiting for the recorded movie.",
            ),
            quality_gate=quality_gate,
            provisional_measurement=provisional_measurement,
        )
        job_record = {
            "jobId": job_id,
            "runId": run_id,
            "sessionId": request.session_id,
            "uploadId": upload_id,
            "status": status.to_dict(),
            "resultId": None,
            "createdAt": isoformat_utc(created_at),
            "updatedAt": isoformat_utc(created_at),
        }
        _write_json(self._job_path(job_id), job_record)
        self._touch_session(
            request.session_id,
            updated_at=created_at,
            latest_upload_id=upload_id,
            latest_job_id=job_id,
            latest_run_id=run_id,
        )
        return authorization

    def save_upload_bytes(
        self,
        upload_id: str,
        payload: bytes,
        *,
        finalize: bool = True,
    ) -> UploadArtifact:
        upload_record = self._load_upload_record(upload_id)
        storage_path = Path(str(upload_record["storagePath"]))
        storage_path.parent.mkdir(parents=True, exist_ok=True)
        storage_path.write_bytes(payload)

        bytes_received = len(payload)
        self._persist_upload_progress(
            upload_record,
            bytes_received=bytes_received,
            state=UploadState.COMPLETE if finalize else UploadState.RECEIVING,
        )
        if finalize:
            self.finalize_upload(upload_id, bytes_received=bytes_received)

        return UploadArtifact(upload_id=upload_id, storage_path=storage_path, byte_count=bytes_received)

    def receive_upload_bytes(self, upload_id: str, payload: bytes) -> ProcessingJobStatus:
        self.save_upload_bytes(upload_id, payload, finalize=True)
        upload_record = self._load_upload_record(upload_id)
        return self.fetch_processing_job(str(upload_record["jobId"]))

    def save_upload_file(
        self,
        upload_id: str,
        source_path: str | Path,
        *,
        finalize: bool = True,
    ) -> UploadArtifact:
        upload_record = self._load_upload_record(upload_id)
        source = Path(source_path)
        if not source.exists():
            raise MobileAPIValidationError(f"Upload source file does not exist: {source}")

        storage_path = Path(str(upload_record["storagePath"]))
        storage_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, storage_path)

        bytes_received = storage_path.stat().st_size
        self._persist_upload_progress(
            upload_record,
            bytes_received=bytes_received,
            state=UploadState.COMPLETE if finalize else UploadState.RECEIVING,
        )
        if finalize:
            self.finalize_upload(upload_id, bytes_received=bytes_received)

        return UploadArtifact(upload_id=upload_id, storage_path=storage_path, byte_count=bytes_received)

    def receive_upload_file(self, upload_id: str, source_path: str | Path) -> ProcessingJobStatus:
        self.save_upload_file(upload_id, source_path, finalize=True)
        upload_record = self._load_upload_record(upload_id)
        return self.fetch_processing_job(str(upload_record["jobId"]))

    def mark_upload_received(
        self,
        upload_id: str,
        *,
        bytes_received: int | None = None,
        content_type: str | None = None,
    ) -> ProcessingJobStatus:
        return self.finalize_upload(
            upload_id,
            bytes_received=bytes_received,
            content_type=content_type,
        ).job_status

    def finalize_upload(
        self,
        upload_id: str,
        *,
        bytes_received: int | None = None,
        content_type: str | None = None,
    ) -> UploadFinalization:
        upload_record = self._load_upload_record(upload_id)
        storage_path = Path(str(upload_record["storagePath"]))
        request = self._upload_request_from_record(upload_record, persist_enriched=True)
        current_job_status = self.fetch_processing_job(str(upload_record["jobId"]))
        upload_state = UploadState(str(upload_record["uploadState"]))

        # Treat repeated success-path finalize calls as idempotent so mobile retries do not
        # churn timestamps or bounce a job back into upload-received once processing has started.
        if (
            upload_state is UploadState.COMPLETE
            and current_job_status.phase is not JobPhase.UPLOAD_AUTHORIZED
        ):
            return self._existing_upload_finalization(
                upload_record,
                request=request,
                job_status=current_job_status,
            )

        resolved_bytes = (
            int(bytes_received)
            if bytes_received is not None
            else (
                storage_path.stat().st_size
                if storage_path.exists()
                else int(upload_record.get("bytesReceived") or 0)
            )
        )
        resolved_content_type = _normalize_content_type(content_type) or _normalize_content_type(
            request.content_type,
        )

        receipt_id = str(upload_record.get("receiptId") or upload_id)
        checksum_sha256 = _sha256_file(storage_path) if storage_path.exists() and resolved_bytes > 0 else None
        accepted_at = utc_now()

        validation_errors: list[str] = []
        if not storage_path.exists():
            validation_errors.append(
                f"Upload target for {upload_id} is missing at {storage_path}; finalize the transfer again.",
            )
        elif resolved_bytes <= 0:
            validation_errors.append(
                f"Upload {upload_id} is empty; a recorded walkaround is required before processing can begin.",
            )
        if resolved_bytes != request.byte_count:
            validation_errors.append(
                f"Expected {request.byte_count} bytes but received {resolved_bytes}.",
            )

        expected_content_type = _normalize_content_type(request.content_type)
        if expected_content_type and resolved_content_type != expected_content_type:
            validation_errors.append(
                f"Expected content type {expected_content_type} but received {resolved_content_type or 'unknown'}.",
            )

        expected_checksum = _normalize_checksum(request.checksum_sha256)
        if expected_checksum and checksum_sha256 != expected_checksum:
            validation_errors.append(
                "The uploaded file checksum did not match the authorization request.",
            )

        if validation_errors:
            detail = "Upload verification failed. " + " ".join(validation_errors)
            self._persist_upload_progress(
                upload_record,
                bytes_received=resolved_bytes,
                state=UploadState.FAILED,
            )
            upload_record["contentTypeReceived"] = resolved_content_type
            upload_record["checksumSha256Received"] = checksum_sha256
            upload_record["receiptId"] = receipt_id
            upload_record["acceptedAt"] = isoformat_utc(accepted_at)
            _write_json(self._upload_path(str(upload_record["uploadId"])), upload_record)
            self.fail_job(str(upload_record["jobId"]), detail)
            raise MobileAPIValidationError(detail)

        self._persist_upload_progress(
            upload_record,
            bytes_received=resolved_bytes,
            state=UploadState.COMPLETE,
        )
        upload_record["contentTypeReceived"] = resolved_content_type
        upload_record["checksumSha256Received"] = checksum_sha256
        upload_record["receiptId"] = receipt_id
        upload_record["acceptedAt"] = isoformat_utc(accepted_at)
        _write_json(self._upload_path(str(upload_record["uploadId"])), upload_record)

        job_status = self._update_job_from_upload(upload_record, phase=JobPhase.UPLOAD_RECEIVED)
        receipt = UploadReceipt(
            receipt_id=receipt_id,
            upload_id=str(upload_record["uploadId"]),
            job_id=str(upload_record["jobId"]),
            run_id=str(upload_record["runId"]),
            phase=job_status.phase,
            bytes_received=resolved_bytes,
            content_type=resolved_content_type or request.content_type,
            checksum_sha256=checksum_sha256,
            accepted_at=accepted_at,
        )
        return UploadFinalization(receipt=receipt, job_status=job_status)

    def update_job_processing(
        self,
        job_id: str,
        *,
        phase: JobPhase,
        progress: float,
        headline: str,
        detail: str,
        quality_gate: QualityGatePayload | None = None,
    ) -> ProcessingJobStatus:
        job_record = self._load_job_record(job_id)
        upload_record = self._load_upload_record(str(job_record["uploadId"]))
        current_status = self._status_from_record(job_record)
        status = ProcessingJobStatus(
            job_id=str(job_record["jobId"]),
            run_id=str(job_record["runId"]),
            phase=phase,
            progress=max(0.0, min(1.0, float(progress))),
            headline=headline,
            detail=detail,
            updated_at=utc_now(),
            upload=self._upload_progress_from_record(upload_record),
            processing=ProcessingStatePayload(
                phase=phase,
                progress=max(0.0, min(1.0, float(progress))),
                headline=headline,
                detail=detail,
            ),
            quality_gate=quality_gate or current_status.quality_gate,
            provisional_measurement=current_status.provisional_measurement,
        )
        self._persist_job_status(job_record, status)
        return status

    def fail_job(self, job_id: str, detail: str) -> ProcessingJobStatus:
        return self.update_job_processing(
            job_id,
            phase=JobPhase.FAILED,
            progress=1.0,
            headline="Processing failed",
            detail=detail,
            quality_gate=QualityGatePayload(
                state=QualityGateState.BLOCK,
                primary_reason=detail,
            ),
        )

    def store_result(self, job_id: str, result: ResultPayload) -> ResultPayload:
        job_record = self._load_job_record(job_id)
        expected_run_id = str(job_record["runId"])
        if result.run_id != expected_run_id:
            raise MobileAPIValidationError(
                f"Result run_id {result.run_id} does not match job run_id {expected_run_id}",
            )
        session = self._load_session(str(job_record["sessionId"]))
        upload_record = self._load_upload_record(str(job_record["uploadId"]))
        upload_request = self._upload_request_from_record(upload_record, persist_enriched=True)
        current_status = self._status_from_record(job_record)

        phase = {
            RunOutcome.VERIFIED: JobPhase.VERIFIED,
            RunOutcome.REVIEW_ONLY: JobPhase.REVIEW_ONLY,
            RunOutcome.BLOCKED: JobPhase.BLOCKED,
        }[result.outcome]
        terminal_updated_at = utc_now()
        terminal_status = ProcessingJobStatus(
            job_id=str(job_record["jobId"]),
            run_id=result.run_id,
            phase=phase,
            progress=1.0,
            headline=self._terminal_headline(result.outcome),
            detail=result.recommended_action,
            updated_at=terminal_updated_at,
            upload=self._upload_progress_from_record(
                self._load_upload_record(str(job_record["uploadId"])),
            ),
            processing=ProcessingStatePayload(
                phase=phase,
                progress=1.0,
                headline=self._terminal_headline(result.outcome),
                detail=result.recommended_action,
            ),
            quality_gate=self._quality_gate_from_result(result),
        )
        terminal_provisional_measurement = result.provisional_measurement
        if terminal_provisional_measurement is None:
            terminal_provisional_measurement = current_status.provisional_measurement
        terminal_provisional_measurement = self._merge_provisional_mobile_intelligence(
            terminal_provisional_measurement,
            request=upload_request,
            session=session,
            fallback=current_status.provisional_measurement,
            updated_at=terminal_updated_at,
        )
        terminal_status = replace(
            terminal_status,
            provisional_measurement=terminal_provisional_measurement,
        )
        stored_result = replace(
            result,
            updated_at=terminal_updated_at,
            site_id=session.site_id,
            session_id=session.session_id,
            job_id=str(job_record["jobId"]),
            provisional_measurement=terminal_provisional_measurement,
        )
        _write_json(self._result_path(stored_result.run_id), stored_result.to_dict())
        job_record["resultId"] = stored_result.run_id
        self._persist_job_status(job_record, terminal_status)
        return stored_result

    def store_result_from_pipeline(
        self,
        job_id: str,
        pipeline_result: Any,
    ) -> ResultPayload:
        result = self._result_from_pipeline(job_id, pipeline_result)
        return self.store_result(job_id, result)

    def fetch_processing_job(self, job_id: str) -> ProcessingJobStatus:
        return self._status_from_record(self._load_job_record(job_id))

    def fetch_processing_job_for_run(
        self,
        run_id: str,
        *,
        site_id: str | None = None,
        session_id: str | None = None,
    ) -> ProcessingJobStatus:
        job_record = self._find_job_record_by_run_id(
            run_id,
            site_id=site_id,
            session_id=session_id,
        )
        return self._status_from_record(job_record)

    def fetch_result(
        self,
        run_id: str,
        *,
        site_id: str | None = None,
        session_id: str | None = None,
    ) -> ResultPayload:
        path = self._result_path(run_id)
        if not path.exists():
            raise ResultNotFoundError(f"Result {run_id} was not found")

        payload = ResultPayload.from_dict(_read_json(path))
        refreshed_payload = self._hydrate_result_payload(
            payload,
            fallback_updated_at=datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc),
        )
        if refreshed_payload != payload:
            _write_json(path, refreshed_payload.to_dict())

        if not self._result_matches_scope(
            refreshed_payload,
            site_id=site_id,
            session_id=session_id,
        ):
            raise ResultNotFoundError(f"Result {run_id} was not found")
        return refreshed_payload

    def list_recent_results(
        self,
        limit: int = 6,
        *,
        site_id: str | None = None,
        session_id: str | None = None,
    ) -> list[ResultPayload]:
        bounded_limit = max(0, int(limit))
        if bounded_limit == 0:
            return []

        results: list[tuple[datetime, ResultPayload]] = []
        for path in self.results_dir.glob("*.json"):
            payload = ResultPayload.from_dict(_read_json(path))
            refreshed_payload = self._hydrate_result_payload(
                payload,
                fallback_updated_at=datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc),
            )
            if not self._result_matches_scope(
                refreshed_payload,
                site_id=site_id,
                session_id=session_id,
            ):
                continue

            if refreshed_payload != payload:
                _write_json(path, refreshed_payload.to_dict())

            result_updated_at = refreshed_payload.updated_at or datetime.fromtimestamp(
                path.stat().st_mtime,
                tz=timezone.utc,
            )
            results.append((result_updated_at, refreshed_payload))

        results.sort(key=lambda item: item[0], reverse=True)
        return [payload for _, payload in results[:bounded_limit]]

    def fetch_capture_session(
        self,
        session_id: str,
        *,
        site_id: str | None = None,
    ) -> CaptureSession:
        session = self._hydrate_capture_session(self._load_session(session_id))
        if site_id is not None and _normalize_id(session.site_id) != _normalize_id(site_id):
            raise CaptureSessionNotFoundError(f"Capture session {session_id} was not found")
        return session

    def list_recent_capture_sessions(
        self,
        limit: int = 6,
        *,
        site_id: str | None = None,
        include_expired: bool = False,
    ) -> list[CaptureSession]:
        bounded_limit = max(0, int(limit))
        if bounded_limit == 0:
            return []

        requested_site_id = _normalize_id(site_id)
        sessions: list[tuple[datetime, CaptureSession]] = []
        for path in self.sessions_dir.glob("*.json"):
            payload = CaptureSession.from_dict(_read_json(path))
            refreshed_payload = self._hydrate_capture_session(payload)
            if refreshed_payload != payload:
                _write_json(path, refreshed_payload.to_dict())

            if (
                requested_site_id is not None
                and _normalize_id(refreshed_payload.site_id) != requested_site_id
            ):
                continue
            if not include_expired and refreshed_payload.expires_at < utc_now():
                continue

            session_updated_at = refreshed_payload.updated_at or refreshed_payload.created_at
            sessions.append((session_updated_at, refreshed_payload))

        sessions.sort(key=lambda item: item[0], reverse=True)
        return [payload for _, payload in sessions[:bounded_limit]]

    def fetch_upload_context(self, upload_id: str) -> UploadContext:
        upload_record = self._load_upload_record(upload_id)
        session = self._load_session(str(upload_record["sessionId"]))
        upload_request = self._upload_request_from_record(upload_record, persist_enriched=True)
        return UploadContext(
            upload_id=str(upload_record["uploadId"]),
            job_id=str(upload_record["jobId"]),
            run_id=str(upload_record["runId"]),
            session=session,
            upload_request=upload_request,
            storage_path=Path(str(upload_record["storagePath"])),
        )

    def fetch_job_context(self, job_id: str) -> UploadContext:
        job_record = self._load_job_record(job_id)
        return self.fetch_upload_context(str(job_record["uploadId"]))

    def get_upload_storage_path(self, upload_id: str) -> Path:
        upload_record = self._load_upload_record(upload_id)
        return Path(str(upload_record["storagePath"]))

    def list_restartable_job_ids(self) -> list[str]:
        job_ids: list[str] = []
        for path in sorted(self.jobs_dir.glob("*.json")):
            job_record = _read_json(path)
            status_payload = job_record.get("status")
            if not isinstance(status_payload, dict):
                continue

            try:
                status = ProcessingJobStatus.from_dict(status_payload)
            except Exception:
                continue
            if status.phase.is_terminal:
                continue

            upload_id = str(job_record.get("uploadId") or "").strip()
            if not upload_id:
                continue

            try:
                context = self.fetch_upload_context(upload_id)
            except (CaptureSessionNotFoundError, UploadNotFoundError, ValueError):
                continue

            if not context.storage_path.exists():
                continue

            byte_count = context.storage_path.stat().st_size
            if byte_count <= 0:
                continue

            job_ids.append(str(job_record["jobId"]))

        return job_ids

    def _validate_upload_request(self, session: CaptureSession, request: UploadRequest):
        if session.expires_at < utc_now():
            raise MobileAPIValidationError(
                f"Capture session {session.session_id} has expired and cannot authorize new uploads",
            )
        if (
            request.tagged_reference_strategy is not None
            and request.tagged_reference_strategy.reference_count_goal != session.reference_count_goal
        ):
            raise MobileAPIValidationError(
                "Upload request reference goal does not match the capture session reference goal",
            )
        if (
            request.capture_metadata is not None
            and request.capture_metadata.mode != session.capture_metadata.mode
        ):
            raise MobileAPIValidationError(
                "Upload request capture mode does not match the capture session mode",
            )

    def _upload_request_from_record(
        self,
        upload_record: dict[str, Any],
        *,
        persist_enriched: bool = False,
    ) -> UploadRequest:
        request = UploadRequest.from_dict(upload_record["request"])
        enriched_request = self._enrich_upload_request_with_reference_evidence(request)
        if persist_enriched and enriched_request != request:
            upload_record["request"] = enriched_request.to_dict()
            upload_record["updatedAt"] = isoformat_utc(utc_now())
            _write_json(self._upload_path(str(upload_record["uploadId"])), upload_record)
        return enriched_request

    def _enrich_upload_request_with_reference_evidence(
        self,
        request: UploadRequest,
    ) -> UploadRequest:
        if not request.reference_evidence_frames:
            return request

        existing_observations = list(request.reference_observations)
        existing_keys = {
            self._reference_observation_key(observation)
            for observation in existing_observations
        }

        derived_observations: list[ReferenceObservationPayload] = []
        for observation in self._reference_observations_from_evidence_frames(
            request.reference_evidence_frames,
        ):
            key = self._reference_observation_key(observation)
            if key in existing_keys:
                continue
            existing_keys.add(key)
            derived_observations.append(observation)

        if not derived_observations:
            return request

        return replace(
            request,
            reference_observations=tuple(existing_observations + derived_observations),
        )

    def _reference_observations_from_evidence_frames(
        self,
        frames: tuple[ReferenceEvidenceFramePayload, ...],
    ) -> tuple[ReferenceObservationPayload, ...]:
        try:
            from .config import TaggedReferenceConfig
            from .tagged_reference_detection import detect_tagged_references
        except Exception:
            return ()

        config = TaggedReferenceConfig(enabled=True)
        mapped: list[ReferenceObservationPayload] = []

        for frame in frames:
            image = self._decode_reference_evidence_frame_image(frame)
            if image is None:
                continue

            try:
                detections = detect_tagged_references(image, config)
            except Exception:
                continue

            for detection in detections:
                spec = config.spec_for_tag(detection.tag_id)
                family = spec.family if spec is not None else detection.family
                reference_id = (
                    spec.display_name
                    if spec is not None
                    else f"{detection.family}:{detection.tag_id}"
                )
                edge_length_px = float(detection.mean_edge_length_px)
                bbox = detection.bbox
                pixel_area_px = max(float(bbox[2]), 0.0) * max(float(bbox[3]), 0.0)
                confidence = self._reference_evidence_confidence(
                    edge_length_px=edge_length_px,
                    minimum_edge_px=config.min_tag_edge_px,
                )
                mapped.append(
                    ReferenceObservationPayload(
                        reference_id=reference_id,
                        family=family,
                        frame_time_sec=frame.time_offset_sec,
                        captured_at=frame.captured_at,
                        pose_sample_index=frame.pose_sample_index,
                        edge_length_px=edge_length_px,
                        frame_id=frame.frame_id,
                        pixel_area_px=pixel_area_px,
                        confidence=confidence,
                        state=(
                            ReferenceMarkerQuality.CONFIRMED
                            if confidence >= 0.75
                            else ReferenceMarkerQuality.WEAK
                        ),
                    ),
                )

        return tuple(mapped)

    def _decode_reference_evidence_frame_image(
        self,
        frame: ReferenceEvidenceFramePayload,
    ):
        try:
            raw_bytes = base64.b64decode(frame.jpeg_base64, validate=True)
        except (binascii.Error, ValueError):
            return None

        if not raw_bytes:
            return None

        try:
            import cv2
            import numpy as np
        except Exception:
            return None

        buffer = np.frombuffer(raw_bytes, dtype=np.uint8)
        if buffer.size == 0:
            return None

        return cv2.imdecode(buffer, cv2.IMREAD_COLOR)

    def _reference_evidence_confidence(
        self,
        *,
        edge_length_px: float,
        minimum_edge_px: int,
    ) -> float:
        ratio = edge_length_px / max(float(minimum_edge_px) * 2.0, 1.0)
        return max(0.55, min(0.99, ratio))

    def _reference_observation_key(
        self,
        observation: ReferenceObservationPayload,
    ) -> tuple[str, str, str, int]:
        return (
            observation.reference_id.strip().lower(),
            observation.family.strip().lower(),
            str(observation.frame_id or "").strip().lower(),
            int(observation.pose_sample_index if observation.pose_sample_index is not None else -1),
        )

    def _mobile_first_capture_payload(
        self,
        *,
        request: UploadRequest,
        session: CaptureSession | None = None,
    ):
        quality_input = request.quality_input
        if quality_input is None and session is not None:
            quality_input = session.quality_input
        return None if quality_input is None else quality_input.mobile_first_capture

    def _native_reference_observations_from_request(
        self,
        request: UploadRequest,
        *,
        session: CaptureSession | None = None,
    ) -> tuple[ReferenceObservationPayload, ...]:
        mobile_first_capture = self._mobile_first_capture_payload(
            request=request,
            session=session,
        )
        if mobile_first_capture is None:
            return ()
        return tuple(mobile_first_capture.native_reference_observations)

    def _on_device_vision_from_request(
        self,
        request: UploadRequest,
        *,
        session: CaptureSession | None = None,
    ):
        mobile_first_capture = self._mobile_first_capture_payload(
            request=request,
            session=session,
        )
        if mobile_first_capture is None:
            return None
        return mobile_first_capture.on_device_vision

    def _on_device_vision_material_suggestion(
        self,
        request: UploadRequest,
        *,
        session: CaptureSession | None = None,
    ) -> MaterialSuggestionPayload | None:
        on_device_vision = self._on_device_vision_from_request(
            request=request,
            session=session,
        )
        if on_device_vision is None:
            return None
        if (
            on_device_vision.material_family_code is None
            and on_device_vision.material_family_label is None
        ):
            return None
        return MaterialSuggestionPayload(
            material_code=on_device_vision.material_family_code,
            label=on_device_vision.material_family_label,
            confidence=on_device_vision.material_confidence_score,
            source=on_device_vision.source,
        )

    def _on_device_vision_segmentation_confidence(
        self,
        request: UploadRequest,
        *,
        session: CaptureSession | None = None,
    ) -> float | None:
        on_device_vision = self._on_device_vision_from_request(
            request=request,
            session=session,
        )
        if on_device_vision is None:
            return None
        if on_device_vision.segmentation_confidence_score is not None:
            return float(on_device_vision.segmentation_confidence_score)
        if on_device_vision.pile_segmentation_score is not None:
            return float(on_device_vision.pile_segmentation_score)
        return None

    def _on_device_vision_toe_score(
        self,
        request: UploadRequest,
        *,
        session: CaptureSession | None = None,
    ) -> float | None:
        on_device_vision = self._on_device_vision_from_request(
            request=request,
            session=session,
        )
        if on_device_vision is None:
            return None
        if on_device_vision.toe_segmentation_score is not None:
            return float(on_device_vision.toe_segmentation_score)
        return None

    def _effective_reference_observations_for_provisional(
        self,
        request: UploadRequest,
        *,
        session: CaptureSession | None = None,
    ) -> tuple[ReferenceObservationPayload, ...]:
        if request.reference_observations:
            return request.reference_observations
        return self._native_reference_observations_from_request(
            request,
            session=session,
        )

    def _material_suggestion_from_request(
        self,
        request: UploadRequest,
        *,
        session: CaptureSession | None = None,
    ) -> MaterialSuggestionPayload | None:
        mobile_first_capture = self._mobile_first_capture_payload(
            request=request,
            session=session,
        )
        if mobile_first_capture is None:
            return None
        return mobile_first_capture.material_suggestion or self._on_device_vision_material_suggestion(
            request,
            session=session,
        )

    def _quick_segmentation_intelligence_from_request(
        self,
        request: UploadRequest,
        *,
        session: CaptureSession | None = None,
    ) -> dict[str, float | int | None]:
        mobile_first_capture = self._mobile_first_capture_payload(
            request=request,
            session=session,
        )
        if mobile_first_capture is None:
            return {}
        return {
            "quick_volume_m3": mobile_first_capture.quick_volume_m3,
            "quick_footprint_area_m2": mobile_first_capture.quick_footprint_area_m2,
            "quick_peak_height_m": mobile_first_capture.quick_peak_height_m,
            "quick_confidence_score": mobile_first_capture.quick_confidence_score,
            "quick_geometry_point_count": mobile_first_capture.quick_geometry_point_count,
            "quick_camera_path_distance_m": mobile_first_capture.quick_camera_path_distance_m,
        }

    def _merge_provisional_mobile_intelligence(
        self,
        provisional_measurement: ProvisionalMeasurementPayload | None,
        *,
        request: UploadRequest | None = None,
        session: CaptureSession | None = None,
        fallback: ProvisionalMeasurementPayload | None = None,
        updated_at: datetime | None = None,
    ) -> ProvisionalMeasurementPayload | None:
        resolved = provisional_measurement or fallback
        if resolved is None:
            return None

        native_reference_observations = tuple(resolved.native_reference_observations)
        if not native_reference_observations and fallback is not None:
            native_reference_observations = tuple(fallback.native_reference_observations)
        if not native_reference_observations and request is not None:
            native_reference_observations = self._native_reference_observations_from_request(
                request,
                session=session,
            )

        material_suggestion = resolved.material_suggestion
        if material_suggestion is None and fallback is not None:
            material_suggestion = fallback.material_suggestion
        if material_suggestion is None and request is not None:
            material_suggestion = self._material_suggestion_from_request(
                request,
                session=session,
            )

        request_quick_intelligence = (
            self._quick_segmentation_intelligence_from_request(
                request,
                session=session,
            )
            if request is not None
            else {}
        )
        merged_quick_intelligence: dict[str, float | int | None] = {}
        for field_name in (
            "quick_volume_m3",
            "quick_footprint_area_m2",
            "quick_peak_height_m",
            "quick_confidence_score",
            "quick_geometry_point_count",
            "quick_camera_path_distance_m",
        ):
            value = getattr(resolved, field_name)
            if value is None and fallback is not None:
                value = getattr(fallback, field_name)
            if value is None:
                value = request_quick_intelligence.get(field_name)
            merged_quick_intelligence[field_name] = value

        return replace(
            resolved,
            native_reference_observations=native_reference_observations,
            material_suggestion=material_suggestion,
            updated_at=updated_at if updated_at is not None else resolved.updated_at,
            **merged_quick_intelligence,
        )

    def _terminal_headline(self, outcome: RunOutcome) -> str:
        return {
            RunOutcome.VERIFIED: "Processing verified",
            RunOutcome.REVIEW_ONLY: "Processing complete with review required",
            RunOutcome.BLOCKED: "Processing blocked",
        }[outcome]

    def _quality_gate_from_capture_input(
        self,
        quality_input: CaptureQualityInputPayload,
    ) -> QualityGatePayload:
        scores = {
            "Reference visibility": quality_input.reference_visibility_score,
            "Perimeter coverage": quality_input.coverage_score,
            "Motion stability": quality_input.motion_stability_score,
            "Overall guidance": quality_input.overall_guidance_score,
        }
        low_block = [label for label, score in scores.items() if score is not None and score < 0.35]
        low_watch = [label for label, score in scores.items() if score is not None and score < 0.65]

        if low_block:
            state = QualityGateState.BLOCK
            reason = f"{low_block[0]} is still below the live-capture minimum."
        elif low_watch:
            state = QualityGateState.WATCH
            reason = f"{low_watch[0]} is soft-failing and should be reviewed during processing."
        else:
            state = QualityGateState.PASS
            reason = None

        return QualityGatePayload(
            state=state,
            reference_visibility_score=quality_input.reference_visibility_score,
            perimeter_coverage_score=quality_input.coverage_score,
            motion_stability_score=quality_input.motion_stability_score,
            overall_guidance_score=quality_input.overall_guidance_score,
            primary_reason=reason,
        )

    def _provisional_measurement_from_mobile_first_request(
        self,
        *,
        session: CaptureSession,
        request: UploadRequest,
        updated_at: datetime,
    ) -> ProvisionalMeasurementPayload | None:
        quality_input = request.quality_input or session.quality_input
        if quality_input is None:
            return None

        mobile_first_capture = quality_input.mobile_first_capture
        capture = self._mobile_first_capture_envelope(session, request)
        observed_reference_count = len({observation.marker_id for observation in capture.reference_observations})
        estimated_reference_count = (
            mobile_first_capture.estimated_concurrent_reference_count
            if mobile_first_capture is not None
            else None
        )
        recovered_reference_count = max(
            observed_reference_count,
            int(estimated_reference_count or 0),
        )
        reference_goal = max(session.reference_count_goal, 1)
        recovery_ratio = min(1.0, recovered_reference_count / float(reference_goal))

        toe_confidence_score = (
            mobile_first_capture.toe_coverage_score
            if mobile_first_capture is not None and mobile_first_capture.toe_coverage_score is not None
            else (
                quality_input.toe_coverage_score
                if quality_input.toe_coverage_score is not None
                else capture.toe_coverage_score
            )
        )
        geometry_confidence_score = (
            quality_input.reference_visibility_score
            if quality_input.reference_visibility_score is not None
            else (
                quality_input.overall_guidance_score
                if quality_input.overall_guidance_score is not None
                else (
                    quality_input.coverage_score
                    if quality_input.coverage_score is not None
                    else 0.0
                )
            )
        )
        if mobile_first_capture is not None and mobile_first_capture.quick_confidence_score is not None:
            geometry_confidence_score = max(
                geometry_confidence_score,
                float(mobile_first_capture.quick_confidence_score),
            )
        elif mobile_first_capture is not None and mobile_first_capture.segmentation_confidence_score is not None:
            geometry_confidence_score = max(
                geometry_confidence_score,
                float(mobile_first_capture.segmentation_confidence_score),
            )
        else:
            on_device_segmentation_confidence = self._on_device_vision_segmentation_confidence(
                request,
                session=session,
            )
            if on_device_segmentation_confidence is not None:
                geometry_confidence_score = max(
                    geometry_confidence_score,
                    on_device_segmentation_confidence,
                )

        provisional = evaluate_provisional_measurement(
            ProvisionalMeasurementInput(
                capture=capture,
                quick_volume_m3=(
                    None
                    if mobile_first_capture is None
                    else mobile_first_capture.quick_volume_m3
                ),
                tagged_reference_recovery_ratio=recovery_ratio,
                scale_agreement_ratio=None,
                toe_confidence_score=toe_confidence_score,
                geometry_confidence_score=geometry_confidence_score,
            )
        )
        return self._provisional_measurement_payload_from_output(
            provisional,
            density_kg_per_m3=session.density_kg_per_m3,
            basis="mobile_first_capture",
            **self._quick_segmentation_intelligence_from_request(
                request,
                session=session,
            ),
            native_reference_observations=self._native_reference_observations_from_request(
                request,
                session=session,
            ),
            material_suggestion=self._material_suggestion_from_request(
                request,
                session=session,
            ),
            updated_at=updated_at,
        )

    def _provisional_measurement_payload_from_output(
        self,
        output: Any,
        *,
        density_kg_per_m3: int | None = None,
        basis: str | None = None,
        quick_volume_m3: float | None = None,
        quick_footprint_area_m2: float | None = None,
        quick_peak_height_m: float | None = None,
        quick_confidence_score: float | None = None,
        quick_geometry_point_count: int | None = None,
        quick_camera_path_distance_m: float | None = None,
        native_reference_observations: tuple[ReferenceObservationPayload, ...] = (),
        material_suggestion: MaterialSuggestionPayload | None = None,
        updated_at: datetime | None = None,
    ) -> ProvisionalMeasurementPayload:
        provisional_payload_cls = globals().get("ProvisionalMeasurementPayload")
        if provisional_payload_cls is None:
            from .mobile_api_models import ProvisionalMeasurementPayload as provisional_payload_cls

        volume_m3 = getattr(output, "provisional_volume_m3", None)
        weight_tonnes = (
            float(volume_m3) * float(density_kg_per_m3) / 1000.0
            if volume_m3 is not None and density_kg_per_m3 is not None
            else None
        )
        reasons = tuple(
            str(reason).strip()
            for reason in getattr(output, "reasons", ())
            if str(reason).strip()
        )
        reason = str(getattr(output, "operator_action", "") or "").strip() or (
            "; ".join(reasons) if reasons else None
        )
        return provisional_payload_cls(
            status=str(getattr(output, "state").value),
            basis=basis,
            volume_m3=volume_m3,
            weight_tonnes=weight_tonnes,
            confidence_score=int(round(float(getattr(output, "confidence_score", 0.0)) * 100)),
            reason=reason,
            quick_volume_m3=quick_volume_m3,
            quick_footprint_area_m2=quick_footprint_area_m2,
            quick_peak_height_m=quick_peak_height_m,
            quick_confidence_score=quick_confidence_score,
            quick_geometry_point_count=quick_geometry_point_count,
            quick_camera_path_distance_m=quick_camera_path_distance_m,
            native_reference_observations=tuple(native_reference_observations),
            material_suggestion=material_suggestion,
            updated_at=updated_at,
        )

    def _quality_gate_from_result(self, result: ResultPayload) -> QualityGatePayload:
        if result.blockers:
            state = QualityGateState.BLOCK
            reason = result.blockers[0]
        elif result.warnings:
            state = QualityGateState.WATCH
            reason = result.warnings[0]
        else:
            state = QualityGateState.PASS
            reason = None

        capture_quality = result.capture_quality
        return QualityGatePayload(
            state=state,
            reference_visibility_score=(
                capture_quality.reference_visibility_score if capture_quality else None
            ),
            perimeter_coverage_score=(
                capture_quality.perimeter_coverage_score if capture_quality else None
            ),
            motion_stability_score=(
                capture_quality.motion_stability_score if capture_quality else None
            ),
            overall_guidance_score=(
                capture_quality.overall_guidance_score if capture_quality else None
            ),
            primary_reason=reason,
        )

    def _result_from_pipeline(self, job_id: str, pipeline_result: Any) -> ResultPayload:
        job_record = self._load_job_record(job_id)
        session = self._load_session(str(job_record["sessionId"]))
        upload_record = self._load_upload_record(str(job_record["uploadId"]))
        upload_request = self._upload_request_from_record(upload_record, persist_enriched=True)
        warnings = _dedupe_messages(getattr(pipeline_result, "quality_warnings", None))
        blockers = _dedupe_messages(getattr(pipeline_result, "quality_blockers", None))
        if getattr(pipeline_result, "error", None) and not blockers:
            blockers.append(str(getattr(pipeline_result, "error")))

        publishable = bool(getattr(pipeline_result, "publishable", False))
        review_grade = bool(getattr(pipeline_result, "review_grade", False))
        if blockers or not publishable:
            outcome = RunOutcome.BLOCKED
        elif review_grade or warnings:
            outcome = RunOutcome.REVIEW_ONLY
        else:
            outcome = RunOutcome.VERIFIED

        calibration = getattr(pipeline_result, "calibration", None)
        volume = getattr(pipeline_result, "volume", None)
        measurement = None
        if outcome is not RunOutcome.BLOCKED and volume is not None:
            measurement = MeasurementPayload(
                volume_m3=float(getattr(volume, "recommended_m3", 0.0) or 0.0),
                weight_tonnes=float(getattr(pipeline_result, "weight_kg", 0.0) or 0.0) / 1000.0,
                density_kg_per_m3=session.density_kg_per_m3,
            )

        calibration = getattr(pipeline_result, "calibration", None)
        mobile_provisional, mobile_review = self._evaluate_mobile_first_review(
            session=session,
            upload_request=upload_request,
            calibration=calibration,
            measurement=measurement,
        )
        if mobile_review is not None:
            if mobile_review.outcome is VerificationOutcome.RECAPTURE_REQUIRED:
                outcome = RunOutcome.BLOCKED
                blockers = _dedupe_messages([*blockers, *mobile_review.reasons])
            elif mobile_review.outcome is VerificationOutcome.REVIEW_ONLY and outcome is not RunOutcome.BLOCKED:
                outcome = RunOutcome.REVIEW_ONLY
                warnings = _dedupe_messages([*warnings, *mobile_review.reasons])

        confidence = self._confidence_from_pipeline(outcome, calibration, warnings, blockers)
        if mobile_provisional is not None:
            confidence = replace(
                confidence,
                score=min(confidence.score, int(round(mobile_provisional.confidence_score * 100))),
                summary=(
                    mobile_review.summary
                    if mobile_review is not None and mobile_review.summary
                    else confidence.summary
                ),
            )
        recommended_action = self._recommended_action(outcome, warnings, blockers)
        if mobile_provisional is not None and mobile_provisional.operator_action:
            recommended_action = mobile_provisional.operator_action
        provisional_measurement = (
            self._provisional_measurement_payload_from_output(
                mobile_provisional,
                density_kg_per_m3=session.density_kg_per_m3,
                basis="mobile_first_review",
                **self._quick_segmentation_intelligence_from_request(
                    upload_request,
                    session=session,
                ),
                native_reference_observations=self._native_reference_observations_from_request(
                    upload_request,
                    session=session,
                ),
                material_suggestion=self._material_suggestion_from_request(
                    upload_request,
                    session=session,
                ),
            )
            if mobile_provisional is not None
            else None
        )
        capture_quality = CaptureQualityPayload(
            reference_visibility_score=session.quality_input.reference_visibility_score,
            perimeter_coverage_score=session.quality_input.coverage_score,
            motion_stability_score=session.quality_input.motion_stability_score,
            overall_guidance_score=session.quality_input.overall_guidance_score,
        )
        observation_summary = self._reference_observation_summary(
            self._effective_reference_observations_for_provisional(
                upload_request,
                session=session,
            ),
            calibration,
        )
        reference_diagnostics = ReferenceDiagnosticsPayload(
            target_count=session.tagged_reference_strategy.reference_count_goal,
            minimum_visible_together=session.tagged_reference_strategy.minimum_visible_reference_count,
            preferred_visible_count=session.tagged_reference_strategy.preferred_visible_reference_count,
            frames_meeting_visibility_goal=(
                getattr(calibration, "frames_with_multiple_detections", None) if calibration else None
            ),
            frames_checked=(
                getattr(calibration, "registered_cone_frames", None)
                if calibration and getattr(calibration, "registered_cone_frames", None) is not None
                else getattr(calibration, "detected_cone_frames", None) if calibration else None
            ),
            calibration_basis=self._calibration_basis(
                calibration,
                upload_request=upload_request,
            ),
            calibration_status=self._calibration_status(outcome, calibration),
            reference_strategy=(
                str(getattr(pipeline_result, "reference_strategy", ""))
                or getattr(calibration, "reference_family", None)
                or "cones"
            ),
            references_used=(
                getattr(calibration, "num_references_used", None)
                if calibration else None
            ) or (
                getattr(calibration, "num_cones_used", None) if calibration else None
            ),
            observation_summary=observation_summary,
        )

        report_url = None
        if self.report_base_url:
            report_url = f"{self.report_base_url}/{job_record['runId']}"
        reconstruction = self._reconstruction_from_pipeline(pipeline_result, outcome=outcome)

        return ResultPayload(
            run_id=str(job_record["runId"]),
            pile_name=str(getattr(pipeline_result, "pile_name", "") or session.pile_name),
            outcome=outcome,
            confidence=confidence,
            measurement=measurement,
            warnings=warnings,
            blockers=blockers,
            recommended_action=recommended_action,
            capture_quality=capture_quality,
            reference_diagnostics=reference_diagnostics,
            report_url=report_url,
            provisional_measurement=provisional_measurement,
            reconstruction=reconstruction,
        )

    def _reconstruction_from_pipeline(
        self,
        pipeline_result: Any,
        *,
        outcome: RunOutcome,
    ) -> ReconstructionPayload | None:
        pile_cloud = getattr(pipeline_result, "pile_cloud", None)
        if pile_cloud is None:
            return None

        try:
            points = np.asarray(pile_cloud.points, dtype=float)
        except Exception:
            return None
        if points.ndim != 2 or points.shape[0] < 16:
            return None

        volume = getattr(pipeline_result, "volume", None)
        footprint_area_m2 = float(
            getattr(volume, "footprint_area_m2", None) or self._estimate_reconstruction_footprint_area(points)
        )
        peak_height_m = float(max(0.0, points[:, 2].max() - points[:, 2].min()))
        point_cloud = self._sample_reconstruction_points(points, max_count=320)
        vertices, triangles = self._build_reconstruction_mesh(pile_cloud)
        toe_markers = self._sample_toe_markers(
            points,
            toe_height_upper_m=getattr(volume, "toe_height_upper_m", None),
            max_count=20,
        )
        surface_risk_markers = self._sample_surface_risk_markers(points, max_count=12)

        if not point_cloud and not vertices:
            return None

        default_mode = "3d"
        if outcome is RunOutcome.REVIEW_ONLY:
            default_mode = "toe"
        elif outcome is RunOutcome.BLOCKED:
            default_mode = "surface"

        summary = (
            f"Preview mesh from {len(points):,} reconstructed pile points."
            if vertices
            else f"Point-cloud preview from {len(points):,} reconstructed pile points."
        )
        return ReconstructionPayload(
            summary=summary,
            footprint_area_m2=footprint_area_m2,
            peak_height_m=peak_height_m,
            default_mode=default_mode,
            vertices=vertices,
            triangles=triangles,
            point_cloud=point_cloud,
            toe_markers=toe_markers,
            surface_risk_markers=surface_risk_markers,
        )

    def _build_reconstruction_mesh(
        self,
        pile_cloud: Any,
    ) -> tuple[list[ReconstructionPointPayload], list[ReconstructionTrianglePayload]]:
        candidates = [pile_cloud]
        if hasattr(pile_cloud, "voxel_down_sample"):
            for voxel_size in (0.25, 0.4, 0.6, 0.9):
                try:
                    candidates.append(pile_cloud.voxel_down_sample(float(voxel_size)))
                except Exception:
                    continue

        for candidate in candidates:
            try:
                candidate_points = np.asarray(candidate.points)
            except Exception:
                continue
            if candidate_points.ndim != 2 or len(candidate_points) < 8:
                continue

            try:
                hull_mesh, _ = candidate.compute_convex_hull()
            except Exception:
                continue

            try:
                vertices = np.asarray(hull_mesh.vertices, dtype=float)
                triangles = np.asarray(hull_mesh.triangles, dtype=int)
            except Exception:
                continue

            if vertices.ndim != 2 or len(vertices) < 3 or triangles.ndim != 2 or len(triangles) < 1:
                continue

            if len(vertices) > 220:
                continue
            if len(triangles) > 480:
                continue

            return (
                [self._make_point_payload(point) for point in vertices],
                [
                    ReconstructionTrianglePayload(a=int(face[0]), b=int(face[1]), c=int(face[2]))
                    for face in triangles
                ],
            )

        return [], []

    def _sample_reconstruction_points(
        self,
        points: np.ndarray,
        *,
        max_count: int,
    ) -> list[ReconstructionPointPayload]:
        if points.ndim != 2 or len(points) == 0:
            return []
        count = min(int(max_count), len(points))
        indices = np.linspace(0, len(points) - 1, count, dtype=int)
        unique_indices = np.unique(indices)
        return [self._make_point_payload(points[index]) for index in unique_indices]

    def _sample_toe_markers(
        self,
        points: np.ndarray,
        *,
        toe_height_upper_m: float | None,
        max_count: int,
    ) -> list[ReconstructionPointPayload]:
        if points.ndim != 2 or len(points) < 8:
            return []

        z = points[:, 2]
        lower_band = float(toe_height_upper_m) if toe_height_upper_m is not None else float(np.quantile(z, 0.22))
        lower_band = max(lower_band, float(np.quantile(z, 0.15)))
        toe_candidates = points[z <= lower_band]
        if len(toe_candidates) < 8:
            toe_candidates = points[z <= float(np.quantile(z, 0.3))]
        return self._sample_sector_extrema(toe_candidates, max_count=max_count, prefer_high=False)

    def _sample_surface_risk_markers(
        self,
        points: np.ndarray,
        *,
        max_count: int,
    ) -> list[ReconstructionPointPayload]:
        if points.ndim != 2 or len(points) < 8:
            return []

        z = points[:, 2]
        high_candidates = points[z >= float(np.quantile(z, 0.9))]
        if len(high_candidates) < 6:
            high_candidates = points[z >= float(np.quantile(z, 0.82))]
        return self._sample_sector_extrema(high_candidates, max_count=max_count, prefer_high=True)

    def _sample_sector_extrema(
        self,
        points: np.ndarray,
        *,
        max_count: int,
        prefer_high: bool,
    ) -> list[ReconstructionPointPayload]:
        if points.ndim != 2 or len(points) == 0:
            return []

        center_xy = points[:, :2].mean(axis=0)
        rel_xy = points[:, :2] - center_xy
        angles = np.arctan2(rel_xy[:, 1], rel_xy[:, 0])
        radii = np.linalg.norm(rel_xy, axis=1)
        sector_edges = np.linspace(-np.pi, np.pi, max_count + 1)
        markers: list[ReconstructionPointPayload] = []
        for start, end in zip(sector_edges[:-1], sector_edges[1:]):
            mask = (angles >= start) & (angles < end)
            if not np.any(mask):
                continue
            sector = points[mask]
            sector_radii = radii[mask]
            if prefer_high:
                score = (sector[:, 2] * 1000.0) + sector_radii
            else:
                score = (sector_radii * 1000.0) - sector[:, 2]
            index = int(np.argmax(score))
            markers.append(self._make_point_payload(sector[index]))
        return markers

    def _estimate_reconstruction_footprint_area(self, points: np.ndarray) -> float:
        xy = points[:, :2]
        minimums = xy.min(axis=0)
        maximums = xy.max(axis=0)
        extents = np.maximum(maximums - minimums, 0.0)
        return float(extents[0] * extents[1])

    def _make_point_payload(self, point: Any) -> ReconstructionPointPayload:
        return ReconstructionPointPayload(
            x=float(point[0]),
            y=float(point[1]),
            z=float(point[2]),
        )

    def _evaluate_mobile_first_review(
        self,
        *,
        session: CaptureSession,
        upload_request: UploadRequest,
        calibration: Any,
        measurement: MeasurementPayload | None,
    ):
        capture = self._mobile_first_capture_envelope(session, upload_request)
        observed_reference_count = len({observation.marker_id for observation in capture.reference_observations})
        reference_goal = max(session.reference_count_goal, 1)
        calibration_reference_count = int(
            getattr(calibration, "num_references_used", None)
            or getattr(calibration, "num_cones_used", None)
            or 0
        )
        recovery_ratio = min(
            1.0,
            max(observed_reference_count, calibration_reference_count) / float(reference_goal),
        )
        geometry_confidence = float(getattr(calibration, "confidence", 0.0) or 0.0)
        scale_agreement_ratio = getattr(calibration, "scale_disagreement_ratio", None)
        provisional = evaluate_provisional_measurement(
            ProvisionalMeasurementInput(
                capture=capture,
                quick_volume_m3=None if measurement is None else measurement.volume_m3,
                tagged_reference_recovery_ratio=recovery_ratio,
                scale_agreement_ratio=scale_agreement_ratio,
                toe_confidence_score=capture.toe_coverage_score,
                geometry_confidence_score=geometry_confidence,
            )
        )
        review = evaluate_review_packet(
            ReviewPacket(
                provisional=provisional,
                tagged_reference_count=max(observed_reference_count, calibration_reference_count),
                minimum_expected_reference_count=max(
                    session.tagged_reference_strategy.minimum_visible_reference_count,
                    1,
                ),
                scale_agreement_ratio=scale_agreement_ratio,
            )
        )
        return provisional, review

    def _mobile_first_capture_envelope(
        self,
        session: CaptureSession,
        upload_request: UploadRequest,
    ) -> MobileFirstCaptureEnvelope:
        capture_metadata = upload_request.capture_metadata or session.capture_metadata
        quality_input = upload_request.quality_input or session.quality_input
        sensor_metadata = None if capture_metadata is None else capture_metadata.sensor_metadata
        mobile_first_capture = quality_input.mobile_first_capture
        on_device_toe_score = self._on_device_vision_toe_score(upload_request, session=session)

        return MobileFirstCaptureEnvelope(
            session_id=session.session_id,
            site_id=session.site_id,
            pile_name=session.pile_name,
            material_code=session.material_code,
            density_kg_per_m3=session.density_kg_per_m3,
            reference_count_goal=session.reference_count_goal,
            reference_observations=tuple(
                self._mobile_first_reference_observations(
                    self._effective_reference_observations_for_provisional(
                        upload_request,
                        session=session,
                    ),
                )
            ),
            device_pose_samples=tuple(self._mobile_first_device_pose_samples(upload_request.pose_samples)),
            toe_coverage_score=(
                mobile_first_capture.toe_coverage_score
                if mobile_first_capture is not None and mobile_first_capture.toe_coverage_score is not None
                else (
                    quality_input.toe_coverage_score
                    if quality_input.toe_coverage_score is not None
                    else (
                        on_device_toe_score
                        if on_device_toe_score is not None
                        else quality_input.coverage_score
                    )
                )
            ),
            motion_stability_score=quality_input.motion_stability_score,
            perimeter_coverage_score=quality_input.coverage_score,
            lidar_assist_enabled=bool(
                sensor_metadata.depth_data_included if sensor_metadata is not None else False
            ),
        )

    def _mobile_first_reference_observations(
        self,
        observations: tuple[ReferenceObservationPayload, ...],
    ) -> list[ReferenceObservation]:
        mapped: list[ReferenceObservation] = []
        for index, observation in enumerate(observations):
            mapped.append(
                ReferenceObservation(
                    marker_id=observation.reference_id,
                    frame_id=(
                        observation.frame_id
                        or (
                            f"sample-{observation.pose_sample_index}"
                            if observation.pose_sample_index is not None
                            else (
                                f"t-{observation.frame_time_sec:.3f}"
                                if observation.frame_time_sec is not None
                                else f"capture-{index}"
                            )
                        )
                    ),
                    pixel_area=float(observation.pixel_area_px or 0.0),
                    confidence=float(observation.confidence or 0.0),
                    estimated_distance_m=observation.estimated_distance_m,
                    state=self._mobile_first_reference_state(observation.state, observation.confidence),
                )
            )
        return mapped

    def _mobile_first_device_pose_samples(self, samples: tuple[Any, ...]) -> list[DevicePoseSample]:
        mapped: list[DevicePoseSample] = []
        for sample in samples:
            if sample.position_m is None or sample.yaw_pitch_roll_deg is None:
                continue
            mapped.append(
                DevicePoseSample(
                    timestamp_seconds=float(sample.time_offset_sec),
                    position_xyz_m=(
                        float(sample.position_m.x),
                        float(sample.position_m.y),
                        float(sample.position_m.z),
                    ),
                    yaw_pitch_roll_deg=(
                        float(sample.yaw_pitch_roll_deg.x),
                        float(sample.yaw_pitch_roll_deg.y),
                        float(sample.yaw_pitch_roll_deg.z),
                    ),
                    horizontal_accuracy_m=sample.horizontal_accuracy_m,
                    vertical_accuracy_m=sample.vertical_accuracy_m,
                )
            )
        return mapped

    def _mobile_first_reference_state(
        self,
        state: ReferenceMarkerQuality | None,
        confidence: float | None,
    ) -> ReferenceObservationState:
        if state is ReferenceMarkerQuality.CONFIRMED:
            return ReferenceObservationState.CONFIRMED
        if state is ReferenceMarkerQuality.MISSING:
            return ReferenceObservationState.MISSING
        if state is ReferenceMarkerQuality.WEAK:
            return ReferenceObservationState.WEAK
        if confidence is not None and confidence >= 0.75:
            return ReferenceObservationState.CONFIRMED
        return ReferenceObservationState.WEAK

    def _reference_observation_summary(
        self,
        observations: tuple[ReferenceObservationPayload, ...],
        calibration: Any,
    ) -> ReferenceObservationSummaryPayload | None:
        if not observations and calibration is None:
            return None

        observed_reference_ids = {
            observation.reference_id.strip()
            for observation in observations
            if observation.reference_id.strip()
        }
        frame_ids = [observation.frame_id for observation in observations if observation.frame_id]
        frames_with_observations = len(set(frame_ids)) if frame_ids else None
        max_visible_together = max(Counter(frame_ids).values()) if frame_ids else None

        return ReferenceObservationSummaryPayload(
            observed_reference_count=len(observed_reference_ids) if observations else None,
            frames_with_observations=frames_with_observations,
            max_visible_together=max_visible_together,
            used_for_calibration_count=(
                getattr(calibration, "num_references_used", None)
                if calibration is not None
                else None
            ),
        )

    def _confidence_from_pipeline(
        self,
        outcome: RunOutcome,
        calibration: Any,
        warnings: list[str],
        blockers: list[str],
    ) -> ConfidencePayload:
        base_ratio = float(getattr(calibration, "confidence", 0.0) or 0.0)
        score = int(round(max(0.0, min(1.0, base_ratio)) * 100))
        score -= min(len(warnings), 3) * 5
        score -= min(len(blockers), 3) * 15

        if outcome is RunOutcome.VERIFIED:
            score = max(score, 80)
            summary = "Processing completed and the run cleared the current release gates."
        elif outcome is RunOutcome.REVIEW_ONLY:
            score = min(max(score, 55), 79)
            summary = "Processing completed, but the run still needs benchmark review before release."
        else:
            score = min(score, 49)
            if blockers:
                summary = blockers[0]
            else:
                summary = "Processing did not clear the current release gates."

        if score >= 80:
            label = "High"
        elif score >= 60:
            label = "Moderate"
        elif score >= 40:
            label = "Low"
        else:
            label = "Very Low"

        return ConfidencePayload(score=score, label=label, summary=summary)

    def _recommended_action(
        self,
        outcome: RunOutcome,
        warnings: list[str],
        blockers: list[str],
    ) -> str:
        if outcome is RunOutcome.BLOCKED:
            if blockers:
                return (
                    "Recapture before release. "
                    f"Primary blocker: {blockers[0]}"
                )
            return "Recapture before release."
        if outcome is RunOutcome.REVIEW_ONLY:
            if warnings:
                return (
                    "Review against the latest site benchmark before release. "
                    f"Primary concern: {warnings[0]}"
                )
            return "Review against the latest site benchmark before release."
        return "Release as verified after the normal operator QA spot-check."

    def _calibration_basis(self, calibration: Any, *, upload_request: UploadRequest | None = None) -> str:
        if calibration is None:
            return "unavailable"
        family = str(getattr(calibration, "reference_family", "cone") or "cone")
        method = str(getattr(calibration, "selected_method", "projection") or "projection")
        basis = f"{family}_plus_camera_pose"
        if method == "camera_height":
            basis = f"{family}_plus_camera_height"
        if self._has_mobile_pose_provenance(calibration, upload_request=upload_request):
            return f"{basis}_plus_mobile_pose_provenance"
        return basis

    def _has_mobile_pose_provenance(self, calibration: Any, *, upload_request: UploadRequest | None = None) -> bool:
        if calibration is None:
            return False
        if (
            getattr(calibration, "mobile_pose_scale_factor", None) is not None
            or getattr(calibration, "mobile_pose_confidence", None) is not None
        ):
            return True

        for raw_note in getattr(calibration, "notes", ()) or ():
            note = str(raw_note).strip().lower()
            if not note:
                continue
            if "mobile pose" in note or "device pose" in note or "arkit pose anchor" in note:
                return True
        if upload_request is None:
            return False
        pose_by_index = {
            int(sample.sample_index): sample
            for sample in upload_request.pose_samples
            if sample.position_m is not None and sample.yaw_pitch_roll_deg is not None
        }
        for observation in upload_request.reference_observations:
            if observation.pose_sample_index is None:
                continue
            if int(observation.pose_sample_index) in pose_by_index:
                return True
        return False

    def _calibration_status(self, outcome: RunOutcome, calibration: Any) -> str:
        if calibration is None:
            return "missing"
        if outcome is RunOutcome.VERIFIED:
            return "verified"
        if outcome is RunOutcome.REVIEW_ONLY:
            return "needs_review"
        return "blocked"

    def _upload_progress_from_record(self, upload_record: dict[str, Any]) -> UploadProgressPayload:
        request = UploadRequest.from_dict(upload_record["request"])
        return UploadProgressPayload(
            state=UploadState(str(upload_record["uploadState"])),
            bytes_received=int(upload_record.get("bytesReceived") or 0),
            bytes_expected=request.byte_count,
        )

    def _existing_upload_finalization(
        self,
        upload_record: dict[str, Any],
        *,
        request: UploadRequest,
        job_status: ProcessingJobStatus,
    ) -> UploadFinalization:
        receipt = UploadReceipt(
            receipt_id=str(upload_record.get("receiptId") or upload_record["uploadId"]),
            upload_id=str(upload_record["uploadId"]),
            job_id=str(upload_record["jobId"]),
            run_id=str(upload_record["runId"]),
            phase=job_status.phase,
            bytes_received=int(upload_record.get("bytesReceived") or request.byte_count),
            content_type=str(upload_record.get("contentTypeReceived") or request.content_type),
            checksum_sha256=_normalize_checksum(upload_record.get("checksumSha256Received")),
            accepted_at=parse_datetime(str(upload_record.get("acceptedAt") or "")) or utc_now(),
        )
        return UploadFinalization(receipt=receipt, job_status=job_status)

    def _status_from_record(self, job_record: dict[str, Any]) -> ProcessingJobStatus:
        return ProcessingJobStatus.from_dict(job_record["status"])

    def _persist_upload_progress(
        self,
        upload_record: dict[str, Any],
        *,
        bytes_received: int,
        state: UploadState,
    ):
        upload_record["bytesReceived"] = max(0, int(bytes_received))
        upload_record["uploadState"] = state.value
        upload_record["updatedAt"] = isoformat_utc(utc_now())
        _write_json(self._upload_path(str(upload_record["uploadId"])), upload_record)

    def _update_job_from_upload(
        self,
        upload_record: dict[str, Any],
        *,
        phase: JobPhase,
    ) -> ProcessingJobStatus:
        job_record = self._load_job_record(str(upload_record["jobId"]))
        upload_progress = self._upload_progress_from_record(upload_record)
        current_status = self._status_from_record(job_record)
        status = ProcessingJobStatus(
            job_id=str(job_record["jobId"]),
            run_id=str(job_record["runId"]),
            phase=phase,
            progress=0.1,
            headline="Upload received",
            detail="The backend has received the recorded movie and queued processing.",
            updated_at=utc_now(),
            upload=upload_progress,
            processing=ProcessingStatePayload(
                phase=phase,
                progress=0.1,
                headline="Queued for processing",
                detail="Upload finalized. Waiting for frame extraction to begin.",
            ),
            quality_gate=current_status.quality_gate,
            provisional_measurement=current_status.provisional_measurement,
        )
        self._persist_job_status(job_record, status)
        return status

    def _persist_job_status(self, job_record: dict[str, Any], status: ProcessingJobStatus):
        job_record["status"] = status.to_dict()
        job_record["updatedAt"] = isoformat_utc(status.updated_at)
        _write_json(self._job_path(str(job_record["jobId"])), job_record)
        self._touch_session(
            str(job_record["sessionId"]),
            updated_at=status.updated_at,
            latest_upload_id=_normalize_id(job_record.get("uploadId")),
            latest_job_id=str(job_record["jobId"]),
            latest_run_id=str(job_record["runId"]),
        )

    def _load_session(self, session_id: str) -> CaptureSession:
        path = self._session_path(session_id)
        if not path.exists():
            raise CaptureSessionNotFoundError(f"Capture session {session_id} was not found")
        return CaptureSession.from_dict(_read_json(path))

    def _load_upload_record(self, upload_id: str) -> dict[str, Any]:
        path = self._upload_path(upload_id)
        if not path.exists():
            raise UploadNotFoundError(f"Upload {upload_id} was not found")
        return _read_json(path)

    def _load_job_record(self, job_id: str) -> dict[str, Any]:
        path = self._job_path(job_id)
        if not path.exists():
            raise ProcessingJobNotFoundError(f"Processing job {job_id} was not found")
        return _read_json(path)

    def _find_job_record_by_run_id(
        self,
        run_id: str,
        *,
        site_id: str | None = None,
        session_id: str | None = None,
    ) -> dict[str, Any]:
        normalized_run_id = str(run_id).strip()
        requested_site_id = _normalize_id(site_id)
        requested_session_id = _normalize_id(session_id)
        for path in sorted(self.jobs_dir.glob("*.json")):
            job_record = _read_json(path)
            if str(job_record.get("runId") or "").strip() == normalized_run_id:
                record_session_id = _normalize_id(job_record.get("sessionId"))
                if requested_session_id is not None and record_session_id != requested_session_id:
                    continue
                if requested_site_id is not None:
                    if record_session_id is None:
                        continue
                    try:
                        session = self._load_session(record_session_id)
                    except CaptureSessionNotFoundError:
                        continue
                    if _normalize_id(session.site_id) != requested_site_id:
                        continue
                return job_record
        raise ProcessingJobNotFoundError(f"Processing job for run {run_id} was not found")

    def _touch_session(
        self,
        session_id: str,
        *,
        updated_at: datetime,
        latest_upload_id: str | None = None,
        latest_job_id: str | None = None,
        latest_run_id: str | None = None,
    ) -> None:
        try:
            session = self._load_session(session_id)
        except CaptureSessionNotFoundError:
            return

        current_updated_at = session.updated_at or session.created_at
        resolved_updated_at = updated_at if updated_at >= current_updated_at else current_updated_at
        refreshed_session = replace(
            session,
            updated_at=resolved_updated_at,
            latest_upload_id=latest_upload_id or session.latest_upload_id,
            latest_job_id=latest_job_id or session.latest_job_id,
            latest_run_id=latest_run_id or session.latest_run_id,
        )
        if refreshed_session != session:
            _write_json(self._session_path(session.session_id), refreshed_session.to_dict())

    def _hydrate_capture_session(self, session: CaptureSession) -> CaptureSession:
        updated_at = session.updated_at or session.created_at
        return replace(session, updated_at=updated_at)

    def _hydrate_result_payload(
        self,
        payload: ResultPayload,
        *,
        fallback_updated_at: datetime | None = None,
    ) -> ResultPayload:
        updated_at = payload.updated_at
        site_id = _normalize_id(payload.site_id)
        session_id = _normalize_id(payload.session_id)
        job_id = _normalize_id(payload.job_id)
        session: CaptureSession | None = None
        upload_request: UploadRequest | None = None
        fallback_provisional_measurement: ProvisionalMeasurementPayload | None = None

        job_record: dict[str, Any] | None = None
        try:
            job_record = self._find_job_record_by_run_id(payload.run_id)
        except ProcessingJobNotFoundError:
            job_record = None

        if job_record is not None:
            job_updated_at = parse_datetime(str(job_record.get("updatedAt") or ""))
            if job_updated_at is not None and (updated_at is None or job_updated_at > updated_at):
                updated_at = job_updated_at

            job_id = str(job_record["jobId"])
            fallback_provisional_measurement = self._status_from_record(job_record).provisional_measurement
            session_id = _normalize_id(job_record.get("sessionId"))
            if session_id is not None:
                try:
                    session = self._load_session(session_id)
                except CaptureSessionNotFoundError:
                    session = None
                if session is not None:
                    site_id = session.site_id
                    if updated_at is None:
                        updated_at = session.updated_at or session.created_at
            upload_id = _normalize_id(job_record.get("uploadId"))
            if upload_id is not None:
                try:
                    upload_request = self._upload_request_from_record(
                        self._load_upload_record(upload_id),
                        persist_enriched=False,
                    )
                except UploadNotFoundError:
                    upload_request = None
        elif session_id is not None and site_id is None:
            try:
                session = self._load_session(session_id)
            except CaptureSessionNotFoundError:
                session = None
            if session is not None:
                site_id = session.site_id
                if updated_at is None:
                    updated_at = session.updated_at or session.created_at

        if updated_at is None:
            updated_at = fallback_updated_at or utc_now()

        provisional_measurement = self._merge_provisional_mobile_intelligence(
            payload.provisional_measurement,
            request=upload_request,
            session=session,
            fallback=fallback_provisional_measurement,
        )

        return replace(
            payload,
            provisional_measurement=provisional_measurement,
            updated_at=updated_at,
            site_id=site_id,
            session_id=session_id,
            job_id=job_id,
        )

    def _result_matches_scope(
        self,
        payload: ResultPayload,
        *,
        site_id: str | None = None,
        session_id: str | None = None,
    ) -> bool:
        requested_site_id = _normalize_id(site_id)
        requested_session_id = _normalize_id(session_id)
        if requested_site_id is not None and _normalize_id(payload.site_id) != requested_site_id:
            return False
        if (
            requested_session_id is not None
            and _normalize_id(payload.session_id) != requested_session_id
        ):
            return False
        return True

    def _session_path(self, session_id: str) -> Path:
        return self.sessions_dir / f"{session_id}.json"

    def _upload_path(self, upload_id: str) -> Path:
        return self.uploads_dir / f"{upload_id}.json"

    def _job_path(self, job_id: str) -> Path:
        return self.jobs_dir / f"{job_id}.json"

    def _result_path(self, run_id: str) -> Path:
        return self.results_dir / f"{run_id}.json"


__all__ = [
    "CaptureSessionNotFoundError",
    "MobileAPIServiceError",
    "MobileAPIValidationError",
    "ProcessingJobNotFoundError",
    "ResultNotFoundError",
    "StockpileMobileAPIService",
    "UploadArtifact",
    "UploadNotFoundError",
]
