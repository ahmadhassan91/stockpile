import Foundation

public struct StockpileLiveMobileAPIConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let pathPrefix: String
    public let defaultHeaders: [String: String]
    public let timeoutInterval: TimeInterval

    public init(
        baseURL: URL,
        pathPrefix: String = "api/mobile",
        defaultHeaders: [String: String] = [:],
        timeoutInterval: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.pathPrefix = Self.normalizedPathPrefix(pathPrefix)
        self.defaultHeaders = defaultHeaders
        self.timeoutInterval = max(timeoutInterval, 1)
    }

    public static func environment(
        processInfo: ProcessInfo = .processInfo,
        fallbackBaseURL: URL = URL(string: "https://api.stockpile.theclustox.com")!
    ) -> StockpileLiveMobileAPIConfiguration {
        environment(
            environment: processInfo.environment,
            fallbackBaseURL: fallbackBaseURL
        )
    }

    public static func environment(
        environment: [String: String],
        fallbackBaseURL: URL = URL(string: "https://api.stockpile.theclustox.com")!
    ) -> StockpileLiveMobileAPIConfiguration {
        let rawBaseURL = environment.nonEmptyValue(for: "STOCKPILE_MOBILE_API_BASE_URL")
            ?? environment.nonEmptyValue(for: "STOCKPILE_API_BASE_URL")
        let baseURL = rawBaseURL.flatMap(URL.init(string:)) ?? fallbackBaseURL
        let explicitPathPrefix = environment.nonEmptyValue(for: "STOCKPILE_MOBILE_API_PATH_PREFIX")
        let timeoutInterval = environment.nonEmptyDouble(for: "STOCKPILE_MOBILE_API_TIMEOUT_SECONDS") ?? 30

        var defaultHeaders: [String: String] = [:]

        if let bearerToken = environment.nonEmptyValue(for: "STOCKPILE_MOBILE_API_BEARER_TOKEN")
            ?? environment.nonEmptyValue(for: "STOCKPILE_API_BEARER_TOKEN") {
            defaultHeaders["Authorization"] = "Bearer \(bearerToken)"
        }

        if let apiKey = environment.nonEmptyValue(for: "STOCKPILE_MOBILE_API_KEY")
            ?? environment.nonEmptyValue(for: "STOCKPILE_API_KEY") {
            defaultHeaders["x-api-key"] = apiKey
        }

        if let userAgent = environment.nonEmptyValue(for: "STOCKPILE_MOBILE_API_USER_AGENT")
            ?? environment.nonEmptyValue(for: "STOCKPILE_CLIENT_BUILD") {
            defaultHeaders["User-Agent"] = userAgent
        }

        return StockpileLiveMobileAPIConfiguration(
            baseURL: baseURL,
            pathPrefix: explicitPathPrefix ?? defaultPathPrefix(for: baseURL),
            defaultHeaders: defaultHeaders,
            timeoutInterval: timeoutInterval
        )
    }

    var pathPrefixComponents: [String] {
        let prefixComponents = Self.pathComponents(from: pathPrefix)
        guard !prefixComponents.isEmpty else {
            return []
        }

        let basePathComponents = Self.pathComponents(from: baseURL.path)
        let overlapCount = Self.overlapCount(
            betweenSuffixOf: basePathComponents,
            andPrefixOf: prefixComponents
        )

        return Array(prefixComponents.dropFirst(overlapCount))
    }

    private static func normalizedPathPrefix(_ prefix: String) -> String {
        prefix
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func defaultPathPrefix(for baseURL: URL) -> String {
        let normalizedPath = baseURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        if normalizedPath.hasSuffix("api/mobile") {
            return ""
        }

        return "api/mobile"
    }

    private static func pathComponents(from path: String) -> [String] {
        path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)
    }

    private static func overlapCount(
        betweenSuffixOf baseComponents: [String],
        andPrefixOf prefixComponents: [String]
    ) -> Int {
        let maxOverlap = min(baseComponents.count, prefixComponents.count)
        guard maxOverlap > 0 else {
            return 0
        }

        for candidate in stride(from: maxOverlap, through: 1, by: -1) {
            let baseSuffix = baseComponents.suffix(candidate)
            let prefixHead = prefixComponents.prefix(candidate)
            let isMatch = zip(baseSuffix, prefixHead).allSatisfy { baseComponent, prefixComponent in
                baseComponent.caseInsensitiveCompare(prefixComponent) == .orderedSame
            }

            if isMatch {
                return candidate
            }
        }

        return 0
    }
}

public actor LiveStockpileMobileAPIService: StockpileMobileAPIServicing {
    private let configuration: StockpileLiveMobileAPIConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: StockpileLiveMobileAPIConfiguration,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        let sessionConfiguration = sessionConfiguration
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeoutInterval
        sessionConfiguration.timeoutIntervalForResource = max(configuration.timeoutInterval * 2, configuration.timeoutInterval)

        self.configuration = configuration
        self.session = URLSession(configuration: sessionConfiguration)
        self.encoder = Self.makeJSONEncoder()
        self.decoder = Self.makeJSONDecoder()
    }

    public init(
        processInfo: ProcessInfo = .processInfo,
        fallbackBaseURL: URL = URL(string: "https://api.stockpile.theclustox.com")!,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.init(
            configuration: .environment(
                processInfo: processInfo,
                fallbackBaseURL: fallbackBaseURL
            ),
            sessionConfiguration: sessionConfiguration
        )
    }

    public init(
        environment: [String: String],
        fallbackBaseURL: URL = URL(string: "https://api.stockpile.theclustox.com")!,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.init(
            configuration: .environment(
                environment: environment,
                fallbackBaseURL: fallbackBaseURL
            ),
            sessionConfiguration: sessionConfiguration
        )
    }

    public func createCaptureSession(request: StockpileCaptureSessionCreateRequest) async throws -> StockpileCaptureSession {
        try await post(
            pathComponents: ["capture-sessions"],
            body: request,
            decode: StockpileCaptureSession.self
        )
    }

    public func createUploadAuthorization(request: StockpileUploadRequest) async throws -> StockpileUploadAuthorization {
        try await post(
            pathComponents: ["uploads"],
            body: request,
            decode: StockpileUploadAuthorization.self,
            notFound: .sessionNotFound(request.sessionID)
        )
    }

    public func fetchProcessingJob(jobID: String) async throws -> StockpileProcessingJobStatus {
        try await get(
            pathComponents: ["jobs", jobID],
            decode: StockpileProcessingJobStatus.self,
            notFound: .jobNotFound(jobID)
        )
    }

    public func fetchResult(runID: String) async throws -> StockpileResultPayload {
        let request = try makeRequest(
            method: "GET",
            pathComponents: ["results", runID],
            body: nil
        )

        let (data, httpResponse) = try await performRequest(request)
        switch httpResponse.statusCode {
        case 200:
            return try decodeResponse(StockpileResultPayload.self, from: data)
        case 202, 404:
            throw StockpileMobileAPIError.resultNotFound(runID)
        case 409:
            if Self.resultPollEnvelope(from: data)?.indicatesMissingResult == true {
                throw StockpileMobileAPIError.resultNotFound(runID)
            }

            fallthrough
        default:
            throw Self.mapHTTPError(
                statusCode: httpResponse.statusCode,
                data: data,
                headers: httpResponse.allHeaderFields,
                notFound: .resultNotFound(runID)
            )
        }
    }

    public func fetchRecentResults(
        limit: Int,
        siteID: String? = nil,
        sessionID: String? = nil
    ) async throws -> [StockpileResultPayload] {
        let safeLimit = max(0, limit)
        guard safeLimit > 0 else {
            return []
        }

        var queryItems = [
            URLQueryItem(name: "limit", value: String(safeLimit)),
        ]

        if let siteID,
           siteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            queryItems.append(URLQueryItem(name: "siteId", value: siteID))
        }

        if let sessionID,
           sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            queryItems.append(URLQueryItem(name: "sessionId", value: sessionID))
        }

        return try await get(
            pathComponents: ["runs", "recent"],
            queryItems: queryItems,
            decode: [StockpileResultPayload].self
        )
    }

    private func get<Response: Decodable>(
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        decode responseType: Response.Type,
        notFound: StockpileMobileAPIError? = nil
    ) async throws -> Response {
        let request = try makeRequest(
            method: "GET",
            pathComponents: pathComponents,
            queryItems: queryItems,
            body: nil
        )

        return try await perform(
            request,
            decode: responseType,
            notFound: notFound
        )
    }

    private func post<RequestBody: Encodable, Response: Decodable>(
        pathComponents: [String],
        body: RequestBody,
        decode responseType: Response.Type,
        notFound: StockpileMobileAPIError? = nil
    ) async throws -> Response {
        let bodyData = try encode(body)
        let request = try makeRequest(
            method: "POST",
            pathComponents: pathComponents,
            body: bodyData
        )

        return try await perform(
            request,
            decode: responseType,
            notFound: notFound
        )
    }

    private func encode<RequestBody: Encodable>(_ body: RequestBody) throws -> Data {
        do {
            return try encoder.encode(body)
        } catch {
            throw StockpileMobileAPIError.encodingFailure(Self.describe(error))
        }
    }

    private func makeRequest(
        method: String,
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        body: Data?
    ) throws -> URLRequest {
        let url = try url(for: pathComponents, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = configuration.timeoutInterval

        for (header, value) in configuration.defaultHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        if let body {
            request.httpBody = body

            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }

        return request
    }

    private func url(
        for pathComponents: [String],
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        var resolvedURL = configuration.baseURL
        let components = configuration.pathPrefixComponents + pathComponents

        for component in components where !component.isEmpty {
            resolvedURL = resolvedURL.appending(path: component)
        }

        guard resolvedURL.scheme != nil else {
            throw StockpileMobileAPIError.invalidRequestURL(components.joined(separator: "/"))
        }

        guard queryItems.isEmpty == false else {
            return resolvedURL
        }

        guard var urlComponents = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false) else {
            throw StockpileMobileAPIError.invalidRequestURL(components.joined(separator: "/"))
        }
        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else {
            throw StockpileMobileAPIError.invalidRequestURL(components.joined(separator: "/"))
        }

        return url
    }

    private func perform<Response: Decodable>(
        _ request: URLRequest,
        decode responseType: Response.Type,
        notFound: StockpileMobileAPIError? = nil
    ) async throws -> Response {
        let (data, httpResponse) = try await performRequest(request)

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.mapHTTPError(
                statusCode: httpResponse.statusCode,
                data: data,
                headers: httpResponse.allHeaderFields,
                notFound: notFound
            )
        }

        return try decodeResponse(responseType, from: data)
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch let error as StockpileMobileAPIError {
            throw error
        } catch let error as URLError {
            throw StockpileMobileAPIError.transportFailure(error.localizedDescription)
        } catch {
            throw StockpileMobileAPIError.transportFailure(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StockpileMobileAPIError.invalidResponse
        }

        return (data, httpResponse)
    }

    private func decodeResponse<Response: Decodable>(
        _ responseType: Response.Type,
        from data: Data
    ) throws -> Response {
        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            throw StockpileMobileAPIError.decodingFailure(Self.describe(error))
        }
    }

    private static func mapHTTPError(
        statusCode: Int,
        data: Data,
        headers: [AnyHashable: Any],
        notFound: StockpileMobileAPIError?
    ) -> StockpileMobileAPIError {
        let message = serverMessage(from: data)

        switch statusCode {
        case 401:
            return .authenticationRequired(message)
        case 403:
            return .forbidden(message)
        case 404:
            return notFound ?? .requestFailed(statusCode: statusCode, message: message)
        case 409, 422:
            return .validationFailed(message)
        case 429:
            return .rateLimited(
                retryAfter: retryAfter(from: headers),
                message: message
            )
        case 500...599:
            return .serverError(statusCode: statusCode, message: message)
        default:
            return .requestFailed(statusCode: statusCode, message: message)
        }
    }

    private static func serverMessage(from data: Data) -> String? {
        guard !data.isEmpty else {
            return nil
        }

        if let envelope = try? makeJSONDecoder().decode(StockpileAPIErrorEnvelope.self, from: data),
           let message = envelope.bestMessage {
            return message
        }

        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else {
            return nil
        }

        return text
    }

    private static func retryAfter(from headers: [AnyHashable: Any]) -> TimeInterval? {
        guard let rawValue = headers.firstHeaderValue(named: "Retry-After") else {
            return nil
        }

        if let seconds = TimeInterval(rawValue) {
            return seconds
        }

        return nil
    }

    private static func resultPollEnvelope(from data: Data) -> StockpileResultPollEnvelope? {
        try? makeJSONDecoder().decode(StockpileResultPollEnvelope.self, from: data)
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601DateFormatter().string(from: date))
        }
        return encoder
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)

            if let date = iso8601DateFormatter(withFractionalSeconds: true).date(from: rawValue)
                ?? iso8601DateFormatter().date(from: rawValue) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported ISO-8601 date string: \(rawValue)"
            )
        }
        return decoder
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let decodingError as DecodingError:
            switch decodingError {
            case let .dataCorrupted(context):
                return context.debugDescription
            case let .keyNotFound(key, context):
                return "Missing key \(key.stringValue): \(context.debugDescription)"
            case let .typeMismatch(type, context):
                return "Type mismatch for \(type): \(context.debugDescription)"
            case let .valueNotFound(type, context):
                return "Missing value for \(type): \(context.debugDescription)"
            @unknown default:
                return decodingError.localizedDescription
            }
        default:
            return error.localizedDescription
        }
    }

    private static func iso8601DateFormatter(withFractionalSeconds: Bool = false) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = withFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

private struct StockpileAPIErrorEnvelope: Decodable {
    let code: String?
    let error: String?
    let message: String?
    let detail: String?

    var bestMessage: String? {
        [message, detail, error, code]
            .compactMap { value in
                value?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first(where: { !$0.isEmpty })
    }
}

private struct StockpileResultPollEnvelope: Decodable {
    let state: String?

    var indicatesMissingResult: Bool {
        guard let state = state?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              state.isEmpty == false else {
            return false
        }

        return state == "pending" || state == "terminal_missing_result"
    }
}

private extension [String: String] {
    func nonEmptyValue(for key: String) -> String? {
        guard let value = self[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }

        return value
    }

    func nonEmptyDouble(for key: String) -> Double? {
        guard let value = nonEmptyValue(for: key) else {
            return nil
        }

        return Double(value)
    }
}

private extension [AnyHashable: Any] {
    func firstHeaderValue(named headerName: String) -> String? {
        first { key, _ in
            String(describing: key).caseInsensitiveCompare(headerName) == .orderedSame
        }
        .flatMap { _, value in
            value as? String
        }
    }
}
