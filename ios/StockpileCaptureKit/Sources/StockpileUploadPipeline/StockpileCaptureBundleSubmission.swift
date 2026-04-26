import Foundation

/// Receipt returned by the v2 backend after a `.stockpilecapture` bundle is accepted.
///
/// The shape mirrors the JSON that `POST /api/v2/captures` returns from the lean
/// LiDAR backend at `stockpile-lidar-backend/`: camelCase fields, a string status,
/// and an optional `resultId` that is populated when the synchronous quick-estimate
/// pipeline finishes during the request handler.
public struct StockpileCaptureBundleSubmissionReceipt: Sendable, Equatable, Decodable {
    public let captureID: String
    public let jobID: String
    public let resultID: String?
    public let status: String

    public init(
        captureID: String,
        jobID: String,
        resultID: String? = nil,
        status: String
    ) {
        self.captureID = captureID
        self.jobID = jobID
        self.resultID = resultID
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case captureID = "captureId"
        case jobID = "jobId"
        case resultID = "resultId"
        case status
    }
}

/// Errors raised by the v2 capture bundle submission flow.
public enum StockpileCaptureBundleSubmissionError: Error, LocalizedError, Sendable {
    case bundleFileMissing(URL)
    case bundleFileEmpty(URL)
    case multipartBodyBuildFailed(String)
    case nonHTTPResponse
    case httpError(statusCode: Int, body: String)
    case responseDecodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .bundleFileMissing(url):
            return "Capture bundle file is missing at \(url.path)."
        case let .bundleFileEmpty(url):
            return "Capture bundle file is empty at \(url.path)."
        case let .multipartBodyBuildFailed(detail):
            return "Failed to build multipart body: \(detail)"
        case .nonHTTPResponse:
            return "Capture bundle submission received a non-HTTP response."
        case let .httpError(statusCode, _):
            return "Capture bundle submission failed with HTTP \(statusCode)."
        case let .responseDecodeFailed(detail):
            return "Failed to decode capture bundle submission response: \(detail)"
        }
    }
}

/// Configuration for an instance of `URLSessionCaptureBundleSubmitter`.
///
/// The endpoint URL should already include the `/api/v2/captures` path so callers
/// only have to set it once per environment.
public struct StockpileCaptureBundleSubmissionConfiguration: Sendable, Equatable {
    public let endpointURL: URL
    public let timeoutInterval: TimeInterval
    public let additionalHeaders: [String: String]

    public init(
        endpointURL: URL,
        timeoutInterval: TimeInterval = 120,
        additionalHeaders: [String: String] = [:]
    ) {
        self.endpointURL = endpointURL
        self.timeoutInterval = timeoutInterval
        self.additionalHeaders = additionalHeaders
    }
}

/// Public protocol so capture flow code can depend on this abstraction without
/// caring whether it is talking to a live backend or a mock in tests.
public protocol StockpileCaptureBundleSubmitting: Sendable {
    func submitCaptureBundle(
        at fileURL: URL,
        captureID: String,
        siteID: String,
        materialCode: String
    ) async throws -> StockpileCaptureBundleSubmissionReceipt
}

/// Test seam over `URLSession.upload(for:fromFile:)` so production code uses
/// real `URLSession` and tests can stub the response.
public protocol StockpileCaptureBundleSubmissionSessioning: Sendable {
    func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse)
}

public struct URLSessionCaptureBundleSubmissionSession: StockpileCaptureBundleSubmissionSessioning {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, fromFile: fileURL)
    }
}

/// `URLSession`-backed submitter that POSTs a `.stockpilecapture` ZIP to the
/// new lean LiDAR backend's `/api/v2/captures` endpoint as multipart/form-data.
///
/// The bundle file is streamed into a temp multipart body (no in-memory copy of
/// the whole ZIP) and that temp body is then uploaded with
/// `URLSession.upload(for:fromFile:)` so background and large bundle uploads
/// stay efficient.
public struct URLSessionCaptureBundleSubmitter: StockpileCaptureBundleSubmitting {
    private let configuration: StockpileCaptureBundleSubmissionConfiguration
    private let session: any StockpileCaptureBundleSubmissionSessioning

    public init(
        configuration: StockpileCaptureBundleSubmissionConfiguration,
        session: any StockpileCaptureBundleSubmissionSessioning = URLSessionCaptureBundleSubmissionSession()
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func submitCaptureBundle(
        at fileURL: URL,
        captureID: String,
        siteID: String,
        materialCode: String
    ) async throws -> StockpileCaptureBundleSubmissionReceipt {
        try Self.validateBundleFile(at: fileURL)

        let boundary = "stockpile-bundle-\(UUID().uuidString)"
        let multipartBodyURL = try Self.writeMultipartBody(
            bundleURL: fileURL,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: multipartBodyURL) }

        let request = makeRequest(
            boundary: boundary,
            captureID: captureID,
            siteID: siteID,
            materialCode: materialCode
        )

        let (data, response) = try await session.upload(for: request, fromFile: multipartBodyURL)
        guard let http = response as? HTTPURLResponse else {
            throw StockpileCaptureBundleSubmissionError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw StockpileCaptureBundleSubmissionError.httpError(
                statusCode: http.statusCode,
                body: bodyText
            )
        }

        do {
            return try JSONDecoder().decode(
                StockpileCaptureBundleSubmissionReceipt.self,
                from: data
            )
        } catch {
            throw StockpileCaptureBundleSubmissionError.responseDecodeFailed("\(error)")
        }
    }

    /// Internal-but-testable: build the v2 `URLRequest` (no body — body is streamed
    /// from a separate file into `URLSession.upload(for:fromFile:)`).
    func makeRequest(
        boundary: String,
        captureID: String,
        siteID: String,
        materialCode: String
    ) -> URLRequest {
        var request = URLRequest(
            url: configuration.endpointURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.timeoutInterval
        )
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("markerless", forHTTPHeaderField: "X-Stockpile-Capture-Mode")
        request.setValue(captureID, forHTTPHeaderField: "X-Stockpile-Capture-ID")
        request.setValue(siteID, forHTTPHeaderField: "X-Stockpile-Site-ID")
        request.setValue(materialCode, forHTTPHeaderField: "X-Stockpile-Material-Code")
        for (key, value) in configuration.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    static func validateBundleFile(at fileURL: URL) throws {
        let reachable = (try? fileURL.checkResourceIsReachable()) ?? false
        if !reachable {
            throw StockpileCaptureBundleSubmissionError.bundleFileMissing(fileURL)
        }
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if fileSize <= 0 {
            throw StockpileCaptureBundleSubmissionError.bundleFileEmpty(fileURL)
        }
    }

    /// Stream the bundle file into a multipart/form-data body file on disk so the
    /// actual upload can use `URLSession.upload(for:fromFile:)` without loading
    /// the entire ZIP into memory.
    static func writeMultipartBody(bundleURL: URL, boundary: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let bodyURL = tempDir.appendingPathComponent(
            "stockpile-capture-body-\(UUID().uuidString).tmp"
        )
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw StockpileCaptureBundleSubmissionError.multipartBodyBuildFailed(
                "could not create multipart body file at \(bodyURL.path)"
            )
        }

        let writer: FileHandle
        do {
            writer = try FileHandle(forWritingTo: bodyURL)
        } catch {
            throw StockpileCaptureBundleSubmissionError.multipartBodyBuildFailed(
                "could not open multipart body for writing: \(error)"
            )
        }
        defer { try? writer.close() }

        let filename = bundleURL.lastPathComponent
        let preface = """
        --\(boundary)\r
        Content-Disposition: form-data; name="bundle"; filename="\(filename)"\r
        Content-Type: application/zip\r
        \r

        """
        writer.write(Data(preface.utf8))

        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: bundleURL)
        } catch {
            throw StockpileCaptureBundleSubmissionError.multipartBodyBuildFailed(
                "could not open bundle for reading: \(error)"
            )
        }
        defer { try? reader.close() }

        while true {
            let chunk = reader.readData(ofLength: 1 * 1024 * 1024)
            if chunk.isEmpty { break }
            writer.write(chunk)
        }

        writer.write(Data("\r\n--\(boundary)--\r\n".utf8))
        return bodyURL
    }
}

/// In-memory mock used by tests and local previews. Returns a fixed receipt or
/// throws a fixed error.
public struct MockStockpileCaptureBundleSubmitter: StockpileCaptureBundleSubmitting {
    public enum Behaviour: Sendable {
        case success(StockpileCaptureBundleSubmissionReceipt)
        case failure(StockpileCaptureBundleSubmissionError)
    }

    public let behaviour: Behaviour

    public init(behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    public init(receipt: StockpileCaptureBundleSubmissionReceipt) {
        self.behaviour = .success(receipt)
    }

    public func submitCaptureBundle(
        at fileURL: URL,
        captureID: String,
        siteID: String,
        materialCode: String
    ) async throws -> StockpileCaptureBundleSubmissionReceipt {
        switch behaviour {
        case let .success(receipt):
            return receipt
        case let .failure(error):
            throw error
        }
    }
}
