from pathlib import Path

from stockpile.benchmark import build_group_comparisons, load_manifest
from stockpile.config import PipelineConfig
from stockpile.presets import apply_profile_overrides


def test_load_manifest_resolves_video_paths_relative_to_manifest(tmp_path):
    samples_dir = tmp_path / "samples"
    samples_dir.mkdir()
    video_path = samples_dir / "example.mp4"
    video_path.write_bytes(b"")

    manifest = samples_dir / "benchmark_manifest.json"
    manifest.write_text(
        """
        {
          "cases": [
            {
              "case_id": "example_case",
              "video": "example.mp4",
              "material": "Backfill 0\\u201375 mm",
              "processing_profile": "standard"
            }
          ]
        }
        """
    )

    cases = load_manifest(manifest)

    assert len(cases) == 1
    assert cases[0].case_id == "example_case"
    assert cases[0].video == video_path.resolve()


def test_apply_profile_overrides_sets_shared_pipeline_values():
    config = PipelineConfig()

    apply_profile_overrides(config, "Aggregates 5–14 mm", "high_accuracy")

    assert config.frame_extraction.interval_sec == 0.20
    assert config.frame_extraction.max_frames == 1000
    assert config.colmap.quality == "high"
    assert config.ground_plane.above_ground_threshold == 0.08
    assert config.volume.grid_resolution == 0.04


def test_load_manifest_reads_runtime_override_fields(tmp_path):
    samples_dir = tmp_path / "samples"
    samples_dir.mkdir()
    video_path = samples_dir / "example.mp4"
    video_path.write_bytes(b"")

    manifest = samples_dir / "benchmark_manifest.json"
    manifest.write_text(
        """
        {
          "cases": [
            {
              "case_id": "fast_case",
              "video": "example.mp4",
              "material": "Aggregates 5\\u201314 mm",
              "processing_profile": "fast_review",
              "frame_interval_sec": 1.0,
              "frame_max_frames": 120,
              "colmap_quality": "low",
              "colmap_max_frames": 80,
              "colmap_use_gpu": false
            }
          ]
        }
        """
    )

    case = load_manifest(manifest)[0]

    assert case.frame_interval_sec == 1.0
    assert case.frame_max_frames == 120
    assert case.colmap_quality == "low"
    assert case.colmap_max_frames == 80
    assert case.colmap_use_gpu is False


def test_build_group_comparisons_reports_volume_spread():
    comparisons = build_group_comparisons(
        [
            {
                "case_id": "case_v1",
                "pair_group": "aggregate_a",
                "variant_label": "V1",
                "recommended_volume_m3": 100.0,
                "publishable": True,
                "status": "verified",
                "error": None,
            },
            {
                "case_id": "case_v2",
                "pair_group": "aggregate_a",
                "variant_label": "V2",
                "recommended_volume_m3": 110.0,
                "publishable": True,
                "status": "review_grade",
                "error": None,
            },
        ]
    )

    assert len(comparisons) == 1
    assert comparisons[0]["pair_group"] == "aggregate_a"
    assert comparisons[0]["spread_pct"] == 9.523809523809524
