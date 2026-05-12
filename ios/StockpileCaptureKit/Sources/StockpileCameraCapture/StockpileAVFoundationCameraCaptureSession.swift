import AVFoundation
import Foundation
import ImageIO
#if canImport(Vision)
import Vision
#endif

private enum StockpileCameraCaptureTrace {
    private static let traceFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("stockpile_recording_trace.log")
    }()
    private static let lock = NSLock()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ event: String, details: String = "") {
        let message = details.isEmpty ? event : "\(event) | \(details)"
        NSLog("STOCKPILE_CAPTURE_TRACE %@", message)
        appendToFile(message)
    }

    static func stateDetails(_ state: StockpileCameraCaptureSessionState) -> String {
        [
            "phase=\(state.phase.rawValue)",
            "session=\(state.sessionLifecycle.rawValue)",
            "recording=\(state.recordingLifecycle.rawValue)",
            "permission=\(state.permission.status.rawValue)",
            "canFinish=\(state.canFinish)",
            "prompt=\(state.activePrompt)",
        ].joined(separator: " ")
    }

    private static func appendToFile(_ line: String) {
        let stamped = "[\(dateFormatter.string(from: Date()))] CAM | \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: traceFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: traceFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: traceFileURL, options: .atomic)
        }
    }
}

public enum StockpileCameraLensPosition: String, Codable, Sendable, CaseIterable {
    case back
    case front
    case unspecified
}

struct StockpileCaptureNormalizedRegion: Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        let clampedX = min(max(Double(rect.origin.x), 0), 1)
        let clampedY = min(max(Double(rect.origin.y), 0), 1)
        let maximumX = min(max(Double(rect.maxX), clampedX), 1)
        let maximumY = min(max(Double(rect.maxY), clampedY), 1)
        x = clampedX
        y = clampedY
        width = maximumX - clampedX
        height = maximumY - clampedY
    }
}

enum StockpileCaptureReferenceObservationSource: String, Sendable, CaseIterable {
    case barcode
    case ocr
    case tagLike
}

struct StockpileCaptureReferenceObservation: Sendable, Equatable, Identifiable {
    let id: String
    let markerID: String?
    let source: StockpileCaptureReferenceObservationSource
    let confidence: Double
    let stabilityScore: Double
    let framesObserved: Int
    let region: StockpileCaptureNormalizedRegion

    init(
        id: String,
        markerID: String?,
        source: StockpileCaptureReferenceObservationSource,
        confidence: Double,
        stabilityScore: Double,
        framesObserved: Int,
        region: StockpileCaptureNormalizedRegion
    ) {
        self.id = id
        self.markerID = markerID
        self.source = source
        self.confidence = min(max(confidence, 0), 1)
        self.stabilityScore = min(max(stabilityScore, 0), 1)
        self.framesObserved = max(0, framesObserved)
        self.region = region
    }
}

struct StockpileCaptureMaterialFamilySuggestion: Sendable, Equatable {
    let familyCode: String
    let label: String
    let confidence: Double

    init(
        familyCode: String,
        label: String,
        confidence: Double
    ) {
        self.familyCode = familyCode
        self.label = label
        self.confidence = min(max(confidence, 0), 1)
    }
}

enum StockpileCaptureSceneRejectionReason: String, Sendable, CaseIterable {
    case screenLikeDisplay
    case nearbyEquipment
    case textHeavyForeground
}

struct StockpileCaptureSceneDiagnostics: Sendable, Equatable {
    let capturedAt: Date
    let referenceObservations: [StockpileCaptureReferenceObservation]
    let materialFamilySuggestion: StockpileCaptureMaterialFamilySuggestion?
    let screenLikelihood: Double
    let equipmentLikelihood: Double
    let textLikelihood: Double
    let rejectionReasons: [StockpileCaptureSceneRejectionReason]
    let supportingLabels: [String]

    init(
        capturedAt: Date,
        referenceObservations: [StockpileCaptureReferenceObservation],
        materialFamilySuggestion: StockpileCaptureMaterialFamilySuggestion?,
        screenLikelihood: Double,
        equipmentLikelihood: Double,
        textLikelihood: Double,
        rejectionReasons: [StockpileCaptureSceneRejectionReason],
        supportingLabels: [String]
    ) {
        self.capturedAt = capturedAt
        self.referenceObservations = referenceObservations
        self.materialFamilySuggestion = materialFamilySuggestion
        self.screenLikelihood = Self.clamp(screenLikelihood)
        self.equipmentLikelihood = Self.clamp(equipmentLikelihood)
        self.textLikelihood = Self.clamp(textLikelihood)
        self.rejectionReasons = rejectionReasons
        self.supportingLabels = Array(supportingLabels.prefix(4))
    }

    var primaryOperatorAction: String? {
        if rejectionReasons.contains(.screenLikeDisplay) || rejectionReasons.contains(.textHeavyForeground) {
            return "Move off the screen or sign and reframe onto the stockpile with tagged references in view."
        }

        if rejectionReasons.contains(.nearbyEquipment) {
            return "Step back and reframe so the stockpile fills the shot instead of nearby equipment."
        }

        let decodedMarkerIDs = referenceObservations.compactMap(\.markerID)
        if decodedMarkerIDs.count >= 2 {
            let visibleIDs = Array(decodedMarkerIDs.prefix(2)).joined(separator: " and ")
            return "Tagged references \(visibleIDs) are reading cleanly. Keep them in frame while you finish the lap."
        }

        if let decodedMarkerID = decodedMarkerIDs.first {
            return "Keep \(decodedMarkerID) in view and pan until a second tagged reference locks."
        }

        return nil
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

protocol StockpileCameraPlatform {
    func currentPermissionState() -> StockpileCameraPermissionState
    func requestCameraAccess() async -> StockpileCameraPermissionState
    func makeSessionController(
        preferredPosition: StockpileCameraLensPosition,
        lidarAssistEnabled: Bool
    ) throws -> any StockpileCameraSessionControlling
}

protocol StockpileCameraSessionControlling: AnyObject {
    var captureSession: AVCaptureSession { get }
    var deviceLabel: String { get }
    var isRunning: Bool { get }
    var isRecording: Bool { get }
    var videoWidth: Int? { get }
    var videoHeight: Int? { get }
    var videoFrameRate: Double? { get }
    var videoStabilizationModeLabel: String? { get }
    var supportsDepthDataDelivery: Bool { get }
    var latestSceneAnalysis: StockpileCaptureSceneAnalysis? { get }
    var latestSceneDiagnostics: StockpileCaptureSceneDiagnostics? { get }

    func startRunning()
    func waitUntilRunning(timeout: TimeInterval) -> Bool
    func stopRunning()
    func startRecording(
        to outputURL: URL,
        delegate: any StockpileCameraSessionRecordingDelegate
    ) throws
    func stopRecording()
}

protocol StockpileCameraSessionRecordingDelegate: AnyObject {
    func cameraSessionController(
        _ controller: any StockpileCameraSessionControlling,
        didStartRecordingTo outputURL: URL
    )

    func cameraSessionController(
        _ controller: any StockpileCameraSessionControlling,
        didFinishRecordingTo outputURL: URL,
        error: Error?
    )
}

extension StockpileCameraSessionControlling {
    var latestSceneDiagnostics: StockpileCaptureSceneDiagnostics? { nil }

    func waitUntilRunning(timeout: TimeInterval) -> Bool {
        guard timeout > 0 else {
            return isRunning
        }

        let deadline = Date().addingTimeInterval(timeout)
        while isRunning == false && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        return isRunning
    }
}

public final class StockpileCameraCaptureSessionLive: StockpileCameraCaptureSessionServicing, StockpileCaptureDeviceTelemetryProviding, @unchecked Sendable {
    public var state: StockpileCameraCaptureSessionState {
        storageQueue.sync { storage.state }
    }

    public var latestTelemetrySnapshot: StockpileCaptureSensorSnapshot? {
        telemetryRuntime.latestSnapshot
    }

    public var captureSession: AVCaptureSession? {
        storageQueue.sync { storage.controller?.captureSession }
    }

    private struct Storage {
        var state: StockpileCameraCaptureSessionState
        var currentStepIndex: Int
        var controller: (any StockpileCameraSessionControlling)?
        var pendingRecording: PendingRecording?
        var pendingRecordingStartupID: UUID?
        var stopSessionAfterRecordingFinalize: Bool
        var sceneCoverageAccumulator: Double
        var lastSceneAnalysisAt: Date?
        var guidanceRefreshID: UUID?
    }

    private struct PendingRecording {
        let outputURL: URL
        let startedAt: Date
    }

    private enum RecordingStartupTimeoutOutcome {
        case ignored
        case recorderAlreadyActive
        case timedOut(activeController: (any StockpileCameraSessionControlling)?)
    }

    private let preferredPosition: StockpileCameraLensPosition
    private let checkpoints: [StockpileCaptureGuidanceSummary]
    private let platform: any StockpileCameraPlatform
    private let lidarAssistEnabled: Bool
    private let markerlessCaptureEnabled: Bool
    private let recordingsDirectory: URL
    private let recordingStartupTimeout: TimeInterval
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let telemetryRuntime: any StockpileCaptureDeviceTelemetryRuntime
    private let sessionQueue = DispatchQueue(label: "com.clustox.stockpile.camera.session")
    private let storageQueue = DispatchQueue(label: "com.clustox.stockpile.camera.storage")
    private var storage: Storage

    public init(
        preferredPosition: StockpileCameraLensPosition = .back,
        checkpoints: [StockpileCaptureGuidanceSummary] = StockpileCameraCaptureSessionMock.demoCheckpoints,
        lidarAssistEnabled: Bool = true,
        markerlessCaptureEnabled: Bool = false,
        recordingStartupTimeout: TimeInterval = 5,
        recordingsDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StockpileCaptures",
            isDirectory: true
        )
    ) {
        self.preferredPosition = preferredPosition
        self.checkpoints = checkpoints.isEmpty ? StockpileCameraCaptureSessionMock.demoCheckpoints : checkpoints
        self.platform = StockpileAVFoundationCameraPlatform()
        self.lidarAssistEnabled = lidarAssistEnabled
        self.markerlessCaptureEnabled = markerlessCaptureEnabled
        self.recordingsDirectory = recordingsDirectory
        self.recordingStartupTimeout = recordingStartupTimeout
        self.fileManager = .default
        self.now = { Date() }
        let telemetryRuntime = StockpileMotionAndCapabilityTelemetryRuntime()
        self.telemetryRuntime = telemetryRuntime

        let permission = platform.currentPermissionState()
        self.storage = Storage(
            state: permission.isGranted
                ? .idle(permission: permission)
                : Self.initialState(for: permission),
            currentStepIndex: 0,
            controller: nil,
            pendingRecording: nil,
            pendingRecordingStartupID: nil,
            stopSessionAfterRecordingFinalize: false,
            sceneCoverageAccumulator: 0,
            lastSceneAnalysisAt: nil,
            guidanceRefreshID: nil
        )

        telemetryRuntime.onSnapshotUpdated = { [weak self] snapshot in
            guard let self else {
                return
            }

            self.storageQueue.sync {
                self.storage.state.sensorSnapshot = snapshot
            }

            self.sessionQueue.async { [weak self] in
                self?.refreshLiveGuidanceIfPossible()
            }
        }
    }

    init(
        preferredPosition: StockpileCameraLensPosition = .back,
        checkpoints: [StockpileCaptureGuidanceSummary] = StockpileCameraCaptureSessionMock.demoCheckpoints,
        platform: any StockpileCameraPlatform,
        lidarAssistEnabled: Bool = true,
        markerlessCaptureEnabled: Bool = false,
        recordingStartupTimeout: TimeInterval = 5,
        recordingsDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StockpileCaptures",
            isDirectory: true
        ),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        telemetryRuntime: any StockpileCaptureDeviceTelemetryRuntime = StockpileMotionAndCapabilityTelemetryRuntime()
    ) {
        self.preferredPosition = preferredPosition
        self.checkpoints = checkpoints.isEmpty ? StockpileCameraCaptureSessionMock.demoCheckpoints : checkpoints
        self.platform = platform
        self.lidarAssistEnabled = lidarAssistEnabled
        self.markerlessCaptureEnabled = markerlessCaptureEnabled
        self.recordingsDirectory = recordingsDirectory
        self.recordingStartupTimeout = recordingStartupTimeout
        self.fileManager = fileManager
        self.now = now
        self.telemetryRuntime = telemetryRuntime

        let permission = platform.currentPermissionState()
        self.storage = Storage(
            state: permission.isGranted
                ? .idle(permission: permission)
                : Self.initialState(for: permission),
            currentStepIndex: 0,
            controller: nil,
            pendingRecording: nil,
            pendingRecordingStartupID: nil,
            stopSessionAfterRecordingFinalize: false,
            sceneCoverageAccumulator: 0,
            lastSceneAnalysisAt: nil,
            guidanceRefreshID: nil
        )

        telemetryRuntime.onSnapshotUpdated = { [weak self] snapshot in
            guard let self else {
                return
            }

            self.storageQueue.sync {
                self.storage.state.sensorSnapshot = snapshot
            }

            self.sessionQueue.async { [weak self] in
                self?.refreshLiveGuidanceIfPossible()
            }
        }
    }

    deinit {
        telemetryRuntime.stopSampling()
    }

    public func refreshPermissionState() {
        let permission = platform.currentPermissionState()
        let shouldStopRunning = storageQueue.sync { storage.controller?.isRunning == true && !permission.isGranted }
        StockpileCameraCaptureTrace.log(
            "refreshPermissionState",
            details: "permission=\(permission.status.rawValue) canRequest=\(permission.canRequestAccess) shouldStopRunning=\(shouldStopRunning)"
        )

        storageQueue.sync {
            storage.state.permission = permission
            storage.state.debugTraceSummary = "permission \(permission.status.rawValue)"

            guard !permission.isGranted else {
                storage.state.sessionLifecycle = Self.lifecycle(
                    for: permission,
                    controller: storage.controller
                )
                if storage.state.phase == .blocked || storage.state.phase == .failed {
                    storage.state = StockpileCameraCaptureSessionState.idle(permission: permission)
                    storage.state.activeDeviceName = storage.controller?.deviceLabel
                    storage.state.sensorSnapshot = telemetryRuntime.latestSnapshot
                    storage.state.sessionLifecycle = Self.lifecycle(
                        for: permission,
                        controller: storage.controller
                    )
                }
                return
            }

            storage.state.phase = permission.status == .notDetermined ? .idle : .blocked
            storage.state.sessionLifecycle = .permissionRequired
            storage.state.activePrompt = permission.operatorHint
            storage.state.lastErrorDescription = nil
            storage.state.debugTraceSummary = "permission blocked: \(permission.status.rawValue)"
        }

        if shouldStopRunning {
            stopCaptureSession()
        }
    }

    @discardableResult
    public func requestCameraAccess() async -> StockpileCameraPermissionState {
        refreshPermissionState()
        let existingPermission = state.permission

        guard existingPermission.canRequestAccess else {
            return existingPermission
        }

        let permission = await platform.requestCameraAccess()

        storageQueue.sync {
            storage.state.permission = permission

            guard permission.isGranted else {
                storage.state.phase = permission.status == .notDetermined ? .idle : .blocked
                storage.state.sessionLifecycle = .permissionRequired
                storage.state.activePrompt = permission.operatorHint
                storage.state.lastErrorDescription = nil
                return
            }

            storage.state = StockpileCameraCaptureSessionState.idle(permission: permission)
            storage.state.activeDeviceName = storage.controller?.deviceLabel
            storage.state.sensorSnapshot = telemetryRuntime.latestSnapshot
            storage.state.sessionLifecycle = Self.lifecycle(
                for: permission,
                controller: storage.controller
            )
        }

        return permission
    }

    public func startCaptureSession() {
        startCaptureSession(shouldStartRecording: false)
    }

    public func stopCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let controller = self.storageQueue.sync { self.storage.controller }

            guard let controller else {
                self.storageQueue.sync {
                    self.storage.guidanceRefreshID = nil
                    self.storage.state.sessionLifecycle = self.storage.state.permission.isGranted ? .unconfigured : .permissionRequired
                }
                return
            }

            if controller.isRecording || self.storageQueue.sync(execute: { self.storage.state.recordingLifecycle == .starting }) {
                self.storageQueue.sync {
                    self.storage.stopSessionAfterRecordingFinalize = true
                    if self.storage.state.recordingLifecycle == .starting || self.storage.state.recordingLifecycle == .recording {
                        self.storage.state.recordingLifecycle = .finalizing
                    }
                }
                controller.stopRecording()
                return
            }

            if controller.isRunning {
                controller.stopRunning()
            }

            self.telemetryRuntime.stopSampling()

            self.storageQueue.sync {
                self.storage.stopSessionAfterRecordingFinalize = false
                self.storage.guidanceRefreshID = nil
                self.storage.state.sessionLifecycle = Self.lifecycle(
                    for: self.storage.state.permission,
                    controller: controller
                )
            }
        }
    }

    public func startRecording() {
        refreshPermissionState()

        let permission = state.permission
        StockpileCameraCaptureTrace.log(
            "manualStartRecording.requested",
            details: StockpileCameraCaptureTrace.stateDetails(state)
        )
        guard permission.isGranted else {
            storageQueue.sync {
                storage.state = permission.status == .notDetermined
                    ? Self.initialState(for: permission)
                    : .blocked(permission: permission)
                storage.state.debugTraceSummary = "manual recording blocked: permission \(permission.status.rawValue)"
            }
            return
        }

        storageQueue.sync {
            if storage.state.phase == .idle {
                storage.currentStepIndex = 0
                storage.state.phase = .capturing
                storage.state.activePrompt = "Recording local capture. Keep moving steadily around the pile."
            }
            storage.state.recordingLifecycle = .starting
            storage.state.recordingOutput = nil
            storage.state.lastErrorDescription = nil
            storage.state.debugTraceSummary = "manual recording requested"
        }

        startCaptureSession(shouldStartRecording: true)
    }

    public func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let controller = self.storageQueue.sync { self.storage.controller }

            guard let controller else {
                return
            }

            let shouldStop = self.storageQueue.sync { self.storage.stopSessionAfterRecordingFinalize }
            if controller.isRecording || self.storageQueue.sync(execute: { self.storage.state.recordingLifecycle == .starting }) {
                self.storageQueue.sync {
                    self.storage.state.recordingLifecycle = .finalizing
                    self.storage.stopSessionAfterRecordingFinalize = shouldStop
                }
                controller.stopRecording()
            }
        }
    }

    public func startGuidedCapture() {
        refreshPermissionState()

        let permission = state.permission
        StockpileCameraCaptureTrace.log(
            "guidedStart.requested",
            details: StockpileCameraCaptureTrace.stateDetails(state)
        )
        guard permission.isGranted else {
            storageQueue.sync {
                storage.state = permission.status == .notDetermined
                    ? Self.initialState(for: permission)
                    : .blocked(permission: permission)
                storage.state.debugTraceSummary = "guided start blocked: permission \(permission.status.rawValue)"
            }
            return
        }

        if markerlessCaptureEnabled {
            startMarkerlessGuidedCapture(permission: permission)
            return
        }

        storageQueue.sync {
            storage.currentStepIndex = 0
            let guidance = checkpoints[0]
            storage.state = StockpileCameraCaptureSessionState(
                phase: .capturing,
                permission: permission,
                guidance: guidance,
                sensorSnapshot: telemetryRuntime.latestSnapshot,
                completedSteps: 0,
                totalSteps: checkpoints.count,
                activePrompt: markerlessCaptureEnabled
                    ? "Walk slowly around the pile, keeping the full pile in frame."
                    : "Frame the pile and keep two references visible.",
                sessionLifecycle: storage.controller?.isRunning == true ? .running : .configuring,
                recordingLifecycle: .starting,
                activeDeviceName: storage.controller?.deviceLabel
            )
            storage.state.debugTraceSummary = "guided start requested"
            storage.pendingRecording = nil
            storage.stopSessionAfterRecordingFinalize = false
            storage.sceneCoverageAccumulator = 0
            storage.lastSceneAnalysisAt = nil
            storage.guidanceRefreshID = nil
        }

        startCaptureSession(shouldStartRecording: true)
    }

    private func startMarkerlessGuidedCapture(permission: StockpileCameraPermissionState) {
        let startedAt = now()
        let outputURL = recordingsDirectory.appendingPathComponent(
            "markerless-\(UUID().uuidString).stockpilecapture"
        )
        storageQueue.sync {
            storage.currentStepIndex = 0
            storage.sceneCoverageAccumulator = 0
            storage.lastSceneAnalysisAt = nil
            storage.guidanceRefreshID = nil
            storage.pendingRecording = PendingRecording(outputURL: outputURL, startedAt: startedAt)
            storage.pendingRecordingStartupID = nil
            storage.stopSessionAfterRecordingFinalize = false
            storage.state = StockpileCameraCaptureSessionState(
                phase: .capturing,
                permission: permission,
                guidance: checkpoints[0],
                sensorSnapshot: telemetryRuntime.latestSnapshot,
                completedSteps: 0,
                totalSteps: checkpoints.count,
                activePrompt: "Walk slowly around the pile, keeping the full pile in frame.",
                sessionLifecycle: .running,
                recordingLifecycle: .recording,
                activeDeviceName: "iPhone LiDAR"
            )
            storage.state.debugTraceSummary = "markerless ARKit bundle capture active"
        }
        beginGuidanceRefreshLoop()
    }

    public func advanceGuidedCapture() {
        storageQueue.sync {
            guard storage.state.phase == .capturing else {
                return
            }

            guard storage.currentStepIndex < checkpoints.count - 1 else {
                storage.state.phase = storage.state.guidance.isReadyToFinish ? .readyToFinish : .capturing
                storage.state.activePrompt = storage.state.guidance.primaryOperatorAction
                return
            }

            storage.currentStepIndex += 1

            if refreshLiveGuidance(using: storage.controller, storage: &storage) {
                return
            }

            let nextGuidance = checkpoints[storage.currentStepIndex]
            let nextPhase: StockpileCameraCaptureSessionPhase =
                nextGuidance.isReadyToFinish && storage.currentStepIndex == checkpoints.count - 1
                ? .readyToFinish
                : .capturing

            applyCheckpoint(
                at: storage.currentStepIndex,
                guidance: nextGuidance,
                phase: nextPhase,
                activePrompt: nextGuidance.primaryOperatorAction,
                storage: &storage
            )
        }
    }

    public func finishGuidedCapture() {
        let canFinish = state.canFinish
        guard canFinish else {
            return
        }

        if markerlessCaptureEnabled {
            storageQueue.sync {
                storage.state.phase = .completed
                storage.state.completedSteps = max(checkpoints.count - 1, 0)
                storage.state.recordingLifecycle = .finished
                storage.state.activePrompt = "LiDAR bundle sealed on device."
                storage.state.lastErrorDescription = nil
                storage.guidanceRefreshID = nil
            }
            return
        }

        let shouldFinalizeRecording = storageQueue.sync {
            storage.state.recordingLifecycle == .starting || storage.state.recordingLifecycle == .recording
        }

        storageQueue.sync {
            storage.state.phase = .completed
            storage.state.completedSteps = max(checkpoints.count - 1, 0)
            storage.state.activePrompt = shouldFinalizeRecording
                ? "Finalizing local capture."
                : "Capture complete. The run is ready for upload."
            storage.state.lastErrorDescription = nil
            storage.stopSessionAfterRecordingFinalize = true
            storage.guidanceRefreshID = nil
        }

        if shouldFinalizeRecording {
            stopRecording()
        } else {
            stopCaptureSession()
        }
    }

    public func reset() {
        stopCaptureSession()

        storageQueue.sync {
            let permission = storage.state.permission
            storage.currentStepIndex = 0
            storage.pendingRecording = nil
            storage.pendingRecordingStartupID = nil
            storage.stopSessionAfterRecordingFinalize = false
            storage.sceneCoverageAccumulator = 0
            storage.lastSceneAnalysisAt = nil
            storage.guidanceRefreshID = nil

            if permission.isGranted {
                storage.state = StockpileCameraCaptureSessionState.idle(permission: permission)
                storage.state.activeDeviceName = storage.controller?.deviceLabel
                storage.state.sensorSnapshot = telemetryRuntime.latestSnapshot
                storage.state.sessionLifecycle = Self.lifecycle(
                    for: permission,
                    controller: storage.controller
                )
            } else {
                storage.state = permission.status == .notDetermined
                    ? Self.initialState(for: permission)
                    : .blocked(permission: permission)
            }
        }
    }

    private func startCaptureSession(shouldStartRecording: Bool) {
        let permission = state.permission
        StockpileCameraCaptureTrace.log(
            "startCaptureSession.enter",
            details: "shouldStartRecording=\(shouldStartRecording) \(StockpileCameraCaptureTrace.stateDetails(state))"
        )

        guard permission.isGranted else {
            storageQueue.sync {
                storage.state = permission.status == .notDetermined
                    ? Self.initialState(for: permission)
                    : .blocked(permission: permission)
                storage.state.debugTraceSummary = "session start blocked: permission \(permission.status.rawValue)"
            }
            return
        }

        storageQueue.sync {
            if storage.state.sessionLifecycle != .running {
                storage.state.sessionLifecycle = .configuring
            }
            if shouldStartRecording {
                storage.state.recordingLifecycle = .starting
                storage.state.recordingOutput = nil
            }
            storage.state.lastErrorDescription = nil
            storage.state.debugTraceSummary = shouldStartRecording
                ? "session configuring for recording"
                : "session configuring preview"
        }

        sessionQueue.async { [weak self] in
            self?.configureAndStartSession(shouldStartRecording: shouldStartRecording)
        }
    }

    private func configureAndStartSession(shouldStartRecording: Bool) {
        let controller: any StockpileCameraSessionControlling
        StockpileCameraCaptureTrace.log(
            "configureAndStartSession.begin",
            details: "shouldStartRecording=\(shouldStartRecording)"
        )

        do {
            if let existingController = storageQueue.sync(execute: { storage.controller }) {
                controller = existingController
                StockpileCameraCaptureTrace.log(
                    "configureAndStartSession.usingExistingController",
                    details: "running=\(existingController.isRunning) recording=\(existingController.isRecording)"
                )
            } else {
                StockpileCameraCaptureTrace.log(
                    "configureAndStartSession.makeController",
                    details: "preferred=\(preferredPosition.rawValue) lidarAssist=\(lidarAssistEnabled)"
                )
                let newController = try platform.makeSessionController(
                    preferredPosition: preferredPosition,
                    lidarAssistEnabled: lidarAssistEnabled
                )
                controller = newController

                storageQueue.sync {
                    storage.controller = newController
                    storage.state.activeDeviceName = newController.deviceLabel
                    if storage.state.sessionLifecycle != .running {
                        storage.state.sessionLifecycle = .ready
                    }
                    storage.state.debugTraceSummary = "controller ready: \(newController.deviceLabel)"
                }
            }

            StockpileCameraCaptureTrace.log(
                "configureAndStartSession.startRunning.before",
                details: "running=\(controller.isRunning) recording=\(controller.isRecording)"
            )
            controller.startRunning()
            let isRunning = controller.waitUntilRunning(timeout: 1.5)
            guard isRunning else {
                StockpileCameraCaptureTrace.log("configureAndStartSession.sessionDidNotStart")
                throw StockpileAVFoundationCameraError.sessionDidNotStart
            }

            telemetryRuntime.startSampling(
                configuration: telemetryConfiguration(for: controller)
            )

            storageQueue.sync {
                storage.state.sessionLifecycle = .running
                storage.state.activeDeviceName = controller.deviceLabel
                storage.state.sensorSnapshot = telemetryRuntime.latestSnapshot
                storage.state.debugTraceSummary = "session running on \(controller.deviceLabel)"
            }
            StockpileCameraCaptureTrace.log(
                "configureAndStartSession.startRunning.after",
                details: "running=\(controller.isRunning) recording=\(controller.isRecording)"
            )

            if shouldStartRecording {
                StockpileCameraCaptureTrace.log("configureAndStartSession.beginRecording")
                try beginRecording(using: controller)
            }
        } catch {
            StockpileCameraCaptureTrace.log(
                "configureAndStartSession.error",
                details: error.localizedDescription
            )
            storageQueue.sync {
                if let activeController = storage.controller,
                   activeController.isRunning {
                    storage.state.phase = .failed
                    if shouldStartRecording {
                        storage.state.recordingLifecycle = .failed
                    }
                    storage.state.sessionLifecycle = .running
                    storage.state.activeDeviceName = activeController.deviceLabel
                    storage.state.activePrompt = error.localizedDescription
                    storage.state.lastErrorDescription = error.localizedDescription
                    storage.guidanceRefreshID = nil
                    storage.state.debugTraceSummary = "recording start error while preview running: \(error.localizedDescription)"
                } else {
                    storage.state = .failed(
                        permission: storage.state.permission,
                        message: error.localizedDescription,
                        activeDeviceName: storage.state.activeDeviceName
                    )
                }
                storage.state.sensorSnapshot = telemetryRuntime.latestSnapshot
            }
        }
    }

    private func telemetryConfiguration(
        for controller: any StockpileCameraSessionControlling
    ) -> StockpileCaptureDeviceTelemetryConfiguration {
        StockpileCaptureDeviceTelemetryConfiguration(
            lidarAssistEnabled: lidarAssistEnabled,
            cameraCalibrationIncluded: controller.videoWidth != nil && controller.videoHeight != nil,
            depthDataIncluded: false,
            videoWidth: controller.videoWidth,
            videoHeight: controller.videoHeight,
            videoFrameRate: controller.videoFrameRate,
            videoStabilizationMode: controller.videoStabilizationModeLabel
        )
    }

    private func beginRecording(using controller: any StockpileCameraSessionControlling) throws {
        StockpileCameraCaptureTrace.log(
            "beginRecording.enter",
            details: "running=\(controller.isRunning) recording=\(controller.isRecording)"
        )
        if controller.isRecording {
            storageQueue.sync {
                storage.state.recordingLifecycle = .recording
                storage.state.debugTraceSummary = "recording already active"
            }
            return
        }

        let outputURL = try makeRecordingOutputURL()
        StockpileCameraCaptureTrace.log(
            "beginRecording.outputReady",
            details: outputURL.path
        )
        let pendingRecording = PendingRecording(
            outputURL: outputURL,
            startedAt: now()
        )
        let startupID = UUID()

        storageQueue.sync {
            storage.pendingRecording = pendingRecording
            storage.pendingRecordingStartupID = startupID
            storage.state.recordingLifecycle = .starting
            storage.state.recordingOutput = nil
            storage.state.debugTraceSummary = "recording request sent: \(outputURL.lastPathComponent)"
        }

        scheduleRecordingStartupTimeout(
            outputURL: outputURL,
            startupID: startupID
        )

        do {
            StockpileCameraCaptureTrace.log(
                "beginRecording.startRecording.call",
                details: "output=\(outputURL.lastPathComponent)"
            )
            try controller.startRecording(
                to: outputURL,
                delegate: self
            )
            StockpileCameraCaptureTrace.log("beginRecording.startRecording.returned")
            if controller.isRecording,
               markRecordingLiveIfPending(
                outputURL: outputURL,
                controller: controller,
                debugTraceSummary: "recording live: recorder active before didStart callback"
               ) {
                StockpileCameraCaptureTrace.log(
                    "beginRecording.recoveredFromMissingDidStart",
                    details: "output=\(outputURL.lastPathComponent)"
                )
                beginGuidanceRefreshLoop()
            }
        } catch {
            StockpileCameraCaptureTrace.log(
                "beginRecording.startRecording.threw",
                details: error.localizedDescription
            )
            storageQueue.sync {
                storage.pendingRecording = nil
                storage.pendingRecordingStartupID = nil
                storage.state.recordingLifecycle = .failed
                storage.state.phase = .failed
                storage.state.activePrompt = error.localizedDescription
                storage.state.lastErrorDescription = error.localizedDescription
                storage.state.debugTraceSummary = "startRecording threw: \(error.localizedDescription)"
                storage.guidanceRefreshID = nil
            }
            throw error
        }
    }

    @discardableResult
    private func markRecordingLiveIfPending(
        outputURL: URL,
        controller: any StockpileCameraSessionControlling,
        debugTraceSummary: String
    ) -> Bool {
        storageQueue.sync {
            guard storage.pendingRecording?.outputURL == outputURL else {
                storage.state.debugTraceSummary = "didStart ignored: pending output mismatch"
                return false
            }
            guard storage.pendingRecordingStartupID != nil else {
                return false
            }

            storage.pendingRecordingStartupID = nil
            storage.state.recordingLifecycle = .recording
            storage.state.activeDeviceName = controller.deviceLabel
            storage.state.sensorSnapshot = telemetryRuntime.latestSnapshot
            storage.state.lastErrorDescription = nil
            storage.state.debugTraceSummary = debugTraceSummary
            return true
        }
    }

    private func scheduleRecordingStartupTimeout(
        outputURL: URL,
        startupID: UUID
    ) {
        guard recordingStartupTimeout > 0 else {
            return
        }

        StockpileCameraCaptureTrace.log(
            "recordingStartupTimeout.scheduled",
            details: "\(recordingStartupTimeout)s output=\(outputURL.lastPathComponent)"
        )
        sessionQueue.asyncAfter(deadline: .now() + recordingStartupTimeout) { [weak self] in
            guard let self else { return }

            let timeoutOutcome = self.storageQueue.sync { () -> RecordingStartupTimeoutOutcome in
                guard self.storage.pendingRecordingStartupID == startupID,
                      self.storage.pendingRecording?.outputURL == outputURL,
                      self.storage.state.recordingLifecycle == .starting else {
                    return .ignored
                }

                let activeController = self.storage.controller
                if activeController?.isRecording == true {
                    self.storage.pendingRecordingStartupID = nil
                    self.storage.state.recordingLifecycle = .recording
                    self.storage.state.sessionLifecycle = Self.lifecycle(
                        for: self.storage.state.permission,
                        controller: activeController
                    )
                    self.storage.state.activeDeviceName = activeController?.deviceLabel
                    self.storage.state.lastErrorDescription = nil
                    self.storage.state.debugTraceSummary = "recording live: recorder active before didStart callback"
                    self.storage.state.sensorSnapshot = self.telemetryRuntime.latestSnapshot
                    return .recorderAlreadyActive
                }

                self.storage.pendingRecording = nil
                self.storage.pendingRecordingStartupID = nil
                self.storage.stopSessionAfterRecordingFinalize = false
                self.storage.guidanceRefreshID = nil
                self.storage.state.phase = .failed
                self.storage.state.recordingLifecycle = .failed
                self.storage.state.sessionLifecycle = Self.lifecycle(
                    for: self.storage.state.permission,
                    controller: self.storage.controller
                )
                self.storage.state.activePrompt = "The rear camera took too long to start recording. Retry recording and keep the phone unlocked."
                self.storage.state.lastErrorDescription = self.storage.state.activePrompt
                self.storage.state.debugTraceSummary = "recording start timeout: didStart callback missing"
                self.storage.state.sensorSnapshot = self.telemetryRuntime.latestSnapshot
                return .timedOut(activeController: activeController)
            }

            switch timeoutOutcome {
            case .ignored:
                StockpileCameraCaptureTrace.log(
                    "recordingStartupTimeout.ignored",
                    details: "recording started or request changed"
                )
                return
            case .recorderAlreadyActive:
                StockpileCameraCaptureTrace.log(
                    "recordingStartupTimeout.recoveredRecorderActive",
                    details: "output=\(outputURL.lastPathComponent)"
                )
                self.beginGuidanceRefreshLoop()
                return
            case let .timedOut(activeController):
                StockpileCameraCaptureTrace.log(
                    "recordingStartupTimeout.fired",
                    details: "output=\(outputURL.lastPathComponent)"
                )
                guard let activeController else {
                    self.telemetryRuntime.stopSampling()
                    return
                }

                if activeController.isRecording {
                    activeController.stopRecording()
                }
            }
        }
    }

    private func makeRecordingOutputURL() throws -> URL {
        try fileManager.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let outputURL = recordingsDirectory.appendingPathComponent(
            "stockpile-capture-\(UUID().uuidString).mov"
        )

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        return outputURL
    }

    private static func initialState(for permission: StockpileCameraPermissionState) -> StockpileCameraCaptureSessionState {
        StockpileCameraCaptureSessionState(
            phase: .idle,
            permission: permission,
            guidance: .watchPreview,
            completedSteps: 0,
            totalSteps: 3,
            activePrompt: permission.operatorHint,
            sessionLifecycle: .permissionRequired,
            recordingLifecycle: .idle
        )
    }

    private static func lifecycle(
        for permission: StockpileCameraPermissionState,
        controller: (any StockpileCameraSessionControlling)?
    ) -> StockpileCameraSessionLifecycle {
        guard permission.isGranted else {
            return .permissionRequired
        }

        guard let controller else {
            return .unconfigured
        }

        return controller.isRunning ? .running : .stopped
    }

    private func applyCheckpoint(
        at index: Int,
        guidance: StockpileCaptureGuidanceSummary,
        phase: StockpileCameraCaptureSessionPhase,
        activePrompt: String,
        storage: inout Storage
    ) {
        storage.state = StockpileCameraCaptureSessionState(
            phase: phase,
            permission: storage.state.permission,
            guidance: guidance,
            sensorSnapshot: storage.state.sensorSnapshot,
            completedSteps: index,
            totalSteps: checkpoints.count,
            activePrompt: activePrompt,
            sessionLifecycle: storage.state.sessionLifecycle,
            recordingLifecycle: storage.state.recordingLifecycle,
            recordingOutput: storage.state.recordingOutput,
            activeDeviceName: storage.state.activeDeviceName,
            observedReferenceMarkers: storage.state.observedReferenceMarkers,
            materialSuggestion: storage.state.materialSuggestion,
            lastErrorDescription: storage.state.lastErrorDescription,
            debugTraceSummary: storage.state.debugTraceSummary
        )
    }

    private func refreshLiveGuidanceIfPossible() {
        storageQueue.sync {
            _ = refreshLiveGuidance(using: storage.controller, storage: &storage)
        }
    }

    @discardableResult
    private func refreshLiveGuidance(
        using controller: (any StockpileCameraSessionControlling)?,
        storage: inout Storage
    ) -> Bool {
        guard storage.state.phase == .capturing || storage.state.phase == .readyToFinish else {
            return false
        }

        if markerlessCaptureEnabled, controller == nil {
            return refreshMarkerlessGuidance(storage: &storage)
        }

        guard let controller,
              let sceneAnalysis = controller.latestSceneAnalysis else {
            return false
        }

        let diagnostics = controller.latestSceneDiagnostics
        if storage.lastSceneAnalysisAt != sceneAnalysis.capturedAt {
            storage.lastSceneAnalysisAt = sceneAnalysis.capturedAt
            let coverageGate = max(1 - sceneAnalysis.structuredArtifactScore * 0.82, 0.12)
            let incrementalCoverage = max(sceneAnalysis.sceneChangeScore - 0.03, 0) * 1.35 * coverageGate
            storage.sceneCoverageAccumulator = min(
                storage.sceneCoverageAccumulator + incrementalCoverage,
                1
            )
        }

        let elapsedRecordingTime: TimeInterval
        if let pendingRecording = storage.pendingRecording {
            elapsedRecordingTime = max(now().timeIntervalSince(pendingRecording.startedAt), 0)
        } else if let recordingOutput = storage.state.recordingOutput {
            elapsedRecordingTime = max(recordingOutput.finishedAt.timeIntervalSince(recordingOutput.startedAt), 0)
        } else {
            elapsedRecordingTime = 0
        }

        let progress = StockpileLiveGuidanceEstimator.estimate(
            totalSteps: checkpoints.count,
            manualCompletedSteps: storage.currentStepIndex,
            elapsedRecordingTime: elapsedRecordingTime,
            sceneCoverageAccumulator: storage.sceneCoverageAccumulator,
            sceneAnalysis: sceneAnalysis,
            telemetry: storage.state.sensorSnapshot ?? telemetryRuntime.latestSnapshot,
            markerlessCaptureEnabled: markerlessCaptureEnabled
        )
        storage.currentStepIndex = max(storage.currentStepIndex, progress.completedSteps)
        storage.state.guidance = progress.guidance
        storage.state.phase = progress.phase
        storage.state.completedSteps = progress.completedSteps
        storage.state.totalSteps = checkpoints.count
        storage.state.activePrompt = Self.activePrompt(
            guidance: progress.guidance,
            diagnostics: diagnostics
        )
        storage.state.activeDeviceName = controller.deviceLabel
        storage.state.observedReferenceMarkers = Self.observedReferenceMarkers(from: diagnostics)
        storage.state.materialSuggestion = Self.materialSuggestion(from: diagnostics)
        storage.state.sensorSnapshot = telemetryRuntime.latestSnapshot
        storage.state.lastErrorDescription = nil
        return true
    }

    @discardableResult
    private func refreshMarkerlessGuidance(storage: inout Storage) -> Bool {
        let elapsedRecordingTime: TimeInterval
        if let pendingRecording = storage.pendingRecording {
            elapsedRecordingTime = max(now().timeIntervalSince(pendingRecording.startedAt), 0)
        } else {
            elapsedRecordingTime = 0
        }

        storage.sceneCoverageAccumulator = min(max(storage.sceneCoverageAccumulator, 0), 1)
        let telemetry = telemetryRuntime.latestSnapshot ?? storage.state.sensorSnapshot
        let progress = StockpileLiveGuidanceEstimator.estimate(
            totalSteps: checkpoints.count,
            manualCompletedSteps: storage.currentStepIndex,
            elapsedRecordingTime: elapsedRecordingTime,
            sceneCoverageAccumulator: storage.sceneCoverageAccumulator,
            sceneAnalysis: StockpileCaptureSceneAnalysis(
                capturedAt: now(),
                referenceCandidateCount: 0,
                referenceCandidateConfidence: 0,
                brightnessScore: 0.72,
                sharpnessScore: 0.72,
                sceneChangeScore: 0.12,
                structuredArtifactScore: 0.04,
                sceneFitConfidence: 0.82,
                sceneRejectionConfidence: 0.04,
                pileSegmentationConfidence: 0.84,
                toeSegmentationConfidence: min(max(elapsedRecordingTime / 50.0, 0.45), 0.88),
                depthConfidence: 0.88,
                quickVolumeConfidence: 0.8,
                trackingConfidence: 0.9
            ),
            telemetry: telemetry,
            markerlessCaptureEnabled: true
        )
        storage.currentStepIndex = max(storage.currentStepIndex, progress.completedSteps)
        storage.state.guidance = progress.guidance
        storage.state.phase = progress.phase
        storage.state.completedSteps = progress.completedSteps
        storage.state.totalSteps = checkpoints.count
        storage.state.activePrompt = progress.guidance.primaryOperatorAction
        storage.state.activeDeviceName = "iPhone LiDAR"
        storage.state.sensorSnapshot = telemetry
        storage.state.lastErrorDescription = nil
        return true
    }

    private static func activePrompt(
        guidance: StockpileCaptureGuidanceSummary,
        diagnostics: StockpileCaptureSceneDiagnostics?
    ) -> String {
        diagnostics?.primaryOperatorAction ?? guidance.primaryOperatorAction
    }

    private static func observedReferenceMarkers(
        from diagnostics: StockpileCaptureSceneDiagnostics?
    ) -> [StockpileCaptureObservedReferenceMarker] {
        guard let diagnostics else {
            return []
        }

        let visibleCount = min(max(diagnostics.referenceObservations.count, 0), 3)
        return diagnostics.referenceObservations.compactMap { observation in
            let rawMarkerID = observation.markerID ?? observation.id
            let normalizedMarkerID = rawMarkerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedMarkerID.isEmpty == false else {
                return nil
            }

            return StockpileCaptureObservedReferenceMarker(
                markerID: normalizedMarkerID,
                visibleCount: visibleCount,
                confidence: observation.confidence,
                source: referenceMarkerSource(from: observation.source)
            )
        }
    }

    private static func materialSuggestion(
        from diagnostics: StockpileCaptureSceneDiagnostics?
    ) -> StockpileCaptureMaterialSuggestion? {
        guard let suggestion = diagnostics?.materialFamilySuggestion else {
            return nil
        }

        return StockpileCaptureMaterialSuggestion(
            materialName: suggestion.label,
            materialCode: suggestion.familyCode,
            confidence: suggestion.confidence
        )
    }

    private static func referenceMarkerSource(
        from source: StockpileCaptureReferenceObservationSource
    ) -> StockpileCaptureObservedReferenceMarker.DetectionSource {
        switch source {
        case .ocr:
            return .opticalLabel
        case .barcode:
            return .barcode
        case .tagLike:
            return .visualCandidate
        }
    }

    private func beginGuidanceRefreshLoop() {
        let refreshID = UUID()
        let shouldStart = storageQueue.sync {
            guard storage.guidanceRefreshID == nil else {
                return false
            }
            storage.guidanceRefreshID = refreshID
            return true
        }
        guard shouldStart else {
            return
        }
        sessionQueue.async { [weak self] in
            self?.refreshLiveGuidanceIfPossible()
            self?.scheduleGuidanceRefresh(with: refreshID)
        }
    }

    private func scheduleGuidanceRefresh(with refreshID: UUID) {
        sessionQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }

            let shouldContinue = self.storageQueue.sync {
                self.storage.guidanceRefreshID == refreshID
            }
            guard shouldContinue else {
                return
            }

            self.refreshLiveGuidanceIfPossible()
            self.scheduleGuidanceRefresh(with: refreshID)
        }
    }
}

extension StockpileCameraCaptureSessionLive: StockpileCameraSessionRecordingDelegate {
    func cameraSessionController(
        _ controller: any StockpileCameraSessionControlling,
        didStartRecordingTo outputURL: URL
    ) {
        StockpileCameraCaptureTrace.log(
            "recordingDelegate.didStart",
            details: "output=\(outputURL.lastPathComponent) running=\(controller.isRunning) recording=\(controller.isRecording)"
        )
        if markRecordingLiveIfPending(
            outputURL: outputURL,
            controller: controller,
            debugTraceSummary: "recording live: \(outputURL.lastPathComponent)"
        ) {
            beginGuidanceRefreshLoop()
        }
    }

    func cameraSessionController(
        _ controller: any StockpileCameraSessionControlling,
        didFinishRecordingTo outputURL: URL,
        error: Error?
    ) {
        StockpileCameraCaptureTrace.log(
            "recordingDelegate.didFinish",
            details: "output=\(outputURL.lastPathComponent) error=\(error?.localizedDescription ?? "nil")"
        )
        let shouldStopSession = storageQueue.sync { () -> Bool in
            defer {
                storage.pendingRecording = nil
                storage.pendingRecordingStartupID = nil
            }

            guard let pendingRecording = storage.pendingRecording,
                  pendingRecording.outputURL == outputURL else {
                storage.state.debugTraceSummary = "didFinish ignored: pending output mismatch"
                return false
            }

            if let error {
                storage.state.recordingLifecycle = .failed
                storage.state.phase = .failed
                storage.state.activePrompt = error.localizedDescription
                storage.state.lastErrorDescription = error.localizedDescription
                storage.state.debugTraceSummary = "recording finish error: \(error.localizedDescription)"
                storage.guidanceRefreshID = nil
            } else {
                storage.state.recordingLifecycle = .finished
                storage.state.recordingOutput = StockpileCameraRecordingOutput(
                    fileURL: outputURL,
                    fileSizeBytes: fileSize(for: outputURL),
                    startedAt: pendingRecording.startedAt,
                    finishedAt: now()
                )
                storage.state.debugTraceSummary = "recording finished: \(outputURL.lastPathComponent)"
                switch storage.state.phase {
                case .completed:
                    storage.state.activePrompt = "Capture complete. The run is ready for upload."
                case .blocked:
                    storage.state.activePrompt = storage.state.permission.operatorHint
                default:
                    storage.state.activePrompt = "Recording saved locally."
                }
                storage.state.lastErrorDescription = nil
                storage.state.sensorSnapshot = telemetryRuntime.latestSnapshot
                storage.guidanceRefreshID = nil
            }

            let shouldStop = storage.stopSessionAfterRecordingFinalize
            storage.stopSessionAfterRecordingFinalize = false
            return shouldStop
        }

        guard shouldStopSession else {
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let controller = self.storageQueue.sync { self.storage.controller }

            guard let controller else {
                return
            }

            if controller.isRunning {
                controller.stopRunning()
            }

            self.storageQueue.sync {
                self.storage.state.sessionLifecycle = Self.lifecycle(
                    for: self.storage.state.permission,
                    controller: controller
                )
            }
        }
    }

    private func fileSize(for fileURL: URL) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return nil
        }

        return fileSize.int64Value
    }
}

private struct StockpileAVFoundationCameraPlatform: StockpileCameraPlatform {
    func currentPermissionState() -> StockpileCameraPermissionState {
        permissionState(for: AVCaptureDevice.authorizationStatus(for: .video))
    }

    func requestCameraAccess() async -> StockpileCameraPermissionState {
        let current = currentPermissionState()

        guard current.canRequestAccess else {
            return current
        }

        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }

        if granted {
            return StockpileCameraPermissionState(status: .authorized, canRequestAccess: false)
        }

        return currentPermissionState()
    }

    func makeSessionController(
        preferredPosition: StockpileCameraLensPosition,
        lidarAssistEnabled: Bool
    ) throws -> any StockpileCameraSessionControlling {
        try StockpileAVFoundationSessionController(
            preferredPosition: preferredPosition,
            lidarAssistEnabled: lidarAssistEnabled
        )
    }

    private func permissionState(for status: AVAuthorizationStatus) -> StockpileCameraPermissionState {
        switch status {
        case .notDetermined:
            return StockpileCameraPermissionState(status: .notDetermined, canRequestAccess: true)
        case .restricted:
            return StockpileCameraPermissionState(status: .restricted, canRequestAccess: false)
        case .denied:
            return StockpileCameraPermissionState(status: .denied, canRequestAccess: false)
        case .authorized:
            return StockpileCameraPermissionState(status: .authorized, canRequestAccess: false)
        @unknown default:
            return StockpileCameraPermissionState(status: .restricted, canRequestAccess: false)
        }
    }
}

private final class StockpileAVFoundationSessionController: NSObject, StockpileCameraSessionControlling {
    let captureSession: AVCaptureSession
    let deviceLabel: String
    private let movieOutput: AVCaptureMovieFileOutput
    private let videoDataOutput: AVCaptureVideoDataOutput
    private let videoDevice: AVCaptureDevice
    private let sceneAnalyzer = StockpileCameraFrameSceneAnalyzer()
    private let analysisQueue = DispatchQueue(label: "com.clustox.stockpile.camera.analysis")
    private let analysisLock = NSLock()
    private var recordingProxy: StockpileAVFoundationRecordingProxy?
    private var sceneAnalysis: StockpileCaptureSceneAnalysis?
    private var sceneDiagnostics: StockpileCaptureSceneDiagnostics?
    private var notificationObservers: [NSObjectProtocol] = []

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isRunning: Bool {
        captureSession.isRunning
    }

    var isRecording: Bool {
        movieOutput.isRecording
    }

    var videoWidth: Int? {
        let dimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
        return Int(dimensions.width)
    }

    var videoHeight: Int? {
        let dimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
        return Int(dimensions.height)
    }

    var videoFrameRate: Double? {
        videoDevice.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate
    }

    var videoStabilizationModeLabel: String? {
        #if os(iOS)
        guard let connection = movieOutput.connection(with: .video),
              connection.isVideoStabilizationSupported else {
            return nil
        }
        return String(describing: connection.preferredVideoStabilizationMode)
        #else
        return nil
        #endif
    }

    var supportsDepthDataDelivery: Bool {
        #if os(iOS)
        videoDevice.activeFormat.supportedDepthDataFormats.isEmpty == false
        #else
        false
        #endif
    }

    var latestSceneAnalysis: StockpileCaptureSceneAnalysis? {
        analysisLock.withLock {
            sceneAnalysis
        }
    }

    var latestSceneDiagnostics: StockpileCaptureSceneDiagnostics? {
        analysisLock.withLock {
            sceneDiagnostics
        }
    }

    init(
        preferredPosition: StockpileCameraLensPosition,
        lidarAssistEnabled: Bool
    ) throws {
        let captureSession = AVCaptureSession()
        let videoDevice = try Self.makeVideoDevice(
            preferredPosition: preferredPosition,
            lidarAssistEnabled: lidarAssistEnabled
        )
        #if os(iOS)
        let supportsDepth = !videoDevice.activeFormat.supportedDepthDataFormats.isEmpty
        #else
        let supportsDepth = false
        #endif
        StockpileCameraCaptureTrace.log(
            "avfoundation.controller.init.device",
            details: "device=\(videoDevice.localizedName) uniqueID=\(videoDevice.uniqueID) supportsDepth=\(supportsDepth)"
        )
        let input = try AVCaptureDeviceInput(device: videoDevice)
        let movieOutput = AVCaptureMovieFileOutput()
        let videoDataOutput = AVCaptureVideoDataOutput()

        self.captureSession = captureSession
        self.deviceLabel = videoDevice.localizedName
        self.movieOutput = movieOutput
        self.videoDataOutput = videoDataOutput
        self.videoDevice = videoDevice
        super.init()
        installSessionDiagnostics()

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        defer {
            captureSession.commitConfiguration()
        }

        guard captureSession.canAddInput(input) else {
            StockpileCameraCaptureTrace.log("avfoundation.controller.init.cannotAddInput")
            throw StockpileAVFoundationCameraError.unableToAddInput
        }

        captureSession.addInput(input)
        StockpileCameraCaptureTrace.log("avfoundation.controller.init.inputAdded")

        guard captureSession.canAddOutput(movieOutput) else {
            StockpileCameraCaptureTrace.log("avfoundation.controller.init.cannotAddMovieOutput")
            throw StockpileAVFoundationCameraError.unableToAddMovieOutput
        }

        captureSession.addOutput(movieOutput)
        StockpileCameraCaptureTrace.log(
            "avfoundation.controller.init.movieOutputAdded",
            details: "hasVideoConnection=\(movieOutput.connection(with: .video) != nil)"
        )
        #if os(iOS)
        if let connection = movieOutput.connection(with: .video),
           connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
        #endif

        if captureSession.canAddOutput(videoDataOutput) {
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            #if os(iOS)
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            #endif
            captureSession.addOutput(videoDataOutput)
            videoDataOutput.setSampleBufferDelegate(self, queue: analysisQueue)
            StockpileCameraCaptureTrace.log("avfoundation.controller.init.videoDataOutputAdded")
        } else {
            StockpileCameraCaptureTrace.log("avfoundation.controller.init.videoDataOutputSkipped")
        }
    }

    func startRunning() {
        guard !captureSession.isRunning else {
            StockpileCameraCaptureTrace.log("avfoundation.startRunning.skippedAlreadyRunning")
            return
        }

        StockpileCameraCaptureTrace.log("avfoundation.startRunning.begin")
        captureSession.startRunning()
        StockpileCameraCaptureTrace.log(
            "avfoundation.startRunning.end",
            details: "isRunning=\(captureSession.isRunning)"
        )
    }

    func stopRunning() {
        guard captureSession.isRunning else {
            StockpileCameraCaptureTrace.log("avfoundation.stopRunning.skippedNotRunning")
            return
        }

        StockpileCameraCaptureTrace.log("avfoundation.stopRunning.begin")
        captureSession.stopRunning()
        StockpileCameraCaptureTrace.log("avfoundation.stopRunning.end")
        analysisLock.withLock {
            sceneAnalysis = nil
            sceneDiagnostics = nil
        }
    }

    func startRecording(
        to outputURL: URL,
        delegate: any StockpileCameraSessionRecordingDelegate
    ) throws {
        guard !movieOutput.isRecording else {
            StockpileCameraCaptureTrace.log("avfoundation.startRecording.alreadyInProgress")
            throw StockpileAVFoundationCameraError.recordingAlreadyInProgress
        }

        let proxy = StockpileAVFoundationRecordingProxy(
            controller: self,
            delegate: delegate
        ) { [weak self] in
            self?.recordingProxy = nil
        }

        recordingProxy = proxy
        analysisLock.withLock {
            sceneAnalysis = nil
            sceneDiagnostics = nil
        }
        StockpileCameraCaptureTrace.log(
            "avfoundation.startRecording.callMovieOutput",
            details: "sessionRunning=\(captureSession.isRunning) output=\(outputURL.lastPathComponent) hasVideoConnection=\(movieOutput.connection(with: .video) != nil)"
        )
        movieOutput.startRecording(
            to: outputURL,
            recordingDelegate: proxy
        )
        StockpileCameraCaptureTrace.log(
            "avfoundation.startRecording.afterMovieOutput",
            details: "isRecording=\(movieOutput.isRecording)"
        )
    }

    func stopRecording() {
        guard movieOutput.isRecording else {
            StockpileCameraCaptureTrace.log("avfoundation.stopRecording.skippedNotRecording")
            return
        }

        StockpileCameraCaptureTrace.log("avfoundation.stopRecording.call")
        movieOutput.stopRecording()
    }

    func waitUntilRunning(timeout: TimeInterval) -> Bool {
        guard timeout > 0 else {
            return captureSession.isRunning
        }

        let deadline = Date().addingTimeInterval(timeout)
        while captureSession.isRunning == false && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        StockpileCameraCaptureTrace.log(
            "avfoundation.waitUntilRunning.end",
            details: "isRunning=\(captureSession.isRunning)"
        )
        return captureSession.isRunning
    }

    private func installSessionDiagnostics() {
        let center = NotificationCenter.default

        notificationObservers.append(
            center.addObserver(
                forName: .AVCaptureSessionDidStartRunning,
                object: captureSession,
                queue: nil
            ) { _ in
                StockpileCameraCaptureTrace.log("avfoundation.notification.didStartRunning")
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: .AVCaptureSessionDidStopRunning,
                object: captureSession,
                queue: nil
            ) { _ in
                StockpileCameraCaptureTrace.log("avfoundation.notification.didStopRunning")
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: .AVCaptureSessionRuntimeError,
                object: captureSession,
                queue: nil
            ) { notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                StockpileCameraCaptureTrace.log(
                    "avfoundation.notification.runtimeError",
                    details: error?.localizedDescription ?? "unknown"
                )
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: .AVCaptureSessionWasInterrupted,
                object: captureSession,
                queue: nil
            ) { notification in
                #if os(iOS)
                let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey]
                #else
                let reason: Any? = nil
                #endif
                StockpileCameraCaptureTrace.log(
                    "avfoundation.notification.wasInterrupted",
                    details: String(describing: reason)
                )
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: .AVCaptureSessionInterruptionEnded,
                object: captureSession,
                queue: nil
            ) { _ in
                StockpileCameraCaptureTrace.log("avfoundation.notification.interruptionEnded")
            }
        )
    }

    private static func makeVideoDevice(
        preferredPosition: StockpileCameraLensPosition,
        lidarAssistEnabled: Bool
    ) throws -> AVCaptureDevice {
        if let position = preferredPosition.avCapturePosition,
           let preferredDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            if preferredPosition == .back, lidarAssistEnabled {
                StockpileCameraCaptureTrace.log(
                    "avfoundation.makeVideoDevice.usingWideAngleForRecording",
                    details: "LiDAR/depth stays on the separate native pose/depth pipeline."
                )
            }
            return preferredDevice
        }

        #if os(iOS)
        if preferredPosition == .back {
            if let dualWideDevice = AVCaptureDevice.default(
                .builtInDualWideCamera,
                for: .video,
                position: .back
            ) {
                return dualWideDevice
            }
        }
        #endif

        if let fallbackDevice = AVCaptureDevice.default(for: .video) {
            return fallbackDevice
        }

        throw StockpileAVFoundationCameraError.noVideoDevice(preferredPosition)
    }
}

extension StockpileAVFoundationSessionController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard output === videoDataOutput,
              let analysis = sceneAnalyzer.analyze(
                sampleBuffer: sampleBuffer,
                orientation: connection.visionImageOrientation
              ) else {
            return
        }

        analysisLock.withLock {
            sceneAnalysis = analysis.sceneAnalysis
            sceneDiagnostics = analysis.sceneDiagnostics
        }
    }
}

private final class StockpileAVFoundationRecordingProxy: NSObject, AVCaptureFileOutputRecordingDelegate {
    private weak var controller: StockpileAVFoundationSessionController?
    private weak var delegate: (any StockpileCameraSessionRecordingDelegate)?
    private let didFinish: () -> Void

    init(
        controller: StockpileAVFoundationSessionController,
        delegate: any StockpileCameraSessionRecordingDelegate,
        didFinish: @escaping () -> Void
    ) {
        self.controller = controller
        self.delegate = delegate
        self.didFinish = didFinish
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        StockpileCameraCaptureTrace.log(
            "avfoundation.proxy.didStart",
            details: "output=\(fileURL.lastPathComponent) connections=\(connections.count)"
        )
        guard let controller else {
            StockpileCameraCaptureTrace.log("avfoundation.proxy.didStart.missingController")
            return
        }

        delegate?.cameraSessionController(
            controller,
            didStartRecordingTo: fileURL
        )
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        StockpileCameraCaptureTrace.log(
            "avfoundation.proxy.didFinish",
            details: "output=\(outputFileURL.lastPathComponent) connections=\(connections.count) error=\(error?.localizedDescription ?? "nil")"
        )
        defer { didFinish() }

        guard let controller else {
            StockpileCameraCaptureTrace.log("avfoundation.proxy.didFinish.missingController")
            return
        }

        delegate?.cameraSessionController(
            controller,
            didFinishRecordingTo: outputFileURL,
            error: error
        )
    }
}

private final class StockpileCameraFrameSceneAnalyzer {
    struct FrameAnalysis {
        let sceneAnalysis: StockpileCaptureSceneAnalysis
        let sceneDiagnostics: StockpileCaptureSceneDiagnostics
    }

    private struct ForegroundSegmentationSummary {
        let pileConfidence: Double
        let toeConfidence: Double
    }

    private struct ForegroundMaskStats {
        let foregroundRatio: Double
        let lowerFrameRatio: Double
        let toeBandRatio: Double
        let horizontalSpread: Double
        let centeredness: Double
        let bottomReach: Double
    }

    private struct RectangleCandidateAssessment {
        let boundingBox: CGRect
        let detectionConfidence: Double
        let tagLikeScore: Double
        let structuredArtifactScore: Double
        let displayLikeScore: Double
        let isTagLike: Bool
        let isStructuredArtifact: Bool
    }

    private struct RectangleSampleStats {
        let average: Double
        let spread: Double
        let sampleCount: Int

        static let empty = RectangleSampleStats(average: 0, spread: 0, sampleCount: 0)
    }

    private struct ReferenceDetection {
        let markerID: String?
        let source: StockpileCaptureReferenceObservationSource
        let confidence: Double
        let boundingBox: CGRect
    }

    private struct ReferenceTrack {
        let id: String
        var markerID: String?
        var source: StockpileCaptureReferenceObservationSource
        var confidence: Double
        var lastBounds: CGRect
        var framesObserved: Int
        var decodedFrames: Int
        var lastSeenAt: Date
    }

    private struct SceneEvidence {
        let materialFamilySuggestion: StockpileCaptureMaterialFamilySuggestion?
        let screenClassificationScore: Double
        let equipmentClassificationScore: Double
        let textLikelihood: Double
        let supportingLabels: [String]
    }

    private struct SceneTextObservation {
        let blockCount: Int
        let characterCount: Int

        static let empty = SceneTextObservation(blockCount: 0, characterCount: 0)
    }

    private var lastProcessedAt = Date.distantPast
    private var lastSceneEvidenceAt = Date.distantPast
    private var previousLumaGrid: [UInt8] = []
    private var cachedSceneEvidence: SceneEvidence?
    private var referenceTracks: [ReferenceTrack] = []
    private var nextTrackSequence = 1
    private let minimumProcessInterval: TimeInterval = 0.55
    private let sceneEvidenceInterval: TimeInterval = 1.65
    private let referenceTrackExpiry: TimeInterval = 2.7

    func analyze(
        sampleBuffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation
    ) -> FrameAnalysis? {
        let now = Date()
        guard now.timeIntervalSince(lastProcessedAt) >= minimumProcessInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        lastProcessedAt = now

        let coarseLumaGrid = Self.makeLumaGrid(from: pixelBuffer, columns: 8, rows: 6)
        let detailLumaGrid = Self.makeLumaGrid(from: pixelBuffer, columns: 24, rows: 18)
        let brightnessScore = Self.averageNormalizedLuma(from: coarseLumaGrid)
        let sharpnessScore = Self.localContrastScore(from: coarseLumaGrid, columns: 8)
        let sceneChangeScore = Self.sceneChangeScore(
            current: coarseLumaGrid,
            previous: previousLumaGrid
        )
        previousLumaGrid = coarseLumaGrid

        let rectangleCandidates = Self.detectRectangleCandidates(
            in: pixelBuffer,
            lumaGrid: detailLumaGrid,
            columns: 24,
            rows: 18,
            orientation: orientation
        )
        let sceneEvidence = sceneEvidence(
            in: pixelBuffer,
            orientation: orientation,
            capturedAt: now
        )
        let acceptedRectangleCandidates = rectangleCandidates.filter(\.isTagLike)
        let structuredRectangleCandidates = rectangleCandidates.filter(\.isStructuredArtifact)
        let referenceDetections = Self.referenceDetections(
            from: acceptedRectangleCandidates,
            in: pixelBuffer,
            orientation: orientation
        )
        let stabilizedObservations = updateReferenceTracks(
            with: referenceDetections,
            capturedAt: now
        )
        let decodedObservationCount = stabilizedObservations.reduce(into: 0) { partialResult, observation in
            if observation.markerID != nil {
                partialResult += 1
            }
        }
        let referenceCandidateCount = min(stabilizedObservations.count, 3)
        let referenceCandidateConfidence = stabilizedObservations.isEmpty
            ? (acceptedRectangleCandidates.isEmpty
                ? 0
                : acceptedRectangleCandidates.reduce(0) { partialResult, candidate in
                    partialResult + candidate.tagLikeScore
                } / Double(acceptedRectangleCandidates.count) * 0.82)
            : min(
                stabilizedObservations.reduce(0) { partialResult, observation in
                    let decodeBoost = observation.markerID == nil ? 0 : 0.14
                    return partialResult + observation.confidence + decodeBoost
                } / Double(stabilizedObservations.count),
                1
            )
        let structuredRectangleScore = structuredRectangleCandidates.isEmpty
            ? 0
            : min(
                structuredRectangleCandidates.reduce(0) { partialResult, candidate in
                    partialResult + candidate.structuredArtifactScore
                } / Double(structuredRectangleCandidates.count)
                    * 0.72
                    + min(Double(structuredRectangleCandidates.count) / 4.0, 1) * 0.28,
                1
            )
        let displayLikeScore = structuredRectangleCandidates.isEmpty
            ? 0
            : min(
                structuredRectangleCandidates.reduce(0) { partialResult, candidate in
                    partialResult + candidate.displayLikeScore
                } / Double(structuredRectangleCandidates.count),
                1
            )
        let structuredDensity = Self.clamp(Double(structuredRectangleCandidates.count) / 5.0)
        let screenLikelihood = Self.clamp(
            sceneEvidence.screenClassificationScore * 0.44
                + displayLikeScore * 0.30
                + sceneEvidence.textLikelihood * 0.26
        )
        let equipmentLikelihood = Self.clamp(
            sceneEvidence.equipmentClassificationScore * 0.64
                + structuredDensity * 0.24
                + max(0, 1 - displayLikeScore) * 0.12
        )
        let artifactPenalty = min(Double(decodedObservationCount) * 0.12, 0.24)
        let artifactSignal = structuredRectangleScore * 0.40
            + max(screenLikelihood, equipmentLikelihood) * 0.46
            + sceneEvidence.textLikelihood * 0.14
        let structuredArtifactScore = Self.clamp(
            artifactSignal - artifactPenalty
        )
        let sceneDiagnostics = StockpileCaptureSceneDiagnostics(
            capturedAt: now,
            referenceObservations: Array(
                stabilizedObservations
                    .sorted(by: Self.referenceObservationSort)
                    .prefix(4)
            ),
            materialFamilySuggestion: max(screenLikelihood, equipmentLikelihood) >= 0.68
                ? nil
                : sceneEvidence.materialFamilySuggestion,
            screenLikelihood: screenLikelihood,
            equipmentLikelihood: equipmentLikelihood,
            textLikelihood: sceneEvidence.textLikelihood,
            rejectionReasons: Self.sceneRejectionReasons(
                screenLikelihood: screenLikelihood,
                equipmentLikelihood: equipmentLikelihood,
                textLikelihood: sceneEvidence.textLikelihood
            ),
            supportingLabels: sceneEvidence.supportingLabels
        )
        let segmentationSummary = Self.foregroundSegmentationSummary(
            in: pixelBuffer,
            orientation: orientation,
            screenLikelihood: screenLikelihood,
            equipmentLikelihood: equipmentLikelihood,
            textLikelihood: sceneEvidence.textLikelihood,
            referenceObservationCount: stabilizedObservations.count
        )
        let sceneAnalysis = StockpileCaptureSceneAnalysis(
            capturedAt: now,
            referenceCandidateCount: referenceCandidateCount,
            referenceCandidateConfidence: referenceCandidateConfidence,
            brightnessScore: brightnessScore,
            sharpnessScore: sharpnessScore,
            sceneChangeScore: sceneChangeScore,
            structuredArtifactScore: structuredArtifactScore,
            pileSegmentationConfidence: segmentationSummary?.pileConfidence,
            toeSegmentationConfidence: segmentationSummary?.toeConfidence
        )

        return FrameAnalysis(
            sceneAnalysis: sceneAnalysis,
            sceneDiagnostics: sceneDiagnostics
        )
    }

    private func sceneEvidence(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        capturedAt: Date
    ) -> SceneEvidence {
        if let cachedSceneEvidence,
           capturedAt.timeIntervalSince(lastSceneEvidenceAt) < sceneEvidenceInterval {
            return cachedSceneEvidence
        }

        let sceneText = Self.detectSceneText(in: pixelBuffer, orientation: orientation)
        let classifications = Self.classifyScene(in: pixelBuffer, orientation: orientation)
        let textLikelihood = Self.clamp(
            Double(sceneText.blockCount) / 7.0 * 0.48
                + Double(sceneText.characterCount) / 54.0 * 0.52
        )
        let sceneEvidence = SceneEvidence(
            materialFamilySuggestion: Self.materialFamilySuggestion(from: classifications),
            screenClassificationScore: Self.keywordScore(
                from: classifications,
                keywords: [
                    ("screen", 1.0),
                    ("display", 1.0),
                    ("monitor", 1.0),
                    ("television", 0.96),
                    ("laptop", 0.92),
                    ("computer", 0.82),
                    ("tablet", 0.86),
                    ("cellular telephone", 0.88),
                    ("smartphone", 0.88),
                    ("web site", 0.72),
                    ("menu", 0.52)
                ]
            ),
            equipmentClassificationScore: Self.keywordScore(
                from: classifications,
                keywords: [
                    ("excavator", 1.0),
                    ("bulldozer", 1.0),
                    ("loader", 0.96),
                    ("dump truck", 1.0),
                    ("truck", 0.94),
                    ("tractor", 0.88),
                    ("forklift", 0.94),
                    ("crane", 0.90),
                    ("construction", 0.76),
                    ("vehicle", 0.62),
                    ("machine", 0.54)
                ]
            ),
            textLikelihood: textLikelihood,
            supportingLabels: classifications.prefix(4).map(\.identifier)
        )
        cachedSceneEvidence = sceneEvidence
        lastSceneEvidenceAt = capturedAt
        return sceneEvidence
    }

    private func updateReferenceTracks(
        with detections: [ReferenceDetection],
        capturedAt: Date
    ) -> [StockpileCaptureReferenceObservation] {
        referenceTracks.removeAll { capturedAt.timeIntervalSince($0.lastSeenAt) > referenceTrackExpiry }

        var matchedTrackIDs: Set<String> = []
        for detection in Self.deduplicateReferenceDetections(detections) {
            if let index = bestTrackIndex(
                for: detection,
                capturedAt: capturedAt,
                matchedTrackIDs: matchedTrackIDs
            ) {
                referenceTracks[index].markerID = detection.markerID ?? referenceTracks[index].markerID
                referenceTracks[index].source = detection.markerID == nil
                    ? referenceTracks[index].source
                    : detection.source
                referenceTracks[index].confidence = Self.clamp(
                    referenceTracks[index].confidence * 0.42 + detection.confidence * 0.58
                )
                referenceTracks[index].lastBounds = Self.blendedRect(
                    referenceTracks[index].lastBounds,
                    detection.boundingBox
                )
                referenceTracks[index].framesObserved += 1
                if detection.markerID != nil {
                    referenceTracks[index].decodedFrames += 1
                }
                referenceTracks[index].lastSeenAt = capturedAt
                matchedTrackIDs.insert(referenceTracks[index].id)
                continue
            }

            let newTrack = ReferenceTrack(
                id: "tag-like-\(nextTrackSequence)",
                markerID: detection.markerID,
                source: detection.source,
                confidence: detection.confidence,
                lastBounds: detection.boundingBox,
                framesObserved: 1,
                decodedFrames: detection.markerID == nil ? 0 : 1,
                lastSeenAt: capturedAt
            )
            nextTrackSequence += 1
            referenceTracks.append(newTrack)
            matchedTrackIDs.insert(newTrack.id)
        }

        return referenceTracks
            .filter { capturedAt.timeIntervalSince($0.lastSeenAt) <= 1.35 }
            .map { track in
                let stabilityScore = Self.clamp(
                    min(Double(track.framesObserved) / 3.0, 1) * 0.56
                        + min(Double(track.decodedFrames) / 2.0, 1) * 0.44
                )
                let confidence = Self.clamp(
                    track.confidence * 0.68
                        + stabilityScore * 0.18
                        + (track.markerID == nil ? 0 : 0.14)
                )
                return StockpileCaptureReferenceObservation(
                    id: track.id,
                    markerID: track.markerID,
                    source: track.source,
                    confidence: confidence,
                    stabilityScore: stabilityScore,
                    framesObserved: track.framesObserved,
                    region: StockpileCaptureNormalizedRegion(track.lastBounds)
                )
            }
    }

    private func bestTrackIndex(
        for detection: ReferenceDetection,
        capturedAt: Date,
        matchedTrackIDs: Set<String>
    ) -> Int? {
        if let markerID = detection.markerID,
           let exactMatchIndex = referenceTracks.firstIndex(where: { track in
               matchedTrackIDs.contains(track.id) == false
                   && capturedAt.timeIntervalSince(track.lastSeenAt) <= referenceTrackExpiry
                   && track.markerID == markerID
           }) {
            return exactMatchIndex
        }

        var bestIndex: Int?
        var bestScore = 0.0

        for (index, track) in referenceTracks.enumerated() {
            guard matchedTrackIDs.contains(track.id) == false,
                  capturedAt.timeIntervalSince(track.lastSeenAt) <= referenceTrackExpiry else {
                continue
            }

            let iou = Self.intersectionOverUnion(track.lastBounds, detection.boundingBox)
            let centerDistance = Self.centerDistance(track.lastBounds, detection.boundingBox)
            let proximityScore = max(1 - centerDistance / 0.42, 0)
            let markerHint = detection.markerID != nil && track.markerID == nil ? 0.18 : 0
            let associationScore = iou * 0.72 + proximityScore * 0.28 + markerHint
            if associationScore > bestScore {
                bestScore = associationScore
                bestIndex = index
            }
        }

        let threshold = detection.markerID == nil ? 0.34 : 0.26
        guard bestScore >= threshold else {
            return nil
        }
        return bestIndex
    }

    private static func makeLumaGrid(
        from pixelBuffer: CVPixelBuffer,
        columns: Int,
        rows: Int
    ) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planeIndex = CVPixelBufferGetPlaneCount(pixelBuffer) > 0 ? 0 : -1
        let width = planeIndex >= 0
            ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetWidth(pixelBuffer)
        let height = planeIndex >= 0
            ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = planeIndex >= 0
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = (planeIndex >= 0
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBaseAddress(pixelBuffer)) else {
            return []
        }

        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        var grid: [UInt8] = []
        grid.reserveCapacity(columns * rows)

        for row in 0..<rows {
            let y = min((row * height) / rows, max(height - 1, 0))
            let rowPointer = pointer.advanced(by: y * bytesPerRow)

            for column in 0..<columns {
                let x = min((column * width) / columns, max(width - 1, 0))
                grid.append(rowPointer[x])
            }
        }

        return grid
    }

    private static func averageNormalizedLuma(from grid: [UInt8]) -> Double {
        guard grid.isEmpty == false else {
            return 0
        }

        let total = grid.reduce(0.0) { partialResult, value in
            partialResult + Double(value)
        }
        return min(max(total / Double(grid.count) / 255.0, 0), 1)
    }

    private static func localContrastScore(from grid: [UInt8], columns: Int) -> Double {
        guard grid.isEmpty == false, columns > 1 else {
            return 0
        }

        let rows = grid.count / columns
        guard rows > 1 else {
            return 0
        }

        var totalDifference = 0.0
        var comparisons = 0.0

        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let current = Double(grid[index])

                if column + 1 < columns {
                    totalDifference += abs(current - Double(grid[index + 1]))
                    comparisons += 1
                }

                if row + 1 < rows {
                    totalDifference += abs(current - Double(grid[index + columns]))
                    comparisons += 1
                }
            }
        }

        guard comparisons > 0 else {
            return 0
        }

        let normalized = totalDifference / comparisons / 255.0
        return min(max(normalized * 2.8, 0), 1)
    }

    private static func sceneChangeScore(current: [UInt8], previous: [UInt8]) -> Double {
        guard current.isEmpty == false, current.count == previous.count else {
            return 0.12
        }

        let totalDifference = zip(current, previous).reduce(0.0) { partialResult, pair in
            partialResult + abs(Double(pair.0) - Double(pair.1))
        }
        let normalized = totalDifference / Double(current.count) / 255.0
        return min(max(normalized * 4.6, 0), 1)
    }

    private static func detectRectangleCandidates(
        in pixelBuffer: CVPixelBuffer,
        lumaGrid: [UInt8],
        columns: Int,
        rows: Int,
        orientation: CGImagePropertyOrientation
    ) -> [RectangleCandidateAssessment] {
        #if canImport(Vision)
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 10
        request.minimumConfidence = 0.35
        request.minimumAspectRatio = 0.52
        request.minimumSize = 0.02
        request.quadratureTolerance = 25

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = request.results ?? []
        return observations.compactMap { observation in
            let aspectRatio = observation.boundingBox.width / max(observation.boundingBox.height, 0.0001)
            let area = observation.boundingBox.width * observation.boundingBox.height
            guard aspectRatio >= 0.5,
                  aspectRatio <= 1.85,
                  area >= 0.004,
                  area <= 0.28 else {
                return nil
            }

            let outerStats = sampleStats(
                in: observation.boundingBox,
                from: lumaGrid,
                columns: columns,
                rows: rows
            )
            let innerStats = sampleStats(
                in: inset(normalizedRect: observation.boundingBox, xFraction: 0.18, yFraction: 0.18),
                from: lumaGrid,
                columns: columns,
                rows: rows
            )
            let centerStats = sampleStats(
                in: inset(normalizedRect: observation.boundingBox, xFraction: 0.32, yFraction: 0.32),
                from: lumaGrid,
                columns: columns,
                rows: rows
            )
            guard outerStats.sampleCount >= 6, innerStats.sampleCount >= 4 else {
                return nil
            }

            let borderAverage: Double
            if outerStats.sampleCount > innerStats.sampleCount {
                borderAverage = max(
                    (
                        outerStats.average * Double(outerStats.sampleCount)
                            - innerStats.average * Double(innerStats.sampleCount)
                    ) / Double(outerStats.sampleCount - innerStats.sampleCount),
                    0
                )
            } else {
                borderAverage = outerStats.average
            }

            let confidence = clamp(Double(observation.confidence))
            let squareness = 1 - min(abs(1 - aspectRatio) / 0.35, 1)
            let labelAspectFit = 1 - min(abs(1.1 - aspectRatio) / 0.95, 1)
            let borderDarkness = clamp((innerStats.average - borderAverage) * 2.6)
            let interiorVariation = clamp(innerStats.spread * 3.0)
            let centerVariation = clamp(centerStats.spread * 3.4)
            let displayLikeScore = clamp(
                confidence * 0.18
                    + clamp(area * 3.1) * 0.18
                    + labelAspectFit * 0.24
                    + (1 - borderDarkness) * 0.18
                    + (1 - interiorVariation) * 0.22
            )
            let tagLikeScore = clamp(
                confidence * 0.18
                    + squareness * 0.12
                    + labelAspectFit * 0.12
                    + borderDarkness * 0.24
                    + interiorVariation * 0.20
                    + centerVariation * 0.14
            )
            let isTagLike = tagLikeScore >= 0.54
                && (borderDarkness >= 0.10 || interiorVariation >= 0.22)
                && centerStats.sampleCount >= 4
            let structuredArtifactScore = clamp(
                confidence * 0.24
                    + labelAspectFit * 0.16
                    + displayLikeScore * 0.26
                    + (1 - borderDarkness) * 0.12
                    + (1 - centerVariation) * 0.10
                    + clamp(outerStats.spread * 1.8) * 0.12
            )

            return RectangleCandidateAssessment(
                boundingBox: observation.boundingBox,
                detectionConfidence: confidence,
                tagLikeScore: tagLikeScore,
                structuredArtifactScore: structuredArtifactScore,
                displayLikeScore: displayLikeScore,
                isTagLike: isTagLike,
                isStructuredArtifact: !isTagLike && structuredArtifactScore >= 0.58
            )
        }
        #else
        return []
        #endif
    }

    private static func foregroundSegmentationSummary(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        screenLikelihood: Double,
        equipmentLikelihood: Double,
        textLikelihood: Double,
        referenceObservationCount: Int
    ) -> ForegroundSegmentationSummary? {
        #if canImport(Vision)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first else {
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
        guard stats.foregroundRatio >= 0.04 || stats.lowerFrameRatio >= 0.08 else {
            return nil
        }

        let clutterPenalty = clamp(
            screenLikelihood * 0.34
                + equipmentLikelihood * 0.14
                + textLikelihood * 0.12
        )
        let referenceLift = min(Double(referenceObservationCount) / 2.0, 1) * 0.08
        let pileConfidence = clamp(
            stats.foregroundRatio * 0.34
                + stats.lowerFrameRatio * 0.28
                + stats.horizontalSpread * 0.16
                + stats.centeredness * 0.12
                + stats.bottomReach * 0.10
                + referenceLift
                - clutterPenalty
        )
        let toeConfidence = clamp(
            stats.toeBandRatio * 0.44
                + stats.lowerFrameRatio * 0.20
                + stats.bottomReach * 0.20
                + stats.horizontalSpread * 0.08
                + referenceLift * 0.5
                - clutterPenalty * 0.72
        )

        guard pileConfidence >= 0.08 || toeConfidence >= 0.08 else {
            return nil
        }

        return ForegroundSegmentationSummary(
            pileConfidence: pileConfidence,
            toeConfidence: toeConfidence
        )
        #else
        return nil
        #endif
    }

    private static func foregroundMaskStats(from pixelBuffer: CVPixelBuffer) -> ForegroundMaskStats {
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
        let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.stride
        let unsignedPointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let floatPointer = baseAddress.assumingMemoryBound(to: Float32.self)
        let foregroundThreshold: Double = pixelFormat == kCVPixelFormatType_OneComponent32Float ? 0.12 : 0.08

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

            for column in 0..<columns {
                let normalizedX = (Double(column) + 0.5) / Double(columns)
                let pixelX = min(max(Int(normalizedX * Double(width)), 0), max(width - 1, 0))
                let isForeground = sampleValue(x: pixelX, y: pixelY) >= foregroundThreshold

                if normalizedY >= 0.58 {
                    lowerTotalSamples += 1
                }
                if normalizedY >= 0.78 {
                    toeTotalSamples += 1
                }

                guard isForeground else {
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

    private static func referenceDetections(
        from rectangleCandidates: [RectangleCandidateAssessment],
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> [ReferenceDetection] {
        rectangleCandidates
            .sorted { lhs, rhs in
                if lhs.tagLikeScore == rhs.tagLikeScore {
                    return lhs.detectionConfidence > rhs.detectionConfidence
                }
                return lhs.tagLikeScore > rhs.tagLikeScore
            }
            .prefix(3)
            .map { candidate in
                let region = expandedRegion(
                    for: candidate.boundingBox,
                    xFraction: 0.12,
                    yFraction: 0.12
                )
                if let barcodeResult = decodeBarcode(
                    in: pixelBuffer,
                    orientation: orientation,
                    regionOfInterest: region
                ) {
                    return ReferenceDetection(
                        markerID: barcodeResult.markerID,
                        source: .barcode,
                        confidence: clamp(candidate.tagLikeScore * 0.46 + barcodeResult.confidence * 0.54),
                        boundingBox: candidate.boundingBox
                    )
                }

                if let textResult = decodeText(
                    in: pixelBuffer,
                    orientation: orientation,
                    regionOfInterest: region
                ) {
                    return ReferenceDetection(
                        markerID: textResult.markerID,
                        source: .ocr,
                        confidence: clamp(candidate.tagLikeScore * 0.52 + textResult.confidence * 0.48),
                        boundingBox: candidate.boundingBox
                    )
                }

                return ReferenceDetection(
                    markerID: nil,
                    source: .tagLike,
                    confidence: clamp(candidate.tagLikeScore * 0.76 + candidate.detectionConfidence * 0.24),
                    boundingBox: candidate.boundingBox
                )
            }
    }

    private static func deduplicateReferenceDetections(
        _ detections: [ReferenceDetection]
    ) -> [ReferenceDetection] {
        let sortedDetections = detections.sorted { lhs, rhs in
            lhs.confidence > rhs.confidence
        }
        var acceptedDetections: [ReferenceDetection] = []
        var acceptedMarkerIDs: Set<String> = []

        for detection in sortedDetections {
            if let markerID = detection.markerID {
                guard acceptedMarkerIDs.contains(markerID) == false else {
                    continue
                }
                acceptedMarkerIDs.insert(markerID)
            }

            let overlapsExisting = acceptedDetections.contains { existingDetection in
                intersectionOverUnion(existingDetection.boundingBox, detection.boundingBox) >= 0.66
            }
            guard overlapsExisting == false else {
                continue
            }
            acceptedDetections.append(detection)
        }

        return acceptedDetections
    }

    private static func detectSceneText(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> SceneTextObservation {
        #if canImport(Vision)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.018
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        do {
            try handler.perform([request])
        } catch {
            return .empty
        }

        let observations = request.results ?? []
        let characterCount = observations.reduce(0) { partialResult, observation in
            guard let topCandidate = observation.topCandidates(1).first else {
                return partialResult
            }
            return partialResult + min(topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines).count, 24)
        }
        return SceneTextObservation(
            blockCount: observations.count,
            characterCount: characterCount
        )
        #else
        return .empty
        #endif
    }

    private static func classifyScene(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> [VNClassificationObservation] {
        #if canImport(Vision)
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return Array((request.results ?? []).prefix(6))
        #else
        return []
        #endif
    }

    private static func materialFamilySuggestion(
        from classifications: [VNClassificationObservation]
    ) -> StockpileCaptureMaterialFamilySuggestion? {
        let families: [(familyCode: String, label: String, keywords: [(String, Double)])] = [
            (
                familyCode: "aggregate_rock",
                label: "Coarse aggregate / rock",
                keywords: [
                    ("gravel", 1.0),
                    ("pebble", 0.94),
                    ("rock", 0.88),
                    ("stone", 0.84),
                    ("quarry", 0.80),
                    ("boulder", 0.76)
                ]
            ),
            (
                familyCode: "sand_soil_fines",
                label: "Sand / soil / fines",
                keywords: [
                    ("sand", 1.0),
                    ("soil", 0.92),
                    ("earth", 0.88),
                    ("dirt", 0.86),
                    ("mud", 0.80),
                    ("dune", 0.78)
                ]
            ),
            (
                familyCode: "asphalt_or_tailings",
                label: "Asphalt / dark fines",
                keywords: [
                    ("asphalt", 1.0),
                    ("road", 0.82),
                    ("pavement", 0.82),
                    ("tar", 0.76),
                    ("coal", 0.76),
                    ("charcoal", 0.72)
                ]
            )
        ]

        var bestSuggestion: StockpileCaptureMaterialFamilySuggestion?
        var bestScore = 0.0

        for family in families {
            let score = keywordScore(from: classifications, keywords: family.keywords)
            guard score > bestScore else {
                continue
            }
            bestScore = score
            bestSuggestion = StockpileCaptureMaterialFamilySuggestion(
                familyCode: family.familyCode,
                label: family.label,
                confidence: score
            )
        }

        guard bestScore >= 0.34 else {
            return nil
        }
        return bestSuggestion
    }

    private static func keywordScore(
        from classifications: [VNClassificationObservation],
        keywords: [(String, Double)]
    ) -> Double {
        var bestScore = 0.0
        for classification in classifications {
            let identifier = classification.identifier.lowercased()
            for (keyword, weight) in keywords where identifier.contains(keyword) {
                bestScore = max(bestScore, Double(classification.confidence) * weight)
            }
        }
        return clamp(bestScore)
    }

    private static func sceneRejectionReasons(
        screenLikelihood: Double,
        equipmentLikelihood: Double,
        textLikelihood: Double
    ) -> [StockpileCaptureSceneRejectionReason] {
        var reasons: [StockpileCaptureSceneRejectionReason] = []
        if screenLikelihood >= 0.56 {
            reasons.append(.screenLikeDisplay)
        }
        if equipmentLikelihood >= 0.58 {
            reasons.append(.nearbyEquipment)
        }
        if textLikelihood >= 0.72 {
            reasons.append(.textHeavyForeground)
        }
        return reasons
    }

    private static func referenceObservationSort(
        lhs: StockpileCaptureReferenceObservation,
        rhs: StockpileCaptureReferenceObservation
    ) -> Bool {
        if lhs.markerID != nil && rhs.markerID == nil {
            return true
        }
        if lhs.markerID == nil && rhs.markerID != nil {
            return false
        }
        if lhs.confidence == rhs.confidence {
            return lhs.stabilityScore > rhs.stabilityScore
        }
        return lhs.confidence > rhs.confidence
    }

    private static func decodeBarcode(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        regionOfInterest: CGRect
    ) -> (markerID: String, confidence: Double)? {
        #if canImport(Vision)
        let request = VNDetectBarcodesRequest()
        request.regionOfInterest = clamp(normalizedRect: regionOfInterest)
        request.symbologies = [
            .qr,
            .aztec,
            .dataMatrix,
            .pdf417,
            .code128,
            .code39,
            .code93
        ]

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let bestObservation = (request.results ?? []).max { lhs, rhs in
            lhs.confidence < rhs.confidence
        }
        guard let observation = bestObservation,
              let payload = observation.payloadStringValue,
              let markerID = normalizeMarkerID(from: payload) else {
            return nil
        }

        return (
            markerID: markerID,
            confidence: clamp(Double(observation.confidence))
        )
        #else
        return nil
        #endif
    }

    private static func decodeText(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        regionOfInterest: CGRect
    ) -> (markerID: String, confidence: Double)? {
        #if canImport(Vision)
        let request = VNRecognizeTextRequest()
        request.regionOfInterest = clamp(normalizedRect: regionOfInterest)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.08

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(2) {
                if let markerID = normalizeMarkerID(from: candidate.string) {
                    return (
                        markerID: markerID,
                        confidence: clamp(Double(candidate.confidence))
                    )
                }
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    private static func normalizeMarkerID(from rawValue: String) -> String? {
        let asciiValue = rawValue.folding(options: .diacriticInsensitive, locale: .current)
        let cleanedValue = asciiValue
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanedValue.isEmpty == false else {
            return nil
        }

        let rawSegments = cleanedValue.split { character in
            character.isLetter == false && character.isNumber == false
        }
        let normalizedSegments = rawSegments.map { segment in
            String(segment).lowercased()
        }

        if normalizedSegments.count >= 2 {
            let prefix = normalizedSegments[0]
            let suffix = normalizedSegments[1]
            if prefix.count >= 2,
               suffix.contains(where: { $0.isNumber }) {
                return "\(prefix)-\(suffix)"
            }
        }

        let compactValue = cleanedValue
            .lowercased()
            .filter { character in
                character.isLetter || character.isNumber || character == "-" || character == "_"
            }
            .replacingOccurrences(of: "_", with: "-")
        guard compactValue.count >= 4, compactValue.count <= 20 else {
            return nil
        }

        if let splitIndex = compactValue.firstIndex(where: { $0.isNumber }),
           splitIndex != compactValue.startIndex {
            let prefix = String(compactValue[..<splitIndex])
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let suffix = String(compactValue[splitIndex...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if prefix.count >= 2,
               suffix.contains(where: { $0.isNumber }) {
                return "\(prefix)-\(suffix)"
            }
        }

        guard compactValue.contains(where: { $0.isNumber }) else {
            return nil
        }

        return compactValue
    }

    private static func expandedRegion(
        for normalizedRect: CGRect,
        xFraction: CGFloat,
        yFraction: CGFloat
    ) -> CGRect {
        let rect = clamp(normalizedRect: normalizedRect)
        let insetX = rect.width * xFraction
        let insetY = rect.height * yFraction
        return clamp(
            normalizedRect: CGRect(
                x: rect.minX - insetX,
                y: rect.minY - insetY,
                width: rect.width + insetX * 2,
                height: rect.height + insetY * 2
            )
        )
    }

    private static func blendedRect(_ lhs: CGRect, _ rhs: CGRect) -> CGRect {
        CGRect(
            x: lhs.origin.x * 0.42 + rhs.origin.x * 0.58,
            y: lhs.origin.y * 0.42 + rhs.origin.y * 0.58,
            width: lhs.size.width * 0.42 + rhs.size.width * 0.58,
            height: lhs.size.height * 0.42 + rhs.size.height * 0.58
        )
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersectionRect = lhs.intersection(rhs)
        guard intersectionRect.isNull == false else {
            return 0
        }

        let intersectionArea = intersectionRect.width * intersectionRect.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        guard unionArea > 0 else {
            return 0
        }

        return clamp(Double(intersectionArea / unionArea))
    }

    private static func centerDistance(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let deltaX = lhs.midX - rhs.midX
        let deltaY = lhs.midY - rhs.midY
        return sqrt(Double(deltaX * deltaX + deltaY * deltaY))
    }

    private static func inset(
        normalizedRect: CGRect,
        xFraction: CGFloat,
        yFraction: CGFloat
    ) -> CGRect {
        let rect = clamp(normalizedRect: normalizedRect)
        let insetX = rect.width * xFraction
        let insetY = rect.height * yFraction
        let insetRect = rect.insetBy(dx: insetX, dy: insetY)
        guard insetRect.width > 0.01, insetRect.height > 0.01 else {
            return rect
        }
        return clamp(normalizedRect: insetRect)
    }

    private static func sampleStats(
        in normalizedRect: CGRect,
        from grid: [UInt8],
        columns: Int,
        rows: Int
    ) -> RectangleSampleStats {
        guard grid.isEmpty == false, columns > 0, rows > 0 else {
            return .empty
        }

        let rect = clamp(normalizedRect: normalizedRect)
        guard rect.width > 0.001, rect.height > 0.001 else {
            return .empty
        }

        let minimumColumn = max(0, min(columns - 1, Int(floor(rect.minX * CGFloat(columns)))))
        let maximumColumn = max(
            minimumColumn,
            min(columns - 1, Int(ceil(rect.maxX * CGFloat(columns))) - 1)
        )
        let minimumRow = max(0, min(rows - 1, Int(floor((1 - rect.maxY) * CGFloat(rows)))))
        let maximumRow = max(
            minimumRow,
            min(rows - 1, Int(ceil((1 - rect.minY) * CGFloat(rows))) - 1)
        )

        var minimumValue = UInt8.max
        var maximumValue = UInt8.min
        var total = 0.0
        var count = 0

        for row in minimumRow...maximumRow {
            for column in minimumColumn...maximumColumn {
                let sample = grid[row * columns + column]
                minimumValue = min(minimumValue, sample)
                maximumValue = max(maximumValue, sample)
                total += Double(sample)
                count += 1
            }
        }

        guard count > 0 else {
            return .empty
        }

        return RectangleSampleStats(
            average: total / Double(count) / 255.0,
            spread: Double(maximumValue - minimumValue) / 255.0,
            sampleCount: count
        )
    }

    private static func clamp(normalizedRect: CGRect) -> CGRect {
        let minimumX = min(max(normalizedRect.minX, 0), 1)
        let minimumY = min(max(normalizedRect.minY, 0), 1)
        let maximumX = min(max(normalizedRect.maxX, 0), 1)
        let maximumY = min(max(normalizedRect.maxY, 0), 1)

        guard maximumX > minimumX, maximumY > minimumY else {
            return .zero
        }

        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private extension AVCaptureConnection {
    var visionImageOrientation: CGImagePropertyOrientation {
        #if os(macOS)
        switch Int(videoRotationAngle.rounded()) % 360 {
        case 90:
            return .right
        case 180:
            return .down
        case 270:
            return .left
        default:
            return .up
        }
        #else
        switch videoOrientation {
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeRight:
            return .down
        case .landscapeLeft:
            return .up
        @unknown default:
            return .right
        }
        #endif
    }
}

private enum StockpileAVFoundationCameraError: LocalizedError {
    case noVideoDevice(StockpileCameraLensPosition)
    case unableToAddInput
    case unableToAddMovieOutput
    case sessionDidNotStart
    case recordingAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case let .noVideoDevice(preferredPosition):
            switch preferredPosition {
            case .back:
                return "No back camera is available on this device."
            case .front:
                return "No front camera is available on this device."
            case .unspecified:
                return "No video capture device is available on this device."
            }
        case .unableToAddInput:
            return "The camera session could not be configured for video input."
        case .unableToAddMovieOutput:
            return "The camera session could not be configured for movie recording."
        case .sessionDidNotStart:
            return "The rear camera session did not start. Close other camera apps and retry."
        case .recordingAlreadyInProgress:
            return "A camera recording is already in progress."
        }
    }
}

private extension StockpileCameraLensPosition {
    var avCapturePosition: AVCaptureDevice.Position? {
        switch self {
        case .back:
            return .back
        case .front:
            return .front
        case .unspecified:
            return nil
        }
    }
}
