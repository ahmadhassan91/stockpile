import Foundation

public actor MockStockpileUploadService: StockpileUploadServicing {
    private struct StreamState {
        var snapshots: [StockpileUploadProgressSnapshot]
        var continuations: [AsyncStream<StockpileUploadProgressSnapshot>.Continuation]
    }

    private var taskCounter = 0
    private var tasks: [String: StockpileUploadTask] = [:]
    private var streamStates: [String: StreamState] = [:]
    private let now: @Sendable () -> Date
    private let queuedScenarios: [StockpileUploadTaskStage]
    private var scenarioIndex = 0

    public init(
        queuedScenarios: [StockpileUploadTaskStage] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.queuedScenarios = queuedScenarios
        self.now = now
    }

    public func createUploadTask(request: StockpileUploadTaskRequest) async throws -> StockpileUploadTask {
        taskCounter += 1
        let createdAt = request.createdAt
        let taskID = request.uploadID.isEmpty ? Self.makeID(prefix: "upload_task", number: taskCounter) : request.uploadID
        let initialStage = StockpileUploadTaskStage.preparingLocalFile(
            StockpileLocalFilePreparationState(
                inspectedByteCount: request.file.byteCount,
                securityScopeActive: request.file.fileURL.isFileURL,
                isReadable: true,
                headline: "Preparing local file",
                detail: "Validating file access and size before background transfer starts."
            )
        )

        let task = StockpileUploadTask(
            taskID: taskID,
            file: request.file,
            backgroundSessionIdentifier: request.backgroundSessionIdentifier,
            createdAt: createdAt,
            updatedAt: createdAt,
            stage: initialStage
        )
        tasks[taskID] = task
        streamStates[taskID] = StreamState(snapshots: [StockpileUploadProgressSnapshot(taskID: taskID, stage: initialStage, capturedAt: createdAt)], continuations: [])
        return task
    }

    public func reattachUploadTask(request: StockpileUploadTaskRestoreRequest) async throws -> StockpileUploadTask? {
        if let existingTask = tasks[request.taskID] {
            return existingTask
        }

        let restoredStage = StockpileUploadTaskStage.transferringBytes(
            StockpileByteTransferState(
                bytesTransferred: 0,
                totalBytes: max(request.file.byteCount, 1),
                retryCount: 1,
                throughputBytesPerSecond: nil,
                headline: "Resuming upload",
                detail: "The app reattached the background upload after relaunch."
            )
        )
        let restoredTask = StockpileUploadTask(
            taskID: request.taskID,
            file: request.file,
            backgroundSessionIdentifier: request.backgroundSessionIdentifier,
            createdAt: request.createdAt,
            updatedAt: now(),
            stage: restoredStage
        )
        tasks[request.taskID] = restoredTask
        streamStates[request.taskID] = StreamState(
            snapshots: [StockpileUploadProgressSnapshot(taskID: request.taskID, stage: restoredStage, capturedAt: now())],
            continuations: []
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
        guard var task = tasks[taskID] else { return }
        let failedStage = StockpileUploadTaskStage.failed(
            StockpileUploadFailureState(
                failedAt: now(),
                reason: "Cancelled by operator",
                recoverable: true,
                headline: "Upload cancelled",
                detail: "The background upload was cancelled before the server handoff completed."
            )
        )
        task = StockpileUploadTask(
            taskID: task.taskID,
            file: task.file,
            backgroundSessionIdentifier: task.backgroundSessionIdentifier,
            createdAt: task.createdAt,
            updatedAt: now(),
            stage: failedStage
        )
        tasks[taskID] = task
        emit(taskID: taskID, stage: failedStage)
        finish(taskID: taskID)
    }

    public func emitNextSnapshot(for taskID: String) async {
        guard var task = tasks[taskID] else { return }
        let stage = nextStage(for: task)
        task = StockpileUploadTask(
            taskID: task.taskID,
            file: task.file,
            backgroundSessionIdentifier: task.backgroundSessionIdentifier,
            createdAt: task.createdAt,
            updatedAt: now(),
            stage: stage
        )
        tasks[taskID] = task
        emit(taskID: taskID, stage: stage)
        if stage.isTerminal {
            finish(taskID: taskID)
        }
    }

    private func nextStage(for task: StockpileUploadTask) -> StockpileUploadTaskStage {
        if scenarioIndex < queuedScenarios.count {
            let stage = queuedScenarios[scenarioIndex]
            scenarioIndex += 1
            return stage
        }

        switch task.stage {
        case .preparingLocalFile:
            return .transferringBytes(
                StockpileByteTransferState(
                    bytesTransferred: min(task.file.byteCount / 4, max(task.file.byteCount, 1)),
                    totalBytes: max(task.file.byteCount, 1),
                    retryCount: 0,
                    throughputBytesPerSecond: 2_000_000,
                    headline: "Uploading bytes",
                    detail: "The background transfer is now moving the file to the server."
                )
            )
        case .transferringBytes:
            return .handingOffToServer(
                StockpileServerHandoffState(
                    serverUploadID: "server_upload_\(task.taskID)",
                    acknowledgedAt: now(),
                    headline: "Handing off to server",
                    detail: "The final server acknowledgement is in progress."
                )
            )
        case .queuedForRetry(let state):
            return .transferringBytes(
                StockpileByteTransferState(
                    bytesTransferred: max(task.file.byteCount * 3 / 4, 1),
                    totalBytes: max(task.file.byteCount, 1),
                    retryCount: state.attempt,
                    throughputBytesPerSecond: 1_750_000,
                    headline: "Resuming upload",
                    detail: "The transfer resumed after a temporary retry window."
                )
            )
        case .handingOffToServer:
            return .completed(
                StockpileUploadCompletionState(
                    uploadID: task.taskID,
                    serverUploadID: "server_upload_\(task.taskID)",
                    completedAt: now(),
                    serverReceiptID: "receipt_\(task.taskID)",
                    headline: "Upload complete",
                    detail: "The server accepted the background upload and issued a receipt."
                )
            )
        case .completed, .failed:
            return task.stage
        }
    }

    private func registerContinuation(_ continuation: AsyncStream<StockpileUploadProgressSnapshot>.Continuation, taskID: String) {
        let state = streamStates[taskID, default: StreamState(snapshots: [], continuations: [])]
        streamStates[taskID] = StreamState(
            snapshots: state.snapshots,
            continuations: state.continuations + [continuation]
        )
        continuation.onTermination = { _ in }
        for snapshot in state.snapshots {
            continuation.yield(snapshot)
        }
    }

    private func emit(taskID: String, stage: StockpileUploadTaskStage) {
        let snapshot = StockpileUploadProgressSnapshot(taskID: taskID, stage: stage, capturedAt: now())
        var state = streamStates[taskID, default: StreamState(snapshots: [], continuations: [])]
        state.snapshots.append(snapshot)
        streamStates[taskID] = state
        for continuation in state.continuations {
            continuation.yield(snapshot)
        }
    }

    private func finish(taskID: String) {
        guard let state = streamStates[taskID] else { return }
        for continuation in state.continuations {
            continuation.finish()
        }
        streamStates[taskID]?.continuations.removeAll()
    }

    private static func makeID(prefix: String, number: Int) -> String {
        "\(prefix)_\(number)"
    }
}
