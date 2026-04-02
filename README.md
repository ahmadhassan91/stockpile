# Stockpile Weight Estimator

Estimate stockpile volume and weight from a ground-level walkaround video. Place red traffic cones around the pile for scale reference — the pipeline reconstructs a 3D point cloud via COLMAP, calibrates real-world scale from the cones, segments the pile, computes volume, and multiplies by material density.

## Prerequisites

- **Python 3.10–3.12** (Open3D does not support 3.13+)
- **COLMAP** (used via subprocess)

### Install COLMAP

macOS:
```bash
brew install colmap
```

Ubuntu/Debian:
```bash
sudo apt-get install colmap
```

Verify:
```bash
colmap -h
```

## Setup

```bash
cd stock_pile
python3.12 -m venv .venv
source .venv/bin/activate
pip install -e .
```

## Run

```bash
source .venv/bin/activate
streamlit run app/app.py
```

Open http://localhost:8501 in your browser.

## Usage

1. **Upload** — Upload a walkaround video (MP4/AVI/MOV) of the stockpile with red traffic cones placed around it. Set cone height and material type in the sidebar.
2. **Processing** — Click "Start Processing". The pipeline extracts frames, detects cones, runs COLMAP 3D reconstruction, calibrates scale, fits the ground plane, and computes volume. This takes 5–30 minutes depending on video length and COLMAP quality setting.
3. **Results** — View estimated volume (m³) and weight (kg/tonnes), interactive 3D point cloud, and run reliability diagnostics before reporting a result.
4. **Debug** — Inspect cone detections per frame, COLMAP reconstruction stats, scale calibration details, and ground plane / volume quality metrics.

### Tips

- **Cone placement**: Place 3+ cones around the pile at ground level. More cones = more reliable scale calibration.
- **Video capture**: Walk slowly around the entire pile. 1–3 minutes at 30fps works well. Overlap between frames helps COLMAP.
- **Scale override**: If auto-calibration confidence is low (< 50%), use the "Override scale manually" checkbox in the sidebar to set the scale factor directly.
- **COLMAP quality**: Use "low" for quick tests, "medium" (default) for production, "high" on GPU-backed deployments when you want maximum reconstruction coverage.
- **Reliability gates**: Treat runs with low grid occupancy, large scale disagreement, or very sparse pile points as review-only until they are cross-checked against survey or weighbridge data.

## Project Structure

```
stock_pile/
├── stockpile/               # Core library
│   ├── config.py            # Pipeline configuration dataclasses
│   ├── pipeline.py          # Orchestrator wiring all stages
│   ├── frame_extraction.py  # Video → frames (OpenCV)
│   ├── cone_detection.py    # 2D red cone detection (HSV + contours)
│   ├── colmap_runner.py     # COLMAP subprocess wrapper + binary parsers
│   ├── scale_calibration.py # 2D→3D cone matching, scale factor
│   ├── ground_plane.py      # Ground plane fitting, pile segmentation
│   ├── volume.py            # Volume computation (3 methods)
│   └── visualization.py     # Plotly 3D helpers
├── app/                     # Streamlit web app
│   ├── app.py               # Entry point
│   ├── pages/               # Multi-page app
│   └── components/          # Reusable UI components
├── pyproject.toml
├── requirements.txt
└── data/                    # Runtime workspace (gitignored)
```

## Pipeline Stages

1. **Frame extraction** — Extract frames every 0.5s (configurable) from video
2. **Cone detection** — HSV red/orange masking + contour filtering with vertical merge for banded cones
3. **COLMAP sparse reconstruction** — `automatic_reconstructor` with `--dense 0`, using a larger evenly-spaced frame budget on GPU-backed deployments
4. **Scale calibration** — Match 2D cone detections to 3D COLMAP keypoints, cluster with DBSCAN, compute scale from cone height
5. **Ground plane fitting** — Dominant-plane alignment + percentile-based ground level
6. **Volume computation** — Three methods: convex hull, alpha shape, and 2.5D grid integration constrained to the cone/observed footprint, plus a conservative fallback when the grid estimate becomes unstable
7. **Reliability assessment** — Flag runs with weak calibration, sparse reconstruction, or runaway interpolation before they are reported
8. **Weight** = selected volume × material density
