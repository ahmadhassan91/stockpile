import Foundation

public struct URLSessionStockpileUploadServiceConfiguration: Sendable, Hashable, Equatable {
    public let uploadURL: URL
    public let httpMethod: String
    public let additionalHeaders: [String: String]
    public let timeoutInterval: TimeInterval
    public let sharedContainerIdentifier: String?
    public let allowsCellularAccess: Bool
    public let waitsForConnectivity: Bool
    public let isDiscretionary: Bool

    public init(
        uploadURL: URL,
        httpMethod: String = "POST",
        additionalHeaders: [String: String] = [:],
        timeoutInterval: TimeInterval = 60,
        sharedContainerIdentifier: String? = nil,
        allowsCellularAccess: Bool = true,
        waitsForConnectivity: Bool = true,
        isDiscretionary: Bool = false
    ) {
        self.uploadURL = uploadURL
        self.httpMethod = httpMethod
        self.additionalHeaders = additionalHeaders
        self.timeoutInterval = timeoutInterval
        self.sharedContainerIdentifier = sharedContainerIdentifier
        self.allowsCellularAccess = allowsCellularAccess
        self.waitsForConnectivity = waitsForConnectivity
        self.isDiscretionary = isDiscretionary
    }
}

public enum URLSessionStockpileUploadServiceError: Error, Sendable, Equatable {
    case unreadableLocalFile(URL)
}

struct StockpileUploadSessionDescriptor: Sendable, Hashable, Equatable {
    let backgroundSessionIdentifier: String?

    init(backgroundSessionIdentifier: String?) {
        self.backgroundSessionIdentifier = backgroundSessionIdentifier?.stockpileNonEmptyTrimmed
    }

    var sessionKey: String {
        backgroundSessionIdentifier ?? "com.stockpile.uploadpipeline.foreground"
    }
}

struct StockpileUploadTaskProgressEvent: Sendable, Equatable {
    let sessionKey: String
    let taskIdentifier: Int
    let totalBytesSent: Int64
    let totalBytesExpectedToSend: Int64
}

struct StockpileUploadTaskResponseDataEvent: Sendable, Equatable {
    let sessionKey: String
    let taskIdentifier: Int
    let data: Data
}

struct StockpileUploadHTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let headers: [String: String]
}

struct StockpileUploadErrorSummary: Sendable, Equatable {
    let domain: String
    let code: Int
    let localizedDescription: String

    init(error: any Error) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        localizedDescription = nsError.localizedDescription
    }
}

struct StockpileUploadTaskCompletionEvent: Sendable, Equatable {
    let sessionKey: String
    let taskIdentifier: Int
    let response: StockpileUploadHTTPResponse?
    let error: StockpileUploadErrorSummary?
}

enum StockpileUploadSessionConfigurationFactory {
    static func makeConfiguration(
        descriptor: StockpileUploadSessionDescriptor,
        configuration: URLSessionStockpileUploadServiceConfiguration
    ) -> URLSessionConfiguration {
        let sessionConfiguration: URLSessionConfiguration
        if let identifier = descriptor.backgroundSessionIdentifier {
            sessionConfiguration = URLSessionConfiguration.background(withIdentifier: identifier)
            sessionConfiguration.sessionSendsLaunchEvents = true
            sessionConfiguration.sharedContainerIdentifier = configuration.sharedContainerIdentifier
        } else {
            sessionConfiguration = URLSessionConfiguration.default
        }

        sessionConfiguration.httpMaximumConnectionsPerHost = 1
        sessionConfiguration.httpShouldUsePipelining = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeoutInterval
        sessionConfiguration.timeoutIntervalForResource = resourceTimeoutInterval(
            descriptor: descriptor,
            configuration: configuration
        )
        sessionConfiguration.allowsCellularAccess = configuration.allowsCellularAccess
        sessionConfiguration.allowsConstrainedNetworkAccess = true
        sessionConfiguration.allowsExpensiveNetworkAccess = true
        sessionConfiguration.waitsForConnectivity = configuration.waitsForConnectivity
        sessionConfiguration.isDiscretionary = configuration.isDiscretionary
        return sessionConfiguration
    }

    private static func resourceTimeoutInterval(
        descriptor: StockpileUploadSessionDescriptor,
        configuration: URLSessionStockpileUploadServiceConfiguration
    ) -> TimeInterval {
        guard descriptor.backgroundSessionIdentifier != nil else {
            return max(configuration.timeoutInterval * 2, configuration.timeoutInterval)
        }

        // Background transfers may wait for connectivity or app relaunch before URLSession completes.
        return max(configuration.timeoutInterval * 60, 60 * 60)
    }
}

enum StockpileUploadRequestBuilder {
    static func makeRequest(
        for request: StockpileUploadTaskRequest,
        configuration: URLSessionStockpileUploadServiceConfiguration
    ) -> URLRequest {
        var urlRequest = URLRequest(url: configuration.uploadURL)
        urlRequest.httpMethod = configuration.httpMethod
        urlRequest.timeoutInterval = configuration.timeoutInterval
        urlRequest.setValue(request.file.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.file.byteCount.formatted(), forHTTPHeaderField: "Content-Length")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(request.uploadID, forHTTPHeaderField: "X-Stockpile-Upload-ID")
        urlRequest.setValue(request.file.fileName, forHTTPHeaderField: "X-Stockpile-File-Name")
        urlRequest.setValue(makeTimestamp(request.createdAt), forHTTPHeaderField: "X-Stockpile-Upload-Created-At")

        if let checksum = request.file.checksumSHA256?.stockpileNonEmptyTrimmed {
            urlRequest.setValue(checksum, forHTTPHeaderField: "X-Stockpile-Checksum-SHA256")
        }

        if let backgroundSessionIdentifier = request.backgroundSessionIdentifier?.stockpileNonEmptyTrimmed {
            urlRequest.setValue(backgroundSessionIdentifier, forHTTPHeaderField: "X-Stockpile-Background-Session-ID")
        }

        for (header, value) in configuration.additionalHeaders.sorted(by: { $0.key < $1.key }) {
            urlRequest.setValue(value, forHTTPHeaderField: header)
        }

        return urlRequest
    }

    private static func makeTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct StockpileUploadThroughputTracker: Sendable, Equatable {
    private(set) var lastBytesSent: Int64?
    private(set) var lastSampleDate: Date?

    mutating func recordSample(totalBytesSent: Int64, at date: Date) -> Double? {
        defer {
            lastBytesSent = totalBytesSent
            lastSampleDate = date
        }

        guard let lastBytesSent, let lastSampleDate else {
            return nil
        }

        let elapsed = date.timeIntervalSince(lastSampleDate)
        let byteDelta = totalBytesSent - lastBytesSent
        guard elapsed > 0, byteDelta > 0 else {
            return nil
        }

        return Double(byteDelta) / elapsed
    }
}

enum StockpileUploadTransferStateFactory {
    static func makeState(
        bytesTransferred: Int64,
        totalBytesExpected: Int64,
        retryCount: Int,
        throughputBytesPerSecond: Double?
    ) -> StockpileByteTransferState {
        let totalBytes = max(totalBytesExpected, bytesTransferred)
        let isAwaitingServerReceipt = totalBytes > 0 && bytesTransferred >= totalBytes
        let headline: String
        if bytesTransferred <= 0 {
            headline = "Starting upload"
        } else if isAwaitingServerReceipt {
            headline = "Finalizing transfer"
        } else if retryCount > 0 {
            headline = "Resuming upload"
        } else {
            headline = "Uploading bytes"
        }

        let detailBase: String
        if isAwaitingServerReceipt {
            detailBase = "All \(formatBytes(totalBytes)) have been handed to the uploader."
        } else if totalBytes > 0 {
            detailBase = "\(formatBytes(bytesTransferred)) of \(formatBytes(totalBytes)) sent."
        } else {
            detailBase = "\(formatBytes(bytesTransferred)) sent."
        }

        var detailParts = [detailBase]
        if let throughputBytesPerSecond {
            let rate = formatBytes(Int64(throughputBytesPerSecond.rounded()))
            detailParts.append(
                isAwaitingServerReceipt
                    ? "Last observed rate \(rate) per second."
                    : "\(rate) per second."
            )
        } else if bytesTransferred == 0 {
            detailParts.append("Waiting for iOS to start the background transfer and send the first progress callback.")
        }

        if isAwaitingServerReceipt {
            detailParts.append("Waiting for the server to confirm receipt.")
        }

        if retryCount > 0 {
            detailParts.append("Attempt \(retryCount + 1).")
        }

        return StockpileByteTransferState(
            bytesTransferred: bytesTransferred,
            totalBytes: totalBytes,
            retryCount: retryCount,
            throughputBytesPerSecond: throughputBytesPerSecond,
            headline: headline,
            detail: detailParts.joined(separator: " ")
        )
    }

    private static func formatBytes(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

enum StockpileUploadResponseInterpreter {
    static func receiptID(
        response: StockpileUploadHTTPResponse?,
        responseBody: Data,
        fallbackTaskID: String
    ) -> String {
        if let headerValue = headerValue(
            in: response?.headers,
            matching: ["x-stockpile-receipt-id", "x-receipt-id"]
        ) {
            return headerValue
        }

        if let jsonValue = bodyValue(in: responseBody, keys: ["receipt_id", "receiptId", "serverReceiptID"]) {
            return jsonValue
        }

        return "receipt_\(fallbackTaskID)"
    }

    static func serverUploadID(
        response: StockpileUploadHTTPResponse?,
        responseBody: Data
    ) -> String? {
        if let headerValue = headerValue(
            in: response?.headers,
            matching: ["x-stockpile-server-upload-id", "x-upload-id"]
        ) {
            return headerValue
        }

        return bodyValue(in: responseBody, keys: ["server_upload_id", "serverUploadID", "upload_id", "uploadId"])
    }

    private static func headerValue(in headers: [String: String]?, matching keys: [String]) -> String? {
        guard let headers else { return nil }
        let lowercasedHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        for key in keys where lowercasedHeaders[key]?.isEmpty == false {
            return lowercasedHeaders[key]
        }
        return nil
    }

    private static func bodyValue(in responseBody: Data, keys: [String]) -> String? {
        guard
            !responseBody.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: responseBody),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

        for key in keys {
            if let value = dictionary[key] as? String, value.isEmpty == false {
                return value
            }
        }

        return nil
    }
}

enum StockpileUploadFailureFactory {
    static func makeFailure(
        at failedAt: Date,
        response: StockpileUploadHTTPResponse? = nil,
        error: StockpileUploadErrorSummary? = nil
    ) -> StockpileUploadFailureState {
        if let response, (200 ..< 300).contains(response.statusCode) == false {
            let recoverable = response.statusCode == 408 || response.statusCode == 429 || (500 ... 599).contains(response.statusCode)
            return StockpileUploadFailureState(
                failedAt: failedAt,
                reason: "Server responded with status \(response.statusCode)",
                recoverable: recoverable,
                headline: recoverable ? "Upload interrupted" : "Upload failed",
                detail: recoverable
                    ? "The server could not finalize the upload yet. Retry once service conditions improve."
                    : "The server rejected the upload before a receipt was issued."
            )
        }

        if let error {
            let recoverableCodes: Set<Int> = [
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorInternationalRoamingOff,
                NSURLErrorCallIsActive,
                NSURLErrorDataNotAllowed,
            ]
            let recoverable = error.domain == NSURLErrorDomain && recoverableCodes.contains(error.code)
            return StockpileUploadFailureState(
                failedAt: failedAt,
                reason: error.localizedDescription,
                recoverable: recoverable,
                headline: recoverable ? "Upload interrupted" : "Upload failed",
                detail: recoverable
                    ? "The network dropped before the server handoff completed. The file can be retried safely."
                    : "The upload task ended before the server could confirm receipt."
            )
        }

        return StockpileUploadFailureState(
            failedAt: failedAt,
            reason: "Unknown upload failure",
            recoverable: false,
            headline: "Upload failed",
            detail: "The upload ended unexpectedly before a server receipt was returned."
        )
    }
}

enum StockpileUploadLocalFileInspector {
    static func inspect(file: StockpileUploadFileDescriptor) -> StockpileLocalFilePreparationState {
        let path = file.fileURL.path
        let inspectedByteCount = inspectedByteCount(for: file)
        let readable = FileManager.default.isReadableFile(atPath: path)

        return StockpileLocalFilePreparationState(
            inspectedByteCount: inspectedByteCount,
            securityScopeActive: file.fileURL.isFileURL,
            isReadable: readable,
            headline: "Preparing local file",
            detail: readable
                ? "Validated local access and queued the file for URLSession upload."
                : "The file could not be opened for upload from its current location."
        )
    }

    private static func inspectedByteCount(for file: StockpileUploadFileDescriptor) -> Int64 {
        if file.byteCount > 0 {
            return file.byteCount
        }

        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.fileURL.path),
            let fileSize = attributes[.size] as? NSNumber
        else {
            return 0
        }

        return fileSize.int64Value
    }
}

protocol StockpileURLSessionTasking: AnyObject, Sendable {
    var taskIdentifier: Int { get }
    var taskDescription: String? { get set }
    var originalRequest: URLRequest? { get }
    var currentRequest: URLRequest? { get }
    var response: URLResponse? { get }
    var countOfBytesSent: Int64 { get }
    var countOfBytesExpectedToSend: Int64 { get }
    func resume()
    func cancel()
}

protocol StockpileURLSessioning: AnyObject, Sendable {
    func uploadTask(with request: URLRequest, fromFile fileURL: URL) -> any StockpileURLSessionTasking
    func allTasks() async -> [any StockpileURLSessionTasking]
}

final class URLSessionTaskEventSink: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private let sessionKey: String
    private let backgroundSessionIdentifier: String?
    private let onProgress: @Sendable (StockpileUploadTaskProgressEvent) -> Void
    private let onResponseData: @Sendable (StockpileUploadTaskResponseDataEvent) -> Void
    private let onCompletion: @Sendable (StockpileUploadTaskCompletionEvent) -> Void
    private let onBackgroundEventsFinished: @Sendable (String) -> Void

    init(
        sessionKey: String,
        backgroundSessionIdentifier: String?,
        onProgress: @escaping @Sendable (StockpileUploadTaskProgressEvent) -> Void,
        onResponseData: @escaping @Sendable (StockpileUploadTaskResponseDataEvent) -> Void,
        onCompletion: @escaping @Sendable (StockpileUploadTaskCompletionEvent) -> Void,
        onBackgroundEventsFinished: @escaping @Sendable (String) -> Void
    ) {
        self.sessionKey = sessionKey
        self.backgroundSessionIdentifier = backgroundSessionIdentifier
        self.onProgress = onProgress
        self.onResponseData = onResponseData
        self.onCompletion = onCompletion
        self.onBackgroundEventsFinished = onBackgroundEventsFinished
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(
            StockpileUploadTaskProgressEvent(
                sessionKey: sessionKey,
                taskIdentifier: task.taskIdentifier,
                totalBytesSent: totalBytesSent,
                totalBytesExpectedToSend: totalBytesExpectedToSend
            )
        )
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onResponseData(
            StockpileUploadTaskResponseDataEvent(
                sessionKey: sessionKey,
                taskIdentifier: dataTask.taskIdentifier,
                data: data
            )
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let response = (task.response as? HTTPURLResponse).map { httpResponse in
            StockpileUploadHTTPResponse(
                statusCode: httpResponse.statusCode,
                headers: Dictionary(uniqueKeysWithValues: httpResponse.allHeaderFields.compactMap { key, value in
                    guard let key = key as? String else { return nil }
                    return (key, String(describing: value))
                })
            )
        }

        onCompletion(
            StockpileUploadTaskCompletionEvent(
                sessionKey: sessionKey,
                taskIdentifier: task.taskIdentifier,
                response: response,
                error: error.map(StockpileUploadErrorSummary.init(error:))
            )
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let sessionIdentifier = session.configuration.identifier ?? backgroundSessionIdentifier else {
            return
        }

        onBackgroundEventsFinished(sessionIdentifier)
    }
}

final class FoundationStockpileURLSessionTask: StockpileURLSessionTasking, @unchecked Sendable {
    private let task: URLSessionTask

    init(task: URLSessionTask) {
        self.task = task
    }

    var taskIdentifier: Int {
        task.taskIdentifier
    }

    var taskDescription: String? {
        get { task.taskDescription }
        set { task.taskDescription = newValue }
    }

    var originalRequest: URLRequest? {
        task.originalRequest
    }

    var currentRequest: URLRequest? {
        task.currentRequest
    }

    var response: URLResponse? {
        task.response
    }

    var countOfBytesSent: Int64 {
        task.countOfBytesSent
    }

    var countOfBytesExpectedToSend: Int64 {
        task.countOfBytesExpectedToSend
    }

    func resume() {
        task.resume()
    }

    func cancel() {
        task.cancel()
    }
}

final class FoundationStockpileURLSession: StockpileURLSessioning, @unchecked Sendable {
    private let session: URLSession
    private let delegate: URLSessionTaskEventSink

    init(
        descriptor: StockpileUploadSessionDescriptor,
        configuration: URLSessionConfiguration,
        eventSink: URLSessionTaskEventSink
    ) {
        let queue = OperationQueue()
        queue.name = "StockpileUploadPipeline.\(descriptor.sessionKey)"
        queue.maxConcurrentOperationCount = 1

        delegate = eventSink
        session = URLSession(configuration: configuration, delegate: eventSink, delegateQueue: queue)
    }

    func uploadTask(with request: URLRequest, fromFile fileURL: URL) -> any StockpileURLSessionTasking {
        FoundationStockpileURLSessionTask(task: session.uploadTask(with: request, fromFile: fileURL))
    }

    func allTasks() async -> [any StockpileURLSessionTasking] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.map(FoundationStockpileURLSessionTask.init(task:)))
            }
        }
    }
}

public actor URLSessionStockpileUploadService: StockpileUploadServicing {
    typealias SessionFactory = @Sendable (StockpileUploadSessionDescriptor, URLSessionTaskEventSink) -> any StockpileURLSessioning
    typealias RequestBuilder = @Sendable (StockpileUploadTaskRequest) -> URLRequest

    private struct StreamState {
        var snapshots: [StockpileUploadProgressSnapshot]
        var continuations: [UUID: AsyncStream<StockpileUploadProgressSnapshot>.Continuation]
    }

    private struct ManagedTaskState {
        var task: StockpileUploadTask
        let sessionKey: String
        let sessionTaskIdentifier: Int
        var retryCount: Int
        var responseData: Data
        var throughputTracker: StockpileUploadThroughputTracker
    }

    private let configuration: URLSessionStockpileUploadServiceConfiguration
    private let now: @Sendable () -> Date
    private let sessionFactory: SessionFactory
    private let requestBuilder: RequestBuilder

    private var taskCounter = 0
    private var tasks: [String: StockpileUploadTask] = [:]
    private var managedTaskStates: [String: ManagedTaskState] = [:]
    private var streamStates: [String: StreamState] = [:]
    private var sessions: [String: any StockpileURLSessioning] = [:]
    private var taskIDsBySessionTaskKey: [String: String] = [:]
    private var sessionTasks: [String: any StockpileURLSessionTasking] = [:]

    public init(
        configuration: URLSessionStockpileUploadServiceConfiguration,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.now = now
        requestBuilder = { request in
            StockpileUploadRequestBuilder.makeRequest(for: request, configuration: configuration)
        }
        sessionFactory = { descriptor, eventSink in
            FoundationStockpileURLSession(
                descriptor: descriptor,
                configuration: StockpileUploadSessionConfigurationFactory.makeConfiguration(
                    descriptor: descriptor,
                    configuration: configuration
                ),
                eventSink: eventSink
            )
        }
    }

    init(
        configuration: URLSessionStockpileUploadServiceConfiguration,
        now: @escaping @Sendable () -> Date = { Date() },
        requestBuilder: @escaping RequestBuilder,
        sessionFactory: @escaping SessionFactory
    ) {
        self.configuration = configuration
        self.now = now
        self.requestBuilder = requestBuilder
        self.sessionFactory = sessionFactory
    }

    public func createUploadTask(request: StockpileUploadTaskRequest) async throws -> StockpileUploadTask {
        taskCounter += 1

        let taskID = request.uploadID.isEmpty ? Self.makeID(prefix: "upload_task", number: taskCounter) : request.uploadID
        let preparationState = StockpileUploadLocalFileInspector.inspect(file: request.file)
        guard preparationState.isReadable else {
            throw URLSessionStockpileUploadServiceError.unreadableLocalFile(request.file.fileURL)
        }

        let initialStage = StockpileUploadTaskStage.preparingLocalFile(preparationState)
        let createdAt = request.createdAt
        let initialTask = StockpileUploadTask(
            taskID: taskID,
            file: request.file,
            backgroundSessionIdentifier: request.backgroundSessionIdentifier,
            createdAt: createdAt,
            updatedAt: createdAt,
            stage: initialStage
        )

        tasks[taskID] = initialTask
        streamStates[taskID] = StreamState(
            snapshots: [StockpileUploadProgressSnapshot(taskID: taskID, stage: initialStage, capturedAt: createdAt)],
            continuations: [:]
        )

        let descriptor = StockpileUploadSessionDescriptor(backgroundSessionIdentifier: request.backgroundSessionIdentifier)
        let session = session(for: descriptor)
        let sessionTask = session.uploadTask(with: requestBuilder(request), fromFile: request.file.fileURL)
        sessionTask.taskDescription = taskID
        let sessionTaskKey = Self.makeSessionTaskKey(sessionKey: descriptor.sessionKey, taskIdentifier: sessionTask.taskIdentifier)

        let transferStage = StockpileUploadTaskStage.transferringBytes(
            StockpileUploadTransferStateFactory.makeState(
                bytesTransferred: 0,
                totalBytesExpected: request.file.byteCount,
                retryCount: 0,
                throughputBytesPerSecond: nil
            )
        )
        let transferTask = StockpileUploadTask(
            taskID: taskID,
            file: request.file,
            backgroundSessionIdentifier: request.backgroundSessionIdentifier,
            createdAt: createdAt,
            updatedAt: now(),
            stage: transferStage
        )

        managedTaskStates[taskID] = ManagedTaskState(
            task: transferTask,
            sessionKey: descriptor.sessionKey,
            sessionTaskIdentifier: sessionTask.taskIdentifier,
            retryCount: 0,
            responseData: Data(),
            throughputTracker: StockpileUploadThroughputTracker()
        )
        taskIDsBySessionTaskKey[sessionTaskKey] = taskID
        sessionTasks[sessionTaskKey] = sessionTask
        tasks[taskID] = transferTask
        emit(taskID: taskID, stage: transferStage)
        sessionTask.resume()

        return transferTask
    }

    public func reattachUploadTask(request: StockpileUploadTaskRestoreRequest) async throws -> StockpileUploadTask? {
        let descriptor = StockpileUploadSessionDescriptor(backgroundSessionIdentifier: request.backgroundSessionIdentifier)
        let session = session(for: descriptor)
        let existingTask = await findExistingTask(in: session, taskID: request.taskID)
        guard let existingTask else {
            return nil
        }

        let restoredTask = makeRestoredTask(
            from: existingTask,
            taskID: request.taskID,
            file: request.file,
            backgroundSessionIdentifier: request.backgroundSessionIdentifier,
            createdAt: request.createdAt
        )
        let sessionTaskKey = Self.makeSessionTaskKey(
            sessionKey: descriptor.sessionKey,
            taskIdentifier: existingTask.taskIdentifier
        )

        managedTaskStates[request.taskID] = ManagedTaskState(
            task: restoredTask,
            sessionKey: descriptor.sessionKey,
            sessionTaskIdentifier: existingTask.taskIdentifier,
            retryCount: stageRetryCount(from: restoredTask.stage),
            responseData: Data(),
            throughputTracker: StockpileUploadThroughputTracker()
        )
        taskIDsBySessionTaskKey[sessionTaskKey] = request.taskID
        sessionTasks[sessionTaskKey] = existingTask
        tasks[request.taskID] = restoredTask
        streamStates[request.taskID] = StreamState(
            snapshots: [StockpileUploadProgressSnapshot(taskID: request.taskID, stage: restoredTask.stage, capturedAt: restoredTask.updatedAt)],
            continuations: [:]
        )

        return restoredTask
    }

    nonisolated public func progressSnapshots(for taskID: String) -> AsyncStream<StockpileUploadProgressSnapshot> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else { return }
                await self.registerContinuation(continuation, taskID: taskID)
            }
        }
    }

    public func task(taskID: String) async -> StockpileUploadTask? {
        tasks[taskID]
    }

    public func cancelUpload(taskID: String) async {
        guard let managedState = managedTaskStates[taskID] else { return }
        let sessionTaskKey = Self.makeSessionTaskKey(
            sessionKey: managedState.sessionKey,
            taskIdentifier: managedState.sessionTaskIdentifier
        )

        sessionTasks[sessionTaskKey]?.cancel()

        let failedStage = StockpileUploadTaskStage.failed(
            StockpileUploadFailureState(
                failedAt: now(),
                reason: "Cancelled by operator",
                recoverable: true,
                headline: "Upload cancelled",
                detail: "The URLSession upload was cancelled before the server handoff completed."
            )
        )

        let failedTask = StockpileUploadTask(
            taskID: managedState.task.taskID,
            file: managedState.task.file,
            backgroundSessionIdentifier: managedState.task.backgroundSessionIdentifier,
            createdAt: managedState.task.createdAt,
            updatedAt: now(),
            stage: failedStage
        )

        tasks[taskID] = failedTask
        emit(taskID: taskID, stage: failedStage)
        finish(taskID: taskID)
        removeActiveTask(taskID: taskID, sessionTaskKey: sessionTaskKey)
    }

    func handleProgress(_ event: StockpileUploadTaskProgressEvent) {
        guard var managedState = managedTaskState(for: event.sessionKey, taskIdentifier: event.taskIdentifier) else { return }

        let updatedAt = now()
        let throughput = managedState.throughputTracker.recordSample(totalBytesSent: event.totalBytesSent, at: updatedAt)
        let totalBytesExpected = event.totalBytesExpectedToSend > 0 ? event.totalBytesExpectedToSend : managedState.task.file.byteCount
        let stage = StockpileUploadTaskStage.transferringBytes(
            StockpileUploadTransferStateFactory.makeState(
                bytesTransferred: event.totalBytesSent,
                totalBytesExpected: totalBytesExpected,
                retryCount: managedState.retryCount,
                throughputBytesPerSecond: throughput
            )
        )
        let task = StockpileUploadTask(
            taskID: managedState.task.taskID,
            file: managedState.task.file,
            backgroundSessionIdentifier: managedState.task.backgroundSessionIdentifier,
            createdAt: managedState.task.createdAt,
            updatedAt: updatedAt,
            stage: stage
        )

        managedState.task = task
        managedTaskStates[task.taskID] = managedState
        tasks[task.taskID] = task
        emit(taskID: task.taskID, stage: stage)
    }

    func handleResponseData(_ event: StockpileUploadTaskResponseDataEvent) {
        guard var managedState = managedTaskState(for: event.sessionKey, taskIdentifier: event.taskIdentifier) else { return }
        managedState.responseData.append(event.data)
        managedTaskStates[managedState.task.taskID] = managedState
    }

    func handleCompletion(_ event: StockpileUploadTaskCompletionEvent) {
        guard let taskID = taskIDsBySessionTaskKey[Self.makeSessionTaskKey(sessionKey: event.sessionKey, taskIdentifier: event.taskIdentifier)],
              var managedState = managedTaskStates[taskID]
        else {
            return
        }

        if let response = event.response, (200 ..< 300).contains(response.statusCode) == false {
            let failure = StockpileUploadFailureFactory.makeFailure(at: now(), response: response)
            applyTerminalStage(.failed(failure), to: taskID, managedState: managedState)
            return
        }

        if let error = event.error {
            let failure = StockpileUploadFailureFactory.makeFailure(at: now(), error: error)
            applyTerminalStage(.failed(failure), to: taskID, managedState: managedState)
            return
        }

        let acknowledgedAt = now()
        let serverUploadID = StockpileUploadResponseInterpreter.serverUploadID(
            response: event.response,
            responseBody: managedState.responseData
        )
        let handoffStage = StockpileUploadTaskStage.handingOffToServer(
            StockpileServerHandoffState(
                serverUploadID: serverUploadID,
                acknowledgedAt: acknowledgedAt,
                headline: "Handing off to server",
                detail: "The transfer finished and the server is issuing the final upload receipt."
            )
        )
        let handoffTask = StockpileUploadTask(
            taskID: managedState.task.taskID,
            file: managedState.task.file,
            backgroundSessionIdentifier: managedState.task.backgroundSessionIdentifier,
            createdAt: managedState.task.createdAt,
            updatedAt: acknowledgedAt,
            stage: handoffStage
        )

        managedState.task = handoffTask
        managedTaskStates[taskID] = managedState
        tasks[taskID] = handoffTask
        emit(taskID: taskID, stage: handoffStage)

        let completedAt = now()
        let completionStage = StockpileUploadTaskStage.completed(
            StockpileUploadCompletionState(
                uploadID: managedState.task.taskID,
                serverUploadID: serverUploadID,
                completedAt: completedAt,
                serverReceiptID: StockpileUploadResponseInterpreter.receiptID(
                    response: event.response,
                    responseBody: managedState.responseData,
                    fallbackTaskID: taskID
                ),
                headline: "Upload complete",
                detail: "The server acknowledged the upload and issued a receipt."
            )
        )
        applyTerminalStage(completionStage, to: taskID, managedState: managedState)
    }

    private func session(for descriptor: StockpileUploadSessionDescriptor) -> any StockpileURLSessioning {
        if let session = sessions[descriptor.sessionKey] {
            return session
        }

        let eventSink = makeEventSink(for: descriptor)
        let session = sessionFactory(descriptor, eventSink)
        sessions[descriptor.sessionKey] = session
        return session
    }

    private func findExistingTask(
        in session: any StockpileURLSessioning,
        taskID: String
    ) async -> (any StockpileURLSessionTasking)? {
        let existingTasks = await session.allTasks()
        return existingTasks.first { task in
            if task.taskDescription == taskID {
                return true
            }

            return task.originalRequest?.value(forHTTPHeaderField: "X-Stockpile-Upload-ID") == taskID
                || task.currentRequest?.value(forHTTPHeaderField: "X-Stockpile-Upload-ID") == taskID
        }
    }

    private func makeRestoredTask(
        from existingTask: any StockpileURLSessionTasking,
        taskID: String,
        file: StockpileUploadFileDescriptor,
        backgroundSessionIdentifier: String?,
        createdAt: Date
    ) -> StockpileUploadTask {
        let updatedAt = now()
        let bytesTransferred = existingTask.countOfBytesSent
        let totalBytesExpected = existingTask.countOfBytesExpectedToSend > 0
            ? existingTask.countOfBytesExpectedToSend
            : file.byteCount

        let stage: StockpileUploadTaskStage
        if totalBytesExpected > 0, bytesTransferred >= totalBytesExpected {
            stage = .handingOffToServer(
                StockpileServerHandoffState(
                    serverUploadID: nil,
                    acknowledgedAt: nil,
                    headline: "Resuming server handoff",
                    detail: "The upload bytes were already delivered. Waiting for the server to confirm the handoff after the app relaunched."
                )
            )
        } else {
            stage = .transferringBytes(
                StockpileUploadTransferStateFactory.makeState(
                    bytesTransferred: bytesTransferred,
                    totalBytesExpected: totalBytesExpected,
                    retryCount: 1,
                    throughputBytesPerSecond: nil
                )
            )
        }

        return StockpileUploadTask(
            taskID: taskID,
            file: file,
            backgroundSessionIdentifier: backgroundSessionIdentifier,
            createdAt: createdAt,
            updatedAt: updatedAt,
            stage: stage
        )
    }

    private func stageRetryCount(from stage: StockpileUploadTaskStage) -> Int {
        switch stage {
        case .transferringBytes(let transferState):
            return transferState.retryCount
        case .queuedForRetry(let retryState):
            return retryState.attempt
        case .handingOffToServer, .completed, .failed, .preparingLocalFile:
            return 1
        }
    }

    private func makeEventSink(for descriptor: StockpileUploadSessionDescriptor) -> URLSessionTaskEventSink {
        URLSessionTaskEventSink(
            sessionKey: descriptor.sessionKey,
            backgroundSessionIdentifier: descriptor.backgroundSessionIdentifier,
            onProgress: { [weak self] event in
                Task { await self?.handleProgress(event) }
            },
            onResponseData: { [weak self] event in
                Task { await self?.handleResponseData(event) }
            },
            onCompletion: { [weak self] event in
                Task { await self?.handleCompletion(event) }
            },
            onBackgroundEventsFinished: { sessionIdentifier in
                StockpileBackgroundUploadEventCoordinator.finishEvents(
                    forSessionIdentifier: sessionIdentifier
                )
            }
        )
    }

    private func managedTaskState(for sessionKey: String, taskIdentifier: Int) -> ManagedTaskState? {
        let sessionTaskKey = Self.makeSessionTaskKey(sessionKey: sessionKey, taskIdentifier: taskIdentifier)
        guard let taskID = taskIDsBySessionTaskKey[sessionTaskKey] else { return nil }
        return managedTaskStates[taskID]
    }

    private func applyTerminalStage(
        _ stage: StockpileUploadTaskStage,
        to taskID: String,
        managedState: ManagedTaskState
    ) {
        let terminalTask = StockpileUploadTask(
            taskID: managedState.task.taskID,
            file: managedState.task.file,
            backgroundSessionIdentifier: managedState.task.backgroundSessionIdentifier,
            createdAt: managedState.task.createdAt,
            updatedAt: now(),
            stage: stage
        )
        let sessionTaskKey = Self.makeSessionTaskKey(
            sessionKey: managedState.sessionKey,
            taskIdentifier: managedState.sessionTaskIdentifier
        )

        tasks[taskID] = terminalTask
        emit(taskID: taskID, stage: stage)
        finish(taskID: taskID)
        removeActiveTask(taskID: taskID, sessionTaskKey: sessionTaskKey)
    }

    private func registerContinuation(
        _ continuation: AsyncStream<StockpileUploadProgressSnapshot>.Continuation,
        taskID: String
    ) {
        var state = streamStates[taskID, default: StreamState(snapshots: [], continuations: [:])]
        let continuationID = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                await self.removeContinuation(taskID: taskID, continuationID: continuationID)
            }
        }

        for snapshot in state.snapshots {
            continuation.yield(snapshot)
        }

        if state.snapshots.last?.stage.isTerminal == true {
            continuation.finish()
            return
        }

        state.continuations[continuationID] = continuation
        streamStates[taskID] = state
    }

    private func emit(taskID: String, stage: StockpileUploadTaskStage) {
        let snapshot = StockpileUploadProgressSnapshot(taskID: taskID, stage: stage, capturedAt: now())
        var state = streamStates[taskID, default: StreamState(snapshots: [], continuations: [:])]
        state.snapshots.append(snapshot)
        streamStates[taskID] = state

        for continuation in state.continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func finish(taskID: String) {
        guard let state = streamStates[taskID] else { return }
        for continuation in state.continuations.values {
            continuation.finish()
        }
        streamStates[taskID]?.continuations = [:]
    }

    private func removeContinuation(taskID: String, continuationID: UUID) {
        streamStates[taskID]?.continuations.removeValue(forKey: continuationID)
    }

    private func removeActiveTask(taskID: String, sessionTaskKey: String) {
        managedTaskStates.removeValue(forKey: taskID)
        taskIDsBySessionTaskKey.removeValue(forKey: sessionTaskKey)
        sessionTasks.removeValue(forKey: sessionTaskKey)
    }

    private static func makeID(prefix: String, number: Int) -> String {
        "\(prefix)_\(number)"
    }

    private static func makeSessionTaskKey(sessionKey: String, taskIdentifier: Int) -> String {
        "\(sessionKey)#\(taskIdentifier)"
    }
}

private extension String {
    var stockpileNonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
