import Foundation

/// Status of an in-progress markerless capture bundle recording.
public enum StockpileCaptureBundleRecordingStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case preparing
    case recording
    case archiving
    case finished
    case failed
}

/// Output of a successfully archived markerless capture bundle.
public struct StockpileCaptureBundleRecordingOutput: Equatable, Sendable {
    public let captureID: String
    public let archiveURL: URL
    public let stagingDirectoryURL: URL
    public let manifest: StockpileCaptureBundleManifest
    public let poses: StockpileCaptureBundlePoseDocument
    public let anchors: StockpileCaptureBundleAnchorDocument
    public let frameCount: Int
    public let droppedFrameCount: Int
    public let archiveSizeBytes: Int64

    public init(
        captureID: String,
        archiveURL: URL,
        stagingDirectoryURL: URL,
        manifest: StockpileCaptureBundleManifest,
        poses: StockpileCaptureBundlePoseDocument,
        anchors: StockpileCaptureBundleAnchorDocument,
        frameCount: Int,
        droppedFrameCount: Int,
        archiveSizeBytes: Int64
    ) {
        self.captureID = captureID
        self.archiveURL = archiveURL
        self.stagingDirectoryURL = stagingDirectoryURL
        self.manifest = manifest
        self.poses = poses
        self.anchors = anchors
        self.frameCount = frameCount
        self.droppedFrameCount = droppedFrameCount
        self.archiveSizeBytes = max(0, archiveSizeBytes)
    }
}

/// Snapshot of an active bundle recording. Mirrors the existing
/// `StockpileARKitPrimaryRecordingSnapshot` shape but is scoped to markerless
/// `.stockpilecapture` bundle output.
public struct StockpileCaptureBundleRecordingSnapshot: Equatable, Sendable {
    public let status: StockpileCaptureBundleRecordingStatus
    public let captureID: String?
    public let stagingDirectoryURL: URL?
    public let archiveURL: URL?
    public let frameCount: Int
    public let droppedFrameCount: Int
    public let issueDescription: String?
    public let output: StockpileCaptureBundleRecordingOutput?

    public init(
        status: StockpileCaptureBundleRecordingStatus,
        captureID: String? = nil,
        stagingDirectoryURL: URL? = nil,
        archiveURL: URL? = nil,
        frameCount: Int = 0,
        droppedFrameCount: Int = 0,
        issueDescription: String? = nil,
        output: StockpileCaptureBundleRecordingOutput? = nil
    ) {
        self.status = status
        self.captureID = captureID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.stagingDirectoryURL = stagingDirectoryURL
        self.archiveURL = archiveURL
        self.frameCount = max(0, frameCount)
        self.droppedFrameCount = max(0, droppedFrameCount)
        let trimmed = issueDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.issueDescription = (trimmed?.isEmpty == false) ? trimmed : nil
        self.output = output
    }

    public static let idle = StockpileCaptureBundleRecordingSnapshot(status: .idle)
}
