import Foundation
import StockpileMobileAPI

public actor StockpileProcessingRuntimeCoordinator {
    private let service: any StockpileMobileAPIServicing
    private let sleeper: any StockpileProcessingRuntimeSleeping
    private let pollInterval: Duration
    private let transientFailureRetryLimit: Int

    public init(
        service: any StockpileMobileAPIServicing,
        pollInterval: Duration = .seconds(2),
        sleeper: any StockpileProcessingRuntimeSleeping = SystemStockpileProcessingRuntimeSleeper(),
        transientFailureRetryLimit: Int = 3
    ) {
        self.service = service
        self.pollInterval = pollInterval
        self.sleeper = sleeper
        self.transientFailureRetryLimit = max(0, transientFailureRetryLimit)
    }

    public func fetchLatestState(jobID: String) async throws -> StockpileProcessingRuntimeState {
        try await fetchLatestState(jobID: jobID, retryLimit: transientFailureRetryLimit)
    }

    public func pollUntilTerminalState(jobID: String) async throws -> StockpileProcessingRuntimeState {
        while true {
            try Task.checkCancellation()
            let state = try await fetchLatestState(jobID: jobID)
            if state.isTerminal {
                return state
            }

            try await sleepUntilNextPoll()
        }
    }

    public func sleepUntilNextPoll() async throws {
        try await sleeper.sleep(for: pollInterval)
    }

    private func fetchLatestState(
        jobID: String,
        retryLimit: Int
    ) async throws -> StockpileProcessingRuntimeState {
        var attempt = 0

        while true {
            do {
                let status = try await service.fetchProcessingJob(jobID: jobID)
                let job = StockpileProcessingRuntimeJobState(status: status)
                return try await makeState(job: job)
            } catch {
                guard attempt < retryLimit,
                      let retryDelay = retryDelay(for: error) else {
                    throw error
                }

                attempt += 1
                try await sleeper.sleep(for: retryDelay)
            }
        }
    }

    private func makeState(job: StockpileProcessingRuntimeJobState) async throws -> StockpileProcessingRuntimeState {
        switch job.phase {
        case .queued, .uploadAuthorized, .uploadReceived, .extractingFrames, .detectingReferences, .reconstructing, .calibrating, .computingVolume:
            return .processing(job: job)
        case .verified:
            return try await fetchTerminalState(job: job, expectedOutcome: .verified)
        case .reviewOnly:
            return try await fetchTerminalState(job: job, expectedOutcome: .reviewOnly)
        case .blocked:
            return try await fetchTerminalState(job: job, expectedOutcome: .blocked)
        case .failed:
            throw StockpileProcessingRuntimeError.jobFailed(
                jobID: job.id,
                headline: job.headline,
                detail: job.detail
            )
        }
    }

    private func fetchTerminalState(
        job: StockpileProcessingRuntimeJobState,
        expectedOutcome: StockpileRunOutcome
    ) async throws -> StockpileProcessingRuntimeState {
        let result = try await fetchResult(runID: job.runID)
        guard result.outcome == expectedOutcome else {
            throw StockpileProcessingRuntimeError.resultOutcomeMismatch(
                jobID: job.id,
                expected: expectedOutcome,
                actual: result.outcome
            )
        }

        switch expectedOutcome {
        case .verified:
            return .verified(job: job, result: result)
        case .reviewOnly:
            return .reviewOnly(job: job, result: result)
        case .blocked:
            return .blocked(job: job, result: result)
        }
    }

    private func fetchResult(runID: String) async throws -> StockpileProcessingRuntimeResultState {
        let payload = try await service.fetchResult(runID: runID)
        return StockpileProcessingRuntimeResultState(payload: payload)
    }

    private func retryDelay(for error: Error) -> Duration? {
        guard let error = error as? StockpileMobileAPIError else {
            return nil
        }

        switch error {
        case .jobNotFound, .resultNotFound, .invalidResponse, .transportFailure:
            return pollInterval
        case let .rateLimited(retryAfter, _):
            if let retryAfter, retryAfter.isFinite, retryAfter > 0 {
                return .milliseconds(Int64((retryAfter * 1_000).rounded()))
            }
            return pollInterval
        case let .requestFailed(statusCode, _):
            if statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode) {
                return pollInterval
            }
            return nil
        case .serverError:
            return pollInterval
        case .sessionNotFound,
             .invalidRequestURL,
             .authenticationRequired,
             .forbidden,
             .validationFailed,
             .decodingFailure,
             .encodingFailure:
            return nil
        }
    }
}
