#!/usr/bin/env python3
"""Run the experimental depth-rescue path on a video."""

from __future__ import annotations

import argparse
from pathlib import Path

from stockpile.depth_rescue import DepthRescueConfig, run_depth_rescue_from_video


def main() -> int:
    parser = argparse.ArgumentParser(description="Experimental depth rescue for stockpile videos")
    parser.add_argument("video_path", type=Path, help="Path to the source video")
    parser.add_argument(
        "--workspace",
        type=Path,
        required=True,
        help="Workspace directory for extracted frames and outputs",
    )
    parser.add_argument("--cone-height-m", type=float, default=0.75)
    parser.add_argument("--density-t-per-m3", type=float, default=2.1)
    parser.add_argument("--model-name", type=str, default="depth-anything/Depth-Anything-V2-Small-hf")
    args = parser.parse_args()

    result = run_depth_rescue_from_video(
        args.video_path,
        args.workspace,
        config=DepthRescueConfig(
            model_name=args.model_name,
            cone_height_m=args.cone_height_m,
            material_density_t_per_m3=args.density_t_per_m3,
        ),
    )
    print(result.to_json())
    return 0 if result.success else 1


if __name__ == "__main__":
    raise SystemExit(main())
