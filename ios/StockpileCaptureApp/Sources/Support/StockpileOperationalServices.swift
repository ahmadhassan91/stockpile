import Foundation
import StockpileMobileAPI
import StockpileUploadPipeline

private enum StockpileOperationalServicesError: LocalizedError {
    case missingUploadAuthorization(String)
    case expiredUploadAuthorization(String, Date)
    case missingCaptureFileConfiguration
    case captureFileMustBeLocal(URL)
    case captureFileNotFound(URL)
    case captureFileAttributesUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case let .missingUploadAuthorization(uploadID):
            return "Upload authorization \(uploadID) was not available when the transfer started."
        case let .expiredUploadAuthorization(uploadID, expiresAt):
            return "Upload authorization \(uploadID) expired at \(expiresAt.formatted(date: .omitted, time: .standard)). Request a new upload slot before retrying."
        case .missingCaptureFileConfiguration:
            return "No fallback capture file is configured. The app expected a live recorded walkaround or an explicit local backup file."
        case let .captureFileMustBeLocal(fileURL):
            return "The configured fallback capture file must be a local file URL: \(fileURL.absoluteString)"
        case let .captureFileNotFound(fileURL):
            return "The configured fallback capture file could not be found at \(fileURL.path)."
        case let .captureFileAttributesUnavailable(fileURL):
            return "The fallback capture file metadata could not be read at \(fileURL.path)."
        }
    }
}

actor StockpileOperationalUploadAuthorizationStore {
    private var authorizations: [String: StockpileUploadAuthorization] = [:]

    func store(_ authorization: StockpileUploadAuthorization) {
        authorizations[authorization.uploadID] = authorization
    }

    func authorization(for uploadID: String) -> StockpileUploadAuthorization? {
        authorizations[uploadID]
    }
}

actor StockpileOperationalMobileAPIService: StockpileMobileAPIServicing {
    private let liveService: LiveStockpileMobileAPIService
    private let authorizationStore: StockpileOperationalUploadAuthorizationStore

    init(
        configuration: StockpileLiveMobileAPIConfiguration,
        authorizationStore: StockpileOperationalUploadAuthorizationStore,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.authorizationStore = authorizationStore
        self.liveService = LiveStockpileMobileAPIService(
            configuration: configuration,
            sessionConfiguration: sessionConfiguration
        )
    }

    func createCaptureSession(request: StockpileCaptureSessionCreateRequest) async throws -> StockpileCaptureSession {
        try await liveService.createCaptureSession(request: request)
    }

    func createUploadAuthorization(request: StockpileUploadRequest) async throws -> StockpileUploadAuthorization {
        let authorization = try await liveService.createUploadAuthorization(request: request)
        await authorizationStore.store(authorization)
        return authorization
    }

    func fetchProcessingJob(jobID: String) async throws -> StockpileProcessingJobStatus {
        try await liveService.fetchProcessingJob(jobID: jobID)
    }

    func fetchResult(runID: String) async throws -> StockpileResultPayload {
        try await liveService.fetchResult(runID: runID)
    }

    func fetchRecentResults(
        limit: Int,
        siteID: String?,
        sessionID: String?
    ) async throws -> [StockpileResultPayload] {
        try await liveService.fetchRecentResults(
            limit: limit,
            siteID: siteID,
            sessionID: sessionID
        )
    }
}

actor StockpileOperationalUploadService: StockpileUploadServicing {
    private static let restorationPlaceholderUploadURL = URL(string: "https://stockpile.invalid/uploads")!
    private let authorizationStore: StockpileOperationalUploadAuthorizationStore
    private let defaultHeaders: [String: String]
    private let now: @Sendable () -> Date
    private let defaultTimeoutInterval: TimeInterval
    private let sharedContainerIdentifier: String?
    private let allowsCellularAccess: Bool
    private let waitsForConnectivity: Bool
    private let isDiscretionary: Bool
    private var servicesByTaskID: [String: URLSessionStockpileUploadService] = [:]

    init(
        authorizationStore: StockpileOperationalUploadAuthorizationStore,
        defaultHeaders: [String: String] = [:],
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authorizationStore = authorizationStore
        self.defaultHeaders = Self.sanitizedHeaders(defaultHeaders)
        self.now = now
        let sessionConfiguration = session.configuration
        defaultTimeoutInterval = max(sessionConfiguration.timeoutIntervalForRequest, 600)
        sharedContainerIdentifier = sessionConfiguration.sharedContainerIdentifier
        allowsCellularAccess = sessionConfiguration.allowsCellularAccess
        waitsForConnectivity = sessionConfiguration.waitsForConnectivity
        isDiscretionary = sessionConfiguration.isDiscretionary
    }

    func createUploadTask(request: StockpileUploadTaskRequest) async throws -> StockpileUploadTask {
        let authorization = try await authorization(for: request.uploadID)
        try validateAuthorization(authorization)

        let resolvedRequest = StockpileUploadTaskRequest(
            uploadID: request.uploadID,
            file: request.file,
            backgroundSessionIdentifier: makeBackgroundSessionIdentifier(
                baseIdentifier: request.backgroundSessionIdentifier,
                uploadID: request.uploadID
            ),
            createdAt: request.createdAt
        )
        let liveService = URLSessionStockpileUploadService(
            configuration: URLSessionStockpileUploadServiceConfiguration(
                uploadURL: authorization.uploadURL,
                httpMethod: resolvedHTTPMethod(from: authorization.httpMethod),
                additionalHeaders: mergedHeaders(uploadHeaders: authorization.headers),
                timeoutInterval: resolvedTimeoutInterval(for: authorization),
                sharedContainerIdentifier: sharedContainerIdentifier,
                allowsCellularAccess: allowsCellularAccess,
                waitsForConnectivity: waitsForConnectivity,
                isDiscretionary: isDiscretionary
            ),
            now: now
        )

        let task = try await liveService.createUploadTask(request: resolvedRequest)
        servicesByTaskID[task.taskID] = liveService
        return task
    }

    func reattachUploadTask(request: StockpileUploadTaskRestoreRequest) async throws -> StockpileUploadTask? {
        if let existingService = servicesByTaskID[request.taskID] {
            if let existingTask = await existingService.task(taskID: request.taskID) {
                return existingTask
            }
        }

        let liveService = URLSessionStockpileUploadService(
            configuration: URLSessionStockpileUploadServiceConfiguration(
                uploadURL: Self.restorationPlaceholderUploadURL,
                httpMethod: "PUT",
                additionalHeaders: defaultHeaders,
                timeoutInterval: defaultTimeoutInterval,
                sharedContainerIdentifier: sharedContainerIdentifier,
                allowsCellularAccess: allowsCellularAccess,
                waitsForConnectivity: waitsForConnectivity,
                isDiscretionary: isDiscretionary
            ),
            now: now
        )

        let restoredTask = try await liveService.reattachUploadTask(request: request)
        if restoredTask != nil {
            servicesByTaskID[request.taskID] = liveService
        }
        return restoredTask
    }

    nonisolated func progressSnapshots(for taskID: String) -> AsyncStream<StockpileUploadProgressSnapshot> {
        AsyncStream { continuation in
            let bridge = Task {
                guard let service = await self.service(for: taskID) else {
                    continuation.finish()
                    return
                }

                for await snapshot in service.progressSnapshots(for: taskID) {
                    if Task.isCancelled {
                        break
                    }

                    continuation.yield(snapshot)
                }

                continuation.finish()
            }
            continuation.onTermination = { _ in
                bridge.cancel()
            }
        }
    }

    func task(taskID: String) async -> StockpileUploadTask? {
        guard let service = servicesByTaskID[taskID] else {
            return nil
        }

        return await service.task(taskID: taskID)
    }

    func cancelUpload(taskID: String) async {
        guard let service = servicesByTaskID[taskID] else {
            return
        }

        await service.cancelUpload(taskID: taskID)
    }

    private func service(for taskID: String) -> URLSessionStockpileUploadService? {
        servicesByTaskID[taskID]
    }

    private func authorization(for uploadID: String) async throws -> StockpileUploadAuthorization {
        guard let authorization = await authorizationStore.authorization(for: uploadID) else {
            throw StockpileOperationalServicesError.missingUploadAuthorization(uploadID)
        }

        return authorization
    }

    private func validateAuthorization(_ authorization: StockpileUploadAuthorization) throws {
        if authorization.expiresAt <= now() {
            throw StockpileOperationalServicesError.expiredUploadAuthorization(
                authorization.uploadID,
                authorization.expiresAt
            )
        }
    }

    private func resolvedHTTPMethod(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "PUT" : trimmed
    }

    private static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { partialResult, entry in
            let header = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard header.isEmpty == false, value.isEmpty == false else {
                return
            }

            partialResult[header] = value
        }
    }

    private func mergedHeaders(uploadHeaders: [String: String]) -> [String: String] {
        defaultHeaders.merging(Self.sanitizedHeaders(uploadHeaders)) { _, uploadValue in
            uploadValue
        }
    }

    private func resolvedTimeoutInterval(for authorization: StockpileUploadAuthorization) -> TimeInterval {
        let secondsUntilExpiration = authorization.expiresAt.timeIntervalSince(now())
        guard secondsUntilExpiration.isFinite, secondsUntilExpiration > 0 else {
            return defaultTimeoutInterval
        }

        return min(defaultTimeoutInterval, max(secondsUntilExpiration, 15))
    }

    private func makeBackgroundSessionIdentifier(
        baseIdentifier: String?,
        uploadID: String
    ) -> String? {
        guard let baseIdentifier = baseIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              baseIdentifier.isEmpty == false else {
            return nil
        }

        let suffix = uploadID.unicodeScalars
            .map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
            }
        let sanitizedSuffix = String(suffix).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard sanitizedSuffix.isEmpty == false else {
            return baseIdentifier
        }

        return "\(baseIdentifier).\(sanitizedSuffix.prefix(48))"
    }
}

extension StockpileOperationalUploadConfiguration {
    func makeFileDescriptor() throws -> StockpileUploadFileDescriptor {
        guard let fileURL else {
            throw StockpileOperationalServicesError.missingCaptureFileConfiguration
        }

        guard fileURL.isFileURL else {
            throw StockpileOperationalServicesError.captureFileMustBeLocal(fileURL)
        }

        let filePath = fileURL.path
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw StockpileOperationalServicesError.captureFileNotFound(fileURL)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
        guard let fileSize = (attributes[.size] as? NSNumber)?.int64Value else {
            throw StockpileOperationalServicesError.captureFileAttributesUnavailable(fileURL)
        }

        return StockpileUploadFileDescriptor(
            fileURL: fileURL,
            fileName: fileURL.lastPathComponent,
            byteCount: byteCountOverride ?? fileSize,
            contentType: contentType,
            checksumSHA256: checksumSHA256
        )
    }
}
