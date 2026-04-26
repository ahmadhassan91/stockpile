import io
import json
import zipfile
from uuid import UUID

import numpy as np
import pytest
from fastapi.testclient import TestClient

from stockpile_lidar.api.main import create_app
from stockpile_lidar.pipeline import JOB_STORE, RESULT_STORE, reset_state


@pytest.fixture(autouse=True)
def _clean_state():
    reset_state()
    yield
    reset_state()


@pytest.fixture
def client():
    return TestClient(create_app())


def _depth_frame_bytes() -> bytes:
    buffer = io.BytesIO()
    np.save(buffer, np.ones((2, 2), dtype=np.float16))
    return buffer.getvalue()


def _build_capture_zip(
    *,
    manifest_overrides: dict | None = None,
    skip_manifest: bool = False,
) -> bytes:
    manifest = {
        "schema_version": 1,
        "capture_id": "cap_route_001",
        "site_id": "site_alpha",
        "pile_name": "Pile A",
        "material_code": "GRAVEL",
        "density_kg_per_m3": 1500.0,
        "frame_count": 1,
        "depth_dtype": "float16",
        "tracking_state_summary": "normal",
        "on_device_quick_estimate": {
            "volume_m3": 7.0,
            "footprint_area_m2": 5.0,
            "peak_height_m": 1.4,
            "confidence_score": 0.7,
        },
    }
    if manifest_overrides:
        manifest.update(manifest_overrides)

    poses = [
        {
            "timestamp": 0.0,
            "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            "intrinsics": [1, 0, 0, 0, 1, 0, 0, 0, 1],
            "tracking_state": "normal",
        }
    ]

    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        if not skip_manifest:
            archive.writestr("manifest.json", json.dumps(manifest).encode("utf-8"))
        archive.writestr("poses.json", json.dumps(poses).encode("utf-8"))
        archive.writestr("rgb/000000.jpg", b"rgb-bytes")
        archive.writestr("depth/000000.npy", _depth_frame_bytes())
    return buffer.getvalue()


def test_post_capture_accepts_bundle_and_returns_receipt(client):
    bundle_bytes = _build_capture_zip()

    response = client.post(
        "/api/v2/captures",
        files={"bundle": ("capture.stockpilecapture", bundle_bytes, "application/zip")},
        headers={
            "X-Stockpile-Capture-Mode": "markerless",
            "X-Stockpile-Capture-ID": "cap_route_001",
            "X-Stockpile-Site-ID": "site_alpha",
            "X-Stockpile-Material-Code": "GRAVEL",
        },
    )

    assert response.status_code == 202, response.text
    payload = response.json()
    assert payload["captureId"] == "cap_route_001"
    assert payload["status"] == "completed"

    job_id = payload["jobId"]
    result_id = payload["resultId"]
    UUID(job_id)
    UUID(result_id)

    assert job_id in JOB_STORE
    assert result_id in RESULT_STORE
    assert RESULT_STORE[result_id]["weight_kg"] == pytest.approx(7.0 * 1500.0)


def test_post_capture_rejects_malformed_zip(client):
    response = client.post(
        "/api/v2/captures",
        files={
            "bundle": (
                "capture.stockpilecapture",
                b"not-a-real-zip",
                "application/zip",
            ),
        },
    )

    assert response.status_code == 400
    detail = response.json()["detail"]
    assert isinstance(detail, str) and detail


def test_post_capture_rejects_zip_missing_manifest(client):
    bundle_bytes = _build_capture_zip(skip_manifest=True)

    response = client.post(
        "/api/v2/captures",
        files={"bundle": ("capture.stockpilecapture", bundle_bytes, "application/zip")},
    )

    assert response.status_code == 400
    assert "manifest.json" in response.json()["detail"]


def test_post_capture_applies_header_overrides(client):
    bundle_bytes = _build_capture_zip(
        manifest_overrides={
            "capture_id": "cap_in_manifest",
            "site_id": "site_in_manifest",
            "material_code": "SAND",
        }
    )

    response = client.post(
        "/api/v2/captures",
        files={"bundle": ("capture.stockpilecapture", bundle_bytes, "application/zip")},
        headers={
            "X-Stockpile-Capture-Mode": "markerless",
            "X-Stockpile-Capture-ID": "cap_from_header",
            "X-Stockpile-Site-ID": "site_from_header",
            "X-Stockpile-Material-Code": "GRAVEL",
        },
    )

    assert response.status_code == 202, response.text
    payload = response.json()
    assert payload["captureId"] == "cap_from_header"

    diagnostics = RESULT_STORE[payload["resultId"]]["diagnostics"]
    assert diagnostics["capture_id"] == "cap_from_header"
    assert diagnostics["site_id"] == "site_from_header"
    assert diagnostics["material_code"] == "GRAVEL"
