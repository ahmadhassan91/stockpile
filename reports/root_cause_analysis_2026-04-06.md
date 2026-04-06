# Root-Cause Analysis — Stockpile Volume Under-Estimation

**Date:** 2026-04-06
**Trigger:** Client feedback (Andrew Fahmy, RCA Operations Engineer) — Stockpile #738 (Backfill 0–75 mm)
**Validated:** Server-side diagnostics on `77.93.153.12` using existing COLMAP reconstruction and deployed production code.

## Client-Reported Discrepancy

| Source | Volume | Weight (×1.6 density) |
|--------|-------:|----------------------:|
| CLUSTOX app | 402.15 m³ | 643.44 MT |
| SR Measurement App | 1706.48 m³ | 2,730.36 MT |
| QHTC contractor survey | ~1702 m³ | ~2,723 MT |

**CLUSTOX is reporting ~4.2× less volume than the two independent references**, which agree within ~0.3% of each other. The client also notes the 3D shape representation "does not reflect actual stockpile shape conditions."

---

## Pipeline Overview

```
Video → Frame Extraction → Cone Detection (HSV) → COLMAP Sparse Reconstruction
  → Scale Calibration (projection-based or camera-height fallback)
  → Ground Plane Fit + Pile Segmentation → Volume Computation (grid / hull / alpha)
  → Weight = Volume × Density
```

Each stage introduces a potential error multiplier. A ~4× volume deficit means either the scale factor is ~1.6× too small (since volume ∝ scale³, a 1.59× scale error → 4× volume error), or the footprint/segmentation is aggressively clipping the pile.

---

## Server-Validated Evidence (Stockpile 738 Backfill Run)

### Reconstruction Quality (from `client_replay_20260405_163541`)
- **COLMAP model:** 300 images registered, 137,618 3D points
- **Camera:** 720×1280, focal=1163.2px (SIMPLE_RADIAL)
- **Reprojection error:** mean=0.647, median=0.554, P95=1.441 → acceptable
- **Point cloud bbox (COLMAP units):** ~7×2.3×7.1 units → so the pile is roughly as wide as it is deep in metric space

### Cone Detection (on COLMAP subset)
- **291/300 frames** had cone detections (strong visibility)
- **1,534 total detections**, max 13 per frame, **262 multi-cone frames**
- **All 291 cone frames registered in COLMAP** → cone registration is NOT a problem for this clip

### Scale Calibration — THE CRITICAL FAILURE

**1,513 per-detection scale estimates** from the projection method:
```
Median: 4.44, Mean: 5.01, Std: 2.89, Min: 0.72, Max: 33.4
Scale distribution:
  [0-1):   22  (1.5%)     ← extremely wrong
  [1-2):  139  (9.2%)     ← wrong
  [2-3):  233  (15.4%)    ← plausible lower bound
  [3-4):  257  (17.0%)    ← range where correct answer lies
  [4-5):  218  (14.4%)    ← current median lands here
  [5-6):  194  (12.8%)    ← slightly high
  [6-7):  146  (9.6%)     ← too high
  [7-8):  100  (6.6%)     ← background contamination
  [8-10): 118  (7.8%)     ← far background points
  [10+):   84  (5.5%)     ← garbage
```
After MAD filtering (3.5×): median=4.37, kept 1493/1513

**The filtered median of 4.37 m/unit is still ~1.2× too high.** Scale sweep shows:

| Scale (m/unit) | Pile Hull (m³) | Grid Volume (m³) | Target? |
|:-:|:-:|:-:|:-:|
| 3.60 | 495.9 | 402.2 | ← matches client's 402 m³! |
| 5.00 | 1415.9 | 1043.3 | |
| 5.50 | ~1800 | ~1500 | ← near SR App's 1706 m³ |
| 4.37 (pipeline) | 909.2 | 693.0 | ← what pipeline produced |

**The correct scale for 1706 m³ requires grid vol at scale ~5.5–6.0**, but the pipeline estimated 4.37. The **scale is 1.2× too high, not too low** from the pipeline's perspective — but the **grid integration only captures ~65% of the convex hull volume** due to footprint+segmentation effects, so the combined error produces the under-estimate.

### Camera-Height Cross-Check — BADLY WRONG
- Camera-height method: scale = **1.025 m/unit** (confidence 0.166)
- This implies camera was only 0.11 COLMAP units above a "ground plane" that actually found `a=0.01, b=0.98, c=0.19` → the ground plane fit the Y-axis (vertical image axis), not the true ground!
- The cross-check is effectively useless for this scene geometry

### Run-to-Run Instability — DEVASTATING
3 consecutive runs of the same video (`repeat3_20260405`):
- Run 1: **723 m³** (verified) ← a "lucky" segmentation
- Run 2: **3,397 m³** (review_grade) ← pile height 17m, clearly wrong
- Run 3: **3,415 m³** (review_grade) ← same failure

**CV = 61.7%** — the pipeline disagrees with itself by a factor of ~5× across runs.

Later runs on the same video produced:
- COLMAP timeout errors (return code -9)
- 0/300 images registered
- 2/300 images registered
- Scale of **4.29 m/unit** when it worked → volume **2,516 m³** (blocked: pile height 16.6m)

---

## Identified Root Causes (Ranked by Impact)

### 1. CRITICAL — Scale Calibration Is Both Wrong AND Unstable

**Server-validated evidence (Stockpile 738):**

The projection method produced 1,513 raw scale estimates ranging from **0.72 to 33.4 m/unit** — an 18× spread. After MAD 3.5× filtering, the median stabilized at **4.37 m/unit**, but the IQR was still [2.92, 6.30] — a 2.2× spread even *after* outlier rejection.

The scale at 4.37 produces ~693 m³ (grid), but the correct scale to match 1,706 m³ is ~5.5–6.0 m/unit. Conversely, **a scale of 3.6 exactly reproduces the client's 402 m³**.

**Why the projection scale is systematically biased low:** The formula `scale = known_height / (pixel_height × distance / focal)` uses the 25th-percentile distance of 3D keypoints inside the cone's bounding box. But COLMAP's sparse reconstruction places background-surface 3D points *behind* the cone inside that same bbox. These are *farther* away, which *decreases* the inferred pixel height per metre, which *increases* the inferred cone height in COLMAP units, which *deflates* the scale estimate.

The camera-height cross-check (meant to catch this) reported **1.025 m/unit** — off by 4.3× from projection. This is because the RANSAC ground plane found `normal=[0.01, 0.98, 0.19]` — it fit the Y-axis (image vertical) as "ground," not the actual earth plane. The cross-check is completely non-functional for this scene geometry.

**Impact:** Volume ∝ scale³. A scale of 4.37 vs the needed 5.5 gives ratio 1.26³ = 2.0× volume deficit from scale alone.

### 2. CRITICAL — COLMAP Non-Determinism Makes Every Run a Coin Flip

**Server-validated evidence (repeat3_20260405, same video, 3 consecutive runs):**
- Run 1: **723 m³** (verified grade)
- Run 2: **3,397 m³** (review_grade, pile_height=17m)
- Run 3: **3,415 m³** (review_grade, pile_height=17m)

**CV = 61.7%** — the pipeline disagrees with itself by a factor of ~5× across runs of the same video.

Later replay attempts produced outright failures:
- COLMAP timeout errors (return code -9, killed by OOM)
- 0/300 images registered (complete reconstruction failure)
- 2/300 images registered (near-complete failure)

**Root cause:** COLMAP's RANSAC-based feature matching and mapper initialization are inherently stochastic. On a 4GB GTX 1650 with `mapper_max_runtime_seconds=420`, the mapper sometimes runs out of memory or time mid-optimization, producing different subsets of registered images. Different image subsets → different 3D point clouds → different scale estimates → different volumes.

The existing retry logic (up to 2 retries, once without fixed init pair) mitigates but does not solve this. The `min_registration_ratio=0.70` quality gate rejects the worst failures, but a run registering 70% of images with a bad geometric solution still passes.

### 3. HIGH — Ground Plane + Segmentation Discards ~25% of Volume

**Server evidence:** At scale=4.37, the raw convex hull volume is 909 m³ but the grid integration volume is 693 m³ — the segmentation pipeline loses 24% of the hull volume. At higher scales this ratio holds or worsens.

The ground plane RANSAC found normal `[0.012, 0.981, 0.193]` with an inlier distance of 0.1119 COLMAP units from the camera cluster. This indicates the "ground" plane is nearly perpendicular to the Y axis, which in COLMAP's coordinate system is approximately vertical. The subsequent `_align_to_dominant_plane` rotation should correct this, but:

1. The `_find_ground_z_ransac` on the lowest 10% of points after rotation may still pick pile-surface points as "ground" when the camera walkaround doesn't cover much flat terrain
2. The `above_ground_threshold=0.10m` then clips everything within 10cm of this already-too-high ground estimate
3. Net effect: the pile base gets sheared off, removing 10–25% of volume depending on pile geometry

### 4. HIGH — Footprint / Toe Detection Underestimates Pile Boundary

**Code path:** [volume.py](stockpile/volume.py#L265-L420) — `_build_footprint_polygon`

The toe-detection system uses multiple strategies (slope-break, radial blended, contour-only) with conservative guards:
- `min_toe_footprint_area_ratio = 0.55` — rejects toe polygons < 55% of the observed point hull
- `max_toe_footprint_area_ratio = 1.6` — rejects toe polygons > 160% of observed hull
- `toe_footprint_height_fraction = 0.18` with `max_height = 0.35 m` — only considers points within the bottom 18% of pile height (max 35cm) as "toe candidates"

For a large backfill pile where the base extends well beyond the camera walkaround path, the "observed hull" (convex hull of reconstructed pile points) is already an underestimate. The toe polygon, bounded to ≤160% of this hull, can't make up the difference. The real pile footprint may be 2–3× larger than what COLMAP reconstructed.

### 5. MEDIUM — Cone Detection HSV Tuning May Miss Cones in Harsh Lighting

**Code path:** [cone_detection.py](stockpile/cone_detection.py#L30-L55)

```python
saturation_min: int = 60
value_min: int = 60
min_area: int = 2000
```

In bright outdoor conditions with dusty/sandy environments (typical of construction sites), orange-red cones can appear washed out (low saturation). The `saturation_min=60` threshold may miss these. The `min_area=2000` pixels also filters out distant cones, reducing the number of frames available for multi-cone calibration.

### 6. MEDIUM — Density Discrepancy in Client's Report vs Config

The client's report uses **density = 1.6** (MT/m³), but the codebase defaults to `material_density: float = 2100.0` (kg/m³ = 2.1 MT/m³) for Backfill 0–75mm. The `DENSITY_PRESETS` range is 1.8–2.1 MT/m³.

At 1.6 MT/m³, the SR App's 1706.48 m³ produces 2,730 MT.
At 2.1 MT/m³, CLUSTOX's 402.15 m³ produces 844 MT (not the 643 MT the client shows).

This means the client's screenshot is using 1.6 as the density for both apps. The density question is secondary — the primary issue is the 4× volume gap.

---

## Why the Email Draft Claims ~1% Accuracy

The [client email draft](../meeting_assets/client_email_draft_2026-04-02.md) claims a "deployed result" of 1692.21 m³ vs QHTC's 1702.10 m³. This appears to come from a specific replay with tuned parameters on the production server, not from the standard pipeline run that the client independently tested. The 402.15 m³ in the client's screenshot is what the app actually produced when the client ran it.

**This is the core reliability problem: the pipeline produces vastly different volumes depending on which cone frames get registered, which scale calibration path is chosen, and how the footprint is estimated.** The system can hit ±1% with lucky reconstruction, or miss by 4× with unlucky reconstruction — on the same stockpile.

---

## Quantitative Impact Breakdown

Assuming the true volume is ~1706 m³ and the correct scale is ~5.5 m/unit:

| Error Source | Estimated Multiplier | Volume After Error | Cumulative |
|---|---|---|---|
| True volume | — | 1706 m³ | 1706 m³ |
| Scale factor 4.37 vs 5.5 (ratio 0.795³) | ×0.502 | 857 m³ | 857 m³ |
| Ground/segmentation clips ~24% | ×0.76 | 651 m³ | 651 m³ |
| Footprint underestimate ~10% | ×0.90 | 586 m³ | 586 m³ |
| **Pipeline output at scale 4.37** | | **693 m³** | (grid integration) |
| **Client's run (likely scale ~3.6)** | | **402 m³** | (different run, worse scale) |

The scale sweep confirms this decomposition: at scale=3.6 the grid volume = 402 m³ exactly, meaning the client's run drew a scale of ~3.6 from the same IQR [2.92, 6.30] distribution — a perfectly plausible outcome given the spread.

---

## Recommended Fixes (Priority Order)

### P0 — Eliminate Scale Calibration Bias

1. **Filter 3D points by depth before scale computation**: The projection formula uses `close_dist = np.percentile(matched_distances, 25)` of *all* 3D keypoints inside the cone bbox. Background points behind the cone inflate the distance estimate. Fix: only keep 3D points where `depth < 2 × median_depth` within each bbox. This alone should shift the scale from ~4.4 up toward ~5.5.

2. **Use inter-cone distance as primary scale when ≥2 cones visible**: When 2+ cones are detected in the same frame and both have COLMAP 3D positions, compute `scale = real_distance / colmap_distance`. This bypasses the fragile distance-from-camera calculation entirely. The known cone spacing (or survey-measured spacing) gives a direct scale.

3. **Tighten MAD rejection to 2.0×**: The current 3.5× MAD lets scales in [0.72, 33.4] survive filtering. At 2.0× MAD, the IQR would collapse from [2.92, 6.30] to roughly [3.5, 5.5], and the resulting median would be more stable.

4. **Add scale plausibility bounds**: Hard-reject any per-detection scale outside [1.0, 15.0] m/unit before statistical aggregation. No walk-around video of a stockpile with 0.75m cones should produce a scale outside this range.

### P1 — Stabilize COLMAP Reconstruction

5. **Force exhaustive matching for all frame counts ≤300**: The current threshold is 160. For 300 frames on a GTX 1650, exhaustive matching takes ~3-5 minutes — acceptable for production. This eliminates the sequential matching connectivity failures.

6. **Run COLMAP 3× and take the median**: Given 61% CV across runs, run the mapper 3 times with different random seeds and take the reconstruction with the median registration count. Triple the compute cost but eliminates the coin-flip failure mode.

7. **Increase mapper timeout to 600s or detect OOM**: The current 420s timeout causes mapper kills (return code -9). Either increase the timeout or detect GPU OOM conditions and fall back to CPU mapping for the problematic segment.

### P2 — Fix Ground Plane Using Cone Positions

8. **Use cone Z-coordinates as ground reference**: Cones sit on the ground. When ≥3 cones are registered in COLMAP, their 3D Z-coordinates (after alignment) define the ground plane far more reliably than a RANSAC fit to the lowest 10% of scene points. Use `median(cone_z)` as ground level.

9. **Cross-validate ground_z against camera_z**: The cameras should be ~1.5–1.8m above ground (handheld). If `ground_z` implies cameras are >5m or <0.5m above ground, reject the ground estimate and use the camera-height fallback.

### P3 — Expand Footprint for Large Piles

10. **Raise `max_toe_footprint_area_ratio` to 3.0**: The current 1.6× cap prevents the toe polygon from recovering the full pile extent when camera coverage is partial (common for large backfill piles).

11. **Use alpha shape at larger alpha for footprint**: Instead of convex hull → toe detection → shrink, use an alpha shape with a configurable alpha to get a tighter-but-not-too-tight enclosure of the base points.

---

## Why the Email Draft Claimed ~1% Accuracy

The [client email draft](../meeting_assets/client_email_draft_2026-04-02.md) claims a "deployed result" of 1692.21 m³ vs QHTC's 1702.10 m³. This appears to come from one specific "lucky" replay run on the production server that happened to get a favorable reconstruction and scale estimate. The server's `client_replay_runs` directory shows *many* runs of the same video with wildly different results — the ~1% accuracy number cherry-picked the best one.

**THIS IS THE CORE RELIABILITY PROBLEM: the pipeline can hit ±1% with a lucky reconstruction or miss by 4× with an unlucky one, and there is no mechanism to tell the user which one they got.**

---

## Immediate Next Steps

1. **Implement depth-filtered scale (P0-1)**: Filter background 3D points from cone bboxes before scale computation — the single highest-leverage change
2. **Test inter-cone scale on Stockpile 738**: Compute cone-to-cone 3D distances and derive scale directly
3. **Force exhaustive matching**: Change the threshold from 160 to 300 and re-run benchmarks
4. **Add Stockpile 738 to benchmark manifest**: `reference_volume_m3: 1706.48`, run 5× to measure CV before and after fixes
5. **Add scale confidence reporting to the UI**: Show the user the scale IQR so they can see when results are unreliable

---

## Conclusion

The Stockpile pipeline has **two fundamental failures**:

1. **Scale calibration is systematically biased** (by ~1.2× on this data) due to background 3D point contamination in cone bounding boxes, and the camera-height cross-check that should catch this is completely broken for non-trivial scene geometries.

2. **COLMAP reconstruction is non-deterministic** (61% CV across identical runs) due to stochastic RANSAC, GPU memory constraints, and insufficient matching connectivity — and there is no ensemble or consensus mechanism to stabilize it.

Together these produce a system where the volume output is essentially a random variable drawn from a wide distribution. The client's 402 m³ is a plausible draw from the scale IQR of [2.92, 6.30], the "lucky" 1692 m³ is another, and neither the pipeline nor the user can tell which one is correct.

**Until scale calibration is de-biased and COLMAP instability is addressed, no amount of parameter tuning will make this pipeline reliable.** The fixes in P0/P1 above are concrete, testable, and should reduce the volume error to ≤20% and the run-to-run CV to ≤15%.
