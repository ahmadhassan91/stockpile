# V2 Sample Sweep - 2026-04-04

## Scope

Server-side benchmark sweep using the explicit COLMAP path and isolated benchmark workspace:

- Server repo: `/home/administrator/stock_pile_v2_benchmark`
- Workspace root: `/home/administrator/stock_pile_estimate/data/benchmarks_v2`
- Production service: `stockpile.service`
- Production status during sweep: `active` throughout

Benchmark settings used across the sample sweep:

- `frame_interval_sec = 0.3`
- `frame_max_frames = 220`
- `colmap_quality = low`
- `colmap_max_frames = 140`
- `colmap_use_gpu = true`
- `colmap_binary = colmap-gpu`

## Pair Results

### Aggregates 10-20 mm

- `V1`: `blocked`, `167.38 m3`
  - `num_cones_used = 1`
  - `calibration_confidence = 0.650`
  - `scale_disagreement_ratio = 2.18`
  - blocker: only `1` unique cone recovered
- `V2`: `review_grade`, `24.97 m3`
  - `num_cones_used = 1`
  - `calibration_confidence = 0.765`
  - `scale_disagreement_ratio = 1.69`
  - warning: top-surface spike
- Pair spread: `148.08%`

### Aggregates 5-14 mm

- `V1`: `review_grade`, `88.00 m3`
  - `num_cones_used = 1`
  - `calibration_confidence = 0.805`
  - `scale_disagreement_ratio = 1.50`
- `V2`: `blocked`, `168.86 m3`
  - `num_cones_used = 1`
  - `calibration_confidence = 0.755`
  - `scale_disagreement_ratio = 1.55`
  - blocker: strong spike artifact (`3.51 m` above 99th-percentile surface, `2.71x`)
- Pair spread: `62.97%`

### Non-treated Backfill 0-75 mm

- `V1`: `error`
  - failure: `COLMAP image_registrator failed with return code 1`
  - server log: `` `output_path` is not a directory ``
- `V2`: `blocked`, `181.64 m3`
  - `num_cones_used = 1`
  - `calibration_confidence = 0.347`
  - `scale_disagreement_ratio = 1.54`
  - blocker: only `1` unique cone recovered

## Findings

1. The explicit COLMAP path is materially better than the earlier fallback path, but it does not yet make paired clips agree reliably enough for client-facing confidence.
2. `V2` is not consistently better than `V1` under the current pipeline. In the sample sweep:
   - `10-20 mm`: `V2` beat `V1`
   - `5-14 mm`: `V1` beat `V2`
   - `backfill`: neither variant was publishable
3. The most common quality limit is still scale robustness from only `1` recovered cone.
4. The second recurring failure mode is geometric instability:
   - spike artifacts
   - overly large toe/hull footprint selection
5. The sample sweep also exposed a concrete code bug in the image registration recovery path for backfill `V1`.

## Fix Follow-up

A local patch was added in `stockpile/colmap_runner.py` to create the `image_registrator` and `point_triangulator` output directories before invoking COLMAP. A regression test was also added in `tests/test_colmap_runner.py`.

Local verification after the patch:

- `7 passed`

Server follow-up:

- patched `colmap_runner.py` synced into `/home/administrator/stock_pile_v2_benchmark`
- rerun launched for `backfill_0_75_v1` to verify the fix
- output dir: `/home/administrator/stock_pile_v2_benchmark/benchmark_runs/server-backfill-v1-rerun`

Backfill rerun outcome:

- the code-path error was fixed
- result changed from `error` to `blocked`
- new rerun output: `0.00 m3`, only `3` registered images, `0` pile points
- conclusion: the `image_registrator` bug was real, but the clip is still unusable under the current pipeline

## Follow-up Slices

### Toe Footprint Guard

I added a toe-footprint upper-bound guard in `stockpile/volume.py` so obviously oversized toe polygons are rejected instead of silently slipping through.

Targeted reruns:

- `aggregate_10_20_v1_guarded`
  - before: `167.38 m3`, `blocked`, footprint `178.23 m2`, source `toe_hybrid`
  - after: `158.12 m3`, `blocked`, footprint `168.99 m2`, source `toe_hybrid`
  - outcome: modest improvement only, still blocked by single-cone calibration
- `aggregate_5_14_v2_guarded`
  - before: `168.86 m3`, `blocked`, footprint `256.18 m2`, source `toe_hull`
  - after: `179.84 m3`, `blocked`, footprint `262.33 m2`, source `toe_hull`
  - outcome: no improvement; spike blocker remained dominant

Conclusion:

- the footprint guard was directionally reasonable but did not materially solve the unstable paired clips
- the worst 5-14 mm case is driven more by reconstruction instability than by the specific toe-area guard

### Spike-Trim Experiment

I then tried a narrower slice: post-segmentation pile outlier trimming in `stockpile/ground_plane.py`.

First rerun:

- `aggregate_5_14_v2_spike_trim`
  - failed with code error: `name 'config' is not defined`
  - issue was traced to a wiring bug in `stockpile/volume.py`

Corrected rerun:

- `aggregate_5_14_v2_spike_trim_fixed`
  - result: `2.44 m3`, `blocked`
  - registered images: `3`
  - pile points: `1,665`
  - footprint: `8.11 m2`, source `observed_hull`
  - blockers: single-cone calibration and `9.5x` scale disagreement

Conclusion:

- the spike-trim slice over-pruned the reconstruction and collapsed the usable geometry
- this is not a safe fix in its current form

## Recommended Next Slice

1. Keep the `image_registrator` directory fix, because it removed a real runtime failure.
2. Revert or disable the current pile outlier trim experiment; it is too aggressive.
3. Focus the next V2 slice on calibration robustness and registration quality, not more footprint heuristics.
4. Treat `1` recovered cone as an expected `review_grade` ceiling and avoid client-safe claims without at least `2` usable physical references.
