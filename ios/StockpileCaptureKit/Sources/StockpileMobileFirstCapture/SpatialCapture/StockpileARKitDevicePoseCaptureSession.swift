import Foundation

#if os(iOS) && canImport(ARKit)
import ARKit
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(UIKit)
@preconcurrency import UIKit
#endif
import simd

public final class StockpileARKitDevicePoseCaptureSession: NSObject, StockpileDevicePoseCaptureSession, @unchecked Sendable {
    public var capabilities: StockpileDevicePoseCaptureCapabilities {
        Self.currentCapabilities()
    }

    public var latestSnapshot: StockpileDevicePoseCaptureSnapshot {
        lock.withLock { snapshot }
    }

    public var latestRecordingSnapshot: StockpileARKitPrimaryRecordingSnapshot {
        recordingLock.withLock { recordingSnapshot }
    }

    public var latestBundleSnapshot: StockpileCaptureBundleRecordingSnapshot {
        bundleLock.withLock { bundleSnapshot }
    }

    /// Exposes the underlying ARSession so UI components such as the live mesh
    /// overlay can share the session without spawning a competing one.
    public var underlyingARSession: ARSession { session }

    public var onSnapshotUpdated: (@Sendable (StockpileDevicePoseCaptureSnapshot) -> Void)?
    public var onRecordingSnapshotUpdated: (@Sendable (StockpileARKitPrimaryRecordingSnapshot) -> Void)?
    public var onBundleSnapshotUpdated: (@Sendable (StockpileCaptureBundleRecordingSnapshot) -> Void)?

    /// When set to true, `start(configuration:)` will not honor `startRecording(to:)`
    /// and will instead expect callers to use `startBundleRecording(...)` with
    /// an explicit operator-selected material and density.
    /// The legacy H.264 movie writer is left untouched for the `false` case.
    public var markerlessCaptureEnabled: Bool = false

    private let lock = NSLock()
    private let recordingLock = NSLock()
    private let bundleLock = NSLock()
    private let session = ARSession()
    private var snapshot: StockpileDevicePoseCaptureSnapshot
    private var recordingSnapshot = StockpileARKitPrimaryRecordingSnapshot.idle
    private var bundleSnapshot = StockpileCaptureBundleRecordingSnapshot.idle
    private var bundleRecorder: StockpileCaptureBundleRecorder?
    private var bundleArchiver = StockpileCaptureBundleArchiver()
    private var bundleCompletion: (@Sendable (Result<StockpileCaptureBundleRecordingOutput, Error>) -> Void)?
    private var recordingWriter: StockpileARKitPrimaryMovieWriter?
    private var pendingRecordingURL: URL?
    private var recordingStartedAt: Date?
    private var recordingFrameCount = 0
    private var droppedRecordingFrameCount = 0
    private var recordingIncludesDepth = false
    private var recordingIncludesOnDeviceVision = false
    private var sampleCount = 0
    private let quickVolumeEstimator = StockpileARKitQuickVolumeEstimator()
    private let visionAnalyzer = StockpileARKitOnDeviceVisionAnalyzer()

    public override init() {
        let capabilities = Self.currentCapabilities()
        snapshot = StockpileDevicePoseCaptureSnapshot(
            status: capabilities.isSupported ? .idle : .unavailable,
            capabilities: capabilities,
            issueDescription: capabilities.unavailableReason
        )
        super.init()
        session.delegate = self
    }

    public func start(configuration: StockpileDevicePoseCaptureConfiguration) throws {
        let capabilities = Self.currentCapabilities()
        let resolvedConfiguration = configuration.resolved(using: capabilities)
        guard resolvedConfiguration.isRunnable else {
            let message = resolvedConfiguration.unmetRequirement
                ?? capabilities.unavailableReason
                ?? "ARKit device pose capture is unavailable."
            publish(
                status: .unavailable,
                capabilities: capabilities,
                configuration: configuration,
                resolvedConfiguration: resolvedConfiguration,
                issueDescription: message
            )
            throw StockpileDevicePoseCaptureError.unavailable(message)
        }

        let worldTrackingConfiguration = ARWorldTrackingConfiguration()
        worldTrackingConfiguration.worldAlignment = configuration.worldAlignment.arWorldAlignment
        worldTrackingConfiguration.planeDetection.insert(.horizontal)

        if resolvedConfiguration.deliversDepth {
            let semantics: ARConfiguration.FrameSemantics = resolvedConfiguration.usesSmoothedDepth
                ? .smoothedSceneDepth
                : .sceneDepth
            worldTrackingConfiguration.frameSemantics.insert(semantics)
        }

        if resolvedConfiguration.deliversSceneMesh {
            worldTrackingConfiguration.sceneReconstruction = .meshWithClassification
        }

        sampleCount = 0
        quickVolumeEstimator.reset()
        visionAnalyzer.reset()
        publish(
            status: .preparing,
            capabilities: capabilities,
            configuration: configuration,
            resolvedConfiguration: resolvedConfiguration,
            issueDescription: nil,
            sampleCount: 0,
            startedAt: Date()
        )
        session.run(worldTrackingConfiguration, options: [.resetTracking, .removeExistingAnchors])
        publish(
            status: .running,
            capabilities: capabilities,
            configuration: configuration,
            resolvedConfiguration: resolvedConfiguration,
            issueDescription: nil,
            sampleCount: 0,
            startedAt: latestSnapshot.startedAt
        )
    }

    public func startRecording(to outputURL: URL) throws {
        guard latestSnapshot.status == .running || latestSnapshot.status == .preparing else {
            throw StockpileDevicePoseCaptureError.runtimeFailure(
                "Start ARKit capture before starting ARKit-primary recording."
            )
        }

        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let nextSnapshot: StockpileARKitPrimaryRecordingSnapshot = try recordingLock.withLock {
            switch recordingSnapshot.status {
            case .preparing, .recording, .finishing:
                throw StockpileDevicePoseCaptureError.runtimeFailure(
                    "ARKit-primary recording is already active."
                )
            case .idle, .finished, .failed:
                pendingRecordingURL = outputURL
                recordingWriter = nil
                recordingStartedAt = Date()
                recordingFrameCount = 0
                droppedRecordingFrameCount = 0
                recordingIncludesDepth = false
                recordingIncludesOnDeviceVision = false
                recordingSnapshot = StockpileARKitPrimaryRecordingSnapshot(
                    status: .preparing,
                    usesSingleCameraOwner: true
                )
                return recordingSnapshot
            }
        }
        onRecordingSnapshotUpdated?(nextSnapshot)
    }

    public func stopRecording() {
        let finishRequest = recordingLock.withLock { () -> (
            writer: StockpileARKitPrimaryMovieWriter?,
            startedAt: Date?,
            frameCount: Int,
            droppedFrameCount: Int,
            includesDepth: Bool,
            includesOnDeviceVision: Bool,
            shouldFailWithoutFrames: Bool,
            finishingSnapshot: StockpileARKitPrimaryRecordingSnapshot?
        ) in
            switch recordingSnapshot.status {
            case .preparing where recordingWriter == nil:
                pendingRecordingURL = nil
                recordingSnapshot = StockpileARKitPrimaryRecordingSnapshot(
                    status: .failed,
                    usesSingleCameraOwner: true,
                    issueDescription: "No ARKit frames were recorded before stop."
                )
                return (
                    writer: nil,
                    startedAt: recordingStartedAt,
                    frameCount: recordingFrameCount,
                    droppedFrameCount: droppedRecordingFrameCount,
                    includesDepth: recordingIncludesDepth,
                    includesOnDeviceVision: recordingIncludesOnDeviceVision,
                    shouldFailWithoutFrames: true,
                    finishingSnapshot: recordingSnapshot
                )
            case .recording:
                let writer = recordingWriter
                recordingWriter = nil
                pendingRecordingURL = nil
                recordingSnapshot = StockpileARKitPrimaryRecordingSnapshot(
                    status: .finishing,
                    frameCount: recordingFrameCount,
                    droppedFrameCount: droppedRecordingFrameCount,
                    usesSingleCameraOwner: true,
                    includesDepth: recordingIncludesDepth,
                    includesOnDeviceVision: recordingIncludesOnDeviceVision
                )
                return (
                    writer: writer,
                    startedAt: recordingStartedAt,
                    frameCount: recordingFrameCount,
                    droppedFrameCount: droppedRecordingFrameCount,
                    includesDepth: recordingIncludesDepth,
                    includesOnDeviceVision: recordingIncludesOnDeviceVision,
                    shouldFailWithoutFrames: false,
                    finishingSnapshot: recordingSnapshot
                )
            default:
                return (
                    writer: nil,
                    startedAt: recordingStartedAt,
                    frameCount: recordingFrameCount,
                    droppedFrameCount: droppedRecordingFrameCount,
                    includesDepth: recordingIncludesDepth,
                    includesOnDeviceVision: recordingIncludesOnDeviceVision,
                    shouldFailWithoutFrames: false,
                    finishingSnapshot: nil
                )
            }
        }

        if let finishingSnapshot = finishRequest.finishingSnapshot {
            onRecordingSnapshotUpdated?(finishingSnapshot)
        }
        guard finishRequest.shouldFailWithoutFrames == false,
              let writer = finishRequest.writer,
              let startedAt = finishRequest.startedAt else {
            return
        }

        writer.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(fileSizeBytes):
                self.publishRecording(
                    StockpileARKitPrimaryRecordingSnapshot(
                        status: .finished,
                        output: StockpileARKitPrimaryRecordingOutput(
                            fileURL: writer.outputURL,
                            fileSizeBytes: fileSizeBytes,
                            startedAt: startedAt,
                            finishedAt: Date(),
                            frameCount: finishRequest.frameCount
                        ),
                        frameCount: finishRequest.frameCount,
                        droppedFrameCount: finishRequest.droppedFrameCount,
                        usesSingleCameraOwner: true,
                        includesDepth: finishRequest.includesDepth,
                        includesOnDeviceVision: finishRequest.includesOnDeviceVision
                    )
                )
            case let .failure(error):
                self.publishRecording(
                    StockpileARKitPrimaryRecordingSnapshot(
                        status: .failed,
                        frameCount: finishRequest.frameCount,
                        droppedFrameCount: finishRequest.droppedFrameCount,
                        usesSingleCameraOwner: true,
                        includesDepth: finishRequest.includesDepth,
                        includesOnDeviceVision: finishRequest.includesOnDeviceVision,
                        issueDescription: error.localizedDescription
                    )
                )
            }
        }
    }

    public func stop() {
        stopRecording()
        session.pause()
        let current = latestSnapshot
        publish(
            status: .stopped,
            capabilities: current.capabilities,
            configuration: current.configuration,
            resolvedConfiguration: current.resolvedConfiguration,
            issueDescription: current.issueDescription,
            sampleCount: current.sampleCount,
            latestSample: current.latestSample,
            quickVolumeEstimate: current.quickVolumeEstimate,
            onDeviceVision: current.onDeviceVision,
            startedAt: current.startedAt
        )
    }

    /// Begin recording a markerless `.stockpilecapture` bundle. The session must
    /// be running (or preparing). Persists per-frame RGB/depth/confidence assets
    /// into a staging directory and accumulates pose/anchor metadata until
    /// `stopBundleRecording(...)` is invoked.
    public func startBundleRecording(
        captureID: String,
        siteID: String? = nil,
        materialCode: String,
        densityKgPerM3: Int,
        pileSizeMode: String? = nil,
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        targetFrameRateHz: Double = 2
    ) throws {
        guard latestSnapshot.status == .running || latestSnapshot.status == .preparing else {
            throw StockpileDevicePoseCaptureError.runtimeFailure(
                "Start ARKit capture before starting markerless bundle recording."
            )
        }

        let trimmedCaptureID = captureID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCaptureID.isEmpty == false else {
            throw StockpileDevicePoseCaptureError.configurationRejected(
                "Capture ID is required to start a markerless bundle recording."
            )
        }
        guard StockpileCaptureBundleMaterialPreset.contains(code: materialCode) else {
            throw StockpileDevicePoseCaptureError.configurationRejected(
                "Select Sand, Gravel, Backfill, Aggregate, Soil, or Other before recording."
            )
        }
        guard StockpileCaptureBundleMaterialPreset.densityIsInSaneBounds(densityKgPerM3) else {
            throw StockpileDevicePoseCaptureError.configurationRejected(
                "Selected material density must be between 300 and 3000 kg/m3."
            )
        }

        let configuration = StockpileCaptureBundleRecorderConfiguration(
            captureID: trimmedCaptureID,
            siteID: siteID,
            materialCode: materialCode,
            densityKgPerM3: densityKgPerM3,
            pileSizeMode: pileSizeMode,
            baseDirectory: baseDirectory,
            targetFrameRateHz: targetFrameRateHz,
            preferSmoothedDepth: latestSnapshot.resolvedConfiguration?.usesSmoothedDepth == true,
            device: StockpileCaptureBundleDeviceMetadata.currentDevice()
        )
        let recorder = try StockpileCaptureBundleRecorder(
            configuration: configuration,
            startedAt: Date()
        )

        let nextSnapshot: StockpileCaptureBundleRecordingSnapshot = bundleLock.withLock {
            switch bundleSnapshot.status {
            case .preparing, .recording, .archiving:
                return bundleSnapshot
            case .idle, .finished, .failed:
                bundleRecorder = recorder
                bundleSnapshot = StockpileCaptureBundleRecordingSnapshot(
                    status: .recording,
                    captureID: trimmedCaptureID,
                    stagingDirectoryURL: recorder.stagingDirectoryURL
                )
                return bundleSnapshot
            }
        }
        publishBundle(nextSnapshot)
    }

    /// Stop the active markerless bundle recording, archive the staging
    /// directory, and deliver the final `.stockpilecapture` URL via `completion`.
    public func stopBundleRecording(
        completion: @escaping @Sendable (Result<StockpileCaptureBundleRecordingOutput, Error>) -> Void
    ) {
        var recorder: StockpileCaptureBundleRecorder?
        var archiveURL: URL?
        var captureID: String?

        let archivingSnapshot: StockpileCaptureBundleRecordingSnapshot? = bundleLock.withLock {
            switch bundleSnapshot.status {
            case .recording:
                recorder = bundleRecorder
                bundleRecorder = nil
                if let recorder {
                    archiveURL = recorder.stagingDirectoryURL
                        .deletingLastPathComponent()
                        .appendingPathComponent("\(recorder.configuration.captureID).stockpilecapture")
                    captureID = recorder.configuration.captureID
                } else {
                    archiveURL = nil
                    captureID = nil
                }
                bundleCompletion = completion
                bundleSnapshot = StockpileCaptureBundleRecordingSnapshot(
                    status: .archiving,
                    captureID: captureID,
                    stagingDirectoryURL: recorder?.stagingDirectoryURL,
                    archiveURL: archiveURL,
                    frameCount: recorder?.frameCount ?? 0,
                    droppedFrameCount: recorder?.droppedFrameCount ?? 0
                )
                return bundleSnapshot
            default:
                recorder = nil
                archiveURL = nil
                captureID = nil
                return nil
            }
        }

        guard let recorder, let archiveURL, let captureID, let archivingSnapshot else {
            completion(
                .failure(
                    StockpileDevicePoseCaptureError.runtimeFailure(
                        "No active markerless bundle recording to stop."
                    )
                )
            )
            return
        }
        publishBundle(archivingSnapshot)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let documents = recorder.buildDocuments()
                _ = try self.bundleArchiver.archive(
                    stagingDirectory: recorder.stagingDirectoryURL,
                    manifest: documents.manifest,
                    poses: documents.poses,
                    anchors: documents.anchors,
                    outputURL: archiveURL
                )
                let archiveSize = (
                    try? FileManager.default
                        .attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber
                )?.int64Value ?? 0
                let output = StockpileCaptureBundleRecordingOutput(
                    captureID: captureID,
                    archiveURL: archiveURL,
                    stagingDirectoryURL: recorder.stagingDirectoryURL,
                    manifest: documents.manifest,
                    poses: documents.poses,
                    anchors: documents.anchors,
                    frameCount: recorder.frameCount,
                    droppedFrameCount: recorder.droppedFrameCount,
                    archiveSizeBytes: archiveSize
                )
                let finishedSnapshot: StockpileCaptureBundleRecordingSnapshot = self.bundleLock.withLock {
                    self.bundleSnapshot = StockpileCaptureBundleRecordingSnapshot(
                        status: .finished,
                        captureID: captureID,
                        stagingDirectoryURL: recorder.stagingDirectoryURL,
                        archiveURL: archiveURL,
                        frameCount: recorder.frameCount,
                        droppedFrameCount: recorder.droppedFrameCount,
                        output: output
                    )
                    self.bundleCompletion = nil
                    return self.bundleSnapshot
                }
                self.publishBundle(finishedSnapshot)
                completion(.success(output))
            } catch {
                let failedSnapshot: StockpileCaptureBundleRecordingSnapshot = self.bundleLock.withLock {
                    self.bundleSnapshot = StockpileCaptureBundleRecordingSnapshot(
                        status: .failed,
                        captureID: captureID,
                        stagingDirectoryURL: recorder.stagingDirectoryURL,
                        archiveURL: archiveURL,
                        frameCount: recorder.frameCount,
                        droppedFrameCount: recorder.droppedFrameCount,
                        issueDescription: error.localizedDescription
                    )
                    self.bundleCompletion = nil
                    return self.bundleSnapshot
                }
                self.publishBundle(failedSnapshot)
                completion(.failure(error))
            }
        }
    }

    private func publishBundle(_ snapshot: StockpileCaptureBundleRecordingSnapshot) {
        onBundleSnapshotUpdated?(snapshot)
    }

    private func appendBundleFrameIfNeeded(
        frame: ARFrame,
        quickVolumeEstimate: StockpileDevicePoseQuickVolumeEstimate?
    ) {
        var activeRecorder: StockpileCaptureBundleRecorder?
        var preferSmoothed = false
        bundleLock.withLock {
            guard bundleSnapshot.status == .recording, let recorder = bundleRecorder else {
                activeRecorder = nil
                return
            }
            activeRecorder = recorder
            preferSmoothed = recorder.configuration.preferSmoothedDepth
        }

        guard let recorder = activeRecorder else { return }
        guard recorder.shouldPersist(frameTimestamp: frame.timestamp) else { return }

        let depthData: ARDepthData?
        let depthIsSmoothed: Bool
        if preferSmoothed, let smoothed = frame.smoothedSceneDepth {
            depthData = smoothed
            depthIsSmoothed = true
        } else if let scene = frame.sceneDepth {
            depthData = scene
            depthIsSmoothed = false
        } else if let smoothed = frame.smoothedSceneDepth {
            depthData = smoothed
            depthIsSmoothed = true
        } else {
            depthData = nil
            depthIsSmoothed = false
        }

        let trackingState = StockpileCaptureBundleTrackingState(frame.camera.trackingState)
        let trackingConfidence = trackingConfidence(for: frame.camera.trackingState)
        let quickEstimate = quickVolumeEstimate.map(StockpileCaptureBundleQuickEstimate.init)

        do {
            let persistedFrameNumber = try recorder.appendFrame(
                capturedImage: frame.capturedImage,
                timestamp: frame.timestamp,
                cameraTransform: frame.camera.transform,
                cameraIntrinsics: frame.camera.intrinsics,
                eulerAngles: frame.camera.eulerAngles,
                trackingState: trackingState,
                trackingConfidence: trackingConfidence,
                depthMap: depthData?.depthMap,
                confidenceMap: depthData?.confidenceMap,
                depthIsSmoothed: depthIsSmoothed,
                quickEstimate: quickEstimate
            )

            guard let persistedFrameNumber else {
                return
            }

            // Track largest horizontal plane anchor as the implicit ground anchor.
            if let largestPlane = frame.anchors
                .compactMap({ $0 as? ARPlaneAnchor })
                .filter({ $0.alignment == .horizontal })
                .max(by: { $0.planeExtent.width * $0.planeExtent.height < $1.planeExtent.width * $1.planeExtent.height })
            {
                recorder.updateGroundAnchor(
                    anchorIdentifier: largestPlane.identifier,
                    transform: largestPlane.transform,
                    extentMeters: StockpileCaptureBundleSize3(
                        width: Double(largestPlane.planeExtent.width),
                        height: 0.0,
                        depth: Double(largestPlane.planeExtent.height)
                    ),
                    observedFrameID: "frame-\(String(format: "%06d", persistedFrameNumber))"
                )
            }

            let updatedSnapshot: StockpileCaptureBundleRecordingSnapshot = bundleLock.withLock {
                bundleSnapshot = StockpileCaptureBundleRecordingSnapshot(
                    status: .recording,
                    captureID: recorder.configuration.captureID,
                    stagingDirectoryURL: recorder.stagingDirectoryURL,
                    frameCount: recorder.frameCount,
                    droppedFrameCount: recorder.droppedFrameCount
                )
                return bundleSnapshot
            }
            publishBundle(updatedSnapshot)
        } catch {
            let failedSnapshot: StockpileCaptureBundleRecordingSnapshot = bundleLock.withLock {
                bundleSnapshot = StockpileCaptureBundleRecordingSnapshot(
                    status: .failed,
                    captureID: recorder.configuration.captureID,
                    stagingDirectoryURL: recorder.stagingDirectoryURL,
                    frameCount: recorder.frameCount,
                    droppedFrameCount: recorder.droppedFrameCount,
                    issueDescription: error.localizedDescription
                )
                bundleRecorder = nil
                return bundleSnapshot
            }
            publishBundle(failedSnapshot)
        }
    }

    private func trackingConfidence(for state: ARCamera.TrackingState) -> Double {
        switch state {
        case .normal:
            return 1.0
        case .limited(let reason):
            switch reason {
            case .initializing:
                return 0.2
            case .relocalizing:
                return 0.3
            case .insufficientFeatures, .excessiveMotion:
                return 0.5
            @unknown default:
                return 0.5
            }
        case .notAvailable:
            return 0.0
        }
    }

    private func publish(
        status: StockpileDevicePoseCaptureStatus,
        capabilities: StockpileDevicePoseCaptureCapabilities,
        configuration: StockpileDevicePoseCaptureConfiguration?,
        resolvedConfiguration: StockpileResolvedDevicePoseCaptureConfiguration?,
        issueDescription: String?,
        sampleCount: Int = 0,
        latestSample: StockpileDevicePoseSample? = nil,
        quickVolumeEstimate: StockpileDevicePoseQuickVolumeEstimate? = nil,
        onDeviceVision: StockpileOnDeviceVisionSummary? = nil,
        startedAt: Date? = nil
    ) {
        let nextSnapshot = StockpileDevicePoseCaptureSnapshot(
            status: status,
            capabilities: capabilities,
            configuration: configuration,
            resolvedConfiguration: resolvedConfiguration,
            sampleCount: sampleCount,
            latestSample: latestSample,
            quickVolumeEstimate: quickVolumeEstimate,
            onDeviceVision: onDeviceVision,
            startedAt: startedAt,
            updatedAt: Date(),
            issueDescription: issueDescription
        )
        lock.withLock {
            snapshot = nextSnapshot
        }
        onSnapshotUpdated?(nextSnapshot)
    }

    private func publishRecording(_ nextSnapshot: StockpileARKitPrimaryRecordingSnapshot) {
        recordingLock.withLock {
            recordingSnapshot = nextSnapshot
        }
        onRecordingSnapshotUpdated?(nextSnapshot)
    }

    private func appendRecordingFrameIfNeeded(
        frame: ARFrame,
        includesDepth: Bool,
        includesOnDeviceVision: Bool
    ) {
        let writer: StockpileARKitPrimaryMovieWriter?
        do {
            writer = try recordingLock.withLock {
                switch recordingSnapshot.status {
                case .preparing, .recording:
                    if let recordingWriter {
                        return recordingWriter
                    }

                    guard let pendingRecordingURL else {
                        return nil
                    }

                    let newWriter = try StockpileARKitPrimaryMovieWriter(
                        outputURL: pendingRecordingURL,
                        firstPixelBuffer: frame.capturedImage,
                        firstTimestamp: frame.timestamp
                    )
                    recordingWriter = newWriter
                    self.pendingRecordingURL = nil
                    recordingSnapshot = StockpileARKitPrimaryRecordingSnapshot(
                        status: .recording,
                        frameCount: recordingFrameCount,
                        droppedFrameCount: droppedRecordingFrameCount,
                        usesSingleCameraOwner: true,
                        includesDepth: recordingIncludesDepth,
                        includesOnDeviceVision: recordingIncludesOnDeviceVision
                    )
                    return newWriter
                case .idle, .finishing, .finished, .failed:
                    return nil
                }
            }
        } catch {
            failActiveRecording(error.localizedDescription)
            return
        }

        guard let writer else {
            return
        }

        let didAppend = writer.append(
            pixelBuffer: frame.capturedImage,
            timestamp: frame.timestamp
        )
        let nextSnapshot = recordingLock.withLock {
            guard recordingSnapshot.status == .recording else {
                return recordingSnapshot
            }

            if didAppend {
                recordingFrameCount += 1
            } else {
                droppedRecordingFrameCount += 1
            }
            recordingIncludesDepth = recordingIncludesDepth || includesDepth
            recordingIncludesOnDeviceVision = recordingIncludesOnDeviceVision || includesOnDeviceVision
            recordingSnapshot = StockpileARKitPrimaryRecordingSnapshot(
                status: .recording,
                frameCount: recordingFrameCount,
                droppedFrameCount: droppedRecordingFrameCount,
                usesSingleCameraOwner: true,
                includesDepth: recordingIncludesDepth,
                includesOnDeviceVision: recordingIncludesOnDeviceVision
            )
            return recordingSnapshot
        }
        onRecordingSnapshotUpdated?(nextSnapshot)
    }

    private func failActiveRecording(_ message: String) {
        let failedSnapshot = recordingLock.withLock {
            recordingWriter = nil
            pendingRecordingURL = nil
            recordingSnapshot = StockpileARKitPrimaryRecordingSnapshot(
                status: .failed,
                frameCount: recordingFrameCount,
                droppedFrameCount: droppedRecordingFrameCount,
                usesSingleCameraOwner: true,
                includesDepth: recordingIncludesDepth,
                includesOnDeviceVision: recordingIncludesOnDeviceVision,
                issueDescription: message
            )
            return recordingSnapshot
        }
        onRecordingSnapshotUpdated?(failedSnapshot)
    }

    private static func currentCapabilities() -> StockpileDevicePoseCaptureCapabilities {
        let supportsWorldTracking = ARWorldTrackingConfiguration.isSupported
        let supportsSceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        let supportsSmoothedSceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
        let supportsSceneMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        return StockpileDevicePoseCaptureCapabilities(
            platformLabel: "iOS",
            supportsWorldTracking: supportsWorldTracking,
            supportsGravityAndHeading: supportsWorldTracking,
            supportsSceneDepth: supportsSceneDepth,
            supportsSmoothedSceneDepth: supportsSmoothedSceneDepth,
            supportsSceneMesh: supportsSceneMesh,
            lidarAssistAvailable: Self.lidarAssistAvailable,
            unavailableReason: supportsWorldTracking ? nil : "ARKit world tracking is unavailable on this device."
        )
    }

    private static var lidarAssistAvailable: Bool {
        #if canImport(AVFoundation)
        AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil
        #else
        false
        #endif
    }
}

extension StockpileARKitDevicePoseCaptureSession: ARSessionDelegate {
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        sampleCount += 1
        let current = latestSnapshot
        let latestSample = StockpileDevicePoseSample(
            sequenceNumber: sampleCount,
            sessionTimestamp: frame.timestamp,
            trackingState: StockpileDevicePoseTrackingState(frame.camera.trackingState),
            transform: StockpileDevicePoseTransform(
                cameraTransform: frame.camera.transform,
                eulerAngles: frame.camera.eulerAngles
            ),
            depthSummary: Self.depthSummary(
                for: frame,
                preferSmoothedDepth: current.resolvedConfiguration?.usesSmoothedDepth == true
            )
        )
        let quickVolumeEstimate = quickVolumeEstimator.update(
            frame: frame,
            preferSmoothedDepth: current.resolvedConfiguration?.usesSmoothedDepth == true
        )
        let onDeviceVision = visionAnalyzer.update(
            frame: frame,
            quickVolumeEstimate: quickVolumeEstimate,
            existingSummary: current.onDeviceVision
        )
        appendRecordingFrameIfNeeded(
            frame: frame,
            includesDepth: latestSample.depthSummary != nil,
            includesOnDeviceVision: onDeviceVision != nil
        )
        appendBundleFrameIfNeeded(
            frame: frame,
            quickVolumeEstimate: quickVolumeEstimate
        )
        publish(
            status: .running,
            capabilities: current.capabilities,
            configuration: current.configuration,
            resolvedConfiguration: current.resolvedConfiguration,
            issueDescription: current.issueDescription,
            sampleCount: sampleCount,
            latestSample: latestSample,
            quickVolumeEstimate: quickVolumeEstimate,
            onDeviceVision: onDeviceVision,
            startedAt: current.startedAt
        )
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        let current = latestSnapshot
        quickVolumeEstimator.reset()
        visionAnalyzer.reset()
        publish(
            status: .interrupted,
            capabilities: current.capabilities,
            configuration: current.configuration,
            resolvedConfiguration: current.resolvedConfiguration,
            issueDescription: "ARKit tracking was interrupted.",
            sampleCount: current.sampleCount,
            latestSample: current.latestSample,
            quickVolumeEstimate: nil,
            onDeviceVision: current.onDeviceVision,
            startedAt: current.startedAt
        )
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        let current = latestSnapshot
        quickVolumeEstimator.reset()
        visionAnalyzer.reset()
        publish(
            status: .preparing,
            capabilities: current.capabilities,
            configuration: current.configuration,
            resolvedConfiguration: current.resolvedConfiguration,
            issueDescription: "Re-establishing device pose tracking.",
            sampleCount: current.sampleCount,
            latestSample: current.latestSample,
            quickVolumeEstimate: nil,
            onDeviceVision: current.onDeviceVision,
            startedAt: current.startedAt
        )
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        let current = latestSnapshot
        quickVolumeEstimator.reset()
        visionAnalyzer.reset()
        publish(
            status: .failed,
            capabilities: current.capabilities,
            configuration: current.configuration,
            resolvedConfiguration: current.resolvedConfiguration,
            issueDescription: error.localizedDescription,
            sampleCount: current.sampleCount,
            latestSample: current.latestSample,
            quickVolumeEstimate: nil,
            onDeviceVision: current.onDeviceVision,
            startedAt: current.startedAt
        )
    }

    private static func depthSummary(
        for frame: ARFrame,
        preferSmoothedDepth: Bool
    ) -> StockpileDevicePoseDepthSummary? {
        if preferSmoothedDepth, let smoothedDepth = frame.smoothedSceneDepth {
            return StockpileDevicePoseDepthSummary(
                width: CVPixelBufferGetWidth(smoothedDepth.depthMap),
                height: CVPixelBufferGetHeight(smoothedDepth.depthMap),
                isSmoothed: true
            )
        }

        if let sceneDepth = frame.sceneDepth {
            return StockpileDevicePoseDepthSummary(
                width: CVPixelBufferGetWidth(sceneDepth.depthMap),
                height: CVPixelBufferGetHeight(sceneDepth.depthMap),
                isSmoothed: false
            )
        }

        return nil
    }
}

private final class StockpileARKitPrimaryMovieWriter: @unchecked Sendable {
    let outputURL: URL

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let firstTimestamp: TimeInterval

    init(
        outputURL: URL,
        firstPixelBuffer: CVPixelBuffer,
        firstTimestamp: TimeInterval
    ) throws {
        self.outputURL = outputURL
        self.firstTimestamp = firstTimestamp

        let width = CVPixelBufferGetWidth(firstPixelBuffer)
        let height = CVPixelBufferGetHeight(firstPixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(firstPixelBuffer)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(width * height * 5, 2_500_000),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.canAdd(input) else {
            throw StockpileARKitPrimaryMovieWriterError.cannotAddVideoInput
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw StockpileARKitPrimaryMovieWriterError.startFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> Bool {
        guard writer.status == .writing,
              input.isReadyForMoreMediaData else {
            return false
        }

        let presentationTime = CMTime(
            seconds: max(0, timestamp - firstTimestamp),
            preferredTimescale: 600
        )
        return adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
    }

    func finish(completion: @escaping @Sendable (Result<Int64, Error>) -> Void) {
        input.markAsFinished()
        writer.finishWriting { [self] in
            switch writer.status {
            case .completed:
                let size = (
                    try? FileManager.default
                        .attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
                )?.int64Value ?? 0
                completion(.success(size))
            default:
                completion(.failure(StockpileARKitPrimaryMovieWriterError.finishFailed(writer.error)))
            }
        }
    }
}

private enum StockpileARKitPrimaryMovieWriterError: LocalizedError {
    case cannotAddVideoInput
    case startFailed(Error?)
    case finishFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .cannotAddVideoInput:
            return "ARKit-primary recording could not add a video input."
        case let .startFailed(error):
            return error?.localizedDescription ?? "ARKit-primary recording could not start writing."
        case let .finishFailed(error):
            return error?.localizedDescription ?? "ARKit-primary recording could not finish writing."
        }
    }
}

private final class StockpileARKitOnDeviceVisionAnalyzer: @unchecked Sendable {
    private struct SendablePixelBuffer: @unchecked Sendable {
        let value: CVPixelBuffer
    }

    private struct ForegroundMaskStats {
        let foregroundRatio: Double
        let lowerFrameRatio: Double
        let toeBandRatio: Double
        let horizontalSpread: Double
        let centeredness: Double
        let bottomReach: Double
    }

    private struct MaterialMatch {
        let code: String
        let label: String
        let confidence: Double
    }

    private let analysisQueue = DispatchQueue(label: "com.stockpile.capture.arkit.on-device-vision")
    private let minimumVisionIntervalSec: TimeInterval = 0.75
    private let stateLock = NSLock()
    private var lastVisionTimestamp: TimeInterval?
    private var latestSummary: StockpileOnDeviceVisionSummary?
    private var analysisInFlight = false
    private var analysisGeneration = 0

    func reset() {
        stateLock.withLock {
            lastVisionTimestamp = nil
            latestSummary = nil
            analysisInFlight = false
            analysisGeneration += 1
        }
    }

    func update(
        frame: ARFrame,
        quickVolumeEstimate: StockpileDevicePoseQuickVolumeEstimate?,
        existingSummary: StockpileOnDeviceVisionSummary?
    ) -> StockpileOnDeviceVisionSummary? {
        let fallbackSummary = depthFallbackSummary(from: quickVolumeEstimate)
        let pixelBuffer = SendablePixelBuffer(value: frame.capturedImage)
        let timestamp = frame.timestamp

        let decision = stateLock.withLock { () -> (
            shouldStartAnalysis: Bool,
            generation: Int,
            immediateSummary: StockpileOnDeviceVisionSummary?
        ) in
            let immediateSummary = latestSummary ?? existingSummary ?? fallbackSummary
            guard shouldAnalyze(timestamp: timestamp), analysisInFlight == false else {
                return (
                    shouldStartAnalysis: false,
                    generation: analysisGeneration,
                    immediateSummary: immediateSummary
                )
            }

            lastVisionTimestamp = timestamp
            analysisInFlight = true
            return (
                shouldStartAnalysis: true,
                generation: analysisGeneration,
                immediateSummary: immediateSummary
            )
        }

        if decision.shouldStartAnalysis {
            let orientation = Self.currentVisionOrientation()
            analysisQueue.async { [weak self] in
                guard let self else { return }
                let analyzedSummary = self.analyze(
                    pixelBuffer: pixelBuffer,
                    orientation: orientation,
                    quickVolumeEstimate: quickVolumeEstimate
                )
                self.stateLock.withLock {
                    guard decision.generation == self.analysisGeneration else {
                        return
                    }
                    self.analysisInFlight = false
                    self.latestSummary = analyzedSummary ?? self.latestSummary ?? existingSummary ?? fallbackSummary
                }
            }
        }

        return decision.immediateSummary
    }

    private func shouldAnalyze(timestamp: TimeInterval) -> Bool {
        guard let lastVisionTimestamp else {
            return true
        }

        return timestamp - lastVisionTimestamp >= minimumVisionIntervalSec
    }

    private func analyze(
        pixelBuffer: SendablePixelBuffer,
        orientation: CGImagePropertyOrientation,
        quickVolumeEstimate: StockpileDevicePoseQuickVolumeEstimate?
    ) -> StockpileOnDeviceVisionSummary? {
        #if canImport(Vision)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer.value, orientation: orientation)
        let segmentationRequest = VNGenerateForegroundInstanceMaskRequest()
        let classificationRequest = VNClassifyImageRequest()

        do {
            try handler.perform([segmentationRequest, classificationRequest])
        } catch {
            return depthFallbackSummary(from: quickVolumeEstimate)
        }

        let stats = foregroundStats(
            from: segmentationRequest.results?.first,
            handler: handler
        )
        let materialMatch = materialMatch(from: classificationRequest.results ?? [])
        guard stats != nil || materialMatch != nil || quickVolumeEstimate != nil else {
            return nil
        }

        let pileScore = stats.map { stats in
            clamp(
                stats.foregroundRatio * 0.30
                    + stats.lowerFrameRatio * 0.24
                    + stats.horizontalSpread * 0.18
                    + stats.centeredness * 0.12
                    + stats.bottomReach * 0.16
            )
        }
        let toeScore = stats.map { stats in
            clamp(
                stats.toeBandRatio * 0.46
                    + stats.lowerFrameRatio * 0.22
                    + stats.bottomReach * 0.18
                    + stats.horizontalSpread * 0.14
            )
        }
        let quickConfidence = quickVolumeEstimate?.confidenceScore
        let segmentationConfidence = combinedConfidence(
            pileScore: pileScore,
            toeScore: toeScore,
            quickConfidence: quickConfidence
        )

        return StockpileOnDeviceVisionSummary(
            source: stats == nil ? .visionImageClassifier : .visionForegroundInstanceMask,
            usesMachineLearning: true,
            pileSegmentationScore: pileScore,
            toeSegmentationScore: toeScore,
            segmentationConfidenceScore: segmentationConfidence,
            foregroundCoverageRatio: stats?.foregroundRatio,
            lowerFrameOccupancyRatio: stats?.lowerFrameRatio,
            materialFamilyCode: materialMatch?.code,
            materialFamilyLabel: materialMatch?.label,
            materialConfidenceScore: materialMatch?.confidence,
            guidanceHint: guidanceHint(
                pileScore: pileScore,
                toeScore: toeScore,
                materialMatch: materialMatch
            )
        )
        #else
        return depthFallbackSummary(from: quickVolumeEstimate)
        #endif
    }

    private static func currentVisionOrientation() -> CGImagePropertyOrientation {
        #if canImport(UIKit)
        let deviceOrientation: UIDeviceOrientation
        if Thread.isMainThread {
            deviceOrientation = MainActor.assumeIsolated {
                UIDevice.current.orientation
            }
        } else {
            var mainThreadOrientation = UIDeviceOrientation.unknown
            DispatchQueue.main.sync {
                mainThreadOrientation = MainActor.assumeIsolated {
                    UIDevice.current.orientation
                }
            }
            deviceOrientation = mainThreadOrientation
        }

        switch deviceOrientation {
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeRight:
            return .down
        case .landscapeLeft:
            return .up
        default:
            return .right
        }
        #else
        return .right
        #endif
    }

    #if canImport(Vision)
    private func foregroundStats(
        from observation: VNInstanceMaskObservation?,
        handler: VNImageRequestHandler
    ) -> ForegroundMaskStats? {
        guard let observation else {
            return nil
        }

        let maskBuffer: CVPixelBuffer
        do {
            maskBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
        } catch {
            return nil
        }

        let stats = foregroundMaskStats(from: maskBuffer)
        guard stats.foregroundRatio >= 0.03 || stats.lowerFrameRatio >= 0.07 else {
            return nil
        }

        return stats
    }

    private func materialMatch(
        from classifications: [VNClassificationObservation]
    ) -> MaterialMatch? {
        let families: [(code: String, label: String, keywords: [(String, Double)])] = [
            (
                code: "aggregate_rock",
                label: "Coarse aggregate / rock",
                keywords: [
                    ("gravel", 1.0),
                    ("pebble", 0.94),
                    ("rock", 0.9),
                    ("stone", 0.86),
                    ("boulder", 0.78),
                    ("quarry", 0.76)
                ]
            ),
            (
                code: "sand_soil_fines",
                label: "Sand / soil / fines",
                keywords: [
                    ("sand", 1.0),
                    ("soil", 0.92),
                    ("earth", 0.88),
                    ("dirt", 0.84),
                    ("mud", 0.78),
                    ("ground", 0.72)
                ]
            ),
            (
                code: "asphalt_dark_fines",
                label: "Asphalt / dark fines",
                keywords: [
                    ("asphalt", 1.0),
                    ("pavement", 0.86),
                    ("road", 0.78),
                    ("tar", 0.76),
                    ("charcoal", 0.68)
                ]
            )
        ]

        var bestMatch: MaterialMatch?
        for classification in classifications.prefix(8) {
            let identifier = classification.identifier.lowercased()
            for family in families {
                for keyword in family.keywords where identifier.contains(keyword.0) {
                    let confidence = clamp(Double(classification.confidence) * keyword.1)
                    if confidence > (bestMatch?.confidence ?? 0) {
                        bestMatch = MaterialMatch(
                            code: family.code,
                            label: family.label,
                            confidence: confidence
                        )
                    }
                }
            }
        }

        guard let bestMatch, bestMatch.confidence >= 0.18 else {
            return nil
        }
        return bestMatch
    }
    #endif

    private func foregroundMaskStats(from pixelBuffer: CVPixelBuffer) -> ForegroundMaskStats {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              width > 0,
              height > 0 else {
            return ForegroundMaskStats(
                foregroundRatio: 0,
                lowerFrameRatio: 0,
                toeBandRatio: 0,
                horizontalSpread: 0,
                centeredness: 0,
                bottomReach: 0
            )
        }

        let columns = 24
        let rows = 18
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let floatPointer = baseAddress.assumingMemoryBound(to: Float32.self)
        let unsignedPointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.stride
        let foregroundThreshold = pixelFormat == kCVPixelFormatType_OneComponent32Float ? 0.12 : 0.08

        var foregroundSamples = 0
        var lowerForegroundSamples = 0
        var toeForegroundSamples = 0
        var lowerTotalSamples = 0
        var toeTotalSamples = 0
        var occupiedColumns = Set<Int>()
        var weightedCenterX = 0.0
        var bottomReach = 0.0

        func sampleValue(x: Int, y: Int) -> Double {
            switch pixelFormat {
            case kCVPixelFormatType_OneComponent32Float:
                return clamp(Double(floatPointer[y * floatsPerRow + x]))
            default:
                return clamp(Double(unsignedPointer[y * bytesPerRow + x]) / 255.0)
            }
        }

        for row in 0..<rows {
            let normalizedY = (Double(row) + 0.5) / Double(rows)
            let pixelY = min(max(Int(normalizedY * Double(height)), 0), max(height - 1, 0))
            if normalizedY >= 0.58 {
                lowerTotalSamples += columns
            }
            if normalizedY >= 0.78 {
                toeTotalSamples += columns
            }

            for column in 0..<columns {
                let normalizedX = (Double(column) + 0.5) / Double(columns)
                let pixelX = min(max(Int(normalizedX * Double(width)), 0), max(width - 1, 0))
                guard sampleValue(x: pixelX, y: pixelY) >= foregroundThreshold else {
                    continue
                }

                foregroundSamples += 1
                occupiedColumns.insert(column)
                weightedCenterX += normalizedX
                bottomReach = max(bottomReach, normalizedY)

                if normalizedY >= 0.58 {
                    lowerForegroundSamples += 1
                }
                if normalizedY >= 0.78 {
                    toeForegroundSamples += 1
                }
            }
        }

        let totalSamples = max(columns * rows, 1)
        let foregroundRatio = Double(foregroundSamples) / Double(totalSamples)
        let lowerFrameRatio = lowerTotalSamples > 0
            ? Double(lowerForegroundSamples) / Double(lowerTotalSamples)
            : 0
        let toeBandRatio = toeTotalSamples > 0
            ? Double(toeForegroundSamples) / Double(toeTotalSamples)
            : 0
        let horizontalSpread = Double(occupiedColumns.count) / Double(columns)
        let centerOfMassX = foregroundSamples > 0
            ? weightedCenterX / Double(foregroundSamples)
            : 0.5
        let centeredness = clamp(1 - abs(centerOfMassX - 0.5) / 0.5)

        return ForegroundMaskStats(
            foregroundRatio: foregroundRatio,
            lowerFrameRatio: lowerFrameRatio,
            toeBandRatio: toeBandRatio,
            horizontalSpread: horizontalSpread,
            centeredness: centeredness,
            bottomReach: bottomReach
        )
    }

    private func depthFallbackSummary(
        from quickVolumeEstimate: StockpileDevicePoseQuickVolumeEstimate?
    ) -> StockpileOnDeviceVisionSummary? {
        guard let quickVolumeEstimate else {
            return nil
        }

        let confidence = quickVolumeEstimate.confidenceScore
        return StockpileOnDeviceVisionSummary(
            source: .depthHeuristic,
            usesMachineLearning: false,
            pileSegmentationScore: confidence,
            toeSegmentationScore: min(confidence * 0.92, 1),
            segmentationConfidenceScore: confidence,
            materialFamilyCode: nil,
            materialFamilyLabel: nil,
            materialConfidenceScore: nil,
            guidanceHint: "Depth is available; keep the pile toe visible for stronger segmentation."
        )
    }

    private func combinedConfidence(
        pileScore: Double?,
        toeScore: Double?,
        quickConfidence: Double?
    ) -> Double? {
        let scores = [pileScore, toeScore, quickConfidence].compactMap { $0 }
        guard scores.isEmpty == false else {
            return nil
        }

        return scores.reduce(0, +) / Double(scores.count)
    }

    private func guidanceHint(
        pileScore: Double?,
        toeScore: Double?,
        materialMatch: MaterialMatch?
    ) -> String? {
        if let toeScore, toeScore < 0.55 {
            return "Lower the phone slightly and keep the pile toe in the lower third."
        }

        if let pileScore, pileScore < 0.55 {
            return "Keep the segmented pile face centered and let it fill more of the frame."
        }

        if let materialMatch {
            return "Material looks like \(materialMatch.label.lowercased()); keep one slow lap for backend verification."
        }

        return nil
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private extension StockpileDevicePoseWorldAlignment {
    var arWorldAlignment: ARConfiguration.WorldAlignment {
        switch self {
        case .gravity:
            return .gravity
        case .gravityAndHeading:
            return .gravityAndHeading
        }
    }
}

private extension StockpileCaptureBundleTrackingState {
    init(_ trackingState: ARCamera.TrackingState) {
        switch trackingState {
        case .notAvailable:
            self = .unavailable
        case .normal:
            self = .normal
        case let .limited(reason):
            switch reason {
            case .relocalizing:
                self = .relocalizing
            default:
                self = .limited
            }
        @unknown default:
            self = .limited
        }
    }
}

private extension StockpileDevicePoseTrackingState {
    init(_ trackingState: ARCamera.TrackingState) {
        switch trackingState {
        case .notAvailable:
            self.init(phase: .unavailable, detail: "Tracking is unavailable.")
        case .normal:
            self.init(phase: .tracking)
        case let .limited(reason):
            switch reason {
            case .initializing:
                self.init(phase: .initializing, detail: "Initializing world tracking.")
            case .relocalizing:
                self.init(phase: .relocalizing, detail: "Relocalizing against the scene.")
            case .excessiveMotion:
                self.init(phase: .limited, detail: "Excessive motion is reducing pose confidence.")
            case .insufficientFeatures:
                self.init(phase: .limited, detail: "The scene needs more visual features.")
            @unknown default:
                self.init(phase: .limited, detail: "Tracking is limited.")
            }
        }
    }
}

private extension StockpileDevicePoseTransform {
    init(cameraTransform: simd_float4x4, eulerAngles: simd_float3) {
        let matrix = [
            cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z, cameraTransform.columns.0.w,
            cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z, cameraTransform.columns.1.w,
            cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z, cameraTransform.columns.2.w,
            cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z, cameraTransform.columns.3.w,
        ]
        self.init(
            matrix: matrix,
            translationMeters: StockpileDevicePoseVector3(
                x: cameraTransform.columns.3.x,
                y: cameraTransform.columns.3.y,
                z: cameraTransform.columns.3.z
            ),
            eulerAnglesRadians: StockpileDevicePoseVector3(
                x: eulerAngles.x,
                y: eulerAngles.y,
                z: eulerAngles.z
            )
        )
    }
}

private extension NSLock {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}
#else
public final class StockpileARKitDevicePoseCaptureSession: StockpileDevicePoseCaptureSession {
    public var capabilities: StockpileDevicePoseCaptureCapabilities
    public var latestSnapshot: StockpileDevicePoseCaptureSnapshot
    public private(set) var latestRecordingSnapshot = StockpileARKitPrimaryRecordingSnapshot.idle
    public var onSnapshotUpdated: (@Sendable (StockpileDevicePoseCaptureSnapshot) -> Void)?
    public var onRecordingSnapshotUpdated: (@Sendable (StockpileARKitPrimaryRecordingSnapshot) -> Void)?

    public init() {
        let capabilities = StockpileDevicePoseCaptureCapabilities(
            platformLabel: "Unsupported",
            supportsWorldTracking: false,
            supportsGravityAndHeading: false,
            supportsSceneDepth: false,
            supportsSmoothedSceneDepth: false,
            supportsSceneMesh: false,
            lidarAssistAvailable: false,
            unavailableReason: "ARKit world tracking is available only in the iOS app runtime."
        )
        self.capabilities = capabilities
        self.latestSnapshot = StockpileDevicePoseCaptureSnapshot(
            status: .unavailable,
            capabilities: capabilities,
            issueDescription: capabilities.unavailableReason
        )
    }

    public func start(configuration _: StockpileDevicePoseCaptureConfiguration) throws {
        throw StockpileDevicePoseCaptureError.unavailable(
            capabilities.unavailableReason ?? "ARKit device pose capture is unavailable."
        )
    }

    public func startRecording(to _: URL) throws {
        let message = "ARKit primary recording is available only in the iOS app runtime."
        latestRecordingSnapshot = StockpileARKitPrimaryRecordingSnapshot(
            status: .failed,
            usesSingleCameraOwner: true,
            issueDescription: message
        )
        onRecordingSnapshotUpdated?(latestRecordingSnapshot)
        throw StockpileDevicePoseCaptureError.unavailable(message)
    }

    public func stopRecording() {}

    public func stop() {}
}
#endif
