# Production Measurement Validation

This protocol is for field tests that decide whether Stockpile volume results are ready for production use. It checks repeatability across repeated scans of the same pile and, when available, accuracy against a ground-truth reference.

## Field Protocol

- Capture 3 to 5 independent scans per pile. Use separate walkarounds, not retries from the same capture.
- Keep the pile unchanged between scans. If material moves, start a new validation set.
- Record the same `pile_id` for every repeated scan and a unique `run_id` or `scan_id` for each scan.
- Include `volume_m3` from the measurement system for every scan.
- Include `ground_truth_m3` whenever possible. Good references include certified truck scale tickets, belt scale totals, surveyed volumes, or a known calibration pile.
- Validate multiple pile shapes and site conditions before production rollout: small, medium, tall, constrained edges, and normal operating lighting/weather.

## Acceptance Bands

The default production bands are intentionally conservative:

| Check | Production ready | Review required | Not for client use |
| --- | ---: | ---: | ---: |
| Scan count | 3 or more | - | Fewer than 3 |
| Repeatability CV | <= 5% | > 5% and <= 8% | > 8% |
| Ground-truth error | <= 5% | > 5% and <= 10% | > 10% |

Coefficient of variation is `sample standard deviation / mean volume`. Ground-truth error is `abs(mean volume - ground truth) / ground truth`.

Ground truth is optional for repeatability-only checks, but production acceptance should include it before the measurement is described as accurate.

## Client-Safe Result Labels

Use these labels externally and in test reports:

- `production_ready`: repeatability and any provided ground-truth error are inside production bands.
- `review_required`: no hard failure, but one or more checks landed in the review band. Use internally or with a qualified client note.
- `not_for_client_use`: insufficient scans or a hard repeatability/accuracy failure. Do not present as a production measurement.

Avoid client-facing phrases such as "exact", "certified", "guaranteed", or "survey-grade" unless the result is independently certified by the accepted site reference.

## Input Format

The validation report script accepts CSV or JSON. Required fields are:

- `pile_id`
- `volume_m3`

Optional fields are:

- `run_id`, `scan_id`, or `capture_id`
- `ground_truth_m3`

Example CSV:

```csv
pile_id,run_id,volume_m3,ground_truth_m3
pile-a,scan-1,100.0,101.0
pile-a,scan-2,102.0,101.0
pile-a,scan-3,98.0,101.0
```

Example command:

```bash
python3 scripts/validation_report.py field_runs.csv
```

Use stricter or looser bands only when the field acceptance plan explicitly calls for them:

```bash
python3 scripts/validation_report.py field_runs.json --min-scans 5 --pass-cv 0.04 --review-cv 0.07 --pass-error-pct 0.04 --review-error-pct 0.08
```
