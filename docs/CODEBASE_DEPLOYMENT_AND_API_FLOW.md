# Stockpile Codebase, Deployment, and API Flow

Last traced: 2026-06-27, Asia/Karachi.

This document explains what codebase is currently active, what problem it solves, how the iOS app talks to the backend, what is deployed on the server, and where the repository structure is blended.

## Executive Summary

The current working code is a monorepo/worktree that contains:

- The native iOS LiDAR capture app.
- The new v2 LiDAR backend used for `.stockpilecapture` bundle uploads.
- The legacy COLMAP/Streamlit stockpile estimator.

The live app is configured to use:

- Legacy mobile API paths under `https://stockpile.theclustox.com/api/mobile` for operational/session/recent-run style surfaces.
- New v2 LiDAR paths under `https://stockpile.theclustox.com/api/v2` for markerless `.stockpilecapture` upload, result fetch, and job fetch.

The current deployed v2 backend is not COLMAP. It is a FastAPI service that uses iPhone/ARKit LiDAR depth, RGB frames, ARKit poses, Open3D TSDF fusion, ground segmentation, volume calculation, and quality gates.

## Active vs Legacy Map

Use this table before touching code. It is the shortest answer to "what is active and what is legacy?"

| Path or surface | Status | Meaning | Deploy for v2? |
| --- | --- | --- | --- |
| `ios/` | ACTIVE | Native iOS LiDAR capture app. Builds `Stockpile Capture` for device/TestFlight. | Yes, app side |
| `ios/StockpileCaptureApp/` | ACTIVE | Main app shell, capture feature, History tab, runtime config. | Yes, app side |
| `ios/StockpileCaptureKit/` | ACTIVE | Swift packages for capture, upload, mobile API models, result UI. | Yes, app side |
| `stockpile-lidar-backend/` | ACTIVE | FastAPI v2 backend for `.stockpilecapture` uploads and LiDAR TSDF processing. | Yes, backend side |
| `stockpile-lidar-backend/stockpile_lidar/` | ACTIVE | Python package serving `/api/v2/*`. | Yes |
| `docs/CODEBASE_DEPLOYMENT_AND_API_FLOW.md` | ACTIVE DOC | Current handoff for app/backend/deployment/API flow. | Reference |
| `AGENTS.md` | ACTIVE DOC | Short agent handoff and root ownership hints. | Reference |
| `stockpile/` | LEGACY | Older cone/COLMAP/shared Python estimator. Not the v2 LiDAR API. | No |
| `app/` | LEGACY | Older Streamlit web UI for legacy estimator. Not the native app. | No |
| root `README.md` | LEGACY DOC | Describes the older video/cone/COLMAP/Streamlit workflow. | No |
| `/api/v2/*` | ACTIVE | Current markerless LiDAR backend API used by iOS upload/result flow. | Yes |
| `/api/mobile/*` | LEGACY/TRANSITIONAL | Older mobile API surface still referenced by operational shell/recent-run code. | Not for new v2 processing |
| public `/` on server | LEGACY | Proxies to Streamlit legacy web app. | No |

Rule of thumb:

- New iOS capture work goes in `ios/`.
- New backend processing work goes in `stockpile-lidar-backend/`.
- Do not modify or deploy `stockpile/` or `app/` for v2 LiDAR unless the task explicitly says "legacy COLMAP" or "Streamlit".

## Problem We Are Solving

The product goal is to measure stockpile volume and weight from field captures using an iPhone LiDAR workflow.

The active v2 workflow solves these specific problems:

1. Capture a site stockpile with the native iOS app using ARKit/LiDAR.
2. Persist a replayable `.stockpilecapture` bundle for every successful upload.
3. Process the captured RGB/depth/pose bundle on the backend.
4. Produce a backend volume estimate in cubic meters.
5. Multiply volume by selected material density to produce weight.
6. Classify the result as `verified`, `review_only`, or `rejected`.
7. Return a mobile-friendly result payload that the iOS app can show and store in History.

Important field issue being handled:

- The old result-only/in-memory workflow made it difficult to replay and tune field runs.
- The v2 backend now persists uploaded `.stockpilecapture` bundles under server storage so real field captures can be replayed.

## Repository Status

### Git Remote

Active worktree:

```text
/Users/clustox1/Documents/Stockpile/stockpile-calibration-readiness
```

Git remote:

```text
origin https://github.com/ahmadhassan91/stockpile.git
```

Active branch:

```text
reliability-p0-fixes
```

Latest local/pushed commit at trace time:

```text
2a58a72 Auto-save successful captures to history
```

The worktree `.git` file points into the main repo worktree storage:

```text
/Users/clustox1/Documents/Stockpile/stockpile-calibration-readiness/.git
-> /Users/clustox1/Documents/Stockpile/stockpile/.git/worktrees/stockpile-calibration-readiness
```

### Current Monorepo Shape

```text
stockpile-calibration-readiness/
|-- AGENTS.md
|-- README.md
|-- app/
|-- docs/
|-- ios/
|   |-- StockpileCaptureApp.xcodeproj
|   |-- StockpileCaptureApp/
|   |-- StockpileCaptureKit/
|   |-- project.yml
|   |-- check-testflight-readiness.sh
|   |-- archive-qpmc-alpha.sh
|   `-- export-qpmc-testflight.sh
|-- stockpile-lidar-backend/
|   |-- pyproject.toml
|   |-- README.md
|   |-- stockpile_lidar/
|   `-- tests/
|-- stockpile/
|-- scripts/
`-- tests/
```

### What Each Root Means

`ios/`

- Native iOS app root.
- This is the app that captures `.stockpilecapture` bundles.
- Xcode project: `ios/StockpileCaptureApp.xcodeproj`.
- App source: `ios/StockpileCaptureApp/Sources`.
- Shared Swift packages: `ios/StockpileCaptureKit/Sources`.
- TestFlight/archive scripts live here.

`stockpile-lidar-backend/`

- New v2 backend root.
- This is the backend that accepts `.stockpilecapture` bundles.
- It is a Python/FastAPI package named `stockpile_lidar`.
- This is the code path that should be deployed for `/api/v2/*`.

`stockpile/`

- Legacy/shared Python stockpile estimator code.
- The root README still describes the older cone/COLMAP/Streamlit flow.
- Do not confuse this with the active v2 LiDAR API.

`app/`

- Streamlit app for the legacy estimator.
- Public site root currently proxies to Streamlit.
- Not the native iOS app.

## Should We Split Repositories?

The current repository works as a monorepo, but it is blended. That creates confusion because iOS, v2 backend, and legacy COLMAP code live together.

Recommended options:

### Option A - Keep Monorepo, Improve Boundaries

Keep one GitHub repo, but make boundaries strict:

```text
ios/                         native iOS app only
stockpile-lidar-backend/     v2 LiDAR backend only
stockpile/                   legacy/shared Python only
app/                         legacy Streamlit UI only
docs/                        handoff and architecture docs
```

Use this if:

- One team is moving quickly across app and backend.
- We want one branch/PR to contain coordinated iOS + backend changes.
- We can keep docs and AGENTS.md clear.

### Option B - Split Into Separate Repos

Create separate repos:

```text
stockpile-ios
stockpile-lidar-backend
stockpile-legacy-colmap
```

Use this if:

- EC2 deployment should pull only backend code.
- TestFlight/iOS should not carry backend/legacy noise.
- Future agents keep confusing Streamlit/COLMAP code with v2 LiDAR code.
- CI/CD needs separate release pipelines.

Recommended practical path:

1. Keep the current monorepo for now.
2. Add clear docs and deployment scripts.
3. When EC2 migration starts, create a clean `stockpile-lidar-backend` repo or subtree split.
4. Move iOS to its own repo later if TestFlight/app work becomes independent.

## Live Server Deployment

Server:

```text
77.93.153.12
hostname: stockpile
public host: stockpile.theclustox.com
```

Live v2 backend directory:

```text
/home/administrator/stockpile-lidar-backend
```

Live process:

```text
/home/administrator/stockpile-lidar-backend/.venv/bin/uvicorn \
  stockpile_lidar.api.main:create_app \
  --factory \
  --host 127.0.0.1 \
  --port 8002
```

Nginx public route:

```text
https://stockpile.theclustox.com/api/v2/* -> http://127.0.0.1:8002/api/v2/*
```

Health:

```text
GET https://stockpile.theclustox.com/api/v2/health
```

Response:

```json
{"status":"ok","service":"stockpile-lidar-backend"}
```

Operational warning:

- A `stockpile-lidar.service` systemd unit exists.
- At trace time, systemd reported the unit inactive.
- The currently running v2 backend was started manually/nohup.
- During EC2 migration, run this under systemd or Docker, not manual nohup.

## Live Server Ports

Active ports observed:

```text
443  nginx public HTTPS
80   nginx HTTP redirect
8002 v2 LiDAR backend on 127.0.0.1
8000 legacy mobile API on 0.0.0.0
```

Public path mapping:

```text
/api/v2/*      -> v2 LiDAR backend, port 8002
/api/mobile/*  -> legacy/mobile API, port 8000
/              -> Streamlit legacy app
```

## iOS App Endpoint Configuration

Configured in:

```text
ios/project.yml
```

Current important settings:

```yaml
STOCKPILE_API_BASE_URL: https://stockpile.theclustox.com/api/mobile
STOCKPILE_CAPTURE_BUNDLE_SUBMISSION_URL: https://stockpile.theclustox.com/api/v2/captures
STOCKPILE_LAUNCH_MODE: operational
STOCKPILE_USE_LIVE_CAMERA: YES
STOCKPILE_USE_MOCK_RESULTS: NO
STOCKPILE_ENABLE_LIDAR_ASSIST: YES
```

The generated Xcode project also contains:

```text
STOCKPILE_API_BASE_URL = https://stockpile.theclustox.com/api/mobile
STOCKPILE_CAPTURE_BUNDLE_SUBMISSION_URL = https://stockpile.theclustox.com/api/v2/captures
```

Runtime configuration source:

```text
ios/StockpileCaptureApp/Sources/Support/StockpileAppConfiguration.swift
```

The app reads:

```text
STOCKPILE_MOBILE_API_BASE_URL
STOCKPILE_API_BASE_URL
STOCKPILE_CAPTURE_BUNDLE_SUBMISSION_URL
STOCKPILE_CAPTURE_BUNDLE_SUBMISSION_TIMEOUT_SECONDS
STOCKPILE_API_BEARER_TOKEN
STOCKPILE_API_AUTH_HEADER_NAME
STOCKPILE_API_AUTH_HEADER_VALUE
```

If `STOCKPILE_CAPTURE_BUNDLE_SUBMISSION_URL` is not set, the app derives:

```text
/api/v2/captures
```

from the configured API host.

## Endpoints Used By The App

### v2 LiDAR Endpoints

These are the important markerless/LiDAR endpoints.

#### Upload capture bundle

```http
POST https://stockpile.theclustox.com/api/v2/captures
Content-Type: multipart/form-data
```

Multipart field:

```text
bundle = <capture.stockpilecapture ZIP>
```

Headers sent by iOS:

```text
X-Stockpile-Capture-Mode: markerless
X-Stockpile-Capture-ID: <capture id>
X-Stockpile-Site-ID: <site id>
X-Stockpile-Material-Code: <sand|gravel|backfill|aggregate|soil|other>
X-Stockpile-Density-Kg-Per-M3: <integer density>
X-Stockpile-Pile-Size-Mode: <optional pile size mode>
Authorization: Bearer <optional>
<custom auth header>: <optional>
```

Implemented in iOS:

```text
ios/StockpileCaptureKit/Sources/StockpileUploadPipeline/StockpileCaptureBundleSubmission.swift
```

Backend route:

```text
stockpile-lidar-backend/stockpile_lidar/api/routes/captures.py
```

Success response:

```json
{
  "captureId": "ios-...",
  "jobId": "uuid",
  "resultId": "uuid",
  "status": "completed",
  "resultLabel": "verified",
  "provisional": false
}
```

#### Fetch result

```http
GET https://stockpile.theclustox.com/api/v2/results/{resultId}
```

The iOS app derives this URL from the capture upload URL by replacing the path with:

```text
/api/v2/results/{resultId}
```

Implemented in:

```text
ios/StockpileCaptureApp/Sources/Features/Capture/CaptureFeatureStore.swift
```

Backend route:

```text
stockpile-lidar-backend/stockpile_lidar/api/routes/results.py
```

Important limitation:

- Results are stored in process memory in `RESULT_STORE`.
- If the backend restarts, old `resultId` values can 404.
- The uploaded `.stockpilecapture` bundle is persisted and can still be replayed.

#### Fetch job

```http
GET https://stockpile.theclustox.com/api/v2/jobs/{jobId}
```

The iOS app derives this URL from the capture upload URL by replacing the path with:

```text
/api/v2/jobs/{jobId}
```

Backend route:

```text
stockpile-lidar-backend/stockpile_lidar/api/routes/jobs.py
```

Current backend behavior:

- The v2 backend runs synchronously in the `POST /captures` request.
- `JOB_STORE` is in-memory.
- Jobs are lightweight completion records, not durable async workers yet.

#### Health

```http
GET https://stockpile.theclustox.com/api/v2/health
```

Nginx maps this to:

```text
http://127.0.0.1:8002/health
```

### Legacy Mobile Endpoints

The app still has a configured legacy/mobile base URL:

```text
https://stockpile.theclustox.com/api/mobile
```

The Swift operational API layer can use these families:

```text
POST/GET /api/mobile/capture-sessions
POST/GET /api/mobile/uploads
GET      /api/mobile/jobs/{jobId}
GET      /api/mobile/results/{runId}
GET      /api/mobile/runs/recent
GET      /api/mobile/health
GET      /api/mobile/healthz
GET      /api/mobile/readyz
```

Implementation root:

```text
ios/StockpileCaptureKit/Sources/StockpileMobileAPI/
```

Important interpretation:

- The markerless LiDAR bundle path uses v2.
- Some operational shell/recent-run/backend-status code still references `/api/mobile`.
- This is why the app currently points at both `/api/mobile` and `/api/v2`.

## v2 Backend Code Shape

Backend package:

```text
stockpile-lidar-backend/stockpile_lidar/
```

Important modules:

```text
api/main.py                    FastAPI app factory and health route
api/routes/captures.py         POST /api/v2/captures
api/routes/results.py          GET /api/v2/results/{resultId}
api/routes/jobs.py             GET /api/v2/jobs/{jobId}
ingestion/bundle_unpacker.py   .stockpilecapture ZIP validation and unpacking
fusion/tsdf_fusion.py          Open3D TSDF RGB/depth/pose fusion
pipeline.py                    Main measurement orchestration
segmentation/ground_plane.py   Ground plane alignment and pile segmentation
volume.py                      Volume computation
quality/gates.py               verified/review/rejected grading
measurement/core.py            NumPy fallback measurement helpers
config.py                      Tunable geometry and quality config
```

FastAPI prefix:

```python
API_V2_PREFIX = "/api/v2"
```

Mounted routers:

```text
/api/v2/captures
/api/v2/jobs
/api/v2/results
```

## v2 Capture Upload Flow

Full request flow:

```text
iOS ARKit capture
  -> creates .stockpilecapture ZIP
  -> POST /api/v2/captures multipart/form-data
  -> nginx
  -> uvicorn 127.0.0.1:8002
  -> FastAPI captures route
  -> save upload to temp file
  -> unpack and validate bundle
  -> apply authoritative header overrides
  -> persist original .stockpilecapture under data/captures/
  -> run LidarPipeline.process_capture()
  -> store result in RESULT_STORE
  -> store job in JOB_STORE
  -> return captureId/jobId/resultId/resultLabel
  -> iOS fetches /api/v2/results/{resultId}
  -> iOS maps backend payload into result screen model
  -> successful verified/review result auto-persists into History
```

## `.stockpilecapture` Bundle Shape

The backend expects a ZIP with:

```text
manifest.json
poses.json
rgb/
depth/
```

Optional:

```text
confidence/
anchors.json
```

Manifest fields used by backend include:

```text
schema_version
frame_count
material_code
density_kg_per_m3
depth_dtype
rgb width/height
depth width/height
tracking_state_summary
on_device_quick_estimate
pile_size_mode
```

Supported material codes:

```text
sand
gravel
backfill
aggregate
soil
other
```

Backend density validation:

```text
100 <= density_kg_per_m3 <= 3500
```

Bundle persistence path on live server:

```text
/home/administrator/stockpile-lidar-backend/data/captures/
```

Persisted filename pattern:

```text
YYYYMMDDTHHMMSSZ-<capture_id>.stockpilecapture
```

## Measurement Pipeline Flow

Current v2 measurement flow:

```text
Unpacked capture bundle
  -> fuse RGB + depth + ARKit poses using Open3D TSDF
  -> extract metric point cloud
  -> optional ROI crop using phone quick footprint
  -> read ARKit/ground anchors from anchors.json
  -> segment ground and pile
  -> compute volume
  -> assess quality gates
  -> build mobile result payload
```

### 1. TSDF Fusion

File:

```text
stockpile_lidar/fusion/tsdf_fusion.py
```

Inputs:

```text
RGB JPEG frames
Float16 depth frames
ARKit camera transforms
ARKit intrinsics
optional confidence frames
```

Defaults:

```text
voxel_size: 0.02 m
sdf_trunc: 0.04 m
depth_trunc: 6.0 m
confidence_min: 1
```

Frames are skipped when:

```text
tracking_state is not normal
lidar_active is false
RGB/depth is missing
depth cannot be decoded
pose transform/intrinsics are invalid
```

### 2. ROI Crop

File:

```text
stockpile_lidar/pipeline.py
```

Function:

```text
_crop_point_cloud_to_capture_roi()
```

Purpose:

- Reduce far yard/background points.
- Use phone quick estimate footprint as a soft spatial crop.
- Avoid cropping if it would remove too much or if no footprint estimate exists.

Diagnostics returned in result:

```text
roi_crop_applied
roi_crop_input_points
roi_crop_output_points
roi_crop_removed_points
roi_crop_radius_m
roi_crop_center_x
roi_crop_center_y
roi_crop_footprint_area_m2
```

Important field observation:

- Some recent bundles had `on_device_quick_estimate` missing or zero.
- In those cases ROI crop may not apply because the backend has no footprint hint.

### 3. Ground Anchors

File:

```text
stockpile_lidar/pipeline.py
```

Function:

```text
_ground_anchor_positions()
```

Reads:

```text
anchors.json
```

Supported anchor forms:

```text
planes[] with alignment == horizontal
anchors[] with anchor_type in {"ground_plane", "pile_toe"}
```

Ground anchors are used as a low-confidence prior, not blindly trusted.

### 4. Ground Segmentation

File:

```text
stockpile_lidar/segmentation/ground_plane.py
```

Flow:

```text
remove statistical outliers
align cloud to dominant plane
fit ground from lowest-Z cluster with RANSAC
compare/blend ARKit anchor ground Z if close enough
shift ground to Z=0
classify pile points above threshold
optionally crop by anchor footprint if 3+ anchors exist
```

Important thresholds:

```text
above_ground_threshold: 0.10 m
ransac_distance_threshold: 0.02 m
max_anchor_ground_disagreement_m: 0.50 m
anchor_crop_margin_m: 0.75 m
```

### 5. Volume Calculation

File:

```text
stockpile_lidar/volume.py
```

Methods:

```text
convex_hull_m3
alpha_shape_m3
grid_integration_m3
recommended_m3
```

The currently recommended method is usually:

```text
grid_integration
```

Weight calculation:

```text
weight_kg = recommended_m3 * density_kg_per_m3
```

### 6. Quality Gates

File:

```text
stockpile_lidar/quality/gates.py
```

Result labels:

```text
verified
review_only
rejected
```

Quality gates include:

```text
pile point density
pile height
peak relief / spike detection
grid occupancy
grid-to-hull ratio
tall-pile + grid/hull inflation
tracking state summary
frame pose continuity
backend-vs-phone quick estimate sanity
small pile mode checks
```

## Result Payload Shape

Typical `GET /api/v2/results/{resultId}` payload:

```json
{
  "result_id": "uuid",
  "stage": "complete",
  "result_label": "verified",
  "measurement_status": "verified",
  "provisional": false,
  "publishable": true,
  "review_grade": false,
  "weight_kg": 3692.68,
  "scale_factor_m_per_unit": 1.0,
  "scale_source": "lidar_native",
  "num_frames": 160,
  "num_colmap_points": 44547,
  "num_colmap_images": 145,
  "calibration": {
    "selected_method": "lidar_tsdf_fusion"
  },
  "volume": {
    "recommended_m3": 1.758,
    "recommended_method": "grid_integration",
    "footprint_area_m2": 3.005
  },
  "quality_blockers": [],
  "quality_warnings": [],
  "diagnostics": {
    "backend_volume_source": "tsdf_fusion",
    "material_code": "backfill",
    "density_kg_per_m3": 2100,
    "persisted_bundle_path": "/home/administrator/stockpile-lidar-backend/data/captures/...",
    "tracking_normal_pct": 90.625,
    "ground_anchor_count": 2,
    "roi_crop_applied": false
  },
  "error": null
}
```

Note:

- `num_colmap_points` and `num_colmap_images` are legacy field names.
- In the v2 LiDAR backend, they represent fused LiDAR point/frame counts.
- They do not mean COLMAP is running.

## Current Deployed Processing Technology

Currently active:

```text
FastAPI
Open3D
NumPy
SciPy
Pillow
ARKit LiDAR depth
ARKit poses/intrinsics
TSDF fusion
```

Currently not active in v2:

```text
COLMAP reconstruction
cone scale calibration
GPU COLMAP processing
durable Postgres result store
async worker queue
```

Server has:

```text
COLMAP installed
NVIDIA GPU visible
Open3D CUDA available
```

But current v2 code path uses legacy Open3D geometry TSDF APIs, so it should be treated as mostly CPU-path unless explicitly changed to tensor/CUDA Open3D or COLMAP GPU.

## Persistence Model

Durable:

```text
uploaded .stockpilecapture bundles
```

Live server path:

```text
/home/administrator/stockpile-lidar-backend/data/captures/
```

Not durable yet:

```text
RESULT_STORE
JOB_STORE
```

These are module-level Python dictionaries in:

```text
stockpile_lidar/pipeline.py
```

Consequence:

- The app can fetch a result immediately after upload.
- If uvicorn restarts, old `resultId` and `jobId` lookups can return 404.
- The persisted capture bundle can still be replayed manually.

Recommended fix:

- Add durable result/job storage in Postgres, SQLite, or object-store JSON sidecars.
- Keep `.stockpilecapture` as the replay source of truth.

## iOS History Behavior

Recent app fix:

```text
2a58a72 Auto-save successful captures to history
```

Changed files:

```text
ios/StockpileCaptureApp/Sources/Features/Capture/CaptureFeatureStore.swift
ios/StockpileCaptureApp/Sources/Support/StockpileAppSession.swift
```

Behavior:

- When a completed v2 result is applied and outcome is `verified` or `review_only`, the app explicitly persists it into the local History cache.
- The History tab is driven by `StockpileAppSession.historyModels`.
- Blocked/rejected results are not intentionally added by the new success callback.

## Latest Known Live Capture State

Recent persisted captures observed on server:

```text
/home/administrator/stockpile-lidar-backend/data/captures/20260518T081456Z-ios-2FD5C5D9-5EB9-4502-8B89-43C6555F04F7.stockpilecapture
/home/administrator/stockpile-lidar-backend/data/captures/20260518T080712Z-ios-2FD5C5D9-5EB9-4502-8B89-43C6555F04F7.stockpilecapture
/home/administrator/stockpile-lidar-backend/data/captures/20260513T060131Z-ios-2FD5C5D9-5EB9-4502-8B89-43C6555F04F7.stockpilecapture
```

Recent replay result previously confirmed:

```text
result label: verified
material: backfill
volume: 1.758 m3
weight: 3.69 tonnes at 2100 kg/m3
frames: 160
tracking normal: 90.625%
quality blockers: none
quality warnings: none
roi crop applied: false
```

## Known Confusion Points

### 1. README Still Describes Legacy COLMAP

The root README still describes:

```text
video upload
traffic cones
COLMAP reconstruction
Streamlit app
```

That is legacy behavior. It is not the current v2 LiDAR backend flow.

### 2. Server Has COLMAP But v2 Does Not Use It

COLMAP being installed on the server does not mean v2 uses COLMAP.

Current v2 selected method:

```text
lidar_tsdf_fusion
```

### 3. Some Result Fields Still Say `colmap`

Legacy field names remain in API output:

```text
num_colmap_points
num_colmap_images
```

In v2 these mean:

```text
fused LiDAR points
fused LiDAR frames
```

### 4. Server Deployment Is Not Git-Clean

The live server folder is not a git checkout. It is a copied code folder.

That makes it harder to answer:

```text
which commit is deployed?
```

Recommended EC2 fix:

- Deploy from Git.
- Pin commit hash.
- Add `/api/v2/version`.
- Add CI/CD or a simple deploy script.

### 5. App Uses Both `/api/mobile` And `/api/v2`

This is expected right now:

- `/api/v2` is the markerless LiDAR processing path.
- `/api/mobile` still supports operational shell/recent-run/legacy API surfaces.

Long-term simplification:

- Move all active mobile app backend surfaces to `/api/v2`.
- Retire `/api/mobile` from the iOS app once equivalent v2 endpoints exist.

## Recommended EC2 Migration Shape

For the current v2 backend:

```text
EC2 Ubuntu
Python 3.10+
Nginx
systemd service
/opt/stockpile/stockpile-lidar-backend
/opt/stockpile/data/captures
```

Systemd should run:

```bash
uvicorn stockpile_lidar.api.main:create_app \
  --factory \
  --host 127.0.0.1 \
  --port 8002 \
  --workers 1
```

Recommended environment:

```text
STOCKPILE_LIDAR_ENV=production
STOCKPILE_LIDAR_STORAGE_ROOT=/opt/stockpile/data
```

Recommended public routes:

```text
/api/v2/health
/api/v2/captures
/api/v2/results/{resultId}
/api/v2/jobs/{jobId}
```

Recommended additions before or during migration:

1. Add `/api/v2/version` returning app version, git commit, build time, and environment.
2. Move `RESULT_STORE` and `JOB_STORE` to durable storage.
3. Add server-side replay command for persisted `.stockpilecapture`.
4. Remove manual/nohup deployment.
5. Decide whether `/api/mobile` remains on old server or gets v2 equivalents.

## Repo Split Recommendation

If creating new repos, use this mapping:

### `stockpile-ios`

Move:

```text
ios/
docs/iOS-specific docs
```

Keep endpoint config documented:

```text
STOCKPILE_API_BASE_URL
STOCKPILE_CAPTURE_BUNDLE_SUBMISSION_URL
```

### `stockpile-lidar-backend`

Move:

```text
stockpile-lidar-backend/
docs/backend deployment docs
```

Add:

```text
Dockerfile or systemd deploy script
README for EC2
version endpoint
capture replay CLI
```

### `stockpile-legacy-colmap`

Move:

```text
stockpile/
app/
legacy README
COLMAP/Streamlit docs
```

This would prevent future agents from confusing the old COLMAP video estimator with the active v2 LiDAR capture backend.

## Minimum Developer Handoff

When a new agent/session starts, tell it:

```text
Worktree:
/Users/clustox1/Documents/Stockpile/stockpile-calibration-readiness

Branch:
reliability-p0-fixes

GitHub:
https://github.com/ahmadhassan91/stockpile.git

iOS app:
ios/

v2 backend:
stockpile-lidar-backend/

Live v2 server:
/home/administrator/stockpile-lidar-backend on 77.93.153.12

Do not confuse:
stockpile/ and app/ are legacy COLMAP/Streamlit areas.

App v2 upload endpoint:
https://stockpile.theclustox.com/api/v2/captures

App v2 result endpoint:
https://stockpile.theclustox.com/api/v2/results/{resultId}

App v2 job endpoint:
https://stockpile.theclustox.com/api/v2/jobs/{jobId}
```
