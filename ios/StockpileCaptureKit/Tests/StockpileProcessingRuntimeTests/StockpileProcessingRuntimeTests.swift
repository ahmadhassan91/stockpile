import Foundation
import XCTest
@testable import StockpileMobileAPI
@testable import StockpileProcessingRuntime

private actor RecordingSleeper: StockpileProcessingRuntimeSleeping {
    private(set) var sleptDurations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        sleptDurations.append(duration)
    }
}

private actor ScriptedService: StockpileMobileAPIServicing {
    enum ScriptedError: Error {
        case unimplemented
        case exhausted
        case resultUnavailable
    }

    private var statuses: [StockpileProcessingJobStatus]
    private let result: StockpileResultPayload
    private(set) var fetchedJobIDs: [String] = []
    private(set) var fetchedResultIDs: [String] = []

    init(statuses: [StockpileProcessingJobStatus], result: StockpileResultPayload) {
        self.statuses = statuses
        self.result = result
    }

    func createCaptureSession(request: StockpileCaptureSessionCreateRequest) async throws -> StockpileCaptureSession {
        throw ScriptedError.unimplemented
    }

    func createUploadAuthorization(request: StockpileUploadRequest) async throws -> StockpileUploadAuthorization {
        throw ScriptedError.unimplemented
    }

    func fetchProcessingJob(jobID: String) async throws -> StockpileProcessingJobStatus {
        fetchedJobIDs.append(jobID)
        guard !statuses.isEmpty else {
            throw ScriptedError.exhausted
        }

        return statuses.removeFirst()
    }

    func fetchResult(runID: String) async throws -> StockpileResultPayload {
        fetchedResultIDs.append(runID)
        guard runID == result.runID else {
            throw ScriptedError.resultUnavailable
        }
        return result
    }

    func fetchRecentResults(
        limit: Int,
        siteID: String?,
        sessionID: String?
    ) async throws -> [StockpileResultPayload] {
        limit > 0 ? [result] : []
    }
}

private actor FlakyScriptedService: StockpileMobileAPIServicing {
    enum JobResponse {
        case error(StockpileMobileAPIError)
        case status(StockpileProcessingJobStatus)
    }

    enum ResultResponse {
        case error(StockpileMobileAPIError)
        case result(StockpileResultPayload)
    }

    enum FlakyError: Error {
        case unimplemented
        case exhausted
    }

    private var jobResponses: [JobResponse]
    private var resultResponses: [ResultResponse]
    private(set) var fetchedJobIDs: [String] = []
    private(set) var fetchedResultIDs: [String] = []

    init(jobResponses: [JobResponse], resultResponses: [ResultResponse]) {
        self.jobResponses = jobResponses
        self.resultResponses = resultResponses
    }

    func createCaptureSession(request: StockpileCaptureSessionCreateRequest) async throws -> StockpileCaptureSession {
        throw FlakyError.unimplemented
    }

    func createUploadAuthorization(request: StockpileUploadRequest) async throws -> StockpileUploadAuthorization {
        throw FlakyError.unimplemented
    }

    func fetchProcessingJob(jobID: String) async throws -> StockpileProcessingJobStatus {
        fetchedJobIDs.append(jobID)
        guard !jobResponses.isEmpty else {
            throw FlakyError.exhausted
        }

        switch jobResponses.removeFirst() {
        case .error(let error):
            throw error
        case .status(let status):
            return status
        }
    }

    func fetchResult(runID: String) async throws -> StockpileResultPayload {
        fetchedResultIDs.append(runID)
        guard !resultResponses.isEmpty else {
            throw FlakyError.exhausted
        }

        switch resultResponses.removeFirst() {
        case .error(let error):
            throw error
        case .result(let result):
            return result
        }
    }

    func fetchRecentResults(
        limit: Int,
        siteID: String?,
        sessionID: String?
    ) async throws -> [StockpileResultPayload] {
        []
    }
}

final class StockpileProcessingRuntimeTests: XCTestCase {
    func testPollUntilTerminalStateReturnsVerifiedResultAndSleepsBetweenProcessingPolls() async throws {
        let jobID = "job_001"
        let runID = "run_001"
        let provisionalMeasurement = StockpileProvisionalMeasurementPayload(
            status: "ready",
            basis: "tagged_reference_and_toe_coverage",
            volumeM3: 1713.6,
            weightTonnes: 3598.56,
            confidenceScore: 86,
            reason: "Enough signal was available to surface a provisional estimate.",
            updatedAt: .now
        )
        let service = ScriptedService(
            statuses: [
                StockpileProcessingJobStatus(
                    jobID: jobID,
                    runID: runID,
                    phase: .queued,
                    progress: 0.10,
                    headline: "Queued",
                    detail: "Waiting for processing.",
                    provisionalMeasurement: provisionalMeasurement,
                    updatedAt: .now
                ),
                StockpileProcessingJobStatus(
                    jobID: jobID,
                    runID: runID,
                    phase: .uploadReceived,
                    progress: 0.40,
                    headline: "Upload received",
                    detail: "Processing is warming up.",
                    provisionalMeasurement: provisionalMeasurement,
                    updatedAt: .now
                ),
                StockpileProcessingJobStatus(
                    jobID: jobID,
                    runID: runID,
                    phase: .verified,
                    progress: 1.00,
                    headline: "Verified result ready",
                    detail: "Final report is ready.",
                    provisionalMeasurement: provisionalMeasurement,
                    updatedAt: .now
                ),
            ],
            result: StockpileResultPayload(
                runID: runID,
                pileName: "North Yard 03",
                outcome: .verified,
                confidence: StockpileConfidencePayload(score: 91, label: "High", summary: "Strong reference coverage."),
                measurement: StockpileMeasurementPayload(volumeM3: 1711.20, weightTonnes: 3593.52, densityKgPerM3: 2100),
                warnings: [],
                blockers: [],
                recommendedAction: "Share the verified report.",
                provisionalMeasurement: provisionalMeasurement
            )
        )
        let sleeper = RecordingSleeper()
        let coordinator = StockpileProcessingRuntimeCoordinator(service: service, pollInterval: .milliseconds(250), sleeper: sleeper)

        let state = try await coordinator.pollUntilTerminalState(jobID: jobID)
        let sleptDurations = await sleeper.sleptDurations
        let fetchedJobIDs = await service.fetchedJobIDs
        let fetchedResultIDs = await service.fetchedResultIDs

        XCTAssertEqual(state.job.id, jobID)
        XCTAssertEqual(state.job.phase, .verified)
        XCTAssertEqual(state.job.provisionalMeasurement?.status, "ready")
        XCTAssertEqual(state.result?.outcome, .verified)
        XCTAssertEqual(state.result?.provisionalMeasurement?.basis, "tagged_reference_and_toe_coverage")
        XCTAssertEqual(sleptDurations, [.milliseconds(250), .milliseconds(250)])
        XCTAssertEqual(fetchedJobIDs, [jobID, jobID, jobID])
        XCTAssertEqual(fetchedResultIDs, [runID])
    }

    func testPollUntilTerminalStateReturnsReviewOnlyResultWithoutExtraDelay() async throws {
        let jobID = "job_002"
        let runID = "run_002"
        let service = ScriptedService(
            statuses: [
                StockpileProcessingJobStatus(
                    jobID: jobID,
                    runID: runID,
                    phase: .reviewOnly,
                    progress: 1.00,
                    headline: "Review-only result ready",
                    detail: "Final review is required.",
                    updatedAt: .now
                )
            ],
            result: StockpileResultPayload(
                runID: runID,
                pileName: "North Yard 04",
                outcome: .reviewOnly,
                confidence: StockpileConfidencePayload(score: 62, label: "Moderate", summary: "Needs a benchmark cross-check."),
                measurement: StockpileMeasurementPayload(volumeM3: 2528.43, weightTonnes: 5309.70, densityKgPerM3: 2100),
                warnings: ["Toe coverage is partial on the north edge."],
                blockers: ["Scale still needs review."],
                recommendedAction: "Review against the latest benchmark."
            )
        )
        let sleeper = RecordingSleeper()
        let coordinator = StockpileProcessingRuntimeCoordinator(service: service, pollInterval: .seconds(1), sleeper: sleeper)

        let state = try await coordinator.pollUntilTerminalState(jobID: jobID)
        let sleptDurations = await sleeper.sleptDurations
        let fetchedJobIDs = await service.fetchedJobIDs
        let fetchedResultIDs = await service.fetchedResultIDs

        switch state {
        case let .reviewOnly(job, result):
            XCTAssertEqual(job.phase, .reviewOnly)
            XCTAssertEqual(result.outcome, .reviewOnly)
            XCTAssertEqual(result.blockers, ["Scale still needs review."])
        default:
            XCTFail("Expected review-only terminal state")
        }
        XCTAssertEqual(sleptDurations, [])
        XCTAssertEqual(fetchedJobIDs, [jobID])
        XCTAssertEqual(fetchedResultIDs, [runID])
    }

    func testPollUntilTerminalStateReturnsBlockedResultWithoutExtraDelay() async throws {
        let jobID = "job_003"
        let runID = "run_003"
        let service = ScriptedService(
            statuses: [
                StockpileProcessingJobStatus(
                    jobID: jobID,
                    runID: runID,
                    phase: .blocked,
                    progress: 1.00,
                    headline: "Capture blocked",
                    detail: "The system could not verify this capture confidently enough to report it.",
                    updatedAt: .now
                )
            ],
            result: StockpileResultPayload(
                runID: runID,
                pileName: "North Yard 05",
                outcome: .blocked,
                confidence: StockpileConfidencePayload(score: 27, label: "Low", summary: "Tagged references were too weak."),
                measurement: nil,
                warnings: ["Only one tagged reference remained visible."],
                blockers: ["Scale disagreement exceeded the reporting threshold."],
                recommendedAction: "Retake the capture with stronger reference coverage."
            )
        )
        let sleeper = RecordingSleeper()
        let coordinator = StockpileProcessingRuntimeCoordinator(service: service, pollInterval: .seconds(1), sleeper: sleeper)

        let state = try await coordinator.pollUntilTerminalState(jobID: jobID)
        let sleptDurations = await sleeper.sleptDurations
        let fetchedJobIDs = await service.fetchedJobIDs
        let fetchedResultIDs = await service.fetchedResultIDs

        switch state {
        case let .blocked(job, result):
            XCTAssertEqual(job.phase, .blocked)
            XCTAssertEqual(result.outcome, .blocked)
            XCTAssertNil(result.measurement)
        default:
            XCTFail("Expected blocked terminal state")
        }
        XCTAssertEqual(sleptDurations, [])
        XCTAssertEqual(fetchedJobIDs, [jobID])
        XCTAssertEqual(fetchedResultIDs, [runID])
    }

    func testFetchLatestStateThrowsWhenTerminalResultDoesNotMatchPhase() async throws {
        let jobID = "job_004"
        let runID = "run_004"
        let service = ScriptedService(
            statuses: [
                StockpileProcessingJobStatus(
                    jobID: jobID,
                    runID: runID,
                    phase: .verified,
                    progress: 1.00,
                    headline: "Verified result ready",
                    detail: "Final report is ready.",
                    updatedAt: .now
                )
            ],
            result: StockpileResultPayload(
                runID: runID,
                pileName: "North Yard 06",
                outcome: .blocked,
                confidence: StockpileConfidencePayload(score: 10, label: "Low", summary: "This is intentionally inconsistent."),
                measurement: nil,
                warnings: [],
                blockers: ["Mismatch."],
                recommendedAction: "Do not use this result."
            )
        )
        let coordinator = StockpileProcessingRuntimeCoordinator(service: service, pollInterval: .seconds(1), sleeper: RecordingSleeper())

        do {
            _ = try await coordinator.fetchLatestState(jobID: jobID)
            XCTFail("Expected a result outcome mismatch")
        } catch let error as StockpileProcessingRuntimeError {
            switch error {
            case let .resultOutcomeMismatch(actualJobID, expected, actual):
                XCTAssertEqual(actualJobID, jobID)
                XCTAssertEqual(expected, .verified)
                XCTAssertEqual(actual, .blocked)
            default:
                XCTFail("Expected a result outcome mismatch error")
            }
        }
    }

    func testFetchLatestStateFallsBackToPhaseNarrativeWhenStatusCopyIsEmpty() async throws {
        let jobID = "job_005"
        let runID = "run_005"
        let service = ScriptedService(
            statuses: [
                StockpileProcessingJobStatus(
                    jobID: jobID,
                    runID: runID,
                    phase: .detectingReferences,
                    progress: 0.52,
                    headline: "   ",
                    detail: "",
                    updatedAt: .now
                )
            ],
            result: StockpileResultPayload(
                runID: runID,
                pileName: "North Yard 07",
                outcome: .verified,
                confidence: StockpileConfidencePayload(score: 93, label: "High", summary: "Not used in this test."),
                measurement: StockpileMeasurementPayload(volumeM3: 100, weightTonnes: 210, densityKgPerM3: 2100),
                warnings: [],
                blockers: [],
                recommendedAction: "Share the verified report."
            )
        )
        let coordinator = StockpileProcessingRuntimeCoordinator(service: service, pollInterval: .seconds(1), sleeper: RecordingSleeper())

        let state = try await coordinator.fetchLatestState(jobID: jobID)

        XCTAssertEqual(state.job.phase, .detectingReferences)
        XCTAssertEqual(state.job.headline, "Detecting tagged references")
        XCTAssertEqual(
            state.job.detail,
            "Checking which tagged references stayed visible strongly enough for scale."
        )
    }

    func testFetchLatestStateFallsBackToOutcomeActionWhenResultActionIsEmpty() async throws {
        let jobID = "job_006"
        let runID = "run_006"
        let service = ScriptedService(
            statuses: [
                StockpileProcessingJobStatus(
                    jobID: jobID,
                    runID: runID,
                    phase: .reviewOnly,
                    progress: 1.00,
                    headline: "",
                    detail: "",
                    updatedAt: .now
                )
            ],
            result: StockpileResultPayload(
                runID: runID,
                pileName: "North Yard 08",
                outcome: .reviewOnly,
                confidence: StockpileConfidencePayload(score: 61, label: "Moderate", summary: "Needs review."),
                measurement: StockpileMeasurementPayload(volumeM3: 202, weightTonnes: 424.2, densityKgPerM3: 2100),
                warnings: ["Reference alignment should be checked."],
                blockers: [],
                recommendedAction: "   "
            )
        )
        let coordinator = StockpileProcessingRuntimeCoordinator(service: service, pollInterval: .seconds(1), sleeper: RecordingSleeper())

        let state = try await coordinator.fetchLatestState(jobID: jobID)

        switch state {
        case let .reviewOnly(job, result):
            XCTAssertEqual(job.headline, "Review-only result ready")
            XCTAssertEqual(
                job.detail,
                "Processing completed, but this run still needs review before reporting."
            )
            XCTAssertEqual(
                result.recommendedAction,
                "Review against the latest site benchmark before treating this run as final."
            )
        default:
            XCTFail("Expected review-only terminal state")
        }
    }

    func testFetchLatestStateRetriesTransientJobFetchFailure() async throws {
        let jobID = "job_retry_001"
        let service = FlakyScriptedService(
            jobResponses: [
                .error(.transportFailure("The network connection was lost.")),
                .status(
                    StockpileProcessingJobStatus(
                        jobID: jobID,
                        runID: "run_retry_001",
                        phase: .uploadReceived,
                        progress: 0.33,
                        headline: "",
                        detail: "",
                        updatedAt: .now
                    )
                ),
            ],
            resultResponses: []
        )
        let sleeper = RecordingSleeper()
        let coordinator = StockpileProcessingRuntimeCoordinator(
            service: service,
            pollInterval: .milliseconds(250),
            sleeper: sleeper,
            transientFailureRetryLimit: 2
        )

        let state = try await coordinator.fetchLatestState(jobID: jobID)
        let sleptDurations = await sleeper.sleptDurations
        let fetchedJobIDs = await service.fetchedJobIDs

        XCTAssertEqual(state.job.phase, .uploadReceived)
        XCTAssertEqual(sleptDurations, [.milliseconds(250)])
        XCTAssertEqual(fetchedJobIDs, [jobID, jobID])
    }

    func testFetchLatestStateRetriesTerminalResultLookupUntilAvailable() async throws {
        let jobID = "job_retry_002"
        let runID = "run_retry_002"
        let result = StockpileResultPayload(
            runID: runID,
            pileName: "North Yard 09",
            outcome: .verified,
            confidence: StockpileConfidencePayload(score: 88, label: "High", summary: "References stabilized after upload."),
            measurement: StockpileMeasurementPayload(volumeM3: 510, weightTonnes: 1071, densityKgPerM3: 2100),
            warnings: [],
            blockers: [],
            recommendedAction: "Share the verified report."
        )
        let service = FlakyScriptedService(
            jobResponses: [
                .status(
                    StockpileProcessingJobStatus(
                        jobID: jobID,
                        runID: runID,
                        phase: .verified,
                        progress: 1,
                        headline: "Verified result ready",
                        detail: "Final report is ready.",
                        updatedAt: .now
                    )
                ),
                .status(
                    StockpileProcessingJobStatus(
                        jobID: jobID,
                        runID: runID,
                        phase: .verified,
                        progress: 1,
                        headline: "Verified result ready",
                        detail: "Final report is ready.",
                        updatedAt: .now
                    )
                ),
            ],
            resultResponses: [
                .error(.resultNotFound(runID)),
                .result(result),
            ]
        )
        let sleeper = RecordingSleeper()
        let coordinator = StockpileProcessingRuntimeCoordinator(
            service: service,
            pollInterval: .milliseconds(250),
            sleeper: sleeper,
            transientFailureRetryLimit: 2
        )

        let state = try await coordinator.fetchLatestState(jobID: jobID)
        let sleptDurations = await sleeper.sleptDurations
        let fetchedJobIDs = await service.fetchedJobIDs
        let fetchedResultIDs = await service.fetchedResultIDs

        XCTAssertEqual(state.job.phase, .verified)
        XCTAssertEqual(state.result?.outcome, .verified)
        XCTAssertEqual(sleptDurations, [.milliseconds(250)])
        XCTAssertEqual(fetchedJobIDs, [jobID, jobID])
        XCTAssertEqual(fetchedResultIDs, [runID, runID])
    }
}
