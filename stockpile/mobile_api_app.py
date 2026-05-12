"""FastAPI app exposing the durable mobile capture backend."""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager
from functools import lru_cache
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Query, Request, Response, status
from fastapi.responses import JSONResponse

from .mobile_api_models import CaptureSessionCreateRequest, JobPhase, UploadRequest
from .mobile_api_service import (
    CaptureSessionNotFoundError,
    MobileAPIValidationError,
    ProcessingJobNotFoundError,
    ResultNotFoundError,
    StockpileMobileAPIService,
    UploadNotFoundError,
)
from .mobile_job_runtime import StockpileMobileJobRuntime

logger = logging.getLogger(__name__)


def create_app(
    *,
    service: StockpileMobileAPIService | None = None,
    runtime: StockpileMobileJobRuntime | None = None,
) -> FastAPI:
    resolved_service = service or get_mobile_api_service()
    if runtime is not None:
        resolved_runtime = runtime
    elif service is not None:
        resolved_runtime = StockpileMobileJobRuntime(resolved_service)
    else:
        resolved_runtime = get_mobile_job_runtime()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        _resume_pending_jobs_if_supported(resolved_runtime)
        yield

    app = FastAPI(
        title="Stockpile Mobile API",
        version="0.1.0",
        lifespan=lifespan,
    )

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/readyz")
    async def readyz() -> dict[str, str]:
        return {
            "status": "ok",
            "api": "ready",
            "service": "ready" if resolved_service is not None else "unavailable",
            "runtime": "ready" if resolved_runtime is not None else "unavailable",
        }

    @app.post("/api/mobile/capture-sessions", status_code=status.HTTP_201_CREATED)
    async def create_capture_session(
        request: Request,
        authorization: str | None = Header(default=None),
        x_api_key: str | None = Header(default=None),
    ) -> dict:
        _authorize_request(authorization, x_api_key)
        payload = await request.json()
        try:
            capture_request = CaptureSessionCreateRequest.from_dict(payload)
            session = resolved_service.create_capture_session(capture_request)
        except ValueError as exc:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)) from exc
        return session.to_dict()

    @app.get("/api/mobile/capture-sessions/recent")
    async def fetch_recent_capture_sessions(
        limit: int = 6,
        site_id: str | None = Query(default=None, alias="siteId"),
        include_expired: bool = Query(default=False, alias="includeExpired"),
        authorization: str | None = Header(default=None),
        x_api_key: str | None = Header(default=None),
    ) -> list[dict]:
        _authorize_request(authorization, x_api_key)
        bounded_limit = max(0, min(limit, 20))
        sessions = resolved_service.list_recent_capture_sessions(
            limit=bounded_limit,
            site_id=site_id,
            include_expired=include_expired,
        )
        return [session.to_dict() for session in sessions]

    @app.get("/api/mobile/capture-sessions/{session_id}")
    async def fetch_capture_session(
        session_id: str,
        site_id: str | None = Query(default=None, alias="siteId"),
        authorization: str | None = Header(default=None),
        x_api_key: str | None = Header(default=None),
    ) -> dict:
        _authorize_request(authorization, x_api_key)
        try:
            session = resolved_service.fetch_capture_session(session_id, site_id=site_id)
        except CaptureSessionNotFoundError as exc:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
        return session.to_dict()

    @app.post("/api/mobile/uploads", status_code=status.HTTP_201_CREATED)
    async def create_upload_authorization(
        request: Request,
        authorization: str | None = Header(default=None),
        x_api_key: str | None = Header(default=None),
    ) -> dict:
        _authorize_request(authorization, x_api_key)
        payload = await request.json()
        try:
            upload_request = UploadRequest.from_dict(payload)
            upload_authorization = resolved_service.create_upload_authorization(upload_request)
        except CaptureSessionNotFoundError as exc:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
        except (MobileAPIValidationError, ValueError) as exc:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)) from exc
        return upload_authorization.to_dict()

    @app.put("/api/mobile/uploads/{upload_id}/content", status_code=status.HTTP_202_ACCEPTED)
    async def upload_capture_content(
        upload_id: str,
        request: Request,
        response: Response,
        authorization: str | None = Header(default=None),
        x_api_key: str | None = Header(default=None),
    ) -> dict:
        _authorize_request(authorization, x_api_key)

        try:
            context = resolved_service.fetch_upload_context(upload_id)
            current_status = resolved_service.fetch_processing_job(context.job_id)
        except UploadNotFoundError as exc:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc

        bytes_received = await _write_request_body(request, context.storage_path)
        try:
            finalization = resolved_service.finalize_upload(
                upload_id,
                bytes_received=bytes_received,
                content_type=request.headers.get("content-type"),
            )
        except MobileAPIValidationError as exc:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)) from exc

        _apply_upload_receipt_headers(response, finalization.receipt)
        _start_processing_for_upload_if_needed(
            runtime=resolved_runtime,
            upload_id=upload_id,
            job_id=context.job_id,
            current_phase=current_status.phase,
        )

        return _upload_handoff_payload(finalization)

    @app.get("/api/mobile/jobs/{job_id}")
    async def fetch_processing_job(
        job_id: str,
        authorization: str | None = Header(default=None),
        x_api_key: str | None = Header(default=None),
    ) -> dict:
        _authorize_request(authorization, x_api_key)
        try:
            _ensure_processing_for_job_if_supported(resolved_runtime, job_id)
            status_payload = resolved_service.fetch_processing_job(job_id)
        except ProcessingJobNotFoundError as exc:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
        return status_payload.to_dict()

    @app.get("/api/mobile/results/{run_id}")
    async def fetch_result(
        run_id: str,
        site_id: str | None = Query(default=None, alias="siteId"),
        session_id: str | None = Query(default=None, alias="sessionId"),
        authorization: str | None = Header(default=None),
        x_api_key: str | None = Header(default=None),
    ) -> dict:
        _authorize_request(authorization, x_api_key)
        try:
            result = resolved_service.fetch_result(
                run_id,
                site_id=site_id,
                session_id=session_id,
            )
        except ResultNotFoundError as exc:
            try:
                pending_status = resolved_service.fetch_processing_job_for_run(
                    run_id,
                    site_id=site_id,
                    session_id=session_id,
                )
                _ensure_processing_for_job_if_supported(resolved_runtime, pending_status.job_id)
                pending_status = resolved_service.fetch_processing_job(pending_status.job_id)
            except ProcessingJobNotFoundError:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc

            response_payload, response_headers = _result_unavailable_payload(
                run_id=run_id,
                status_payload=pending_status.to_dict(),
            )
            return JSONResponse(
                status_code=status.HTTP_404_NOT_FOUND,
                content=response_payload,
                headers=response_headers,
            )
        return result.to_dict()

    @app.get("/api/mobile/runs/recent")
    async def fetch_recent_runs(
        limit: int = 6,
        site_id: str | None = Query(default=None, alias="siteId"),
        session_id: str | None = Query(default=None, alias="sessionId"),
        authorization: str | None = Header(default=None),
        x_api_key: str | None = Header(default=None),
    ) -> list[dict]:
        _authorize_request(authorization, x_api_key)
        bounded_limit = max(0, min(limit, 20))
        return [
            result.to_dict()
            for result in resolved_service.list_recent_results(
                limit=bounded_limit,
                site_id=site_id,
                session_id=session_id,
            )
        ]

    @app.post("/api/mobile/uploads/{upload_id}/finalize", status_code=status.HTTP_204_NO_CONTENT)
    async def finalize_upload(
        upload_id: str,
        authorization: str | None = Header(default=None),
        x_api_key: str | None = Header(default=None),
    ) -> Response:
        _authorize_request(authorization, x_api_key)
        try:
            context = resolved_service.fetch_upload_context(upload_id)
            current_status = resolved_service.fetch_processing_job(context.job_id)
        except UploadNotFoundError as exc:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc

        bytes_received = context.storage_path.stat().st_size if context.storage_path.exists() else 0
        try:
            finalization = resolved_service.finalize_upload(upload_id, bytes_received=bytes_received)
        except MobileAPIValidationError as exc:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)) from exc

        _start_processing_for_upload_if_needed(
            runtime=resolved_runtime,
            upload_id=upload_id,
            job_id=context.job_id,
            current_phase=current_status.phase,
        )
        response = Response(status_code=status.HTTP_204_NO_CONTENT)
        _apply_upload_receipt_headers(response, finalization.receipt)
        return response

    return app


async def _write_request_body(request: Request, destination: Path) -> int:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp_path = destination.with_suffix(f"{destination.suffix}.part")
    bytes_received = 0

    with temp_path.open("wb") as handle:
        async for chunk in request.stream():
            if not chunk:
                continue
            handle.write(chunk)
            bytes_received += len(chunk)

    temp_path.replace(destination)
    return bytes_received


def _authorize_request(authorization: str | None, x_api_key: str | None):
    expected_bearer = os.environ.get("STOCKPILE_MOBILE_API_BEARER_TOKEN", "").strip()
    expected_api_key = os.environ.get("STOCKPILE_MOBILE_API_KEY", "").strip()

    if expected_bearer:
        expected_header = f"Bearer {expected_bearer}"
        if authorization != expected_header:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Missing or invalid bearer token.",
            )

    if expected_api_key and x_api_key != expected_api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or invalid API key.",
        )


def _apply_upload_receipt_headers(response: Response, receipt) -> None:
    response.headers["x-stockpile-receipt-id"] = receipt.receipt_id
    response.headers["x-stockpile-server-upload-id"] = receipt.upload_id
    response.headers["x-stockpile-job-id"] = receipt.job_id
    response.headers["x-stockpile-run-id"] = receipt.run_id


def _upload_handoff_payload(finalization) -> dict:
    payload = finalization.job_status.to_dict()
    payload.update(finalization.receipt.to_dict())
    return payload


def _result_unavailable_payload(*, run_id: str, status_payload: dict) -> tuple[dict, dict[str, str]]:
    phase = str(status_payload.get("phase") or "").strip().lower()
    job_id = str(status_payload.get("jobId") or "").strip()

    if phase == JobPhase.FAILED.value:
        state = "failed"
        message = (
            f"Result {run_id} is unavailable because processing failed for job {job_id or 'unknown'}."
        )
    elif phase in {JobPhase.VERIFIED.value, JobPhase.REVIEW_ONLY.value, JobPhase.BLOCKED.value}:
        state = "terminal_missing_result"
        message = (
            f"Result {run_id} is not available yet even though job {job_id or 'unknown'} "
            f"reached terminal phase {phase}."
        )
    else:
        state = "pending"
        message = (
            f"Result {run_id} is not ready yet. "
            f"The backend is still in phase {phase or 'unknown'}."
        )

    return (
        {
            "runId": run_id,
            "state": state,
            "message": message,
            "detail": status_payload.get("detail"),
            "status": status_payload,
        },
        {
            "x-stockpile-run-state": state,
            "x-stockpile-job-id": job_id,
            "x-stockpile-job-phase": phase or "unknown",
        },
    )


def _resume_pending_jobs_if_supported(runtime: object) -> None:
    resume = getattr(runtime, "resume_pending_jobs", None)
    if callable(resume):
        try:
            resume()
        except Exception:  # pragma: no cover - startup resilience
            logger.exception("Failed to resume pending mobile jobs during app startup")
            return


def _ensure_processing_for_job_if_supported(runtime: object, job_id: str) -> bool:
    ensure = getattr(runtime, "ensure_processing_for_job", None)
    if callable(ensure):
        try:
            return bool(ensure(job_id))
        except MobileAPIValidationError:
            logger.warning("Auto-resume validation failed for mobile job %s", job_id)
            return False
        except Exception:
            logger.exception("Unexpected auto-resume failure for mobile job %s", job_id)
            raise
    return False


def _start_processing_for_upload_if_needed(
    *,
    runtime: object,
    upload_id: str,
    job_id: str,
    current_phase: JobPhase,
) -> bool:
    if current_phase is not JobPhase.UPLOAD_AUTHORIZED:
        return False

    ensure = getattr(runtime, "ensure_processing_for_job", None)
    if callable(ensure):
        try:
            return bool(ensure(job_id))
        except MobileAPIValidationError:
            logger.warning("Mobile upload %s failed validation while starting processing", upload_id)
            return False

    start = getattr(runtime, "start_processing_for_upload", None)
    if callable(start):
        start(upload_id)
        return True
    return False


@lru_cache(maxsize=1)
def get_mobile_api_service() -> StockpileMobileAPIService:
    return StockpileMobileAPIService.from_environment()


@lru_cache(maxsize=1)
def get_mobile_job_runtime() -> StockpileMobileJobRuntime:
    service = get_mobile_api_service()
    return StockpileMobileJobRuntime(service)


def create_mobile_api_app(
    service: StockpileMobileAPIService | None = None,
    runtime: StockpileMobileJobRuntime | None = None,
) -> FastAPI:
    return create_app(service=service, runtime=runtime)


app = create_app()
