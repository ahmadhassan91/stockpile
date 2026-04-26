import io
import json
import zipfile

import numpy as np
import pytest

from stockpile_lidar.ingestion import (
    BundleValidationError,
    unpack_stockpile_capture,
)


def _depth_frame(dtype: np.dtype = np.float16) -> bytes:
    buffer = io.BytesIO()
    np.save(buffer, np.ones((2, 2), dtype=dtype))
    return buffer.getvalue()


def _write_bundle(
    path,
    *,
    manifest=None,
    poses=None,
    extra_entries=None,
    omit=(),
    depth_dtype: np.dtype = np.float16,
):
    manifest = {
        "schema_version": 1,
        "frame_count": 2,
        "depth_dtype": "float16",
        **(manifest or {}),
    }
    poses = poses if poses is not None else [{"id": 0}, {"id": 1}]
    entries = {
        "manifest.json": json.dumps(manifest).encode("utf-8"),
        "poses.json": json.dumps(poses).encode("utf-8"),
        "rgb/frame_000001.jpg": b"rgb-1",
        "rgb/frame_000002.jpg": b"rgb-2",
        "depth/frame_000001.npy": _depth_frame(depth_dtype),
        "depth/frame_000002.npy": _depth_frame(depth_dtype),
        **(extra_entries or {}),
    }
    for name in omit:
        if name.endswith("/"):
            entries = {
                entry_name: payload
                for entry_name, payload in entries.items()
                if not entry_name.startswith(name)
            }
        else:
            entries.pop(name, None)
    with zipfile.ZipFile(path, "w") as archive:
        for name, payload in entries.items():
            archive.writestr(name, payload)


def test_unpacks_valid_stockpile_capture_bundle(tmp_path):
    bundle_path = tmp_path / "capture.stockpilecapture"
    output_dir = tmp_path / "out"
    _write_bundle(bundle_path)

    bundle = unpack_stockpile_capture(bundle_path, output_dir)

    assert bundle.root == output_dir
    assert bundle.manifest["frame_count"] == 2
    assert bundle.poses == [{"id": 0}, {"id": 1}]
    assert [path.name for path in bundle.rgb_frames] == [
        "frame_000001.jpg",
        "frame_000002.jpg",
    ]
    assert [path.name for path in bundle.depth_frames] == [
        "frame_000001.npy",
        "frame_000002.npy",
    ]
    assert (output_dir / "manifest.json").is_file()


def test_rejects_bundle_with_path_traversal_entry(tmp_path):
    bundle_path = tmp_path / "capture.stockpilecapture"
    _write_bundle(bundle_path, extra_entries={"../escape.txt": b"nope"})

    with pytest.raises(BundleValidationError, match="path traversal"):
        unpack_stockpile_capture(bundle_path, tmp_path / "out")


@pytest.mark.parametrize(
    ("missing_entry", "message"),
    [
        ("manifest.json", "manifest.json"),
        ("poses.json", "poses.json"),
        ("rgb/", "rgb/"),
        ("depth/", "depth/"),
    ],
)
def test_rejects_bundle_missing_required_layout(tmp_path, missing_entry, message):
    bundle_path = tmp_path / "capture.stockpilecapture"
    _write_bundle(bundle_path, omit=(missing_entry,))

    with pytest.raises(BundleValidationError, match=message):
        unpack_stockpile_capture(bundle_path, tmp_path / "out")


def test_rejects_unsupported_manifest_schema_version(tmp_path):
    bundle_path = tmp_path / "capture.stockpilecapture"
    _write_bundle(bundle_path, manifest={"schema_version": 2})

    with pytest.raises(BundleValidationError, match="schema_version"):
        unpack_stockpile_capture(bundle_path, tmp_path / "out")


def test_rejects_manifest_frame_count_mismatch(tmp_path):
    bundle_path = tmp_path / "capture.stockpilecapture"
    _write_bundle(bundle_path, manifest={"frame_count": 3})

    with pytest.raises(BundleValidationError, match="frame_count"):
        unpack_stockpile_capture(bundle_path, tmp_path / "out")


def test_rejects_manifest_depth_dtype_other_than_float16(tmp_path):
    bundle_path = tmp_path / "capture.stockpilecapture"
    _write_bundle(bundle_path, manifest={"depth_dtype": "float32"})

    with pytest.raises(BundleValidationError, match="depth_dtype"):
        unpack_stockpile_capture(bundle_path, tmp_path / "out")


def test_rejects_depth_frames_that_are_not_float16(tmp_path):
    bundle_path = tmp_path / "capture.stockpilecapture"
    _write_bundle(bundle_path, depth_dtype=np.float32)

    with pytest.raises(BundleValidationError, match="float16 depth data"):
        unpack_stockpile_capture(bundle_path, tmp_path / "out")


def test_rejects_pose_count_mismatch(tmp_path):
    bundle_path = tmp_path / "capture.stockpilecapture"
    _write_bundle(bundle_path, poses=[{"id": 0}])

    with pytest.raises(BundleValidationError, match="pose count"):
        unpack_stockpile_capture(bundle_path, tmp_path / "out")
