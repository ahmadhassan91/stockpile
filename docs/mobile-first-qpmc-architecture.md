# QPMC Mobile-First Architecture

## Goal

Build a native iPhone-first stockpile measurement system that feels operationally close to SR:

- guided live capture in app
- fast provisional result for field use
- verified/reviewed result after backend checks
- tagged physical references for scale reliability
- backend confidence and review workflow instead of silent guesswork

The target for pilot validation is **high consistency with a strong benchmark pack**, not a blind promise that every run will achieve a fixed accuracy number on day one. Internally, we should treat **90%+ agreement within the accepted pilot tolerance band** as the goal for tagged-reference captures, then prove it with benchmark data.

## What We Keep

These parts of the current system are still useful:

- upload/job/result orchestration
- durable run status and confidence state handling
- 3D visualization and report packaging
- some geometry/volume utilities
- iOS app shell, brand system, and result/review UI foundation

Keep these as infrastructure, not as the final measurement truth path.

## What We Replace

These parts should no longer be the primary production measurement path:

- generic web-style video upload as the main operator workflow
- generic cone-color detection as the main scale source
- COLMAP-heavy reconstruction as the only path to a usable result
- publishing weak runs as if they were normal outputs

The old reconstruction pipeline remains valuable for:

- benchmarking
- fallback analysis
- comparison against the mobile-first path
- forensic review on hard captures

## Product Workflow

### 1. Live guided capture

The operator should not browse for a file in the normal path.

The app should:

- open directly into live capture
- guide perimeter movement
- require tagged references to be visible together
- check toe/base coverage while recording
- monitor motion/orientation quality
- stop the operator from finishing a weak capture too early

### 2. Provisional result

Immediately after capture:

- upload starts in background
- the backend produces a fast provisional result
- the operator sees:
  - provisional volume
  - confidence band
  - benchmark cross-check required / not required
  - recapture-required if capture is weak

### 3. Verified result

After deeper backend checks:

- promote the run to `verified`
- or hold it as `review_only`
- or block it as `recapture_required`

This split is important. It is how we get a field-friendly experience without pretending every fast result is fully verified.

## Tagged References

The production path should use **tagged physical references**, not generic red cones.

Recommended options:

- AprilTag sleeves on cones
- ArUco boards on stands
- branded tagged reference panels with known physical dimensions

Required characteristics:

- known identity
- known physical size
- recoverable in multiple frames
- trackable across the walkaround

Why this matters:

- scale becomes reference-aware instead of color/shape guesswork
- the same physical marker can be tracked across frames
- quality gates can explicitly fail when too few valid tags are recovered

## iPhone Sensor Usage

The new path should be mobile-first in a real sense, not just "upload from a phone."

Use:

- `AVFoundation` for capture
- `ARKit` for device pose and camera transform
- `CoreMotion` for motion/orientation quality
- camera intrinsics / metadata from the device
- `LiDAR` when available as an enhancement, not a hard dependency

### LiDAR role

LiDAR should help with:

- provisional depth prior
- ground plane sanity checks
- toe visibility confidence
- faster short-range mesh preview

It should not be mandatory for pilot use, because device coverage will vary.

## Backend Services

The production backend should be split into explicit services:

### Capture ingestion service

Responsible for:

- accepting mobile capture uploads
- storing capture metadata
- storing device pose telemetry
- storing tagged reference observations
- queueing measurement jobs

### Provisional measurement service

Fast path built for operator speed:

- uses tagged references
- uses device pose
- uses toe/coverage heuristics
- returns provisional volume + confidence + reasons

### Verification service

Slower, stricter path:

- cross-check provisional result
- compare scale signals
- compare against benchmark history where available
- produce final `verified`, `review_only`, or `recapture_required`

### Benchmark and review service

Supports:

- side-by-side benchmark review
- operator notes
- acceptance/rejection
- audit trail

## Confidence Model

Confidence should not be a single vague number.

Track at least:

- tagged reference recovery quality
- scale agreement quality
- toe visibility quality
- motion stability quality
- perimeter coverage quality
- geometry consistency quality

The app should translate those into a clear operator state:

- `verified`
- `review_only`
- `recapture_required`

## Old Backend vs New Backend

### Old path

- video-first
- cone-first
- reconstruction-heavy
- slow
- fragile on hard clips

### New path

- mobile capture first
- tagged-reference first
- device-pose aware
- provisional result first
- verified result second
- reconstruction as support, not the only truth engine

## Phased Build Plan

### Phase 1: Mobile-first alpha

- live capture in iOS app
- tagged reference workflow
- background upload
- real backend capture ingestion
- provisional result states
- verified/review/recapture workflow

### Phase 2: Accuracy hardening

- benchmark pack evaluation
- scale solver tuning
- toe/ground confidence improvements
- ARKit/LiDAR-assisted checks
- repeatability validation

### Phase 3: Pilot operations

- TestFlight rollout
- site/material presets
- benchmark comparison UX
- operator review queue
- PDF/reporting export

## Definition Of Success For QPMC Alpha

The alpha is ready for QPMC testing when all of the following are true:

- capture starts and ends entirely in app
- upload happens automatically in background
- provisional result returns without manual file handling
- weak runs are blocked or held for review, not silently published
- tagged references are part of the capture and scaling path
- at least one benchmark pack shows materially better consistency than the old cone-only path

## Current Recommendation

Treat the current COLMAP-heavy backend as:

- benchmark support
- fallback analysis
- comparison harness

Treat the new mobile-first system as the product path:

- native iPhone guided capture
- tagged references
- device-pose aware provisional estimate
- verified backend review

