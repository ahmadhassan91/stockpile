import XCTest
@testable import StockpileMobileAPI

final class StockpileLiveMobileAPIServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StockpileURLProtocolStub.reset()
    }

    override func tearDown() {
        StockpileURLProtocolStub.reset()
        super.tearDown()
    }

    func testEnvironmentConfigurationAppliesBaseURLHeadersAndTimeoutOverrides() {
        let configuration = StockpileLiveMobileAPIConfiguration.environment(
            environment: [
                "STOCKPILE_API_BASE_URL": "https://staging-api.theclustox.com/stockpile",
                "STOCKPILE_MOBILE_API_PATH_PREFIX": "/mobile/v2/",
                "STOCKPILE_MOBILE_API_BEARER_TOKEN": "token-123",
                "STOCKPILE_MOBILE_API_KEY": "key-456",
                "STOCKPILE_MOBILE_API_USER_AGENT": "StockpileAlpha/1.2",
                "STOCKPILE_MOBILE_API_TIMEOUT_SECONDS": "45",
            ]
        )

        XCTAssertEqual(configuration.baseURL.absoluteString, "https://staging-api.theclustox.com/stockpile")
        XCTAssertEqual(configuration.pathPrefix, "mobile/v2")
        XCTAssertEqual(configuration.defaultHeaders["Authorization"], "Bearer token-123")
        XCTAssertEqual(configuration.defaultHeaders["x-api-key"], "key-456")
        XCTAssertEqual(configuration.defaultHeaders["User-Agent"], "StockpileAlpha/1.2")
        XCTAssertEqual(configuration.timeoutInterval, 45, accuracy: 0.001)
    }

    func testCreateCaptureSessionBuildsPostRequestAndDecodesResponse() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedCreatedAt = try XCTUnwrap(formatter.date(from: "2024-04-21T11:10:45.123Z"))
        let expectedExpiresAt = try XCTUnwrap(formatter.date(from: "2024-04-21T17:10:45.456Z"))

        StockpileURLProtocolStub.responseProvider = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            let data = """
            {
              "sessionId": "session_123",
              "siteId": "qpmc-north-yard",
              "pileName": "North Yard 03",
              "materialCode": "backfill-0-75",
              "densityKgPerM3": 2100,
              "referenceCountGoal": 3,
              "createdAt": "2024-04-21T11:10:45.123Z",
              "expiresAt": "2024-04-21T17:10:45.456Z"
            }
            """.data(using: .utf8)!

            return (response, data)
        }

        let service = makeService(
            configuration: StockpileLiveMobileAPIConfiguration(
                baseURL: URL(string: "https://example.com/stockpile")!,
                defaultHeaders: ["Authorization": "Bearer demo-token"]
            )
        )

        let session = try await service.createCaptureSession(
            request: StockpileCaptureSessionCreateRequest(
                siteID: "qpmc-north-yard",
                pileName: "North Yard 03",
                materialCode: "backfill-0-75",
                densityKgPerM3: 2100,
                referenceCountGoal: 3,
                clientBuild: "ios-alpha",
                taggedReferenceStrategy: makeTaggedReferenceStrategy(),
                captureMetadata: makeCaptureMetadata(source: .liveRecordedVideo),
                qualityInput: makeQualityInput(referenceVisibilityScore: 0.93)
            )
        )

        let request = try XCTUnwrap(StockpileURLProtocolStub.lastRequest)
        let body = try XCTUnwrap(StockpileURLProtocolStub.lastRequestBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/stockpile/api/mobile/capture-sessions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer demo-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertEqual(json["siteId"] as? String, "qpmc-north-yard")
        XCTAssertEqual(json["pileName"] as? String, "North Yard 03")
        XCTAssertEqual(json["clientBuild"] as? String, "ios-alpha")
        let taggedReferenceStrategy = try XCTUnwrap(json["taggedReferenceStrategy"] as? [String: Any])
        XCTAssertEqual(taggedReferenceStrategy["preferredVisibleReferenceCount"] as? Int, 3)
        let captureMetadata = try XCTUnwrap(json["captureMetadata"] as? [String: Any])
        XCTAssertEqual(captureMetadata["source"] as? String, "live_recorded_video")
        let qualityInput = try XCTUnwrap(json["qualityInput"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap(qualityInput["referenceVisibilityScore"] as? Double),
            0.93,
            accuracy: 0.0001
        )

        XCTAssertEqual(session.sessionID, "session_123")
        XCTAssertEqual(session.siteID, "qpmc-north-yard")
        XCTAssertEqual(session.referenceCountGoal, 3)
        XCTAssertEqual(session.createdAt.timeIntervalSince1970, expectedCreatedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(session.expiresAt.timeIntervalSince1970, expectedExpiresAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testFetchProcessingJobUsesCamelCaseIdentifiersWhenDecoding() async throws {
        StockpileURLProtocolStub.responseProvider = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            let data = """
            {
              "jobId": "job_123",
              "runId": "run_456",
              "phase": "reconstructing",
              "progress": 0.72,
              "headline": "Reconstructing pile geometry",
              "detail": "Sparse reconstruction is in progress.",
              "updatedAt": "2024-04-21T11:10:45Z"
            }
            """.data(using: .utf8)!

            return (response, data)
        }

        let service = makeService(
            configuration: StockpileLiveMobileAPIConfiguration(
                baseURL: URL(string: "https://example.com/api/mobile")!
            )
        )

        let status = try await service.fetchProcessingJob(jobID: "job_123")
        let request = try XCTUnwrap(StockpileURLProtocolStub.lastRequest)

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/mobile/jobs/job_123")
        XCTAssertEqual(status.jobID, "job_123")
        XCTAssertEqual(status.runID, "run_456")
        XCTAssertEqual(status.phase, .reconstructing)
        XCTAssertEqual(status.progress, 0.72, accuracy: 0.0001)
    }

    func testFetchResultMaps404ToDomainSpecificError() async throws {
        StockpileURLProtocolStub.responseProvider = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            let data = #"{"message":"Result not found"}"#.data(using: .utf8)!
            return (response, data)
        }

        let service = makeService(
            configuration: StockpileLiveMobileAPIConfiguration(
                baseURL: URL(string: "https://example.com")!
            )
        )

        do {
            _ = try await service.fetchResult(runID: "run_missing")
            XCTFail("Expected result not found error")
        } catch let error as StockpileMobileAPIError {
            XCTAssertEqual(error, .resultNotFound("run_missing"))
        }
    }

    func testFetchRecentResultsBuildsQueryAndDecodesPayload() async throws {
        StockpileURLProtocolStub.responseProvider = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            let data = """
            [
              {
                "runId": "run_123",
                "pileName": "QPMC Yard 01",
                "outcome": "review_only",
                "confidence": {
                  "score": 61,
                  "label": "Moderate",
                  "summary": "Still needs a benchmark cross-check."
                },
                "measurement": {
                  "volumeM3": 1804.2,
                  "weightTonnes": 3788.82,
                  "densityKgPerM3": 2100
                },
                "warnings": [],
                "blockers": [],
                "recommendedAction": "Review before release.",
                "reportUrl": "https://stockpile.theclustox.com/reports/run_123",
                "updatedAt": "2026-04-22T09:30:00Z"
              }
            ]
            """.data(using: .utf8)!

            return (response, data)
        }

        let service = makeService(
            configuration: StockpileLiveMobileAPIConfiguration(
                baseURL: URL(string: "https://example.com/api/mobile")!
            )
        )

        let recentRuns = try await service.fetchRecentResults(
            limit: 4,
            siteID: "qpmc-north-yard",
            sessionID: "session_123"
        )
        let request = try XCTUnwrap(StockpileURLProtocolStub.lastRequest)

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.com/api/mobile/runs/recent?limit=4&siteId=qpmc-north-yard&sessionId=session_123"
        )
        XCTAssertEqual(recentRuns.count, 1)
        XCTAssertEqual(recentRuns.first?.runID, "run_123")
        XCTAssertEqual(recentRuns.first?.pileName, "QPMC Yard 01")
        XCTAssertEqual(recentRuns.first?.reportURL?.absoluteString, "https://stockpile.theclustox.com/reports/run_123")
        XCTAssertNotNil(recentRuns.first?.updatedAt)
    }

    func testFetchResultMapsLegacyPendingEnvelopeToResultNotFound() async throws {
        StockpileURLProtocolStub.responseProvider = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 202,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            let data = """
            {
              "runId": "run_pending",
              "state": "pending",
              "message": "Result run_pending is not ready yet.",
              "status": {
                "jobId": "job_123",
                "runId": "run_pending",
                "phase": "upload_received",
                "progress": 0.15,
                "headline": "Upload received",
                "detail": "The backend is preparing the recorded movie.",
                "updatedAt": "2024-04-21T11:10:45Z"
              }
            }
            """.data(using: .utf8)!

            return (response, data)
        }

        let service = makeService(
            configuration: StockpileLiveMobileAPIConfiguration(
                baseURL: URL(string: "https://example.com")!
            )
        )

        do {
            _ = try await service.fetchResult(runID: "run_pending")
            XCTFail("Expected pending result to map to resultNotFound")
        } catch let error as StockpileMobileAPIError {
            XCTAssertEqual(error, .resultNotFound("run_pending"))
        }
    }

    func testFetchResultMapsLegacyTerminalMissingResultEnvelopeToResultNotFound() async throws {
        StockpileURLProtocolStub.responseProvider = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 409,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            let data = """
            {
              "runId": "run_missing_terminal",
              "state": "terminal_missing_result",
              "message": "Result run_missing_terminal is not available yet.",
              "status": {
                "jobId": "job_999",
                "runId": "run_missing_terminal",
                "phase": "review_only",
                "progress": 1.0,
                "headline": "Review-only result ready",
                "detail": "The result has not been persisted yet.",
                "updatedAt": "2024-04-21T11:10:45Z"
              }
            }
            """.data(using: .utf8)!

            return (response, data)
        }

        let service = makeService(
            configuration: StockpileLiveMobileAPIConfiguration(
                baseURL: URL(string: "https://example.com")!
            )
        )

        do {
            _ = try await service.fetchResult(runID: "run_missing_terminal")
            XCTFail("Expected terminal missing result to map to resultNotFound")
        } catch let error as StockpileMobileAPIError {
            XCTAssertEqual(error, .resultNotFound("run_missing_terminal"))
        }
    }

    func testCreateUploadAuthorizationEncodesPoseSamplesAndReferenceObservations() async throws {
        let formatter = ISO8601DateFormatter()
        let expectedExpiresAt = try XCTUnwrap(formatter.date(from: "2024-04-21T17:10:45Z"))

        StockpileURLProtocolStub.responseProvider = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            let data = """
            {
              "uploadId": "upload_123",
              "sessionId": "session_123",
              "jobId": "job_789",
              "uploadUrl": "https://uploads.example.com/upload_123",
              "httpMethod": "PUT",
              "headers": {
                "Content-Type": "video/quicktime"
              },
              "expiresAt": "2024-04-21T17:10:45Z"
            }
            """.data(using: .utf8)!

            return (response, data)
        }

        let service = makeService(
            configuration: StockpileLiveMobileAPIConfiguration(
                baseURL: URL(string: "https://example.com")!
            )
        )

        let authorization = try await service.createUploadAuthorization(
            request: StockpileUploadRequest(
                sessionID: "session_123",
                fileName: "north-yard-03.mov",
                byteCount: 287_548_015,
                contentType: "video/quicktime",
                checksumSHA256: "abc123",
                taggedReferenceStrategy: makeTaggedReferenceStrategy(),
                captureMetadata: makeCaptureMetadata(source: .liveRecordedVideo),
                qualityInput: makeQualityInput(referenceVisibilityScore: 0.93),
                poseSamples: makePoseSamples(),
                referenceObservations: makeReferenceObservations(),
                referenceEvidenceJPEGFrames: makeReferenceEvidenceJPEGFrames()
            )
        )

        let request = try XCTUnwrap(StockpileURLProtocolStub.lastRequest)
        let body = try XCTUnwrap(StockpileURLProtocolStub.lastRequestBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/mobile/uploads")
        let poseSamples = try XCTUnwrap(json["poseSamples"] as? [[String: Any]])
        XCTAssertEqual(poseSamples.count, 1)
        XCTAssertEqual(poseSamples[0]["sampleIndex"] as? Int, 7)
        XCTAssertEqual(
            try XCTUnwrap(poseSamples[0]["headingDegrees"] as? Double),
            12,
            accuracy: 0.0001
        )
        let referenceObservations = try XCTUnwrap(json["referenceObservations"] as? [[String: Any]])
        XCTAssertEqual(referenceObservations.count, 1)
        XCTAssertEqual(referenceObservations[0]["referenceId"] as? String, "QPMC-01")
        XCTAssertEqual(referenceObservations[0]["poseSampleIndex"] as? Int, 7)
        XCTAssertEqual(
            try XCTUnwrap(referenceObservations[0]["estimatedDistanceM"] as? Double),
            4.2,
            accuracy: 0.0001
        )
        let referenceEvidenceJPEGFrames = try XCTUnwrap(
            json["referenceEvidenceJPEGFrames"] as? [[String: Any]]
        )
        XCTAssertEqual(referenceEvidenceJPEGFrames.count, 1)
        XCTAssertEqual(referenceEvidenceJPEGFrames[0]["frameId"] as? String, "frame_0010")
        XCTAssertEqual(referenceEvidenceJPEGFrames[0]["poseSampleIndex"] as? Int, 7)
        XCTAssertEqual(referenceEvidenceJPEGFrames[0]["widthPx"] as? Int, 1440)
        XCTAssertEqual(referenceEvidenceJPEGFrames[0]["heightPx"] as? Int, 810)
        XCTAssertEqual(referenceEvidenceJPEGFrames[0]["jpegBase64"] as? String, "jpeg-frame-0010")
        XCTAssertEqual(referenceEvidenceJPEGFrames[0]["capturedAt"] as? String, "2024-04-21T11:10:45Z")
        XCTAssertEqual(authorization.uploadID, "upload_123")
        XCTAssertEqual(authorization.expiresAt, expectedExpiresAt)
    }

    func testCreateUploadAuthorizationMapsRateLimitResponse() async throws {
        StockpileURLProtocolStub.responseProvider = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 429,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Retry-After": "30",
                ]
            )!

            let data = #"{"message":"Too many requests"}"#.data(using: .utf8)!
            return (response, data)
        }

        let service = makeService(
            configuration: StockpileLiveMobileAPIConfiguration(
                baseURL: URL(string: "https://example.com")!
            )
        )

        do {
            _ = try await service.createUploadAuthorization(
                request: StockpileUploadRequest(
                    sessionID: "session_123",
                    fileName: "north-yard-03.mov",
                    byteCount: 287_548_015,
                    contentType: "video/quicktime",
                    taggedReferenceStrategy: makeTaggedReferenceStrategy(),
                    captureMetadata: makeCaptureMetadata(source: .importedVideo),
                    qualityInput: makeQualityInput(referenceVisibilityScore: nil)
                )
            )
            XCTFail("Expected rate limit error")
        } catch let error as StockpileMobileAPIError {
            XCTAssertEqual(
                error,
                .rateLimited(retryAfter: 30, message: "Too many requests")
            )
        }
    }

    private func makeService(
        configuration: StockpileLiveMobileAPIConfiguration
    ) -> LiveStockpileMobileAPIService {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StockpileURLProtocolStub.self]

        return LiveStockpileMobileAPIService(
            configuration: configuration,
            sessionConfiguration: sessionConfiguration
        )
    }
}

private func makeTaggedReferenceStrategy() -> StockpileTaggedReferenceStrategyPayload {
    StockpileTaggedReferenceStrategyPayload(
        mode: .concurrentVisibility,
        referenceCountGoal: 3,
        minimumVisibleReferenceCount: 2,
        preferredVisibleReferenceCount: 3
    )
}

private func makeCaptureMetadata(
    source: StockpileCaptureSourcePayload
) -> StockpileCaptureMetadataPayload {
    StockpileCaptureMetadataPayload(
        source: source,
        mode: .guidedWalkaround,
        startedAt: nil,
        completedAt: nil,
        timeZoneIdentifier: "Asia/Karachi",
        activeDeviceName: "Back Camera",
        capturePhase: "capturing",
        sessionLifecycle: "running",
        recordingLifecycle: "recording",
        sensorMetadata: StockpileCaptureSensorMetadataPayload(
            deviceModelIdentifier: "iPhone17,2",
            videoWidth: 1920,
            videoHeight: 1080,
            videoFrameRate: 60,
            poseSamplingHz: 15,
            depthDataIncluded: false,
            worldAlignment: "gravityAndHeading",
            videoStabilizationMode: "auto"
        )
    )
}

private func makeQualityInput(
    referenceVisibilityScore: Double?
) -> StockpileCaptureQualityInputPayload {
    StockpileCaptureQualityInputPayload(
        referenceVisibilityScore: referenceVisibilityScore,
        coverageScore: 0.84,
        motionStabilityScore: 0.79,
        overallGuidanceScore: 0.85,
        deviceSensors: .reserved
    )
}

private func makePoseSamples() -> [StockpileDevicePoseSamplePayload] {
    [
        StockpileDevicePoseSamplePayload(
            sampleIndex: 7,
            timeOffsetSec: 2.5,
            positionM: StockpileVector3Payload(x: 3, y: 4, z: 5),
            headingDegrees: 12,
            trackingState: "running",
            yawPitchRollDeg: StockpileVector3Payload(x: 90, y: -4, z: 1),
            horizontalAccuracyM: 0.4,
            verticalAccuracyM: 0.8
        )
    ]
}

private func makeReferenceObservations() -> [StockpileReferenceObservationPayload] {
    [
        StockpileReferenceObservationPayload(
            referenceID: "QPMC-01",
            family: "apriltag",
            frameTimeSec: 2.5,
            poseSampleIndex: 7,
            decisionMargin: 92.5,
            hamming: 0,
            edgeLengthPx: 144,
            frameID: "frame_0010",
            pixelAreaPx: 1800,
            confidence: 0.92,
            estimatedDistanceM: 4.2,
            state: .confirmed
        )
    ]
}

private func makeReferenceEvidenceJPEGFrames() -> [StockpileReferenceEvidenceJPEGFramePayload] {
    [
        StockpileReferenceEvidenceJPEGFramePayload(
            frameID: "frame_0010",
            timeOffsetSec: 2.5,
            poseSampleIndex: 7,
            capturedAt: Date(timeIntervalSince1970: 1_713_697_845),
            widthPx: 1440,
            heightPx: 810,
            jpegBase64: "jpeg-frame-0010"
        )
    ]
}

private final class StockpileURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var responseProvider: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var capturedBodies: [Data?] = []

    static var lastRequest: URLRequest? {
        lock.withLock {
            capturedRequests.last
        }
    }

    static var lastRequestBody: Data? {
        lock.withLock {
            capturedBodies.last ?? nil
        }
    }

    static func reset() {
        lock.withLock {
            responseProvider = nil
            capturedRequests = []
            capturedBodies = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyData(for: request)

        Self.lock.withLock {
            Self.capturedRequests.append(request)
            Self.capturedBodies.append(body)
        }

        guard let responseProvider = Self.lock.withLock({ Self.responseProvider }) else {
            XCTFail("Missing URLProtocol response provider")
            return
        }

        do {
            let (response, data) = try responseProvider(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(for request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)

            guard readCount >= 0 else {
                return nil
            }

            if readCount == 0 {
                break
            }

            data.append(buffer, count: readCount)
        }

        return data
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
