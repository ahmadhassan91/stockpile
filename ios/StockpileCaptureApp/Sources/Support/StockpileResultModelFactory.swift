import Foundation
import StockpileMobileAPI
import StockpileProcessingRuntime
import StockpileResultsUI

enum StockpileResultModelFactory {
    static func makeResultScreenModel(from payload: StockpileResultPayload) -> StockpileResultScreenModel {
        StockpileResultScreenModel(
            runID: payload.runID,
            pileName: payload.pileName,
            outcome: resultOutcome(from: payload.outcome),
            confidence: StockpileConfidenceSummary(
                score: payload.confidence.score,
                label: payload.confidence.label,
                summary: payload.confidence.summary
            ),
            measurement: measurement(from: payload),
            warnings: payload.warnings,
            blockers: payload.blockers,
            recommendedAction: payload.recommendedAction,
            confidenceLenses: confidenceLenses(
                captureQuality: payload.captureQuality,
                referenceDiagnostics: payload.referenceDiagnostics
            ),
            reportURL: payload.reportURL,
            updatedAt: payload.updatedAt,
            reconstruction: reconstruction(from: payload.reconstruction)
        )
    }

    static func makeProvisionalResultScreenModel(from payload: StockpileResultPayload) -> StockpileResultScreenModel {
        StockpileResultScreenModel(
            runID: payload.runID,
            pileName: payload.pileName,
            outcome: provisionalOutcome(from: payload),
            runtimeState: .processing,
            confidence: provisionalConfidence(from: payload),
            measurement: measurement(from: payload),
            warnings: payload.warnings,
            blockers: payload.blockers,
            recommendedAction: provisionalRecommendedAction(from: payload),
            confidenceLenses: confidenceLenses(
                captureQuality: payload.captureQuality,
                referenceDiagnostics: payload.referenceDiagnostics
            ),
            reportURL: nil,
            updatedAt: payload.provisionalMeasurement?.updatedAt ?? payload.updatedAt,
            reconstruction: reconstruction(from: payload.reconstruction)
        )
    }

    static func makeResultScreenModel(from result: StockpileProcessingRuntimeResultState) -> StockpileResultScreenModel {
        makeResultScreenModel(from: result.payload)
    }

    private static func provisionalOutcome(from payload: StockpileResultPayload) -> StockpileResultOutcome {
        switch payload.outcome {
        case .blocked:
            return .blocked
        case .reviewOnly, .verified:
            return .reviewOnly
        }
    }

    private static func provisionalConfidence(from payload: StockpileResultPayload) -> StockpileConfidenceSummary {
        let score = payload.provisionalMeasurement?.confidenceScore ?? payload.confidence.score
        return StockpileConfidenceSummary(
            score: score,
            label: "Processing",
            summary: provisionalConfidenceSummary(from: payload)
        )
    }

    private static func provisionalConfidenceSummary(from payload: StockpileResultPayload) -> String {
        var parts: [String] = []

        if let provisionalMeasurement = payload.provisionalMeasurement {
            if let reason = provisionalMeasurement.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
               reason.isEmpty == false {
                parts.append(reason)
            } else {
                parts.append("A provisional measurement is available.")
            }
        } else {
            parts.append("This run is still in flight.")
        }

        if payload.captureQuality != nil || payload.referenceDiagnostics != nil {
            parts.append("Capture and reference diagnostics are still being folded in.")
        } else {
            parts.append("No diagnostics have been attached yet.")
        }

        parts.append("This is not a verified result.")
        return parts.joined(separator: " ")
    }

    private static func provisionalRecommendedAction(from payload: StockpileResultPayload) -> String {
        let trimmedAction = payload.recommendedAction.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAction.isEmpty
            ? "Wait for backend processing to finish before treating this run as final."
            : trimmedAction
    }

    private static func resultOutcome(from outcome: StockpileRunOutcome) -> StockpileResultOutcome {
        switch outcome {
        case .verified:
            return .verified
        case .reviewOnly:
            return .reviewOnly
        case .blocked:
            return .blocked
        }
    }

    private static func measurement(from payload: StockpileResultPayload) -> StockpileMeasurement? {
        if let measurement = payload.measurement {
            return StockpileMeasurement(
                volumeM3: measurement.volumeM3,
                weightTonnes: measurement.weightTonnes,
                densityKgPerM3: measurement.densityKgPerM3
            )
        }

        guard
            let provisional = payload.provisionalMeasurement,
            let volumeM3 = provisional.volumeM3,
            let weightTonnes = provisional.weightTonnes,
            volumeM3 > 0
        else {
            return nil
        }

        let derivedDensity = Int(((weightTonnes * 1_000) / volumeM3).rounded())
        return StockpileMeasurement(
            volumeM3: volumeM3,
            weightTonnes: weightTonnes,
            densityKgPerM3: max(derivedDensity, 0)
        )
    }

    private static func confidenceLenses(
        captureQuality: StockpileCaptureQualityPayload?,
        referenceDiagnostics: StockpileReferenceDiagnosticsPayload?
    ) -> [StockpileConfidenceLens] {
        [
            calibrationLens(from: referenceDiagnostics),
            referencesLens(from: referenceDiagnostics),
            captureLens(from: captureQuality),
        ]
        .compactMap { $0 }
    }

    private static func reconstruction(
        from payload: StockpileReconstructionPayload?
    ) -> StockpileResultReconstruction? {
        guard let payload else {
            return nil
        }

        let defaultMode = StockpileResultViewerMode(rawValue: payload.defaultMode) ?? .threeD
        return StockpileResultReconstruction(
            summary: payload.summary,
            footprintAreaM2: payload.footprintAreaM2,
            peakHeightM: payload.peakHeightM,
            defaultMode: defaultMode,
            vertices: payload.vertices.map {
                StockpileResultPoint3D(x: $0.x, y: $0.y, z: $0.z)
            },
            triangles: payload.triangles.map {
                StockpileResultTriangle(a: $0.a, b: $0.b, c: $0.c)
            },
            pointCloud: payload.pointCloud.map {
                StockpileResultPoint3D(x: $0.x, y: $0.y, z: $0.z)
            },
            toeMarkers: payload.toeMarkers.map {
                StockpileResultPoint3D(x: $0.x, y: $0.y, z: $0.z)
            },
            surfaceRiskMarkers: payload.surfaceRiskMarkers.map {
                StockpileResultPoint3D(x: $0.x, y: $0.y, z: $0.z)
            }
        )
    }

    private static func calibrationLens(
        from diagnostics: StockpileReferenceDiagnosticsPayload?
    ) -> StockpileConfidenceLens? {
        guard let diagnostics else {
            return nil
        }

        let state: StockpileConfidenceLensState
        switch diagnostics.calibrationStatus.lowercased() {
        case "verified", "ready", "pass":
            state = .high
        case "needs_review", "review_only", "warning":
            state = .medium
        default:
            state = .low
        }

        let basis = diagnostics.calibrationBasis
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        let strategy = diagnostics.referenceStrategy?
            .replacingOccurrences(of: "_", with: " ")
            .capitalized ?? "Reference-assisted"

        return StockpileConfidenceLens(
            id: "calibration",
            label: "Calibration",
            state: state,
            detail: "\(strategy) scaling settled on \(basis). Current status: \(diagnostics.calibrationStatus.replacingOccurrences(of: "_", with: " "))."
        )
    }

    private static func referencesLens(
        from diagnostics: StockpileReferenceDiagnosticsPayload?
    ) -> StockpileConfidenceLens? {
        guard let diagnostics else {
            return nil
        }

        let framesChecked = diagnostics.framesChecked ?? 0
        let framesMeetingGoal = diagnostics.framesMeetingVisibilityGoal ?? 0
        let referencesUsed = diagnostics.referencesUsed ?? 0
        let usesTaggedReferences = diagnostics.referenceStrategy?.lowercased() == "tagged_references"

        let state: StockpileConfidenceLensState
        if framesChecked > 0 {
            let successRatio = Double(framesMeetingGoal) / Double(framesChecked)
            if usesTaggedReferences && framesMeetingGoal == 0 {
                state = .low
            } else if successRatio >= 0.6 && referencesUsed >= diagnostics.minimumVisibleTogether {
                state = .high
            } else if successRatio >= 0.2 || referencesUsed >= diagnostics.minimumVisibleTogether {
                state = .medium
            } else {
                state = .low
            }
        } else if referencesUsed >= diagnostics.preferredVisibleCount {
            state = .high
        } else if referencesUsed >= diagnostics.minimumVisibleTogether {
            state = .medium
        } else {
            state = .low
        }

        let detail: String
        if framesChecked > 0 {
            detail = "\(framesMeetingGoal) of \(framesChecked) checked frames met the \(diagnostics.preferredVisibleCount)-reference visibility goal. \(referencesUsed) references contributed to calibration."
        } else {
            detail = "\(referencesUsed) references contributed to calibration. Target: \(diagnostics.targetCount), minimum together: \(diagnostics.minimumVisibleTogether)."
        }

        return StockpileConfidenceLens(
            id: "references",
            label: "References",
            state: state,
            detail: detail
        )
    }

    private static func captureLens(
        from captureQuality: StockpileCaptureQualityPayload?
    ) -> StockpileConfidenceLens? {
        guard let captureQuality else {
            return nil
        }

        let metrics = [
            ("Reference visibility", captureQuality.referenceVisibilityScore),
            ("Coverage", captureQuality.perimeterCoverageScore),
            ("Motion", captureQuality.motionStabilityScore),
            ("Overall guidance", captureQuality.overallGuidanceScore),
        ].compactMap { label, score in
            score.map { (label, $0) }
        }

        guard metrics.isEmpty == false else {
            return nil
        }

        let strongestMetric = metrics.max(by: { $0.1 < $1.1 })!
        let weakestMetric = metrics.min(by: { $0.1 < $1.1 })!
        let averageScore = metrics.map { $0.1 }.reduce(0, +) / Double(metrics.count)

        let state: StockpileConfidenceLensState
        switch averageScore {
        case 0.75...:
            state = .high
        case 0.45...:
            state = .medium
        default:
            state = .low
        }

        return StockpileConfidenceLens(
            id: "capture",
            label: "Capture",
            state: state,
            detail: "Strongest signal: \(strongestMetric.0.lowercased()) (\(percentLabel(for: strongestMetric.1))). Weakest signal: \(weakestMetric.0.lowercased()) (\(percentLabel(for: weakestMetric.1)))."
        )
    }

    private static func percentLabel(for rawScore: Double) -> String {
        "\(Int((rawScore * 100).rounded()))%"
    }
}
