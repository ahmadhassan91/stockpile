import pytest

from stockpile_lidar.manifest import ManifestValidationError, validate_capture_manifest


def _valid_manifest() -> dict:
    return {
        "captureId": "cap_123",
        "deviceId": "iphone-15-pro-qpmc-01",
        "capturedAt": "2026-04-26T10:30:00Z",
        "lidar": {
            "frameCount": 2,
            "frames": [
                {
                    "fileName": "depth/frame_0001.ply",
                    "timestampMs": 0,
                    "format": "ply",
                },
                {
                    "fileName": "depth/frame_0002.ply",
                    "timestampMs": 33,
                    "format": "ply",
                },
            ],
        },
    }


def test_manifest_validator_accepts_minimal_lidar_manifest():
    manifest = validate_capture_manifest(_valid_manifest())

    assert manifest.capture_id == "cap_123"
    assert manifest.device_id == "iphone-15-pro-qpmc-01"
    assert manifest.frame_count == 2
    assert [frame.file_name for frame in manifest.frames] == [
        "depth/frame_0001.ply",
        "depth/frame_0002.ply",
    ]


def test_manifest_validator_rejects_missing_required_fields():
    payload = _valid_manifest()
    del payload["lidar"]["frames"][0]["fileName"]

    with pytest.raises(ManifestValidationError) as exc_info:
        validate_capture_manifest(payload)

    assert "lidar.frames[0].fileName" in str(exc_info.value)


def test_manifest_validator_rejects_frame_count_mismatch():
    payload = _valid_manifest()
    payload["lidar"]["frameCount"] = 3

    with pytest.raises(ManifestValidationError) as exc_info:
        validate_capture_manifest(payload)

    assert "lidar.frameCount" in str(exc_info.value)
