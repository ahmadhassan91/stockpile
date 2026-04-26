import Foundation

public enum StockpileLiveCaptureStage: String, Codable, Sendable, CaseIterable {
    case ready
    case acquiringReferences
    case walkingPerimeter
    case sealingCapture
    case uploading
    case provisionalResult
    case reviewQueue
    case recaptureRequired
}

public enum StockpileReferenceMarkerQuality: String, Codable, Sendable, CaseIterable {
    case confirmed
    case weak
    case missing
}

public struct StockpileReferenceMarkerSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let markerID: String
    public let visibleCount: Int
    public let confidence: Double
    public let quality: StockpileReferenceMarkerQuality

    public init(
        id: String? = nil,
        markerID: String,
        visibleCount: Int,
        confidence: Double,
        quality: StockpileReferenceMarkerQuality
    ) {
        self.id = id ?? markerID
        self.markerID = markerID
        self.visibleCount = max(0, visibleCount)
        self.confidence = min(max(confidence, 0), 1)
        self.quality = quality
    }
}

public struct StockpileDevicePoseTelemetry: Codable, Equatable, Sendable {
    public let samplesCaptured: Int
    public let headingStable: Bool
    public let motionStable: Bool
    public let lidarAssistAvailable: Bool

    public init(
        samplesCaptured: Int,
        headingStable: Bool,
        motionStable: Bool,
        lidarAssistAvailable: Bool
    ) {
        self.samplesCaptured = max(0, samplesCaptured)
        self.headingStable = headingStable
        self.motionStable = motionStable
        self.lidarAssistAvailable = lidarAssistAvailable
    }
}

public struct StockpileLiveCaptureQuality: Codable, Equatable, Sendable {
    public let referenceRecoveryScore: Double
    public let toeCoverageScore: Double
    public let perimeterCoverageScore: Double
    public let motionStabilityScore: Double

    public init(
        referenceRecoveryScore: Double,
        toeCoverageScore: Double,
        perimeterCoverageScore: Double,
        motionStabilityScore: Double
    ) {
        self.referenceRecoveryScore = min(max(referenceRecoveryScore, 0), 1)
        self.toeCoverageScore = min(max(toeCoverageScore, 0), 1)
        self.perimeterCoverageScore = min(max(perimeterCoverageScore, 0), 1)
        self.motionStabilityScore = min(max(motionStabilityScore, 0), 1)
    }

    public var isReadyForProvisionalMeasurement: Bool {
        referenceRecoveryScore >= 0.6
            && toeCoverageScore >= 0.65
            && perimeterCoverageScore >= 0.65
            && motionStabilityScore >= 0.55
    }
}

public struct StockpileProvisionalMeasurementHandoff: Codable, Equatable, Sendable {
    public let sessionID: String
    public let pileName: String
    public let stage: StockpileLiveCaptureStage
    public let quality: StockpileLiveCaptureQuality
    public let markerSnapshots: [StockpileReferenceMarkerSnapshot]
    public let telemetry: StockpileDevicePoseTelemetry

    public init(
        sessionID: String,
        pileName: String,
        stage: StockpileLiveCaptureStage,
        quality: StockpileLiveCaptureQuality,
        markerSnapshots: [StockpileReferenceMarkerSnapshot],
        telemetry: StockpileDevicePoseTelemetry
    ) {
        self.sessionID = sessionID
        self.pileName = pileName
        self.stage = stage
        self.quality = quality
        self.markerSnapshots = markerSnapshots
        self.telemetry = telemetry
    }

    public var operatorSummary: String {
        if quality.isReadyForProvisionalMeasurement {
            return "Capture is strong enough to request a provisional result."
        }

        return "Keep recording until tagged references and toe coverage stabilize."
    }
}

