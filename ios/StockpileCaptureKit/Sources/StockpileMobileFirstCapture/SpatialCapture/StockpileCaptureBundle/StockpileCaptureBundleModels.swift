import Foundation

public enum StockpileCaptureBundleContract {
    public static let schemaVersion = "1.0"
    public static let manifestFileName = "manifest.json"
    public static let posesFileName = "poses.json"
    public static let anchorsFileName = "anchors.json"
}

public struct StockpileCaptureBundleDeviceMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let manufacturer: String
    public let modelIdentifier: String
    public let operatingSystem: String
    public let operatingSystemVersion: String
    public let appVersion: String?
    public let captureKitVersion: String?
    public let supportsLiDAR: Bool

    public init(
        schemaVersion: String = StockpileCaptureBundleContract.schemaVersion,
        manufacturer: String,
        modelIdentifier: String,
        operatingSystem: String,
        operatingSystemVersion: String,
        appVersion: String? = nil,
        captureKitVersion: String? = nil,
        supportsLiDAR: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.manufacturer = manufacturer.trimmedForCaptureBundle
        self.modelIdentifier = modelIdentifier.trimmedForCaptureBundle
        self.operatingSystem = operatingSystem.trimmedForCaptureBundle
        self.operatingSystemVersion = operatingSystemVersion.trimmedForCaptureBundle
        self.appVersion = appVersion?.trimmedForCaptureBundle
        self.captureKitVersion = captureKitVersion?.trimmedForCaptureBundle
        self.supportsLiDAR = supportsLiDAR
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case manufacturer
        case modelIdentifier = "model_identifier"
        case operatingSystem = "operating_system"
        case operatingSystemVersion = "operating_system_version"
        case appVersion = "app_version"
        case captureKitVersion = "capture_kit_version"
        case supportsLiDAR = "supports_lidar"
    }
}

public struct StockpileCaptureBundleRGBMetadata: Codable, Equatable, Sendable {
    public let relativePath: String
    public let width: Int
    public let height: Int
    public let colorSpace: String
    public let byteSize: Int64?

    public init(
        relativePath: String,
        width: Int,
        height: Int,
        colorSpace: String,
        byteSize: Int64? = nil
    ) {
        self.relativePath = relativePath.trimmedForCaptureBundle
        self.width = max(0, width)
        self.height = max(0, height)
        self.colorSpace = colorSpace.trimmedForCaptureBundle
        self.byteSize = byteSize.map { max(0, $0) }
    }
}

public struct StockpileCaptureBundleDepthMetadata: Codable, Equatable, Sendable {
    public let relativePath: String
    public let width: Int
    public let height: Int
    public let pixelFormat: String
    public let minDepthM: Double
    public let maxDepthM: Double
    public let isSmoothed: Bool
    public let byteSize: Int64?

    public init(
        relativePath: String,
        width: Int,
        height: Int,
        pixelFormat: String,
        minDepthM: Double,
        maxDepthM: Double,
        isSmoothed: Bool,
        byteSize: Int64? = nil
    ) {
        self.relativePath = relativePath.trimmedForCaptureBundle
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixelFormat = pixelFormat.trimmedForCaptureBundle
        self.minDepthM = max(0, minDepthM)
        self.maxDepthM = max(self.minDepthM, maxDepthM)
        self.isSmoothed = isSmoothed
        self.byteSize = byteSize.map { max(0, $0) }
    }
}

public struct StockpileCaptureBundleConfidenceMetadata: Codable, Equatable, Sendable {
    public let relativePath: String
    public let width: Int
    public let height: Int
    public let pixelFormat: String
    public let coverageRatio: Double
    public let byteSize: Int64?

    public init(
        relativePath: String,
        width: Int,
        height: Int,
        pixelFormat: String,
        coverageRatio: Double,
        byteSize: Int64? = nil
    ) {
        self.relativePath = relativePath.trimmedForCaptureBundle
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixelFormat = pixelFormat.trimmedForCaptureBundle
        self.coverageRatio = coverageRatio.clampedCaptureBundleRatio
        self.byteSize = byteSize.map { max(0, $0) }
    }
}

public struct StockpileCaptureBundleFrameIndexEntry: Codable, Equatable, Sendable {
    public let frameID: String
    public let frameNumber: Int
    public let timestampSec: TimeInterval
    public let rgb: StockpileCaptureBundleRGBMetadata
    public let depth: StockpileCaptureBundleDepthMetadata?
    public let confidence: StockpileCaptureBundleConfidenceMetadata?
    public let poseID: String?

    public init(
        frameID: String,
        frameNumber: Int,
        timestampSec: TimeInterval,
        rgb: StockpileCaptureBundleRGBMetadata,
        depth: StockpileCaptureBundleDepthMetadata? = nil,
        confidence: StockpileCaptureBundleConfidenceMetadata? = nil,
        poseID: String? = nil
    ) {
        self.frameID = frameID.trimmedForCaptureBundle
        self.frameNumber = max(0, frameNumber)
        self.timestampSec = max(0, timestampSec)
        self.rgb = rgb
        self.depth = depth
        self.confidence = confidence
        self.poseID = poseID?.trimmedForCaptureBundle
    }

    private enum CodingKeys: String, CodingKey {
        case frameID = "frame_id"
        case frameNumber = "frame_number"
        case timestampSec = "timestamp_sec"
        case rgb
        case depth
        case confidence
        case poseID = "pose_id"
    }
}

public struct StockpileCaptureBundleTrackingSummary: Codable, Equatable, Sendable {
    public let totalFrameCount: Int
    public let trackedFrameCount: Int
    public let limitedFrameCount: Int
    public let lostFrameCount: Int
    public let averageTrackingConfidence: Double
    public let trackingRatio: Double

    public init(
        totalFrameCount: Int,
        trackedFrameCount: Int,
        limitedFrameCount: Int,
        lostFrameCount: Int,
        averageTrackingConfidence: Double
    ) {
        self.totalFrameCount = max(0, totalFrameCount)
        self.trackedFrameCount = max(0, trackedFrameCount)
        self.limitedFrameCount = max(0, limitedFrameCount)
        self.lostFrameCount = max(0, lostFrameCount)
        self.averageTrackingConfidence = averageTrackingConfidence.clampedCaptureBundleRatio
        if self.totalFrameCount == 0 {
            self.trackingRatio = 0
        } else {
            self.trackingRatio = (Double(self.trackedFrameCount) / Double(self.totalFrameCount)).clampedCaptureBundleRatio
        }
    }

    public static let empty = StockpileCaptureBundleTrackingSummary(
        totalFrameCount: 0,
        trackedFrameCount: 0,
        limitedFrameCount: 0,
        lostFrameCount: 0,
        averageTrackingConfidence: 0
    )
}

public struct StockpileCaptureBundleQuickEstimate: Codable, Equatable, Sendable {
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
        self.confidenceScore = confidenceScore.clampedCaptureBundleRatio
        self.sampledPointCount = max(0, sampledPointCount)
        self.cameraPathDistanceM = max(0, cameraPathDistanceM)
    }

    public init(_ estimate: StockpileDevicePoseQuickVolumeEstimate) {
        self.init(
            volumeM3: estimate.volumeM3,
            footprintAreaM2: estimate.footprintAreaM2,
            peakHeightM: estimate.peakHeightM,
            confidenceScore: estimate.confidenceScore,
            sampledPointCount: estimate.sampledPointCount,
            cameraPathDistanceM: estimate.cameraPathDistanceM
        )
    }
}

public struct StockpileCaptureBundleManifest: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let manifestFileName: String
    public let posesFileName: String
    public let anchorsFileName: String
    public let captureID: String
    public let createdAt: Date
    public let device: StockpileCaptureBundleDeviceMetadata
    public let frameIndex: [StockpileCaptureBundleFrameIndexEntry]
    public let trackingSummary: StockpileCaptureBundleTrackingSummary
    public let groundAnchorID: String
    public let onDeviceQuickEstimate: StockpileCaptureBundleQuickEstimate?

    public init(
        schemaVersion: String = StockpileCaptureBundleContract.schemaVersion,
        manifestFileName: String = StockpileCaptureBundleContract.manifestFileName,
        posesFileName: String = StockpileCaptureBundleContract.posesFileName,
        anchorsFileName: String = StockpileCaptureBundleContract.anchorsFileName,
        captureID: String,
        createdAt: Date,
        device: StockpileCaptureBundleDeviceMetadata,
        frameIndex: [StockpileCaptureBundleFrameIndexEntry],
        trackingSummary: StockpileCaptureBundleTrackingSummary,
        groundAnchorID: String,
        onDeviceQuickEstimate: StockpileCaptureBundleQuickEstimate? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.manifestFileName = manifestFileName
        self.posesFileName = posesFileName
        self.anchorsFileName = anchorsFileName
        self.captureID = captureID.trimmedForCaptureBundle
        self.createdAt = createdAt
        self.device = device
        self.frameIndex = frameIndex
        self.trackingSummary = trackingSummary
        self.groundAnchorID = groundAnchorID.trimmedForCaptureBundle
        self.onDeviceQuickEstimate = onDeviceQuickEstimate
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case manifestFileName = "manifest_file"
        case posesFileName = "poses_file"
        case anchorsFileName = "anchors_file"
        case captureID = "capture_id"
        case createdAt = "created_at"
        case device
        case frameIndex = "frame_index"
        case trackingSummary = "tracking_summary"
        case groundAnchorID = "ground_anchor_id"
        case onDeviceQuickEstimate = "on_device_quick_estimate"
    }
}

public struct StockpileCaptureBundleVector3: Codable, Equatable, Sendable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct StockpileCaptureBundleSize3: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let depth: Double

    public init(width: Double, height: Double, depth: Double) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.depth = max(0, depth)
    }
}

public struct StockpileCaptureBundleTransform: Codable, Equatable, Sendable {
    public let matrix4x4: [Float]
    public let translationMeters: StockpileCaptureBundleVector3
    public let eulerAnglesRadians: StockpileCaptureBundleVector3

    public init(
        matrix4x4: [Float],
        translationMeters: StockpileCaptureBundleVector3,
        eulerAnglesRadians: StockpileCaptureBundleVector3
    ) {
        self.matrix4x4 = Array(matrix4x4.prefix(16)) + Array(repeating: 0, count: max(0, 16 - matrix4x4.count))
        self.translationMeters = translationMeters
        self.eulerAnglesRadians = eulerAnglesRadians
    }

    public init(_ transform: StockpileDevicePoseTransform) {
        self.init(
            matrix4x4: transform.matrix,
            translationMeters: StockpileCaptureBundleVector3(
                x: transform.translationMeters.x,
                y: transform.translationMeters.y,
                z: transform.translationMeters.z
            ),
            eulerAnglesRadians: StockpileCaptureBundleVector3(
                x: transform.eulerAnglesRadians.x,
                y: transform.eulerAnglesRadians.y,
                z: transform.eulerAnglesRadians.z
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case matrix4x4 = "matrix_4x4"
        case translationMeters = "translation_meters"
        case eulerAnglesRadians = "euler_angles_radians"
    }
}

public enum StockpileCaptureBundleTrackingState: String, Codable, Sendable, CaseIterable {
    case normal
    case limited
    case relocalizing
    case unavailable
}

public struct StockpileCaptureBundlePoseSample: Codable, Equatable, Sendable {
    public let poseID: String
    public let frameID: String
    public let frameNumber: Int
    public let timestampSec: TimeInterval
    public let transform: StockpileCaptureBundleTransform
    public let trackingState: StockpileCaptureBundleTrackingState
    public let trackingConfidence: Double

    public init(
        poseID: String,
        frameID: String,
        frameNumber: Int,
        timestampSec: TimeInterval,
        transform: StockpileCaptureBundleTransform,
        trackingState: StockpileCaptureBundleTrackingState,
        trackingConfidence: Double
    ) {
        self.poseID = poseID.trimmedForCaptureBundle
        self.frameID = frameID.trimmedForCaptureBundle
        self.frameNumber = max(0, frameNumber)
        self.timestampSec = max(0, timestampSec)
        self.transform = transform
        self.trackingState = trackingState
        self.trackingConfidence = trackingConfidence.clampedCaptureBundleRatio
    }

    private enum CodingKeys: String, CodingKey {
        case poseID = "pose_id"
        case frameID = "frame_id"
        case frameNumber = "frame_number"
        case timestampSec = "timestamp_sec"
        case transform
        case trackingState = "tracking_state"
        case trackingConfidence = "tracking_confidence"
    }
}

public struct StockpileCaptureBundlePoseDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let poses: [StockpileCaptureBundlePoseSample]

    public init(
        schemaVersion: String = StockpileCaptureBundleContract.schemaVersion,
        poses: [StockpileCaptureBundlePoseSample]
    ) {
        self.schemaVersion = schemaVersion
        self.poses = poses
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case poses
    }
}

public enum StockpileCaptureBundleAnchorType: String, Codable, Sendable, CaseIterable {
    case groundPlane = "ground_plane"
    case worldOrigin = "world_origin"
    case referenceMarker = "reference_marker"
    case pileToe = "pile_toe"
    case pileSurface = "pile_surface"
}

public struct StockpileCaptureBundleAnchor: Codable, Equatable, Sendable {
    public let anchorID: String
    public let anchorType: StockpileCaptureBundleAnchorType
    public let transform: StockpileCaptureBundleTransform
    public let extentMeters: StockpileCaptureBundleSize3?
    public let confidenceScore: Double
    public let observedFrameIDs: [String]

    public init(
        anchorID: String,
        anchorType: StockpileCaptureBundleAnchorType,
        transform: StockpileCaptureBundleTransform,
        extentMeters: StockpileCaptureBundleSize3? = nil,
        confidenceScore: Double,
        observedFrameIDs: [String] = []
    ) {
        self.anchorID = anchorID.trimmedForCaptureBundle
        self.anchorType = anchorType
        self.transform = transform
        self.extentMeters = extentMeters
        self.confidenceScore = confidenceScore.clampedCaptureBundleRatio
        self.observedFrameIDs = observedFrameIDs.map(\.trimmedForCaptureBundle)
    }

    private enum CodingKeys: String, CodingKey {
        case anchorID = "anchor_id"
        case anchorType = "anchor_type"
        case transform
        case extentMeters = "extent_meters"
        case confidenceScore = "confidence_score"
        case observedFrameIDs = "observed_frame_ids"
    }
}

public struct StockpileCaptureBundleAnchorDocument: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let groundAnchorID: String
    public let anchors: [StockpileCaptureBundleAnchor]

    public init(
        schemaVersion: String = StockpileCaptureBundleContract.schemaVersion,
        groundAnchorID: String,
        anchors: [StockpileCaptureBundleAnchor]
    ) {
        self.schemaVersion = schemaVersion
        self.groundAnchorID = groundAnchorID.trimmedForCaptureBundle
        self.anchors = anchors
    }

    public var groundAnchor: StockpileCaptureBundleAnchor? {
        anchors.first { $0.anchorID == groundAnchorID }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case groundAnchorID = "ground_anchor_id"
        case anchors
    }
}

private extension String {
    var trimmedForCaptureBundle: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Double {
    var clampedCaptureBundleRatio: Double {
        min(max(self, 0), 1)
    }
}
