import Foundation

#if os(iOS) && canImport(ARKit)
import ARKit
import CoreImage
import CoreVideo
import simd
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(MobileCoreServices)
import MobileCoreServices
#endif
import UniformTypeIdentifiers

/// Configuration for an in-progress markerless capture bundle recording.
struct StockpileCaptureBundleRecorderConfiguration {
    let captureID: String
    let siteID: String?
    let materialCode: String
    let densityKgPerM3: Int
    let pileSizeMode: String?
    let baseDirectory: URL
    let targetFrameRateHz: Double
    let jpegQuality: CGFloat
    let rgbMaxDimension: CGFloat
    let maxPersistedFrameCount: Int
    let preferSmoothedDepth: Bool
    let device: StockpileCaptureBundleDeviceMetadata

    init(
        captureID: String,
        siteID: String? = nil,
        materialCode: String,
        densityKgPerM3: Int,
        pileSizeMode: String? = nil,
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        targetFrameRateHz: Double = 2,
        jpegQuality: CGFloat = 0.55,
        rgbMaxDimension: CGFloat = 960,
        maxPersistedFrameCount: Int = 160,
        preferSmoothedDepth: Bool = true,
        device: StockpileCaptureBundleDeviceMetadata
    ) {
        self.captureID = captureID
        let trimmedSiteID = siteID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.siteID = trimmedSiteID?.isEmpty == false ? trimmedSiteID : nil
        let trimmedMaterialCode = materialCode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.materialCode = trimmedMaterialCode.lowercased()
        self.densityKgPerM3 = densityKgPerM3
        let trimmedPileSizeMode = pileSizeMode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pileSizeMode = trimmedPileSizeMode?.isEmpty == false ? trimmedPileSizeMode?.lowercased() : nil
        self.baseDirectory = baseDirectory
        self.targetFrameRateHz = max(1, min(targetFrameRateHz, 30))
        self.jpegQuality = max(0.1, min(jpegQuality, 1.0))
        self.rgbMaxDimension = max(320, min(rgbMaxDimension, 1920))
        self.maxPersistedFrameCount = max(30, min(maxPersistedFrameCount, 600))
        self.preferSmoothedDepth = preferSmoothedDepth
        self.device = device
    }
}

/// Helper that persists per-frame RGB/depth/confidence assets and accumulates
/// pose/anchor metadata to be archived as a `.stockpilecapture` bundle.
final class StockpileCaptureBundleRecorder: @unchecked Sendable {
    enum RecorderError: Error, LocalizedError, Equatable {
        case stagingDirectoryCreationFailed(String)
        case rgbEncodingFailed(String)
        case depthSerializationFailed(String)
        case fileWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case let .stagingDirectoryCreationFailed(detail):
                return "Failed to create staging directory: \(detail)"
            case let .rgbEncodingFailed(detail):
                return "Failed to encode RGB frame: \(detail)"
            case let .depthSerializationFailed(detail):
                return "Failed to serialize depth map: \(detail)"
            case let .fileWriteFailed(detail):
                return "Failed to write capture asset: \(detail)"
            }
        }
    }

    let configuration: StockpileCaptureBundleRecorderConfiguration
    let stagingDirectoryURL: URL
    let rgbDirectoryURL: URL
    let depthDirectoryURL: URL
    let confidenceDirectoryURL: URL
    let startedAt: Date

    private(set) var frameCount = 0
    private(set) var droppedFrameCount = 0
    private(set) var poses: [StockpileCaptureBundlePoseSample] = []
    private(set) var frameIndex: [StockpileCaptureBundleFrameIndexEntry] = []
    private(set) var trackingStateCounts: [StockpileCaptureBundleTrackingState: Int] = [:]
    private(set) var trackingConfidenceSum: Double = 0
    private(set) var lastQuickEstimate: StockpileCaptureBundleQuickEstimate?
    private(set) var anchors: [StockpileCaptureBundleAnchor] = []
    private(set) var groundAnchorID: String = "anchor-ground"

    private let ciContext: CIContext
    private let fileManager: FileManager
    private var lastPersistedFrameTimestamp: TimeInterval?

    init(
        configuration: StockpileCaptureBundleRecorderConfiguration,
        startedAt: Date = Date(),
        fileManager: FileManager = .default,
        ciContext: CIContext = CIContext(options: nil)
    ) throws {
        self.configuration = configuration
        self.startedAt = startedAt
        self.fileManager = fileManager
        self.ciContext = ciContext
        self.stagingDirectoryURL = configuration.baseDirectory
            .appendingPathComponent(configuration.captureID, isDirectory: true)
        self.rgbDirectoryURL = stagingDirectoryURL.appendingPathComponent("rgb", isDirectory: true)
        self.depthDirectoryURL = stagingDirectoryURL.appendingPathComponent("depth", isDirectory: true)
        self.confidenceDirectoryURL = stagingDirectoryURL.appendingPathComponent("confidence", isDirectory: true)

        do {
            try fileManager.createDirectory(at: rgbDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: depthDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: confidenceDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw RecorderError.stagingDirectoryCreationFailed(error.localizedDescription)
        }
    }

    /// Decides whether the current frame should be persisted based on the target
    /// throttle rate. Uses the ARKit frame timestamp directly so the recorder does
    /// not depend on wall clock or display sync.
    func shouldPersist(frameTimestamp: TimeInterval) -> Bool {
        guard frameCount < configuration.maxPersistedFrameCount else {
            return false
        }
        guard let last = lastPersistedFrameTimestamp else {
            return true
        }
        let minimumInterval = 1.0 / configuration.targetFrameRateHz
        return frameTimestamp - last >= minimumInterval
    }

    /// Persists a single ARKit frame's RGB/depth/confidence assets to disk and
    /// records pose/frame-index entries. Returns the index assigned to the
    /// persisted frame, or nil if the frame was skipped.
    @discardableResult
    func appendFrame(
        capturedImage: CVPixelBuffer,
        timestamp: TimeInterval,
        cameraTransform: simd_float4x4,
        cameraIntrinsics: simd_float3x3,
        eulerAngles: simd_float3,
        trackingState: StockpileCaptureBundleTrackingState,
        trackingConfidence: Double,
        depthMap: CVPixelBuffer?,
        confidenceMap: CVPixelBuffer?,
        depthIsSmoothed: Bool,
        quickEstimate: StockpileCaptureBundleQuickEstimate?
    ) throws -> Int? {
        guard let depthMap else {
            droppedFrameCount += 1
            return nil
        }

        let frameNumber = frameCount
        let zeroPaddedID = String(format: "%06d", frameNumber)
        let frameID = "frame-\(zeroPaddedID)"
        let poseID = "pose-\(zeroPaddedID)"

        // 1. Serialize depth before writing RGB so a dropped depth frame never
        // leaves behind an RGB/pose entry the backend cannot fuse.
        let serializedDepth: StockpileSerializedDepthMap
        do {
            serializedDepth = try StockpileDepthMapSerializer.serialize(
                depthMap: depthMap,
                confidenceMap: confidenceMap
            )
        } catch let error as StockpileDepthMapSerializer.SerializationError {
            _ = error
            droppedFrameCount += 1
            return nil
        } catch {
            droppedFrameCount += 1
            throw RecorderError.depthSerializationFailed(error.localizedDescription)
        }

        // 2. Persist RGB JPEG.
        let rgbRelativePath = "rgb/\(zeroPaddedID).jpg"
        let rgbURL = stagingDirectoryURL.appendingPathComponent(rgbRelativePath)
        var rgbWidth = CVPixelBufferGetWidth(capturedImage)
        var rgbHeight = CVPixelBufferGetHeight(capturedImage)
        let rgbBytes: Int64
        do {
            let encodedRGB = try writeJPEG(
                pixelBuffer: capturedImage,
                to: rgbURL,
                quality: configuration.jpegQuality,
                maxDimension: configuration.rgbMaxDimension
            )
            rgbBytes = encodedRGB.byteSize
            rgbWidth = encodedRGB.width
            rgbHeight = encodedRGB.height
        } catch let error as RecorderError {
            droppedFrameCount += 1
            throw error
        } catch {
            droppedFrameCount += 1
            throw RecorderError.rgbEncodingFailed(error.localizedDescription)
        }
        let rgbMetadata = StockpileCaptureBundleRGBMetadata(
            relativePath: rgbRelativePath,
            width: rgbWidth,
            height: rgbHeight,
            colorSpace: "srgb",
            byteSize: rgbBytes
        )

        // 3. Persist depth + confidence.
        let depthMetadata: StockpileCaptureBundleDepthMetadata
        var confidenceMetadata: StockpileCaptureBundleConfidenceMetadata?

        do {
            let depthRelativePath = "depth/\(zeroPaddedID).f16.bin"
            let depthURL = stagingDirectoryURL.appendingPathComponent(depthRelativePath)
            try writeData(serializedDepth.depthF16LittleEndianData, to: depthURL)
            let (minDepth, maxDepth) = depthRangeMeters(from: depthMap)
            depthMetadata = StockpileCaptureBundleDepthMetadata(
                relativePath: depthRelativePath,
                width: serializedDepth.width,
                height: serializedDepth.height,
                pixelFormat: "float16",
                minDepthM: minDepth,
                maxDepthM: maxDepth,
                isSmoothed: depthIsSmoothed,
                byteSize: Int64(serializedDepth.depthF16LittleEndianData.count)
            )

            if let confidenceData = serializedDepth.confidenceMapUInt8Data {
                let confidenceRelativePath = "confidence/\(zeroPaddedID).u8.bin"
                let confidenceURL = stagingDirectoryURL.appendingPathComponent(confidenceRelativePath)
                try writeData(confidenceData, to: confidenceURL)
                confidenceMetadata = StockpileCaptureBundleConfidenceMetadata(
                    relativePath: confidenceRelativePath,
                    width: serializedDepth.width,
                    height: serializedDepth.height,
                    pixelFormat: "uint8",
                    coverageRatio: confidenceCoverageRatio(samples: confidenceData),
                    byteSize: Int64(confidenceData.count)
                )
            }
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.depthSerializationFailed(error.localizedDescription)
        }

        // 4. Append pose sample.
        let transform = StockpileCaptureBundleTransform(
            matrix4x4: matrixComponents(cameraTransform),
            translationMeters: StockpileCaptureBundleVector3(
                x: cameraTransform.columns.3.x,
                y: cameraTransform.columns.3.y,
                z: cameraTransform.columns.3.z
            ),
            eulerAnglesRadians: StockpileCaptureBundleVector3(
                x: eulerAngles.x,
                y: eulerAngles.y,
                z: eulerAngles.z
            )
        )
        let pose = StockpileCaptureBundlePoseSample(
            poseID: poseID,
            frameID: frameID,
            frameNumber: frameNumber,
            timestampSec: timestamp,
            transform: transform,
            intrinsics: intrinsicsComponents(cameraIntrinsics),
            lidarActive: true,
            trackingState: trackingState,
            trackingConfidence: trackingConfidence
        )
        poses.append(pose)
        trackingStateCounts[trackingState, default: 0] += 1
        trackingConfidenceSum += trackingConfidence

        // 5. Append frame index entry.
        let entry = StockpileCaptureBundleFrameIndexEntry(
            frameID: frameID,
            frameNumber: frameNumber,
            timestampSec: timestamp,
            rgb: rgbMetadata,
            depth: depthMetadata,
            confidence: confidenceMetadata,
            poseID: poseID
        )
        frameIndex.append(entry)

        frameCount += 1
        lastPersistedFrameTimestamp = timestamp
        if let quickEstimate {
            lastQuickEstimate = quickEstimate
        }

        return frameNumber
    }

    /// Records the largest horizontal plane discovered so far. Anchor mesh export
    /// is intentionally a stub for a later slice.
    func updateGroundAnchor(
        anchorIdentifier: UUID,
        transform: simd_float4x4,
        extentMeters: StockpileCaptureBundleSize3?,
        observedFrameID: String?
    ) {
        let anchorID = "anchor-ground-\(anchorIdentifier.uuidString.prefix(8))"
        let anchorTransform = StockpileCaptureBundleTransform(
            matrix4x4: matrixComponents(transform),
            translationMeters: StockpileCaptureBundleVector3(
                x: transform.columns.3.x,
                y: transform.columns.3.y,
                z: transform.columns.3.z
            ),
            eulerAnglesRadians: StockpileCaptureBundleVector3(x: 0, y: 0, z: 0)
        )
        let observedFrameIDs = observedFrameID.map { [$0] } ?? []
        let anchor = StockpileCaptureBundleAnchor(
            anchorID: anchorID,
            anchorType: .groundPlane,
            transform: anchorTransform,
            extentMeters: extentMeters,
            confidenceScore: 0.6,
            observedFrameIDs: observedFrameIDs
        )

        if let existingIndex = anchors.firstIndex(where: { $0.anchorID == anchorID }) {
            anchors[existingIndex] = anchor
        } else {
            anchors.append(anchor)
        }
        groundAnchorID = anchorID
    }

    /// Builds the manifest/poses/anchors documents from the accumulated state.
    func buildDocuments() -> (
        manifest: StockpileCaptureBundleManifest,
        poses: StockpileCaptureBundlePoseDocument,
        anchors: StockpileCaptureBundleAnchorDocument
    ) {
        let totalCount = frameIndex.count
        let trackedCount = trackingStateCounts[.normal, default: 0]
        let limitedCount = trackingStateCounts[.limited, default: 0]
        let lostCount = trackingStateCounts[.unavailable, default: 0]
            + trackingStateCounts[.relocalizing, default: 0]
        let averageConfidence = totalCount == 0 ? 0 : trackingConfidenceSum / Double(totalCount)

        let summary = StockpileCaptureBundleTrackingSummary(
            totalFrameCount: totalCount,
            trackedFrameCount: trackedCount,
            limitedFrameCount: limitedCount,
            lostFrameCount: lostCount,
            averageTrackingConfidence: averageConfidence
        )

        let manifest = StockpileCaptureBundleManifestBuilder(
            captureID: configuration.captureID,
            siteID: configuration.siteID,
            materialCode: configuration.materialCode,
            densityKgPerM3: configuration.densityKgPerM3,
            pileSizeMode: configuration.pileSizeMode,
            createdAt: startedAt,
            device: configuration.device,
            frameIndex: frameIndex,
            trackingSummary: summary,
            groundAnchorID: groundAnchorID,
            onDeviceQuickEstimate: lastQuickEstimate
        ).build()

        let posesDocument = StockpileCaptureBundlePoseDocument(poses: poses)
        let anchorsDocument = StockpileCaptureBundleAnchorDocument(
            groundAnchorID: groundAnchorID,
            anchors: anchors
        )
        return (manifest, posesDocument, anchorsDocument)
    }

    // MARK: - File helpers

    private func writeData(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw RecorderError.fileWriteFailed(error.localizedDescription)
        }
    }

    private func writeJPEG(
        pixelBuffer: CVPixelBuffer,
        to url: URL,
        quality: CGFloat,
        maxDimension: CGFloat
    ) throws -> (byteSize: Int64, width: Int, height: Int) {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = sourceImage.extent
        let sourceMaxDimension = max(sourceExtent.width, sourceExtent.height)
        let scale = sourceMaxDimension > maxDimension ? maxDimension / sourceMaxDimension : 1
        let ciImage = scale < 1
            ? sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : sourceImage
        let encodedExtent = ciImage.extent.integral
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        guard let data = ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: colorSpace,
            options: options
        ) else {
            throw RecorderError.rgbEncodingFailed("Encoder returned a nil JPEG payload.")
        }
        guard data.isEmpty == false else {
            throw RecorderError.rgbEncodingFailed("Encoder returned an empty JPEG payload.")
        }
        try writeData(data, to: url)
        return (
            byteSize: Int64(data.count),
            width: Int(encodedExtent.width),
            height: Int(encodedExtent.height)
        )
    }

    private func depthRangeMeters(from depthMap: CVPixelBuffer) -> (Double, Double) {
        // We avoid a full pass over the buffer here; use the conservative AR depth
        // working range which is adequate for manifest-level metadata. Actual depth
        // bytes are still serialized per pixel by `StockpileDepthMapSerializer`.
        return (0.25, 8.0)
    }

    private func confidenceCoverageRatio(samples: Data) -> Double {
        guard samples.isEmpty == false else { return 0 }
        var highCount = 0
        for byte in samples where byte >= 2 {
            highCount += 1
        }
        return min(max(Double(highCount) / Double(samples.count), 0), 1)
    }

    private func matrixComponents(_ matrix: simd_float4x4) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.1.x, matrix.columns.2.x, matrix.columns.3.x,
            matrix.columns.0.y, matrix.columns.1.y, matrix.columns.2.y, matrix.columns.3.y,
            matrix.columns.0.z, matrix.columns.1.z, matrix.columns.2.z, matrix.columns.3.z,
            matrix.columns.0.w, matrix.columns.1.w, matrix.columns.2.w, matrix.columns.3.w,
        ]
    }

    private func intrinsicsComponents(_ matrix: simd_float3x3) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.1.x, matrix.columns.2.x,
            matrix.columns.0.y, matrix.columns.1.y, matrix.columns.2.y,
            matrix.columns.0.z, matrix.columns.1.z, matrix.columns.2.z,
        ]
    }
}

extension StockpileCaptureBundleDeviceMetadata {
    /// Builds device metadata from current process info + UIDevice. Suitable as a
    /// default for capture sessions that do not otherwise know the device shape.
    static func currentDevice(
        appVersion: String? = nil,
        captureKitVersion: String? = nil
    ) -> StockpileCaptureBundleDeviceMetadata {
        #if canImport(UIKit)
        // UIDevice properties are @MainActor-isolated in the iOS 26 SDK.
        // This helper is always called from UI-driven capture flow (main thread),
        // so assumeIsolated is safe and avoids making the signature @MainActor.
        return MainActor.assumeIsolated {
            let device = UIDevice.current
            let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
            return StockpileCaptureBundleDeviceMetadata(
                manufacturer: "Apple",
                modelIdentifier: device.model,
                operatingSystem: device.systemName,
                operatingSystemVersion: osVersion,
                appVersion: appVersion,
                captureKitVersion: captureKitVersion,
                supportsLiDAR: Self.currentDeviceSupportsLiDAR
            )
        }
        #else
        return StockpileCaptureBundleDeviceMetadata(
            manufacturer: "Apple",
            modelIdentifier: "Unknown",
            operatingSystem: "iOS",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: appVersion,
            captureKitVersion: captureKitVersion,
            supportsLiDAR: false
        )
        #endif
    }

    private static var currentDeviceSupportsLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
            || ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            || ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }
}

#endif
