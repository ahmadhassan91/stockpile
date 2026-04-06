from types import SimpleNamespace

from stockpile.colmap_runner import _quality_to_sift_settings, _subsample_images_dir, run_colmap_reconstruction
from stockpile.config import ColmapConfig


def test_subsample_images_dir_preserves_priority_frames_and_neighbors(tmp_path):
    images_dir = tmp_path / "images"
    images_dir.mkdir()

    for index in range(12):
        (images_dir / f"frame_{index:05d}.jpg").write_bytes(b"test")

    subset_dir = _subsample_images_dir(
        images_dir,
        max_frames=6,
        priority_image_names={"frame_00000.jpg", "frame_00011.jpg"},
        priority_neighbor_radius=1,
    )

    subset_names = sorted(path.name for path in subset_dir.glob("*.jpg"))

    assert len(subset_names) == 6
    assert "frame_00000.jpg" in subset_names
    assert "frame_00001.jpg" in subset_names
    assert "frame_00010.jpg" in subset_names
    assert "frame_00011.jpg" in subset_names


def test_quality_to_sift_settings_maps_low_medium_high():
    assert _quality_to_sift_settings("low") == (1600, 4096)
    assert _quality_to_sift_settings("medium") == (2400, 8192)
    assert _quality_to_sift_settings("high") == (3200, 16384)


def test_run_colmap_reconstruction_creates_registration_output_dirs(tmp_path, monkeypatch):
    images_dir = tmp_path / "images"
    workspace_dir = tmp_path / "workspace"
    images_dir.mkdir()
    (images_dir / "frame_00000.jpg").write_bytes(b"test")

    sparse_dir = workspace_dir / "sparse"
    model_dir = sparse_dir / "0"
    triangulated_dir = workspace_dir / "sparse_triangulated"

    run_steps: list[str] = []

    def fake_run_colmap_command(cmd, command_workspace_dir, step_name, timeout):
        del timeout
        run_steps.append(step_name)
        assert command_workspace_dir == workspace_dir
        if step_name == "mapper":
            model_dir.mkdir(parents=True, exist_ok=True)
            for name in ("cameras.bin", "images.bin", "points3D.bin"):
                (model_dir / name).write_bytes(b"test")
        if step_name == "image_registrator":
            output_dir = workspace_dir / "sparse_registered"
            assert output_dir.is_dir()
        if step_name == "point_triangulator":
            output_dir = workspace_dir / "sparse_triangulated"
            assert output_dir.is_dir()
            final_model_dir = output_dir / "0"
            final_model_dir.mkdir(parents=True, exist_ok=True)
            for name in ("cameras.bin", "images.bin", "points3D.bin"):
                (final_model_dir / name).write_bytes(b"test")
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    def fake_registered_image_names(candidate):
        candidate = candidate.resolve()
        if candidate == model_dir.resolve():
            return set()
        if candidate == (triangulated_dir / "0").resolve():
            return {"frame_00000.jpg"}
        return set()

    monkeypatch.setattr("stockpile.colmap_runner._run_colmap_command", fake_run_colmap_command)
    monkeypatch.setattr("stockpile.colmap_runner._registered_image_names", fake_registered_image_names)

    model_path = run_colmap_reconstruction(
        images_dir=images_dir,
        workspace_dir=workspace_dir,
        config=ColmapConfig(max_colmap_frames=10),
        priority_image_names={"frame_00000.jpg"},
    )

    assert model_path == triangulated_dir / "0"
    assert run_steps == [
        "feature_extractor",
        "exhaustive_matcher",
        "mapper",
        "image_registrator",
        "point_triangulator",
    ]
