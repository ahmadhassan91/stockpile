from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, HTTPException, status

from stockpile_lidar.pipeline import RESULT_STORE


router = APIRouter(prefix="/results", tags=["results"])


@router.get("/{result_id}")
async def get_result(result_id: str) -> dict[str, Any]:
    _validate_uuid(result_id, field="result_id")

    record = RESULT_STORE.get(result_id)
    if record is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"result {result_id} not found",
        )
    return record


def _validate_uuid(value: str, *, field: str) -> None:
    try:
        UUID(value)
    except (TypeError, ValueError) as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"{field} must be a valid UUID",
        ) from exc
