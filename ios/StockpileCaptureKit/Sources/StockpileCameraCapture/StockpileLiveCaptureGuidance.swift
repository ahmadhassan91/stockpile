import Foundation

public struct StockpileCaptureSceneAnalysis: Sendable, Equatable {
    public let capturedAt: Date
    public let referenceCandidateCount: Int
    public let referenceCandidateConfidence: Double
    public let brightnessScore: Double
    public let sharpnessScore: Double
    public let sceneChangeScore: Double
    public let structuredArtifactScore: Double
    public let decodedReferenceMarkerCount: Int
    public let decodedReferenceMarkerConfidence: Double?
    public let nativeReferenceMarkerCount: Int
    public let nativeReferenceMarkerConfidence: Double?
    public let materialSuggestion: String?
    public let materialSuggestionConfidence: Double?
    public let sceneFitConfidence: Double?
    public let sceneRejectionConfidence: Double?
    public let pileSegmentationConfidence: Double?
    public let toeSegmentationConfidence: Double?
    public let depthConfidence: Double?
    public let quickVolumeConfidence: Double?
    public let trackingConfidence: Double?

    public init(
        capturedAt: Date,
        referenceCandidateCount: Int,
        referenceCandidateConfidence: Double,
        brightnessScore: Double,
        sharpnessScore: Double,
        sceneChangeScore: Double,
        structuredArtifactScore: Double = 0,
        decodedReferenceMarkerCount: Int = 0,
        decodedReferenceMarkerConfidence: Double? = nil,
        nativeReferenceMarkerCount: Int = 0,
        nativeReferenceMarkerConfidence: Double? = nil,
        materialSuggestion: String? = nil,
        materialSuggestionConfidence: Double? = nil,
        sceneFitConfidence: Double? = nil,
        sceneRejectionConfidence: Double? = nil,
        pileSegmentationConfidence: Double? = nil,
        toeSegmentationConfidence: Double? = nil,
        depthConfidence: Double? = nil,
        quickVolumeConfidence: Double? = nil,
        trackingConfidence: Double? = nil
    ) {
        self.capturedAt = capturedAt
        self.referenceCandidateCount = max(0, referenceCandidateCount)
        self.referenceCandidateConfidence = Self.clamp(referenceCandidateConfidence)
        self.brightnessScore = Self.clamp(brightnessScore)
        self.sharpnessScore = Self.clamp(sharpnessScore)
        self.sceneChangeScore = Self.clamp(sceneChangeScore)
        self.structuredArtifactScore = Self.clamp(structuredArtifactScore)
        self.decodedReferenceMarkerCount = max(0, decodedReferenceMarkerCount)
        self.decodedReferenceMarkerConfidence = Self.clamp(decodedReferenceMarkerConfidence)
        self.nativeReferenceMarkerCount = max(0, nativeReferenceMarkerCount)
        self.nativeReferenceMarkerConfidence = Self.clamp(nativeReferenceMarkerConfidence)
        let normalizedMaterialSuggestion = materialSuggestion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.materialSuggestion = (normalizedMaterialSuggestion?.isEmpty == false)
            ? normalizedMaterialSuggestion
            : nil
        self.materialSuggestionConfidence = Self.clamp(materialSuggestionConfidence)
        self.sceneFitConfidence = Self.clamp(sceneFitConfidence)
        self.sceneRejectionConfidence = Self.clamp(sceneRejectionConfidence)
        self.pileSegmentationConfidence = Self.clamp(pileSegmentationConfidence)
        self.toeSegmentationConfidence = Self.clamp(toeSegmentationConfidence)
        self.depthConfidence = Self.clamp(depthConfidence)
        self.quickVolumeConfidence = Self.clamp(quickVolumeConfidence)
        self.trackingConfidence = Self.clamp(trackingConfidence)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func clamp(_ value: Double?) -> Double? {
        value.map { clamp($0) }
    }
}

struct StockpileLiveGuidanceProgress: Sendable, Equatable {
    let guidance: StockpileCaptureGuidanceSummary
    let completedSteps: Int
    let phase: StockpileCameraCaptureSessionPhase
}

enum StockpileLiveGuidanceModeConfig: Sendable, Equatable {
    case markerRequired
    case markerless

    var markerlessCaptureEnabled: Bool {
        self == .markerless
    }
}

enum StockpileLiveGuidanceEstimator {
    static func estimate(
        totalSteps: Int,
        manualCompletedSteps: Int,
        elapsedRecordingTime: TimeInterval,
        sceneCoverageAccumulator: Double,
        sceneAnalysis: StockpileCaptureSceneAnalysis,
        telemetry: StockpileCaptureSensorSnapshot?,
        markerlessCaptureEnabled: Bool = false,
        modeConfig: StockpileLiveGuidanceModeConfig = .markerRequired
    ) -> StockpileLiveGuidanceProgress {
        let markerlessCaptureEnabled = markerlessCaptureEnabled || modeConfig.markerlessCaptureEnabled
        let markerlessEvidence = markerlessCaptureEnabled
            ? markerlessSceneEvidence(from: sceneAnalysis, telemetry: telemetry)
            : nil
        let referenceVisibility = markerlessCaptureEnabled
            ? markerlessReferenceVisibilityMetric(from: sceneAnalysis, evidence: markerlessEvidence)
            : referenceVisibilityMetric(from: sceneAnalysis)
        let decodedReferenceQuality = markerlessCaptureEnabled
            ? nil
            : decodedReferenceQualityMetric(from: sceneAnalysis)
        let pileSegmentation = pileSegmentationMetric(from: sceneAnalysis)
        let toeSegmentation = toeSegmentationMetric(from: sceneAnalysis)
        let motion = motionMetric(from: telemetry, sceneAnalysis: sceneAnalysis)
        let coverage = coverageMetric(
            elapsedRecordingTime: elapsedRecordingTime,
            sceneCoverageAccumulator: sceneCoverageAccumulator,
            sceneAnalysis: sceneAnalysis,
            manualCompletedSteps: manualCompletedSteps,
            totalSteps: totalSteps
        )
        let sceneRejection = sceneRejectionMetric(
            from: sceneAnalysis,
            markerlessEvidence: markerlessEvidence
        )
        let sceneFit = markerlessEvidence.map {
            markerlessSceneFitMetric(from: sceneAnalysis, evidence: $0)
        } ?? sceneFitMetric(from: sceneAnalysis)
        let materialConfidence = materialConfidenceMetric(from: sceneAnalysis)
        let guidance = StockpileCaptureGuidanceSummary(
            referenceVisibility: referenceVisibility,
            coverage: coverage,
            motion: motion,
            decodedReferenceQuality: decodedReferenceQuality,
            pileSegmentation: pileSegmentation,
            toeSegmentation: toeSegmentation,
            sceneFit: sceneFit,
            sceneRejection: sceneRejection,
            materialConfidence: materialConfidence
        )

        let maximumCompletedSteps = max(totalSteps - 1, 0)
        let synthesizedCompletedSteps = Int(
            (coverage.score * Double(maximumCompletedSteps)).rounded(.toNearestOrAwayFromZero)
        )
        let completedSteps = min(
            max(manualCompletedSteps, synthesizedCompletedSteps),
            maximumCompletedSteps
        )
        let phase: StockpileCameraCaptureSessionPhase =
            guidance.isReadyToFinish && completedSteps >= maximumCompletedSteps
            ? .readyToFinish
            : .capturing

        return StockpileLiveGuidanceProgress(
            guidance: guidance,
            completedSteps: completedSteps,
            phase: phase
        )
    }

    private static func referenceVisibilityMetric(
        from sceneAnalysis: StockpileCaptureSceneAnalysis
    ) -> StockpileCaptureGuidanceMetric {
        let visibleReferenceCount = sceneAnalysis.strongestReferenceCount
        let confirmedReferenceCount = sceneAnalysis.confirmedReferenceCount
        let visualTrust = sceneAnalysis.visualReferenceTrust

        let score: Double
        let detail: String
        switch visibleReferenceCount {
        case 2...:
            if sceneAnalysis.hasExplicitReferenceConfirmation && confirmedReferenceCount < 2 {
                score = min(
                    0.6
                        + visualTrust * 0.12
                        + sceneAnalysis.nativeReferenceTrust * 0.12,
                    0.78
                )
                detail = confirmedReferenceCount == 1
                    ? "Only one tagged reference is holding. Bring a second into view."
                    : "Tagged references are visible. Keep two steady in frame."
            } else {
                score = min(
                    0.8
                        + visualTrust * 0.14
                        + sceneAnalysis.nativeReferenceTrust * 0.06,
                    0.98
                )
                detail = sceneAnalysis.decodedReferenceMarkerCount >= 2
                    ? "Two tagged references are locked. Keep them in frame."
                    : "Keep two tagged references in frame."
            }
        case 1:
            score = min(
                0.46
                    + visualTrust * 0.18
                    + sceneAnalysis.nativeReferenceTrust * 0.08,
                0.72
            )
            detail =
                (sceneAnalysis.nativeReferenceMarkerCount > 0 || sceneAnalysis.decodedReferenceMarkerCount > 0)
                ? "Only one tagged reference is holding. Pan until a second joins."
                : (
                    sceneAnalysis.sharpnessScore < 0.28
                    ? "Only one tagged reference is clear. Slow down for a second lock."
                    : "Only one tagged reference is visible. Pan until a second joins."
                )
        default:
            if sceneAnalysis.sceneRejectionTrust >= 0.72 {
                score = 0.16
                detail = "Reframe on the pile and tagged references."
            } else if sceneAnalysis.brightnessScore < 0.18 {
                score = 0.24
                detail = "Too dark to lock the tagged references. Reframe with better light."
            } else if sceneAnalysis.sharpnessScore < 0.18 {
                score = 0.28
                detail = "Frame is too soft to confirm the tagged references. Slow down."
            } else {
                score = 0.34
                detail = "Move until two tagged references are visible together."
            }
        }

        return StockpileCaptureGuidanceMetric(
            title: "Reference visibility",
            score: score,
            watchThreshold: 0.7,
            blockedThreshold: 0.45,
            detail: detail,
            observedCount: min(visibleReferenceCount, 2),
            targetCount: 2
        )
    }

    private static func markerlessReferenceVisibilityMetric(
        from sceneAnalysis: StockpileCaptureSceneAnalysis,
        evidence: MarkerlessSceneEvidence?
    ) -> StockpileCaptureGuidanceMetric {
        let optionalReferenceCount = min(sceneAnalysis.strongestReferenceCount, 2)
        let evidenceScore = evidence?.score ?? sceneAnalysis.markerlessVisualSceneFitTrust
        let score = min(max(0.82, evidenceScore * 0.12 + 0.78), 0.96)
        let detail = optionalReferenceCount > 0
            ? "Markerless capture is using depth and tracking; tagged references are optional."
            : "Markerless capture is using depth and tracking instead of tagged references."

        return StockpileCaptureGuidanceMetric(
            title: "LiDAR tracking",
            score: score,
            watchThreshold: 0.7,
            blockedThreshold: 0.2,
            detail: detail,
            observedCount: optionalReferenceCount,
            targetCount: nil
        )
    }

    private static func decodedReferenceQualityMetric(
        from sceneAnalysis: StockpileCaptureSceneAnalysis
    ) -> StockpileCaptureGuidanceMetric {
        let visibleReferenceCount = sceneAnalysis.strongestReferenceCount
        let confirmedReferenceCount = sceneAnalysis.confirmedReferenceCount
        let decodedReferenceCount = min(sceneAnalysis.decodedReferenceMarkerCount, 2)
        let decodedTrust = sceneAnalysis.decodedReferenceTrust
        let nativeTrust = sceneAnalysis.nativeReferenceTrust
        let visualTrust = sceneAnalysis.visualReferenceTrust

        let score: Double
        let detail: String
        if decodedReferenceCount >= 2 {
            score = min(0.84 + decodedTrust * 0.14, 0.98)
            detail = "Reference tags are decoding cleanly."
        } else if decodedReferenceCount == 1 {
            score = min(0.58 + decodedTrust * 0.12 + nativeTrust * 0.12, 0.76)
            detail = "One tag decoded. Hold flatter until a second resolves."
        } else if sceneAnalysis.hasExplicitReferenceConfirmation && confirmedReferenceCount >= 2 {
            score = min(0.48 + nativeTrust * 0.18 + visualTrust * 0.08, 0.68)
            detail = sceneAnalysis.sharpnessScore < 0.3
                ? "Tagged references are visible but too soft to decode. Steady the phone."
                : "Tagged references are visible but not decoding. Hold flatter."
        } else if visibleReferenceCount >= 2 {
            score = min(0.72 + visualTrust * 0.16, 0.9)
            detail = sceneAnalysis.hasExplicitReferenceConfirmation
                ? "Keep the tagged references square to the camera."
                : "Tagged references look stable. Keep them square to camera."
        } else if visibleReferenceCount == 1 {
            score = min(0.44 + visualTrust * 0.16, 0.66)
            detail = "Only one tagged reference looks stable. Pan until a second joins."
        } else {
            score = 0.28
            detail = "Keep two tagged references visible until they lock."
        }

        return StockpileCaptureGuidanceMetric(
            title: "Reference quality",
            score: score,
            watchThreshold: 0.76,
            blockedThreshold: 0.52,
            detail: detail,
            observedCount: decodedReferenceCount > 0
                ? decodedReferenceCount
                : min(confirmedReferenceCount, 2),
            targetCount: 2
        )
    }

    private static func pileSegmentationMetric(
        from sceneAnalysis: StockpileCaptureSceneAnalysis
    ) -> StockpileCaptureGuidanceMetric? {
        guard let pileTrust = sceneAnalysis.pileSegmentationTrust else {
            return nil
        }

        let score = min(0.18 + pileTrust * 0.82, 1)
        let detail: String
        if pileTrust >= 0.82 {
            detail = "Pile outline is separating cleanly from the background."
        } else if pileTrust >= 0.62 {
            detail = "Pile outline is settling. Keep the full face clear in frame."
        } else if pileTrust >= 0.38 {
            detail = "Recenter so the pile face stays dominant in frame."
        } else {
            detail = "Reframe so the full pile face separates from the background."
        }

        return StockpileCaptureGuidanceMetric(
            title: "Pile definition",
            score: score,
            watchThreshold: 0.72,
            blockedThreshold: 0.48,
            detail: detail
        )
    }

    private static func toeSegmentationMetric(
        from sceneAnalysis: StockpileCaptureSceneAnalysis
    ) -> StockpileCaptureGuidanceMetric? {
        guard let toeTrust = sceneAnalysis.toeSegmentationTrust else {
            return nil
        }

        let score = min(0.18 + toeTrust * 0.82, 1)
        let detail: String
        if toeTrust >= 0.82 {
            detail = "Toe boundary is staying visible through the lap."
        } else if toeTrust >= 0.62 {
            detail = "Toe read is settling. Keep the full base edge in frame."
        } else if toeTrust >= 0.38 {
            detail = "Hold wider so the toe boundary stays visible."
        } else {
            detail = "Keep the full toe boundary visible before you seal the clip."
        }

        return StockpileCaptureGuidanceMetric(
            title: "Toe definition",
            score: score,
            watchThreshold: 0.74,
            blockedThreshold: 0.5,
            detail: detail
        )
    }

    private static func coverageMetric(
        elapsedRecordingTime: TimeInterval,
        sceneCoverageAccumulator: Double,
        sceneAnalysis: StockpileCaptureSceneAnalysis,
        manualCompletedSteps: Int,
        totalSteps: Int
    ) -> StockpileCaptureGuidanceMetric {
        let maximumCompletedSteps = max(totalSteps - 1, 1)
        let manualFloor = min(max(Double(manualCompletedSteps) / Double(maximumCompletedSteps), 0), 1)
        let sceneTravel = min(max(sceneCoverageAccumulator, 0), 1)
        let timeAssist = min(max(elapsedRecordingTime / 24.0, 0), 0.5)
        let toeAssist = max((sceneAnalysis.toeSegmentationTrust ?? 0) - 0.55, 0) * 0.18
        let toePenalty = sceneAnalysis.toeSegmentationTrust.map { max(0.62 - $0, 0) * 0.42 } ?? 0
        let scenePenalty =
            sceneAnalysis.sceneRejectionTrust * 0.18
            + max(0.55 - sceneAnalysis.sceneFitTrust, 0) * 0.12
        let referenceAssist: Double
        if sceneAnalysis.confirmedReferenceCount >= 2 {
            referenceAssist = 0.14
        } else if sceneAnalysis.strongestReferenceCount >= 2 {
            referenceAssist = 0.08
        } else if sceneAnalysis.strongestReferenceCount == 1 {
            referenceAssist = 0.05
        } else {
            referenceAssist = 0
        }

        let rawScore = sceneTravel + timeAssist + referenceAssist + toeAssist - scenePenalty - toePenalty
        let score = min(max(manualFloor, rawScore), 1)
        let detail: String
        if let toeTrust = sceneAnalysis.toeSegmentationTrust, toeTrust < 0.38 {
            detail = "Keep the full toe boundary visible before you seal the clip."
        } else if let toeTrust = sceneAnalysis.toeSegmentationTrust, toeTrust < 0.6 {
            detail = "Keep the toe boundary visible all the way around the pile."
        } else if score >= 0.82 {
            detail = "Perimeter coverage looks strong. Finish the last visible edge and seal the clip."
        } else if score >= 0.6 {
            detail = "Coverage is building well. Keep the lap moving so the far edge is not missed."
        } else {
            detail = "Keep walking the toe boundary so the app sees more of the pile perimeter."
        }

        return StockpileCaptureGuidanceMetric(
            title: "Coverage",
            score: score,
            watchThreshold: 0.7,
            blockedThreshold: 0.5,
            detail: detail
        )
    }

    private static func motionMetric(
        from telemetry: StockpileCaptureSensorSnapshot?,
        sceneAnalysis: StockpileCaptureSceneAnalysis
    ) -> StockpileCaptureGuidanceMetric {
        guard let telemetry else {
            let score = min(0.52 + sceneAnalysis.sharpnessScore * 0.2, 0.7)
            return StockpileCaptureGuidanceMetric(
                title: "Motion",
                score: score,
                watchThreshold: 0.72,
                blockedThreshold: 0.5,
                detail: "Motion telemetry is still settling. Keep the phone steady while the lap continues."
            )
        }

        let score: Double
        let detail: String
        if telemetry.motionStable {
            if telemetry.headingSignalsIncluded && !telemetry.headingStable {
                score = 0.69
                detail = "Motion is steady, but heading is still settling. Keep the phone level for a moment."
            } else {
                score = min(0.82 + sceneAnalysis.sharpnessScore * 0.16, 0.97)
                detail = "Motion stability is strong enough for reconstruction."
            }
        } else {
            score = max(0.34 + sceneAnalysis.sharpnessScore * 0.12, 0.34)
            detail = "Slow down and keep the phone from swinging so the reconstruction stays stable."
        }

        return StockpileCaptureGuidanceMetric(
            title: "Motion",
            score: score,
            watchThreshold: 0.72,
            blockedThreshold: 0.5,
            detail: detail
        )
    }

    private static func sceneRejectionMetric(
        from sceneAnalysis: StockpileCaptureSceneAnalysis,
        markerlessEvidence: MarkerlessSceneEvidence? = nil
    ) -> StockpileCaptureGuidanceMetric {
        let rejectionTrust = sceneAnalysis.sceneRejectionTrust

        if let markerlessEvidence {
            let sceneFitTrust = max(sceneAnalysis.markerlessVisualSceneFitTrust, markerlessEvidence.score)
            let score: Double
            let detail: String
            if rejectionTrust >= 0.82 {
                score = 0.16
                detail = "Wrong scene. Reframe on the pile."
            } else if rejectionTrust >= 0.66 || sceneFitTrust < 0.3 {
                score = 0.42
                detail = "Frame is drifting off pile. Point back to the stockpile."
            } else if rejectionTrust >= 0.46 || sceneFitTrust < 0.52 {
                score = 0.62
                detail = "Keep more of the pile face in view."
            } else {
                score = min(
                    0.78
                        + sceneFitTrust * 0.16
                        + (markerlessEvidence.trackingScore ?? 0) * 0.04,
                    0.98
                )
                detail = "Scene matches a depth-assisted stockpile capture."
            }

            return StockpileCaptureGuidanceMetric(
                title: "Scene match",
                score: score,
                watchThreshold: 0.66,
                blockedThreshold: 0.36,
                detail: detail
            )
        }

        let sceneFitTrust = sceneAnalysis.sceneFitTrust
        let confirmedReferenceCount = sceneAnalysis.confirmedReferenceCount

        let score: Double
        let detail: String
        if rejectionTrust >= 0.78 || (sceneFitTrust < 0.28 && confirmedReferenceCount == 0) {
            score = 0.16
            detail = "Wrong scene. Reframe on the pile and tagged refs."
        } else if rejectionTrust >= 0.58 || (sceneFitTrust < 0.44 && confirmedReferenceCount <= 1) {
            score = 0.4
            detail = "Frame is drifting off pile. Point back to the stockpile."
        } else if rejectionTrust >= 0.38 || sceneFitTrust < 0.62 {
            score = 0.68
            detail = "Keep more of the pile face in view."
        } else {
            score = min(
                0.82
                    + sceneFitTrust * 0.14
                    + Double(min(confirmedReferenceCount, 2)) / 2.0 * 0.04,
                0.98
            )
            detail = "Scene matches a stockpile capture."
        }

        return StockpileCaptureGuidanceMetric(
            title: "Scene match",
            score: score,
            watchThreshold: 0.78,
            blockedThreshold: 0.5,
            detail: detail
        )
    }

    private static func sceneFitMetric(
        from sceneAnalysis: StockpileCaptureSceneAnalysis
    ) -> StockpileCaptureGuidanceMetric {
        let sceneFitTrust = sceneAnalysis.sceneFitTrust
        let confirmedReferenceLift = Double(min(sceneAnalysis.confirmedReferenceCount, 2)) / 2.0
        let baseScore = min(
            sceneFitTrust * 0.76
                + confirmedReferenceLift * 0.1
                + sceneAnalysis.sharpnessScore * 0.08
                + sceneAnalysis.brightnessScore * 0.06,
            1
        )
        let score: Double
        if let pileTrust = sceneAnalysis.pileSegmentationTrust {
            let toeCarry = max((sceneAnalysis.toeSegmentationTrust ?? 0) - 0.6, 0) * 0.06
            score = min(baseScore * 0.72 + pileTrust * 0.28 + toeCarry, 1)
        } else {
            score = baseScore
        }
        let detail: String

        if let pileTrust = sceneAnalysis.pileSegmentationTrust, pileTrust < 0.32 {
            detail = "Reframe so the full pile face separates from the background."
        } else if let pileTrust = sceneAnalysis.pileSegmentationTrust, pileTrust < 0.56 {
            detail = "Hold wider and keep the full pile face clear in frame."
        } else if let toeTrust = sceneAnalysis.toeSegmentationTrust, toeTrust < 0.42, score < 0.84 {
            detail = "Hold slightly wider so the pile face and toe stay connected in frame."
        } else if score >= 0.84 {
            detail = "Pile framing looks steady."
        } else if score >= 0.68 {
            detail = "Widen slightly so the pile stays dominant."
        } else {
            detail = "Let the pile fill more of the frame."
        }

        return StockpileCaptureGuidanceMetric(
            title: "Scene framing",
            score: score,
            watchThreshold: 0.72,
            blockedThreshold: 0.48,
            detail: detail
        )
    }

    private static func markerlessSceneFitMetric(
        from sceneAnalysis: StockpileCaptureSceneAnalysis,
        evidence: MarkerlessSceneEvidence
    ) -> StockpileCaptureGuidanceMetric {
        let score = evidence.score
        let detail: String

        if let pileTrust = sceneAnalysis.pileSegmentationTrust, pileTrust < 0.3 {
            detail = "Reframe so the full pile face separates from the background."
        } else if let quickVolumeScore = evidence.quickVolumeScore, quickVolumeScore >= 0.72, score >= 0.66 {
            detail = "Depth and quick volume agree with the pile framing."
        } else if let depthScore = evidence.depthScore, depthScore >= 0.7, score >= 0.66 {
            detail = "Depth and tracking support the pile framing."
        } else if score >= 0.66 {
            detail = "Pile framing looks steady."
        } else if score >= 0.48 {
            detail = "Keep the pile centered while depth and tracking settle."
        } else {
            detail = "Hold wider so depth and tracking can read the full pile face."
        }

        return StockpileCaptureGuidanceMetric(
            title: "Scene framing",
            score: score,
            watchThreshold: 0.66,
            blockedThreshold: 0.36,
            detail: detail
        )
    }

    private static func materialConfidenceMetric(
        from sceneAnalysis: StockpileCaptureSceneAnalysis
    ) -> StockpileCaptureGuidanceMetric? {
        guard let materialTrust = sceneAnalysis.materialConfidenceTrust else {
            return nil
        }

        let score = min(0.24 + materialTrust * 0.76, 1)
        let detail: String
        if materialTrust >= 0.8 {
            detail = sceneAnalysis.materialSuggestion.map { "\($0) read looks stable." }
                ?? "Material read looks stable."
        } else if materialTrust >= 0.55 {
            detail = "Material read is settling. Keep the pile centered."
        } else if sceneAnalysis.sceneRejectionTrust >= 0.58 {
            detail = "Stay on the pile face while the material read settles."
        } else {
            detail = "Material read is still uncertain. Keep the pile centered."
        }

        return StockpileCaptureGuidanceMetric(
            title: "Material confidence",
            score: score,
            watchThreshold: 0.72,
            blockedThreshold: 0.12,
            detail: detail
        )
    }

    private static func markerlessSceneEvidence(
        from sceneAnalysis: StockpileCaptureSceneAnalysis,
        telemetry: StockpileCaptureSensorSnapshot?
    ) -> MarkerlessSceneEvidence {
        let depthScore = maxOptional(
            sceneAnalysis.depthTrust,
            telemetry?.markerlessDepthTrust
        )
        let trackingScore = maxOptional(
            sceneAnalysis.trackingTrust,
            telemetry?.markerlessTrackingTrust
        )
        let quickVolumeScore = sceneAnalysis.quickVolumeTrust
        let segmentationScore = average(
            [
                sceneAnalysis.pileSegmentationTrust,
                sceneAnalysis.toeSegmentationTrust,
            ]
        )
        let visualScore = sceneAnalysis.markerlessVisualSceneFitTrust

        let sensorScore = weightedAverage(
            [
                (depthScore, 0.32),
                (quickVolumeScore, 0.3),
                (trackingScore, 0.24),
                (segmentationScore, 0.18),
            ]
        )
        let score = sensorScore.map { min(max($0 * 0.74 + visualScore * 0.26, 0), 1) }
            ?? visualScore

        return MarkerlessSceneEvidence(
            score: score,
            depthScore: depthScore,
            quickVolumeScore: quickVolumeScore,
            trackingScore: trackingScore
        )
    }

    private static func weightedAverage(_ values: [(Double?, Double)]) -> Double? {
        let weightedValues = values.compactMap { value, weight -> (Double, Double)? in
            guard let value else {
                return nil
            }
            return (value, weight)
        }
        let totalWeight = weightedValues.reduce(0.0) { partialResult, item in
            partialResult + item.1
        }
        guard totalWeight > 0 else {
            return nil
        }
        let total = weightedValues.reduce(0.0) { partialResult, item in
            partialResult + item.0 * item.1
        }
        return total / totalWeight
    }

    private static func average(_ values: [Double?]) -> Double? {
        let scores = values.compactMap { $0 }
        guard scores.isEmpty == false else {
            return nil
        }
        return scores.reduce(0, +) / Double(scores.count)
    }

    private static func maxOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private struct MarkerlessSceneEvidence {
        let score: Double
        let depthScore: Double?
        let quickVolumeScore: Double?
        let trackingScore: Double?
    }
}

private extension StockpileCaptureSceneAnalysis {
    var pileSegmentationTrust: Double? {
        StockpileCaptureSceneAnalysis.clamp(pileSegmentationConfidence)
    }

    var toeSegmentationTrust: Double? {
        StockpileCaptureSceneAnalysis.clamp(toeSegmentationConfidence)
    }

    var depthTrust: Double? {
        StockpileCaptureSceneAnalysis.clamp(depthConfidence)
    }

    var quickVolumeTrust: Double? {
        StockpileCaptureSceneAnalysis.clamp(quickVolumeConfidence)
    }

    var trackingTrust: Double? {
        StockpileCaptureSceneAnalysis.clamp(trackingConfidence)
    }

    var hasExplicitReferenceConfirmation: Bool {
        decodedReferenceMarkerCount > 0
            || nativeReferenceMarkerCount > 0
            || decodedReferenceMarkerConfidence != nil
            || nativeReferenceMarkerConfidence != nil
    }

    var strongestReferenceCount: Int {
        min(max(referenceCandidateCount, nativeReferenceMarkerCount, decodedReferenceMarkerCount), 3)
    }

    var confirmedReferenceCount: Int {
        if hasExplicitReferenceConfirmation {
            return min(max(nativeReferenceMarkerCount, decodedReferenceMarkerCount), 3)
        }

        return strongestReferenceCount
    }

    var visualReferenceTrust: Double {
        StockpileCaptureSceneAnalysis.clamp(
            referenceCandidateConfidence * 0.5
                + sharpnessScore * 0.3
                + brightnessScore * 0.2
        )
    }

    var decodedReferenceTrust: Double {
        if let decodedReferenceMarkerConfidence {
            return StockpileCaptureSceneAnalysis.clamp(decodedReferenceMarkerConfidence)
        }

        if hasExplicitReferenceConfirmation {
            guard decodedReferenceMarkerCount > 0 else {
                return 0
            }

            return StockpileCaptureSceneAnalysis.clamp(
                referenceCandidateConfidence * 0.68
                    + min(Double(decodedReferenceMarkerCount) / 2.0, 1) * 0.24
            )
        }

        guard strongestReferenceCount > 0 else {
            return 0
        }

        return StockpileCaptureSceneAnalysis.clamp(
            visualReferenceTrust * 0.82
                + min(Double(strongestReferenceCount) / 2.0, 1) * 0.18
        )
    }

    var nativeReferenceTrust: Double {
        if let nativeReferenceMarkerConfidence {
            return StockpileCaptureSceneAnalysis.clamp(nativeReferenceMarkerConfidence)
        }

        if hasExplicitReferenceConfirmation {
            guard nativeReferenceMarkerCount > 0 else {
                return 0
            }

            return StockpileCaptureSceneAnalysis.clamp(
                referenceCandidateConfidence * 0.66
                    + min(Double(nativeReferenceMarkerCount) / 2.0, 1) * 0.22
            )
        }

        guard strongestReferenceCount > 0 else {
            return 0
        }

        return StockpileCaptureSceneAnalysis.clamp(
            visualReferenceTrust * 0.78
                + min(Double(strongestReferenceCount) / 2.0, 1) * 0.12
        )
    }

    var sceneFitTrust: Double {
        if let sceneFitConfidence {
            return StockpileCaptureSceneAnalysis.clamp(sceneFitConfidence)
        }

        return StockpileCaptureSceneAnalysis.clamp(
            (1 - structuredArtifactScore) * 0.46
                + sharpnessScore * 0.12
                + brightnessScore * 0.08
                + visualReferenceTrust * 0.12
                + min(Double(strongestReferenceCount) / 2.0, 1) * 0.22
        )
    }

    var markerlessVisualSceneFitTrust: Double {
        if let sceneFitConfidence {
            return StockpileCaptureSceneAnalysis.clamp(sceneFitConfidence)
        }

        return StockpileCaptureSceneAnalysis.clamp(
            (1 - structuredArtifactScore) * 0.5
                + sharpnessScore * 0.22
                + brightnessScore * 0.14
                + (pileSegmentationTrust ?? 0) * 0.1
                + (toeSegmentationTrust ?? 0) * 0.04
        )
    }

    var sceneRejectionTrust: Double {
        if let sceneRejectionConfidence {
            return StockpileCaptureSceneAnalysis.clamp(sceneRejectionConfidence)
        }

        let sparseReferencePenalty: Double
        switch strongestReferenceCount {
        case 2...:
            sparseReferencePenalty = 0
        case 1:
            sparseReferencePenalty = 0.08
        default:
            sparseReferencePenalty = 0.18
        }

        return StockpileCaptureSceneAnalysis.clamp(
            structuredArtifactScore * 0.54
                + max(0.52 - sceneFitTrust, 0) * 0.7
                + sparseReferencePenalty
        )
    }

    var materialConfidenceTrust: Double? {
        if let materialSuggestionConfidence {
            return StockpileCaptureSceneAnalysis.clamp(materialSuggestionConfidence)
        }

        guard materialSuggestion != nil else {
            return nil
        }

        return StockpileCaptureSceneAnalysis.clamp(
            sceneFitTrust * 0.62
                + referenceCandidateConfidence * 0.14
        )
    }
}

private extension StockpileCaptureSensorSnapshot {
    var markerlessDepthTrust: Double? {
        if sensorMetadata?.depthDataIncluded == true {
            return lidarAssistAvailable ? 0.84 : 0.74
        }

        return lidarAssistAvailable ? 0.66 : nil
    }

    var markerlessTrackingTrust: Double? {
        let normalizedTrackingState = trackingState?.lowercased() ?? ""
        let trackingStateScore: Double?
        if normalizedTrackingState.contains("normal")
            || normalizedTrackingState.contains("active")
            || normalizedTrackingState.contains("running")
            || normalizedTrackingState.contains("tracking") {
            trackingStateScore = 0.82
        } else if normalizedTrackingState.contains("limited")
            || normalizedTrackingState.contains("initializing")
            || normalizedTrackingState.contains("relocalizing")
            || normalizedTrackingState.contains("settle") {
            trackingStateScore = 0.48
        } else {
            trackingStateScore = sampleCount > 0 ? 0.54 : nil
        }

        let motionScore: Double?
        if motionStable && (headingSignalsIncluded == false || headingStable) {
            motionScore = cameraCalibrationIncluded ? 0.88 : 0.82
        } else if motionStable {
            motionScore = 0.72
        } else {
            motionScore = nil
        }

        switch (trackingStateScore, motionScore) {
        case let (trackingStateScore?, motionScore?):
            return max(trackingStateScore, motionScore)
        case let (trackingStateScore?, nil):
            return trackingStateScore
        case let (nil, motionScore?):
            return motionScore
        case (nil, nil):
            return nil
        }
    }
}
