"""Batch validation: run all sample videos through the patched pipeline.

Usage (on server):
    cd /home/administrator/stock_pile_estimate
    .venv/bin/python3 scripts/run_sample_sweep.py 2>&1 | tee /tmp/sample_sweep.log
"""

import json
import logging
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)
logger = logging.getLogger("sample_sweep")

from stockpile.config import PipelineConfig
from stockpile.pipeline import Pipeline

SAMPLES_DIR = Path("data/samples")
RESULTS_DIR = Path("data/sample_sweep_results")

VIDEOS = [
    {"file": "AGGREGATE 10-20MM V1.mp4", "material": "Aggregate 10-20 mm", "density": 1600},
    {"file": "AGGREGATE 10-20MM V2.mp4", "material": "Aggregate 10-20 mm", "density": 1600},
    {"file": "AGGREGATE 5-14MM V1.mp4", "material": "Aggregate 5-14 mm", "density": 1600},
    {"file": "AGGREGATE 5-14MM V2.mp4", "material": "Aggregate 5-14 mm", "density": 1600},
    {"file": "NON-TREATED BACKFILL 0-75MM V2.mp4", "material": "Backfill 0-75 mm", "density": 2100},
]


def run_one(video_info: dict, run_idx: int) -> dict:
    video_path = SAMPLES_DIR / video_info["file"]
    if not video_path.exists():
        return {"file": video_info["file"], "error": f"File not found: {video_path}"}

    tag = video_info["file"].replace(" ", "_").replace(".mp4", "").lower()
    workspace = RESULTS_DIR / tag

    logger.info("=" * 70)
    logger.info("[%d/%d] %s", run_idx, len(VIDEOS), video_info["file"])
    logger.info("  Workspace: %s", workspace)
    logger.info("=" * 70)

    config = PipelineConfig()
    config.workspace = workspace
    config.material_name = video_info["material"]
    config.material_density = float(video_info["density"])
    # Use standard settings
    config.scale_calibration.known_cone_height_m = 0.75
    config.scale_calibration.assumed_camera_height_m = 1.6

    start = time.monotonic()
    try:
        pipeline = Pipeline(config)
        result = pipeline.run(str(video_path))
    except Exception as exc:
        elapsed = time.monotonic() - start
        logger.error("CRASHED after %.1fs: %s", elapsed, exc)
        return {
            "file": video_info["file"],
            "material": video_info["material"],
            "error": str(exc),
            "elapsed_sec": round(elapsed, 1),
        }

    elapsed = time.monotonic() - start
    cal = result.calibration
    vol = result.volume

    summary = {
        "file": video_info["file"],
        "material": video_info["material"],
        "density": video_info["density"],
        "elapsed_sec": round(elapsed, 1),
        "error": result.error,
        "stage": result.stage,
        "publishable": result.publishable,
        "review_grade": result.review_grade,
        "num_frames": result.num_frames,
        "num_frames_with_cones": result.num_frames_with_cones,
        "num_colmap_images": result.num_colmap_images,
        "num_colmap_points": result.num_colmap_points,
        "scale_source": result.scale_source,
        "scale_factor": round(result.scale_factor_m_per_unit, 4) if result.scale_factor_m_per_unit else None,
        "calibration_confidence": round(cal.confidence, 4) if cal else None,
        "num_cones_used": cal.num_cones_used if cal else None,
        "num_samples": len(cal.per_cone_scales) if cal and cal.per_cone_scales else None,
        "recommended_volume_m3": round(vol.recommended_m3, 1) if vol else None,
        "recommended_method": vol.recommended_method if vol else None,
        "grid_volume_m3": round(vol.grid_integration_m3, 1) if vol and vol.grid_integration_m3 else None,
        "hull_volume_m3": round(vol.convex_hull_m3, 1) if vol and vol.convex_hull_m3 else None,
        "weight_kg": round(result.weight_kg, 0) if result.weight_kg else None,
        "quality_blockers": result.quality_blockers,
        "quality_warnings": result.quality_warnings,
    }

    logger.info("RESULT: %s", json.dumps(summary, indent=2))
    return summary


def main():
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    # Check all videos exist before starting
    missing = [v["file"] for v in VIDEOS if not (SAMPLES_DIR / v["file"]).exists()]
    if missing:
        logger.error("Missing videos: %s", missing)
        sys.exit(1)

    logger.info("Starting sample sweep: %d videos", len(VIDEOS))
    all_results = []

    for i, video in enumerate(VIDEOS, 1):
        summary = run_one(video, i)
        all_results.append(summary)

        # Save incremental results
        out_path = RESULTS_DIR / "sweep_results.json"
        with open(out_path, "w") as f:
            json.dump({
                "sweep_started_utc": datetime.now(timezone.utc).isoformat(),
                "results": all_results,
            }, f, indent=2)

    # Print summary table
    print("\n" + "=" * 90)
    print(f"{'Video':<35} {'Scale':>7} {'Volume':>10} {'Hull':>10} {'Cones':>6} {'Time':>6} {'Status'}")
    print("=" * 90)
    for r in all_results:
        if r.get("error") and not r.get("scale_factor"):
            status = f"ERROR: {r['error'][:30]}"
            print(f"{r['file']:<35} {'—':>7} {'—':>10} {'—':>10} {'—':>6} {r.get('elapsed_sec', 0):>5.0f}s {status}")
        else:
            vol_str = f"{r['recommended_volume_m3']:.0f}" if r.get("recommended_volume_m3") else "—"
            hull_str = f"{r['hull_volume_m3']:.0f}" if r.get("hull_volume_m3") else "—"
            scale_str = f"{r['scale_factor']:.2f}" if r.get("scale_factor") else "—"
            cones_str = f"{r['num_cones_used']}" if r.get("num_cones_used") else "—"
            status = "OK" if r.get("publishable") else ("REVIEW" if r.get("review_grade") else "BLOCKED")
            if r.get("error"):
                status = f"FAIL: {r['error'][:20]}"
            print(f"{r['file']:<35} {scale_str:>7} {vol_str:>10} {hull_str:>10} {cones_str:>6} {r.get('elapsed_sec', 0):>5.0f}s {status}")
    print("=" * 90)


if __name__ == "__main__":
    main()
