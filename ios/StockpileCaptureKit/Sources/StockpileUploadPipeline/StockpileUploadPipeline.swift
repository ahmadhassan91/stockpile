import Foundation

public enum StockpileUploadPipelineNamespace {}

public struct StockpileUploadFileDescriptor: Sendable, Hashable, Equatable {
    public let fileURL: URL
    public let fileName: String
    public let byteCount: Int64
    public let contentType: String
    public let checksumSHA256: String?

    public init(
        fileURL: URL,
        fileName: String,
        byteCount: Int64,
        contentType: String,
        checksumSHA256: String? = nil
    ) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.byteCount = byteCount
        self.contentType = contentType
        self.checksumSHA256 = checksumSHA256
    }
}

public struct StockpileUploadTaskRequest: Sendable, Hashable, Equatable {
    public let uploadID: String
    public let file: StockpileUploadFileDescriptor
    public let backgroundSessionIdentifier: String?
    public let createdAt: Date

    public init(
        uploadID: String,
        file: StockpileUploadFileDescriptor,
        backgroundSessionIdentifier: String? = nil,
        createdAt: Date = Date()
    ) {
        self.uploadID = uploadID
        self.file = file
        self.backgroundSessionIdentifier = backgroundSessionIdentifier
        self.createdAt = createdAt
    }
}

public struct StockpileUploadTaskRestoreRequest: Sendable, Hashable, Equatable {
    public let taskID: String
    public let file: StockpileUploadFileDescriptor
    public let backgroundSessionIdentifier: String?
    public let createdAt: Date

    public init(
        taskID: String,
        file: StockpileUploadFileDescriptor,
        backgroundSessionIdentifier: String? = nil,
        createdAt: Date
    ) {
        self.taskID = taskID
        self.file = file
        self.backgroundSessionIdentifier = backgroundSessionIdentifier
        self.createdAt = createdAt
    }
}

public struct StockpileLocalFilePreparationState: Sendable, Hashable, Equatable {
    public let inspectedByteCount: Int64
    public let securityScopeActive: Bool
    public let isReadable: Bool
    public let headline: String
    public let detail: String

    public init(
        inspectedByteCount: Int64,
        securityScopeActive: Bool,
        isReadable: Bool,
        headline: String,
        detail: String
    ) {
        self.inspectedByteCount = inspectedByteCount
        self.securityScopeActive = securityScopeActive
        self.isReadable = isReadable
        self.headline = headline
        self.detail = detail
    }
}

public struct StockpileByteTransferState: Sendable, Hashable, Equatable {
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public let retryCount: Int
    public let throughputBytesPerSecond: Double?
    public let headline: String
    public let detail: String

    public init(
        bytesTransferred: Int64,
        totalBytes: Int64,
        retryCount: Int,
        throughputBytesPerSecond: Double?,
        headline: String,
        detail: String
    ) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.retryCount = retryCount
        self.throughputBytesPerSecond = throughputBytesPerSecond
        self.headline = headline
        self.detail = detail
    }

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(bytesTransferred) / Double(totalBytes), 0), 1)
    }
}

public struct StockpileQueuedRetryState: Sendable, Hashable, Equatable {
    public let attempt: Int
    public let maxAttempts: Int
    public let nextRetryAt: Date
    public let reason: String
    public let headline: String
    public let detail: String

    public init(
        attempt: Int,
        maxAttempts: Int,
        nextRetryAt: Date,
        reason: String,
        headline: String,
        detail: String
    ) {
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.nextRetryAt = nextRetryAt
        self.reason = reason
        self.headline = headline
        self.detail = detail
    }
}

public struct StockpileServerHandoffState: Sendable, Hashable, Equatable {
    public let serverUploadID: String?
    public let acknowledgedAt: Date?
    public let headline: String
    public let detail: String

    public init(
        serverUploadID: String?,
        acknowledgedAt: Date?,
        headline: String,
        detail: String
    ) {
        self.serverUploadID = serverUploadID
        self.acknowledgedAt = acknowledgedAt
        self.headline = headline
        self.detail = detail
    }
}

public struct StockpileUploadCompletionState: Sendable, Hashable, Equatable {
    public let uploadID: String
    public let serverUploadID: String?
    public let completedAt: Date
    public let serverReceiptID: String
    public let headline: String
    public let detail: String

    public init(
        uploadID: String,
        serverUploadID: String? = nil,
        completedAt: Date,
        serverReceiptID: String,
        headline: String,
        detail: String
    ) {
        self.uploadID = uploadID
        self.serverUploadID = serverUploadID
        self.completedAt = completedAt
        self.serverReceiptID = serverReceiptID
        self.headline = headline
        self.detail = detail
    }
}

public struct StockpileUploadFailureState: Sendable, Hashable, Equatable {
    public let failedAt: Date
    public let reason: String
    public let recoverable: Bool
    public let headline: String
    public let detail: String

    public init(
        failedAt: Date,
        reason: String,
        recoverable: Bool,
        headline: String,
        detail: String
    ) {
        self.failedAt = failedAt
        self.reason = reason
        self.recoverable = recoverable
        self.headline = headline
        self.detail = detail
    }
}

public enum StockpileUploadTaskStage: Sendable, Hashable, Equatable {
    case preparingLocalFile(StockpileLocalFilePreparationState)
    case transferringBytes(StockpileByteTransferState)
    case queuedForRetry(StockpileQueuedRetryState)
    case handingOffToServer(StockpileServerHandoffState)
    case completed(StockpileUploadCompletionState)
    case failed(StockpileUploadFailureState)

    public var headline: String {
        switch self {
        case .preparingLocalFile(let state):
            return state.headline
        case .transferringBytes(let state):
            return state.headline
        case .queuedForRetry(let state):
            return state.headline
        case .handingOffToServer(let state):
            return state.headline
        case .completed(let state):
            return state.headline
        case .failed(let state):
            return state.headline
        }
    }

    public var detail: String {
        switch self {
        case .preparingLocalFile(let state):
            return state.detail
        case .transferringBytes(let state):
            return state.detail
        case .queuedForRetry(let state):
            return state.detail
        case .handingOffToServer(let state):
            return state.detail
        case .completed(let state):
            return state.detail
        case .failed(let state):
            return state.detail
        }
    }

    public var progress: Double {
        switch self {
        case .preparingLocalFile:
            return 0.05
        case .transferringBytes(let state):
            return 0.10 + (state.progress * 0.70)
        case .queuedForRetry:
            return 0.80
        case .handingOffToServer:
            return 0.92
        case .completed:
            return 1.0
        case .failed:
            return 1.0
        }
    }

    public var narrative: String {
        switch self {
        case .preparingLocalFile:
            return "Preparing the local file before network transfer begins."
        case .transferringBytes(let state):
            return "Transferring \(state.bytesTransferred.formatted()) of \(state.totalBytes.formatted()) bytes."
        case .queuedForRetry(let state):
            return "Upload paused after attempt \(state.attempt) of \(state.maxAttempts) and queued for retry."
        case .handingOffToServer:
            return "Byte transfer finished and the server handoff is being finalized."
        case .completed(let state):
            return "Upload finished successfully with server receipt \(state.serverReceiptID)."
        case .failed(let state):
            return "Upload stopped because \(state.reason)."
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed:
            return true
        case .preparingLocalFile, .transferringBytes, .queuedForRetry, .handingOffToServer:
            return false
        }
    }
}

public struct StockpileUploadProgressSnapshot: Sendable, Hashable, Equatable, Identifiable {
    public let taskID: String
    public let stage: StockpileUploadTaskStage
    public let capturedAt: Date

    public var id: String { taskID }

    public init(taskID: String, stage: StockpileUploadTaskStage, capturedAt: Date) {
        self.taskID = taskID
        self.stage = stage
        self.capturedAt = capturedAt
    }
}

public struct StockpileUploadTask: Sendable, Hashable, Equatable, Identifiable {
    public let taskID: String
    public let file: StockpileUploadFileDescriptor
    public let backgroundSessionIdentifier: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let stage: StockpileUploadTaskStage

    public var id: String { taskID }
    public var headline: String { stage.headline }
    public var detail: String { stage.detail }
    public var progress: Double { stage.progress }
    public var narrative: String { stage.narrative }
    public var isTerminal: Bool { stage.isTerminal }

    public init(
        taskID: String,
        file: StockpileUploadFileDescriptor,
        backgroundSessionIdentifier: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        stage: StockpileUploadTaskStage
    ) {
        self.taskID = taskID
        self.file = file
        self.backgroundSessionIdentifier = backgroundSessionIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.stage = stage
    }
}

public protocol StockpileUploadServicing: Sendable {
    func createUploadTask(request: StockpileUploadTaskRequest) async throws -> StockpileUploadTask
    func reattachUploadTask(request: StockpileUploadTaskRestoreRequest) async throws -> StockpileUploadTask?
    func progressSnapshots(for taskID: String) -> AsyncStream<StockpileUploadProgressSnapshot>
    func task(taskID: String) async -> StockpileUploadTask?
    func cancelUpload(taskID: String) async
}
