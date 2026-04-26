import Foundation
import StockpileMobileAPI

public struct StockpileProcessingRuntimeJobState: Sendable, Equatable, Identifiable {
    public let status: StockpileProcessingJobStatus

    public var id: String { status.jobID }
    public var runID: String { status.runID }
    public var phase: StockpileJobPhase { status.phase }
    public var progress: Double { status.progress }
    public var headline: String { status.headline.stockpileNonEmptyTrimmed ?? phase.stockpileFallbackHeadline }
    public var detail: String { status.detail.stockpileNonEmptyTrimmed ?? phase.stockpileFallbackDetail }
    public var provisionalMeasurement: StockpileProvisionalMeasurementPayload? { status.provisionalMeasurement }
    public var updatedAt: Date { status.updatedAt }
    public var isTerminal: Bool { status.isTerminal }

    public init(status: StockpileProcessingJobStatus) {
        self.status = status
    }
}

public struct StockpileProcessingRuntimeResultState: Sendable, Equatable, Identifiable {
    public let payload: StockpileResultPayload

    public var id: String { payload.runID }
    public var runID: String { payload.runID }
    public var pileName: String { payload.pileName }
    public var outcome: StockpileRunOutcome { payload.outcome }
    public var confidence: StockpileConfidencePayload { payload.confidence }
    public var measurement: StockpileMeasurementPayload? { payload.measurement }
    public var captureQuality: StockpileCaptureQualityPayload? { payload.captureQuality }
    public var referenceDiagnostics: StockpileReferenceDiagnosticsPayload? { payload.referenceDiagnostics }
    public var provisionalMeasurement: StockpileProvisionalMeasurementPayload? { payload.provisionalMeasurement }
    public var reportURL: URL? { payload.reportURL }
    public var warnings: [String] { payload.warnings }
    public var blockers: [String] { payload.blockers }
    public var recommendedAction: String {
        payload.recommendedAction.stockpileNonEmptyTrimmed ?? outcome.stockpileFallbackRecommendedAction
    }

    public init(payload: StockpileResultPayload) {
        self.payload = payload
    }
}

public enum StockpileProcessingRuntimeState: Sendable, Equatable, Identifiable {
    case processing(job: StockpileProcessingRuntimeJobState)
    case reviewOnly(job: StockpileProcessingRuntimeJobState, result: StockpileProcessingRuntimeResultState)
    case verified(job: StockpileProcessingRuntimeJobState, result: StockpileProcessingRuntimeResultState)
    case blocked(job: StockpileProcessingRuntimeJobState, result: StockpileProcessingRuntimeResultState)

    public var id: String {
        job.id
    }

    public var job: StockpileProcessingRuntimeJobState {
        switch self {
        case let .processing(job):
            return job
        case let .reviewOnly(job, _):
            return job
        case let .verified(job, _):
            return job
        case let .blocked(job, _):
            return job
        }
    }

    public var result: StockpileProcessingRuntimeResultState? {
        switch self {
        case .processing:
            return nil
        case let .reviewOnly(_, result):
            return result
        case let .verified(_, result):
            return result
        case let .blocked(_, result):
            return result
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .processing:
            return false
        case .reviewOnly, .verified, .blocked:
            return true
        }
    }

    public var outcome: StockpileRunOutcome? {
        result?.outcome
    }
}

public enum StockpileProcessingRuntimeError: Error, Sendable, Equatable, LocalizedError {
    case jobFailed(jobID: String, headline: String, detail: String)
    case resultOutcomeMismatch(jobID: String, expected: StockpileRunOutcome, actual: StockpileRunOutcome)

    public var errorDescription: String? {
        switch self {
        case let .jobFailed(jobID, headline, detail):
            return "Processing job \(jobID) failed: \(headline). \(detail)"
        case let .resultOutcomeMismatch(jobID, expected, actual):
            return "Processing job \(jobID) returned \(actual) after a \(expected) terminal phase."
        }
    }
}

private extension StockpileJobPhase {
    var stockpileFallbackHeadline: String {
        switch self {
        case .queued:
            return "Capture queued"
        case .uploadAuthorized:
            return "Upload authorized"
        case .uploadReceived:
            return "Upload received"
        case .extractingFrames:
            return "Extracting frames"
        case .detectingReferences:
            return "Detecting tagged references"
        case .reconstructing:
            return "Reconstructing stockpile geometry"
        case .calibrating:
            return "Calibrating scale"
        case .computingVolume:
            return "Computing volume"
        case .verified:
            return "Verified result ready"
        case .reviewOnly:
            return "Review-only result ready"
        case .blocked:
            return "Capture blocked"
        case .failed:
            return "Processing failed"
        }
    }

    var stockpileFallbackDetail: String {
        switch self {
        case .queued:
            return "The upload is waiting for a processing worker."
        case .uploadAuthorized:
            return "The server is ready to receive the capture."
        case .uploadReceived:
            return "The video is already on the server and processing is about to begin."
        case .extractingFrames:
            return "Breaking the walkaround into frames and checking capture coverage."
        case .detectingReferences:
            return "Checking which tagged references stayed visible strongly enough for scale."
        case .reconstructing:
            return "Building the 3D stockpile surface from the selected frames."
        case .calibrating:
            return "Cross-checking tagged references before a report can be released."
        case .computingVolume:
            return "Finalizing pile segmentation and grid integration."
        case .verified:
            return "This run passed confidence thresholds and is ready for reporting."
        case .reviewOnly:
            return "Processing completed, but this run still needs review before reporting."
        case .blocked:
            return "Processing finished, but this capture could not be verified strongly enough to report."
        case .failed:
            return "The server could not complete this capture cleanly."
        }
    }
}

private extension StockpileRunOutcome {
    var stockpileFallbackRecommendedAction: String {
        switch self {
        case .verified:
            return "Share or export the verified report."
        case .reviewOnly:
            return "Review against the latest site benchmark before treating this run as final."
        case .blocked:
            return "Retake the capture with stronger reference coverage and full toe visibility."
        }
    }
}

private extension String {
    var stockpileNonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
