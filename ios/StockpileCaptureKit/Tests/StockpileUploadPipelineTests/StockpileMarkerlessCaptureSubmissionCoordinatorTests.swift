import XCTest
@testable import StockpileUploadPipeline

final class StockpileMarkerlessCaptureSubmissionCoordinatorTests: XCTestCase {

    func testSubmitInvokesUnderlyingSubmitterExactlyOnceWithRequestFields() async throws {
        let recordingSubmitter = RecordingCaptureBundleSubmitter(
            behaviour: .success(.init(
                captureID: "cap_42",
                jobID: "job_42",
                resultID: "res_42",
                status: "completed"
            ))
        )
        let coordinator = StockpileMarkerlessCaptureSubmissionCoordinator(
            submitter: recordingSubmitter
        )

        let request = StockpileMarkerlessCaptureSubmissionRequest(
            archiveURL: URL(fileURLWithPath: "/tmp/bundle.stockpilecapture"),
            captureID: "cap_42",
            siteID: "site_north",
            materialCode: "aggregate_5_14"
        )

        let receipt = try await coordinator.submit(request)

        let recordedCalls = await recordingSubmitter.recordedCalls
        XCTAssertEqual(recordedCalls.count, 1)
        XCTAssertEqual(recordedCalls.first?.archiveURL, request.archiveURL)
        XCTAssertEqual(recordedCalls.first?.captureID, "cap_42")
        XCTAssertEqual(recordedCalls.first?.siteID, "site_north")
        XCTAssertEqual(recordedCalls.first?.materialCode, "aggregate_5_14")

        XCTAssertEqual(receipt.captureID, "cap_42")
        XCTAssertEqual(receipt.jobID, "job_42")
        XCTAssertEqual(receipt.resultID, "res_42")

        let state = await coordinator.currentState
        XCTAssertEqual(state.receipt?.captureID, "cap_42")
        XCTAssertTrue(state.isTerminal)
        XCTAssertFalse(state.isInProgress)

        let observedCount = await coordinator.observedSubmitCallCount
        XCTAssertEqual(observedCount, 1)
    }

    func testSubmissionFailureExposesRetryableFailedState() async throws {
        let failingSubmitter = MockStockpileCaptureBundleSubmitter(
            behaviour: .failure(.httpError(statusCode: 503, body: "service unavailable"))
        )
        let coordinator = StockpileMarkerlessCaptureSubmissionCoordinator(
            submitter: failingSubmitter
        )

        let request = StockpileMarkerlessCaptureSubmissionRequest(
            archiveURL: URL(fileURLWithPath: "/tmp/bundle.stockpilecapture"),
            captureID: "cap_503",
            siteID: "site_a",
            materialCode: "m"
        )

        do {
            _ = try await coordinator.submit(request)
            XCTFail("expected coordinator to surface the underlying HTTP error")
        } catch StockpileCaptureBundleSubmissionError.httpError(let code, _) {
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let state = await coordinator.currentState
        switch state {
        case .failed(let captureID, let message):
            XCTAssertEqual(captureID, "cap_503")
            XCTAssertFalse(message.isEmpty, "operator-facing failure must carry a non-empty message")
        default:
            XCTFail("expected failed state, got \(state)")
        }
    }

    func testResetReturnsToIdleAfterTerminalState() async throws {
        let coordinator = StockpileMarkerlessCaptureSubmissionCoordinator(
            submitter: MockStockpileCaptureBundleSubmitter(
                receipt: .init(captureID: "x", jobID: "y", status: "completed")
            )
        )
        _ = try await coordinator.submit(
            .init(
                archiveURL: URL(fileURLWithPath: "/tmp/x.stockpilecapture"),
                captureID: "x",
                siteID: "s",
                materialCode: "m"
            )
        )

        await coordinator.reset()
        let state = await coordinator.currentState
        XCTAssertEqual(state, .idle)
    }

    func testFailedStateAllowsRetryBySubmittingAgain() async throws {
        // First call fails, second call succeeds. The same archive bytes are
        // re-submitted, exercising the "retry handle" path the feature store
        // wires up through `retryMarkerlessSubmission`.
        let toggleSubmitter = ToggleableSubmitter(
            firstError: .httpError(statusCode: 500, body: "boom"),
            secondReceipt: .init(
                captureID: "cap_retry",
                jobID: "job_retry",
                status: "completed"
            )
        )
        let coordinator = StockpileMarkerlessCaptureSubmissionCoordinator(
            submitter: toggleSubmitter
        )

        let request = StockpileMarkerlessCaptureSubmissionRequest(
            archiveURL: URL(fileURLWithPath: "/tmp/retry.stockpilecapture"),
            captureID: "cap_retry",
            siteID: "site",
            materialCode: "m"
        )

        do {
            _ = try await coordinator.submit(request)
            XCTFail("first submission should fail")
        } catch StockpileCaptureBundleSubmissionError.httpError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let failedState = await coordinator.currentState
        if case .failed = failedState {
            // good
        } else {
            XCTFail("expected failed state, got \(failedState)")
        }

        // Retry: submit again with the same request and verify the success path
        // rolls the state forward to `.submitted`.
        let receipt = try await coordinator.submit(request)
        XCTAssertEqual(receipt.captureID, "cap_retry")

        let finalState = await coordinator.currentState
        XCTAssertEqual(finalState.receipt?.captureID, "cap_retry")

        let totalCalls = await coordinator.observedSubmitCallCount
        XCTAssertEqual(totalCalls, 2, "retry should make a second call to the submitter")
    }

    func testStateProgressesThroughSubmittingThenSubmittedWhileMatchingCaptureID() async throws {
        // Drive the submitter via a continuation so we can observe the
        // `.submitting` state while the underlying request is still in flight.
        // This proves the live HUD readout the SwiftUI store consumes will
        // briefly publish a "submitting" state, exactly like the v1 transfer
        // flow signals "uploading".
        let submitter = ContinuationSubmitter()
        let coordinator = StockpileMarkerlessCaptureSubmissionCoordinator(submitter: submitter)

        let request = StockpileMarkerlessCaptureSubmissionRequest(
            archiveURL: URL(fileURLWithPath: "/tmp/gate.stockpilecapture"),
            captureID: "cap_gate",
            siteID: "s",
            materialCode: "m"
        )

        let submissionTask = Task {
            try await coordinator.submit(request)
        }

        // Wait until the submitter has been called at least once.
        for _ in 0..<200 {
            let calls = await submitter.callCount
            if calls > 0 {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let inFlightState = await coordinator.currentState
        switch inFlightState {
        case .submitting(let captureID):
            XCTAssertEqual(captureID, "cap_gate")
        default:
            XCTFail("expected submitting state, got \(inFlightState)")
        }

        await submitter.finish(
            with: .init(captureID: "cap_gate", jobID: "j", status: "completed")
        )

        let receipt = try await submissionTask.value
        XCTAssertEqual(receipt.captureID, "cap_gate")

        let finalState = await coordinator.currentState
        XCTAssertEqual(finalState.receipt?.captureID, "cap_gate")
    }
}

// MARK: - Test doubles

/// Submitter that records every call so tests can assert `submit(_:)` was
/// called exactly once with the right arguments.
private actor RecordingCaptureBundleSubmitter: StockpileCaptureBundleSubmitting {
    struct Call: Equatable {
        let archiveURL: URL
        let captureID: String
        let siteID: String
        let materialCode: String
    }

    enum Behaviour {
        case success(StockpileCaptureBundleSubmissionReceipt)
        case failure(StockpileCaptureBundleSubmissionError)
    }

    private let behaviour: Behaviour
    private(set) var recordedCalls: [Call] = []

    init(behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    nonisolated func submitCaptureBundle(
        at fileURL: URL,
        captureID: String,
        siteID: String,
        materialCode: String
    ) async throws -> StockpileCaptureBundleSubmissionReceipt {
        try await record(
            archiveURL: fileURL,
            captureID: captureID,
            siteID: siteID,
            materialCode: materialCode
        )
    }

    private func record(
        archiveURL: URL,
        captureID: String,
        siteID: String,
        materialCode: String
    ) async throws -> StockpileCaptureBundleSubmissionReceipt {
        recordedCalls.append(
            Call(
                archiveURL: archiveURL,
                captureID: captureID,
                siteID: siteID,
                materialCode: materialCode
            )
        )
        switch behaviour {
        case let .success(receipt):
            return receipt
        case let .failure(error):
            throw error
        }
    }
}

/// Submitter that throws once, then succeeds. Used to prove the coordinator
/// can be retried after a transient HTTP failure.
private actor ToggleableSubmitter: StockpileCaptureBundleSubmitting {
    private let firstError: StockpileCaptureBundleSubmissionError
    private let secondReceipt: StockpileCaptureBundleSubmissionReceipt
    private var hasThrown: Bool = false

    init(
        firstError: StockpileCaptureBundleSubmissionError,
        secondReceipt: StockpileCaptureBundleSubmissionReceipt
    ) {
        self.firstError = firstError
        self.secondReceipt = secondReceipt
    }

    nonisolated func submitCaptureBundle(
        at fileURL: URL,
        captureID: String,
        siteID: String,
        materialCode: String
    ) async throws -> StockpileCaptureBundleSubmissionReceipt {
        try await next()
    }

    private func next() async throws -> StockpileCaptureBundleSubmissionReceipt {
        if hasThrown {
            return secondReceipt
        }
        hasThrown = true
        throw firstError
    }
}

/// Submitter that blocks on a continuation so the test can drive it manually.
/// Lets us observe the in-flight `.submitting` state without races.
private actor ContinuationSubmitter: StockpileCaptureBundleSubmitting {
    private(set) var callCount: Int = 0
    private var continuation: CheckedContinuation<StockpileCaptureBundleSubmissionReceipt, Error>?

    nonisolated func submitCaptureBundle(
        at fileURL: URL,
        captureID: String,
        siteID: String,
        materialCode: String
    ) async throws -> StockpileCaptureBundleSubmissionReceipt {
        try await register()
    }

    private func register() async throws -> StockpileCaptureBundleSubmissionReceipt {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(with receipt: StockpileCaptureBundleSubmissionReceipt) {
        continuation?.resume(returning: receipt)
        continuation = nil
    }
}
