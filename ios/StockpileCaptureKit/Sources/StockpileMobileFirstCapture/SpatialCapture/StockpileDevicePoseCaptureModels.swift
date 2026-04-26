import Foundation

public enum StockpileDevicePoseCaptureStatus: String, Codable, Sendable, CaseIterable {
    case unavailable
    case idle
    case preparing
    case running
    case interrupted
    case stopped
    case failed

    public var title: String {
        switch self {
        case .unavailable:
            return "Unavailable"
        case .idle:
            return "Idle"
        case .preparing:
            return "Preparing"
        case .running:
            return "Tracking"
        case .interrupted:
            return "Interrupted"
        case .stopped:
            return "Stopped"
        case .failed:
            return "Failed"
        }
    }
}

public enum StockpileDevicePoseWorldAlignment: String, Codable, Sendable, CaseIterable {
    case gravity
    case gravityAndHeading
}

public enum StockpileDevicePoseDepthMode: String, Codable, Sendable, CaseIterable {
    case disabled
    case ifAvailable
    case required
}

public enum StockpileDevicePoseSceneMeshMode: String, Codable, Sendable, CaseIterable {
    case disabled
    case ifAvailable
    case required
}

public struct StockpileDevicePoseCaptureCapabilities: Codable, Equatable, Sendable {
    public let platformLabel: String
    public let supportsWorldTracking: Bool
    public let supportsGravityAndHeading: Bool
    public let supportsSceneDepth: Bool
    public let supportsSmoothedSceneDepth: Bool
    public let supportsSceneMesh: Bool
    public let lidarAssistAvailable: Bool
    public let unavailableReason: String?

    public init(
        platformLabel: String,
        supportsWorldTracking: Bool,
        supportsGravityAndHeading: Bool,
        supportsSceneDepth: Bool,
        supportsSmoothedSceneDepth: Bool,
        supportsSceneMesh: Bool,
        lidarAssistAvailable: Bool,
        unavailableReason: String? = nil
    ) {
        self.platformLabel = platformLabel
        self.supportsWorldTracking = supportsWorldTracking
        self.supportsGravityAndHeading = supportsGravityAndHeading
        self.supportsSceneDepth = supportsSceneDepth
        self.supportsSmoothedSceneDepth = supportsSmoothedSceneDepth
        self.supportsSceneMesh = supportsSceneMesh
        self.lidarAssistAvailable = lidarAssistAvailable
        self.unavailableReason = unavailableReason
    }

    public var isSupported: Bool {
        supportsWorldTracking
    }
}

public struct StockpileResolvedDevicePoseCaptureConfiguration: Codable, Equatable, Sendable {
    public let isRunnable: Bool
    public let deliversDepth: Bool
    public let usesSmoothedDepth: Bool
    public let deliversSceneMesh: Bool
    public let unmetRequirement: String?

    public init(
        isRunnable: Bool,
        deliversDepth: Bool,
        usesSmoothedDepth: Bool,
        deliversSceneMesh: Bool,
        unmetRequirement: String? = nil
    ) {
        self.isRunnable = isRunnable
        self.deliversDepth = deliversDepth
        self.usesSmoothedDepth = usesSmoothedDepth
        self.deliversSceneMesh = deliversSceneMesh
        self.unmetRequirement = unmetRequirement
    }
}

public struct StockpileDevicePoseCaptureConfiguration: Codable, Equatable, Sendable {
    public let worldAlignment: StockpileDevicePoseWorldAlignment
    public let depthMode: StockpileDevicePoseDepthMode
    public let preferSmoothedDepth: Bool
    public let sceneMeshMode: StockpileDevicePoseSceneMeshMode
    public let targetSampleRateHz: Double?

    public init(
        worldAlignment: StockpileDevicePoseWorldAlignment = .gravity,
        depthMode: StockpileDevicePoseDepthMode = .ifAvailable,
        preferSmoothedDepth: Bool = true,
        sceneMeshMode: StockpileDevicePoseSceneMeshMode = .ifAvailable,
        targetSampleRateHz: Double? = 15
    ) {
        self.worldAlignment = worldAlignment
        self.depthMode = depthMode
        self.preferSmoothedDepth = preferSmoothedDepth
        self.sceneMeshMode = sceneMeshMode
        if let targetSampleRateHz {
            self.targetSampleRateHz = min(max(targetSampleRateHz, 1), 60)
        } else {
            self.targetSampleRateHz = nil
        }
    }

    public func resolved(
        using capabilities: StockpileDevicePoseCaptureCapabilities
    ) -> StockpileResolvedDevicePoseCaptureConfiguration {
        guard capabilities.supportsWorldTracking else {
            return StockpileResolvedDevicePoseCaptureConfiguration(
                isRunnable: false,
                deliversDepth: false,
                usesSmoothedDepth: false,
                deliversSceneMesh: false,
                unmetRequirement: capabilities.unavailableReason ?? "World tracking is unavailable on this device."
            )
        }

        if worldAlignment == .gravityAndHeading && capabilities.supportsGravityAndHeading == false {
            return StockpileResolvedDevicePoseCaptureConfiguration(
                isRunnable: false,
                deliversDepth: false,
                usesSmoothedDepth: false,
                deliversSceneMesh: false,
                unmetRequirement: "Gravity-and-heading alignment is unavailable on this device."
            )
        }

        let deliversDepth = switch depthMode {
        case .disabled:
            false
        case .ifAvailable, .required:
            capabilities.supportsSceneDepth || capabilities.supportsSmoothedSceneDepth
        }

        if depthMode == .required && deliversDepth == false {
            return StockpileResolvedDevicePoseCaptureConfiguration(
                isRunnable: false,
                deliversDepth: false,
                usesSmoothedDepth: false,
                deliversSceneMesh: false,
                unmetRequirement: "Scene depth is required but unavailable on this device."
            )
        }

        let usesSmoothedDepth = deliversDepth && preferSmoothedDepth && capabilities.supportsSmoothedSceneDepth

        let deliversSceneMesh = switch sceneMeshMode {
        case .disabled:
            false
        case .ifAvailable, .required:
            capabilities.supportsSceneMesh
        }

        if sceneMeshMode == .required && deliversSceneMesh == false {
            return StockpileResolvedDevicePoseCaptureConfiguration(
                isRunnable: false,
                deliversDepth: deliversDepth,
                usesSmoothedDepth: usesSmoothedDepth,
                deliversSceneMesh: false,
                unmetRequirement: "Scene mesh reconstruction is required but unavailable on this device."
            )
        }

        return StockpileResolvedDevicePoseCaptureConfiguration(
            isRunnable: true,
            deliversDepth: deliversDepth,
            usesSmoothedDepth: usesSmoothedDepth,
            deliversSceneMesh: deliversSceneMesh
        )
    }

    public static let alphaDefault = StockpileDevicePoseCaptureConfiguration()
}

public enum StockpileDevicePoseTrackingPhase: String, Codable, Sendable, CaseIterable {
    case unavailable
    case initializing
    case relocalizing
    case limited
    case tracking
}

public struct StockpileDevicePoseTrackingState: Codable, Equatable, Sendable {
    public let phase: StockpileDevicePoseTrackingPhase
    public let detail: String?

    public init(phase: StockpileDevicePoseTrackingPhase, detail: String? = nil) {
        self.phase = phase
        self.detail = detail
    }

    public var isStable: Bool {
        phase == .tracking
    }
}

public struct StockpileDevicePoseVector3: Codable, Equatable, Sendable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct StockpileDevicePoseTransform: Codable, Equatable, Sendable {
    public let matrix: [Float]
    public let translationMeters: StockpileDevicePoseVector3
    public let eulerAnglesRadians: StockpileDevicePoseVector3

    public init(
        matrix: [Float],
        translationMeters: StockpileDevicePoseVector3,
        eulerAnglesRadians: StockpileDevicePoseVector3
    ) {
        self.matrix = Array(matrix.prefix(16)) + Array(repeating: 0, count: max(0, 16 - matrix.count))
        self.translationMeters = translationMeters
        self.eulerAnglesRadians = eulerAnglesRadians
    }
}

public struct StockpileDevicePoseDepthSummary: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let isSmoothed: Bool

    public init(width: Int, height: Int, isSmoothed: Bool) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.isSmoothed = isSmoothed
    }
}

public struct StockpileDevicePoseQuickVolumeEstimate: Codable, Equatable, Sendable {
    public let volumeM3: Double
    public let footprintAreaM2: Double
    public let peakHeightM: Double
    public let confidenceScore: Double
    public let sampledPointCount: Int
    public let cameraPathDistanceM: Double

    public init(
        volumeM3: Double,
        footprintAreaM2: Double,
        peakHeightM: Double,
        confidenceScore: Double,
        sampledPointCount: Int,
        cameraPathDistanceM: Double
    ) {
        self.volumeM3 = max(0, volumeM3)
        self.footprintAreaM2 = max(0, footprintAreaM2)
        self.peakHeightM = max(0, peakHeightM)
        self.confidenceScore = min(max(confidenceScore, 0), 1)
        self.sampledPointCount = max(0, sampledPointCount)
        self.cameraPathDistanceM = max(0, cameraPathDistanceM)
    }
}

public enum StockpileOnDeviceVisionSource: String, Codable, Sendable, CaseIterable {
    case visionForegroundInstanceMask = "vision_foreground_instance_mask"
    case visionImageClassifier = "vision_image_classifier"
    case depthHeuristic = "depth_heuristic"
    case unavailable
}

public struct StockpileOnDeviceVisionSummary: Codable, Equatable, Sendable {
    public let source: StockpileOnDeviceVisionSource
    public let usesMachineLearning: Bool
    public let pileSegmentationScore: Double?
    public let toeSegmentationScore: Double?
    public let segmentationConfidenceScore: Double?
    public let foregroundCoverageRatio: Double?
    public let lowerFrameOccupancyRatio: Double?
    public let materialFamilyCode: String?
    public let materialFamilyLabel: String?
    public let materialConfidenceScore: Double?
    public let guidanceHint: String?

    public init(
        source: StockpileOnDeviceVisionSource,
        usesMachineLearning: Bool,
        pileSegmentationScore: Double? = nil,
        toeSegmentationScore: Double? = nil,
        segmentationConfidenceScore: Double? = nil,
        foregroundCoverageRatio: Double? = nil,
        lowerFrameOccupancyRatio: Double? = nil,
        materialFamilyCode: String? = nil,
        materialFamilyLabel: String? = nil,
        materialConfidenceScore: Double? = nil,
        guidanceHint: String? = nil
    ) {
        self.source = source
        self.usesMachineLearning = usesMachineLearning
        self.pileSegmentationScore = Self.clampRatio(pileSegmentationScore)
        self.toeSegmentationScore = Self.clampRatio(toeSegmentationScore)
        self.segmentationConfidenceScore = Self.clampRatio(segmentationConfidenceScore)
        self.foregroundCoverageRatio = Self.clampRatio(foregroundCoverageRatio)
        self.lowerFrameOccupancyRatio = Self.clampRatio(lowerFrameOccupancyRatio)
        self.materialFamilyCode = materialFamilyCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.materialFamilyLabel = materialFamilyLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.materialConfidenceScore = Self.clampRatio(materialConfidenceScore)
        self.guidanceHint = guidanceHint?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clampRatio(_ value: Double?) -> Double? {
        value.map { min(max($0, 0), 1) }
    }
}

public enum StockpileARKitPrimaryRecordingStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case preparing
    case recording
    case finishing
    case finished
    case failed
}

public struct StockpileARKitPrimaryRecordingOutput: Codable, Equatable, Sendable {
    public let fileURL: URL
    public let fileSizeBytes: Int64
    public let startedAt: Date
    public let finishedAt: Date
    public let frameCount: Int

    public init(
        fileURL: URL,
        fileSizeBytes: Int64,
        startedAt: Date,
        finishedAt: Date,
        frameCount: Int
    ) {
        self.fileURL = fileURL
        self.fileSizeBytes = max(0, fileSizeBytes)
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.frameCount = max(0, frameCount)
    }

    public var durationSec: TimeInterval {
        max(0, finishedAt.timeIntervalSince(startedAt))
    }
}

public struct StockpileARKitPrimaryRecordingSnapshot: Codable, Equatable, Sendable {
    public let status: StockpileARKitPrimaryRecordingStatus
    public let output: StockpileARKitPrimaryRecordingOutput?
    public let frameCount: Int
    public let droppedFrameCount: Int
    public let usesSingleCameraOwner: Bool
    public let includesDepth: Bool
    public let includesOnDeviceVision: Bool
    public let issueDescription: String?

    public init(
        status: StockpileARKitPrimaryRecordingStatus,
        output: StockpileARKitPrimaryRecordingOutput? = nil,
        frameCount: Int = 0,
        droppedFrameCount: Int = 0,
        usesSingleCameraOwner: Bool = true,
        includesDepth: Bool = false,
        includesOnDeviceVision: Bool = false,
        issueDescription: String? = nil
    ) {
        self.status = status
        self.output = output
        self.frameCount = max(0, frameCount)
        self.droppedFrameCount = max(0, droppedFrameCount)
        self.usesSingleCameraOwner = usesSingleCameraOwner
        self.includesDepth = includesDepth
        self.includesOnDeviceVision = includesOnDeviceVision
        let cleanedIssue = issueDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.issueDescription = cleanedIssue?.isEmpty == true ? "" : cleanedIssue
    }

    public static let idle = StockpileARKitPrimaryRecordingSnapshot(status: .idle)
}

public struct StockpileDevicePoseSample: Codable, Equatable, Sendable {
    public let sequenceNumber: Int
    public let sessionTimestamp: TimeInterval
    public let trackingState: StockpileDevicePoseTrackingState
    public let transform: StockpileDevicePoseTransform
    public let depthSummary: StockpileDevicePoseDepthSummary?

    public init(
        sequenceNumber: Int,
        sessionTimestamp: TimeInterval,
        trackingState: StockpileDevicePoseTrackingState,
        transform: StockpileDevicePoseTransform,
        depthSummary: StockpileDevicePoseDepthSummary? = nil
    ) {
        self.sequenceNumber = max(0, sequenceNumber)
        self.sessionTimestamp = max(0, sessionTimestamp)
        self.trackingState = trackingState
        self.transform = transform
        self.depthSummary = depthSummary
    }
}

public struct StockpileDevicePoseCaptureSnapshot: Codable, Equatable, Sendable {
    public let status: StockpileDevicePoseCaptureStatus
    public let capabilities: StockpileDevicePoseCaptureCapabilities
    public let configuration: StockpileDevicePoseCaptureConfiguration?
    public let resolvedConfiguration: StockpileResolvedDevicePoseCaptureConfiguration?
    public let sampleCount: Int
    public let latestSample: StockpileDevicePoseSample?
    public let quickVolumeEstimate: StockpileDevicePoseQuickVolumeEstimate?
    public let onDeviceVision: StockpileOnDeviceVisionSummary?
    public let startedAt: Date?
    public let updatedAt: Date
    public let issueDescription: String?

    public init(
        status: StockpileDevicePoseCaptureStatus,
        capabilities: StockpileDevicePoseCaptureCapabilities,
        configuration: StockpileDevicePoseCaptureConfiguration? = nil,
        resolvedConfiguration: StockpileResolvedDevicePoseCaptureConfiguration? = nil,
        sampleCount: Int = 0,
        latestSample: StockpileDevicePoseSample? = nil,
        quickVolumeEstimate: StockpileDevicePoseQuickVolumeEstimate? = nil,
        onDeviceVision: StockpileOnDeviceVisionSummary? = nil,
        startedAt: Date? = nil,
        updatedAt: Date = Date(),
        issueDescription: String? = nil
    ) {
        self.status = status
        self.capabilities = capabilities
        self.configuration = configuration
        self.resolvedConfiguration = resolvedConfiguration
        self.sampleCount = max(0, sampleCount)
        self.latestSample = latestSample
        self.quickVolumeEstimate = quickVolumeEstimate
        self.onDeviceVision = onDeviceVision
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.issueDescription = issueDescription
    }

    public var telemetry: StockpileDevicePoseTelemetry {
        StockpileDevicePoseTelemetry(
            samplesCaptured: sampleCount,
            headingStable: configuration?.worldAlignment == .gravityAndHeading && latestSample?.trackingState.isStable == true,
            motionStable: latestSample?.trackingState.isStable == true,
            lidarAssistAvailable: capabilities.lidarAssistAvailable
        )
    }
}

public enum StockpileDevicePoseCaptureError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case configurationRejected(String)
    case runtimeFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message),
            let .configurationRejected(message),
            let .runtimeFailure(message):
            return message
        }
    }
}
