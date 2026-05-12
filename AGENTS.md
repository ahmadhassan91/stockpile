# Stockpile Agent Handoff

This repository is a monorepo. Keep the mobile app and the LiDAR backend treated as separate deployable units.

## Active Roots

- iOS app: `ios/`
  - Xcode project: `ios/StockpileCaptureApp.xcodeproj`
  - Main app sources: `ios/StockpileCaptureApp/Sources/`
  - Capture/upload package: `ios/StockpileCaptureKit/Sources/`
  - TestFlight scripts: `ios/check-testflight-readiness.sh`, `ios/archive-qpmc-alpha.sh`, `ios/export-qpmc-testflight.sh`
- v2 LiDAR backend: `stockpile-lidar-backend/`
  - API route: `stockpile-lidar-backend/stockpile_lidar/api/routes/captures.py`
  - Processing pipeline: `stockpile-lidar-backend/stockpile_lidar/pipeline.py`
  - Server deploy path: `/home/administrator/stockpile-lidar-backend`
  - Public health URL: `https://stockpile.theclustox.com/api/v2/health`

## Field-Test State

- The iOS app posts `.stockpilecapture` bundles to the v2 backend.
- The backend persists every uploaded bundle under `data/captures/` on the server.
- ROI cropping is active and clamps obviously inflated phone quick estimates so yard/background points do not disable the crop.
- Operational iOS capture defaults to `stockpile` pile-size mode for yard runs.
- ARKit horizontal plane detection is enabled for ground anchors.

## Do Not Confuse

- `stockpile/` is legacy/shared Python processing code. Do not deploy it as the v2 LiDAR API unless the task explicitly says so.
- `app/` is not the native iOS app.
- Local build products live under `build/`, `.build/`, DerivedData, and `ios/build/`; do not commit them.

## Quick Verification

- Backend focused tests:
  `PYTHONPATH=stockpile-lidar-backend .venv/bin/python -m pytest stockpile-lidar-backend/tests/test_pipeline_quick_estimate.py -q`
- iOS device build:
  `xcodebuild -project ios/StockpileCaptureApp.xcodeproj -scheme StockpileCaptureApp -configuration Debug -destination 'id=00008101-00080DAC02DB001E' -allowProvisioningUpdates build`
