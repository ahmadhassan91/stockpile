from fastapi.testclient import TestClient

from stockpile_lidar.api.main import create_app


def test_health_reports_lidar_backend_status():
    client = TestClient(create_app())

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "service": "stockpile-lidar-backend",
    }
