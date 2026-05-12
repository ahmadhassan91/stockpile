import Foundation
import StockpileCameraCapture
import StockpileMobileAPI

enum StockpileAppLaunchMode: String, Equatable, Sendable {
    case operational

    init(
        environment: [String: String],
        bundle: Bundle = .main
    ) {
        self = .operational
    }

    static func explicitMode(from environment: [String: String]) -> StockpileAppLaunchMode? {
        explicitMode(
            launchModeValue: environment.stockpileStringValue(for: "STOCKPILE_LAUNCH_MODE")
        )
    }

    static func explicitMode(from bundle: Bundle) -> StockpileAppLaunchMode? {
        explicitMode(
            launchModeValue: bundle.stockpileStringValue(for: "STOCKPILE_LAUNCH_MODE")
        )
    }

    private static func explicitMode(
        launchModeValue: String?
    ) -> StockpileAppLaunchMode? {
        if let rawValue = launchModeValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !rawValue.isEmpty {
            switch rawValue {
            case "operational", "ops", "capture", "live", "production":
                return .operational
            default:
                break
            }
        }

        return nil
    }
}

struct StockpileOperationalAPIConfiguration: Equatable, Sendable {
    let captureSessionsURL: URL
    let uploadAuthorizationURL: URL
    let processingJobsBaseURL: URL
    let resultsBaseURL: URL
    let bearerToken: String?
    let authHeaderName: String?
    let authHeaderValue: String?
    let timeoutInterval: TimeInterval
}

struct StockpileOperationalCaptureConfiguration: Equatable, Sendable {
    let siteName: String
    let siteID: String
    let pileName: String
    let materialName: String
    let materialCode: String
    let densityKgPerM3: Int
    let referenceCountGoal: Int
    let operatorLabel: String
    let activeFacilityName: String
    let clientBuild: String
    let backgroundUploadSessionIdentifier: String
    let preferredCameraPosition: StockpileCameraLensPosition
    let usesLiveCameraSession: Bool
    let markerlessCaptureEnabled: Bool
    let allowsImportedBackupVideo: Bool
    let allowsConfiguredFallbackCaptureFile: Bool
}

struct StockpileOperationalUploadConfiguration: Equatable, Sendable {
    let fileURL: URL?
    let contentType: String
    let checksumSHA256: String?
    let byteCountOverride: Int64?
}

/// Configuration for the v2 markerless capture submission path. Coexists with
/// the legacy `StockpileOperationalUploadConfiguration` so the v1 movie upload
/// flow stays untouched while markerless `.stockpilecapture` bundles get a
/// dedicated POST surface.
struct StockpileOperationalMarkerlessSubmissionConfiguration: Equatable, Sendable {
    let captureBundleSubmissionURL: URL
    let timeoutInterval: TimeInterval
}

struct StockpileAppConfiguration: Equatable, Sendable {
    let environmentName: String
    let apiBaseURL: URL
    let uploadsBaseURL: URL
    let launchMode: StockpileAppLaunchMode
    let showsEnvironmentBanner: Bool
    let enablesLidarAssist: Bool
    let api: StockpileOperationalAPIConfiguration
    let capture: StockpileOperationalCaptureConfiguration
    let upload: StockpileOperationalUploadConfiguration
    let markerlessSubmission: StockpileOperationalMarkerlessSubmissionConfiguration
    let processingPollInterval: Duration

    static func current(
        processInfo: ProcessInfo = .processInfo,
        bundle: Bundle = .main
    ) -> StockpileAppConfiguration {
        let environment = processInfo.environment
        let runtimeValues = StockpileRuntimeConfigurationValues(
            environment: environment,
            bundle: bundle
        )
        let launchMode = StockpileAppLaunchMode(
            environment: environment,
            bundle: bundle
        )

        let apiBaseURL = runtimeValues.urlValue(for: "STOCKPILE_MOBILE_API_BASE_URL")
            ?? runtimeValues.urlValue(for: "STOCKPILE_API_BASE_URL")
            ?? defaultOperationalAPIBaseURL
        let uploadsBaseURL = runtimeValues.urlValue(for: "STOCKPILE_UPLOADS_BASE_URL")
            ?? apiBaseURL.appending(path: "uploads")
        let environmentName = runtimeValues.stringValue(for: "STOCKPILE_ENVIRONMENT")
            ?? defaultEnvironmentName(for: apiBaseURL, launchMode: launchMode)
        let showsEnvironmentBanner = runtimeValues.booleanValue(for: "STOCKPILE_SHOW_ENVIRONMENT_BANNER") ?? false
        let enablesLidarAssist = runtimeValues.booleanValue(for: "STOCKPILE_ENABLE_LIDAR_ASSIST") ?? true

        let siteName = runtimeValues.stringValue(for: "STOCKPILE_SITE_NAME") ?? "Assigned site"
        let pileName = runtimeValues.stringValue(for: "STOCKPILE_PILE_NAME") ?? "Current stockpile"
        let materialName = runtimeValues.stringValue(for: "STOCKPILE_MATERIAL_NAME") ?? "Backfill"

        let capture = StockpileOperationalCaptureConfiguration(
            siteName: siteName,
            siteID: runtimeValues.stringValue(for: "STOCKPILE_SITE_ID") ?? slug(from: siteName),
            pileName: pileName,
            materialName: materialName,
            materialCode: runtimeValues.stringValue(for: "STOCKPILE_MATERIAL_CODE") ?? slug(from: materialName),
            densityKgPerM3: runtimeValues.intValue(for: "STOCKPILE_DENSITY_KG_PER_M3") ?? 2100,
            referenceCountGoal: runtimeValues.intValue(for: "STOCKPILE_REFERENCE_COUNT_GOAL") ?? 3,
            operatorLabel: runtimeValues.stringValue(for: "STOCKPILE_OPERATOR_LABEL") ?? "Active operator",
            activeFacilityName: runtimeValues.stringValue(for: "STOCKPILE_ACTIVE_FACILITY") ?? siteName,
            clientBuild: runtimeValues.stringValue(for: "STOCKPILE_CLIENT_BUILD") ?? bundle.stockpileClientBuildLabel,
            backgroundUploadSessionIdentifier: runtimeValues.stringValue(for: "STOCKPILE_UPLOAD_BACKGROUND_SESSION_ID")
                ?? "com.clustox.stockpile.capture.upload",
            preferredCameraPosition: runtimeValues.cameraLensPositionValue(for: "STOCKPILE_CAMERA_POSITION") ?? .back,
            usesLiveCameraSession: runtimeValues.liveCameraEnabledValue(
                defaultValue: defaultLiveCameraSessionEnabled
            ),
            markerlessCaptureEnabled: runtimeValues.booleanValue(
                for: "STOCKPILE_MARKERLESS_CAPTURE_ENABLED"
            ) ?? true,
            allowsImportedBackupVideo: runtimeValues.booleanValue(for: "STOCKPILE_ENABLE_BACKUP_VIDEO_IMPORT") ?? false,
            allowsConfiguredFallbackCaptureFile: runtimeValues.booleanValue(for: "STOCKPILE_ENABLE_CONFIGURED_FALLBACK_CAPTURE") ?? false
        )

        let upload = StockpileOperationalUploadConfiguration(
            fileURL: runtimeValues.fileURLValue(
                urlKey: "STOCKPILE_CAPTURE_FILE_URL",
                pathKey: "STOCKPILE_CAPTURE_FILE_PATH"
            ),
            contentType: runtimeValues.stringValue(for: "STOCKPILE_CAPTURE_CONTENT_TYPE") ?? "video/quicktime",
            checksumSHA256: runtimeValues.stringValue(for: "STOCKPILE_CAPTURE_CHECKSUM_SHA256"),
            byteCountOverride: runtimeValues.int64Value(for: "STOCKPILE_CAPTURE_BYTE_COUNT")
        )

        let api = StockpileOperationalAPIConfiguration(
            captureSessionsURL: runtimeValues.urlValue(for: "STOCKPILE_CAPTURE_SESSIONS_URL")
                ?? apiBaseURL.appending(path: "capture-sessions"),
            uploadAuthorizationURL: runtimeValues.urlValue(for: "STOCKPILE_UPLOAD_AUTHORIZATION_URL")
                ?? uploadsBaseURL,
            processingJobsBaseURL: runtimeValues.urlValue(for: "STOCKPILE_PROCESSING_JOBS_URL")
                ?? apiBaseURL.appending(path: "jobs"),
            resultsBaseURL: runtimeValues.urlValue(for: "STOCKPILE_RESULTS_URL")
                ?? apiBaseURL.appending(path: "results"),
            bearerToken: runtimeValues.stringValue(for: "STOCKPILE_API_BEARER_TOKEN"),
            authHeaderName: runtimeValues.stringValue(for: "STOCKPILE_API_AUTH_HEADER_NAME"),
            authHeaderValue: runtimeValues.stringValue(for: "STOCKPILE_API_AUTH_HEADER_VALUE"),
            timeoutInterval: runtimeValues.doubleValue(for: "STOCKPILE_MOBILE_API_TIMEOUT_SECONDS")
                ?? runtimeValues.doubleValue(for: "STOCKPILE_API_TIMEOUT_SECONDS")
                ?? 30
        )

        let pollIntervalMilliseconds = runtimeValues.intValue(for: "STOCKPILE_PROCESSING_POLL_INTERVAL_MS") ?? 2_000

        let markerlessSubmission = StockpileOperationalMarkerlessSubmissionConfiguration(
            captureBundleSubmissionURL: runtimeValues.urlValue(for: "STOCKPILE_CAPTURE_BUNDLE_SUBMISSION_URL")
                ?? Self.defaultCaptureBundleSubmissionURL(for: apiBaseURL),
            timeoutInterval: runtimeValues.doubleValue(for: "STOCKPILE_CAPTURE_BUNDLE_SUBMISSION_TIMEOUT_SECONDS")
                ?? 120
        )

        return StockpileAppConfiguration(
            environmentName: environmentName,
            apiBaseURL: apiBaseURL,
            uploadsBaseURL: uploadsBaseURL,
            launchMode: launchMode,
            showsEnvironmentBanner: showsEnvironmentBanner,
            enablesLidarAssist: enablesLidarAssist,
            api: api,
            capture: capture,
            upload: upload,
            markerlessSubmission: markerlessSubmission,
            processingPollInterval: .milliseconds(pollIntervalMilliseconds)
        )
    }

    /// Resolve the v2 capture bundle endpoint by stripping the v1 mobile prefix
    /// (if present) and appending `/api/v2/captures`. Both backends share a
    /// host but expose different path families, so this defaults the new path
    /// without forcing operators to set an extra env var.
    private static func defaultCaptureBundleSubmissionURL(for apiBaseURL: URL) -> URL {
        let pathV2 = "/api/v2/captures"

        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
        components?.path = pathV2
        components?.query = nil
        components?.fragment = nil

        if let resolved = components?.url {
            return resolved
        }

        return apiBaseURL.appending(path: pathV2)
    }

    var usesLocalOperationalAPI: Bool {
        Self.isLocalOperationalAPIURL(apiBaseURL)
    }

    var isProduction: Bool {
        environmentName.caseInsensitiveCompare("production") == .orderedSame
    }

    var environmentBadgeTitle: String {
        isProduction ? "Production" : environmentName
    }

    var environmentSummary: String {
        if usesLocalOperationalAPI {
            return "Operational mode is active against the local mobile API in this workspace."
        }

        if isProduction {
            return "Operational mode is active with live services against the production processing stack."
        }

        return "Operational mode is active with live services against the configured processing stack."
    }

    var apiHostLabel: String {
        if let host = apiBaseURL.host(percentEncoded: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return host
        }

        return apiBaseURL.absoluteString
    }

    var authenticationModeLabel: String {
        let hasBearerToken = api.bearerToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasHeaderName = api.authHeaderName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasHeaderValue = api.authHeaderValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false

        if hasBearerToken, hasHeaderName, hasHeaderValue {
            return "bearer token and custom auth header"
        }

        if hasBearerToken {
            return "bearer token"
        }

        if hasHeaderName, hasHeaderValue {
            return "custom auth header"
        }

        if hasHeaderName || hasHeaderValue {
            return "incomplete custom auth header"
        }

        return "no explicit auth header"
    }

    var hasIncompleteAuthenticationConfiguration: Bool {
        let hasHeaderName = api.authHeaderName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasHeaderValue = api.authHeaderValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false

        return hasHeaderName != hasHeaderValue
    }

    var liveMobileAPIConfiguration: StockpileLiveMobileAPIConfiguration {
        var defaultHeaders: [String: String] = [
            "User-Agent": capture.clientBuild,
        ]

        if let bearerToken = api.bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           bearerToken.isEmpty == false {
            defaultHeaders["Authorization"] = "Bearer \(bearerToken)"
        }

        if let headerName = api.authHeaderName?.trimmingCharacters(in: .whitespacesAndNewlines),
           let headerValue = api.authHeaderValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           headerName.isEmpty == false,
           headerValue.isEmpty == false {
            defaultHeaders[headerName] = headerValue
        }

        return StockpileLiveMobileAPIConfiguration(
            baseURL: apiBaseURL,
            pathPrefix: "",
            defaultHeaders: defaultHeaders,
            timeoutInterval: api.timeoutInterval
        )
    }

    func resolvedLaunchMode(processInfo: ProcessInfo = .processInfo) -> StockpileAppLaunchMode {
        if let explicitMode = StockpileAppLaunchMode.explicitMode(from: processInfo.environment) {
            return explicitMode
        }

        return launchMode
    }

    private static func slug(from rawValue: String) -> String {
        rawValue
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func defaultEnvironmentName(
        for apiBaseURL: URL,
        launchMode: StockpileAppLaunchMode
    ) -> String {
        if launchMode == .operational,
           isLocalOperationalAPIURL(apiBaseURL) {
            return "Local"
        }

        return "Operational"
    }

    private static func isLocalOperationalAPIURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }

        switch host {
        case "127.0.0.1", "localhost", "0.0.0.0":
            return true
        default:
            return false
        }
    }

    private static let defaultOperationalAPIBaseURL = URL(string: "https://stockpile.theclustox.com/api/mobile")!
    private static let defaultLiveCameraSessionEnabled = true
}

private struct StockpileRuntimeConfigurationValues {
    let environment: [String: String]
    let bundle: Bundle

    func stringValue(for key: String) -> String? {
        environment.stockpileStringValue(for: key)
            ?? bundle.stockpileStringValue(for: key)
    }

    func booleanValue(for key: String) -> Bool? {
        environment.stockpileBooleanValue(for: key)
            ?? bundle.stockpileBooleanValue(for: key)
    }

    func intValue(for key: String) -> Int? {
        guard let rawValue = stringValue(for: key) else {
            return nil
        }

        return Int(rawValue)
    }

    func int64Value(for key: String) -> Int64? {
        guard let rawValue = stringValue(for: key) else {
            return nil
        }

        return Int64(rawValue)
    }

    func doubleValue(for key: String) -> Double? {
        guard let rawValue = stringValue(for: key) else {
            return nil
        }

        return Double(rawValue)
    }

    func urlValue(for key: String) -> URL? {
        guard let rawValue = stringValue(for: key) else {
            return nil
        }

        return URL(string: rawValue)
    }

    func fileURLValue(urlKey: String, pathKey: String) -> URL? {
        if let url = urlValue(for: urlKey) {
            return url
        }

        guard let path = stringValue(for: pathKey) else {
            return nil
        }

        if path.hasPrefix("file://") {
            return URL(string: path)
        }

        return URL(fileURLWithPath: path)
    }

    func cameraLensPositionValue(for key: String) -> StockpileCameraLensPosition? {
        guard let rawValue = stringValue(for: key)?.lowercased() else {
            return nil
        }

        switch rawValue {
        case "back", "rear":
            return .back
        case "front", "selfie":
            return .front
        case "unspecified", "auto", "default":
            return .unspecified
        default:
            return nil
        }
    }

    func liveCameraEnabledValue(defaultValue: Bool) -> Bool {
        if let explicitLiveValue = booleanValue(for: "STOCKPILE_USE_LIVE_CAMERA") {
            return explicitLiveValue
        }

        if let explicitMockValue = booleanValue(for: "STOCKPILE_USE_MOCK_CAMERA") {
            return !explicitMockValue
        }

        return defaultValue
    }
}

private extension Bundle {
    func stockpileStringValue(for key: String) -> String? {
        guard let rawValue = object(forInfoDictionaryKey: key) else {
            return nil
        }

        switch rawValue {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            let stringValue = value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return stringValue.isEmpty ? nil : stringValue
        default:
            return nil
        }
    }

    func stockpileBooleanValue(for key: String) -> Bool? {
        guard let rawValue = stockpileStringValue(for: key)?.lowercased() else {
            return nil
        }

        switch rawValue {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }

    var stockpileClientBuildLabel: String {
        let shortVersion = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String

        switch (shortVersion, buildNumber) {
        case let (.some(version), .some(build)):
            return "ios-\(version)(\(build))"
        case let (.some(version), .none):
            return "ios-\(version)"
        case let (.none, .some(build)):
            return "ios-build-\(build)"
        case (.none, .none):
            return "ios-alpha"
        }
    }
}

private extension [String: String] {
    func stockpileStringValue(for key: String) -> String? {
        guard let rawValue = self[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty else {
            return nil
        }

        return rawValue
    }

    func stockpileBooleanValue(for key: String) -> Bool? {
        guard let rawValue = stockpileStringValue(for: key)?.lowercased() else {
            return nil
        }

        switch rawValue {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }

    func stockpileIntValue(for key: String) -> Int? {
        guard let rawValue = stockpileStringValue(for: key) else {
            return nil
        }

        return Int(rawValue)
    }

    func stockpileInt64Value(for key: String) -> Int64? {
        guard let rawValue = stockpileStringValue(for: key) else {
            return nil
        }

        return Int64(rawValue)
    }

    func stockpileDoubleValue(for key: String) -> Double? {
        guard let rawValue = stockpileStringValue(for: key) else {
            return nil
        }

        return Double(rawValue)
    }

    func stockpileURLValue(for key: String) -> URL? {
        guard let rawValue = stockpileStringValue(for: key) else {
            return nil
        }

        return URL(string: rawValue)
    }

    func stockpileFileURLValue(urlKey: String, pathKey: String) -> URL? {
        if let url = stockpileURLValue(for: urlKey) {
            return url
        }

        guard let path = stockpileStringValue(for: pathKey) else {
            return nil
        }

        if path.hasPrefix("file://") {
            return URL(string: path)
        }

        return URL(fileURLWithPath: path)
    }

    func stockpileCameraLensPositionValue(for key: String) -> StockpileCameraLensPosition? {
        guard let rawValue = stockpileStringValue(for: key)?.lowercased() else {
            return nil
        }

        switch rawValue {
        case "back", "rear":
            return .back
        case "front", "selfie":
            return .front
        case "unspecified", "auto", "default":
            return .unspecified
        default:
            return nil
        }
    }

    func stockpileLiveCameraEnabledValue(defaultValue: Bool) -> Bool {
        if let explicitLiveValue = stockpileBooleanValue(for: "STOCKPILE_USE_LIVE_CAMERA") {
            return explicitLiveValue
        }

        if let explicitMockValue = stockpileBooleanValue(for: "STOCKPILE_USE_MOCK_CAMERA") {
            return !explicitMockValue
        }

        return defaultValue
    }
}
