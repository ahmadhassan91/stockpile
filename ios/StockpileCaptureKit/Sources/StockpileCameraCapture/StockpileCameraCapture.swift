import Foundation

public enum StockpileCameraAuthorizationStatus: String, Codable, Sendable, CaseIterable {
    case notDetermined
    case restricted
    case denied
    case authorized

    public var title: String {
        switch self {
        case .notDetermined:
            return "Not determined"
        case .restricted:
            return "Restricted"
        case .denied:
            return "Denied"
        case .authorized:
            return "Authorized"
        }
    }

    public var isGranted: Bool {
        self == .authorized
    }

    public var requiresSettingsVisit: Bool {
        self == .denied || self == .restricted
    }
}

public struct StockpileCameraPermissionState: Codable, Equatable, Sendable {
    public var status: StockpileCameraAuthorizationStatus
    public var canRequestAccess: Bool

    public init(status: StockpileCameraAuthorizationStatus, canRequestAccess: Bool = true) {
        self.status = status
        self.canRequestAccess = canRequestAccess
    }

    public var isGranted: Bool {
        status.isGranted
    }

    public var needsAttention: Bool {
        !isGranted
    }

    public var requiresSettingsVisit: Bool {
        status.requiresSettingsVisit && !canRequestAccess
    }

    public var statusLabel: String {
        status.title
    }

    public var operatorHint: String {
        switch status {
        case .authorized:
            return "Rear-camera access is ready."
        case .notDetermined:
            return "Allow rear-camera access to start recording in app."
        case .restricted:
            return "Camera access is restricted on this device."
        case .denied:
            return "Turn on camera access in Settings to keep recording in app."
        }
    }

    public static let preview = StockpileCameraPermissionState(status: .authorized, canRequestAccess: false)
    public static let blockedPreview = StockpileCameraPermissionState(status: .denied, canRequestAccess: false)
}

public struct StockpileCaptureObservedReferenceMarker: Codable, Sendable, Equatable, Identifiable {
    public enum DetectionSource: String, Codable, Sendable, CaseIterable {
        case opticalLabel
        case barcode
        case visualCandidate
    }

    public let markerID: String
    public let family: String
    public let visibleCount: Int
    public let confidence: Double
    public let source: DetectionSource

    public var id: String { markerID }

    public init(
        markerID: String,
        family: String = "tagged_reference",
        visibleCount: Int,
        confidence: Double,
        source: DetectionSource
    ) {
        self.markerID = markerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.family = family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "tagged_reference" : family
        self.visibleCount = max(0, visibleCount)
        self.confidence = min(max(confidence, 0), 1)
        self.source = source
    }
}

public struct StockpileCaptureMaterialSuggestion: Codable, Sendable, Equatable {
    public let materialName: String
    public let materialCode: String
    public let confidence: Double

    public init(
        materialName: String,
        materialCode: String,
        confidence: Double
    ) {
        self.materialName = materialName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.materialCode = materialCode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.confidence = min(max(confidence, 0), 1)
    }
}

public enum StockpileCameraSessionLifecycle: String, Codable, Sendable, CaseIterable {
    case permissionRequired
    case unconfigured
    case configuring
    case ready
    case running
    case stopped
    case failed

    public var title: String {
        switch self {
        case .permissionRequired:
            return "Permission required"
        case .unconfigured:
            return "Camera idle"
        case .configuring:
            return "Opening rear camera"
        case .ready:
            return "Preview ready"
        case .running:
            return "Camera live"
        case .stopped:
            return "Camera stopped"
        case .failed:
            return "Camera unavailable"
        }
    }
}

public enum StockpileCameraRecordingLifecycle: String, Codable, Sendable, CaseIterable {
    case idle
    case starting
    case recording
    case finalizing
    case finished
    case failed

    public var title: String {
        switch self {
        case .idle:
            return "Waiting to record"
        case .starting:
            return "Starting recording"
        case .recording:
            return "Recording live"
        case .finalizing:
            return "Sealing recording"
        case .finished:
            return "Saved on device"
        case .failed:
            return "Recording interrupted"
        }
    }

    public var isActive: Bool {
        switch self {
        case .starting, .recording:
            return true
        case .idle, .finalizing, .finished, .failed:
            return false
        }
    }
}

public struct StockpileCameraRecordingOutput: Codable, Equatable, Sendable {
    public let fileURL: URL
    public let fileSizeBytes: Int64?
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        fileURL: URL,
        fileSizeBytes: Int64?,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.fileURL = fileURL
        self.fileSizeBytes = fileSizeBytes
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public enum StockpileCaptureGuidanceLevel: String, Codable, Sendable, CaseIterable {
    case good
    case watch
    case blocked

    public var title: String {
        switch self {
        case .good:
            return "Good"
        case .watch:
            return "Watch"
        case .blocked:
            return "Blocked"
        }
    }
}

public struct StockpileCaptureGuidanceMetric: Codable, Equatable, Sendable {
    public var title: String
    public var score: Double
    public var watchThreshold: Double
    public var blockedThreshold: Double
    public var detail: String
    public var observedCount: Int?
    public var targetCount: Int?

    public init(
        title: String,
        score: Double,
        watchThreshold: Double,
        blockedThreshold: Double,
        detail: String,
        observedCount: Int? = nil,
        targetCount: Int? = nil
    ) {
        self.title = title
        self.score = Self.clamp(score)
        self.watchThreshold = Self.clamp(watchThreshold)
        self.blockedThreshold = Self.clamp(blockedThreshold)
        self.detail = detail
        self.observedCount = observedCount
        self.targetCount = targetCount
    }

    public var level: StockpileCaptureGuidanceLevel {
        if score < blockedThreshold {
            return .blocked
        }

        if score < watchThreshold {
            return .watch
        }

        return .good
    }

    public var isReady: Bool {
        level == .good
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

public struct StockpileCaptureGuidanceSummary: Codable, Equatable, Sendable {
    public var referenceVisibility: StockpileCaptureGuidanceMetric
    public var coverage: StockpileCaptureGuidanceMetric
    public var motion: StockpileCaptureGuidanceMetric
    public var decodedReferenceQuality: StockpileCaptureGuidanceMetric?
    public var pileSegmentation: StockpileCaptureGuidanceMetric?
    public var toeSegmentation: StockpileCaptureGuidanceMetric?
    public var sceneFit: StockpileCaptureGuidanceMetric?
    public var sceneRejection: StockpileCaptureGuidanceMetric?
    public var materialConfidence: StockpileCaptureGuidanceMetric?

    public init(
        referenceVisibility: StockpileCaptureGuidanceMetric,
        coverage: StockpileCaptureGuidanceMetric,
        motion: StockpileCaptureGuidanceMetric,
        decodedReferenceQuality: StockpileCaptureGuidanceMetric? = nil,
        pileSegmentation: StockpileCaptureGuidanceMetric? = nil,
        toeSegmentation: StockpileCaptureGuidanceMetric? = nil,
        sceneFit: StockpileCaptureGuidanceMetric? = nil,
        sceneRejection: StockpileCaptureGuidanceMetric? = nil,
        materialConfidence: StockpileCaptureGuidanceMetric? = nil
    ) {
        self.referenceVisibility = referenceVisibility
        self.coverage = coverage
        self.motion = motion
        self.decodedReferenceQuality = decodedReferenceQuality
        self.pileSegmentation = pileSegmentation
        self.toeSegmentation = toeSegmentation
        self.sceneFit = sceneFit
        self.sceneRejection = sceneRejection
        self.materialConfidence = materialConfidence
    }

    public var overallLevel: StockpileCaptureGuidanceLevel {
        if finishPriorityMetrics.contains(where: { $0.level == .blocked })
            || advisoryMetrics.contains(where: { $0.level == .blocked }) {
            return .blocked
        }

        if finishPriorityMetrics.contains(where: { $0.level == .watch }) {
            return .watch
        }

        return .good
    }

    public var isReadyToFinish: Bool {
        finishPriorityMetrics.allSatisfy(\.isReady)
            && advisoryMetrics.allSatisfy { $0.level != .blocked }
    }

    public var primaryOperatorAction: String {
        if referenceVisibility.title == "LiDAR tracking",
           coverage.level == .good,
           finishPriorityMetrics.contains(where: { $0.level == .blocked }) == false,
           finishPriorityMetrics.contains(where: { $0.level == .watch }) {
            return "Review-only allowed. Finish now, or make one steadier pass for production confidence."
        }

        if let finishBlocker = finishPriorityMetrics.first(where: { $0.level != .good }) {
            return finishBlocker.detail
        }

        if let advisory = advisoryMetrics.first(where: { $0.level != .good }) {
            return advisory.detail
        }

        if referenceVisibility.title == "LiDAR tracking" {
            return "Ready to finish. Depth tracking and coverage look production-ready."
        }

        return "Scene and references look strong. Finish when the last edge is covered."
    }

    public var overallScore: Double {
        let metrics = allMetrics
        let total = metrics.reduce(0.0) { partialResult, metric in
            partialResult + metric.score
        }
        return metrics.isEmpty ? 0 : total / Double(metrics.count)
    }

    private var allMetrics: [StockpileCaptureGuidanceMetric] {
        finishPriorityMetrics + advisoryMetrics
    }

    private var finishPriorityMetrics: [StockpileCaptureGuidanceMetric] {
        [
            sceneRejection,
            referenceVisibility,
            decodedReferenceQuality,
            pileSegmentation,
            sceneFit,
            toeSegmentation,
            coverage,
            motion
        ].compactMap { $0 }
    }

    private var advisoryMetrics: [StockpileCaptureGuidanceMetric] {
        [materialConfidence].compactMap { $0 }
    }

    public static let preview = StockpileCaptureGuidanceSummary(
        referenceVisibility: StockpileCaptureGuidanceMetric(
            title: "Reference visibility",
            score: 0.88,
            watchThreshold: 0.7,
            blockedThreshold: 0.45,
            detail: "Two tagged references are visible together."
        ),
        coverage: StockpileCaptureGuidanceMetric(
            title: "Coverage",
            score: 0.82,
            watchThreshold: 0.7,
            blockedThreshold: 0.5,
            detail: "Most of the pile toe is already covered."
        ),
        motion: StockpileCaptureGuidanceMetric(
            title: "Motion",
            score: 0.86,
            watchThreshold: 0.72,
            blockedThreshold: 0.5,
            detail: "Camera motion is steady enough for reconstruction."
        ),
        decodedReferenceQuality: StockpileCaptureGuidanceMetric(
            title: "Reference quality",
            score: 0.9,
            watchThreshold: 0.76,
            blockedThreshold: 0.52,
            detail: "Reference tags are decoding cleanly."
        ),
        sceneFit: StockpileCaptureGuidanceMetric(
            title: "Scene framing",
            score: 0.9,
            watchThreshold: 0.72,
            blockedThreshold: 0.48,
            detail: "Pile framing looks steady."
        ),
        sceneRejection: StockpileCaptureGuidanceMetric(
            title: "Scene match",
            score: 0.94,
            watchThreshold: 0.78,
            blockedThreshold: 0.5,
            detail: "Scene matches a stockpile capture."
        ),
        materialConfidence: StockpileCaptureGuidanceMetric(
            title: "Material confidence",
            score: 0.82,
            watchThreshold: 0.72,
            blockedThreshold: 0.12,
            detail: "Material read looks stable."
        )
    )

    public static let watchPreview = StockpileCaptureGuidanceSummary(
        referenceVisibility: StockpileCaptureGuidanceMetric(
            title: "Reference visibility",
            score: 0.68,
            watchThreshold: 0.7,
            blockedThreshold: 0.45,
            detail: "Keep two tagged references in frame together."
        ),
        coverage: StockpileCaptureGuidanceMetric(
            title: "Coverage",
            score: 0.79,
            watchThreshold: 0.7,
            blockedThreshold: 0.5,
            detail: "Coverage is strong, but the last edge needs a pass."
        ),
        motion: StockpileCaptureGuidanceMetric(
            title: "Motion",
            score: 0.81,
            watchThreshold: 0.72,
            blockedThreshold: 0.5,
            detail: "Motion stability is acceptable."
        ),
        decodedReferenceQuality: StockpileCaptureGuidanceMetric(
            title: "Reference quality",
            score: 0.66,
            watchThreshold: 0.76,
            blockedThreshold: 0.52,
            detail: "Tagged references are visible but not decoding. Hold flatter."
        ),
        sceneFit: StockpileCaptureGuidanceMetric(
            title: "Scene framing",
            score: 0.74,
            watchThreshold: 0.72,
            blockedThreshold: 0.48,
            detail: "Widen slightly so the pile stays dominant."
        ),
        sceneRejection: StockpileCaptureGuidanceMetric(
            title: "Scene match",
            score: 0.71,
            watchThreshold: 0.78,
            blockedThreshold: 0.5,
            detail: "Keep more of the pile face in view."
        )
    )
}

public enum StockpileCameraCaptureSessionPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case preparing
    case capturing
    case readyToFinish
    case completed
    case blocked
    case failed

    public var title: String {
        switch self {
        case .idle:
            return "Ready"
        case .preparing:
            return "Opening camera"
        case .capturing:
            return "Recording"
        case .readyToFinish:
            return "Ready to finish"
        case .completed:
            return "Recording saved"
        case .blocked:
            return "Camera blocked"
        case .failed:
            return "Recording failed"
        }
    }
}

public enum StockpileCameraOperatorStage: String, Sendable, CaseIterable {
    case idle
    case permissionRequired
    case accessBlocked
    case openingCamera
    case recordingLive
    case readyToFinish
    case finalizingRecording
    case recordingSaved
    case failed
}

public struct StockpileCameraCaptureSessionState: Codable, Equatable, Sendable {
    public var phase: StockpileCameraCaptureSessionPhase
    public var permission: StockpileCameraPermissionState
    public var guidance: StockpileCaptureGuidanceSummary
    public var sensorSnapshot: StockpileCaptureSensorSnapshot?
    public var completedSteps: Int
    public var totalSteps: Int
    public var activePrompt: String
    public var sessionLifecycle: StockpileCameraSessionLifecycle
    public var recordingLifecycle: StockpileCameraRecordingLifecycle
    public var recordingOutput: StockpileCameraRecordingOutput?
    public var activeDeviceName: String?
    public var observedReferenceMarkers: [StockpileCaptureObservedReferenceMarker]
    public var materialSuggestion: StockpileCaptureMaterialSuggestion?
    public var lastErrorDescription: String?
    public var debugTraceSummary: String?

    public init(
        phase: StockpileCameraCaptureSessionPhase,
        permission: StockpileCameraPermissionState,
        guidance: StockpileCaptureGuidanceSummary,
        sensorSnapshot: StockpileCaptureSensorSnapshot? = nil,
        completedSteps: Int,
        totalSteps: Int,
        activePrompt: String,
        sessionLifecycle: StockpileCameraSessionLifecycle = .unconfigured,
        recordingLifecycle: StockpileCameraRecordingLifecycle = .idle,
        recordingOutput: StockpileCameraRecordingOutput? = nil,
        activeDeviceName: String? = nil,
        observedReferenceMarkers: [StockpileCaptureObservedReferenceMarker] = [],
        materialSuggestion: StockpileCaptureMaterialSuggestion? = nil,
        lastErrorDescription: String? = nil,
        debugTraceSummary: String? = nil
    ) {
        self.phase = phase
        self.permission = permission
        self.guidance = guidance
        self.sensorSnapshot = sensorSnapshot
        self.completedSteps = max(0, completedSteps)
        self.totalSteps = max(0, totalSteps)
        self.activePrompt = activePrompt
        self.sessionLifecycle = sessionLifecycle
        self.recordingLifecycle = recordingLifecycle
        self.recordingOutput = recordingOutput
        self.activeDeviceName = activeDeviceName
        self.observedReferenceMarkers = observedReferenceMarkers
        self.materialSuggestion = materialSuggestion
        self.lastErrorDescription = lastErrorDescription
        self.debugTraceSummary = debugTraceSummary
    }

    enum CodingKeys: String, CodingKey {
        case phase
        case permission
        case guidance
        case sensorSnapshot
        case completedSteps
        case totalSteps
        case activePrompt
        case sessionLifecycle
        case recordingLifecycle
        case recordingOutput
        case activeDeviceName
        case observedReferenceMarkers
        case materialSuggestion
        case lastErrorDescription
        case debugTraceSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decode(StockpileCameraCaptureSessionPhase.self, forKey: .phase)
        permission = try container.decode(StockpileCameraPermissionState.self, forKey: .permission)
        guidance = try container.decode(StockpileCaptureGuidanceSummary.self, forKey: .guidance)
        sensorSnapshot = try container.decodeIfPresent(StockpileCaptureSensorSnapshot.self, forKey: .sensorSnapshot)
        completedSteps = max(0, try container.decode(Int.self, forKey: .completedSteps))
        totalSteps = max(0, try container.decode(Int.self, forKey: .totalSteps))
        activePrompt = try container.decode(String.self, forKey: .activePrompt)
        sessionLifecycle = try container.decodeIfPresent(StockpileCameraSessionLifecycle.self, forKey: .sessionLifecycle)
            ?? (permission.isGranted ? .unconfigured : .permissionRequired)
        recordingLifecycle = try container.decodeIfPresent(StockpileCameraRecordingLifecycle.self, forKey: .recordingLifecycle)
            ?? .idle
        recordingOutput = try container.decodeIfPresent(StockpileCameraRecordingOutput.self, forKey: .recordingOutput)
        activeDeviceName = try container.decodeIfPresent(String.self, forKey: .activeDeviceName)
        observedReferenceMarkers = try container.decodeIfPresent([StockpileCaptureObservedReferenceMarker].self, forKey: .observedReferenceMarkers)
            ?? []
        materialSuggestion = try container.decodeIfPresent(StockpileCaptureMaterialSuggestion.self, forKey: .materialSuggestion)
        lastErrorDescription = try container.decodeIfPresent(String.self, forKey: .lastErrorDescription)
        debugTraceSummary = try container.decodeIfPresent(String.self, forKey: .debugTraceSummary)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phase, forKey: .phase)
        try container.encode(permission, forKey: .permission)
        try container.encode(guidance, forKey: .guidance)
        try container.encodeIfPresent(sensorSnapshot, forKey: .sensorSnapshot)
        try container.encode(completedSteps, forKey: .completedSteps)
        try container.encode(totalSteps, forKey: .totalSteps)
        try container.encode(activePrompt, forKey: .activePrompt)
        try container.encode(sessionLifecycle, forKey: .sessionLifecycle)
        try container.encode(recordingLifecycle, forKey: .recordingLifecycle)
        try container.encodeIfPresent(recordingOutput, forKey: .recordingOutput)
        try container.encodeIfPresent(activeDeviceName, forKey: .activeDeviceName)
        try container.encode(observedReferenceMarkers, forKey: .observedReferenceMarkers)
        try container.encodeIfPresent(materialSuggestion, forKey: .materialSuggestion)
        try container.encodeIfPresent(lastErrorDescription, forKey: .lastErrorDescription)
        try container.encodeIfPresent(debugTraceSummary, forKey: .debugTraceSummary)
    }

    public var progress: Double {
        guard totalSteps > 1 else {
            return phase == .completed ? 1 : 0
        }

        let denominator = Double(totalSteps - 1)
        return min(max(Double(completedSteps) / denominator, 0), 1)
    }

    public var canAdvance: Bool {
        phase == .capturing && completedSteps < max(totalSteps - 1, 0)
    }

    public var canFinish: Bool {
        phase == .readyToFinish || (phase == .capturing && guidance.isReadyToFinish && completedSteps >= max(totalSteps - 1, 0))
    }

    public var isSessionRunning: Bool {
        sessionLifecycle == .running
    }

    public var isRecording: Bool {
        recordingLifecycle == .recording
    }

    public var canStartRecording: Bool {
        permission.isGranted && !recordingLifecycle.isActive && recordingLifecycle != .finalizing
    }

    public var canStopRecording: Bool {
        recordingLifecycle.isActive
    }

    public var recordingStatusLabel: String {
        recordingLifecycle.title
    }

    public var isPreviewAvailable: Bool {
        switch sessionLifecycle {
        case .ready, .running, .stopped:
            return true
        case .permissionRequired, .unconfigured, .configuring, .failed:
            return false
        }
    }

    public var sessionStatusLabel: String {
        sessionLifecycle.title
    }

    public var statusLabel: String {
        switch phase {
        case .idle:
            return "Ready to record"
        case .preparing:
            return "Opening rear camera"
        case .capturing:
            return "Recording pass"
        case .readyToFinish:
            return "Ready to finish"
        case .completed:
            return "Recording saved"
        case .blocked:
            return "Camera blocked"
        case .failed:
            return "Recording interrupted"
        }
    }

    public var operatorStage: StockpileCameraOperatorStage {
        if !permission.isGranted {
            return permission.requiresSettingsVisit ? .accessBlocked : .permissionRequired
        }

        if phase == .failed || recordingLifecycle == .failed || sessionLifecycle == .failed {
            return .failed
        }

        if recordingLifecycle == .finalizing {
            return .finalizingRecording
        }

        if phase == .completed || recordingLifecycle == .finished {
            return .recordingSaved
        }

        if canFinish || phase == .readyToFinish {
            return .readyToFinish
        }

        if recordingLifecycle == .starting || sessionLifecycle == .configuring || phase == .preparing {
            return .openingCamera
        }

        if recordingLifecycle == .recording || phase == .capturing {
            return .recordingLive
        }

        return .idle
    }

    public var operatorStageLabel: String {
        switch operatorStage {
        case .idle:
            return "Ready"
        case .permissionRequired:
            return "Needs access"
        case .accessBlocked:
            return "Access blocked"
        case .openingCamera:
            return "Opening"
        case .recordingLive:
            return "Recording"
        case .readyToFinish:
            return "Ready"
        case .finalizingRecording:
            return "Sealing"
        case .recordingSaved:
            return "Saved"
        case .failed:
            return "Needs attention"
        }
    }

    public var operatorHeadline: String {
        switch operatorStage {
        case .idle:
            return "Rear camera is ready"
        case .permissionRequired:
            return "Camera access is needed"
        case .accessBlocked:
            return "Camera access is off"
        case .openingCamera:
            return "Opening the rear camera"
        case .recordingLive:
            return "Recording is live"
        case .readyToFinish:
            return "This pass is ready to finish"
        case .finalizingRecording:
            return "Sealing the recording"
        case .recordingSaved:
            return "Recording saved on device"
        case .failed:
            return "Recording needs attention"
        }
    }

    public var operatorStageDetail: String {
        switch operatorStage {
        case .idle:
            return activePrompt.isEmpty ? "Start recording when the full pile and tagged references are in view." : activePrompt
        case .permissionRequired, .accessBlocked:
            return permission.operatorHint
        case .openingCamera:
            if activePrompt.isEmpty == false {
                return activePrompt
            }
            return "The rear camera is warming up and recording will begin automatically."
        case .recordingLive:
            return activePrompt
        case .readyToFinish:
            return activePrompt.isEmpty
                ? "Scene and references look strong enough to seal this clip."
                : activePrompt
        case .finalizingRecording:
            return "Hold steady while the clip is finalized locally and handed off for upload."
        case .recordingSaved:
            if recordingOutput != nil {
                return "The clip is sealed on device and ready for the server handoff."
            }
            return "The live pass is complete and ready to move on."
        case .failed:
            return lastErrorDescription ?? activePrompt
        }
    }

    public var operatorSystemImage: String {
        switch operatorStage {
        case .idle:
            return "camera.aperture"
        case .permissionRequired:
            return "camera.badge.ellipsis"
        case .accessBlocked:
            return "camera.fill.badge.xmark"
        case .openingCamera:
            return "camera.viewfinder"
        case .recordingLive:
            return "record.circle.fill"
        case .readyToFinish:
            return "checkmark.circle.fill"
        case .finalizingRecording:
            return "arrow.trianglehead.2.clockwise"
        case .recordingSaved:
            return "externaldrive.badge.checkmark"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    public var operatorShowsIndeterminateActivity: Bool {
        switch operatorStage {
        case .openingCamera, .finalizingRecording:
            return true
        case .idle, .permissionRequired, .accessBlocked, .recordingLive, .readyToFinish, .recordingSaved, .failed:
            return false
        }
    }

    public var operatorProgressValue: Double? {
        switch operatorStage {
        case .recordingLive, .readyToFinish, .recordingSaved:
            return progress
        case .idle, .permissionRequired, .accessBlocked, .openingCamera, .finalizingRecording, .failed:
            return nil
        }
    }

    public var operatorProgressLabel: String? {
        switch operatorStage {
        case .idle:
            return nil
        case .permissionRequired:
            return "Waiting for access"
        case .accessBlocked:
            return "Open Settings to continue"
        case .openingCamera:
            return "Opening rear camera"
        case .recordingLive:
            return checkpointLabel
        case .readyToFinish:
            return "Capture pass complete"
        case .finalizingRecording:
            return "Sealing local recording"
        case .recordingSaved:
            return "Clip sealed on device"
        case .failed:
            return "Recording interrupted"
        }
    }

    public var operatorProgressSummary: String? {
        switch operatorStage {
        case .recordingLive:
            let total = max(totalSteps, 1)
            let current = min(max(completedSteps + 1, 1), total)
            return "\(current)/\(total)"
        case .readyToFinish, .recordingSaved:
            return "Complete"
        case .idle, .permissionRequired, .accessBlocked, .openingCamera, .finalizingRecording, .failed:
            return nil
        }
    }

    private var checkpointLabel: String {
        let total = max(totalSteps, 1)
        let current = min(max(completedSteps + 1, 1), total)
        return "Checkpoint \(current) of \(total)"
    }

    public static func idle(permission: StockpileCameraPermissionState = .preview) -> StockpileCameraCaptureSessionState {
        StockpileCameraCaptureSessionState(
            phase: .idle,
            permission: permission,
            guidance: .watchPreview,
            completedSteps: 0,
            totalSteps: 3,
            activePrompt: permission.isGranted
                ? "Start recording when the full pile and two tagged references are in view."
                : permission.operatorHint,
            sessionLifecycle: permission.isGranted ? .unconfigured : .permissionRequired,
            recordingLifecycle: .idle
        )
    }

    public static func blocked(permission: StockpileCameraPermissionState = .blockedPreview) -> StockpileCameraCaptureSessionState {
        StockpileCameraCaptureSessionState(
            phase: .blocked,
            permission: permission,
            guidance: .watchPreview,
            completedSteps: 0,
            totalSteps: 3,
            activePrompt: permission.operatorHint,
            sessionLifecycle: .permissionRequired,
            recordingLifecycle: .idle
        )
    }

    public static func failed(
        permission: StockpileCameraPermissionState = .preview,
        message: String,
        activeDeviceName: String? = nil
    ) -> StockpileCameraCaptureSessionState {
        StockpileCameraCaptureSessionState(
            phase: .failed,
            permission: permission,
            guidance: .watchPreview,
            completedSteps: 0,
            totalSteps: 3,
            activePrompt: message,
            sessionLifecycle: .failed,
            recordingLifecycle: .failed,
            activeDeviceName: activeDeviceName,
            lastErrorDescription: message,
            debugTraceSummary: "failed: \(message)"
        )
    }
}

public protocol StockpileCameraCaptureSessionServicing: AnyObject {
    var state: StockpileCameraCaptureSessionState { get }

    func startGuidedCapture()
    func advanceGuidedCapture()
    func finishGuidedCapture()
    func reset()
    func refreshPermissionState()
    @discardableResult func requestCameraAccess() async -> StockpileCameraPermissionState
    func startCaptureSession()
    func stopCaptureSession()
    func startRecording()
    func stopRecording()
}

public extension StockpileCameraCaptureSessionServicing {
    func refreshPermissionState() {}

    @discardableResult
    func requestCameraAccess() async -> StockpileCameraPermissionState {
        state.permission
    }

    func startCaptureSession() {}

    func stopCaptureSession() {}

    func startRecording() {}

    func stopRecording() {}
}

public final class StockpileCameraCaptureSessionMock: StockpileCameraCaptureSessionServicing {
    public private(set) var state: StockpileCameraCaptureSessionState

    private let checkpoints: [StockpileCaptureGuidanceSummary]
    private var currentStepIndex: Int
    private var recordingStartedAt: Date?

    public init(
        permission: StockpileCameraPermissionState = .preview,
        checkpoints: [StockpileCaptureGuidanceSummary] = StockpileCameraCaptureSessionMock.demoCheckpoints
    ) {
        self.checkpoints = checkpoints.isEmpty ? Self.demoCheckpoints : checkpoints
        self.currentStepIndex = 0
        self.recordingStartedAt = nil

        if permission.isGranted {
            self.state = StockpileCameraCaptureSessionState.idle(permission: permission)
        } else {
            self.state = StockpileCameraCaptureSessionState.blocked(permission: permission)
        }
    }

    public func startGuidedCapture() {
        guard state.permission.isGranted else {
            state = .blocked(permission: state.permission)
            return
        }

        currentStepIndex = 0
        recordingStartedAt = Date()
        applyCheckpoint(at: currentStepIndex, phase: .capturing, activePrompt: "Walk the toe boundary and keep two tagged references visible together.")
        state.recordingLifecycle = .recording
        state.recordingOutput = nil
    }

    public func advanceGuidedCapture() {
        guard state.phase == .capturing else {
            return
        }

        guard currentStepIndex < checkpoints.count - 1 else {
            state.phase = state.guidance.isReadyToFinish ? .readyToFinish : .capturing
            state.activePrompt = state.guidance.primaryOperatorAction
            return
        }

        currentStepIndex += 1

        let nextGuidance = checkpoints[currentStepIndex]
        let nextPhase: StockpileCameraCaptureSessionPhase = nextGuidance.isReadyToFinish && currentStepIndex == checkpoints.count - 1 ? .readyToFinish : .capturing
        applyCheckpoint(at: currentStepIndex, phase: nextPhase, activePrompt: nextGuidance.primaryOperatorAction)
    }

    public func finishGuidedCapture() {
        guard state.canFinish else {
            return
        }

        state.phase = .completed
        state.completedSteps = max(checkpoints.count - 1, 0)
        state.activePrompt = "Recording sealed. Preparing the upload handoff."
        finalizeRecording()
    }

    public func reset() {
        currentStepIndex = 0
        recordingStartedAt = nil
        state = state.permission.isGranted ? .idle(permission: state.permission) : .blocked(permission: state.permission)
    }

    public func startRecording() {
        guard state.permission.isGranted else {
            state = .blocked(permission: state.permission)
            return
        }

        if state.phase == .idle {
            currentStepIndex = 0
            applyCheckpoint(
                at: currentStepIndex,
                phase: .capturing,
                activePrompt: "Recording in app. Keep moving steadily around the pile."
            )
        }

        recordingStartedAt = Date()
        state.recordingLifecycle = .recording
        state.recordingOutput = nil
        state.lastErrorDescription = nil
    }

    public func stopRecording() {
        finalizeRecording()
    }

    private func applyCheckpoint(
        at index: Int,
        phase: StockpileCameraCaptureSessionPhase,
        activePrompt: String
    ) {
        let guidance = checkpoints[index]
        state = StockpileCameraCaptureSessionState(
            phase: phase,
            permission: state.permission,
            guidance: guidance,
            completedSteps: index,
            totalSteps: checkpoints.count,
            activePrompt: activePrompt,
            sessionLifecycle: state.sessionLifecycle,
            recordingLifecycle: state.recordingLifecycle,
            recordingOutput: state.recordingOutput,
            activeDeviceName: state.activeDeviceName,
            lastErrorDescription: state.lastErrorDescription
        )
    }

    private func finalizeRecording() {
        guard state.recordingLifecycle.isActive || state.recordingLifecycle == .finalizing else {
            return
        }

        let startedAt = recordingStartedAt ?? Date()
        let finishedAt = Date()
        let output = StockpileCameraRecordingOutput(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("stockpile-mock-capture.mov"),
            fileSizeBytes: nil,
            startedAt: startedAt,
            finishedAt: finishedAt
        )

        state.recordingLifecycle = .finished
        state.recordingOutput = output
        recordingStartedAt = nil
    }

    public static let demoCheckpoints: [StockpileCaptureGuidanceSummary] = [
        StockpileCaptureGuidanceSummary(
            referenceVisibility: StockpileCaptureGuidanceMetric(
                title: "Reference visibility",
                score: 0.58,
                watchThreshold: 0.7,
                blockedThreshold: 0.45,
                detail: "Move until two tagged references stay in frame together."
            ),
            coverage: StockpileCaptureGuidanceMetric(
                title: "Coverage",
                score: 0.41,
                watchThreshold: 0.7,
                blockedThreshold: 0.5,
                detail: "Complete the far edge before finishing the walkaround."
            ),
            motion: StockpileCaptureGuidanceMetric(
                title: "Motion",
                score: 0.62,
                watchThreshold: 0.72,
                blockedThreshold: 0.5,
                detail: "Slow down to reduce camera swing."
            ),
            decodedReferenceQuality: StockpileCaptureGuidanceMetric(
                title: "Reference quality",
                score: 0.46,
                watchThreshold: 0.76,
                blockedThreshold: 0.52,
                detail: "Only one tagged reference looks stable. Pan until a second joins."
            ),
            sceneFit: StockpileCaptureGuidanceMetric(
                title: "Scene framing",
                score: 0.7,
                watchThreshold: 0.72,
                blockedThreshold: 0.48,
                detail: "Widen slightly so the pile stays dominant."
            ),
            sceneRejection: StockpileCaptureGuidanceMetric(
                title: "Scene match",
                score: 0.74,
                watchThreshold: 0.78,
                blockedThreshold: 0.5,
                detail: "Keep more of the pile face in view."
            )
        ),
        StockpileCaptureGuidanceSummary(
            referenceVisibility: StockpileCaptureGuidanceMetric(
                title: "Reference visibility",
                score: 0.76,
                watchThreshold: 0.7,
                blockedThreshold: 0.45,
                detail: "Keep the tagged references paired in frame."
            ),
            coverage: StockpileCaptureGuidanceMetric(
                title: "Coverage",
                score: 0.74,
                watchThreshold: 0.7,
                blockedThreshold: 0.5,
                detail: "The perimeter is getting close to full coverage."
            ),
            motion: StockpileCaptureGuidanceMetric(
                title: "Motion",
                score: 0.78,
                watchThreshold: 0.72,
                blockedThreshold: 0.5,
                detail: "Motion stability is improving."
            ),
            decodedReferenceQuality: StockpileCaptureGuidanceMetric(
                title: "Reference quality",
                score: 0.74,
                watchThreshold: 0.76,
                blockedThreshold: 0.52,
                detail: "Keep the tagged references square to the camera."
            ),
            sceneFit: StockpileCaptureGuidanceMetric(
                title: "Scene framing",
                score: 0.82,
                watchThreshold: 0.72,
                blockedThreshold: 0.48,
                detail: "Pile framing looks steady."
            ),
            sceneRejection: StockpileCaptureGuidanceMetric(
                title: "Scene match",
                score: 0.88,
                watchThreshold: 0.78,
                blockedThreshold: 0.5,
                detail: "Scene matches a stockpile capture."
            ),
            materialConfidence: StockpileCaptureGuidanceMetric(
                title: "Material confidence",
                score: 0.64,
                watchThreshold: 0.72,
                blockedThreshold: 0.12,
                detail: "Material read is settling. Keep the pile centered."
            )
        ),
        StockpileCaptureGuidanceSummary.preview
    ]
}
