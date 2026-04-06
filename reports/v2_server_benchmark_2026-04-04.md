# V2 Server Benchmark Report

Date: 2026-04-04
Environment: `77.93.153.12` (`stockpile`)
Production safety: `stockpile.service` remained active during all benchmark runs.

## Goal

Validate whether V2 changes improve reconstruction and scale robustness on the complaint clip without touching the client-facing production app.

## Clip Under Test

- Video: `/home/administrator/agg_5_14_v1.mp4`
- Material: `Aggregates 5-14 mm`

## Summary

The best trustworthy result on this clip is now:

- Status: `review_grade`
- Recommended volume: `89.13 m3`
- Scale source: `projection`
- Calibration confidence: `0.805`
- Cones used: `1`
- COLMAP images: `140`
- COLMAP points: `75,447`
- Pile points: `27,042`
- Grid occupancy: `25.78%`

This is a material improvement over the previous blocked runs, which were falling back to camera-height scale and producing unstable volumes.

## Run History

### 1. Heavy GPU Wrapper Run

- Output: `benchmark_runs/server-single-gpu`
- Result: `error`
- Notes:
  - Long-running reconstruction stalled.
  - No usable sparse model produced.

### 2. Fast Diagnostic Run

- Output: `benchmark_runs/server-fastdiag`
- Result: `blocked`
- Volume: `2.93 m3`
- Notes:
  - Too sparse to trust.
  - Only `73` pile points reconstructed.
  - Only `1` cone reference recovered.

### 3. Balanced Run

- Output: `benchmark_runs/server-balanced`
- Result: `blocked`
- Volume: `37.13 m3`
- Notes:
  - Reconstruction improved, but cone recovery collapsed to `0`.
  - Still fell short of reliable scale.

### 4. Dense Low Run

- Output: `benchmark_runs/server-dense-low`
- Result: `blocked`
- Volume: `190.50 m3`
- Notes:
  - Density improved, but scale still fell back to `camera_height`.
  - Volume swung too high.

### 5. Dense Low Priority Run

- Output: `benchmark_runs/server-dense-low-priority`
- Result: `blocked`
- Volume: `254.82 m3`
- Notes:
  - Preserved all cone frames in the subset.
  - COLMAP still failed to register them under the old automatic flow.

### 6. Dense Low Explicit Run

- Output: `benchmark_runs/server-dense-low-explicit`
- Result: `review_grade`
- Volume: `89.13 m3`
- Notes:
  - Replaced the opaque `automatic_reconstructor` path with explicit:
    - `feature_extractor`
    - `exhaustive_matcher`
    - `mapper`
  - Registered all `20` cone-bearing frames.
  - Switched scale calibration from `camera_height` fallback to `projection`.

## Key Technical Findings

1. The biggest failure was not lack of GPU.
   The earlier issue was that COLMAP was not registering the cone-bearing views under the automatic path.

2. Cone-frame preservation alone was not enough.
   Keeping cone frames in the subset fixed one bug, but the automatic reconstruction path still dropped those frames during registration.

3. The explicit COLMAP path fixed the real bottleneck.
   Once feature extraction, matching, and mapping were run explicitly, all cone frames survived into the registered model.

4. This clip still appears limited to one trustworthy physical reference.
   Relaxing cone detection found extra red-object clusters, but calibration confidence dropped sharply and the extra clusters were not trustworthy enough for verified reporting.

## Current Interpretation

This clip is now good enough for:

- internal comparison
- review-grade reporting
- side-by-side investigation of client complaints

This clip is still not strong enough for:

- a fully verified client-facing result without cross-check

Reason:

- only `1` unique cone reference survived as a trustworthy calibration anchor
- scale cross-check disagreement remains about `1.56x`

## Code Changes Behind The Improvement

- `stockpile/colmap_runner.py`
  - replaced automatic COLMAP reconstruction with explicit sparse reconstruction steps
  - preserved cone-priority frames in the COLMAP subset
  - added step-level logs for feature extraction, matching, mapping, and registration
- `stockpile/pipeline.py`
  - passes cone-priority frames into reconstruction
- `tests/test_colmap_runner.py`
  - added coverage for cone-priority subsetting and quality mapping

Local verification:

- `6` tests passed in the project virtualenv

## Recommended Next Slice

1. Keep the explicit COLMAP path as the new V2 benchmark baseline.
2. Use it on the next client complaint clip as soon as another video is available.
3. Treat this clip as review-grade only.
4. Add or enforce operator guidance that verified-grade runs need at least `2` physically usable cone references.

## Bottom Line

V2 improved substantially on the complaint clip.

The best run moved from blocked, camera-height-driven, and unstable to review-grade, projection-scaled, and geometrically much denser.

The remaining limitation is now the capture itself, not the reconstruction pipeline.
