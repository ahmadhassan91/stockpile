# Native iOS Production Plan

## Goal

Build an iPhone-first production path for stockpile capture that solves the client's real concerns, not just the current demo path:

- the field workflow is too fragile and confusing in Streamlit
- weak captures can still enter processing without enough structure
- result trust is too opaque when scale or coverage is marginal
- backend state is not durable enough for production mobile use

We are not rebuilding the measurement stack from zero. We are keeping the geometry and measurement core that already works on strong inputs, moving field capture to native iOS, making tagged references a first-class production input, and redesigning the backend contract so uploads, jobs, diagnostics, and results are durable and auditable.

This remains an iOS-only plan. Android is intentionally out of scope for this phase.

## Current QPMC Alpha Gate

For the immediate internal shipping decision, use [docs/qpmc-testflight-alpha-readiness.md](docs/qpmc-testflight-alpha-readiness.md) as the source of truth.

For local operator and developer setup, use [docs/ios-real-alpha-local-startup.md](docs/ios-real-alpha-local-startup.md) as the startup and environment handoff.

For Release/TestFlight build settings, signing overrides, and staging backend expectations, use [docs/qpmc-testflight-build-handoff.md](docs/qpmc-testflight-build-handoff.md).

The short version:

- keep the native live-capture path, background upload path, and `verified` / `review_only` / `blocked` review model
- do not ship a QPMC alpha in presentation or demo mode
- treat backend durability and honest review states as part of alpha scope, not post-alpha polish
- treat Apple signing, App Store Connect setup, and TestFlight packaging as separate release prerequisites even when the app already builds for simulator and unsigned device

## Production Decision

### What We Keep

These backend assets remain the right foundation and should stay:

| Current asset | Decision | Why |
| --- | --- | --- |
| `stockpile/pipeline.py` | Keep as the processing spine | It already sequences the major reconstruction and measurement stages. |
| `stockpile/frame_extraction.py` | Keep | Video-to-frame extraction is still the right primitive. |
| `stockpile/colmap_runner.py` | Keep | We should not rebuild the reconstruction engine during the mobile shift. |
| `stockpile/ground_plane.py` | Keep | Ground-plane logic remains part of the measurement core. |
| `stockpile/volume.py` | Keep | Volume and weight calculation stay in the backend measurement layer. |
| `stockpile/calibration_diagnostics.py` | Keep and expand | It is the right place to expose explainable calibration diagnostics. |
| `stockpile/ai_preflight.py` | Keep as advisory only | It can help with hints, but it must not become the authority for reportability. |

### What Must Be Rewritten or Materially Refactored for Production Accuracy

These are the areas we cannot simply wrap and ship:

| Current area | Action | Why this is required for accuracy and client trust |
| --- | --- | --- |
| Streamlit upload and session flow | Rewrite | The field workflow cannot depend on browser state, page refresh behavior, or Streamlit session assumptions. |
| User-facing "upload a video" workflow | Rewrite as native live capture | Operators need a guided walkaround, not an open-ended file upload tool. |
| `stockpile/cone_detection.py` contract | Refactor into a production tagged-reference contract | The product promise must be about required tagged references with known size and placement expectations, not incidental red-cone detection. |
| `stockpile/scale_calibration.py` release gating | Rewrite confidence and acceptance rules | Verified results must depend on tagged-reference visibility and calibration agreement, not best-effort reconstruction alone. |
| Backend orchestration around runs | Rewrite as capture session, upload, job, and result services | Production mobile needs durable IDs, resumable uploads, job polling, and auditability. |
| Result schema | Rewrite and expand | Operators need `verified`, `review_only`, and `blocked` outcomes with human-readable blockers and machine-readable diagnostics. |
| Field language and documentation | Rewrite for production truth | Client-facing docs should say tagged references, guided walkaround, and honest review gates. |

## How This Plan Solves the Client's Concerns

| Client concern | Production answer | What the client gets |
| --- | --- | --- |
| Field workflow is awkward and fragile | Replace Streamlit with native iPhone capture and background upload | One guided flow with reliable recording, upload, retry, and session resume |
| Accuracy is too dependent on operator guesswork | Make tagged references mandatory for release-grade runs and guide for them live | A clear scale anchor instead of a loosely controlled upload process |
| Weak videos still reach processing | Add live capture gating and backend quality gates for references, coverage, and motion | Fewer misleading results and more honest early recapture calls |
| Result trust is opaque | Return explicit `verified`, `review_only`, or `blocked` outcomes with diagnostics | Clear release decisions instead of vague confidence-only messaging |
| Web app state is too entangled with processing | Move to a durable backend run model independent of Streamlit | A backend that is production-safe for mobile and easier to audit |

## Tagged References Are the Accuracy Contract

Tagged references are the clearest answer to the client's accuracy concern.

- Production should standardize on three tagged references per run, with at least two visible together through the sweep whenever possible.
- User-facing language should say tagged references. Internally, the short-term detector can still bootstrap from the current cone-based implementation, but the contract must be about known references with known dimensions and expected placement behavior.
- Tagged references give the iPhone app something objective to guide:
  - keep two to three references recurring in frame
  - widen the angle if references are isolated
  - avoid finishing the run before reference coverage is established
- Tagged references also give the backend something objective to verify:
  - how many references were detected
  - how often the visibility goal was met
  - whether scale stayed consistent
  - whether the run should be `verified`, `review_only`, or `blocked`

Production implication: if reference visibility or calibration agreement is too weak, the system should not present a clean final number. It should force `review_only` or `blocked`.

## Native Capture Is the Input Quality Fix

Native iOS is not just a UX upgrade. It is the mechanism that makes higher-quality inputs more likely.

- Replace browser upload with AVFoundation-based live walkaround capture.
- Record structured run metadata alongside the movie:
  - site, pile, and material selection
  - app build and device context
  - lens selection and timestamps
  - duration and upload provenance
- Surface live operator guidance before upload begins:
  - tagged reference visibility
  - perimeter and toe coverage
  - motion stability
- Support background upload, retry, and resume as production requirements rather than polish items.

This directly answers the usability concern and also improves input consistency before the backend spends time processing weak footage.

## Backend Redesign Is Not Optional

The backend cannot simply expose the current Streamlit pages through new endpoints. We need a durable mobile runtime model.

### Production backend entities

- `CaptureSession`
- `Upload`
- `ProcessingJob`
- `Result`
- `ReferenceDiagnostics`
- `CaptureQualityDiagnostics`

### Required backend changes

- decouple worker execution from Streamlit session state
- persist every run with durable IDs from capture session through final result
- separate upload state from processing state
- store tagged-reference visibility and calibration diagnostics
- return human-readable blockers and machine-readable quality data
- keep the web portal for QA, benchmark review, reporting, and admin, but not as the field capture controller

This is the redesign that makes TestFlight alpha, pilot runs, and eventual production supportable.

## Production Architecture

### iOS app

Responsibilities:

- create the capture session
- guide the live walkaround
- collect capture metadata
- record the movie
- upload in the background
- poll job state
- display results and recapture guidance

### Mobile API layer

Responsibilities:

- authorize the capture session
- create upload authorization
- persist mobile run metadata
- create or attach processing jobs
- expose job and result endpoints
- return reference-aware diagnostics

### Processing workers

Responsibilities:

- extract frames
- detect tagged references
- reconstruct geometry
- calibrate scale
- compute volume and weight
- produce diagnostics and release outcome

### Web portal

Responsibilities:

- admin
- QA
- benchmarking
- report viewing
- historical run comparison

## Production Rules

These rules should be treated as non-negotiable:

- Streamlit must not remain the main field workflow.
- A `verified` result must mean release-grade confidence, not just "the pipeline finished."
- `review_only` must mean a measurement exists but still needs a human release decision.
- `blocked` must mean the run should be recaptured and must not be treated as report-grade.
- AI preflight may advise, but it must never override failed reference or calibration gates.
- LiDAR stays optional. It can improve confidence on supported devices, but it must not be the baseline requirement.

## Delivery Plan

## Phase 0: Production Contract and Reference Standard

Duration: 1 week

Work:

- freeze the iOS field workflow
- define the tagged-reference standard
- lock the `verified` / `review_only` / `blocked` semantics
- finalize the backend reuse versus rewrite map

Exit criteria:

- agreed production vocabulary
- agreed reference placement expectations
- signed-off mobile contract direction

## Phase 1: Backend Decoupling and Durable Run Model

Duration: 2 weeks

Work:

- separate worker execution from Streamlit assumptions
- create durable capture session, upload, job, and result records
- expose stable mobile endpoints
- persist reference and calibration diagnostics cleanly

Exit criteria:

- one end-to-end backend path that works without Streamlit state
- stable IDs across session, upload, job, and result
- clear upload versus processing state

## Phase 2: Native iOS Capture Alpha

Duration: 2 to 3 weeks

Work:

- native app shell and run setup
- live walkaround capture
- background upload and retry
- job polling
- result screen wiring

Exit criteria:

- capture, upload, processing, and result flow from iPhone
- no browser dependency for field use

## Phase 3: Tagged-Reference Guidance and Accuracy Gating

Duration: 2 weeks

Work:

- live tagged-reference visibility checks
- perimeter and motion gating
- calibration acceptance rewrite
- blocked and review-only thresholds tied to reference evidence

Exit criteria:

- weak reference coverage is surfaced before or during processing
- verified runs are demonstrably reference-backed
- blocked runs explain why recapture is required

## Phase 4: Review Workflow and Pilot Readiness

Duration: 1.5 to 2 weeks

Work:

- operator-friendly result review
- confidence and blocker language
- report handoff to web
- instrumentation and field telemetry
- pilot packaging

Exit criteria:

- TestFlight alpha suitable for controlled field trials
- clear operator action on every terminal outcome

## Timeline

Realistic iOS-first delivery window:

- backend-decoupled alpha: 4 to 5 weeks
- TestFlight pilot candidate: 8 to 10 weeks

This assumes we keep the measurement core and do not rebuild reconstruction from zero.

## Team Recommendation

Minimum team:

- 1 iOS engineer
- 1 backend / pipeline engineer
- 1 product / QA owner

Preferred team:

- 1 senior iOS engineer
- 1 backend / CV engineer
- 1 product / UX owner
- shared QA support

## Primary Risks

- current calibration instability on weak captures
- weak or inconsistent tagged-reference visibility in real field conditions
- queue and worker reliability under repeated mobile runs
- upload resilience on poor networks

## Risk Mitigation

- make tagged references a required production contract
- guide capture before upload, not only after upload
- separate provisional progress from terminal release outcome
- keep explicit `review_only` and `blocked` paths
- instrument the backend so every failed run is diagnosable

## Success Criteria

This phase is successful if:

- field users can complete capture without Streamlit or browser confusion
- every run has a durable session, upload, job, and result record
- weak captures are blocked or held for review instead of producing misleading "finished" outputs
- verified runs can point to tagged-reference-backed calibration evidence
- upload and polling remain reliable on poor connectivity
- the client can clearly see why native capture plus tagged references produce a more trustworthy workflow

## Immediate Next Steps

1. Lock the tagged-reference field standard and placement guidance.
2. Freeze the production mobile API surface.
3. Split worker execution from Streamlit assumptions.
4. Finish the live native capture path before spending more time on demo-only flows.
5. Validate the new thresholds against strong and weak real sample captures.
