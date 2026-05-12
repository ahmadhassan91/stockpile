# QPMC TestFlight Build Handoff

This is the practical build and distribution handoff for getting the iOS alpha from local workspace to a real QPMC TestFlight candidate.

Use this together with:

- [docs/qpmc-testflight-alpha-readiness.md](docs/qpmc-testflight-alpha-readiness.md)
- [docs/ios-real-alpha-local-startup.md](docs/ios-real-alpha-local-startup.md)

Release helper scripts now available:

- [ios/archive-qpmc-alpha.sh](../ios/archive-qpmc-alpha.sh)
- [ios/export-qpmc-testflight.sh](../ios/export-qpmc-testflight.sh)

## What Changed In The Project

The iOS project now moves a little closer to distributable behavior:

- Debug and Release both now default to the tracked HTTPS mobile API unless you override them at launch or archive time
- Release now bakes in operational runtime defaults through generated Info.plist keys
- signing team, bundle identifier, marketing version, and build number can be overridden as build settings at archive time instead of editing tracked project files
- the app configuration now falls back from process environment to bundle Info.plist values, which is what makes a staged Release/TestFlight configuration meaningful
- the app now surfaces internal-alpha backend status on launch, so testers can see when the build is checking, connected, or misconfigured before starting a capture
- background upload relaunch events are now bridged back into the upload pipeline, so interrupted handoffs are less dependent on a manual cold-start recovery path

This does not solve full production configuration management. It does make the alpha path more honest than “works only when launched from Xcode with ad hoc env vars.”

## Minimum Handoff Packet

The person creating the archive should hand off this exact metadata with the `.xcarchive` or uploaded build:

| Field | Required note |
| --- | --- |
| App version / build | Exact `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` used for the archive |
| Bundle identifier | Expected App Store Connect bundle ID |
| Git revision | Commit SHA or release branch reference |
| Archive owner and date | Who produced the build and when |
| Apple team used | Team ID or team name used for signing |
| Release API base URL | The mobile API host baked into the build |
| Auth mode | Anonymous, bearer token, or custom header |
| Validation devices | Physical iPhone models and iOS versions used before upload |
| Known issues | Short list of accepted alpha gaps |

## Build Configuration Matrix

| Build configuration | Default runtime target | Intended use |
| --- | --- | --- |
| `Debug` | tracked alpha API at `https://stockpile.theclustox.com/api/mobile` unless overridden in the scheme | local simulator and workspace bring-up |
| `Release` | current tracked alpha API at `https://stockpile.theclustox.com/api/mobile` | device validation, archive preparation, TestFlight candidate builds |

Runtime defaults now come from generated Info.plist keys, so:

- scheme environment variables still win when you set them explicitly
- Release no longer has to fall back to localhost if no scheme env vars are present
- Release also no longer carries a tracked review-presentation default, backup-import default, or configured fallback-capture default

## Build Settings You Can Override Without Editing The Repo

These settings are now safe to override through `xcodebuild`, CI variables, or local Xcode build settings:

- `STOCKPILE_DEVELOPMENT_TEAM`
- `STOCKPILE_PRODUCT_BUNDLE_IDENTIFIER`
- `STOCKPILE_MARKETING_VERSION`
- `STOCKPILE_BUILD_NUMBER`
- `STOCKPILE_API_BASE_URL`
- `STOCKPILE_API_BEARER_TOKEN`
- `STOCKPILE_API_AUTH_HEADER_NAME`
- `STOCKPILE_API_AUTH_HEADER_VALUE`

Examples:

```bash
xcodebuild \
  -project ios/StockpileCaptureApp.xcodeproj \
  -scheme StockpileCaptureApp \
  -configuration Release \
  -destination "generic/platform=iOS" \
  archive \
  -archivePath build/StockpileCaptureApp.xcarchive \
  STOCKPILE_DEVELOPMENT_TEAM=ABCDE12345 \
  STOCKPILE_MARKETING_VERSION=0.1.0 \
  STOCKPILE_BUILD_NUMBER=12
```

If staging auth uses a bearer token:

```bash
STOCKPILE_API_BEARER_TOKEN=replace-me
```

If staging auth uses a custom header:

```bash
STOCKPILE_API_AUTH_HEADER_NAME=x-api-key
STOCKPILE_API_AUTH_HEADER_VALUE=replace-me
```

If the alpha candidate needs a different reachable backend than the repo default, override it intentionally and record the exact value in the handoff packet:

```bash
STOCKPILE_API_BASE_URL=https://example-alpha-host/api/mobile
```

## Staging Backend Expectations

The TestFlight candidate backend should meet these expectations before external operator testing:

- reachable from real iPhones over HTTPS
- implements the real `/api/mobile` routes used by the app
- accepts large `PUT` uploads for walkaround movies without assuming browser session state
- persists capture sessions, uploads, jobs, and results with durable identifiers
- runs background processing through a worker model that survives web process restarts
- returns terminal `verified`, `review_only`, or `blocked` results with honest diagnostics
- exposes the same auth contract the app is configured to send

The staging backend should not depend on:

- localhost reachability
- Xcode scheme env vars
- single-process in-memory or thread-only job ownership
- seeded presentation results

## Signing Checklist

Before archiving a TestFlight build:

- confirm `./ios/check-testflight-readiness.sh` passes with zero `FAIL`
- if the script emits `WARN`, write down the intentional answer before continuing
- confirm `STOCKPILE_DEVELOPMENT_TEAM` resolves to the correct Apple Developer team
- confirm the bundle identifier is the one registered in App Store Connect
- confirm the App Store Connect record exists and matches the bundle ID
- confirm build number and marketing version are set intentionally
- confirm the Release build points at the intended reachable alpha API, not localhost and not an accidental stale host
- confirm release launch mode is operational, live camera is on, mock results are off, backup import is off, and configured fallback capture is off
- confirm you are not archiving with legacy demo overrides or fallback-capture overrides
- confirm archive uses the `Release` configuration

Treat these overrides as disallowed for a QPMC alpha candidate archive:

- `STOCKPILE_LAUNCH_MODE=review_presentation`
- legacy `STOCKPILE_REVIEW_PRESENTATION=YES`
- `STOCKPILE_USE_MOCK_RESULTS=YES`
- `STOCKPILE_ENABLE_BACKUP_VIDEO_IMPORT=YES`
- `STOCKPILE_ENABLE_CONFIGURED_FALLBACK_CAPTURE=YES`
- `STOCKPILE_CAPTURE_FILE_PATH`
- `STOCKPILE_CAPTURE_FILE_URL`

## Preflight Command

Run this before archiving:

```bash
./ios/check-testflight-readiness.sh
```

That script checks the generated project and Release build settings for:

- stale XcodeGen output versus `ios/project.yml`
- tracked config leakage of legacy presentation settings or fallback-capture defaults
- signing style
- team ID presence
- bundle identifier
- version/build number
- Release environment and API base URL
- launch mode, live-camera, and no-fallback defaults
- privacy usage strings and export-compliance key
- background upload session ID and processing poll interval
- archive configuration
- auth-setting completeness
- archive-oriented Release settings such as dSYM generation and product validation

Interpret the output like this:

- `FAIL`: do not archive yet
- `WARN`: archive is still possible, but the answer must be explicit in the handoff packet
- `PASS`: safe default is already in place

## XcodeGen Workflow

When `ios/project.yml` changes:

```bash
./ios/generate-project.sh
```

Then re-run:

```bash
./ios/check-testflight-readiness.sh
```

If the generated project is older than the spec, the preflight script now treats that as a blocker. Archive only from a regenerated project.

## Archive Command Pattern

Typical archive flow without committing secrets:

```bash
STOCKPILE_DEVELOPMENT_TEAM=ABCDE12345 \
STOCKPILE_BUILD_NUMBER=12 \
STOCKPILE_MARKETING_VERSION=0.1.0 \
STOCKPILE_API_BASE_URL=https://stockpile.theclustox.com/api/mobile \
STOCKPILE_API_BEARER_TOKEN=replace-me \
./ios/archive-qpmc-alpha.sh
```

If staging auth uses a custom header instead:

```bash
STOCKPILE_DEVELOPMENT_TEAM=ABCDE12345 \
STOCKPILE_BUILD_NUMBER=12 \
STOCKPILE_MARKETING_VERSION=0.1.0 \
STOCKPILE_API_BASE_URL=https://stockpile.theclustox.com/api/mobile \
STOCKPILE_API_AUTH_HEADER_NAME=x-api-key \
STOCKPILE_API_AUTH_HEADER_VALUE=replace-me \
./ios/archive-qpmc-alpha.sh
```

The archive script will:

- regenerate the Xcode project
- run the readiness check
- refuse to continue if the required signing/build inputs are missing
- produce a Release `.xcarchive` under `ios/build/`

## Export Command Pattern

Once the archive exists, export the candidate for Xcode Organizer / Transporter handoff:

```bash
STOCKPILE_DEVELOPMENT_TEAM=ABCDE12345 \
./ios/export-qpmc-testflight.sh ios/build/StockpileCaptureApp.xcarchive
```

This generates an app-store export under `ios/build/export/`.

After the archive completes, record the values you actually used in the handoff packet above.

## Remaining Gaps Before A Real TestFlight Alpha

These changes improve the build path, but they do not remove the real alpha blockers:

- team ID and auth secrets are still injected manually or in CI; they are not centrally managed yet
- the staging backend still needs durable worker execution and HTTPS reachability from real devices
- the app still needs full device-side validation against real capture, upload, processing, and review outcomes
- App Store Connect submission, tester groups, release notes, and export-compliance answers still need to be completed

## Post-Upload Handoff

Once the build is uploaded, hand the tester or release owner:

- the TestFlight build number
- the handoff packet metadata
- the staging backend or auth assumptions used for the build
- known issues that affect capture, upload, processing, or terminal review interpretation
- the expected operator path: live capture, upload, wait, and review outcome

## Bottom Line

The project now has a better separation between local Debug bring-up and Release/TestFlight candidate behavior.

That is a real step forward, but not the end of the job. The last mile is still operational: real staging backend, real signing setup, real device validation, and a signed archive that proves the app can run outside the comfort of Xcode. 
