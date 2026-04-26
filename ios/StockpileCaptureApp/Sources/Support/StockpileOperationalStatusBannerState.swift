import Foundation
import StockpileDesignSystem
import StockpileMobileAPI

struct StockpileOperationalStatusBannerState: Equatable {
    let title: String
    let message: String
    let tone: StockpileStatusTone
}

enum StockpileBackendConnectionKind: Equatable {
    case checking
    case connected
    case attentionRequired
}

struct StockpileBackendConnectionState: Equatable {
    let kind: StockpileBackendConnectionKind
    let syncLabel: String
    let banner: StockpileOperationalStatusBannerState

    static func checking(configuration: StockpileAppConfiguration) -> StockpileBackendConnectionState {
        StockpileBackendConnectionState(
            kind: .checking,
            syncLabel: "Checking live backend",
            banner: StockpileOperationalStatusBannerState(
                title: "Checking \(configuration.environmentBadgeTitle) backend",
                message: "Verifying \(configuration.apiHostLabel) before the first live capture is handed to internal testers.",
                tone: .info
            )
        )
    }

    static func connected(configuration: StockpileAppConfiguration) -> StockpileBackendConnectionState {
        StockpileBackendConnectionState(
            kind: .connected,
            syncLabel: "Refreshed from backend",
            banner: StockpileOperationalStatusBannerState(
                title: "Internal alpha connected",
                message: "This build is using the \(configuration.environmentBadgeTitle) backend at \(configuration.apiHostLabel). Live camera capture and backend upload are armed on this phone.",
                tone: .info
            )
        )
    }

    static func incompleteAuthConfiguration(
        configuration: StockpileAppConfiguration
    ) -> StockpileBackendConnectionState {
        StockpileBackendConnectionState(
            kind: .attentionRequired,
            syncLabel: "Auth header incomplete",
            banner: StockpileOperationalStatusBannerState(
                title: "Auth configuration is incomplete",
                message: "This build has only part of a custom auth header configured. Fill both the header name and value before sharing it with internal testers.",
                tone: .critical
            )
        )
    }

    static func failed(
        configuration: StockpileAppConfiguration,
        error: Error
    ) -> StockpileBackendConnectionState {
        let hostLabel = configuration.apiHostLabel

        if let apiError = error as? StockpileMobileAPIError {
            switch apiError {
            case let .authenticationRequired(message):
                return StockpileBackendConnectionState(
                    kind: .attentionRequired,
                    syncLabel: "Backend auth required",
                    banner: StockpileOperationalStatusBannerState(
                        title: "Backend authentication is required",
                        message: message
                            ?? "The build reached \(hostLabel), but the server rejected it. Inject the release auth token or header before handing this build to testers.",
                        tone: .critical
                    )
                )
            case let .forbidden(message):
                return StockpileBackendConnectionState(
                    kind: .attentionRequired,
                    syncLabel: "Backend access denied",
                    banner: StockpileOperationalStatusBannerState(
                        title: "This build cannot use the live backend",
                        message: message
                            ?? "The build reached \(hostLabel), but access was denied. Check release auth values and server-side allowlists before sharing it internally.",
                        tone: .critical
                    )
                )
            case let .rateLimited(retryAfter, message):
                let retryMessage: String
                if let message {
                    retryMessage = message
                } else if let retryAfter {
                    retryMessage = "The backend asked this device to wait \(Int(retryAfter)) seconds before retrying."
                } else {
                    retryMessage = "The backend temporarily rate-limited this device."
                }

                return StockpileBackendConnectionState(
                    kind: .attentionRequired,
                    syncLabel: "Backend rate-limited",
                    banner: StockpileOperationalStatusBannerState(
                        title: "Backend is rate-limiting this build",
                        message: "\(retryMessage) Keep the build internal until repeated launches stabilize.",
                        tone: .caution
                    )
                )
            case let .transportFailure(message):
                return StockpileBackendConnectionState(
                    kind: .attentionRequired,
                    syncLabel: "Backend unreachable",
                    banner: StockpileOperationalStatusBannerState(
                        title: "Live backend is unreachable",
                        message: "The build could not reach \(hostLabel). Internal testers can open the app, but uploads will not complete until connectivity or the API base URL is fixed. \(message)",
                        tone: .critical
                    )
                )
            case let .invalidRequestURL(message),
                 let .decodingFailure(message):
                return StockpileBackendConnectionState(
                    kind: .attentionRequired,
                    syncLabel: "Backend config mismatch",
                    banner: StockpileOperationalStatusBannerState(
                        title: "Backend configuration needs attention",
                        message: "This build is not aligned with the live API contract for \(hostLabel). \(message)",
                        tone: .critical
                    )
                )
            case let .requestFailed(statusCode, message),
                 let .serverError(statusCode, message):
                let resolvedMessage = message ?? "The backend returned status \(statusCode)."
                return StockpileBackendConnectionState(
                    kind: .attentionRequired,
                    syncLabel: "Backend returned \(statusCode)",
                    banner: StockpileOperationalStatusBannerState(
                        title: "Live backend is responding with errors",
                        message: "\(resolvedMessage) Keep this build internal until the staging path is healthy again.",
                        tone: statusCode >= 500 ? .critical : .caution
                    )
                )
            case let .validationFailed(message):
                return StockpileBackendConnectionState(
                    kind: .attentionRequired,
                    syncLabel: "Backend request rejected",
                    banner: StockpileOperationalStatusBannerState(
                        title: "Backend rejected the request",
                        message: message
                            ?? "The build reached \(hostLabel), but the request shape was rejected. This usually means the client and API are out of sync.",
                        tone: .critical
                    )
                )
            case .sessionNotFound,
                 .jobNotFound,
                 .resultNotFound,
                 .invalidResponse,
                 .encodingFailure:
                break
            }
        }

        return StockpileBackendConnectionState(
            kind: .attentionRequired,
            syncLabel: "Backend needs attention",
            banner: StockpileOperationalStatusBannerState(
                title: "Live backend needs attention",
                message: "The build hit an unexpected backend problem while checking \(hostLabel): \(error.localizedDescription)",
                tone: .critical
            )
        )
    }
}
