import Foundation

public struct StockpileMockRunScenario: Sendable, Equatable {
    public let snapshots: [StockpileJobSnapshot]
    public let result: StockpileResultPayload

    public init(snapshots: [StockpileJobSnapshot], result: StockpileResultPayload) {
        self.snapshots = snapshots.isEmpty ? [StockpileMockRunScenario.terminalSnapshot(for: result.outcome)] : snapshots
        self.result = result
    }

    public static func verifiedPreview(pileName: String = "North Yard 03") -> StockpileMockRunScenario {
        let result = StockpileResultPayload(
            runID: "run_verified_preview",
            pileName: pileName,
            outcome: .verified,
            confidence: StockpileConfidencePayload(
                score: 92,
                label: "High",
                summary: "Tagged references, toe visibility, and reconstruction all passed reporting thresholds."
            ),
            measurement: StockpileMeasurementPayload(volumeM3: 1711.20, weightTonnes: 3593.52, densityKgPerM3: 2100),
            warnings: [],
            blockers: [],
            recommendedAction: "Share or export the verified report."
        )

        return StockpileMockRunScenario(
            snapshots: [
                StockpileJobSnapshot(phase: .queued, progress: 0.05, headline: "Capture queued", detail: "Your upload is waiting for processing."),
                StockpileJobSnapshot(phase: .uploadReceived, progress: 0.15, headline: "Upload received", detail: "The server is preparing the video."),
                StockpileJobSnapshot(phase: .extractingFrames, progress: 0.30, headline: "Extracting frames", detail: "Breaking the capture into still frames."),
                StockpileJobSnapshot(phase: .detectingReferences, progress: 0.48, headline: "Detecting tagged references", detail: "Checking reference coverage and identity."),
                StockpileJobSnapshot(phase: .reconstructing, progress: 0.72, headline: "Reconstructing pile geometry", detail: "Sparse reconstruction is in progress."),
                StockpileJobSnapshot(phase: .calibrating, progress: 0.86, headline: "Calibrating scale", detail: "Cross-checking tagged references and device pose."),
                StockpileJobSnapshot(phase: .computingVolume, progress: 0.95, headline: "Computing volume", detail: "Finalizing footprint, ground plane, and weight."),
                StockpileMockRunScenario.terminalSnapshot(for: .verified),
            ],
            result: result
        )
    }

    public static func reviewOnlyPreview(pileName: String = "North Yard 03") -> StockpileMockRunScenario {
        let result = StockpileResultPayload(
            runID: "run_review_preview",
            pileName: pileName,
            outcome: .reviewOnly,
            confidence: StockpileConfidencePayload(
                score: 58,
                label: "Moderate",
                summary: "Processing completed, but scale still needs a benchmark cross-check."
            ),
            measurement: StockpileMeasurementPayload(volumeM3: 2528.43, weightTonnes: 5309.70, densityKgPerM3: 2100),
            warnings: ["Toe coverage is partial on the north edge."],
            blockers: ["Projection and camera-height checks are not fully aligned."],
            recommendedAction: "Review against the latest site benchmark before treating as final."
        )

        return StockpileMockRunScenario(
            snapshots: [
                StockpileJobSnapshot(phase: .queued, progress: 0.05, headline: "Capture queued", detail: "Your upload is waiting for processing."),
                StockpileJobSnapshot(phase: .uploadReceived, progress: 0.15, headline: "Upload received", detail: "The server is preparing the video."),
                StockpileJobSnapshot(phase: .extractingFrames, progress: 0.32, headline: "Extracting frames", detail: "Breaking the capture into still frames."),
                StockpileJobSnapshot(phase: .detectingReferences, progress: 0.50, headline: "Checking tagged references", detail: "The system is validating reference visibility."),
                StockpileJobSnapshot(phase: .reconstructing, progress: 0.74, headline: "Reconstructing pile geometry", detail: "Sparse reconstruction is still in progress."),
                StockpileJobSnapshot(phase: .calibrating, progress: 0.88, headline: "Calibrating scale", detail: "Cross-checking scale against reference visibility."),
                StockpileMockRunScenario.terminalSnapshot(for: .reviewOnly),
            ],
            result: result
        )
    }

    public static func blockedPreview(pileName: String = "North Yard 03") -> StockpileMockRunScenario {
        let result = StockpileResultPayload(
            runID: "run_blocked_preview",
            pileName: pileName,
            outcome: .blocked,
            confidence: StockpileConfidencePayload(
                score: 27,
                label: "Low",
                summary: "Tagged references were too weak to publish a trustworthy result."
            ),
            measurement: nil,
            warnings: ["Only one tagged reference remained visible through most of the walkaround."],
            blockers: ["Scale disagreement exceeded the reporting threshold."],
            recommendedAction: "Retake the capture with 2-3 tagged references visible and full toe coverage."
        )

        return StockpileMockRunScenario(
            snapshots: [
                StockpileJobSnapshot(phase: .queued, progress: 0.05, headline: "Capture queued", detail: "Your upload is waiting for processing."),
                StockpileJobSnapshot(phase: .uploadReceived, progress: 0.14, headline: "Upload received", detail: "The server is preparing the video."),
                StockpileJobSnapshot(phase: .extractingFrames, progress: 0.30, headline: "Extracting frames", detail: "Breaking the capture into still frames."),
                StockpileJobSnapshot(phase: .detectingReferences, progress: 0.44, headline: "Checking tagged references", detail: "Reference coverage is weaker than expected."),
                StockpileJobSnapshot(phase: .calibrating, progress: 0.63, headline: "Scale check failed", detail: "Reference agreement is too weak for reporting."),
                StockpileMockRunScenario.terminalSnapshot(for: .blocked),
            ],
            result: result
        )
    }

    private static func terminalSnapshot(for outcome: StockpileRunOutcome) -> StockpileJobSnapshot {
        switch outcome {
        case .verified:
            return StockpileJobSnapshot(
                phase: .verified,
                progress: 1.0,
                headline: "Verified result ready",
                detail: "This run passed confidence thresholds and is ready for reporting."
            )
        case .reviewOnly:
            return StockpileJobSnapshot(
                phase: .reviewOnly,
                progress: 1.0,
                headline: "Review-only result ready",
                detail: "Processing completed, but this run still needs a benchmark cross-check."
            )
        case .blocked:
            return StockpileJobSnapshot(
                phase: .blocked,
                progress: 1.0,
                headline: "Capture blocked",
                detail: "The system could not verify this capture confidently enough to report it."
            )
        }
    }
}

public actor MockStockpileMobileAPIService: StockpileMobileAPIServicing {
    private struct JobCursor: Sendable {
        var snapshots: [StockpileJobSnapshot]
        var currentIndex: Int
        let runID: String
    }

    private var sessionCounter = 0
    private var uploadCounter = 0
    private var jobCounter = 0
    private var runCounter = 0

    private var sessions: [String: StockpileCaptureSession] = [:]
    private var jobs: [String: JobCursor] = [:]
    private var results: [String: StockpileResultPayload] = [:]
    private var queuedScenarios: [StockpileMockRunScenario]
    private let baseURL: URL
    private let now: @Sendable () -> Date

    public init(
        queuedScenarios: [StockpileMockRunScenario] = [],
        baseURL: URL = URL(string: "https://api.stockpile.theclustox.com/mobile")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.queuedScenarios = queuedScenarios
        self.baseURL = baseURL
        self.now = now
    }

    public func enqueueScenario(_ scenario: StockpileMockRunScenario) {
        queuedScenarios.append(scenario)
    }

    public func createCaptureSession(request: StockpileCaptureSessionCreateRequest) async throws -> StockpileCaptureSession {
        sessionCounter += 1
        let createdAt = now()
        let session = StockpileCaptureSession(
            sessionID: Self.makeID(prefix: "session", number: sessionCounter),
            siteID: request.siteID,
            pileName: request.pileName,
            materialCode: request.materialCode,
            densityKgPerM3: request.densityKgPerM3,
            referenceCountGoal: request.referenceCountGoal,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(60 * 60 * 6)
        )
        sessions[session.sessionID] = session
        return session
    }

    public func createUploadAuthorization(request: StockpileUploadRequest) async throws -> StockpileUploadAuthorization {
        guard sessions[request.sessionID] != nil else {
            throw StockpileMobileAPIError.sessionNotFound(request.sessionID)
        }

        uploadCounter += 1
        jobCounter += 1
        runCounter += 1

        let uploadID = Self.makeID(prefix: "upload", number: uploadCounter)
        let jobID = Self.makeID(prefix: "job", number: jobCounter)
        let fallback = StockpileMockRunScenario.reviewOnlyPreview()
        let selectedScenario = queuedScenarios.isEmpty ? fallback : queuedScenarios.removeFirst()
        let runID = Self.makeID(prefix: "run", number: runCounter)

        let normalizedResult = StockpileResultPayload(
            runID: runID,
            pileName: selectedScenario.result.pileName,
            outcome: selectedScenario.result.outcome,
            confidence: selectedScenario.result.confidence,
            measurement: selectedScenario.result.measurement,
            warnings: selectedScenario.result.warnings,
            blockers: selectedScenario.result.blockers,
            recommendedAction: selectedScenario.result.recommendedAction,
            updatedAt: now()
        )

        let snapshots = selectedScenario.snapshots.enumerated().map { index, snapshot in
            if index == selectedScenario.snapshots.count - 1 && !snapshot.phase.isTerminal {
                return Self.terminalSnapshot(for: normalizedResult.outcome)
            }
            return snapshot
        }

        jobs[jobID] = JobCursor(snapshots: snapshots, currentIndex: 0, runID: runID)
        results[runID] = normalizedResult

        return StockpileUploadAuthorization(
            uploadID: uploadID,
            sessionID: request.sessionID,
            jobID: jobID,
            uploadURL: baseURL.appending(path: "uploads/\(uploadID)"),
            httpMethod: "PUT",
            headers: [
                "Content-Type": request.contentType,
                "x-stockpile-file-name": request.fileName,
            ],
            expiresAt: now().addingTimeInterval(60 * 30)
        )
    }

    public func fetchProcessingJob(jobID: String) async throws -> StockpileProcessingJobStatus {
        guard var cursor = jobs[jobID] else {
            throw StockpileMobileAPIError.jobNotFound(jobID)
        }

        let snapshot = cursor.snapshots[cursor.currentIndex]
        let status = StockpileProcessingJobStatus(
            jobID: jobID,
            runID: cursor.runID,
            phase: snapshot.phase,
            progress: snapshot.progress,
            headline: snapshot.headline,
            detail: snapshot.detail,
            updatedAt: now()
        )

        if cursor.currentIndex < cursor.snapshots.count - 1 {
            cursor.currentIndex += 1
            jobs[jobID] = cursor
        }

        return status
    }

    public func fetchResult(runID: String) async throws -> StockpileResultPayload {
        guard let result = results[runID] else {
            throw StockpileMobileAPIError.resultNotFound(runID)
        }
        return result
    }

    public func fetchRecentResults(
        limit: Int,
        siteID: String? = nil,
        sessionID: String? = nil
    ) async throws -> [StockpileResultPayload] {
        guard limit > 0 else {
            return []
        }

        return results.values
            .filter { result in
                let siteMatches = siteID.map { $0 == result.siteID } ?? true
                let sessionMatches = sessionID.map { $0 == result.sessionID } ?? true
                return siteMatches && sessionMatches
            }
            .sorted { lhs, rhs in
                (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func makeID(prefix: String, number: Int) -> String {
        "\(prefix)_\(String(format: "%03d", number))"
    }

    private static func terminalSnapshot(for outcome: StockpileRunOutcome) -> StockpileJobSnapshot {
        switch outcome {
        case .verified:
            return StockpileJobSnapshot(
                phase: .verified,
                progress: 1.0,
                headline: "Verified result ready",
                detail: "This run passed confidence thresholds and is ready for reporting."
            )
        case .reviewOnly:
            return StockpileJobSnapshot(
                phase: .reviewOnly,
                progress: 1.0,
                headline: "Review-only result ready",
                detail: "Processing completed, but this run still needs a benchmark cross-check."
            )
        case .blocked:
            return StockpileJobSnapshot(
                phase: .blocked,
                progress: 1.0,
                headline: "Capture blocked",
                detail: "The system could not verify this capture confidently enough to report it."
            )
        }
    }
}
