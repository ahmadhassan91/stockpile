# QPMC TestFlight Alpha Readiness

As of 2026-04-21, this is the internal readiness plan for the first QPMC TestFlight build of the native iPhone app.

The target build is not a demo shell. It is a controlled alpha that must support:

- real live walkaround capture on iPhone
- upload from the recorded run
- processing progress that distinguishes upload from backend work
- terminal review states of `verified`, `review_only`, or `blocked`

For local operator and developer bring-up, use [docs/ios-real-alpha-local-startup.md](docs/ios-real-alpha-local-startup.md) as the startup and environment reference.

For signing, staged Release defaults, and archive-time overrides, use [docs/qpmc-testflight-build-handoff.md](docs/qpmc-testflight-build-handoff.md).

Archive/export helpers are now available in:

- [ios/archive-qpmc-alpha.sh](../ios/archive-qpmc-alpha.sh)
- [ios/export-qpmc-testflight.sh](../ios/export-qpmc-testflight.sh)

## Alpha Scope

This alpha should prove one honest operational story:

1. an operator starts a real live capture run on iPhone
2. the app records and uploads that run without browser or Streamlit dependency
3. the backend processes the run with durable session, upload, job, and result state
4. the operator lands in a clear review outcome with the right next action

This alpha does not need to promise full production hardening yet. It does need to prove that the product has moved off the demo path and onto a real field workflow.

## Honest Status Snapshot

### Exists in the repo and Release config today

- Release defaults to `operational`, not presentation mode.
- Release defaults to live camera capture with mock results off.
- Release explicitly keeps backup video import and configured fallback capture off.
- The tracked iOS config no longer exports the legacy `STOCKPILE_REVIEW_PRESENTATION` build setting.
- Release points at `https://stockpile.theclustox.com/api/mobile` over HTTPS, not localhost.
- Release carries an upload background session identifier and processing poll interval.
- Privacy usage strings and export-compliance metadata are present.
- The shared scheme archives with the `Release` configuration.

### Still blocks a real TestFlight candidate

- A real Apple Developer team still has to be injected at archive time.
- The current tracked build number is still the starter value and needs an intentional external-test increment.
- Auth is still blank in the tracked Release config if staging requires it.
- The archive owner still has to confirm that the baked Release API host is the intended alpha backend, or override it intentionally at archive time and record that choice.
- The repo does not itself prove a signed archive, an App Store Connect record, or a successful upload to TestFlight.
- The repo does not itself prove one no-mock physical iPhone run from capture through terminal result.
- Any archive built with demo/review overrides or file-backed capture overrides is not a QPMC alpha candidate.

### Still needed for QPMC external testing

- One signed uploaded build tied to the real App Store Connect app.
- One successful physical-device run with capture session ID, upload ID, processing job ID, and terminal result ID recorded.
- At least one upload interruption and relaunch validation on-device.
- Operator evidence for `verified`, `review_only`, and `blocked` using real backend results.
- A short known-issues list and tester instructions for the first QPMC cohort.

## Readiness Gate Classes

Use three gate classes so the team does not confuse "not committed in git" with "safe to ignore."

| Gate class | Meaning | Examples |
| --- | --- | --- |
| Blocking now | Must be true before archiving or handing a build to QPMC testers | Release still points at localhost, Review Presentation is on by default, live camera is off, privacy keys are missing, generated Xcode project is stale, or the app has not completed one real device run |
| Warning to close in handoff | Repo-safe values may be blank, but the archive owner must intentionally fill or confirm them | Apple team ID, staging auth secrets, first distributable build number, known-issues list |
| Evidence to record | Not a config failure, but required for a credible alpha handoff | archive version/build, commit SHA, backend base URL, tester device matrix, screenshots or notes for `verified`, `review_only`, and `blocked` |

## What The Script Can And Cannot Prove

`./ios/check-testflight-readiness.sh` is a Release-config gate, not a field-validation gate.

It can prove:

- the generated project is in sync with `ios/project.yml`
- Release defaults are operational, live-camera, no-mock, and no-fallback
- the tracked iOS config no longer exports the legacy review-presentation setting
- the Release API target is HTTPS and non-local
- privacy, export-compliance, upload-session, poll, and archive settings exist

It cannot prove:

- real backend reachability from a physical iPhone
- successful upload/background resume behavior on-device
- durable processing completion and final result fetch
- operator clarity for `verified`, `review_only`, and `blocked`
- successful App Store Connect upload or external tester setup

## Explicitly Not A QPMC Alpha Candidate

The following modes may still exist for local demos, previews, or bring-up, but they are not valid for QPMC external testing:

- `STOCKPILE_LAUNCH_MODE=review_presentation`
- legacy `STOCKPILE_REVIEW_PRESENTATION=YES`
- legacy `STOCKPILE_USE_MOCK_RESULTS=YES`
- `STOCKPILE_ENABLE_BACKUP_VIDEO_IMPORT=YES`
- `STOCKPILE_ENABLE_CONFIGURED_FALLBACK_CAPTURE=YES`
- file-backed operational fallback via `STOCKPILE_CAPTURE_FILE_PATH` or `STOCKPILE_CAPTURE_FILE_URL`

If any of those are active, the build may still be useful internally, but it should be treated as demo or local bring-up behavior, not as the real alpha path.

## What Is Ready Now

| Area | Status | Ready now |
| --- | --- | --- |
| Native live capture path | Ready for alpha validation | The iOS stack now includes a real AVFoundation-backed camera session with permission handling, session lifecycle, recording control, and live preview wiring. |
| Capture-first app direction | Mostly ready | The app shell and capture flow are already being pushed toward live walkaround capture instead of file-first demo framing. |
| Upload runtime | Ready for alpha validation | The upload pipeline supports background-capable `URLSession` behavior, progress, and retry semantics suitable for device testing. |
| Processing and review states | Ready in product model | The app and API contract already support `verified`, `review_only`, and `blocked` terminal states rather than one vague success state. |
| Production contract direction | Ready | The current docs already align on tagged references, native capture, durable backend entities, and honest result diagnostics. |
| App packaging baseline | Partially ready | The project already has a bundle identifier, privacy usage strings, Release runtime defaults, and successful simulator plus unsigned device builds. |

## What Must Still Be True Before QPMC TestFlight

These are the remaining gates for a credible internal alpha.

### 1. Launch in operational live mode, not presentation mode

- The TestFlight configuration must open on the operational live-capture path by default.
- Presentation or seeded review modes may still exist for internal demos, but they cannot be the default experience for QPMC alpha testers.
- File-backed operational fallback may exist for local bring-up, but it cannot stand in for live in-app capture when validating the QPMC alpha story.
- Any copy that implies the operator should start from a pre-supplied capture file should be removed or clearly treated as fallback-only behavior.

### 2. Prove one real end-to-end run against the target backend

- The app must successfully create a capture session.
- The recorded movie must upload through the intended mobile upload path.
- The backend must create or attach a processing job with durable IDs.
- The app must poll job state and fetch a real result payload.
- The final review state shown in-app must come from the real backend result, not seeded presentation data.
- The backend path used for TestFlight must not rely only on the single-process local FastAPI bring-up described in the local startup doc.

### 3. Validate the live-capture run on physical iPhone hardware

- camera permission prompt and denied-permission handling
- rear-camera preview and start/stop recording flow
- recording save and handoff into upload
- upload continuation across app backgrounding and relaunch
- progress transitions from upload to processing
- terminal result display for `verified`, `review_only`, and `blocked`

### 4. Confirm alpha-grade review behavior

- `verified` must mean release-grade enough for controlled alpha review
- `review_only` must mean a measurement exists but still needs human release judgment
- `blocked` must mean recapture is required and the app says so plainly
- operator-facing review copy must describe why the run landed in that state and what to do next

### 5. Lock the minimum operational telemetry

- capture session ID
- upload ID
- processing job ID
- terminal result ID or run ID
- enough logs or diagnostics to explain a failed upload, failed poll, or blocked run after field testing

## Ready Versus Remaining

### Keep for the first QPMC alpha

- native iPhone app shell
- real live camera capture path
- upload, polling, and review-state flow
- backend measurement core
- tagged-reference-aware result semantics

### Do not treat as done yet

- field-proven tagged-reference reliability across varied site conditions
- final release thresholds for every material and pile shape
- broad operational hardening for weak networks and repeated long-run usage
- production-grade support tooling and QA dashboards

## Signing and TestFlight Prerequisites

The codebase is close enough to build for device, but Apple distribution setup is not done yet.

### Already present in the project

- bundle identifier: `com.clustox.stockpile.capture`
- automatic signing is enabled in project settings
- Release build settings now carry operational live-capture defaults instead of falling back to localhost, presentation mode, or file-seeded capture
- privacy usage strings are present for camera, location, and photo-library export
- upload and processing runtime identifiers are present in the Release configuration
- simulator build succeeds
- unsigned `Release` iPhoneOS build succeeds

### Still required before upload to TestFlight

- set the correct Apple Developer team in the Xcode project
- ensure the App Store Connect app exists for `com.clustox.stockpile.capture`
- confirm a valid iOS distribution signing setup for the bundle identifier
- archive a signed `Release` build instead of an unsigned validation build
- increment version and build numbers for the first distributable alpha
- confirm that `https://stockpile.theclustox.com/api/mobile` is the intended reachable alpha backend, or override `STOCKPILE_API_BASE_URL` intentionally during archive
- prepare internal tester group, release notes, and a short known-issues list
- complete App Store Connect submission metadata and export-compliance answers
- move from localhost-only or dev-tunnel bring-up to a reachable staging backend path with durable worker execution and HTTPS that physical iPhone testers can use reliably
- inject real auth values for the staging backend at archive time if the staged API is not anonymous

### Packaging hygiene to check during archive

- run `./ios/check-testflight-readiness.sh` and clear every `FAIL`
- treat script `WARN` output as assigned handoff work, not as noise
- confirm the app’s supported orientations are valid for the intended device support policy
- verify entitlements and background behavior match the actual alpha scope
- verify privacy copy matches the real live-capture experience
- confirm export-compliance metadata, background upload session ID, and poll settings are still aligned with the Release build

## Alpha Evidence Packet

Every QPMC alpha candidate should ship with a small evidence packet so the build is traceable after upload:

- app version and build number
- bundle identifier
- Git commit SHA or tagged branch
- archive date and archive owner
- Release API base URL and auth mode used for the build
- physical test devices and iOS versions used for validation
- one completed real capture run with its capture session ID, upload ID, job ID, and terminal result ID if available
- notes or screenshots for the operator experience in `verified`, `review_only`, and `blocked`
- known issues and explicit test gaps still accepted for the alpha

## Recommended Go / No-Go Checklist

Ship the QPMC TestFlight alpha only when all of the following are true:

- `./ios/check-testflight-readiness.sh` exits successfully
- any remaining script warnings have an owner and an intentional archive-time answer
- the default build path is operational live capture, not demo presentation
- the archive was not created with demo/review overrides or file-backed capture overrides
- one end-to-end live run succeeds from capture through final result on physical iPhone
- upload interruption and app relaunch have been tested at least once
- `verified`, `review_only`, and `blocked` each render with clear operator guidance
- the backend returns durable identifiers and honest status transitions
- Apple team signing and App Store Connect setup are complete
- a signed archive is produced, and the evidence packet above is ready for internal distribution

## Recommended Sequence This Week

1. Freeze the TestFlight target behavior to operational live capture only.
2. Run `./ios/check-testflight-readiness.sh` and clear any Release-config blockers.
3. Assign any remaining warnings such as team ID, auth injection, or intentional build number to the person creating the archive.
4. Run physical-device end-to-end validation against the target backend environment.
5. Fix any blockers in upload, polling, or terminal review-state presentation.
6. Fill in Apple team signing and App Store Connect configuration, then archive/upload for a small internal tester group.

## Bottom Line

The project is past the point of being only a presentation shell. It now has the right alpha ingredients: real live capture, background-capable upload, durable processing states, and explicit review outcomes.

The remaining work is not “build the app from scratch.” It is to lock the operational path, validate it on real devices and real backend state, and complete Apple distribution setup so QPMC receives an honest TestFlight alpha instead of another demo build.
