"""Tests for field repeatability validation summaries."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from stockpile_lidar.validation import (
    FieldRunRecord,
    ValidationBands,
    summarize_field_runs,
    summarize_pile_runs,
)


def test_summarize_pile_runs_computes_repeatability_and_accuracy():
    records = [
        FieldRunRecord(pile_id="pile-a", run_id="scan-1", volume_m3=100.0, ground_truth_m3=101.0),
        FieldRunRecord(pile_id="pile-a", run_id="scan-2", volume_m3=102.0, ground_truth_m3=101.0),
        FieldRunRecord(pile_id="pile-a", run_id="scan-3", volume_m3=98.0, ground_truth_m3=101.0),
    ]
    bands = ValidationBands(min_scans=3, pass_cv=0.03, review_cv=0.05, pass_error_pct=0.02, review_error_pct=0.05)

    summary = summarize_pile_runs(records, bands=bands)

    assert summary.pile_id == "pile-a"
    assert summary.scan_count == 3
    assert summary.mean_volume_m3 == pytest.approx(100.0)
    assert summary.std_dev_m3 == pytest.approx(2.0)
    assert summary.coefficient_of_variation == pytest.approx(0.02)
    assert summary.ground_truth_m3 == pytest.approx(101.0)
    assert summary.absolute_error_m3 == pytest.approx(1.0)
    assert summary.percent_error == pytest.approx(1.0 / 101.0)
    assert summary.passed is True
    assert summary.result_label == "production_ready"
    assert summary.failures == []


def test_summarize_field_runs_groups_piles_and_marks_review_required():
    records = [
        FieldRunRecord(pile_id="pile-a", run_id="scan-1", volume_m3=100.0),
        FieldRunRecord(pile_id="pile-a", run_id="scan-2", volume_m3=112.0),
        FieldRunRecord(pile_id="pile-a", run_id="scan-3", volume_m3=88.0),
        FieldRunRecord(pile_id="pile-b", run_id="scan-1", volume_m3=50.0),
        FieldRunRecord(pile_id="pile-b", run_id="scan-2", volume_m3=50.5),
    ]
    bands = ValidationBands(min_scans=3, pass_cv=0.05, review_cv=0.08)

    report = summarize_field_runs(records, bands=bands)

    assert [summary.pile_id for summary in report.piles] == ["pile-a", "pile-b"]
    assert report.piles[0].passed is False
    assert report.piles[0].result_label == "not_for_client_use"
    assert any("repeatability" in failure for failure in report.piles[0].failures)
    assert report.piles[1].passed is False
    assert report.piles[1].result_label == "not_for_client_use"
    assert any("at least 3 scans" in failure for failure in report.piles[1].failures)
    assert report.passed is False


def test_validation_cli_reads_json_and_prints_concise_report(tmp_path: Path):
    input_path = tmp_path / "runs.json"
    input_path.write_text(
        json.dumps(
            [
                {"pile_id": "pile-a", "run_id": "scan-1", "volume_m3": 100.0, "ground_truth_m3": 101.0},
                {"pile_id": "pile-a", "run_id": "scan-2", "volume_m3": 102.0, "ground_truth_m3": 101.0},
                {"pile_id": "pile-a", "run_id": "scan-3", "volume_m3": 98.0, "ground_truth_m3": 101.0},
            ],
        ),
        encoding="utf-8",
    )
    script_path = Path(__file__).resolve().parents[2] / "scripts" / "validation_report.py"

    completed = subprocess.run(
        [
            sys.executable,
            str(script_path),
            str(input_path),
            "--min-scans",
            "3",
            "--pass-cv",
            "0.03",
            "--review-cv",
            "0.05",
            "--pass-error-pct",
            "0.02",
            "--review-error-pct",
            "0.05",
        ],
        check=False,
        text=True,
        capture_output=True,
    )

    assert completed.returncode == 0
    assert "pile-a" in completed.stdout
    assert "production_ready" in completed.stdout
    assert "mean=100.00 m3" in completed.stdout
    assert "cv=2.00%" in completed.stdout
