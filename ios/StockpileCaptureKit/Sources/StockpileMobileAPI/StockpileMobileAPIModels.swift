import Foundation

public enum StockpileMobileAPINamespace {}

public enum StockpileRunOutcome: String, Codable, Sendable {
    case verified
    case reviewOnly = "review_only"
    case blocked
}

public enum StockpileJobPhase: String, Codable, Sendable {
    case queued
    case uploadAuthorized = "upload_authorized"
    case uploadReceived = "upload_received"
    case extractingFrames = "extracting_frames"
    case detectingReferences = "detecting_references"
    case reconstructing
    case calibrating
    case computingVolume = "computing_volume"
    case verified
    case reviewOnly = "review_only"
    case blocked
    case failed

    public var isTerminal: Bool {
        switch self {
        case .verified, .reviewOnly, .blocked, .failed:
            return true
        default:
            return false
        }
    }
}

public struct StockpileTaggedReferenceStrategyPayload: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case concurrentVisibility = "concurrent_visibility"
    }

    public let mode: Mode
    public let referenceCountGoal: Int
    public let minimumVisibleReferenceCount: Int
    public let preferredVisibleReferenceCount: Int

    public init(
        mode: Mode,
        referenceCountGoal: Int,
        minimumVisibleReferenceCount: Int,
        preferredVisibleReferenceCount: Int
    ) {
        self.mode = mode
        self.referenceCountGoal = max(0, referenceCountGoal)
        self.minimumVisibleReferenceCount = max(0, minimumVisibleReferenceCount)
        self.preferredVisibleReferenceCount = max(0, preferredVisibleReferenceCount)
    }
}

public enum StockpileCaptureSourcePayload: String, Codable, Sendable {
    case liveRecordedVideo = "live_recorded_video"
    case importedVideo = "imported_video"
    case fallbackVideo = "fallback_video"
}

public enum StockpileCaptureModePayload: String, Codable, Sendable {
    case guidedWalkaround = "guided_walkaround"
}

public enum StockpileReferenceMarkerQualityPayload: String, Codable, Sendable {
    case confirmed
    case weak
    case missing
}

public enum StockpileMobileFirstCaptureStagePayload: String, Codable, Sendable {
    case ready
    case acquiringReferences = "acquiring_references"
    case walkingPerimeter = "walking_perimeter"
    case sealingCapture = "sealing_capture"
    case uploading
    case provisionalResult = "provisional_result"
    case reviewQueue = "review_queue"
    case recaptureRequired = "recapture_required"
}

public struct StockpileCaptureMetadataPayload: Codable, Sendable, Equatable {
    public let source: StockpileCaptureSourcePayload
    public let mode: StockpileCaptureModePayload
    public let startedAt: Date?
    public let completedAt: Date?
    public let timeZoneIdentifier: String
    public let activeDeviceName: String?
    public let capturePhase: String?
    public let sessionLifecycle: String?
    public let recordingLifecycle: String?
    public let sensorMetadata: StockpileCaptureSensorMetadataPayload?

    public init(
        source: StockpileCaptureSourcePayload,
        mode: StockpileCaptureModePayload,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        timeZoneIdentifier: String,
        activeDeviceName: String? = nil,
        capturePhase: String? = nil,
        sessionLifecycle: String? = nil,
        recordingLifecycle: String? = nil,
        sensorMetadata: StockpileCaptureSensorMetadataPayload? = nil
    ) {
        self.source = source
        self.mode = mode
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.activeDeviceName = activeDeviceName
        self.capturePhase = capturePhase
        self.sessionLifecycle = sessionLifecycle
        self.recordingLifecycle = recordingLifecycle
        self.sensorMetadata = sensorMetadata
    }
}

public struct StockpileCaptureSensorMetadataPayload: Codable, Sendable, Equatable {
    public let deviceModelIdentifier: String?
    public let videoWidth: Int?
    public let videoHeight: Int?
    public let videoFrameRate: Double?
    public let poseSamplingHz: Double?
    public let depthDataIncluded: Bool?
    public let worldAlignment: String?
    public let videoStabilizationMode: String?

    public init(
        deviceModelIdentifier: String? = nil,
        videoWidth: Int? = nil,
        videoHeight: Int? = nil,
        videoFrameRate: Double? = nil,
        poseSamplingHz: Double? = nil,
        depthDataIncluded: Bool? = nil,
        worldAlignment: String? = nil,
        videoStabilizationMode: String? = nil
    ) {
        self.deviceModelIdentifier = deviceModelIdentifier
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFrameRate = videoFrameRate
        self.poseSamplingHz = poseSamplingHz
        self.depthDataIncluded = depthDataIncluded
        self.worldAlignment = worldAlignment
        self.videoStabilizationMode = videoStabilizationMode
    }
}

public struct StockpileDeviceSensorInputPayload: Codable, Sendable, Equatable {
    public let motionSignalsIncluded: Bool
    public let gravityVectorIncluded: Bool
    public let headingSignalsIncluded: Bool
    public let cameraCalibrationIncluded: Bool

    public init(
        motionSignalsIncluded: Bool,
        gravityVectorIncluded: Bool,
        headingSignalsIncluded: Bool,
        cameraCalibrationIncluded: Bool
    ) {
        self.motionSignalsIncluded = motionSignalsIncluded
        self.gravityVectorIncluded = gravityVectorIncluded
        self.headingSignalsIncluded = headingSignalsIncluded
        self.cameraCalibrationIncluded = cameraCalibrationIncluded
    }

    public static let reserved = StockpileDeviceSensorInputPayload(
        motionSignalsIncluded: false,
        gravityVectorIncluded: false,
        headingSignalsIncluded: false,
        cameraCalibrationIncluded: false
    )
}

public struct StockpileReferenceMarkerSnapshotPayload: Codable, Sendable, Equatable, Identifiable {
    public let markerID: String
    public let visibleCount: Int
    public let confidence: Double
    public let quality: StockpileReferenceMarkerQualityPayload

    public var id: String { markerID }

    public init(
        markerID: String,
        visibleCount: Int,
        confidence: Double,
        quality: StockpileReferenceMarkerQualityPayload
    ) {
        self.markerID = markerID
        self.visibleCount = max(0, visibleCount)
        self.confidence = min(max(confidence, 0), 1)
        self.quality = quality
    }

    enum CodingKeys: String, CodingKey {
        case markerID = "markerId"
        case visibleCount
        case confidence
        case quality
    }
}

public struct StockpileDevicePoseTelemetryPayload: Codable, Sendable, Equatable {
    public let sampleCount: Int?
    public let motionStable: Bool?
    public let headingStable: Bool?
    public let lidarAssistAvailable: Bool?
    public let trackingState: String?

    public init(
        sampleCount: Int? = nil,
        motionStable: Bool? = nil,
        headingStable: Bool? = nil,
        lidarAssistAvailable: Bool? = nil,
        trackingState: String? = nil
    ) {
        self.sampleCount = sampleCount.map { max(0, $0) }
        self.motionStable = motionStable
        self.headingStable = headingStable
        self.lidarAssistAvailable = lidarAssistAvailable
        self.trackingState = trackingState
    }
}

public struct StockpileVector3Payload: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct StockpileQuaternionPayload: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double
    public let w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }
}

public struct StockpileDevicePoseSamplePayload: Codable, Sendable, Equatable {
    public let sampleIndex: Int
    public let timeOffsetSec: Double
    public let capturedAt: Date?
    public let positionM: StockpileVector3Payload?
    public let orientationQuaternion: StockpileQuaternionPayload?
    public let gravityVector: StockpileVector3Payload?
    public let headingDegrees: Double?
    public let trackingState: String?
    public let yawPitchRollDeg: StockpileVector3Payload?
    public let horizontalAccuracyM: Double?
    public let verticalAccuracyM: Double?

    public init(
        sampleIndex: Int,
        timeOffsetSec: Double,
        capturedAt: Date? = nil,
        positionM: StockpileVector3Payload? = nil,
        orientationQuaternion: StockpileQuaternionPayload? = nil,
        gravityVector: StockpileVector3Payload? = nil,
        headingDegrees: Double? = nil,
        trackingState: String? = nil,
        yawPitchRollDeg: StockpileVector3Payload? = nil,
        horizontalAccuracyM: Double? = nil,
        verticalAccuracyM: Double? = nil
    ) {
        self.sampleIndex = max(0, sampleIndex)
        self.timeOffsetSec = timeOffsetSec
        self.capturedAt = capturedAt
        self.positionM = positionM
        self.orientationQuaternion = orientationQuaternion
        self.gravityVector = gravityVector
        self.headingDegrees = headingDegrees
        self.trackingState = trackingState
        self.yawPitchRollDeg = yawPitchRollDeg
        self.horizontalAccuracyM = horizontalAccuracyM
        self.verticalAccuracyM = verticalAccuracyM
    }
}

public struct StockpileReferenceObservationPayload: Codable, Sendable, Equatable {
    public let referenceID: String
    public let family: String
    public let frameTimeSec: Double?
    public let capturedAt: Date?
    public let poseSampleIndex: Int?
    public let decisionMargin: Double?
    public let hamming: Int?
    public let edgeLengthPx: Double?
    public let frameID: String?
    public let pixelAreaPx: Double?
    public let confidence: Double?
    public let estimatedDistanceM: Double?
    public let state: StockpileReferenceMarkerQualityPayload?

    public init(
        referenceID: String,
        family: String = "unspecified",
        frameTimeSec: Double? = nil,
        capturedAt: Date? = nil,
        poseSampleIndex: Int? = nil,
        decisionMargin: Double? = nil,
        hamming: Int? = nil,
        edgeLengthPx: Double? = nil,
        frameID: String? = nil,
        pixelAreaPx: Double? = nil,
        confidence: Double? = nil,
        estimatedDistanceM: Double? = nil,
        state: StockpileReferenceMarkerQualityPayload? = nil
    ) {
        self.referenceID = referenceID
        self.family = family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unspecified" : family
        self.frameTimeSec = frameTimeSec
        self.capturedAt = capturedAt
        self.poseSampleIndex = poseSampleIndex.map { max(0, $0) }
        self.decisionMargin = decisionMargin
        self.hamming = hamming.map { max(0, $0) }
        self.edgeLengthPx = edgeLengthPx
        self.frameID = frameID
        self.pixelAreaPx = pixelAreaPx
        self.confidence = confidence.map { min(max($0, 0), 1) }
        self.estimatedDistanceM = estimatedDistanceM
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case referenceID = "referenceId"
        case family
        case frameTimeSec
        case capturedAt
        case poseSampleIndex
        case decisionMargin
        case hamming
        case edgeLengthPx
        case frameID = "frameId"
        case pixelAreaPx
        case confidence
        case estimatedDistanceM
        case state
    }
}

public struct StockpileMaterialSuggestionPayload: Codable, Sendable, Equatable {
    public let materialCode: String?
    public let label: String?
    public let confidence: Double?
    public let source: String?

    public init(
        materialCode: String? = nil,
        label: String? = nil,
        confidence: Double? = nil,
        source: String? = nil
    ) {
        let normalizedMaterialCode = materialCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.materialCode = normalizedMaterialCode?.isEmpty == false ? normalizedMaterialCode : nil
        self.label = normalizedLabel?.isEmpty == false ? normalizedLabel : nil
        self.confidence = confidence.map { min(max($0, 0), 1) }
        self.source = normalizedSource?.isEmpty == false ? normalizedSource : nil
    }
}

public struct StockpileReferenceEvidenceJPEGFramePayload: Codable, Sendable, Equatable {
    public let frameID: String
    public let timeOffsetSec: Double
    public let poseSampleIndex: Int?
    public let capturedAt: Date?
    public let widthPx: Int
    public let heightPx: Int
    public let jpegBase64: String

    public init(
        frameID: String,
        timeOffsetSec: Double,
        poseSampleIndex: Int? = nil,
        capturedAt: Date? = nil,
        widthPx: Int,
        heightPx: Int,
        jpegBase64: String
    ) {
        self.frameID = frameID
        self.timeOffsetSec = timeOffsetSec
        self.poseSampleIndex = poseSampleIndex.map { max(0, $0) }
        self.capturedAt = capturedAt
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.jpegBase64 = jpegBase64
    }

    enum CodingKeys: String, CodingKey {
        case frameID = "frameId"
        case timeOffsetSec
        case poseSampleIndex
        case capturedAt
        case widthPx
        case heightPx
        case jpegBase64
    }
}

public struct StockpileOnDeviceVisionPayload: Codable, Sendable, Equatable {
    public let source: String
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
        source: String,
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
        self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        self.usesMachineLearning = usesMachineLearning
        self.pileSegmentationScore = pileSegmentationScore.map { min(max($0, 0), 1) }
        self.toeSegmentationScore = toeSegmentationScore.map { min(max($0, 0), 1) }
        self.segmentationConfidenceScore = segmentationConfidenceScore.map { min(max($0, 0), 1) }
        self.foregroundCoverageRatio = foregroundCoverageRatio.map { min(max($0, 0), 1) }
        self.lowerFrameOccupancyRatio = lowerFrameOccupancyRatio.map { min(max($0, 0), 1) }
        self.materialFamilyCode = materialFamilyCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.materialFamilyLabel = materialFamilyLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.materialConfidenceScore = materialConfidenceScore.map { min(max($0, 0), 1) }
        self.guidanceHint = guidanceHint?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct StockpileMobileFirstCapturePayload: Codable, Sendable, Equatable {
    public let stage: StockpileMobileFirstCaptureStagePayload
    public let referenceMarkerSnapshots: [StockpileReferenceMarkerSnapshotPayload]
    public let nativeReferenceObservations: [StockpileReferenceObservationPayload]
    public let materialSuggestion: StockpileMaterialSuggestionPayload?
    public let onDeviceVision: StockpileOnDeviceVisionPayload?
    public let devicePoseTelemetry: StockpileDevicePoseTelemetryPayload?
    public let toeCoverageScore: Double?
    public let pileSegmentationScore: Double?
    public let toeSegmentationScore: Double?
    public let segmentationConfidenceScore: Double?
    public let estimatedConcurrentReferenceCount: Int?
    public let quickVolumeM3: Double?
    public let quickFootprintAreaM2: Double?
    public let quickPeakHeightM: Double?
    public let quickConfidenceScore: Double?
    public let quickGeometryPointCount: Int?
    public let quickCameraPathDistanceM: Double?

    public init(
        stage: StockpileMobileFirstCaptureStagePayload,
        referenceMarkerSnapshots: [StockpileReferenceMarkerSnapshotPayload] = [],
        nativeReferenceObservations: [StockpileReferenceObservationPayload] = [],
        materialSuggestion: StockpileMaterialSuggestionPayload? = nil,
        onDeviceVision: StockpileOnDeviceVisionPayload? = nil,
        devicePoseTelemetry: StockpileDevicePoseTelemetryPayload? = nil,
        toeCoverageScore: Double? = nil,
        pileSegmentationScore: Double? = nil,
        toeSegmentationScore: Double? = nil,
        segmentationConfidenceScore: Double? = nil,
        estimatedConcurrentReferenceCount: Int? = nil,
        quickVolumeM3: Double? = nil,
        quickFootprintAreaM2: Double? = nil,
        quickPeakHeightM: Double? = nil,
        quickConfidenceScore: Double? = nil,
        quickGeometryPointCount: Int? = nil,
        quickCameraPathDistanceM: Double? = nil
    ) {
        self.stage = stage
        self.referenceMarkerSnapshots = referenceMarkerSnapshots
        self.nativeReferenceObservations = nativeReferenceObservations
        self.materialSuggestion = materialSuggestion
        self.onDeviceVision = onDeviceVision
        self.devicePoseTelemetry = devicePoseTelemetry
        self.toeCoverageScore = toeCoverageScore
        self.pileSegmentationScore = pileSegmentationScore.map { min(max($0, 0), 1) }
        self.toeSegmentationScore = toeSegmentationScore.map { min(max($0, 0), 1) }
        self.segmentationConfidenceScore = segmentationConfidenceScore.map { min(max($0, 0), 1) }
        self.estimatedConcurrentReferenceCount = estimatedConcurrentReferenceCount.map { max(0, $0) }
        self.quickVolumeM3 = quickVolumeM3
        self.quickFootprintAreaM2 = quickFootprintAreaM2
        self.quickPeakHeightM = quickPeakHeightM
        self.quickConfidenceScore = quickConfidenceScore.map { min(max($0, 0), 1) }
        self.quickGeometryPointCount = quickGeometryPointCount.map { max(0, $0) }
        self.quickCameraPathDistanceM = quickCameraPathDistanceM.map { max(0, $0) }
    }

    enum CodingKeys: String, CodingKey {
        case stage
        case referenceMarkerSnapshots
        case nativeReferenceObservations
        case materialSuggestion
        case onDeviceVision
        case devicePoseTelemetry
        case toeCoverageScore
        case pileSegmentationScore
        case toeSegmentationScore
        case segmentationConfidenceScore
        case estimatedConcurrentReferenceCount
        case quickVolumeM3
        case quickFootprintAreaM2
        case quickPeakHeightM
        case quickConfidenceScore
        case quickGeometryPointCount
        case quickCameraPathDistanceM
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            stage: container.decode(StockpileMobileFirstCaptureStagePayload.self, forKey: .stage),
            referenceMarkerSnapshots: container.decodeIfPresent(
                [StockpileReferenceMarkerSnapshotPayload].self,
                forKey: .referenceMarkerSnapshots
            ) ?? [],
            nativeReferenceObservations: container.decodeIfPresent(
                [StockpileReferenceObservationPayload].self,
                forKey: .nativeReferenceObservations
            ) ?? [],
            materialSuggestion: container.decodeIfPresent(
                StockpileMaterialSuggestionPayload.self,
                forKey: .materialSuggestion
            ),
            onDeviceVision: container.decodeIfPresent(
                StockpileOnDeviceVisionPayload.self,
                forKey: .onDeviceVision
            ),
            devicePoseTelemetry: container.decodeIfPresent(
                StockpileDevicePoseTelemetryPayload.self,
                forKey: .devicePoseTelemetry
            ),
            toeCoverageScore: container.decodeIfPresent(Double.self, forKey: .toeCoverageScore),
            pileSegmentationScore: container.decodeIfPresent(Double.self, forKey: .pileSegmentationScore),
            toeSegmentationScore: container.decodeIfPresent(Double.self, forKey: .toeSegmentationScore),
            segmentationConfidenceScore: container.decodeIfPresent(
                Double.self,
                forKey: .segmentationConfidenceScore
            ),
            estimatedConcurrentReferenceCount: container.decodeIfPresent(
                Int.self,
                forKey: .estimatedConcurrentReferenceCount
            ),
            quickVolumeM3: container.decodeIfPresent(Double.self, forKey: .quickVolumeM3),
            quickFootprintAreaM2: container.decodeIfPresent(Double.self, forKey: .quickFootprintAreaM2),
            quickPeakHeightM: container.decodeIfPresent(Double.self, forKey: .quickPeakHeightM),
            quickConfidenceScore: container.decodeIfPresent(Double.self, forKey: .quickConfidenceScore),
            quickGeometryPointCount: container.decodeIfPresent(
                Int.self,
                forKey: .quickGeometryPointCount
            ),
            quickCameraPathDistanceM: container.decodeIfPresent(
                Double.self,
                forKey: .quickCameraPathDistanceM
            )
        )
    }
}

public struct StockpileCaptureQualityInputPayload: Codable, Sendable, Equatable {
    public let referenceVisibilityScore: Double?
    public let coverageScore: Double?
    public let motionStabilityScore: Double?
    public let overallGuidanceScore: Double?
    public let toeCoverageScore: Double?
    public let estimatedConcurrentReferenceCount: Int?
    public let deviceSensors: StockpileDeviceSensorInputPayload
    public let mobileFirstCapture: StockpileMobileFirstCapturePayload?

    public init(
        referenceVisibilityScore: Double? = nil,
        coverageScore: Double? = nil,
        motionStabilityScore: Double? = nil,
        overallGuidanceScore: Double? = nil,
        toeCoverageScore: Double? = nil,
        estimatedConcurrentReferenceCount: Int? = nil,
        deviceSensors: StockpileDeviceSensorInputPayload,
        mobileFirstCapture: StockpileMobileFirstCapturePayload? = nil
    ) {
        self.referenceVisibilityScore = referenceVisibilityScore
        self.coverageScore = coverageScore
        self.motionStabilityScore = motionStabilityScore
        self.overallGuidanceScore = overallGuidanceScore
        self.toeCoverageScore = toeCoverageScore
        self.estimatedConcurrentReferenceCount = estimatedConcurrentReferenceCount.map { max(0, $0) }
        self.deviceSensors = deviceSensors
        self.mobileFirstCapture = mobileFirstCapture
    }
}

public struct StockpileCaptureSessionCreateRequest: Codable, Sendable, Equatable {
    public let siteID: String
    public let pileName: String
    public let materialCode: String
    public let densityKgPerM3: Int
    public let referenceCountGoal: Int
    public let clientBuild: String
    public let taggedReferenceStrategy: StockpileTaggedReferenceStrategyPayload
    public let captureMetadata: StockpileCaptureMetadataPayload
    public let qualityInput: StockpileCaptureQualityInputPayload

    public init(
        siteID: String,
        pileName: String,
        materialCode: String,
        densityKgPerM3: Int,
        referenceCountGoal: Int,
        clientBuild: String,
        taggedReferenceStrategy: StockpileTaggedReferenceStrategyPayload,
        captureMetadata: StockpileCaptureMetadataPayload,
        qualityInput: StockpileCaptureQualityInputPayload
    ) {
        self.siteID = siteID
        self.pileName = pileName
        self.materialCode = materialCode
        self.densityKgPerM3 = densityKgPerM3
        self.referenceCountGoal = referenceCountGoal
        self.clientBuild = clientBuild
        self.taggedReferenceStrategy = taggedReferenceStrategy
        self.captureMetadata = captureMetadata
        self.qualityInput = qualityInput
    }

    enum CodingKeys: String, CodingKey {
        case siteID = "siteId"
        case pileName
        case materialCode
        case densityKgPerM3
        case referenceCountGoal
        case clientBuild
        case taggedReferenceStrategy
        case captureMetadata
        case qualityInput
    }
}

public struct StockpileCaptureSession: Codable, Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let siteID: String
    public let pileName: String
    public let materialCode: String
    public let densityKgPerM3: Int
    public let referenceCountGoal: Int
    public let createdAt: Date
    public let expiresAt: Date
    public let taggedReferenceStrategy: StockpileTaggedReferenceStrategyPayload?
    public let captureMetadata: StockpileCaptureMetadataPayload?
    public let qualityInput: StockpileCaptureQualityInputPayload?
    public let clientBuild: String?

    public var id: String { sessionID }

    public init(
        sessionID: String,
        siteID: String,
        pileName: String,
        materialCode: String,
        densityKgPerM3: Int,
        referenceCountGoal: Int,
        createdAt: Date,
        expiresAt: Date,
        taggedReferenceStrategy: StockpileTaggedReferenceStrategyPayload? = nil,
        captureMetadata: StockpileCaptureMetadataPayload? = nil,
        qualityInput: StockpileCaptureQualityInputPayload? = nil,
        clientBuild: String? = nil
    ) {
        self.sessionID = sessionID
        self.siteID = siteID
        self.pileName = pileName
        self.materialCode = materialCode
        self.densityKgPerM3 = densityKgPerM3
        self.referenceCountGoal = referenceCountGoal
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.taggedReferenceStrategy = taggedReferenceStrategy
        self.captureMetadata = captureMetadata
        self.qualityInput = qualityInput
        self.clientBuild = clientBuild
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case siteID = "siteId"
        case pileName
        case materialCode
        case densityKgPerM3
        case referenceCountGoal
        case createdAt
        case expiresAt
        case taggedReferenceStrategy
        case captureMetadata
        case qualityInput
        case clientBuild
    }
}

public struct StockpileUploadRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let fileName: String
    public let byteCount: Int64
    public let contentType: String
    public let checksumSHA256: String?
    public let taggedReferenceStrategy: StockpileTaggedReferenceStrategyPayload
    public let captureMetadata: StockpileCaptureMetadataPayload
    public let qualityInput: StockpileCaptureQualityInputPayload
    public let poseSamples: [StockpileDevicePoseSamplePayload]
    public let referenceObservations: [StockpileReferenceObservationPayload]
    public let referenceEvidenceJPEGFrames: [StockpileReferenceEvidenceJPEGFramePayload]

    public init(
        sessionID: String,
        fileName: String,
        byteCount: Int64,
        contentType: String,
        checksumSHA256: String? = nil,
        taggedReferenceStrategy: StockpileTaggedReferenceStrategyPayload,
        captureMetadata: StockpileCaptureMetadataPayload,
        qualityInput: StockpileCaptureQualityInputPayload,
        poseSamples: [StockpileDevicePoseSamplePayload] = [],
        referenceObservations: [StockpileReferenceObservationPayload] = [],
        referenceEvidenceJPEGFrames: [StockpileReferenceEvidenceJPEGFramePayload] = []
    ) {
        self.sessionID = sessionID
        self.fileName = fileName
        self.byteCount = byteCount
        self.contentType = contentType
        self.checksumSHA256 = checksumSHA256
        self.taggedReferenceStrategy = taggedReferenceStrategy
        self.captureMetadata = captureMetadata
        self.qualityInput = qualityInput
        self.poseSamples = poseSamples
        self.referenceObservations = referenceObservations
        self.referenceEvidenceJPEGFrames = referenceEvidenceJPEGFrames
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case fileName
        case byteCount
        case contentType
        case checksumSHA256 = "checksumSha256"
        case taggedReferenceStrategy
        case captureMetadata
        case qualityInput
        case poseSamples
        case referenceObservations
        case referenceEvidenceJPEGFrames
    }
}

public struct StockpileUploadAuthorization: Codable, Sendable, Equatable, Identifiable {
    public let uploadID: String
    public let sessionID: String
    public let jobID: String
    public let runID: String?
    public let uploadURL: URL
    public let httpMethod: String
    public let headers: [String: String]
    public let expiresAt: Date

    public var id: String { uploadID }

    public init(
        uploadID: String,
        sessionID: String,
        jobID: String,
        runID: String? = nil,
        uploadURL: URL,
        httpMethod: String,
        headers: [String: String],
        expiresAt: Date
    ) {
        self.uploadID = uploadID
        self.sessionID = sessionID
        self.jobID = jobID
        self.runID = runID
        self.uploadURL = uploadURL
        self.httpMethod = httpMethod
        self.headers = headers
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case uploadID = "uploadId"
        case sessionID = "sessionId"
        case jobID = "jobId"
        case runID = "runId"
        case uploadURL = "uploadUrl"
        case httpMethod
        case headers
        case expiresAt
    }
}

public struct StockpileJobSnapshot: Codable, Sendable, Equatable {
    public let phase: StockpileJobPhase
    public let progress: Double
    public let headline: String
    public let detail: String

    public init(
        phase: StockpileJobPhase,
        progress: Double,
        headline: String,
        detail: String
    ) {
        self.phase = phase
        self.progress = progress
        self.headline = headline
        self.detail = detail
    }
}

public struct StockpileProcessingJobStatus: Codable, Sendable, Equatable, Identifiable {
    public let jobID: String
    public let runID: String
    public let phase: StockpileJobPhase
    public let progress: Double
    public let headline: String
    public let detail: String
    public let provisionalMeasurement: StockpileProvisionalMeasurementPayload?
    public let updatedAt: Date

    public var id: String { jobID }
    public var isTerminal: Bool { phase.isTerminal }

    public init(
        jobID: String,
        runID: String,
        phase: StockpileJobPhase,
        progress: Double,
        headline: String,
        detail: String,
        provisionalMeasurement: StockpileProvisionalMeasurementPayload? = nil,
        updatedAt: Date
    ) {
        self.jobID = jobID
        self.runID = runID
        self.phase = phase
        self.progress = progress
        self.headline = headline
        self.detail = detail
        self.provisionalMeasurement = provisionalMeasurement
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "jobId"
        case runID = "runId"
        case phase
        case progress
        case headline
        case detail
        case provisionalMeasurement
        case updatedAt
    }
}

public struct StockpileConfidencePayload: Codable, Sendable, Equatable {
    public let score: Int
    public let label: String
    public let summary: String

    public init(score: Int, label: String, summary: String) {
        self.score = score
        self.label = label
        self.summary = summary
    }
}

public struct StockpileMeasurementPayload: Codable, Sendable, Equatable {
    public let volumeM3: Double
    public let weightTonnes: Double
    public let densityKgPerM3: Int

    public init(volumeM3: Double, weightTonnes: Double, densityKgPerM3: Int) {
        self.volumeM3 = volumeM3
        self.weightTonnes = weightTonnes
        self.densityKgPerM3 = densityKgPerM3
    }
}

public struct StockpileCaptureQualityPayload: Codable, Sendable, Equatable {
    public let referenceVisibilityScore: Double?
    public let perimeterCoverageScore: Double?
    public let motionStabilityScore: Double?
    public let overallGuidanceScore: Double?

    public init(
        referenceVisibilityScore: Double? = nil,
        perimeterCoverageScore: Double? = nil,
        motionStabilityScore: Double? = nil,
        overallGuidanceScore: Double? = nil
    ) {
        self.referenceVisibilityScore = referenceVisibilityScore
        self.perimeterCoverageScore = perimeterCoverageScore
        self.motionStabilityScore = motionStabilityScore
        self.overallGuidanceScore = overallGuidanceScore
    }
}

public struct StockpileReferenceObservationSummaryPayload: Codable, Sendable, Equatable {
    public let observedReferenceCount: Int?
    public let framesWithObservations: Int?
    public let maxVisibleTogether: Int?
    public let usedForCalibrationCount: Int?

    public init(
        observedReferenceCount: Int? = nil,
        framesWithObservations: Int? = nil,
        maxVisibleTogether: Int? = nil,
        usedForCalibrationCount: Int? = nil
    ) {
        self.observedReferenceCount = observedReferenceCount
        self.framesWithObservations = framesWithObservations
        self.maxVisibleTogether = maxVisibleTogether
        self.usedForCalibrationCount = usedForCalibrationCount
    }
}

public struct StockpileReferenceDiagnosticsPayload: Codable, Sendable, Equatable {
    public let targetCount: Int
    public let minimumVisibleTogether: Int
    public let preferredVisibleCount: Int
    public let framesMeetingVisibilityGoal: Int?
    public let framesChecked: Int?
    public let calibrationBasis: String
    public let calibrationStatus: String
    public let referenceStrategy: String?
    public let referencesUsed: Int?
    public let observationSummary: StockpileReferenceObservationSummaryPayload?

    public init(
        targetCount: Int,
        minimumVisibleTogether: Int,
        preferredVisibleCount: Int,
        framesMeetingVisibilityGoal: Int? = nil,
        framesChecked: Int? = nil,
        calibrationBasis: String,
        calibrationStatus: String,
        referenceStrategy: String? = nil,
        referencesUsed: Int? = nil,
        observationSummary: StockpileReferenceObservationSummaryPayload? = nil
    ) {
        self.targetCount = targetCount
        self.minimumVisibleTogether = minimumVisibleTogether
        self.preferredVisibleCount = preferredVisibleCount
        self.framesMeetingVisibilityGoal = framesMeetingVisibilityGoal
        self.framesChecked = framesChecked
        self.calibrationBasis = calibrationBasis
        self.calibrationStatus = calibrationStatus
        self.referenceStrategy = referenceStrategy
        self.referencesUsed = referencesUsed
        self.observationSummary = observationSummary
    }
}

public struct StockpileProvisionalMeasurementPayload: Codable, Sendable, Equatable {
    public let status: String
    public let basis: String?
    public let volumeM3: Double?
    public let weightTonnes: Double?
    public let confidenceScore: Int?
    public let reason: String?
    public let quickVolumeM3: Double?
    public let quickFootprintAreaM2: Double?
    public let quickPeakHeightM: Double?
    public let quickConfidenceScore: Double?
    public let quickGeometryPointCount: Int?
    public let quickCameraPathDistanceM: Double?
    public let nativeReferenceObservations: [StockpileReferenceObservationPayload]
    public let materialSuggestion: StockpileMaterialSuggestionPayload?
    public let updatedAt: Date?

    public init(
        status: String,
        basis: String? = nil,
        volumeM3: Double? = nil,
        weightTonnes: Double? = nil,
        confidenceScore: Int? = nil,
        reason: String? = nil,
        quickVolumeM3: Double? = nil,
        quickFootprintAreaM2: Double? = nil,
        quickPeakHeightM: Double? = nil,
        quickConfidenceScore: Double? = nil,
        quickGeometryPointCount: Int? = nil,
        quickCameraPathDistanceM: Double? = nil,
        nativeReferenceObservations: [StockpileReferenceObservationPayload] = [],
        materialSuggestion: StockpileMaterialSuggestionPayload? = nil,
        updatedAt: Date? = nil
    ) {
        self.status = status
        self.basis = basis
        self.volumeM3 = volumeM3
        self.weightTonnes = weightTonnes
        self.confidenceScore = confidenceScore
        self.reason = reason
        self.quickVolumeM3 = quickVolumeM3.map { max(0, $0) }
        self.quickFootprintAreaM2 = quickFootprintAreaM2.map { max(0, $0) }
        self.quickPeakHeightM = quickPeakHeightM.map { max(0, $0) }
        self.quickConfidenceScore = quickConfidenceScore.map { min(max($0, 0), 1) }
        self.quickGeometryPointCount = quickGeometryPointCount.map { max(0, $0) }
        self.quickCameraPathDistanceM = quickCameraPathDistanceM.map { max(0, $0) }
        self.nativeReferenceObservations = nativeReferenceObservations
        self.materialSuggestion = materialSuggestion
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case status
        case basis
        case volumeM3
        case weightTonnes
        case confidenceScore
        case reason
        case quickVolumeM3
        case quickFootprintAreaM2
        case quickPeakHeightM
        case quickConfidenceScore
        case quickGeometryPointCount
        case quickCameraPathDistanceM
        case nativeReferenceObservations
        case materialSuggestion
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            status: container.decode(String.self, forKey: .status),
            basis: container.decodeIfPresent(String.self, forKey: .basis),
            volumeM3: container.decodeIfPresent(Double.self, forKey: .volumeM3),
            weightTonnes: container.decodeIfPresent(Double.self, forKey: .weightTonnes),
            confidenceScore: container.decodeIfPresent(Int.self, forKey: .confidenceScore),
            reason: container.decodeIfPresent(String.self, forKey: .reason),
            quickVolumeM3: container.decodeIfPresent(Double.self, forKey: .quickVolumeM3),
            quickFootprintAreaM2: container.decodeIfPresent(Double.self, forKey: .quickFootprintAreaM2),
            quickPeakHeightM: container.decodeIfPresent(Double.self, forKey: .quickPeakHeightM),
            quickConfidenceScore: container.decodeIfPresent(Double.self, forKey: .quickConfidenceScore),
            quickGeometryPointCount: container.decodeIfPresent(
                Int.self,
                forKey: .quickGeometryPointCount
            ),
            quickCameraPathDistanceM: container.decodeIfPresent(
                Double.self,
                forKey: .quickCameraPathDistanceM
            ),
            nativeReferenceObservations: container.decodeIfPresent(
                [StockpileReferenceObservationPayload].self,
                forKey: .nativeReferenceObservations
            ) ?? [],
            materialSuggestion: container.decodeIfPresent(
                StockpileMaterialSuggestionPayload.self,
                forKey: .materialSuggestion
            ),
            updatedAt: container.decodeIfPresent(Date.self, forKey: .updatedAt)
        )
    }
}

public struct StockpileReconstructionPointPayload: Codable, Sendable, Equatable, Hashable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct StockpileReconstructionTrianglePayload: Codable, Sendable, Equatable, Hashable {
    public let a: UInt32
    public let b: UInt32
    public let c: UInt32

    public init(a: UInt32, b: UInt32, c: UInt32) {
        self.a = a
        self.b = b
        self.c = c
    }
}

public struct StockpileReconstructionPayload: Codable, Sendable, Equatable {
    public let summary: String
    public let footprintAreaM2: Double
    public let peakHeightM: Double
    public let defaultMode: String
    public let vertices: [StockpileReconstructionPointPayload]
    public let triangles: [StockpileReconstructionTrianglePayload]
    public let pointCloud: [StockpileReconstructionPointPayload]
    public let toeMarkers: [StockpileReconstructionPointPayload]
    public let surfaceRiskMarkers: [StockpileReconstructionPointPayload]

    public init(
        summary: String,
        footprintAreaM2: Double,
        peakHeightM: Double,
        defaultMode: String = "3d",
        vertices: [StockpileReconstructionPointPayload],
        triangles: [StockpileReconstructionTrianglePayload],
        pointCloud: [StockpileReconstructionPointPayload],
        toeMarkers: [StockpileReconstructionPointPayload],
        surfaceRiskMarkers: [StockpileReconstructionPointPayload]
    ) {
        self.summary = summary
        self.footprintAreaM2 = footprintAreaM2
        self.peakHeightM = peakHeightM
        self.defaultMode = defaultMode
        self.vertices = vertices
        self.triangles = triangles
        self.pointCloud = pointCloud
        self.toeMarkers = toeMarkers
        self.surfaceRiskMarkers = surfaceRiskMarkers
    }
}

public struct StockpileResultPayload: Codable, Sendable, Equatable, Identifiable {
    public let runID: String
    public let pileName: String
    public let outcome: StockpileRunOutcome
    public let confidence: StockpileConfidencePayload
    public let measurement: StockpileMeasurementPayload?
    public let warnings: [String]
    public let blockers: [String]
    public let recommendedAction: String
    public let captureQuality: StockpileCaptureQualityPayload?
    public let referenceDiagnostics: StockpileReferenceDiagnosticsPayload?
    public let provisionalMeasurement: StockpileProvisionalMeasurementPayload?
    public let reconstruction: StockpileReconstructionPayload?
    public let reportURL: URL?
    public let updatedAt: Date?
    public let siteID: String?
    public let sessionID: String?
    public let jobID: String?

    public var id: String { runID }

    enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case pileName
        case outcome
        case confidence
        case measurement
        case warnings
        case blockers
        case recommendedAction
        case captureQuality
        case referenceDiagnostics
        case provisionalMeasurement
        case reconstruction
        case reportURL = "reportUrl"
        case updatedAt
        case siteID = "siteId"
        case sessionID = "sessionId"
        case jobID = "jobId"
    }

    public init(
        runID: String,
        pileName: String,
        outcome: StockpileRunOutcome,
        confidence: StockpileConfidencePayload,
        measurement: StockpileMeasurementPayload?,
        warnings: [String],
        blockers: [String],
        recommendedAction: String,
        captureQuality: StockpileCaptureQualityPayload? = nil,
        referenceDiagnostics: StockpileReferenceDiagnosticsPayload? = nil,
        provisionalMeasurement: StockpileProvisionalMeasurementPayload? = nil,
        reconstruction: StockpileReconstructionPayload? = nil,
        reportURL: URL? = nil,
        updatedAt: Date? = nil,
        siteID: String? = nil,
        sessionID: String? = nil,
        jobID: String? = nil
    ) {
        self.runID = runID
        self.pileName = pileName
        self.outcome = outcome
        self.confidence = confidence
        self.measurement = measurement
        self.warnings = warnings
        self.blockers = blockers
        self.recommendedAction = recommendedAction
        self.captureQuality = captureQuality
        self.referenceDiagnostics = referenceDiagnostics
        self.provisionalMeasurement = provisionalMeasurement
        self.reconstruction = reconstruction
        self.reportURL = reportURL
        self.updatedAt = updatedAt
        self.siteID = siteID
        self.sessionID = sessionID
        self.jobID = jobID
    }
}

public enum StockpileMobileAPIError: Error, Equatable, Sendable, LocalizedError {
    case sessionNotFound(String)
    case jobNotFound(String)
    case resultNotFound(String)
    case invalidRequestURL(String)
    case invalidResponse
    case authenticationRequired(String?)
    case forbidden(String?)
    case rateLimited(retryAfter: TimeInterval?, message: String?)
    case validationFailed(String?)
    case requestFailed(statusCode: Int, message: String?)
    case serverError(statusCode: Int, message: String?)
    case transportFailure(String)
    case decodingFailure(String)
    case encodingFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .sessionNotFound(id):
            return "Capture session \(id) was not found."
        case let .jobNotFound(id):
            return "Processing job \(id) was not found."
        case let .resultNotFound(id):
            return "Result \(id) was not found."
        case let .invalidRequestURL(path):
            return "The mobile API request URL could not be built for \(path)."
        case .invalidResponse:
            return "The mobile API returned an invalid response."
        case let .authenticationRequired(message):
            return message ?? "Authentication is required before calling the mobile API."
        case let .forbidden(message):
            return message ?? "The mobile API request was rejected by the server."
        case let .rateLimited(retryAfter, message):
            if let message {
                return message
            }
            if let retryAfter {
                return "The mobile API rate limit was hit. Retry after \(Int(retryAfter)) seconds."
            }
            return "The mobile API rate limit was hit."
        case let .validationFailed(message):
            return message ?? "The mobile API rejected the request payload."
        case let .requestFailed(statusCode, message):
            return message ?? "The mobile API request failed with status \(statusCode)."
        case let .serverError(statusCode, message):
            return message ?? "The mobile API server failed with status \(statusCode)."
        case let .transportFailure(message):
            return "The mobile API request could not be completed: \(message)"
        case let .decodingFailure(message):
            return "The mobile API response could not be decoded: \(message)"
        case let .encodingFailure(message):
            return "The mobile API request could not be encoded: \(message)"
        }
    }
}

public protocol StockpileMobileAPIServicing: Sendable {
    func createCaptureSession(request: StockpileCaptureSessionCreateRequest) async throws -> StockpileCaptureSession
    func createUploadAuthorization(request: StockpileUploadRequest) async throws -> StockpileUploadAuthorization
    func fetchProcessingJob(jobID: String) async throws -> StockpileProcessingJobStatus
    func fetchResult(runID: String) async throws -> StockpileResultPayload
    func fetchRecentResults(
        limit: Int,
        siteID: String?,
        sessionID: String?
    ) async throws -> [StockpileResultPayload]
}
