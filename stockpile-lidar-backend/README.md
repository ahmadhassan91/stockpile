# Stockpile LiDAR Backend

Lean FastAPI skeleton for the optional LiDAR capture path described in the mobile-first calibration readiness plan.

This service is intentionally separate from the existing `stockpile/` backend. It starts with health, route placeholders, configuration, and manifest validation so the mobile and worker teams can integrate against stable module boundaries before the measurement pipeline is implemented.

## Layout

- `stockpile_lidar/api/main.py` - FastAPI app factory and `/health`
- `stockpile_lidar/api/routes/captures.py` - capture route placeholders
- `stockpile_lidar/api/routes/jobs.py` - job route placeholders
- `stockpile_lidar/api/routes/results.py` - result route placeholders
- `stockpile_lidar/config.py` - environment-backed service settings
- `stockpile_lidar/manifest.py` - LiDAR capture manifest validator
- `stockpile_lidar/pipeline.py` - pipeline submission placeholder

## Run Locally

```bash
python3 -m pip install -e ".[dev]"
uvicorn stockpile_lidar.api.main:app --reload
```

Health check:

```bash
curl http://127.0.0.1:8000/health
```

## Test

```bash
python3 -m pytest
```

## Docker

```bash
docker build -t stockpile-lidar-backend .
docker run --rm -p 8000:8000 stockpile-lidar-backend
```
