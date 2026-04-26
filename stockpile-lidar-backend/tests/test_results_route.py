import io
import json
import zipfile
from uuid import uuid4

import numpy as np
import pytest
from fastapi.testclient import TestClient

from stockpile_lidar.api.main import create_app
from stockpile_lidar.pipeline import reset_state


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


def _build_capture_zip() -> bytes:
    manifest = {
        "schema_version": 1,
        "capture_id": "cap_results_001",
        "site_id": "site_alpha",
        "material_code": "GRAVEL",
        "density_kg_per_m3": 2000.0,
        "frame_count": 1,
        "depth_dtype": "float16",
        "tracking_state_summary": "normal",
        "on_device_quick_estimate": {
            "volume_m3": 3.25,
            "footprint_area_m2": 4.0,
            "peak_height_m": 1.0,
            "confidence_score": 0.6,
        },
    }
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
        archive.writestr("manifest.json", json.dumps(manifest).encode("utf-8"))
        archive.writestr("poses.json", json.dumps(poses).encode("utf-8"))
        archive.writestr("rgb/000000.jpg", b"rgb-bytes")
        archive.writestr("depth/000000.npy", _depth_frame_bytes())
    return buffer.getvalue()


def _create_capture(client: TestClient) -> dict:
    response = client.post(
        "/api/v2/captures",
        files={
            "bundle": (
                "capture.stockpilecapture",
                _build_capture_zip(),
                "application/zip",
            ),
        },
    )
    assert response.status_code == 202, response.text
    return response.json()


def test_get_result_returns_saved_pipeline_result(client):
    receipt = _create_capture(client)

    response = client.get(f"/api/v2/results/{receipt['resultId']}")

    assert response.status_code == 200
    body = response.json()
    assert body["result_id"] == receipt["resultId"]
    assert body["stage"] == "complete"
    assert body["weight_kg"] == pytest.approx(3.25 * 2000.0)
    assert body["volume"]["recommended_m3"] == pytest.approx(3.25)


def test_get_result_returns_404_for_unknown_uuid(client):
    response = client.get(f"/api/v2/results/{uuid4()}")

    assert response.status_code == 404


def test_get_result_returns_400_for_non_uuid(client):
    response = client.get("/api/v2/results/not-a-uuid")

    assert response.status_code == 400


def test_get_job_returns_completed_record_after_capture(client):
    receipt = _create_capture(client)

    response = client.get(f"/api/v2/jobs/{receipt['jobId']}")

    assert response.status_code == 200
    body = response.json()
    assert body["job_id"] == receipt["jobId"]
    assert body["status"] == "completed"
    assert body["result_id"] == receipt["resultId"]


def test_get_job_returns_404_for_unknown_uuid(client):
    response = client.get(f"/api/v2/jobs/{uuid4()}")

    assert response.status_code == 404
