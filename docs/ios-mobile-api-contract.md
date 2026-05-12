# iOS Mobile API Contract

This is the production contract for the native iPhone app.

The current Swift models already define the right top-level entities:

- `CaptureSession`
- `UploadAuthorization`
- `ProcessingJobStatus`
- `ResultPayload`

We should keep that entity split. What must change is the depth and honesty of the payloads so the app can reason about tagged references, live capture metadata, and trustworthy release decisions.

## Contract Principles

- mobile creates a capture session before recording or upload
- tagged references are part of the run contract, not an incidental backend guess
- upload state and processing state are separate
- every run ends in exactly one terminal outcome:
  - `verified`
  - `review_only`
  - `blocked`
- AI preflight is advisory only
- the web portal consumes results but does not own the mobile field session

## What We Keep Versus Expand

| Entity | Keep | Must be expanded for production |
| --- | --- | --- |
| `CaptureSession` | Yes | add explicit reference plan and capture policy |
| `UploadAuthorization` | Yes | support resumable uploads and capture metadata association |
| `ProcessingJobStatus` | Yes | expose upload state, processing state, and quality gate details separately |
| `ResultPayload` | Yes | include capture quality, tagged-reference diagnostics, calibration basis, and release rationale |

## Canonical Mobile Flow

1. `POST /api/mobile/capture-sessions`
2. `POST /api/mobile/uploads`
3. client uploads the recorded movie to a signed URL or resumable upload endpoint
4. `POST /api/mobile/jobs` or the server auto-creates the job after upload finalization
5. `GET /api/mobile/jobs/{jobId}`
6. `GET /api/mobile/results/{runId}`
7. `GET /api/mobile/sites`
8. `GET /api/mobile/materials`

## Capture Session Request

The current request already carries `siteId`, `pileName`, `materialCode`, `densityKgPerM3`, `referenceCountGoal`, and `clientBuild`.

For production, the capture contract also needs an explicit tagged-reference plan, either nested or flattened into equivalent fields.

### Example request

```json
{
  "siteId": "qpmc-north-yard",
  "pileName": "North Yard 03",
  "materialCode": "backfill-0-75-mm",
  "densityKgPerM3": 2100,
  "referenceCountGoal": 3,
  "clientBuild": "ios-0.1.0(12)",
  "captureMode": "live_walkaround",
  "referencePlan": {
    "referenceType": "tagged_reference",
    "minimumVisibleTogether": 2,
    "expectedHeightM": 0.75
  }
}
```

### Example response

```json
{
  "sessionId": "session_123",
  "siteId": "qpmc-north-yard",
  "pileName": "North Yard 03",
  "materialCode": "backfill-0-75-mm",
  "densityKgPerM3": 2100,
  "referenceCountGoal": 3,
  "captureMode": "live_walkaround",
  "minimumVisibleTogether": 2,
  "createdAt": "2026-04-21T09:00:00Z",
  "expiresAt": "2026-04-21T15:00:00Z"
}
```

## Upload Authorization Request

The current request shape of `sessionId`, `fileName`, `byteCount`, `contentType`, and `checksumSha256` should stay.

For production, the upload flow also needs capture metadata so the backend can audit the run and tune quality rules:

- recording duration
- camera position
- recorded timestamp
- device model
- app build
- optional local capture metrics summary

That metadata can be attached in the upload request or in a separate finalize call, but it must be persisted server-side.

### Example request

```json
{
  "sessionId": "session_123",
  "fileName": "north-yard-03.mov",
  "byteCount": 138273648,
  "contentType": "video/quicktime",
  "checksumSha256": "0f4d9f5a7b...",
  "captureMetadata": {
    "durationSec": 46.2,
    "cameraPosition": "back",
    "recordedAt": "2026-04-21T09:03:18Z",
    "deviceModel": "iPhone16,1",
    "clientBuild": "ios-0.1.0(12)"
  }
}
```

### Example response

```json
{
  "uploadId": "upload_123",
  "sessionId": "session_123",
  "jobId": "job_123",
  "uploadUrl": "https://uploads.example.com/upload_123",
  "httpMethod": "PUT",
  "headers": {
    "Content-Type": "video/quicktime"
  },
  "expiresAt": "2026-04-21T09:33:18Z"
}
```

## Job Status Contract

The current `ProcessingJobStatus` shape of one `phase`, one `progress`, one `headline`, and one `detail` is a good start, but it is too thin for production mobile use.

The app must not have to guess whether the file is still uploading, has been received, or is already in reconstruction. The production contract should therefore expose upload state and processing state separately, plus the latest quality gate summary.

### Example response

```json
{
  "jobId": "job_123",
  "runId": "run_123",
  "upload": {
    "state": "complete",
    "bytesReceived": 138273648,
    "bytesExpected": 138273648
  },
  "processing": {
    "phase": "detecting_references",
    "progress": 0.48,
    "headline": "Detecting tagged references",
    "detail": "Checking whether at least two tagged references remain visible together."
  },
  "qualityGate": {
    "state": "watch",
    "referenceVisibilityScore": 0.62,
    "perimeterCoverageScore": 0.54,
    "motionStabilityScore": 0.81,
    "primaryReason": "Only one tagged reference is visible in too many frames."
  },
  "updatedAt": "2026-04-21T09:07:11Z"
}
```

### Required processing phases

- `queued`
- `upload_authorized`
- `upload_received`
- `extracting_frames`
- `detecting_references`
- `reconstructing`
- `calibrating`
- `computing_volume`
- `verified`
- `review_only`
- `blocked`
- `failed`

## Result Payload

The current result shape of `runId`, `pileName`, `outcome`, `confidence`, `measurement`, `warnings`, `blockers`, and `recommendedAction` should stay.

For production, it must expand to explain why a run was verified, held for review, or blocked.

### Example response

```json
{
  "runId": "run_123",
  "pileName": "North Yard 03",
  "outcome": "review_only",
  "confidence": {
    "score": 58,
    "label": "Moderate",
    "summary": "Processing completed, but scale still needs a benchmark cross-check."
  },
  "measurement": {
    "volumeM3": 2528.43,
    "weightTonnes": 5309.70,
    "densityKgPerM3": 2100
  },
  "captureQuality": {
    "referenceVisibilityScore": 0.61,
    "perimeterCoverageScore": 0.88,
    "motionStabilityScore": 0.84
  },
  "referenceDiagnostics": {
    "targetCount": 3,
    "minimumVisibleTogether": 2,
    "framesMeetingVisibilityGoal": 41,
    "framesChecked": 63,
    "calibrationBasis": "tagged_references_plus_camera_pose",
    "calibrationStatus": "needs_review"
  },
  "warnings": [
    "Toe coverage weakened on the north edge."
  ],
  "blockers": [
    "Reference agreement dropped below verified threshold for 22 frames."
  ],
  "recommendedAction": "Review against the latest site benchmark before release.",
  "reportUrl": "https://portal.example.com/runs/run_123"
}
```

## Required Result Semantics

- `verified` means the run is release-grade and passed tagged-reference and calibration gates.
- `review_only` means a measurement exists, but human release judgment is still required.
- `blocked` means the run must be recaptured and should not be treated as report-grade.
- `measurement` must be omitted or `null` when the outcome is `blocked`, unless the product explicitly supports a suppressed internal estimate that is never shown as reportable.
- `warnings` are operator-visible concerns that do not automatically suppress the result.
- `blockers` explain why the run is not report-grade.
- `recommendedAction` must always be present and operator-friendly.

## Non-Negotiable Production Rules

- the API must never return `verified` if tagged-reference or calibration gates failed
- the mobile app must never infer upload versus processing state from one generic progress number
- AI preflight cannot promote a blocked run into a verified run
- user-facing language should say tagged references even if the short-term backend implementation still uses cone-based detection internally
- the result payload should be auditable enough that QA can explain any `review_only` or `blocked` outcome after the fact

## Why This Contract Solves the Client Problem

- Native iOS gets honest, operator-friendly state instead of one vague "processing" bucket.
- Tagged references become an explicit contract that both the app and backend can enforce.
- The backend can explain not just that a run failed, but why it failed.
- Results become easier to trust because the release decision is tied to visible diagnostics rather than a single opaque score.
