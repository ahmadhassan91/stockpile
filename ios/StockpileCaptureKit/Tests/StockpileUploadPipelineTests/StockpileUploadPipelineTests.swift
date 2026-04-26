import Foundation
import XCTest
@testable import StockpileUploadPipeline

final class StockpileUploadPipelineTests: XCTestCase {
    func testTaskNarrativeReflectsTransferStage() {
        let file = StockpileUploadFileDescriptor(
            fileURL: URL(fileURLWithPath: "/tmp/north-yard-03.mov"),
            fileName: "north-yard-03.mov",
            byteCount: 300,
            contentType: "video/quicktime"
        )
        let stage = StockpileUploadTaskStage.transferringBytes(
            StockpileByteTransferState(
                bytesTransferred: 150,
                totalBytes: 300,
                retryCount: 1,
                throughputBytesPerSecond: 1_500_000,
                headline: "Uploading bytes",
                detail: "The background transfer is now moving the file to the server."
            )
        )
        let task = StockpileUploadTask(
            taskID: "upload_task_1",
            file: file,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 110),
            stage: stage
        )

        XCTAssertEqual(task.headline, "Uploading bytes")
        XCTAssertEqual(task.progress, 0.45, accuracy: 0.0001)
        XCTAssertTrue(task.narrative.contains("150"))
        XCTAssertTrue(task.narrative.contains("300"))
    }

    func testQueuedRetryStateCarriesOperatorFacingNarrative() {
        let stage = StockpileUploadTaskStage.queuedForRetry(
            StockpileQueuedRetryState(
                attempt: 2,
                maxAttempts: 4,
                nextRetryAt: Date(timeIntervalSince1970: 250),
                reason: "Temporary network interruption",
                headline: "Queued for retry",
                detail: "The upload will resume once the connection is stable again."
            )
        )

        XCTAssertEqual(stage.headline, "Queued for retry")
        XCTAssertEqual(stage.progress, 0.8, accuracy: 0.0001)
        XCTAssertFalse(stage.isTerminal)
        XCTAssertTrue(stage.narrative.contains("attempt 2"))
        XCTAssertTrue(stage.narrative.contains("4"))
    }

    func testMockServiceStreamsSnapshotsAcrossStateTransitions() async throws {
        let service = MockStockpileUploadService()
        let file = StockpileUploadFileDescriptor(
            fileURL: URL(fileURLWithPath: "/tmp/north-yard-03.mov"),
            fileName: "north-yard-03.mov",
            byteCount: 400,
            contentType: "video/quicktime"
        )

        let task = try await service.createUploadTask(
            request: StockpileUploadTaskRequest(
                uploadID: "upload_task_7",
                file: file,
                backgroundSessionIdentifier: "com.stockpile.upload.background"
            )
        )

        let stream = service.progressSnapshots(for: task.taskID)
        let collector = Task<[StockpileUploadProgressSnapshot], Never> {
            var snapshots: [StockpileUploadProgressSnapshot] = []
            for await snapshot in stream {
                snapshots.append(snapshot)
                if snapshot.stage.isTerminal {
                    break
                }
            }
            return snapshots
        }

        await service.emitNextSnapshot(for: task.taskID)
        await service.emitNextSnapshot(for: task.taskID)
        await service.emitNextSnapshot(for: task.taskID)

        let snapshots = await collector.value

        XCTAssertGreaterThanOrEqual(snapshots.count, 4)
        XCTAssertEqual(snapshots.first?.stage.headline, "Preparing local file")
        XCTAssertTrue(snapshots.contains(where: { if case .transferringBytes = $0.stage { return true }; return false }))
        XCTAssertTrue(snapshots.contains(where: { if case .handingOffToServer = $0.stage { return true }; return false }))
        XCTAssertEqual(snapshots.last?.stage.isTerminal, true)
        XCTAssertTrue(snapshots.last?.stage.headline == "Upload complete" || snapshots.last?.stage.headline == "Upload cancelled")
    }

    func testSessionConfigurationFactoryBuildsBackgroundFriendlyConfiguration() {
        let configuration = URLSessionStockpileUploadServiceConfiguration(
            uploadURL: URL(string: "https://example.com/uploads")!,
            timeoutInterval: 120,
            sharedContainerIdentifier: "group.com.stockpile.alpha",
            allowsCellularAccess: false,
            waitsForConnectivity: true,
            isDiscretionary: true
        )

        let sessionConfiguration = StockpileUploadSessionConfigurationFactory.makeConfiguration(
            descriptor: StockpileUploadSessionDescriptor(backgroundSessionIdentifier: "com.stockpile.upload.background"),
            configuration: configuration
        )

        XCTAssertEqual(sessionConfiguration.identifier, "com.stockpile.upload.background")
        XCTAssertEqual(sessionConfiguration.sharedContainerIdentifier, "group.com.stockpile.alpha")
        XCTAssertEqual(sessionConfiguration.timeoutIntervalForRequest, 120, accuracy: 0.0001)
        XCTAssertEqual(sessionConfiguration.timeoutIntervalForResource, 7_200, accuracy: 0.0001)
        XCTAssertEqual(sessionConfiguration.allowsCellularAccess, false)
        XCTAssertEqual(sessionConfiguration.waitsForConnectivity, true)
        XCTAssertEqual(sessionConfiguration.isDiscretionary, true)
        XCTAssertEqual(sessionConfiguration.httpMaximumConnectionsPerHost, 1)
    }

    func testBackgroundUploadEventCoordinatorFinishesRegisteredHandlerOnce() {
        let fulfilled = expectation(description: "background events finished")
        var callbackCount = 0

        StockpileBackgroundUploadEventCoordinator.registerCompletionHandler(
            {
                callbackCount += 1
                fulfilled.fulfill()
            },
            forSessionIdentifier: "com.stockpile.upload.background"
        )

        StockpileBackgroundUploadEventCoordinator.finishEvents(
            forSessionIdentifier: "com.stockpile.upload.background"
        )
        wait(for: [fulfilled], timeout: 1)
        StockpileBackgroundUploadEventCoordinator.finishEvents(
            forSessionIdentifier: "com.stockpile.upload.background"
        )
        XCTAssertEqual(callbackCount, 1)
    }

    func testTaskEventSinkUsesBackgroundIdentifierWhenFinishingEvents() {
        let finished = expectation(description: "background identifier forwarded")
        let sink = URLSessionTaskEventSink(
            sessionKey: "com.stockpile.upload.background",
            backgroundSessionIdentifier: "com.stockpile.upload.background",
            onProgress: { _ in },
            onResponseData: { _ in },
            onCompletion: { _ in },
            onBackgroundEventsFinished: { identifier in
                XCTAssertEqual(identifier, "com.stockpile.upload.background")
                finished.fulfill()
            }
        )

        sink.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession(configuration: .default))

        wait(for: [finished], timeout: 1)
    }

    func testTransferStateFactoryExplainsBackgroundStartAndReceiptWait() {
        let startingState = StockpileUploadTransferStateFactory.makeState(
            bytesTransferred: 0,
            totalBytesExpected: 512,
            retryCount: 0,
            throughputBytesPerSecond: nil
        )
        let finalizingState = StockpileUploadTransferStateFactory.makeState(
            bytesTransferred: 512,
            totalBytesExpected: 512,
            retryCount: 1,
            throughputBytesPerSecond: 2_000_000
        )

        XCTAssertEqual(startingState.headline, "Starting upload")
        XCTAssertTrue(startingState.detail.contains("background transfer"))
        XCTAssertEqual(finalizingState.headline, "Finalizing transfer")
        XCTAssertTrue(finalizingState.detail.contains("Waiting for the server to confirm receipt"))
        XCTAssertTrue(finalizingState.detail.contains("Attempt 2"))
    }

    func testRequestBuilderAddsUploadMetadataHeaders() {
        let configuration = URLSessionStockpileUploadServiceConfiguration(
            uploadURL: URL(string: "https://example.com/uploads")!,
            httpMethod: "PUT",
            additionalHeaders: ["Authorization": "Bearer demo-token"],
            timeoutInterval: 45
        )
        let file = StockpileUploadFileDescriptor(
            fileURL: URL(fileURLWithPath: "/tmp/north-yard-03.mov"),
            fileName: "north-yard-03.mov",
            byteCount: 512,
            contentType: "video/quicktime",
            checksumSHA256: "abc123"
        )
        let request = StockpileUploadRequestBuilder.makeRequest(
            for: StockpileUploadTaskRequest(
                uploadID: "upload_task_42",
                file: file,
                backgroundSessionIdentifier: "com.stockpile.upload.background",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            configuration: configuration
        )

        XCTAssertEqual(request.url, configuration.uploadURL)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.timeoutInterval, 45, accuracy: 0.0001)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "video/quicktime")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "512")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Stockpile-Upload-ID"), "upload_task_42")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Stockpile-File-Name"), "north-yard-03.mov")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Stockpile-Checksum-SHA256"), "abc123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Stockpile-Background-Session-ID"), "com.stockpile.upload.background")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer demo-token")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Stockpile-Upload-Created-At"))
    }

    func testThroughputTrackerCalculatesRateFromSequentialSamples() {
        var tracker = StockpileUploadThroughputTracker()

        XCTAssertNil(tracker.recordSample(totalBytesSent: 128, at: Date(timeIntervalSince1970: 10)))

        let throughput = tracker.recordSample(totalBytesSent: 640, at: Date(timeIntervalSince1970: 12))

        XCTAssertEqual(throughput ?? 0, 256, accuracy: 0.0001)
    }

    func testResponseInterpreterPrefersHeaderReceiptAndReadsServerUploadIDFromBody() {
        let response = StockpileUploadHTTPResponse(
            statusCode: 201,
            headers: [
                "X-Stockpile-Receipt-ID": "receipt_header",
                "Content-Type": "application/json",
            ]
        )
        let responseBody = #"{"receipt_id":"receipt_body","server_upload_id":"server_upload_11"}"#.data(using: .utf8) ?? Data()

        XCTAssertEqual(
            StockpileUploadResponseInterpreter.receiptID(
                response: response,
                responseBody: responseBody,
                fallbackTaskID: "upload_task_11"
            ),
            "receipt_header"
        )
        XCTAssertEqual(
            StockpileUploadResponseInterpreter.serverUploadID(
                response: response,
                responseBody: responseBody
            ),
            "server_upload_11"
        )
    }

    func testLiveServiceCreatesUploadTaskUsingInjectedSessionFactory() async throws {
        let configuration = URLSessionStockpileUploadServiceConfiguration(
            uploadURL: URL(string: "https://example.com/uploads")!,
            httpMethod: "PUT",
            additionalHeaders: ["Authorization": "Bearer operator"],
            timeoutInterval: 30
        )
        let recorder = SessionFactoryRecorder()
        let service = URLSessionStockpileUploadService(
            configuration: configuration,
            now: { Date(timeIntervalSince1970: 200) },
            requestBuilder: { request in
                StockpileUploadRequestBuilder.makeRequest(for: request, configuration: configuration)
            },
            sessionFactory: { descriptor, eventSink in
                recorder.makeSession(
                    descriptor: descriptor,
                    eventSink: eventSink,
                    taskIdentifier: 91
                )
            }
        )

        let fileURL = try makeTemporaryFile(named: "live-upload.mov", byteCount: 256)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let file = StockpileUploadFileDescriptor(
            fileURL: fileURL,
            fileName: "live-upload.mov",
            byteCount: 256,
            contentType: "video/quicktime"
        )

        let task = try await service.createUploadTask(
            request: StockpileUploadTaskRequest(
                uploadID: "upload_task_live",
                file: file,
                backgroundSessionIdentifier: "com.stockpile.upload.background",
                createdAt: Date(timeIntervalSince1970: 190)
            )
        )

        XCTAssertEqual(recorder.descriptors, [StockpileUploadSessionDescriptor(backgroundSessionIdentifier: "com.stockpile.upload.background")])
        XCTAssertEqual(recorder.sessions.count, 1)
        XCTAssertEqual(recorder.sessions[0].lastFileURL, fileURL)
        XCTAssertEqual(recorder.sessions[0].lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(recorder.sessions[0].lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer operator")
        XCTAssertEqual(recorder.sessions[0].uploadTask.resumeCallCount, 1)
        XCTAssertEqual(task.taskID, "upload_task_live")
        XCTAssertEqual(task.backgroundSessionIdentifier, "com.stockpile.upload.background")

        guard case .transferringBytes(let state) = task.stage else {
            return XCTFail("Expected task to move into transferring state immediately after setup.")
        }
        XCTAssertEqual(state.bytesTransferred, 0)
        XCTAssertEqual(state.totalBytes, 256)
    }

    func testLiveServiceStreamsProgressAndCompletionFromSyntheticEvents() async throws {
        let configuration = URLSessionStockpileUploadServiceConfiguration(
            uploadURL: URL(string: "https://example.com/uploads")!
        )
        let recorder = SessionFactoryRecorder()
        let service = URLSessionStockpileUploadService(
            configuration: configuration,
            requestBuilder: { request in
                StockpileUploadRequestBuilder.makeRequest(for: request, configuration: configuration)
            },
            sessionFactory: { descriptor, eventSink in
                recorder.makeSession(
                    descriptor: descriptor,
                    eventSink: eventSink,
                    taskIdentifier: 17
                )
            }
        )

        let fileURL = try makeTemporaryFile(named: "streamed-upload.mov", byteCount: 400)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let task = try await service.createUploadTask(
            request: StockpileUploadTaskRequest(
                uploadID: "upload_task_stream",
                file: StockpileUploadFileDescriptor(
                    fileURL: fileURL,
                    fileName: "streamed-upload.mov",
                    byteCount: 400,
                    contentType: "video/quicktime"
                ),
                backgroundSessionIdentifier: "com.stockpile.upload.background"
            )
        )

        let stream = service.progressSnapshots(for: task.taskID)
        let collector = Task<[StockpileUploadProgressSnapshot], Never> {
            var snapshots: [StockpileUploadProgressSnapshot] = []
            for await snapshot in stream {
                snapshots.append(snapshot)
                if snapshot.stage.isTerminal {
                    break
                }
            }
            return snapshots
        }

        await Task.yield()
        await service.handleProgress(
            StockpileUploadTaskProgressEvent(
                sessionKey: "com.stockpile.upload.background",
                taskIdentifier: 17,
                totalBytesSent: 400,
                totalBytesExpectedToSend: 400
            )
        )
        await service.handleResponseData(
            StockpileUploadTaskResponseDataEvent(
                sessionKey: "com.stockpile.upload.background",
                taskIdentifier: 17,
                data: #"{"receipt_id":"receipt_streamed","server_upload_id":"server_streamed"}"#.data(using: .utf8) ?? Data()
            )
        )
        await service.handleCompletion(
            StockpileUploadTaskCompletionEvent(
                sessionKey: "com.stockpile.upload.background",
                taskIdentifier: 17,
                response: StockpileUploadHTTPResponse(statusCode: 201, headers: [:]),
                error: nil
            )
        )

        let snapshots = await collector.value
        let storedTask = await service.task(taskID: task.taskID)

        XCTAssertGreaterThanOrEqual(snapshots.count, 5)
        XCTAssertEqual(snapshots.first?.stage.headline, "Preparing local file")
        XCTAssertTrue(snapshots.contains(where: { $0.stage.headline == "Finalizing transfer" }))
        XCTAssertTrue(snapshots.contains(where: { if case .handingOffToServer = $0.stage { return true }; return false }))
        XCTAssertEqual(snapshots.last?.stage.headline, "Upload complete")

        guard case .completed(let completionState) = storedTask?.stage else {
            return XCTFail("Expected the stored task to finish in the completed state.")
        }
        XCTAssertEqual(completionState.uploadID, "upload_task_stream")
        XCTAssertEqual(completionState.serverUploadID, "server_streamed")
        XCTAssertEqual(completionState.serverReceiptID, "receipt_streamed")
    }

    func testLiveServiceReattachesExistingBackgroundTaskUsingTaskDescription() async throws {
        let configuration = URLSessionStockpileUploadServiceConfiguration(
            uploadURL: URL(string: "https://example.com/uploads")!
        )
        let recorder = SessionFactoryRecorder()
        let service = URLSessionStockpileUploadService(
            configuration: configuration,
            requestBuilder: { request in
                StockpileUploadRequestBuilder.makeRequest(for: request, configuration: configuration)
            },
            sessionFactory: { descriptor, eventSink in
                recorder.makeSession(
                    descriptor: descriptor,
                    eventSink: eventSink,
                    taskIdentifier: 33,
                    existingTaskDescription: "upload_task_restore",
                    existingBytesSent: 160,
                    existingBytesExpected: 320
                )
            }
        )

        let restoredTask = try await service.reattachUploadTask(
            request: StockpileUploadTaskRestoreRequest(
                taskID: "upload_task_restore",
                file: StockpileUploadFileDescriptor(
                    fileURL: URL(fileURLWithPath: "/tmp/restore.mov"),
                    fileName: "restore.mov",
                    byteCount: 320,
                    contentType: "video/quicktime"
                ),
                backgroundSessionIdentifier: "com.stockpile.upload.background",
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )

        guard case .transferringBytes(let transferState) = restoredTask?.stage else {
            return XCTFail("Expected restored task to resume in the transferring state.")
        }

        XCTAssertEqual(restoredTask?.taskID, "upload_task_restore")
        XCTAssertEqual(transferState.retryCount, 1)
        XCTAssertEqual(transferState.bytesTransferred, 160)
        XCTAssertEqual(transferState.totalBytes, 320)
    }

    func testLiveServiceReturnsNilWhenNoBackgroundTaskMatchesRestoreRequest() async throws {
        let configuration = URLSessionStockpileUploadServiceConfiguration(
            uploadURL: URL(string: "https://example.com/uploads")!
        )
        let recorder = SessionFactoryRecorder()
        let service = URLSessionStockpileUploadService(
            configuration: configuration,
            requestBuilder: { request in
                StockpileUploadRequestBuilder.makeRequest(for: request, configuration: configuration)
            },
            sessionFactory: { descriptor, eventSink in
                recorder.makeSession(
                    descriptor: descriptor,
                    eventSink: eventSink,
                    taskIdentifier: 77
                )
            }
        )

        let restoredTask = try await service.reattachUploadTask(
            request: StockpileUploadTaskRestoreRequest(
                taskID: "missing_upload",
                file: StockpileUploadFileDescriptor(
                    fileURL: URL(fileURLWithPath: "/tmp/missing.mov"),
                    fileName: "missing.mov",
                    byteCount: 200,
                    contentType: "video/quicktime"
                ),
                backgroundSessionIdentifier: "com.stockpile.upload.background",
                createdAt: Date(timeIntervalSince1970: 120)
            )
        )

        XCTAssertNil(restoredTask)
    }

    private func makeTemporaryFile(named name: String, byteCount: Int) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data(repeating: 7, count: byteCount).write(to: fileURL)
        return fileURL
    }
}

private final class RecordingUploadTask: StockpileURLSessionTasking, @unchecked Sendable {
    let taskIdentifier: Int
    var taskDescription: String?
    var originalRequest: URLRequest?
    var currentRequest: URLRequest?
    var response: URLResponse?
    var countOfBytesSent: Int64
    var countOfBytesExpectedToSend: Int64
    private(set) var resumeCallCount = 0
    private(set) var cancelCallCount = 0

    init(
        taskIdentifier: Int,
        taskDescription: String? = nil,
        originalRequest: URLRequest? = nil,
        currentRequest: URLRequest? = nil,
        response: URLResponse? = nil,
        countOfBytesSent: Int64 = 0,
        countOfBytesExpectedToSend: Int64 = 0
    ) {
        self.taskIdentifier = taskIdentifier
        self.taskDescription = taskDescription
        self.originalRequest = originalRequest
        self.currentRequest = currentRequest
        self.response = response
        self.countOfBytesSent = countOfBytesSent
        self.countOfBytesExpectedToSend = countOfBytesExpectedToSend
    }

    func resume() {
        resumeCallCount += 1
    }

    func cancel() {
        cancelCallCount += 1
    }
}

private final class RecordingSession: StockpileURLSessioning, @unchecked Sendable {
    private(set) var lastRequest: URLRequest?
    private(set) var lastFileURL: URL?
    let uploadTask: RecordingUploadTask
    private let existingTasks: [RecordingUploadTask]
    let eventSink: URLSessionTaskEventSink

    init(
        uploadTask: RecordingUploadTask,
        existingTasks: [RecordingUploadTask] = [],
        eventSink: URLSessionTaskEventSink
    ) {
        self.uploadTask = uploadTask
        self.existingTasks = existingTasks
        self.eventSink = eventSink
    }

    func uploadTask(with request: URLRequest, fromFile fileURL: URL) -> any StockpileURLSessionTasking {
        lastRequest = request
        lastFileURL = fileURL
        return uploadTask
    }

    func allTasks() async -> [any StockpileURLSessionTasking] {
        existingTasks
    }
}

private final class SessionFactoryRecorder: @unchecked Sendable {
    private(set) var descriptors: [StockpileUploadSessionDescriptor] = []
    private(set) var sessions: [RecordingSession] = []

    func makeSession(
        descriptor: StockpileUploadSessionDescriptor,
        eventSink: URLSessionTaskEventSink,
        taskIdentifier: Int,
        existingTaskDescription: String? = nil,
        existingBytesSent: Int64 = 0,
        existingBytesExpected: Int64 = 0
    ) -> any StockpileURLSessioning {
        descriptors.append(descriptor)
        let existingTasks: [RecordingUploadTask]
        if let existingTaskDescription {
            existingTasks = [
                RecordingUploadTask(
                    taskIdentifier: taskIdentifier,
                    taskDescription: existingTaskDescription,
                    countOfBytesSent: existingBytesSent,
                    countOfBytesExpectedToSend: existingBytesExpected
                )
            ]
        } else {
            existingTasks = []
        }
        let session = RecordingSession(
            uploadTask: RecordingUploadTask(taskIdentifier: taskIdentifier),
            existingTasks: existingTasks,
            eventSink: eventSink
        )
        sessions.append(session)
        return session
    }
}
