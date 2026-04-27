import Foundation

/// State emitted by `StockpileMarkerlessCaptureSubmissionCoordinator` while the
/// markerless `.stockpilecapture` ZIP is being POSTed to the v2 backend.
///
/// The shape mirrors the v1 transfer-state pattern but stays markerless-specific
/// so it can coexist with the legacy `StockpileUploadTaskStage` flow without
/// stomping on it.
public enum StockpileMarkerlessCaptureSubmissionState: Equatable, Sendable {
    case idle
    case submitting(captureID: String)
    case submitted(receipt: StockpileCaptureBundleSubmissionReceipt)
    case failed(captureID: String, message: String)

    public var isInProgress: Bool {
        if case .submitting = self {
            return true
        }
        return false
    }

    public var isTerminal: Bool {
        switch self {
        case .submitted, .failed:
            return true
        case .idle, .submitting:
            return false
        }
    }

    public var receipt: StockpileCaptureBundleSubmissionReceipt? {
        if case let .submitted(receipt) = self {
            return receipt
        }
        return nil
    }

    public var failureMessage: String? {
        if case let .failed(_, message) = self {
            return message
        }
        return nil
    }
}

/// Inputs the coordinator requires to submit a markerless bundle. Mirrors the
/// header tuple `URLSessionCaptureBundleSubmitter` already accepts so the
/// coordinator stays a thin wrapper around the transport.
public struct StockpileMarkerlessCaptureSubmissionRequest: Equatable, Sendable {
    public let archiveURL: URL
    public let captureID: String
    public let siteID: String
    public let materialCode: String

    public init(
        archiveURL: URL,
        captureID: String,
        siteID: String,
        materialCode: String
    ) {
        self.archiveURL = archiveURL
        self.captureID = captureID
        self.siteID = siteID
        self.materialCode = materialCode
    }
}

/// Wraps a `StockpileCaptureBundleSubmitting` and tracks the markerless v2
/// submission lifecycle so the iOS feature store can consume a small,
/// testable surface instead of re-implementing transition logic per-callsite.
///
/// The coordinator is an actor so it can guarantee at-most-one in-flight
/// submission and serialise state transitions even when called from multiple
/// concurrency contexts (e.g., the ARKit bundle completion callback and the
/// SwiftUI store's main actor).
public actor StockpileMarkerlessCaptureSubmissionCoordinator {
    private let submitter: any StockpileCaptureBundleSubmitting
    private var state: StockpileMarkerlessCaptureSubmissionState = .idle
    private var submissionInFlight = false
    private var submitCallCount: Int = 0

    public init(submitter: any StockpileCaptureBundleSubmitting) {
        self.submitter = submitter
    }

    public var currentState: StockpileMarkerlessCaptureSubmissionState {
        state
    }

    /// Number of times `submit` has actually called the underlying submitter.
    /// Used by tests to assert "exactly once" behaviour without exposing
    /// internal queues.
    public var observedSubmitCallCount: Int {
        submitCallCount
    }

    /// Submit the bundle described by `request`. Returns the v2 receipt on
    /// success and surfaces a `StockpileCaptureBundleSubmissionError` on
    /// failure (the same error type the underlying submitter throws).
    ///
    /// Concurrent callers while a submission is already in flight receive a
    /// `runtime` error and the existing submission is left untouched.
    @discardableResult
    public func submit(
        _ request: StockpileMarkerlessCaptureSubmissionRequest
    ) async throws -> StockpileCaptureBundleSubmissionReceipt {
        if submissionInFlight {
            throw StockpileMarkerlessCaptureSubmissionCoordinatorError.alreadyInProgress
        }
        submissionInFlight = true
        state = .submitting(captureID: request.captureID)

        defer {
            submissionInFlight = false
        }

        submitCallCount += 1

        do {
            let receipt = try await submitter.submitCaptureBundle(
                at: request.archiveURL,
                captureID: request.captureID,
                siteID: request.siteID,
                materialCode: request.materialCode
            )
            state = .submitted(receipt: receipt)
            return receipt
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? "\(error)"
            state = .failed(captureID: request.captureID, message: message)
            throw error
        }
    }

    /// Reset state back to `.idle`. Useful when the operator restarts a
    /// markerless run after a failure so the UI doesn't leak a stale error.
    public func reset() {
        guard submissionInFlight == false else {
            // Don't tear down state mid-flight — that would race with the
            // pending submitter task. Callers should `await` completion first.
            return
        }
        state = .idle
    }
}

public enum StockpileMarkerlessCaptureSubmissionCoordinatorError: Error, LocalizedError, Sendable {
    case alreadyInProgress

    public var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            return "A markerless capture submission is already in progress."
        }
    }
}
