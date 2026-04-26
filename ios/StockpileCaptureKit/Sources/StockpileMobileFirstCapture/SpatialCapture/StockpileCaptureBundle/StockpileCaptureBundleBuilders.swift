import Foundation

public struct StockpileCaptureBundleManifestBuilder: Sendable {
    public let captureID: String
    public let createdAt: Date
    public let device: StockpileCaptureBundleDeviceMetadata
    public let frameIndex: [StockpileCaptureBundleFrameIndexEntry]
    public let trackingSummary: StockpileCaptureBundleTrackingSummary
    public let groundAnchorID: String
    public let onDeviceQuickEstimate: StockpileCaptureBundleQuickEstimate?

    public init(
        captureID: String,
        createdAt: Date,
        device: StockpileCaptureBundleDeviceMetadata,
        frameIndex: [StockpileCaptureBundleFrameIndexEntry],
        trackingSummary: StockpileCaptureBundleTrackingSummary,
        groundAnchorID: String,
        onDeviceQuickEstimate: StockpileCaptureBundleQuickEstimate? = nil
    ) {
        self.captureID = captureID
        self.createdAt = createdAt
        self.device = device
        self.frameIndex = frameIndex
        self.trackingSummary = trackingSummary
        self.groundAnchorID = groundAnchorID
        self.onDeviceQuickEstimate = onDeviceQuickEstimate
    }

    public func build() -> StockpileCaptureBundleManifest {
        StockpileCaptureBundleManifest(
            captureID: captureID,
            createdAt: createdAt,
            device: device,
            frameIndex: frameIndex,
            trackingSummary: trackingSummary,
            groundAnchorID: groundAnchorID,
            onDeviceQuickEstimate: onDeviceQuickEstimate
        )
    }
}

public struct StockpileCaptureBundleBuilder: Sendable {
    public let manifest: StockpileCaptureBundleManifest
    public let poses: StockpileCaptureBundlePoseDocument
    public let anchors: StockpileCaptureBundleAnchorDocument

    public init(
        manifest: StockpileCaptureBundleManifest,
        poses: StockpileCaptureBundlePoseDocument,
        anchors: StockpileCaptureBundleAnchorDocument
    ) {
        self.manifest = manifest
        self.poses = poses
        self.anchors = anchors
    }

    public func build() -> StockpileCaptureBundleDocuments {
        StockpileCaptureBundleDocuments(
            manifest: manifest,
            poses: poses,
            anchors: anchors
        )
    }
}

public struct StockpileCaptureBundleDocuments: Equatable, Sendable {
    public let schemaVersion: String
    public let manifest: StockpileCaptureBundleManifest
    public let poses: StockpileCaptureBundlePoseDocument
    public let anchors: StockpileCaptureBundleAnchorDocument

    public init(
        schemaVersion: String = StockpileCaptureBundleContract.schemaVersion,
        manifest: StockpileCaptureBundleManifest,
        poses: StockpileCaptureBundlePoseDocument,
        anchors: StockpileCaptureBundleAnchorDocument
    ) {
        self.schemaVersion = schemaVersion
        self.manifest = manifest
        self.poses = poses
        self.anchors = anchors
    }

    public var fileNames: [String] {
        [
            StockpileCaptureBundleContract.manifestFileName,
            StockpileCaptureBundleContract.posesFileName,
            StockpileCaptureBundleContract.anchorsFileName,
        ]
    }

    public func encodedJSONFiles(
        encoder: StockpileCaptureBundleJSONEncoder = StockpileCaptureBundleJSONEncoder()
    ) throws -> [String: Data] {
        var files: [String: Data] = [:]
        files[StockpileCaptureBundleContract.manifestFileName] = try encoder.encode(manifest)
        files[StockpileCaptureBundleContract.posesFileName] = try encoder.encode(poses)
        files[StockpileCaptureBundleContract.anchorsFileName] = try encoder.encode(anchors)
        return files
    }
}

public struct StockpileCaptureBundleJSONEncoder: Sendable {
    public let outputFormatting: JSONEncoder.OutputFormatting

    public init(outputFormatting: JSONEncoder.OutputFormatting = []) {
        self.outputFormatting = outputFormatting
    }

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public func encodeJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw StockpileCaptureBundleJSONEncodingError.topLevelObjectIsNotDictionary
        }
        return dictionary
    }

    public func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = outputFormatting
        return encoder
    }
}

public enum StockpileCaptureBundleJSONEncodingError: Error, Equatable, Sendable {
    case topLevelObjectIsNotDictionary
}
