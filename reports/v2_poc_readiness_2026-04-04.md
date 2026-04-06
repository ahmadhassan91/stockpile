# V2 POC Readiness — Calibration / Registration Slice

Date: 2026-04-04

## What Changed

This slice did not add more volume heuristics. Instead, it made calibration failure modes explicit:

- the pipeline now records how many cone-bearing frames were detected
- it records how many of those frames survived into registered COLMAP images
- it records the maximum number of cones visible in any one frame
- it records how many frames showed multiple cones at once
- benchmark exports now include those diagnostics
- the app surfaces clearer language when a clip is blocked by capture limits versus registration loss

The practical outcome is that the POC can now explain *why* a run is only review-grade or blocked, rather than just showing a low confidence number.

## Evidence From Sample Videos

Cone-visibility scan on the six sample videos:

| Sample | Cone Frames | Max Cones / Frame | Multi-Cone Frames | Interpretation |
| --- | ---: | ---: | ---: | --- |
| Aggregate 10-20 mm V1 | 35 | 1 | 0 | capture-limited |
| Aggregate 10-20 mm V2 | 61 | 1 | 0 | capture-limited |
| Aggregate 5-14 mm V1 | 20 | 1 | 0 | capture-limited |
| Aggregate 5-14 mm V2 | 71 | 1 | 0 | capture-limited |
| Backfill 0-75 mm V1 | 188 | 15 | 158 | registration-limited |
| Backfill 0-75 mm V2 | 14 | 2 | 1 | weak references / borderline capture-limited |

What this means:

- the aggregate clips are not primarily failing because the code cannot detect cones
- they are failing because the video never exposes more than one cone at a time, so verified multi-reference calibration is impossible on the current build
- backfill V1 is different: multiple cones are visible in the raw video, but the reconstruction still collapses before those references survive into usable calibration

## POC Position

This is now a stronger POC posture:

- we can demonstrate that the system distinguishes `verified`, `review_grade`, and `blocked`
- we can explain single-cone review-grade outcomes as capture-limited, not as unexplained model instability
- we can show that some failures are truly registration robustness issues, which gives a concrete roadmap item instead of a vague “accuracy still needs work”

Recommended client-facing capture guidance for the current build:

- keep 2-3 reference cones visible together through most of the walkaround
- keep the full toe / base boundary visible
- avoid clips where cones appear only one at a time if a verified result is expected

## Next Roadmap Slice

The next engineering slice should target registration robustness, not new volume heuristics:

1. improve survival of multi-cone frames into the final sparse model on backfill-like clips
2. add preflight or upload-stage messaging that warns when the clip never shows enough simultaneous references
3. keep the current benchmark harness as the acceptance gate: pair spread should narrow, and more cases should move from `blocked` or `review_grade` toward `verified`

## Verification

Local:

- `python -m pytest tests/test_calibration_diagnostics.py tests/test_benchmark.py tests/test_colmap_runner.py`
- result: `12 passed`

Server (isolated benchmark repo only):

- syntax pass completed for the updated pipeline, benchmark, calibration, and app files
- import-and-assert diagnostics completed successfully
- production service remained `active`
