#!/usr/bin/env python3
"""Read field validation runs from CSV/JSON and print a concise report."""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
LIDAR_BACKEND = REPO_ROOT / "stockpile-lidar-backend"
if str(LIDAR_BACKEND) not in sys.path:
    sys.path.insert(0, str(LIDAR_BACKEND))

from stockpile_lidar.validation import FieldRunRecord, ValidationBands, summarize_field_runs


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Summarize stockpile measurement repeatability from field runs.",
    )
    parser.add_argument("input_path", type=Path, help="CSV or JSON file of field runs")
    parser.add_argument("--min-scans", type=int, default=3)
    parser.add_argument("--pass-cv", type=float, default=0.05)
    parser.add_argument("--review-cv", type=float, default=0.08)
    parser.add_argument("--pass-error-pct", type=float, default=0.05)
    parser.add_argument("--review-error-pct", type=float, default=0.10)
    args = parser.parse_args(argv)

    records = load_records(args.input_path)
    bands = ValidationBands(
        min_scans=args.min_scans,
        pass_cv=args.pass_cv,
        review_cv=args.review_cv,
        pass_error_pct=args.pass_error_pct,
        review_error_pct=args.review_error_pct,
    )
    report = summarize_field_runs(records, bands=bands)

    print(format_report(report))
    return 0 if report.passed else 1


def load_records(input_path: Path) -> list[FieldRunRecord]:
    if input_path.suffix.lower() == ".json":
        payload = json.loads(input_path.read_text(encoding="utf-8"))
        rows = payload["runs"] if isinstance(payload, dict) and "runs" in payload else payload
        if not isinstance(rows, list):
            raise ValueError("JSON input must be a list of runs or an object with a 'runs' list")
        return [_record_from_mapping(row) for row in rows]

    with input_path.open(newline="", encoding="utf-8") as csv_file:
        return [_record_from_mapping(row) for row in csv.DictReader(csv_file)]


def format_report(report: Any) -> str:
    lines = ["Stockpile field validation report"]
    for summary in report.piles:
        line = (
            f"- {summary.pile_id}: {summary.result_label} "
            f"scans={summary.scan_count} "
            f"mean={summary.mean_volume_m3:.2f} m3 "
            f"std={summary.std_dev_m3:.2f} m3 "
            f"cv={summary.coefficient_of_variation * 100:.2f}%"
        )
        if summary.ground_truth_m3 is not None:
            line += (
                f" truth={summary.ground_truth_m3:.2f} m3 "
                f"error={summary.absolute_error_m3:.2f} m3 "
                f"({summary.percent_error * 100:.2f}%)"
            )
        lines.append(line)
        for warning in summary.warnings:
            lines.append(f"  warning: {warning}")
        for failure in summary.failures:
            lines.append(f"  fail: {failure}")
    lines.append(f"overall: {'pass' if report.passed else 'fail'}")
    return "\n".join(lines)


def _record_from_mapping(row: dict[str, Any]) -> FieldRunRecord:
    return FieldRunRecord(
        pile_id=str(_required(row, "pile_id")),
        run_id=str(row.get("run_id") or row.get("scan_id") or row.get("capture_id") or ""),
        volume_m3=float(_required(row, "volume_m3")),
        ground_truth_m3=_optional_float(row.get("ground_truth_m3")),
    )


def _required(row: dict[str, Any], key: str) -> Any:
    value = row.get(key)
    if value is None or value == "":
        raise ValueError(f"missing required field: {key}")
    return value


def _optional_float(value: Any) -> float | None:
    if value is None or value == "":
        return None
    return float(value)


if __name__ == "__main__":
    raise SystemExit(main())
