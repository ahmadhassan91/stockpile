# Field Test Handoff - 2026-05-12

## Current Objective

Improve Stockpile iOS LiDAR capture reliability for on-site sand/gravel pile runs using the v2 backend.

## Server

- Host: `77.93.153.12`
- Backend path: `/home/administrator/stockpile-lidar-backend`
- Process: uvicorn on `127.0.0.1:8002`
- Public health: `https://stockpile.theclustox.com/api/v2/health`
- Persisted bundles: `/home/administrator/stockpile-lidar-backend/data/captures/`

## Latest Relevant Runs

- Latest field run before ROI clamp: `1068e5bc-69f4-425b-99bc-44873d2c44cc`
  - Sand, submitted as `small`
  - Backend: `30.99 m3`, about `49.6t`
  - Phone quick estimate: `271.84 m3`, `8.99m` peak height
  - ROI did not crop because the quick-estimate footprint was inflated.
- Server replay after ROI clamp: `5dd41521-e984-4dd7-ae34-300d7c39a979`
  - Sand, forced to `stockpile`
  - Backend: `19.64 m3`, about `31.4t`
  - ROI applied with `3.5m` radius and removed `23,148` points.

## Implemented

- Persist raw uploaded `.stockpilecapture` bundles on the backend.
- Add ROI crop around the pile and clamp obviously inflated quick estimates.
- Keep ARKit ground anchors safe: parse/count them, but do not trust anchors when they strongly disagree with RANSAC.
- Enable ARKit horizontal plane detection in the iOS capture session.
- Change operational iOS default pile-size mode from `small` to `stockpile`.
- Install a fresh Debug build on the connected iPhone after the stockpile-default fix.

## Next Field Run Guidance

- Use material `Sand` for the current sand pile.
- Confirm pile size mode is `Stockpile`.
- Keep the pile centered and avoid including far yard/background behind it.
- Walk a tight arc and keep ground visible before and during the scan.
