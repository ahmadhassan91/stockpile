from __future__ import annotations

import logging
import shutil
import tempfile
import zipfile
from pathlib import Path
from typing import Any

from fastapi import APIRouter, File, Header, HTTPException, UploadFile, status

from stockpile_lidar.ingestion import (
    BundleValidationError,
    StockpileCaptureBundle,
    unpack_stockpile_capture,
)
from stockpile_lidar.pipeline import LidarPipeline


logger = logging.getLogger(__name__)

router = APIRouter(prefix="/captures", tags=["captures"])


_MAX_BUNDLE_BYTES = 2 * 1024 * 1024 * 1024  # 2 GiB safety net


@router.post("", status_code=status.HTTP_202_ACCEPTED)
async def create_capture(
    bundle: UploadFile = File(...),
    capture_mode: str | None = Header(default=None, alias="X-Stockpile-Capture-Mode"),
    capture_id_header: str | None = Header(default=None, alias="X-Stockpile-Capture-ID"),
    site_id_header: str | None = Header(default=None, alias="X-Stockpile-Site-ID"),
    material_code_header: str | None = Header(
        default=None, alias="X-Stockpile-Material-Code"
    ),
) -> dict[str, str]:
    """Accept a `.stockpilecapture` ZIP, run the lean pipeline, return a receipt."""

    work_dir = Path(tempfile.mkdtemp(prefix="stockpile-capture-"))
    bundle_path = work_dir / "bundle.stockpilecapture"
    extract_dir = work_dir / "unpacked"

    try:
        await _save_upload(bundle, bundle_path)

        try:
            unpacked = unpack_stockpile_capture(bundle_path, extract_dir)
        except BundleValidationError as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=str(exc),
            ) from exc
        except zipfile.BadZipFile as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="capture bundle is not a valid ZIP archive",
            ) from exc
        except Exception as exc:  # pragma: no cover - defensive
            logger.exception("Failed to unpack capture bundle")
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Failed to unpack capture bundle",
            ) from exc

        unpacked = _apply_header_overrides(
            unpacked,
            capture_mode=capture_mode,
            capture_id=capture_id_header,
            site_id=site_id_header,
            material_code=material_code_header,
        )

        try:
            submission = LidarPipeline().process_capture(unpacked)
        except Exception as exc:  # pragma: no cover - defensive
            logger.exception("Pipeline failed to process capture")
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Pipeline failed to process capture",
            ) from exc

        return {
            "captureId": submission.capture_id,
            "jobId": submission.job_id,
            "resultId": submission.result_id,
            "status": submission.status,
        }
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


async def _save_upload(upload: UploadFile, target_path: Path) -> None:
    target_path.parent.mkdir(parents=True, exist_ok=True)
    bytes_written = 0
    chunk_size = 1024 * 1024
    with target_path.open("wb") as sink:
        while True:
            chunk = await upload.read(chunk_size)
            if not chunk:
                break
            bytes_written += len(chunk)
            if bytes_written > _MAX_BUNDLE_BYTES:
                raise HTTPException(
                    status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                    detail="capture bundle exceeds maximum allowed size",
                )
            sink.write(chunk)
    if bytes_written == 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="capture bundle is empty",
        )


def _apply_header_overrides(
    unpacked: StockpileCaptureBundle,
    *,
    capture_mode: str | None,
    capture_id: str | None,
    site_id: str | None,
    material_code: str | None,
) -> StockpileCaptureBundle:
    """Headers are treated as authoritative overrides for the manifest fields."""

    manifest: dict[str, Any] = dict(unpacked.manifest)
    _apply_override(manifest, "capture_mode", capture_mode)
    _apply_override(manifest, "capture_id", capture_id)
    _apply_override(manifest, "site_id", site_id)
    _apply_override(manifest, "material_code", material_code)

    return StockpileCaptureBundle(
        root=unpacked.root,
        manifest=manifest,
        poses=unpacked.poses,
        rgb_frames=unpacked.rgb_frames,
        depth_frames=unpacked.depth_frames,
    )


def _apply_override(manifest: dict[str, Any], key: str, value: str | None) -> None:
    if value is None:
        return
    cleaned = value.strip()
    if not cleaned:
        return
    # Headers override missing/blank manifest values; if the manifest already has
    # a non-empty value, keep ours but allow header to overwrite (per task spec).
    manifest[key] = cleaned
