# iOS Real-Alpha Local Startup

This is the operator/developer handoff for running the native iOS alpha flow against the real local mobile backend.

It covers the smallest honest local stack that can exercise:

- live capture from the iPhone app
- capture-session creation
- upload authorization
- upload handoff into the backend
- job polling
- result and review-state fetch

## What This Startup Path Actually Uses

The repo now has a real local mobile API path:

- `stockpile/mobile_api_app.py`
  FastAPI app for the mobile contract
- `stockpile/mobile_api_service.py`
  durable file-backed session, upload, job, and result store
- `stockpile/mobile_job_runtime.py`
  in-process background runtime that starts the existing stockpile pipeline after upload finalization
- `scripts/run_mobile_api_dev_server.py`
  convenience launcher for the FastAPI app via uvicorn

This is not a mock server anymore. Finalized uploads go through the real mobile API and trigger the real pipeline runtime in a background thread.

## What This Gives You Locally

- real FastAPI HTTP routes for the iOS app
- real upload persistence under `data/mobile_api/`
- real background processing attempts through the existing pipeline
- real job-state progression based on pipeline callbacks
- real terminal outcomes produced from the pipeline result model

## What This Still Is Not

This local path is useful for alpha integration, but it is not a production backend.

It still has important limits:

- job execution is in-process and thread-based, not a durable worker queue
- active jobs do not survive server restarts
- persistence is JSON files on local disk, not a database/object-store deployment
- auth is minimal and environment-variable-based
- localhost HTTP is for local development only, not for TestFlight distribution

## Prerequisites

- Python 3.10 to 3.12
- repo virtualenv with dependencies installed
- COLMAP installed and on `PATH`

Recommended setup:

```bash
cd /Users/clustox1/Documents/Stockpile/stockpile-calibration-readiness
python3.12 -m venv .venv
source .venv/bin/activate
pip install -e .
brew install colmap
```

Notes:

- if COLMAP is missing, uploads can still be accepted, but processing will fail once the pipeline starts
- use a project virtualenv rather than a random system Python; if the local scientific stack is mis-installed for the machine architecture, the API can boot while real processing still fails on the first pipeline import
- tagged-reference detection uses the OpenCV runtime available in the repo environment; weak or missing tag support should be treated as a processing-quality issue, not as proof that the API path is broken

## Start The Real Local Mobile API

Recommended launcher:

```bash
cd /Users/clustox1/Documents/Stockpile/stockpile-calibration-readiness
source .venv/bin/activate
export STOCKPILE_MOBILE_API_BASE_URL=http://127.0.0.1:8000/api/mobile
export STOCKPILE_MOBILE_UPLOAD_BASE_URL=http://127.0.0.1:8000/api/mobile/uploads
export STOCKPILE_MOBILE_PIPELINE_WORKSPACE_ROOT=data/mobile_runs
python scripts/run_mobile_api_dev_server.py --host 127.0.0.1 --port 8000 --reload
```

Direct uvicorn alternative:

```bash
cd /Users/clustox1/Documents/Stockpile/stockpile-calibration-readiness
source .venv/bin/activate
uvicorn stockpile.mobile_api_app:create_app --factory --host 127.0.0.1 --port 8000 --reload
```

## Real FastAPI Routes

The local FastAPI app exposes:

- `GET /health`
- `POST /api/mobile/capture-sessions`
- `POST /api/mobile/uploads`
- `PUT /api/mobile/uploads/{uploadId}/content`
- `POST /api/mobile/uploads/{uploadId}/finalize`
- `GET /api/mobile/jobs/{jobId}`
- `GET /api/mobile/results/{runId}`

Important differences from the older simulated path:

- there is no `/healthz`
- there is no `/api/mobile/uploads/authorize` compatibility alias
- `PUT /api/mobile/uploads/{uploadId}/content` starts the real local background processing runtime

## Local Backend Environment Variables

### Core API service

- `STOCKPILE_MOBILE_API_ROOT`
  Default: `data/mobile_api`
  Root for persisted sessions, uploads, jobs, results, and uploaded objects.

- `STOCKPILE_MOBILE_API_BASE_URL`
  Default: `http://localhost:8000/api/mobile`
  Public-facing API base used in generated responses.

- `STOCKPILE_MOBILE_UPLOAD_BASE_URL`
  Default: `{STOCKPILE_MOBILE_API_BASE_URL}/uploads`
  Base used for generated `uploadUrl` values.

- `STOCKPILE_REPORT_BASE_URL`
  Optional.
  If set, terminal results include a `reportUrl`.

- `STOCKPILE_MOBILE_SESSION_TTL_HOURS`
  Default: `6`

- `STOCKPILE_MOBILE_UPLOAD_TTL_MINUTES`
  Default: `30`

### Auth

- `STOCKPILE_MOBILE_API_BEARER_TOKEN`
  Optional.
  If set, the FastAPI app requires `Authorization: Bearer <token>`.

- `STOCKPILE_MOBILE_API_KEY`
  Optional.
  If set, the FastAPI app requires `x-api-key: <value>`.

### Background processing runtime

- `STOCKPILE_MOBILE_PIPELINE_WORKSPACE_ROOT`
  Default: `data/mobile_runs`
  Workspace root for per-job pipeline output.

## Expected iOS Configuration

For the app to stay on the real live-capture alpha path, keep it in operational mode and point every backend URL at the FastAPI app explicitly.

### Build configuration defaults

The generated project now carries bundle-backed defaults:

- `Debug` defaults to the local mobile API at `http://127.0.0.1:8000/api/mobile`
- `Release` defaults to the staging mobile API at `https://staging-api.theclustox.com/stockpile/api/mobile`

That helps device validation and archive prep because Release no longer needs scheme env vars just to avoid falling back to localhost.

Scheme environment variables still override those bundled defaults when you set them explicitly.

### Minimum scheme env vars for simulator

```text
STOCKPILE_ENVIRONMENT=Local
STOCKPILE_LAUNCH_MODE=operational
STOCKPILE_USE_LIVE_CAMERA=1
STOCKPILE_REVIEW_PRESENTATION=0
STOCKPILE_USE_MOCK_RESULTS=0
STOCKPILE_API_BASE_URL=http://127.0.0.1:8000/api/mobile
STOCKPILE_CAPTURE_SESSIONS_URL=http://127.0.0.1:8000/api/mobile/capture-sessions
STOCKPILE_UPLOAD_AUTHORIZATION_URL=http://127.0.0.1:8000/api/mobile/uploads
STOCKPILE_PROCESSING_JOBS_URL=http://127.0.0.1:8000/api/mobile/jobs
STOCKPILE_RESULTS_URL=http://127.0.0.1:8000/api/mobile/results
```

Useful optional env vars:

```text
STOCKPILE_UPLOADS_BASE_URL=http://127.0.0.1:8000/api/mobile/uploads
STOCKPILE_CLIENT_BUILD=ios-local-alpha
```

### Auth mapping between backend and app

If the FastAPI backend uses a bearer token:

```text
STOCKPILE_MOBILE_API_BEARER_TOKEN=local-dev-token
STOCKPILE_API_BEARER_TOKEN=local-dev-token
```

If the FastAPI backend uses an API key:

```text
STOCKPILE_MOBILE_API_KEY=local-dev-key
STOCKPILE_API_AUTH_HEADER_NAME=x-api-key
STOCKPILE_API_AUTH_HEADER_VALUE=local-dev-key
```

### Upload authorization route

The operational app config now defaults upload authorization to:

- `POST {STOCKPILE_UPLOADS_BASE_URL}`

That matches the real FastAPI route:

- `POST /api/mobile/uploads`

Setting `STOCKPILE_UPLOAD_AUTHORIZATION_URL` explicitly is still fine, but it is no longer required just to reach the correct endpoint.

## Physical iPhone Note

Do not point a physical iPhone or TestFlight-style run at `127.0.0.1`.

For device testing you need a backend address the phone can actually reach, such as:

- a Mac LAN IP with a reachable port
- or an HTTPS tunnel / reverse proxy

Current practical guidance:

- treat plain `http://127.0.0.1` as simulator-only
- prefer HTTPS for device testing
- the current iOS project does not declare obvious ATS exceptions for arbitrary local HTTP hosts, so assume a reachable HTTPS path is the safer device-side choice

## Quick Smoke Test

1. Start the FastAPI server.
2. Confirm `GET /health` returns `{"status":"ok"}`.
3. Launch the app in operational mode with live camera enabled.
4. Start a live walkaround run.
5. Confirm the app creates a capture session and obtains upload authorization from `/api/mobile/uploads`.
6. Finish the recording and let the app upload the movie to `/api/mobile/uploads/{uploadId}/content`.
7. Watch the app poll `/api/mobile/jobs/{jobId}` as the local pipeline runtime advances or fails the job.
8. Confirm the app fetches `/api/mobile/results/{runId}` when a terminal result is available.

Important:

- use a real walkaround movie if you want meaningful processing behavior
- dummy upload bytes are useful for route validation, but they will usually fail once the real pipeline starts

## Data You Can Inspect Locally

The local backend writes:

- `data/mobile_api/capture_sessions/*.json`
- `data/mobile_api/uploads/*.json`
- `data/mobile_api/jobs/*.json`
- `data/mobile_api/results/*.json`
- `data/mobile_api/objects/<uploadId>/...`
- `data/mobile_runs/<jobId>/...`

This is the fastest way to inspect what the app sent, what the backend persisted, and where processing failed.

## What Still Remains Before A Real TestFlight Alpha

This local FastAPI path is real enough for local integration, but it is still not the TestFlight backend story.

The main remaining gaps are:

- move from in-process thread workers to a durable staged worker runtime
- make active jobs resumable across backend restarts
- move from file-backed local persistence to a real staging data model and storage layout
- provide a stable HTTPS-accessible backend path for physical iPhone and TestFlight validation
- move from local and archive-time config overrides to a cleaner staged configuration and secret-management story
- validate real tagged-reference runs against field footage, not only local bring-up
- finish signing, App Store Connect, and archive/upload readiness

## Recommended Handoff Sequence

1. Use this real FastAPI path to validate the app’s live capture, upload, polling, and error handling.
2. Use real sample footage to confirm the local pipeline can produce meaningful terminal states.
3. Move the same contract onto a reachable staging backend with durable worker execution.
4. Re-run the full operator flow on physical iPhone hardware over HTTPS.
5. Only then treat the build as a serious TestFlight alpha candidate.

## Before You Archive

Run the iOS preflight:

```bash
./ios/check-testflight-readiness.sh
```

For signing and staging/TestFlight build details, use [docs/qpmc-testflight-build-handoff.md](docs/qpmc-testflight-build-handoff.md).
