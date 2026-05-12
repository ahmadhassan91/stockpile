"""Repeatability and ground-truth validation for field measurement runs."""

from __future__ import annotations

from dataclasses import dataclass, field
from statistics import mean, stdev
from typing import Iterable


@dataclass(frozen=True)
class FieldRunRecord:
    """One measured field run for a pile."""

    pile_id: str
    run_id: str
    volume_m3: float
    ground_truth_m3: float | None = None


@dataclass(frozen=True)
class ValidationBands:
    """Production acceptance bands for a repeated pile measurement."""

    min_scans: int = 3
    pass_cv: float = 0.05
    review_cv: float = 0.08
    pass_error_pct: float | None = 0.05
    review_error_pct: float | None = 0.10


@dataclass(frozen=True)
class PileValidationSummary:
    """Repeatability summary for all runs of one pile."""

    pile_id: str
    scan_count: int
    mean_volume_m3: float
    std_dev_m3: float
    coefficient_of_variation: float
    ground_truth_m3: float | None
    absolute_error_m3: float | None
    percent_error: float | None
    result_label: str
    passed: bool
    warnings: list[str] = field(default_factory=list)
    failures: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class FieldValidationReport:
    """Validation report across one or more piles."""

    piles: list[PileValidationSummary]
    passed: bool


def summarize_pile_runs(
    records: Iterable[FieldRunRecord],
    *,
    bands: ValidationBands | None = None,
) -> PileValidationSummary:
    """Compute repeatability and optional ground-truth accuracy for one pile."""

    pile_records = list(records)
    if not pile_records:
        raise ValueError("at least one field run record is required")

    pile_id = pile_records[0].pile_id
    if any(record.pile_id != pile_id for record in pile_records):
        raise ValueError("summarize_pile_runs accepts records for one pile only")

    selected_bands = bands or ValidationBands()
    volumes = [float(record.volume_m3) for record in pile_records]
    mean_volume = mean(volumes)
    std_dev = stdev(volumes) if len(volumes) > 1 else 0.0
    coefficient_of_variation = (
        abs(std_dev / mean_volume) if abs(mean_volume) > 1e-12 else 0.0
    )

    ground_truth = _select_ground_truth(pile_records)
    absolute_error = None
    percent_error = None
    if ground_truth is not None:
        absolute_error = abs(mean_volume - ground_truth)
        percent_error = (
            absolute_error / abs(ground_truth) if abs(ground_truth) > 1e-12 else None
        )

    warnings: list[str] = []
    failures: list[str] = []

    if len(pile_records) < selected_bands.min_scans:
        failures.append(
            f"requires at least {selected_bands.min_scans} scans for production validation"
        )

    if coefficient_of_variation > selected_bands.review_cv:
        failures.append(
            "repeatability coefficient of variation "
            f"{_format_pct(coefficient_of_variation)} exceeds "
            f"{_format_pct(selected_bands.review_cv)}"
        )
    elif coefficient_of_variation > selected_bands.pass_cv:
        warnings.append(
            "repeatability coefficient of variation "
            f"{_format_pct(coefficient_of_variation)} exceeds production band "
            f"{_format_pct(selected_bands.pass_cv)}"
        )

    if (
        percent_error is not None
        and selected_bands.review_error_pct is not None
        and percent_error > selected_bands.review_error_pct
    ):
        failures.append(
            "ground-truth percent error "
            f"{_format_pct(percent_error)} exceeds "
            f"{_format_pct(selected_bands.review_error_pct)}"
        )
    elif (
        percent_error is not None
        and selected_bands.pass_error_pct is not None
        and percent_error > selected_bands.pass_error_pct
    ):
        warnings.append(
            "ground-truth percent error "
            f"{_format_pct(percent_error)} exceeds production band "
            f"{_format_pct(selected_bands.pass_error_pct)}"
        )

    passed = not failures
    result_label = _label_for(warnings=warnings, failures=failures)

    return PileValidationSummary(
        pile_id=pile_id,
        scan_count=len(pile_records),
        mean_volume_m3=float(mean_volume),
        std_dev_m3=float(std_dev),
        coefficient_of_variation=float(coefficient_of_variation),
        ground_truth_m3=ground_truth,
        absolute_error_m3=absolute_error,
        percent_error=percent_error,
        result_label=result_label,
        passed=passed,
        warnings=warnings,
        failures=failures,
    )


def summarize_field_runs(
    records: Iterable[FieldRunRecord],
    *,
    bands: ValidationBands | None = None,
) -> FieldValidationReport:
    """Group repeated runs by pile and summarize each pile."""

    grouped: dict[str, list[FieldRunRecord]] = {}
    for record in records:
        grouped.setdefault(record.pile_id, []).append(record)

    summaries = [
        summarize_pile_runs(grouped[pile_id], bands=bands) for pile_id in sorted(grouped)
    ]
    return FieldValidationReport(
        piles=summaries,
        passed=bool(summaries) and all(summary.passed for summary in summaries),
    )


def _select_ground_truth(records: list[FieldRunRecord]) -> float | None:
    values = [
        float(record.ground_truth_m3)
        for record in records
        if record.ground_truth_m3 is not None
    ]
    if not values:
        return None
    first_value = values[0]
    if any(abs(value - first_value) > 1e-9 for value in values[1:]):
        raise ValueError("ground truth must be consistent for runs of the same pile")
    return first_value


def _label_for(*, warnings: list[str], failures: list[str]) -> str:
    if failures:
        return "not_for_client_use"
    if warnings:
        return "review_required"
    return "production_ready"


def _format_pct(value: float) -> str:
    return f"{value * 100:.2f}%"
