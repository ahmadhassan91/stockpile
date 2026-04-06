"""Offline benchmark runner for repeatable V2 validation."""

from __future__ import annotations

import argparse
import csv
import json
import shutil
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING, Any

from .config import DENSITY_PRESETS, PipelineConfig
from .presets import PROCESSING_PROFILE_LABELS, apply_profile_overrides

if TYPE_CHECKING:  # pragma: no cover
    from .pipeline import PipelineResult


@dataclass
class BenchmarkCase:
    case_id: str
    video: Path
    material: str
    processing_profile: str = "standard"
    density_kg_per_m3: float | None = None
    reference_volume_m3: float | None = None
    reference_label: str | None = None
    pair_group: str | None = None
    variant_label: str | None = None
    notes: str | None = None
    manual_scale_override: float | None = None
    cone_height_m: float | None = None
    camera_height_m: float | None = None
    colmap_binary: str | None = None
    frame_interval_sec: float | None = None
    frame_max_frames: int | None = None
    colmap_quality: str | None = None
    colmap_max_frames: int | None = None
    colmap_use_gpu: bool | None = None


def load_manifest(manifest_path: str | Path) -> list[BenchmarkCase]:
    """Load benchmark cases from a JSON manifest."""
    manifest_file = Path(manifest_path).expanduser().resolve()
    payload = json.loads(manifest_file.read_text())
    raw_cases = payload["cases"] if isinstance(payload, dict) else payload
    if not isinstance(raw_cases, list):
        raise ValueError("Benchmark manifest must contain a 'cases' list.")

    cases: list[BenchmarkCase] = []
    for index, raw_case in enumerate(raw_cases, start=1):
        if not isinstance(raw_case, dict):
            raise ValueError(f"Case #{index} must be a JSON object.")

        case_id = str(raw_case["case_id"]).strip()
        if not case_id:
            raise ValueError(f"Case #{index} is missing a non-empty case_id.")

        video_value = raw_case.get("video")
        if not video_value:
            raise ValueError(f"Case '{case_id}' is missing 'video'.")

        video_path = Path(str(video_value))
        if not video_path.is_absolute():
            video_path = (manifest_file.parent / video_path).resolve()

        material = str(raw_case.get("material", "Backfill 0–75 mm"))
        processing_profile = str(raw_case.get("processing_profile", "standard"))
        if processing_profile not in PROCESSING_PROFILE_LABELS:
            supported = ", ".join(sorted(PROCESSING_PROFILE_LABELS))
            raise ValueError(
                f"Case '{case_id}' uses unsupported processing_profile '{processing_profile}'. "
                f"Supported values: {supported}."
            )

        cases.append(
            BenchmarkCase(
                case_id=case_id,
                video=video_path,
                material=material,
                processing_profile=processing_profile,
                density_kg_per_m3=_optional_float(raw_case.get("density_kg_per_m3")),
                reference_volume_m3=_optional_float(raw_case.get("reference_volume_m3")),
                reference_label=_optional_str(raw_case.get("reference_label")),
                pair_group=_optional_str(raw_case.get("pair_group")),
                variant_label=_optional_str(raw_case.get("variant_label")),
                notes=_optional_str(raw_case.get("notes")),
                manual_scale_override=_optional_float(raw_case.get("manual_scale_override")),
                cone_height_m=_optional_float(raw_case.get("cone_height_m")),
                camera_height_m=_optional_float(raw_case.get("camera_height_m")),
                colmap_binary=_optional_str(raw_case.get("colmap_binary")),
                frame_interval_sec=_optional_float(raw_case.get("frame_interval_sec")),
                frame_max_frames=_optional_int(raw_case.get("frame_max_frames")),
                colmap_quality=_optional_str(raw_case.get("colmap_quality")),
                colmap_max_frames=_optional_int(raw_case.get("colmap_max_frames")),
                colmap_use_gpu=_optional_bool(raw_case.get("colmap_use_gpu")),
            )
        )

    return cases


def run_benchmark(
    cases: list[BenchmarkCase],
    output_dir: str | Path,
    workspace_root: str | Path,
    keep_workspaces: bool = False,
) -> dict[str, Any]:
    """Run the pipeline for each benchmark case and write a replay summary."""
    output_path = Path(output_dir).expanduser().resolve()
    workspace_root_path = Path(workspace_root).expanduser().resolve()
    output_path.mkdir(parents=True, exist_ok=True)
    workspace_root_path.mkdir(parents=True, exist_ok=True)

    summaries: list[dict[str, Any]] = []
    started_at = datetime.now(timezone.utc)

    for position, case in enumerate(cases, start=1):
        print(f"[{position}/{len(cases)}] Running {case.case_id} ({case.processing_profile})")
        summary = _run_case(case, workspace_root_path, keep_workspaces=keep_workspaces)
        summaries.append(summary)

        status = summary["status"]
        volume = summary["recommended_volume_m3"]
        if summary["error"]:
            print(f"  -> error: {summary['error']}")
        elif volume is None:
            print(f"  -> {status}: no recommended volume")
        else:
            print(f"  -> {status}: {volume:.2f} m3")

    finished_at = datetime.now(timezone.utc)
    group_comparisons = build_group_comparisons(summaries)
    aggregate = build_aggregate_summary(summaries)
    report = {
        "started_at": started_at.isoformat(),
        "finished_at": finished_at.isoformat(),
        "case_count": len(summaries),
        "output_dir": str(output_path),
        "workspace_root": str(workspace_root_path),
        "aggregate": aggregate,
        "group_comparisons": group_comparisons,
        "cases": summaries,
    }

    (output_path / "benchmark_summary.json").write_text(json.dumps(report, indent=2))
    write_summary_csv(summaries, output_path / "benchmark_summary.csv")
    (output_path / "group_comparisons.json").write_text(json.dumps(group_comparisons, indent=2))
    return report


def build_group_comparisons(summaries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Summarize spread within grouped V1/V2 style replay sets."""
    grouped: dict[str, list[dict[str, Any]]] = {}
    for summary in summaries:
        group = summary.get("pair_group")
        if not group:
            continue
        if summary.get("error") or summary.get("recommended_volume_m3") is None:
            continue
        grouped.setdefault(group, []).append(summary)

    comparisons: list[dict[str, Any]] = []
    for group, items in sorted(grouped.items()):
        if len(items) < 2:
            continue

        ordered = sorted(items, key=lambda item: (item.get("variant_label") or "", item["case_id"]))
        volumes = [float(item["recommended_volume_m3"]) for item in ordered]
        mean_volume = sum(volumes) / len(volumes)
        spread_pct = None
        if mean_volume > 1e-9:
            spread_pct = ((max(volumes) - min(volumes)) / mean_volume) * 100.0

        comparisons.append(
            {
                "pair_group": group,
                "case_ids": [item["case_id"] for item in ordered],
                "variant_labels": [item.get("variant_label") for item in ordered],
                "recommended_volumes_m3": volumes,
                "mean_volume_m3": mean_volume,
                "spread_pct": spread_pct,
                "all_publishable": all(bool(item["publishable"]) for item in ordered),
                "all_verified": all(item["status"] == "verified" for item in ordered),
            }
        )

    return comparisons


def build_aggregate_summary(summaries: list[dict[str, Any]]) -> dict[str, Any]:
    """Build high-signal aggregate counts for the benchmark report."""
    reference_rows = [row for row in summaries if row.get("reference_delta_pct") is not None]
    volumes = [row["recommended_volume_m3"] for row in summaries if row.get("recommended_volume_m3") is not None]

    return {
        "verified_count": sum(1 for row in summaries if row["status"] == "verified"),
        "review_grade_count": sum(1 for row in summaries if row["status"] == "review_grade"),
        "blocked_count": sum(1 for row in summaries if row["status"] == "blocked"),
        "error_count": sum(1 for row in summaries if row["status"] == "error"),
        "mean_recommended_volume_m3": (sum(volumes) / len(volumes)) if volumes else None,
        "mean_abs_reference_delta_pct": (
            sum(abs(row["reference_delta_pct"]) for row in reference_rows) / len(reference_rows)
            if reference_rows
            else None
        ),
    }


def write_summary_csv(summaries: list[dict[str, Any]], csv_path: str | Path) -> None:
    """Write the flat benchmark summary to CSV for quick review."""
    if not summaries:
        return

    fieldnames = list(summaries[0].keys())
    with Path(csv_path).open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(summaries)


def _run_case(case: BenchmarkCase, workspace_root: Path, keep_workspaces: bool) -> dict[str, Any]:
    """Execute a single benchmark case."""
    workspace = workspace_root / case.case_id
    if workspace.exists():
        shutil.rmtree(workspace)

    config = _build_config(case, workspace)
    started_at = datetime.now(timezone.utc)

    error: str | None = None
    result = None
    try:
        from .pipeline import Pipeline

        pipeline = Pipeline(config)
        result = pipeline.run(case.video)
        error = result.error
    except Exception as exc:  # pragma: no cover - defensive runtime guard
        error = str(exc)
    finished_at = datetime.now(timezone.utc)

    summary = _summarize_case(
        case=case,
        result=result,
        error=error,
        workspace=workspace,
        started_at=started_at,
        finished_at=finished_at,
    )

    if not keep_workspaces and workspace.exists():
        shutil.rmtree(workspace)

    return summary


def _build_config(case: BenchmarkCase, workspace: Path) -> PipelineConfig:
    density = float(case.density_kg_per_m3 or DENSITY_PRESETS.get(case.material, 2100.0))
    config = PipelineConfig(
        workspace=workspace,
        material_density=density,
        material_name=case.material,
        manual_scale_override=case.manual_scale_override,
    )
    apply_profile_overrides(config, case.material, case.processing_profile)

    if case.cone_height_m is not None:
        config.scale_calibration.known_cone_height_m = float(case.cone_height_m)
    if case.camera_height_m is not None:
        config.scale_calibration.assumed_camera_height_m = float(case.camera_height_m)
    if case.colmap_binary is not None:
        config.colmap.colmap_binary = case.colmap_binary
    if case.frame_interval_sec is not None:
        config.frame_extraction.interval_sec = float(case.frame_interval_sec)
    if case.frame_max_frames is not None:
        config.frame_extraction.max_frames = int(case.frame_max_frames)
    if case.colmap_quality is not None:
        config.colmap.quality = case.colmap_quality
    if case.colmap_max_frames is not None:
        config.colmap.max_colmap_frames = int(case.colmap_max_frames)
    if case.colmap_use_gpu is not None:
        config.colmap.use_gpu = bool(case.colmap_use_gpu)
    return config


def _summarize_case(
    case: BenchmarkCase,
    result: PipelineResult | None,
    error: str | None,
    workspace: Path,
    started_at: datetime,
    finished_at: datetime,
) -> dict[str, Any]:
    volume = result.volume if result is not None else None
    calibration = result.calibration if result is not None else None
    recommended_volume = volume.recommended_m3 if volume is not None else None

    reference_delta_m3 = None
    reference_delta_pct = None
    if case.reference_volume_m3 is not None and recommended_volume is not None:
        reference_delta_m3 = recommended_volume - case.reference_volume_m3
        if abs(case.reference_volume_m3) > 1e-9:
            reference_delta_pct = (reference_delta_m3 / case.reference_volume_m3) * 100.0

    blockers = list(result.quality_blockers) if result is not None else []
    warnings = list(result.quality_warnings) if result is not None else []

    return {
        "case_id": case.case_id,
        "video": str(case.video),
        "material": case.material,
        "processing_profile": case.processing_profile,
        "processing_profile_label": PROCESSING_PROFILE_LABELS[case.processing_profile],
        "pair_group": case.pair_group,
        "variant_label": case.variant_label,
        "notes": case.notes,
        "workspace": str(workspace),
        "started_at": started_at.isoformat(),
        "finished_at": finished_at.isoformat(),
        "duration_sec": round((finished_at - started_at).total_seconds(), 2),
        "status": _status_from_result(result, error),
        "publishable": bool(result.publishable) if result is not None and not error else False,
        "review_grade": bool(result.review_grade) if result is not None and not error else False,
        "error": error,
        "num_frames": result.num_frames if result is not None else 0,
        "num_frames_with_cones": result.num_frames_with_cones if result is not None else 0,
        "num_colmap_points": result.num_colmap_points if result is not None else 0,
        "num_colmap_images": result.num_colmap_images if result is not None else 0,
        "pile_points": len(result.pile_cloud.points) if result is not None and result.pile_cloud is not None else 0,
        "ground_points": len(result.ground_cloud.points) if result is not None and result.ground_cloud is not None else 0,
        "scale_source": result.scale_source if result is not None else None,
        "scale_factor_m_per_unit": result.scale_factor_m_per_unit if result is not None else None,
        "calibration_confidence": calibration.confidence if calibration is not None else None,
        "num_cones_used": calibration.num_cones_used if calibration is not None else None,
        "detected_cone_frames": calibration.detected_cone_frames if calibration is not None else None,
        "registered_cone_frames": calibration.registered_cone_frames if calibration is not None else None,
        "max_detections_in_frame": calibration.max_detections_in_frame if calibration is not None else None,
        "frames_with_multiple_detections": calibration.frames_with_multiple_detections if calibration is not None else None,
        "scale_disagreement_ratio": calibration.scale_disagreement_ratio if calibration is not None else None,
        "recommended_volume_m3": recommended_volume,
        "grid_volume_m3": volume.grid_integration_m3 if volume is not None else None,
        "convex_hull_volume_m3": volume.convex_hull_m3 if volume is not None else None,
        "alpha_shape_volume_m3": volume.alpha_shape_m3 if volume is not None else None,
        "grid_occupancy_pct": volume.grid_occupancy_pct if volume is not None else None,
        "grid_to_hull_ratio": volume.grid_to_hull_ratio if volume is not None else None,
        "footprint_area_m2": volume.footprint_area_m2 if volume is not None else None,
        "footprint_source": volume.footprint_source if volume is not None else None,
        "recommended_method": volume.recommended_method if volume is not None else None,
        "recommended_note": volume.recommended_note if volume is not None else None,
        "weight_kg": result.weight_kg if result is not None else None,
        "quality_blockers": " | ".join(blockers),
        "quality_warnings": " | ".join(warnings),
        "reference_label": case.reference_label,
        "reference_volume_m3": case.reference_volume_m3,
        "reference_delta_m3": reference_delta_m3,
        "reference_delta_pct": reference_delta_pct,
        "colmap_binary": case.colmap_binary or "default",
        "frame_interval_sec": case.frame_interval_sec,
        "frame_max_frames": case.frame_max_frames,
        "colmap_quality": case.colmap_quality,
        "colmap_max_frames": case.colmap_max_frames,
        "colmap_use_gpu": case.colmap_use_gpu,
    }


def _status_from_result(result: PipelineResult | None, error: str | None) -> str:
    if error or result is None:
        return "error"
    if result.publishable and result.review_grade:
        return "review_grade"
    if result.publishable:
        return "verified"
    return "blocked"


def _optional_float(value: Any) -> float | None:
    if value in (None, ""):
        return None
    return float(value)


def _optional_str(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _optional_int(value: Any) -> int | None:
    if value in (None, ""):
        return None
    return int(value)


def _optional_bool(value: Any) -> bool | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    if text in {"1", "true", "yes", "on"}:
        return True
    if text in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"Cannot interpret boolean value: {value!r}")


def build_arg_parser() -> argparse.ArgumentParser:
    """Return the CLI parser for the benchmark runner."""
    parser = argparse.ArgumentParser(description="Replay a stockpile benchmark manifest.")
    parser.add_argument(
        "--manifest",
        default="samples/benchmark_manifest.json",
        help="Path to a benchmark manifest JSON file.",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Directory for benchmark_summary.json/csv. Defaults to benchmark_runs/<timestamp>.",
    )
    parser.add_argument(
        "--workspace-root",
        default="data/benchmark_workspaces",
        help="Root directory for per-case pipeline workspaces.",
    )
    parser.add_argument(
        "--case",
        action="append",
        dest="case_filters",
        default=[],
        help="Run only the named case_id. Repeat to run multiple cases.",
    )
    parser.add_argument(
        "--keep-workspaces",
        action="store_true",
        help="Keep each per-case workspace after the run for deeper debugging.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint."""
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    manifest_path = Path(args.manifest).expanduser().resolve()
    cases = load_manifest(manifest_path)
    if args.case_filters:
        wanted = set(args.case_filters)
        cases = [case for case in cases if case.case_id in wanted]

    if not cases:
        parser.error("No benchmark cases matched the requested filters.")

    missing_videos = [str(case.video) for case in cases if not case.video.exists()]
    if missing_videos:
        parser.error(
            "The following benchmark videos are missing:\n- " + "\n- ".join(missing_videos)
        )

    output_dir = args.output_dir
    if output_dir is None:
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        output_dir = Path("benchmark_runs") / timestamp

    report = run_benchmark(
        cases=cases,
        output_dir=output_dir,
        workspace_root=args.workspace_root,
        keep_workspaces=args.keep_workspaces,
    )
    print(f"Wrote benchmark report to {report['output_dir']}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
