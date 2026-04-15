from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "app"))

from components.parameter_sidebar import build_pipeline_config_from_values  # noqa: E402
from stockpile.config import DENSITY_PRESETS  # noqa: E402


def test_build_pipeline_config_from_values_uses_preset_density():
    values = {
        "sidebar_material_select": "Backfill 0–75 mm",
        "sidebar_density_input": 1234.0,  # ignored for preset materials
        "sidebar_cone_height": 0.75,
        "sidebar_camera_height": 1.6,
        "sidebar_frame_interval": 0.25,
        "sidebar_max_frames": 800,
        "sidebar_colmap_quality": "medium",
        "sidebar_above_ground": 0.10,
        "sidebar_grid_resolution": 0.05,
        "sidebar_manual_scale_enabled": False,
        "sidebar_manual_scale_value": 3.0,
    }

    config = build_pipeline_config_from_values(values)

    assert config.material_name == "Backfill 0–75 mm"
    assert config.material_density == float(DENSITY_PRESETS["Backfill 0–75 mm"])
    assert config.scale_calibration.known_cone_height_m == 0.75
    assert config.scale_calibration.assumed_camera_height_m == 1.6
    assert config.manual_scale_override is None


def test_build_pipeline_config_from_values_supports_custom_density_and_manual_scale():
    values = {
        "sidebar_material_select": "Custom",
        "sidebar_density_input": 1725.0,
        "sidebar_cone_height": 1.0,
        "sidebar_camera_height": 2.5,
        "sidebar_manual_scale_enabled": True,
        "sidebar_manual_scale_value": 2.25,
    }

    config = build_pipeline_config_from_values(values)

    assert config.material_name == "custom"
    assert config.material_density == 1725.0
    assert config.scale_calibration.known_cone_height_m == 1.0
    assert config.scale_calibration.assumed_camera_height_m == 2.5
    assert config.manual_scale_override == 2.25


def test_build_pipeline_config_from_values_ignores_hidden_scale_overrides_in_client_mode():
    values = {
        "sidebar_material_select": "Backfill 0–75 mm",
        "sidebar_admin_mode": False,
        "sidebar_cone_height": 1.0,
        "sidebar_camera_height": 2.5,
        "sidebar_manual_scale_enabled": True,
        "sidebar_manual_scale_value": 9.5,
    }

    config = build_pipeline_config_from_values(values)

    assert config.scale_calibration.known_cone_height_m == 0.75
    assert config.scale_calibration.assumed_camera_height_m == 1.6
    assert config.manual_scale_override is None
