import AVFoundation
import Foundation
import StockpileCameraCapture
import StockpileCaptureFlow
import StockpileDesignSystem
import StockpileMobileAPI
import StockpileProcessingRuntime
import StockpileResultsUI
import StockpileUploadPipeline
import UniformTypeIdentifiers
#if canImport(StockpileMobileFirstCapture)
import StockpileMobileFirstCapture
#endif
#if os(iOS) && canImport(ARKit)
import ARKit
import simd
#endif

struct CaptureImportedVideoMetadataItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let value: String
    let systemImage: String

    init(
        id: String? = nil,
        title: String,
        value: String,
        systemImage: String
    ) {
        self.id = id ?? title.lowercased().replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        self.title = title
        self.value = value
        self.systemImage = systemImage
    }
}

struct CaptureImportedVideoSelection: Equatable, Sendable {
    let displayName: String
    let subtitle: String
    let statusMessage: String
    let metadataItems: [CaptureImportedVideoMetadataItem]
}

@MainActor
protocol CaptureFeatureVideoImportStoreBridging: AnyObject {
    var selectedImportedVideo: CaptureImportedVideoSelection? { get }

    func importSelectedImportedVideo(from url: URL) async throws
    func clearSelectedImportedVideo()
}

enum CaptureFeaturePhase: String, CaseIterable, Identifiable {
    case idle
    case guidedCapture
    case uploadInProgress
    case processing
    case verifiedResult
    case reviewOnlyResult
    case blockedResult

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle:
            return "Ready to record"
        case .guidedCapture:
            return "Recording walkaround"
        case .uploadInProgress:
            return "Sealing recording"
        case .processing:
            return "Building result"
        case .verifiedResult:
            return "Verified result"
        case .reviewOnlyResult:
            return "Review-only result"
        case .blockedResult:
            return "Capture blocked"
        }
    }

    var badgeLabel: String {
        switch self {
        case .idle:
            return "Ready"
        case .guidedCapture:
            return "Recording"
        case .uploadInProgress:
            return "Sealing"
        case .processing:
            return "Processing"
        case .verifiedResult:
            return "Verified"
        case .reviewOnlyResult:
            return "Review only"
        case .blockedResult:
            return "Blocked"
        }
    }

    var badgeTone: StockpileStatusTone {
        switch self {
        case .idle, .guidedCapture, .uploadInProgress, .processing:
            return .info
        case .verifiedResult:
            return .success
        case .reviewOnlyResult:
            return .caution
        case .blockedResult:
            return .critical
        }
    }

    var summary: String {
        switch self {
        case .idle:
            return "Record the pile in one steady in-app walkaround."
        case .guidedCapture:
            return "Keep the rear-camera lap steady until the toe boundary and tagged references look locked."
        case .uploadInProgress:
            return "The recorded pass is being sealed and handed off automatically."
        case .processing:
            return "Server checks are turning the recorded pass into a result."
        case .verifiedResult:
            return "The run passed the confidence thresholds and is ready to share."
        case .reviewOnlyResult:
            return "The run completed, but the result should be reviewed before it is treated as final."
        case .blockedResult:
            return "The run could not be verified. Retake it with stronger visibility and coverage."
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .idle:
            return "Start live recording"
        case .guidedCapture:
            return "Keep recording"
        case .uploadInProgress:
            return "Sealing..."
        case .processing:
            return "Building result..."
        case .verifiedResult:
            return "Open verified report"
        case .reviewOnlyResult:
            return "Open review"
        case .blockedResult:
            return "Retake capture"
        }
    }

    var primaryActionHint: String {
        switch self {
        case .idle:
            return "Start with the full pile in view and move into one steady lap."
        case .guidedCapture:
            return "Keep two tagged references visible as you complete the perimeter."
        case .uploadInProgress:
            return "Keep the app open while the recorded pass is secured."
        case .processing:
            return "The recorded pass is already secure and result checks are running."
        case .verifiedResult:
            return "Review the metrics and share when you are ready."
        case .reviewOnlyResult:
            return "Compare the result against the site benchmark before sharing."
        case .blockedResult:
            return "Retake with more of the toe boundary and references in frame."
        }
    }

    var primaryAction: CaptureFeatureAction {
        switch self {
        case .idle:
            return .startCapture
        case .guidedCapture:
            return .advanceCapture
        case .uploadInProgress:
            return .viewUploadDetails
        case .processing:
            return .refreshStatus
        case .verifiedResult:
            return .openVerifiedReport
        case .reviewOnlyResult:
            return .openReview
        case .blockedResult:
            return .retakeCapture
        }
    }
}

enum CaptureFeatureAction: Equatable {
    case startCapture
    case advanceCapture
    case viewUploadDetails
    case refreshStatus
    case openVerifiedReport
    case openReview
    case retakeCapture
}

struct CaptureFeatureDependencies {
    var handleAction: @MainActor (CaptureFeatureAction) -> Void

    init(handleAction: @escaping @MainActor (CaptureFeatureAction) -> Void = { _ in }) {
        self.handleAction = handleAction
    }

    static let noop = CaptureFeatureDependencies()
}

struct CaptureFeatureConfiguration {
    var home: CaptureHomeContent
    var guidedCapture: GuidedCaptureContent
    var uploading: UploadProgressContent
    var processing: UploadProgressContent
    var verifiedResult: StockpileResultScreenModel?
    var reviewOnlyResult: StockpileResultScreenModel?
    var blockedResult: StockpileResultScreenModel?
    var terminalResultPhase: CaptureFeaturePhase
    var pipeline: CaptureFeaturePipelineConfiguration

    struct CaptureFeaturePipelineConfiguration {
        var siteID: String
        var materialCode: String
        var densityKgPerM3: Int
        var referenceCountGoal: Int
        var clientBuild: String
        var backgroundSessionIdentifier: String?
        var allowsImportedBackupVideo: Bool
        var allowsConfiguredFallbackCaptureFile: Bool
        var lidarAssistEnabled: Bool
        var markerlessCaptureEnabled: Bool

        static let preview = CaptureFeaturePipelineConfiguration(
            siteID: "qpmc-north-yard",
            materialCode: "backfill-0-75-mm",
            densityKgPerM3: 2100,
            referenceCountGoal: 3,
            clientBuild: "ios-preview",
            backgroundSessionIdentifier: "com.clustox.stockpile.capture.upload",
            allowsImportedBackupVideo: false,
            allowsConfiguredFallbackCaptureFile: false,
            lidarAssistEnabled: true,
            markerlessCaptureEnabled: true
        )
    }

    static let preview = CaptureFeatureConfiguration(
        home: .preview,
        guidedCapture: .preview,
        uploading: .uploadingPreview,
        processing: .processingPreview,
        verifiedResult: .mockVerified,
        reviewOnlyResult: .mockReviewOnly,
        blockedResult: .mockBlocked,
        terminalResultPhase: .reviewOnlyResult,
        pipeline: .preview
    )

    static let blockedPreview = CaptureFeatureConfiguration(
        home: .preview,
        guidedCapture: .preview,
        uploading: .uploadingPreview,
        processing: .blockedPreview,
        verifiedResult: .mockVerified,
        reviewOnlyResult: .mockReviewOnly,
        blockedResult: .mockBlocked,
        terminalResultPhase: .blockedResult,
        pipeline: .preview
    )
}

private struct CaptureSelectedMovieStorage: Sendable {
    let descriptor: StockpileUploadFileDescriptor
    let cachedFileURL: URL
}

private struct CaptureResolvedUploadInput: Sendable {
    let descriptor: StockpileUploadFileDescriptor
    let source: CaptureUploadSource
}

struct CaptureFeaturePendingUploadFileState: Codable, Equatable, Sendable {
    let fileURL: URL
    let fileName: String
    let byteCount: Int64
    let contentType: String
    let checksumSHA256: String?

    init(file: StockpileUploadFileDescriptor) {
        fileURL = file.fileURL
        fileName = file.fileName
        byteCount = file.byteCount
        contentType = file.contentType
        checksumSHA256 = file.checksumSHA256
    }

    func makeDescriptor() -> StockpileUploadFileDescriptor {
        StockpileUploadFileDescriptor(
            fileURL: fileURL,
            fileName: fileName,
            byteCount: byteCount,
            contentType: contentType,
            checksumSHA256: checksumSHA256
        )
    }
}

struct CaptureFeaturePendingRunRecoveryState: Codable, Equatable, Sendable {
    let sessionID: String
    let uploadID: String
    let jobID: String
    var runID: String?
    let pileName: String
    let source: CaptureUploadSource
    let createdAt: Date
    let file: CaptureFeaturePendingUploadFileState?
    var uploadTaskID: String?
    var backgroundSessionIdentifier: String?
    var uploadCompletedAt: Date?
    var serverReceiptID: String?
    var serverUploadID: String?
    var localQuickEstimate: CaptureFeatureLocalQuickEstimate?
}

enum CaptureUploadSource: String, Codable, Sendable, Equatable {
    case liveRecorded
    case importedVideo
    case fallbackVideo

    var apiSource: StockpileCaptureSourcePayload {
        switch self {
        case .liveRecorded:
            return .liveRecordedVideo
        case .importedVideo:
            return .importedVideo
        case .fallbackVideo:
            return .fallbackVideo
        }
    }
}

private enum CaptureSelectedMovieImportError: LocalizedError {
    case missingLocalMovie(URL)
    case unreadableMovie(URL)
    case missingMovieAttributes(URL)
    case unsupportedMovieType(URL)
    case missingSelectedMovie(String)
    case missingRecordedCapture(String)
    case failedToFinalizeRecordedCapture(String)
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingLocalMovie(let url):
            return "The Files backup could not be found at \(url.lastPathComponent)."
        case .unreadableMovie(let url):
            return "The Files backup could not be copied locally from \(url.lastPathComponent)."
        case .missingMovieAttributes(let url):
            return "The Files backup size could not be read for \(url.lastPathComponent)."
        case .unsupportedMovieType(let url):
            return "Choose a Files backup recording that can be opened as a walkaround capture. \(url.lastPathComponent) is not supported."
        case .missingSelectedMovie(let fallbackMessage):
            return "No live walkaround is ready and no Files backup is available for upload. \(fallbackMessage)"
        case .missingRecordedCapture(let message):
            return "The walkaround finished, but no recorded capture file was available yet. \(message)"
        case .failedToFinalizeRecordedCapture(let message):
            return "The walkaround recording could not be finalized for upload. \(message)"
        case .uploadFailed(let message):
            return "The Files backup could not be uploaded cleanly. \(message)"
        }
    }
}

@MainActor
protocol CaptureFeatureRecordedCaptureSessionBridging: AnyObject {
    var finalizedRecordedVideoDescriptor: StockpileUploadFileDescriptor? { get }

    func finalizeRecordedVideoIfNeeded() async throws -> StockpileUploadFileDescriptor
}

@MainActor
protocol CaptureFeatureLivePreviewSessionBridging: AnyObject {
    var livePreviewCaptureSession: AVCaptureSession? { get }
    var livePreviewState: StockpileCameraCaptureSessionState { get }
}

@MainActor
extension StockpileCameraCaptureSessionLive: CaptureFeatureLivePreviewSessionBridging {
    var livePreviewCaptureSession: AVCaptureSession? { captureSession }
    var livePreviewState: StockpileCameraCaptureSessionState { state }
}

struct CaptureFeatureInlineStatusContent {
    let title: String
    let message: String
    let tone: StockpileStatusTone
    let systemImage: String
}

enum CaptureFeatureSceneWarningLevel {
    case none
    case watch
    case blocked
}

struct CaptureFeatureSceneIntelligence {
    let materialSuggestion: CaptureFeatureInlineStatusContent
    let wrongSceneFeedback: CaptureFeatureInlineStatusContent?
    let wrongSceneLevel: CaptureFeatureSceneWarningLevel
}

private enum CaptureFeatureReferenceMarkerSource {
    case observed
    case estimated
    case unavailable
}

private struct CaptureFeatureReferenceMarkerContext {
    let source: CaptureFeatureReferenceMarkerSource
    let snapshots: [StockpileReferenceMarkerSnapshotPayload]

    static let empty = CaptureFeatureReferenceMarkerContext(
        source: .unavailable,
        snapshots: []
    )

    var markerIDs: [String] {
        snapshots.map(\.markerID)
    }

    var maxVisibleTogether: Int {
        snapshots.map(\.visibleCount).max() ?? 0
    }

    var strongestConfidence: Double {
        snapshots.map(\.confidence).max() ?? 0
    }

    var hasObservedMarkers: Bool {
        source == .observed && snapshots.isEmpty == false
    }
}

private enum CaptureFeatureTrace {
    static func log(_ event: String, state: StockpileCameraCaptureSessionState? = nil, details: String = "") {
        var parts = [event]
        if let state {
            parts.append(
                [
                    "phase=\(state.phase.rawValue)",
                    "session=\(state.sessionLifecycle.rawValue)",
                    "recording=\(state.recordingLifecycle.rawValue)",
                    "operator=\(state.operatorStage.rawValue)",
                    "permission=\(state.permission.status.rawValue)",
                    "trace=\(state.debugTraceSummary ?? "nil")",
                ].joined(separator: " ")
            )
        }
        if details.isEmpty == false {
            parts.append(details)
        }
        NSLog("STOCKPILE_CAPTURE_TRACE %@", parts.joined(separator: " | "))
    }
}

@MainActor
final class CaptureFeatureStore: ObservableObject {
    @Published var phase: CaptureFeaturePhase {
        didSet {
            refreshCameraMonitoringState()
        }
    }
    @Published var configuration: CaptureFeatureConfiguration
    @Published private(set) var selectedMovieFileDescriptor: StockpileUploadFileDescriptor?
    @Published private(set) var selectedMovieImportErrorMessage: String?
    @Published private(set) var isPreparingSelectedMovie = false
    @Published private(set) var isFinalizingRecordedCapture = false {
        didSet {
            refreshCameraMonitoringState()
        }
    }
    @Published private(set) var pendingRunRecoveryState: CaptureFeaturePendingRunRecoveryState?
    @Published private(set) var currentProcessingState: StockpileProcessingRuntimeState?
    /// Live on-device LiDAR quick estimate emitted by the ARKit pose runtime.
    /// Updated every time the pose observation controller publishes a new
    /// snapshot, so HUD readouts stay in sync as the operator walks the pile.
    @Published private(set) var latestQuickVolumeEstimate: CaptureFeatureLocalQuickEstimate?
    /// Latest state of the v2 `.stockpilecapture` bundle submission. The legacy
    /// v1 path is unaffected; this stays `.idle` for non-markerless captures.
    @Published private(set) var markerlessSubmissionState: StockpileMarkerlessCaptureSubmissionState = .idle
    /// Most recent markerless submission receipt (kept after the request lands
    /// so the UI can offer "open processing" affordances).
    @Published private(set) var lastMarkerlessSubmissionReceipt: StockpileCaptureBundleSubmissionReceipt?

    private let initialConfiguration: CaptureFeatureConfiguration
    private let dependencies: CaptureFeatureDependencies
    private let cameraSession: (any StockpileCameraCaptureSessionServicing)?
    private let apiService: (any StockpileMobileAPIServicing)?
    private let uploadService: (any StockpileUploadServicing)?
    private let processingCoordinator: StockpileProcessingRuntimeCoordinator?
    private let uploadFileDescriptorProvider: () throws -> StockpileUploadFileDescriptor
    private let poseObservationController: CaptureFeatureDevicePoseObservationController
    private let markerlessSubmissionCoordinator: StockpileMarkerlessCaptureSubmissionCoordinator?
    private var pipelineTask: Task<Void, Never>?
    private var cameraMonitoringTask: Task<Void, Never>?
    private var markerlessSubmissionTask: Task<Void, Never>?
    private var lastSubmittedMarkerlessArchiveURL: URL?
    private var selectedMovieStorage: CaptureSelectedMovieStorage?
    private var ownedSelectedMovieURLs: Set<URL> = []
    private var activeUploadFileURL: URL?
    private var activeUploadSource: CaptureUploadSource?
    private var lastObservedCameraState: StockpileCameraCaptureSessionState?

    init(
        configuration: CaptureFeatureConfiguration = .preview,
        phase: CaptureFeaturePhase = .idle,
        dependencies: CaptureFeatureDependencies = .noop,
        cameraSession: (any StockpileCameraCaptureSessionServicing)? = nil,
        apiService: (any StockpileMobileAPIServicing)? = nil,
        uploadService: (any StockpileUploadServicing)? = nil,
        processingCoordinator: StockpileProcessingRuntimeCoordinator? = nil,
        markerlessSubmissionCoordinator: StockpileMarkerlessCaptureSubmissionCoordinator? = nil,
        uploadFileDescriptorProvider: @escaping () throws -> StockpileUploadFileDescriptor = CaptureFeatureStore.defaultUploadDescriptor
    ) {
        let poseObservationController = CaptureFeatureDevicePoseObservationController()
        self.configuration = configuration
        self.phase = phase
        self.initialConfiguration = configuration
        self.dependencies = dependencies
        self.cameraSession = cameraSession
        self.apiService = apiService
        self.uploadService = uploadService
        self.processingCoordinator = processingCoordinator
        self.markerlessSubmissionCoordinator = markerlessSubmissionCoordinator
        self.poseObservationController = poseObservationController
        self.uploadFileDescriptorProvider = uploadFileDescriptorProvider
        self.poseObservationController.onStateUpdated = { [weak self] state in
            self?.handlePoseObservationStateUpdated(state)
        }
    }

    deinit {
        pipelineTask?.cancel()
        cameraMonitoringTask?.cancel()
        markerlessSubmissionTask?.cancel()
        let retainedURLs = Set([activeUploadFileURL].compactMap { $0 })
        let removableURLs = ownedSelectedMovieURLs.filter { retainedURLs.contains($0) == false }
        Self.removeOwnedFiles(removableURLs)
    }

    var currentResult: StockpileResultScreenModel? {
        switch phase {
        case .verifiedResult:
            return configuration.verifiedResult
        case .blockedResult:
            return configuration.blockedResult
        case .reviewOnlyResult:
            return configuration.reviewOnlyResult
        case .processing:
            return currentProvisionalResultModel()
        default:
            return nil
        }
    }

    var currentProgressContent: UploadProgressContent {
        switch phase {
        case .processing:
            return configuration.processing
        case .uploadInProgress:
            return configuration.uploading
        default:
            return configuration.uploading
        }
    }

    var currentRecaptureGuidance: RecaptureGuidanceContent? {
        switch phase {
        case .processing:
            return configuration.processing.recaptureGuidance
        case .blockedResult:
            return configuration.processing.recaptureGuidance
        default:
            return nil
        }
    }

    var currentSceneIntelligence: CaptureFeatureSceneIntelligence {
        let guidance = (liveCameraState ?? lastObservedCameraState)?.guidance
        let referenceContext = resolvedReferenceMarkerContext(
            for: .liveRecorded,
            guidanceMetric: guidance?.referenceVisibility
        )
        let wrongSceneFeedback = makeWrongSceneFeedback(
            from: guidance?.sceneFit,
            materialName: configuredMaterialName
        )
        return CaptureFeatureSceneIntelligence(
            materialSuggestion: makeMaterialSuggestion(
                guidance: guidance,
                referenceContext: referenceContext,
                materialName: configuredMaterialName
            ),
            wrongSceneFeedback: wrongSceneFeedback,
            wrongSceneLevel: wrongSceneWarningLevel(for: guidance?.sceneFit)
        )
    }

    var liveCameraState: StockpileCameraCaptureSessionState? {
        guard var state = cameraSession?.state else {
            return nil
        }

        if let mergedSensorSnapshot = mergedDeviceTelemetrySnapshot {
            state.sensorSnapshot = mergedSensorSnapshot
        }

        return state
    }

    var currentActionTitle: String {
        switch phase {
        case .idle:
            if let cameraState = liveCameraState {
                if !cameraState.permission.isGranted {
                    return cameraState.permission.canRequestAccess
                        ? "Allow camera"
                        : "Camera access required"
                }

                if cameraState.operatorStage == .openingCamera {
                    return "Opening camera"
                }

                if cameraState.operatorStage == .failed {
                    return "Retry camera"
                }

                return "Start live recording"
            }

            return phase.primaryActionTitle
        case .guidedCapture:
            if let state = liveCameraState {
                if !state.permission.isGranted {
                    return state.permission.canRequestAccess
                        ? "Allow camera"
                        : "Camera access required"
                }

                switch state.operatorStage {
                case .failed:
                    return "Restart recording"
                case .openingCamera:
                    return "Opening camera"
                case .finalizingRecording:
                    return "Sealing recording"
                case .readyToFinish, .recordingSaved:
                    return prefersRecordedCaptureUpload ? "Finish and seal" : "Finish capture"
                default:
                    break
                }
            }

            if configuration.guidedCapture.isReadyToFinish {
                return prefersRecordedCaptureUpload ? "Finish and seal" : "Finish capture"
            }

            return "Keep recording"
        default:
            return phase.primaryActionTitle
        }
    }

    var currentActionHint: String {
        switch phase {
        case .idle:
            if let cameraState = liveCameraState {
                if !cameraState.permission.isGranted {
                    return cameraState.permission.canRequestAccess
                        ? "Allow rear-camera access to open the live preview."
                        : cameraState.permission.operatorHint
                }

                return cameraState.operatorStageDetail
            }

            return phase.primaryActionHint
        case .guidedCapture:
            if let cameraState = liveCameraState {
                if !cameraState.permission.isGranted {
                    return cameraState.permission.operatorHint
                }

                return cameraState.operatorStageDetail
            }
            if configuration.guidedCapture.isReadyToFinish {
                return prefersRecordedCaptureUpload
                    ? "Finish to seal this recording and begin the automatic handoff."
                    : "Finish this recording when the pass looks complete."
            }
            return cameraSession?.state.activePrompt ?? configuration.guidedCapture.activePrompt
        case .uploadInProgress:
            if isFinalizingRecordedCapture {
                return "Sealing the live recording on device."
            }
            return currentProgressContent.uploadStatusDetail
        case .processing:
            return currentProgressContent.processingStatusDetail
        default:
            return phase.primaryActionHint
        }
    }

    var hasSelectedMovie: Bool {
        selectedMovieFileDescriptor != nil
    }

    /// Whether the markerless `.stockpilecapture` flow is enabled for this run.
    /// SwiftUI views read this to decide whether to render the live volume HUD
    /// (which only makes sense when the v2 markerless path is active).
    var isMarkerlessCaptureEnabled: Bool {
        configuration.pipeline.markerlessCaptureEnabled
    }

    var livePreviewSource: (any CaptureFeatureLivePreviewSessionBridging)? {
        cameraSession as? any CaptureFeatureLivePreviewSessionBridging
    }

    var selectedMovieDisplayName: String? {
        selectedMovieFileDescriptor?.fileName
    }

    var selectedMovieStatusSummary: String {
        if isPreparingSelectedMovie {
            return allowsImportedBackupVideo
                ? "Preparing the internal recovery clip so it is ready if the live recording cannot hand off."
                : "Preparing the live recording handoff."
        }

        if let descriptor = selectedMovieFileDescriptor {
            let fileSize = ByteCountFormatter.string(fromByteCount: descriptor.byteCount, countStyle: .file)
            if let selectedMovieImportErrorMessage {
                return allowsImportedBackupVideo
                    ? "\(descriptor.fileName) stays on standby as the internal recovery clip. \(selectedMovieImportErrorMessage)"
                    : selectedMovieImportErrorMessage
            }
            return allowsImportedBackupVideo
                ? "\(descriptor.fileName) is staged as the internal recovery clip. \(fileSize) is already copied locally if the live recording is unavailable."
                : "Live in-app recording remains the only operator path."
        }

        if let selectedMovieImportErrorMessage {
            return selectedMovieImportErrorMessage
        }

        return allowsImportedBackupVideo
            ? "Live in-app recording remains the primary path. Internal recovery import stays hidden unless we need it."
            : "Live in-app recording is the only operator path."
    }

    private var recordedCaptureProvider: (any CaptureFeatureRecordedCaptureSessionBridging)? {
        cameraSession as? any CaptureFeatureRecordedCaptureSessionBridging
    }

    private var prefersRecordedCaptureUpload: Bool {
        recordedCaptureProvider != nil
    }

    private var allowsImportedBackupVideo: Bool {
        configuration.pipeline.allowsImportedBackupVideo
    }

    private var allowsConfiguredFallbackCaptureFile: Bool {
        configuration.pipeline.allowsConfiguredFallbackCaptureFile
    }

    func performPrimaryAction() {
        CaptureFeatureTrace.log(
            "store.performPrimaryAction",
            state: cameraSession?.state,
            details: "phase=\(phase.rawValue) title=\(currentActionTitle)"
        )
        dependencies.handleAction(phase.primaryAction)

        switch phase {
        case .idle:
            startGuidedCapture()
        case .guidedCapture:
            advanceCapture()
        case .uploadInProgress, .processing:
            break
        case .verifiedResult, .reviewOnlyResult:
            break
        case .blockedResult:
            reset()
        }
    }

    func reset() {
        pipelineTask?.cancel()
        pipelineTask = nil
        markerlessSubmissionTask?.cancel()
        markerlessSubmissionTask = nil
        activeUploadFileURL = nil
        activeUploadSource = nil
        pendingRunRecoveryState = nil
        currentProcessingState = nil
        isFinalizingRecordedCapture = false
        lastObservedCameraState = nil
        latestQuickVolumeEstimate = nil
        markerlessSubmissionState = .idle
        lastMarkerlessSubmissionReceipt = nil
        lastSubmittedMarkerlessArchiveURL = nil
        poseObservationController.reset()
        cameraSession?.reset()
        if let coordinator = markerlessSubmissionCoordinator {
            Task { await coordinator.reset() }
        }
        selectedMovieImportErrorMessage = nil
        configuration = initialConfiguration
        phase = .idle
        pruneOwnedSelectedMovieFiles()
    }

    func handleSelectedMoviePickerResult(_ result: Result<URL, any Error>) async {
        guard allowsImportedBackupVideo else {
            selectedMovieImportErrorMessage = "Backup movie import is disabled in this build. Record the walkaround live in the app."
            return
        }

        switch result {
        case .success(let fileURL):
            await importSelectedMovie(from: fileURL)
        case .failure(let error):
            guard Self.isUserCancelledSelection(error) == false else { return }
            selectedMovieImportErrorMessage = error.localizedDescription
        }
    }

    func importSelectedMovie(from fileURL: URL) async {
        guard allowsImportedBackupVideo else {
            selectedMovieImportErrorMessage = "Backup movie import is disabled in this build. Record the walkaround live in the app."
            return
        }

        isPreparingSelectedMovie = true
        selectedMovieImportErrorMessage = nil
        defer { isPreparingSelectedMovie = false }

        do {
            try await prepareAndStoreSelectedMovie(from: fileURL)
        } catch is CancellationError {
            return
        } catch {
            if let selectedMovieFileDescriptor {
                selectedMovieImportErrorMessage = "A new Files backup could not be imported. Keeping \(selectedMovieFileDescriptor.fileName) ready in case the live walkaround cannot hand off. \(error.localizedDescription)"
            } else {
                selectedMovieImportErrorMessage = error.localizedDescription
            }
        }
    }

    func clearSelectedMovieSelection() {
        selectedMovieStorage = nil
        selectedMovieFileDescriptor = nil
        selectedMovieImportErrorMessage = nil
        pruneOwnedSelectedMovieFiles()
    }

    static func preview(phase: CaptureFeaturePhase = .idle) -> CaptureFeatureStore {
        CaptureFeatureStore(configuration: .preview, phase: phase)
    }

    static func blockedPreview(phase: CaptureFeaturePhase = .idle) -> CaptureFeatureStore {
        CaptureFeatureStore(configuration: .blockedPreview, phase: phase)
    }

    static func livePreview(
        configuration: CaptureFeatureConfiguration = .preview,
        dependencies: CaptureFeatureDependencies = .noop,
        cameraSession: any StockpileCameraCaptureSessionServicing,
        apiService: any StockpileMobileAPIServicing,
        uploadService: any StockpileUploadServicing,
        processingCoordinator: StockpileProcessingRuntimeCoordinator,
        uploadFileDescriptorProvider: @escaping () throws -> StockpileUploadFileDescriptor = CaptureFeatureStore.defaultUploadDescriptor
    ) -> CaptureFeatureStore {
        CaptureFeatureStore(
            configuration: configuration,
            phase: .idle,
            dependencies: dependencies,
            cameraSession: cameraSession,
            apiService: apiService,
            uploadService: uploadService,
            processingCoordinator: processingCoordinator,
            uploadFileDescriptorProvider: uploadFileDescriptorProvider
        )
    }

    static func operational(
        configuration: CaptureFeatureConfiguration,
        dependencies: CaptureFeatureDependencies = .noop,
        cameraSession: any StockpileCameraCaptureSessionServicing,
        apiService: any StockpileMobileAPIServicing,
        uploadService: any StockpileUploadServicing,
        processingCoordinator: StockpileProcessingRuntimeCoordinator,
        markerlessSubmissionCoordinator: StockpileMarkerlessCaptureSubmissionCoordinator? = nil,
        uploadFileDescriptorProvider: @escaping () throws -> StockpileUploadFileDescriptor
    ) -> CaptureFeatureStore {
        CaptureFeatureStore(
            configuration: configuration,
            phase: .idle,
            dependencies: dependencies,
            cameraSession: cameraSession,
            apiService: apiService,
            uploadService: uploadService,
            processingCoordinator: processingCoordinator,
            markerlessSubmissionCoordinator: markerlessSubmissionCoordinator,
            uploadFileDescriptorProvider: uploadFileDescriptorProvider
        )
    }

    /// Test/preview seam to drive the live HUD readout from a known quick
    /// estimate without standing up the ARKit pose runtime. The legacy v1
    /// upload path is unchanged.
    func updateLatestQuickVolumeEstimate(_ estimate: CaptureFeatureLocalQuickEstimate?) {
        latestQuickVolumeEstimate = estimate
        objectWillChange.send()
    }

    #if canImport(StockpileMobileFirstCapture)
    /// Hand off a finalized markerless `.stockpilecapture` bundle to the v2
    /// backend. Called from the ARKit bundle completion callback when the
    /// markerless mode is active. The legacy v1 path is untouched.
    ///
    /// On success the store transitions to `.processing` and stores the
    /// receipt. v2 result polling is intentionally a TODO — submitting the
    /// bundle is the slice that lands first; we surface the receipt so the
    /// next slice can drive `/api/v2/jobs/{jobId}` polling without changing
    /// the store shape again.
    func submitMarkerlessBundle(_ output: StockpileCaptureBundleRecordingOutput) {
        let archiveURL = output.archiveURL
        let captureID = output.captureID
        submitMarkerlessBundle(
            archiveURL: archiveURL,
            captureID: captureID
        )
    }
    #endif

    /// Lower-level entry that takes the archive URL and capture ID directly so
    /// tests can drive the submission flow without instantiating the full
    /// `StockpileCaptureBundleRecordingOutput` (which depends on ARKit-only
    /// document types).
    func submitMarkerlessBundle(
        archiveURL: URL,
        captureID: String
    ) {
        guard let coordinator = markerlessSubmissionCoordinator else {
            // No coordinator means the host hasn't opted into v2 markerless.
            // Surface a clear failed state so the operator sees something
            // instead of a silent drop.
            markerlessSubmissionState = .failed(
                captureID: captureID,
                message: "Markerless submission is not configured for this build."
            )
            return
        }

        // Cancel any in-flight submission for a previous bundle. The coordinator
        // itself rejects concurrent calls, but tearing down the prior task
        // keeps the published state consistent.
        markerlessSubmissionTask?.cancel()
        lastSubmittedMarkerlessArchiveURL = archiveURL
        markerlessSubmissionState = .submitting(captureID: captureID)
        // Mirror v1's UX: while the bundle is uploading, treat the run as
        // "upload in progress" so the existing action bar copy applies.
        if phase == .guidedCapture || phase == .idle {
            phase = .uploadInProgress
        }

        let request = StockpileMarkerlessCaptureSubmissionRequest(
            archiveURL: archiveURL,
            captureID: captureID,
            siteID: configuration.pipeline.siteID,
            materialCode: configuration.pipeline.materialCode
        )

        // The store is @MainActor, so the spawned task inherits main-actor
        // isolation. Mutations to the published state therefore stay on the
        // main thread without an extra `MainActor.run` hop.
        markerlessSubmissionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await coordinator.submit(request)
                guard Task.isCancelled == false else { return }
                self.applyMarkerlessSubmissionSuccess(receipt: receipt)
            } catch is CancellationError {
                // Cancelled while another submission started; nothing to do.
                return
            } catch {
                guard Task.isCancelled == false else { return }
                self.applyMarkerlessSubmissionFailure(
                    captureID: request.captureID,
                    error: error
                )
            }
        }
    }

    /// Retry a previously failed markerless submission. Returns false if there
    /// is nothing to retry (e.g., the submission has not been attempted yet
    /// or it already succeeded).
    @discardableResult
    func retryMarkerlessSubmission() -> Bool {
        guard
            case let .failed(captureID, _) = markerlessSubmissionState,
            let archiveURL = lastSubmittedMarkerlessArchiveURL
        else {
            return false
        }

        submitMarkerlessBundle(archiveURL: archiveURL, captureID: captureID)
        return true
    }

    private func applyMarkerlessSubmissionSuccess(
        receipt: StockpileCaptureBundleSubmissionReceipt
    ) {
        markerlessSubmissionState = .submitted(receipt: receipt)
        lastMarkerlessSubmissionReceipt = receipt
        // Mirror the v1 phase progression: a confirmed receipt means the
        // backend now owns the run. v2 result polling will land in a
        // follow-up slice; surfacing `.processing` keeps the existing UI
        // copy ("Building result") accurate in the meantime.
        phase = .processing
    }

    private func applyMarkerlessSubmissionFailure(
        captureID: String,
        error: any Error
    ) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        markerlessSubmissionState = .failed(
            captureID: captureID,
            message: message
        )
        // Push the visible feature phase to the existing blocked-result
        // surface so operators see a clearly recoverable error and can
        // retry from the standard recapture button.
        configuration.processing = UploadProgressContent(
            transferState: .complete,
            processingState: .blocked,
            statusTone: .warning,
            primaryMessage: "Markerless capture submission failed. \(message)",
            recaptureGuidance: runtimeFailureRecaptureGuidance(message: message)
        )
        phase = .blockedResult
    }

    func resumePendingRunRecovery(_ pendingRun: CaptureFeaturePendingRunRecoveryState) {
        guard let processingCoordinator else {
            return
        }

        pipelineTask?.cancel()
        activeUploadFileURL = pendingRun.file?.fileURL
        activeUploadSource = pendingRun.source
        pendingRunRecoveryState = pendingRun
        currentProcessingState = nil
        isFinalizingRecordedCapture = false
        configuration.uploading = restoredUploadProgressContent(for: pendingRun)
        configuration.processing = restoredProcessingContent(for: pendingRun)
        phase = pendingRun.uploadCompletedAt == nil ? .uploadInProgress : .processing

        pipelineTask = Task { [weak self] in
            guard let self else { return }

            do {
                if pendingRun.uploadCompletedAt == nil {
                    try await self.resumeUploadIfPossible(for: pendingRun)
                }

                try await self.driveProcessing(
                    jobID: pendingRun.jobID,
                    coordinator: processingCoordinator,
                    shouldTolerateTransientFailures: true
                )
            } catch {
                self.handleProcessingFailure(
                    error,
                    for: pendingRun.source,
                    shouldRetainPendingRun: Self.shouldKeepWaitingForProcessing(after: error)
                )
            }
        }
    }

    private func startGuidedCapture() {
        currentProcessingState = nil
        CaptureFeatureTrace.log(
            "store.startGuidedCapture.enter",
            state: cameraSession?.state
        )
        guard let cameraSession else {
            poseObservationController.reset()
            phase = .guidedCapture
            CaptureFeatureTrace.log("store.startGuidedCapture.noCameraSession")
            return
        }

        activeUploadSource = nil
        poseObservationController.reset()
        phase = .guidedCapture
        cameraSession.refreshPermissionState()
        CaptureFeatureTrace.log(
            "store.startGuidedCapture.afterRefreshPermission",
            state: cameraSession.state
        )
        syncGuidedCaptureState(from: cameraSession.state)

        Task { [weak self] in
            guard let self else { return }
            await self.prepareAndStartGuidedCapture(using: cameraSession)
        }
    }

    private func advanceCapture() {
        CaptureFeatureTrace.log(
            "store.advanceCapture.enter",
            state: cameraSession?.state,
            details: "phase=\(phase.rawValue)"
        )
        guard let cameraSession else {
            beginUploadAndProcessing()
            return
        }

        let cameraState = cameraSession.state

        guard cameraState.permission.isGranted else {
            CaptureFeatureTrace.log("store.advanceCapture.permissionNotGranted", state: cameraState)
            startGuidedCapture()
            return
        }

        if cameraState.phase == .failed || cameraState.phase == .idle {
            CaptureFeatureTrace.log("store.advanceCapture.restartFromState", state: cameraState)
            startGuidedCapture()
            return
        }

        if cameraState.canFinish {
            CaptureFeatureTrace.log("store.advanceCapture.finish", state: cameraState)
            cameraSession.finishGuidedCapture()
            syncGuidedCaptureState(from: cameraSession.state)
            beginUploadAndProcessing()
            return
        }

        cameraSession.advanceGuidedCapture()
        syncGuidedCaptureState(from: cameraSession.state)
        phase = .guidedCapture
    }

    private func beginUploadAndProcessing() {
        stopPoseObservation(retainingBufferedSamples: true)
        currentProcessingState = nil

        guard
            let apiService,
            let uploadService,
            let processingCoordinator
        else {
            isFinalizingRecordedCapture = false
            applyFailure(message: "Live upload or processing services are not available in this session.")
            return
        }

        activeUploadSource = plannedUploadSource
        isFinalizingRecordedCapture = activeUploadSource == .liveRecorded
        phase = .uploadInProgress
        configuration.uploading = UploadProgressContent(
            transferState: .preparing,
            processingState: .idle,
            statusTone: .neutral,
            primaryMessage: uploadPreparationMessage(
                for: activeUploadSource,
                cameraState: cameraSession?.state
            )
        )
        configuration.processing = pendingProcessingContent(for: activeUploadSource)

        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            guard let self else { return }

            do {
                let uploadInput = try await self.resolveUploadInput()
                self.activeUploadSource = uploadInput.source
                self.isFinalizingRecordedCapture = false
                try await self.runUploadAndProcessingPipeline(
                    uploadInput: uploadInput,
                    apiService: apiService,
                    uploadService: uploadService,
                    processingCoordinator: processingCoordinator
                )
            } catch {
                self.isFinalizingRecordedCapture = false
                self.activeUploadFileURL = nil
                self.pruneOwnedSelectedMovieFiles()
                self.applyFailure(message: error.localizedDescription)
            }
        }
    }

    private func runUploadAndProcessingPipeline(
        uploadInput: CaptureResolvedUploadInput,
        apiService: any StockpileMobileAPIServicing,
        uploadService: any StockpileUploadServicing,
        processingCoordinator: StockpileProcessingRuntimeCoordinator
    ) async throws {
        let home = configuration.home
        let pipeline = configuration.pipeline
        let fileDescriptor = uploadInput.descriptor
        let taggedReferenceStrategy = makeTaggedReferenceStrategy(
            referenceCountGoal: pipeline.referenceCountGoal
        )
        let captureMetadata = makeCaptureMetadata(
            fileDescriptor: fileDescriptor,
            source: uploadInput.source
        )
        let poseSamples = makePoseSamples(for: uploadInput.source)
        let referenceEvidenceJPEGFrames = await makeReferenceEvidenceJPEGFrames(
            from: fileDescriptor.fileURL,
            captureStartedAt: captureMetadata.startedAt,
            poseSamples: poseSamples
        )
        let localQuickEstimate = poseObservationController.latestQuickEstimate
        let onDeviceVision = poseObservationController.latestOnDeviceVision
        let qualityInput = makeCaptureQualityInput(
            source: uploadInput.source,
            localQuickEstimate: localQuickEstimate,
            onDeviceVision: onDeviceVision
        )
        activeUploadFileURL = fileDescriptor.fileURL

        let captureSession = try await apiService.createCaptureSession(
            request: StockpileCaptureSessionCreateRequest(
                siteID: pipeline.siteID,
                pileName: home.pileName,
                materialCode: pipeline.materialCode,
                densityKgPerM3: pipeline.densityKgPerM3,
                referenceCountGoal: pipeline.referenceCountGoal,
                clientBuild: pipeline.clientBuild,
                taggedReferenceStrategy: taggedReferenceStrategy,
                captureMetadata: captureMetadata,
                qualityInput: qualityInput
            )
        )

        let authorization = try await apiService.createUploadAuthorization(
            request: StockpileUploadRequest(
                sessionID: captureSession.sessionID,
                fileName: fileDescriptor.fileName,
                byteCount: fileDescriptor.byteCount,
                contentType: fileDescriptor.contentType,
                checksumSHA256: fileDescriptor.checksumSHA256,
                taggedReferenceStrategy: taggedReferenceStrategy,
                captureMetadata: captureMetadata,
                qualityInput: qualityInput,
                poseSamples: poseSamples,
                referenceObservations: makeReferenceObservations(for: uploadInput.source),
                referenceEvidenceJPEGFrames: referenceEvidenceJPEGFrames
            )
        )

        pendingRunRecoveryState = CaptureFeaturePendingRunRecoveryState(
            sessionID: captureSession.sessionID,
            uploadID: authorization.uploadID,
            jobID: authorization.jobID,
            runID: authorization.runID,
            pileName: home.pileName,
            source: uploadInput.source,
            createdAt: captureSession.createdAt,
            file: CaptureFeaturePendingUploadFileState(file: fileDescriptor),
            uploadTaskID: nil,
            backgroundSessionIdentifier: pipeline.backgroundSessionIdentifier,
            uploadCompletedAt: nil,
            serverReceiptID: nil,
            serverUploadID: nil,
            localQuickEstimate: localQuickEstimate
        )

        let uploadTask = try await uploadService.createUploadTask(
            request: StockpileUploadTaskRequest(
                uploadID: authorization.uploadID,
                file: fileDescriptor,
                backgroundSessionIdentifier: pipeline.backgroundSessionIdentifier
            )
        )

        updatePendingRunRecoveryState { pendingRun in
            pendingRun.uploadTaskID = uploadTask.taskID
            pendingRun.backgroundSessionIdentifier = uploadTask.backgroundSessionIdentifier
        }

        try await driveUpload(taskID: uploadTask.taskID, uploadService: uploadService)
        activeUploadFileURL = nil
        pruneOwnedSelectedMovieFiles()
        try await driveProcessing(
            jobID: authorization.jobID,
            coordinator: processingCoordinator,
            shouldTolerateTransientFailures: true
        )
    }

    private func driveUpload(taskID: String, uploadService: any StockpileUploadServicing) async throws {
        let stream = uploadService.progressSnapshots(for: taskID)

        if usesSyntheticPreviewUploadProgress,
           let mockUploadService = uploadService as? MockStockpileUploadService {
            Task.detached {
                for _ in 0..<3 {
                    try? await Task.sleep(for: .milliseconds(220))
                    await mockUploadService.emitNextSnapshot(for: taskID)
                }
            }
        }

        for await snapshot in stream {
            if Task.isCancelled {
                break
            }

            applyUploadStage(snapshot.stage)
            applyPendingRunStage(snapshot.stage, taskID: taskID)

            if snapshot.stage.isTerminal {
                if case .failed(let failureState) = snapshot.stage {
                    throw CaptureSelectedMovieImportError.uploadFailed(failureState.reason)
                }
                break
            }
        }
    }

    private func resumeUploadIfPossible(
        for pendingRun: CaptureFeaturePendingRunRecoveryState
    ) async throws {
        guard
            let uploadService,
            let file = pendingRun.file,
            let backgroundSessionIdentifier = pendingRun.backgroundSessionIdentifier
        else {
            throw CaptureSelectedMovieImportError.uploadFailed(
                "The in-flight upload could not be restored after the app relaunched. Record a new live walkaround to restart the handoff."
            )
        }

        let taskID = pendingRun.uploadTaskID ?? pendingRun.uploadID
        let restoredTask = try await uploadService.reattachUploadTask(
            request: StockpileUploadTaskRestoreRequest(
                taskID: taskID,
                file: file.makeDescriptor(),
                backgroundSessionIdentifier: backgroundSessionIdentifier,
                createdAt: pendingRun.createdAt
            )
        )

        if let restoredTask {
            activeUploadFileURL = file.fileURL
            applyUploadStage(restoredTask.stage)
            applyPendingRunStage(restoredTask.stage, taskID: restoredTask.taskID)

            if case .failed(let failureState) = restoredTask.stage {
                throw CaptureSelectedMovieImportError.uploadFailed(failureState.reason)
            }

            if restoredTask.stage.isTerminal == false {
                try await driveUpload(taskID: restoredTask.taskID, uploadService: uploadService)
            }

            return
        }

        guard
            let processingCoordinator,
            let state = try? await processingCoordinator.fetchLatestState(jobID: pendingRun.jobID)
        else {
            throw CaptureSelectedMovieImportError.uploadFailed(
                "The upload was interrupted before the server confirmed receipt, and the app could not reattach the background transfer after relaunch."
            )
        }

        applyProcessingState(state)
        if state.job.phase == .uploadAuthorized || state.job.phase == .queued {
            throw CaptureSelectedMovieImportError.uploadFailed(
                "The background transfer is no longer active and the server has not received the recorded pass yet. Start a fresh live capture to resume."
            )
        }
    }

    private func driveProcessing(
        jobID: String,
        coordinator: StockpileProcessingRuntimeCoordinator,
        shouldTolerateTransientFailures: Bool = false
    ) async throws {
        phase = .processing

        while !Task.isCancelled {
            do {
                let state = try await coordinator.fetchLatestState(jobID: jobID)
                applyProcessingState(state)

                if state.isTerminal {
                    return
                }

                try await coordinator.sleepUntilNextPoll()
            } catch {
                guard shouldTolerateTransientFailures,
                      Self.shouldKeepWaitingForProcessing(after: error) else {
                    throw error
                }

                applyProcessingReconnectState(after: error)
                try await coordinator.sleepUntilNextPoll()
            }
        }
    }

    private func syncGuidedCaptureState(from state: StockpileCameraCaptureSessionState) {
        lastObservedCameraState = state
        let referenceContext = resolvedReferenceMarkerContext(
            for: .liveRecorded,
            guidanceMetric: state.guidance.referenceVisibility
        )
        configuration.guidedCapture = GuidedCaptureContent(
            pileName: configuration.home.pileName,
            sessionLabel: state.statusLabel,
            referencesVisible: referenceContext.maxVisibleTogether > 0
                ? referenceContext.maxVisibleTogether
                : visibleReferenceCount(from: state.guidance.referenceVisibility),
            referenceTarget: max(configuration.pipeline.referenceCountGoal, 1),
            perimeterCoverage: state.guidance.coverage.score,
            stabilityScore: state.guidance.motion.score,
            activePrompt: state.activePrompt,
            captureChecks: [
                state.guidance.sceneFit.map(makeGuidedCaptureCheck),
                makeGuidedCaptureCheck(from: state.guidance.referenceVisibility),
                makeGuidedCaptureCheck(from: state.guidance.coverage),
                makeGuidedCaptureCheck(from: state.guidance.motion),
            ]
            .compactMap { $0 }
        )
    }

    private func makeGuidedCaptureCheck(from metric: StockpileCaptureGuidanceMetric) -> GuidedCaptureCheck {
        GuidedCaptureCheck(
            title: metric.title,
            status: checkStatus(from: metric.level),
            detail: metric.detail,
            operatorAction: metric.detail
        )
    }

    private func checkStatus(from level: StockpileCaptureGuidanceLevel) -> GuidedCaptureCheckStatus {
        switch level {
        case .good:
            return .ready
        case .watch:
            return .needsAttention
        case .blocked:
            return .blocked
        }
    }

    private func visibleReferenceCount(from metric: StockpileCaptureGuidanceMetric) -> Int {
        if let observedCount = metric.observedCount {
            return observedCount
        }

        switch metric.level {
        case .good:
            return 3
        case .watch:
            return 2
        case .blocked:
            return 1
        }
    }

    @MainActor
    private func applyUploadStage(_ stage: StockpileUploadTaskStage) {
        configuration.uploading = UploadProgressContent(
            transferState: transferState(from: stage),
            processingState: .idle,
            statusTone: stage.isTerminal ? .success : .neutral,
            primaryMessage: uploadStageMessage(for: stage),
            recaptureGuidance: stage.isTerminal ? nil : configuration.uploading.recaptureGuidance
        )

        phase = stage.isTerminal ? .processing : .uploadInProgress
    }

    @MainActor
    private func applyProcessingState(_ state: StockpileProcessingRuntimeState) {
        currentProcessingState = state
        updatePendingRunRecoveryState { pendingRun in
            pendingRun.runID = state.job.runID
            if pendingRun.uploadCompletedAt == nil,
               state.job.phase != .uploadAuthorized {
                pendingRun.uploadCompletedAt = Date()
            }
        }

        if let result = state.result {
            let resultModel = resultScreenModel(from: result)

            switch result.outcome {
            case .verified:
                configuration.verifiedResult = resultModel
                activeUploadSource = nil
                pendingRunRecoveryState = nil
                phase = .verifiedResult
            case .reviewOnly:
                configuration.reviewOnlyResult = resultModel
                activeUploadSource = nil
                pendingRunRecoveryState = nil
                phase = .reviewOnlyResult
            case .blocked:
                configuration.blockedResult = resultModel
                configuration.processing = UploadProgressContent(
                    transferState: .complete,
                    processingState: .blocked,
                    statusTone: .warning,
                    primaryMessage: result.recommendedAction,
                    recaptureGuidance: recaptureGuidance(from: result)
                )
                activeUploadSource = nil
                pendingRunRecoveryState = nil
                phase = .blockedResult
            }
            return
        }

        configuration.processing = UploadProgressContent(
            transferState: .complete,
            processingState: processingStage(from: state.job.phase),
            statusTone: .neutral,
            primaryMessage: processingStageMessage(detail: state.job.detail),
            recaptureGuidance: nil
        )
        phase = .processing
    }

    @MainActor
    private func applyProcessingReconnectState(after error: Error) {
        let sourceLabel = activeUploadSource.map(sourceOperatorLabel(for:)) ?? "The recorded walkaround"
        configuration.processing = UploadProgressContent(
            transferState: configuration.processing.transferState,
            processingState: configuration.processing.processingState == .idle ? .queued : configuration.processing.processingState,
            statusTone: .neutral,
            primaryMessage: "\(sourceLabel) is still waiting on backend updates. Reconnecting after a temporary interruption. \(error.localizedDescription)"
        )
        phase = .processing
    }

    @MainActor
    private func applyFailure(message: String) {
        let operatorMessage: String
        if let activeUploadSource {
            operatorMessage = "\(sourceOperatorLabel(for: activeUploadSource)) could not finish the handoff. \(message)"
        } else {
            operatorMessage = message
        }

        configuration.processing = UploadProgressContent(
            transferState: .complete,
            processingState: .blocked,
            statusTone: .warning,
            primaryMessage: operatorMessage,
            recaptureGuidance: runtimeFailureRecaptureGuidance(message: operatorMessage)
        )
        configuration.blockedResult = nil
        activeUploadSource = nil
        pendingRunRecoveryState = nil
        currentProcessingState = nil
        phase = .blockedResult
    }

    @MainActor
    private func handleProcessingFailure(
        _ error: Error,
        for source: CaptureUploadSource,
        shouldRetainPendingRun: Bool
    ) {
        if shouldRetainPendingRun {
            activeUploadSource = source
            applyProcessingReconnectState(after: error)
            return
        }

        applyFailure(message: error.localizedDescription)
    }

    private func transferState(from stage: StockpileUploadTaskStage) -> UploadTransferState {
        switch stage {
        case .preparingLocalFile:
            return .preparing
        case .transferringBytes(let transfer):
            return .uploading(progress: transfer.progress)
        case .queuedForRetry:
            return .queuedForRetry
        case .handingOffToServer:
            return .retrying
        case .completed:
            return .complete
        case .failed:
            return .queuedForRetry
        }
    }

    private nonisolated static func shouldKeepWaitingForProcessing(after error: Error) -> Bool {
        guard let mobileAPIError = error as? StockpileMobileAPIError else {
            return false
        }

        switch mobileAPIError {
        case .jobNotFound,
             .resultNotFound,
             .invalidResponse,
             .transportFailure,
             .serverError:
            return true
        case .rateLimited:
            return true
        case let .requestFailed(statusCode, _):
            return statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode)
        case .sessionNotFound,
             .invalidRequestURL,
             .authenticationRequired,
             .forbidden,
             .validationFailed,
             .decodingFailure,
             .encodingFailure:
            return false
        }
    }

    private func processingStage(from phase: StockpileJobPhase) -> ProcessingStageState {
        switch phase {
        case .queued, .uploadAuthorized, .uploadReceived:
            return .queued
        case .extractingFrames:
            return .preparingFrames
        case .detectingReferences:
            return .detectingReferences
        case .reconstructing:
            return .reconstructing
        case .calibrating:
            return .calibrating
        case .computingVolume:
            return .computingVolume
        case .reviewOnly:
            return .reviewReady
        case .blocked, .failed:
            return .blocked
        case .verified:
            return .reviewReady
        }
    }

    private func resultScreenModel(from result: StockpileProcessingRuntimeResultState) -> StockpileResultScreenModel {
        StockpileResultModelFactory.makeResultScreenModel(from: result)
    }

    private func currentProvisionalResultModel() -> StockpileResultScreenModel? {
        if let currentProcessingState,
           let backendModel = provisionalResultModel(from: currentProcessingState) {
            return backendModel
        }

        return localProvisionalResultModel()
    }

    private func provisionalResultModel(
        from state: StockpileProcessingRuntimeState
    ) -> StockpileResultScreenModel? {
        if let result = state.result {
            return resultScreenModel(from: result)
        }

        guard let provisionalMeasurement = state.job.provisionalMeasurement else {
            return nil
        }

        return makeProcessingResultModel(
            runID: state.job.runID,
            pileName: pendingRunRecoveryState?.pileName ?? configuration.home.pileName,
            confidence: provisionalConfidenceSummary(
                from: provisionalMeasurement,
                fallbackDetail: processingStageMessage(detail: state.job.detail),
                localQuickEstimate: pendingRunRecoveryState?.localQuickEstimate
            ),
            measurement: measurement(from: provisionalMeasurement),
            recommendedAction: "Wait for the backend to finish processing before treating this run as final.",
            updatedAt: provisionalMeasurement.updatedAt ?? state.job.updatedAt
        )
    }

    private func localProvisionalResultModel() -> StockpileResultScreenModel {
        let runID = pendingRunRecoveryState?.runID ?? pendingRunRecoveryState?.jobID ?? "processing-live-run"
        let pileName = pendingRunRecoveryState?.pileName ?? configuration.home.pileName
        let detail = currentProcessingState.map { processingStageMessage(detail: $0.job.detail) }
            .flatMap { $0.stockpileNonEmptyTrimmed }
            ?? configuration.processing.primaryMessage
        let localQuickEstimate = pendingRunRecoveryState?.localQuickEstimate
        let measurement = localQuickEstimate?.measurement(
            densityKgPerM3: configuration.pipeline.densityKgPerM3
        )

        let confidence: StockpileConfidenceSummary
        let recommendedAction: String
        if let localQuickEstimate {
            let summary = "\(localQuickEstimate.segmentationSummary) Backend verification continues."
            confidence = StockpileConfidenceSummary(
                score: localQuickEstimate.confidencePercentage,
                label: "On-device",
                summary: summary
            )
            recommendedAction = "Treat this as a provisional phone estimate until the backend finishes verification."
        } else {
            confidence = StockpileConfidenceSummary(
                score: 0,
                label: "In progress",
                summary: detail
            )
            recommendedAction = "Wait for the backend to finish processing before treating this run as final."
        }

        return makeProcessingResultModel(
            runID: runID,
            pileName: pileName,
            confidence: confidence,
            measurement: measurement,
            recommendedAction: recommendedAction,
            updatedAt: currentProcessingState?.job.updatedAt
        )
    }

    private func makeProcessingResultModel(
        runID: String,
        pileName: String,
        confidence: StockpileConfidenceSummary,
        measurement: StockpileMeasurement?,
        recommendedAction: String,
        updatedAt: Date?
    ) -> StockpileResultScreenModel {
        StockpileResultScreenModel(
            runID: runID,
            pileName: pileName,
            outcome: .reviewOnly,
            runtimeState: .processing,
            confidence: confidence,
            measurement: measurement,
            warnings: [],
            blockers: [],
            recommendedAction: recommendedAction,
            confidenceLenses: [],
            reportURL: nil,
            updatedAt: updatedAt,
            reconstruction: nil
        )
    }

    private func provisionalConfidenceSummary(
        from provisionalMeasurement: StockpileProvisionalMeasurementPayload,
        fallbackDetail: String,
        localQuickEstimate: CaptureFeatureLocalQuickEstimate?
    ) -> StockpileConfidenceSummary {
        let resolvedQuickEstimate = CaptureFeatureLocalQuickEstimate(provisionalMeasurement) ?? localQuickEstimate
        let statusLabel = provisionalMeasurement.status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
        let summary = [
            provisionalMeasurement.reason?.stockpileNonEmptyTrimmed,
            provisionalMeasurement.basis?.stockpileNonEmptyTrimmed,
            resolvedQuickEstimate?.segmentationSummary,
            fallbackDetail.stockpileNonEmptyTrimmed
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        return StockpileConfidenceSummary(
            score: min(max(provisionalMeasurement.confidenceScore ?? 0, 0), 100),
            label: statusLabel.isEmpty ? "Provisional" : statusLabel.capitalized,
            summary: summary.isEmpty ? fallbackDetail : summary
        )
    }

    private func measurement(
        from provisionalMeasurement: StockpileProvisionalMeasurementPayload
    ) -> StockpileMeasurement? {
        guard
            let volumeM3 = provisionalMeasurement.volumeM3,
            let weightTonnes = provisionalMeasurement.weightTonnes,
            volumeM3 > 0
        else {
            return nil
        }

        let derivedDensity = Int(((weightTonnes * 1_000) / volumeM3).rounded())
        return StockpileMeasurement(
            volumeM3: volumeM3,
            weightTonnes: weightTonnes,
            densityKgPerM3: max(derivedDensity, 0)
        )
    }

    private func recaptureGuidance(from result: StockpileProcessingRuntimeResultState) -> RecaptureGuidanceContent {
        let reasons = result.blockers.isEmpty ? result.warnings : result.blockers
        let steps = [
            RecaptureGuidanceStep(title: "Start wider", detail: "Begin with the full toe boundary and all tagged references visible."),
            RecaptureGuidanceStep(title: "Hold 2-3 references together", detail: "Keep at least two tagged references in frame when changing angle."),
            RecaptureGuidanceStep(title: "Move slower", detail: "Reduce camera swing and keep the perimeter path steady.")
        ]

        return RecaptureGuidanceContent(
            title: "Recapture guidance",
            summary: result.recommendedAction,
            reasons: reasons.isEmpty ? [result.recommendedAction] : reasons,
            steps: steps,
            primaryActionTitle: "Retake capture"
        )
    }

    private func runtimeFailureRecaptureGuidance(message: String) -> RecaptureGuidanceContent {
        var steps = [
            RecaptureGuidanceStep(
                title: "Check the connection",
                detail: "Confirm the device still has network access before starting a new pass."
            ),
            RecaptureGuidanceStep(
                title: "Restart the live walkaround",
                detail: "Record one steady rear-camera lap so the app can seal and upload a fresh run."
            ),
        ]

        if allowsImportedBackupVideo || allowsConfiguredFallbackCaptureFile {
            steps.append(
                RecaptureGuidanceStep(
                    title: "Use recovery input only if needed",
                    detail: "If the live recording cannot be recovered, hand off an internal recovery clip and retry the upload."
                )
            )
        }

        return RecaptureGuidanceContent(
            title: "Capture recovery",
            summary: "The live run stopped before the app received a backend result.",
            reasons: [message],
            steps: steps,
            primaryActionTitle: "Retake capture"
        )
    }

    private nonisolated static func defaultUploadDescriptor() throws -> StockpileUploadFileDescriptor {
        throw CaptureSelectedMovieImportError.missingSelectedMovie(
            "No real recorded walkaround or imported backup clip is available yet."
        )
    }

    private func resolveUploadInput() async throws -> CaptureResolvedUploadInput {
        if let recordedCaptureProvider {
            if let finalizedRecordedVideoDescriptor = recordedCaptureProvider.finalizedRecordedVideoDescriptor {
                return CaptureResolvedUploadInput(
                    descriptor: finalizedRecordedVideoDescriptor,
                    source: .liveRecorded
                )
            }

            do {
                return CaptureResolvedUploadInput(
                    descriptor: try await recordedCaptureProvider.finalizeRecordedVideoIfNeeded(),
                    source: .liveRecorded
                )
            } catch {
                throw CaptureSelectedMovieImportError.failedToFinalizeRecordedCapture(error.localizedDescription)
            }
        }

        if allowsImportedBackupVideo, let selectedMovieFileDescriptor {
            return CaptureResolvedUploadInput(
                descriptor: selectedMovieFileDescriptor,
                source: .importedVideo
            )
        }

        if allowsConfiguredFallbackCaptureFile {
            do {
                return CaptureResolvedUploadInput(
                    descriptor: try uploadFileDescriptorProvider(),
                    source: .fallbackVideo
                )
            } catch {
                throw CaptureSelectedMovieImportError.missingSelectedMovie(error.localizedDescription)
            }
        }

        throw CaptureSelectedMovieImportError.missingRecordedCapture(
            "Finish a live in-app walkaround before the upload can start."
        )
    }

    private var plannedUploadSource: CaptureUploadSource {
        if prefersRecordedCaptureUpload {
            return .liveRecorded
        }

        if allowsImportedBackupVideo, selectedMovieFileDescriptor != nil {
            return .importedVideo
        }

        return allowsConfiguredFallbackCaptureFile ? .fallbackVideo : .liveRecorded
    }

    private func makeTaggedReferenceStrategy(
        referenceCountGoal: Int
    ) -> StockpileTaggedReferenceStrategyPayload {
        let clampedGoal = max(referenceCountGoal, 0)
        let minimumVisibleReferenceCount = min(clampedGoal, 2)
        let preferredVisibleReferenceCount = min(max(clampedGoal, minimumVisibleReferenceCount), 3)

        return StockpileTaggedReferenceStrategyPayload(
            mode: .concurrentVisibility,
            referenceCountGoal: clampedGoal,
            minimumVisibleReferenceCount: minimumVisibleReferenceCount,
            preferredVisibleReferenceCount: preferredVisibleReferenceCount
        )
    }

    private func makeCaptureMetadata(
        fileDescriptor: StockpileUploadFileDescriptor,
        source: CaptureUploadSource
    ) -> StockpileCaptureMetadataPayload {
        let resolvedLiveCameraState = source == .liveRecorded ? liveCameraState : nil
        let liveTelemetry = source == .liveRecorded ? mergedDeviceTelemetrySnapshot : nil
        let recordingOutput = resolvedLiveCameraState?.recordingOutput
        let fileDates = Self.captureFileDates(for: fileDescriptor.fileURL)

        return StockpileCaptureMetadataPayload(
            source: source.apiSource,
            mode: .guidedWalkaround,
            startedAt: recordingOutput?.startedAt ?? fileDates.startedAt,
            completedAt: recordingOutput?.finishedAt ?? fileDates.completedAt,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            activeDeviceName: resolvedLiveCameraState?.activeDeviceName,
            capturePhase: resolvedLiveCameraState?.phase.rawValue,
            sessionLifecycle: resolvedLiveCameraState?.sessionLifecycle.rawValue,
            recordingLifecycle: resolvedLiveCameraState?.recordingLifecycle.rawValue,
            sensorMetadata: liveTelemetry?.sensorMetadata.map { telemetry in
                StockpileCaptureSensorMetadataPayload(
                    deviceModelIdentifier: telemetry.deviceModelIdentifier,
                    videoWidth: telemetry.videoWidth,
                    videoHeight: telemetry.videoHeight,
                    videoFrameRate: telemetry.videoFrameRate,
                    poseSamplingHz: telemetry.poseSamplingHz,
                    depthDataIncluded: telemetry.depthDataIncluded,
                    worldAlignment: telemetry.worldAlignment,
                    videoStabilizationMode: telemetry.videoStabilizationMode
                )
            }
        )
    }

    private func makeCaptureQualityInput(
        source: CaptureUploadSource,
        localQuickEstimate: CaptureFeatureLocalQuickEstimate? = nil,
        onDeviceVision: CaptureFeatureOnDeviceVisionSummary? = nil
    ) -> StockpileCaptureQualityInputPayload {
        guard source == .liveRecorded, let cameraState = liveCameraState else {
            return StockpileCaptureQualityInputPayload(
                toeCoverageScore: nil,
                estimatedConcurrentReferenceCount: nil,
                deviceSensors: StockpileDeviceSensorInputPayload(
                    motionSignalsIncluded: false,
                    gravityVectorIncluded: false,
                    headingSignalsIncluded: false,
                    cameraCalibrationIncluded: false
                ),
                mobileFirstCapture: nil
            )
        }

        let guidance = cameraState.guidance
        let liveTelemetry = mergedDeviceTelemetrySnapshot
        let referenceContext = resolvedReferenceMarkerContext(
            for: source,
            guidanceMetric: guidance.referenceVisibility
        )
        let estimatedVisibleReferenceCount = referenceContext.maxVisibleTogether > 0
            ? referenceContext.maxVisibleTogether
            : visibleReferenceCount(from: guidance.referenceVisibility)
        let resolvedLocalQuickEstimate = localQuickEstimate ?? poseObservationController.latestQuickEstimate
        let resolvedOnDeviceVision = onDeviceVision ?? poseObservationController.latestOnDeviceVision

        return StockpileCaptureQualityInputPayload(
            referenceVisibilityScore: guidance.referenceVisibility.score,
            coverageScore: guidance.coverage.score,
            motionStabilityScore: guidance.motion.score,
            overallGuidanceScore: guidance.overallScore,
            toeCoverageScore: guidance.coverage.score,
            estimatedConcurrentReferenceCount: estimatedVisibleReferenceCount,
            deviceSensors: StockpileDeviceSensorInputPayload(
                motionSignalsIncluded: liveTelemetry?.motionSignalsIncluded ?? true,
                gravityVectorIncluded: liveTelemetry?.gravityVectorIncluded ?? true,
                headingSignalsIncluded: liveTelemetry?.headingSignalsIncluded ?? false,
                cameraCalibrationIncluded: liveTelemetry?.cameraCalibrationIncluded ?? true
            ),
            mobileFirstCapture: makeMobileFirstCapturePayload(
                cameraState: cameraState,
                liveTelemetry: liveTelemetry,
                guidance: guidance,
                estimatedVisibleReferenceCount: estimatedVisibleReferenceCount,
                localQuickEstimate: resolvedLocalQuickEstimate,
                onDeviceVision: resolvedOnDeviceVision
            )
        )
    }

    private func makeMobileFirstCapturePayload(
        cameraState: StockpileCameraCaptureSessionState?,
        liveTelemetry: StockpileCaptureSensorSnapshot?,
        guidance: StockpileCaptureGuidanceSummary,
        estimatedVisibleReferenceCount: Int?,
        localQuickEstimate: CaptureFeatureLocalQuickEstimate?,
        onDeviceVision: CaptureFeatureOnDeviceVisionSummary?
    ) -> StockpileMobileFirstCapturePayload {
        let payloadEstimate = localQuickEstimate?.mobilePayload()
        let visionPayload = makeOnDeviceVisionPayload(from: onDeviceVision)
        let pileSegmentationScore = guidance.pileSegmentation?.score ?? onDeviceVision?.pileSegmentationScore
        let toeSegmentationScore = guidance.toeSegmentation?.score ?? onDeviceVision?.toeSegmentationScore
        let segmentationConfidence = segmentationConfidenceScore(
            from: guidance,
            onDeviceVision: onDeviceVision
        )
        return StockpileMobileFirstCapturePayload(
            stage: mobileFirstCaptureStage(for: phase),
            referenceMarkerSnapshots: makeReferenceMarkerSnapshots(),
            nativeReferenceObservations: makeNativeReferenceObservations(
                cameraState: cameraState,
                estimatedVisibleReferenceCount: estimatedVisibleReferenceCount
            ),
            materialSuggestion: makeMaterialSuggestionPayload(from: cameraState),
            onDeviceVision: visionPayload,
            devicePoseTelemetry: StockpileDevicePoseTelemetryPayload(
                sampleCount: liveTelemetry?.sampleCount,
                motionStable: liveTelemetry?.motionStable ?? (guidance.motion.level == .good),
                headingStable: liveTelemetry?.headingStable,
                lidarAssistAvailable: liveTelemetry?.lidarAssistAvailable ?? configuration.pipeline.lidarAssistEnabled,
                trackingState: liveTelemetry?.trackingState ?? cameraState?.sessionLifecycle.rawValue
            ),
            toeCoverageScore: guidance.coverage.score,
            pileSegmentationScore: pileSegmentationScore,
            toeSegmentationScore: toeSegmentationScore,
            segmentationConfidenceScore: segmentationConfidence,
            estimatedConcurrentReferenceCount: estimatedVisibleReferenceCount,
            quickVolumeM3: payloadEstimate?.quickVolumeM3,
            quickFootprintAreaM2: payloadEstimate?.quickFootprintAreaM2,
            quickPeakHeightM: payloadEstimate?.quickPeakHeightM,
            quickConfidenceScore: adjustedQuickConfidenceScore(
                base: payloadEstimate?.quickConfidenceScore,
                segmentationConfidence: segmentationConfidence
            ),
            quickGeometryPointCount: payloadEstimate?.quickGeometryPointCount,
            quickCameraPathDistanceM: payloadEstimate?.quickCameraPathDistanceM
        )
    }

    private func makeOnDeviceVisionPayload(
        from summary: CaptureFeatureOnDeviceVisionSummary?
    ) -> StockpileOnDeviceVisionPayload? {
        guard let summary else {
            return nil
        }

        return StockpileOnDeviceVisionPayload(
            source: summary.source,
            usesMachineLearning: summary.usesMachineLearning,
            pileSegmentationScore: summary.pileSegmentationScore,
            toeSegmentationScore: summary.toeSegmentationScore,
            segmentationConfidenceScore: summary.segmentationConfidenceScore,
            foregroundCoverageRatio: summary.foregroundCoverageRatio,
            lowerFrameOccupancyRatio: summary.lowerFrameOccupancyRatio,
            materialFamilyCode: summary.materialFamilyCode,
            materialFamilyLabel: summary.materialFamilyLabel,
            materialConfidenceScore: summary.materialConfidenceScore,
            guidanceHint: summary.guidanceHint
        )
    }

    private func segmentationConfidenceScore(
        from guidance: StockpileCaptureGuidanceSummary,
        onDeviceVision: CaptureFeatureOnDeviceVisionSummary? = nil
    ) -> Double? {
        let scores = [
            guidance.pileSegmentation?.score,
            guidance.toeSegmentation?.score,
        ].compactMap { $0 }

        if scores.isEmpty == false {
            return scores.reduce(0, +) / Double(scores.count)
        }

        return onDeviceVision?.segmentationConfidenceScore
    }

    private func adjustedQuickConfidenceScore(
        base: Double?,
        segmentationConfidence: Double?
    ) -> Double? {
        guard let base else {
            return segmentationConfidence.map { min(max($0 * 0.75, 0), 1) }
        }

        guard let segmentationConfidence else {
            return base
        }

        let blended = (base * 0.75) + (segmentationConfidence * 0.25)
        let weakSegmentationPenalty = max(0.5 - segmentationConfidence, 0) * 0.3
        return min(max(blended - weakSegmentationPenalty, 0), 1)
    }

    private func makeReferenceMarkerSnapshots() -> [StockpileReferenceMarkerSnapshotPayload] {
        resolvedReferenceMarkerContext(for: .liveRecorded).snapshots
    }

    private func makeNativeReferenceObservations(
        cameraState: StockpileCameraCaptureSessionState?,
        estimatedVisibleReferenceCount: Int?
    ) -> [StockpileReferenceObservationPayload] {
        let observedMarkers = cameraState?.observedReferenceMarkers ?? []
        guard observedMarkers.isEmpty == false else {
            return []
        }

        let visibleCount = max(
            estimatedVisibleReferenceCount ?? observedMarkers.map(\.visibleCount).max() ?? 0,
            1
        )

        return observedMarkers.compactMap { marker in
            let normalizedID = marker.markerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedID.isEmpty == false else {
                return nil
            }

            return StockpileReferenceObservationPayload(
                referenceID: normalizedID,
                family: marker.family,
                confidence: marker.confidence,
                state: nativeReferenceQuality(
                    for: marker,
                    visibleCount: max(marker.visibleCount, visibleCount)
                )
            )
        }
    }

    private func nativeReferenceQuality(
        for marker: StockpileCaptureObservedReferenceMarker,
        visibleCount: Int
    ) -> StockpileReferenceMarkerQualityPayload {
        if marker.confidence >= 0.8 && visibleCount >= 2 {
            return .confirmed
        }

        if marker.confidence > 0 {
            return .weak
        }

        return .missing
    }

    private func makeMaterialSuggestionPayload(
        from cameraState: StockpileCameraCaptureSessionState?
    ) -> StockpileMaterialSuggestionPayload? {
        guard let suggestion = cameraState?.materialSuggestion else {
            return nil
        }

        return StockpileMaterialSuggestionPayload(
            materialCode: suggestion.materialCode,
            label: suggestion.materialName,
            confidence: suggestion.confidence,
            source: "ios_vision"
        )
    }

    private func makePoseSamples(
        for source: CaptureUploadSource
    ) -> [StockpileDevicePoseSamplePayload] {
        guard source == .liveRecorded else {
            return []
        }

        return poseObservationController.bufferedSamples.map { sample in
            StockpileDevicePoseSamplePayload(
                sampleIndex: sample.sequenceNumber,
                timeOffsetSec: sample.timeOffsetSec,
                capturedAt: sample.capturedAt,
                positionM: makeVector3Payload(sample.positionM),
                trackingState: sample.trackingState,
                yawPitchRollDeg: makeVector3Payload(sample.yawPitchRollDeg)
            )
        }
    }

    private func makeReferenceEvidenceJPEGFrames(
        from movieFileURL: URL,
        captureStartedAt: Date?,
        poseSamples: [StockpileDevicePoseSamplePayload]
    ) async -> [StockpileReferenceEvidenceJPEGFramePayload] {
        // Evidence extraction is best-effort so imported and fallback videos keep the
        // existing upload path even when the extractor cannot produce frames.
        do {
            let extractedFrames = try await CaptureReferenceEvidenceExtractor()
                .extractEvidence(from: movieFileURL)
            let limitedFrames = Array(extractedFrames.prefix(3))

            guard limitedFrames.isEmpty == false else {
                return []
            }

            return limitedFrames.map { frame in
                alignReferenceEvidenceJPEGFrame(
                    frame,
                    captureStartedAt: captureStartedAt,
                    poseSamples: poseSamples
                )
            }
        } catch {
            return []
        }
    }

    private func alignReferenceEvidenceJPEGFrame(
        _ frame: CaptureReferenceEvidence,
        captureStartedAt: Date?,
        poseSamples: [StockpileDevicePoseSamplePayload]
    ) -> StockpileReferenceEvidenceJPEGFramePayload {
        let poseSampleIndex = nearestPoseSampleIndex(
            for: frame.actualTimeSeconds,
            poseSamples: poseSamples
        )

        return StockpileReferenceEvidenceJPEGFramePayload(
            frameID: String(format: "frame_%04d", frame.frameIndex),
            timeOffsetSec: frame.actualTimeSeconds,
            poseSampleIndex: poseSampleIndex,
            capturedAt: captureStartedAt?.addingTimeInterval(frame.actualTimeSeconds),
            widthPx: frame.pixelWidth,
            heightPx: frame.pixelHeight,
            jpegBase64: frame.jpegBase64
        )
    }

    private func nearestPoseSampleIndex(
        for evidenceTimeOffsetSec: TimeInterval,
        poseSamples: [StockpileDevicePoseSamplePayload]
    ) -> Int? {
        guard poseSamples.isEmpty == false else {
            return nil
        }

        return poseSamples.min { lhs, rhs in
            abs(lhs.timeOffsetSec - evidenceTimeOffsetSec) < abs(rhs.timeOffsetSec - evidenceTimeOffsetSec)
        }?.sampleIndex
    }

    private func makeReferenceObservations(
        for source: CaptureUploadSource
    ) -> [StockpileReferenceObservationPayload] {
        guard source == .liveRecorded else {
            return []
        }

        let referenceContext = resolvedReferenceMarkerContext(for: source)
        return referenceContext.snapshots.map { snapshot in
            StockpileReferenceObservationPayload(
                referenceID: snapshot.markerID,
                family: "tagged_reference",
                confidence: snapshot.confidence,
                state: snapshot.quality
            )
        }
    }

    private func resolvedReferenceMarkerContext(
        for source: CaptureUploadSource,
        guidanceMetric: StockpileCaptureGuidanceMetric? = nil
    ) -> CaptureFeatureReferenceMarkerContext {
        guard source == .liveRecorded else {
            return .empty
        }

        let observedMarkers = normalizedObservedReferenceMarkers()
        if observedMarkers.isEmpty == false {
            let observedSnapshots = StockpileReferenceMarkerSnapshotBuilder.makeSnapshots(from: observedMarkers)
            if observedSnapshots.isEmpty == false {
                return CaptureFeatureReferenceMarkerContext(
                    source: .observed,
                    snapshots: observedSnapshots
                )
            }
        }

        guard let referenceVisibility = guidanceMetric ?? currentReferenceVisibilityMetric else {
            return .empty
        }

        let estimatedMarkers = estimatedReferenceMarkers(from: referenceVisibility)
        guard estimatedMarkers.isEmpty == false else {
            return .empty
        }

        return CaptureFeatureReferenceMarkerContext(
            source: .estimated,
            snapshots: StockpileReferenceMarkerSnapshotBuilder.makeSnapshots(from: estimatedMarkers)
        )
    }

    private func normalizedObservedReferenceMarkers() -> [StockpileObservedReferenceMarker] {
        let observedMarkers = liveCameraState?.observedReferenceMarkers
            ?? lastObservedCameraState?.observedReferenceMarkers
            ?? []

        return observedMarkers.compactMap { observation -> StockpileObservedReferenceMarker? in
            let normalizedID = observation.markerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedID.isEmpty == false else {
                return nil
            }

            return StockpileObservedReferenceMarker(
                markerID: normalizedID,
                visibleCount: observation.visibleCount,
                confidence: observation.confidence,
                qualityHint: observedReferenceQualityHint(for: observation)
            )
        }
    }

    private func observedReferenceQualityHint(
        for observation: StockpileCaptureObservedReferenceMarker
    ) -> StockpileReferenceMarkerQualityPayload {
        if observation.confidence >= 0.8 && observation.visibleCount >= 2 {
            return .confirmed
        }

        if observation.confidence > 0 {
            return .weak
        }

        return .missing
    }

    private func estimatedReferenceMarkers(
        from metric: StockpileCaptureGuidanceMetric
    ) -> [StockpileObservedReferenceMarker] {
        let estimatedVisibleCount = estimatedReferenceCount(from: metric)
        guard estimatedVisibleCount > 0 else {
            return []
        }

        let referenceQuality = estimatedReferenceQuality(
            from: metric,
            estimatedVisibleCount: estimatedVisibleCount
        )
        let confidence = min(max(metric.score, 0.2), 0.94)

        return (1...estimatedVisibleCount).map { index in
            StockpileObservedReferenceMarker(
                markerID: String(format: "guidance-ref-%02d", index),
                visibleCount: estimatedVisibleCount,
                confidence: confidence,
                qualityHint: referenceQuality
            )
        }
    }

    private func estimatedReferenceCount(from metric: StockpileCaptureGuidanceMetric) -> Int {
        if let observedCount = metric.observedCount {
            return min(max(observedCount, 0), max(configuration.pipeline.referenceCountGoal, 1))
        }

        switch metric.level {
        case .good:
            return min(max(configuration.pipeline.referenceCountGoal, 2), 3)
        case .watch:
            return min(max(configuration.pipeline.referenceCountGoal, 2), 2)
        case .blocked:
            return 0
        }
    }

    private func estimatedReferenceQuality(
        from metric: StockpileCaptureGuidanceMetric,
        estimatedVisibleCount: Int
    ) -> StockpileReferenceMarkerQualityPayload {
        guard estimatedVisibleCount > 0 else {
            return .missing
        }

        switch metric.level {
        case .good where estimatedVisibleCount >= 2:
            return .confirmed
        case .good, .watch, .blocked:
            return .weak
        }
    }

    private var currentReferenceVisibilityMetric: StockpileCaptureGuidanceMetric? {
        liveCameraState?.guidance.referenceVisibility ?? lastObservedCameraState?.guidance.referenceVisibility
    }

    private var configuredMaterialName: String {
        let normalized = configuration.home.materialName.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Selected material" : normalized
    }

    private var nativeMaterialSuggestion: StockpileCaptureMaterialSuggestion? {
        liveCameraState?.materialSuggestion ?? lastObservedCameraState?.materialSuggestion
    }

    private func makeMaterialSuggestion(
        guidance: StockpileCaptureGuidanceSummary?,
        referenceContext: CaptureFeatureReferenceMarkerContext,
        materialName: String
    ) -> CaptureFeatureInlineStatusContent {
        let sceneWarningLevel = wrongSceneWarningLevel(for: guidance?.sceneFit)
        let nativeSuggestion = nativeMaterialSuggestion
        let hintTitle = nativeSuggestion == nil ? "Selected material" : "Native material hint"
        let baseMessage: String
        let tone: StockpileStatusTone

        switch sceneWarningLevel {
        case .blocked:
            baseMessage = "\(materialName) stays selected for this run, but the camera is pointed away from the stockpile."
            tone = .caution
        case .watch:
            baseMessage = materialGuidanceMessage(
                materialName: materialName,
                nativeSuggestion: nativeSuggestion,
                fallback: "\(materialName) stays selected. Recenter the stockpile before you finish the lap."
            )
            tone = .info
        case .none:
            baseMessage = materialGuidanceMessage(
                materialName: materialName,
                nativeSuggestion: nativeSuggestion,
                fallback: "\(materialName) is selected for this run."
            )
            tone = nativeSuggestion == nil
                ? (referenceContext.hasObservedMarkers ? .success : .info)
                : (referenceContext.hasObservedMarkers ? .success : .info)
        }

        let supportMessage = materialSuggestionSupportMessage(
            for: referenceContext,
            referenceTarget: max(configuration.pipeline.referenceCountGoal, 2)
        )

        return CaptureFeatureInlineStatusContent(
            title: hintTitle,
            message: [baseMessage, supportMessage]
                .filter { $0.isEmpty == false }
                .joined(separator: " "),
            tone: tone,
            systemImage: "cube.box.fill"
        )
    }

    private func materialGuidanceMessage(
        materialName: String,
        nativeSuggestion: StockpileCaptureMaterialSuggestion?,
        fallback: String
    ) -> String {
        guard let nativeSuggestion else {
            return fallback
        }

        let confidencePercent = Int((nativeSuggestion.confidence * 100).rounded())
        let normalizedConfiguredName = materialName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSuggestedName = nativeSuggestion.materialName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedSuggestedName.isEmpty {
            return fallback
        }

        if normalizedSuggestedName == normalizedConfiguredName {
            return "On-device vision agrees with \(materialName) (\(confidencePercent)% confidence)."
        }

        return "On-device vision leans \(nativeSuggestion.materialName) (\(confidencePercent)% confidence). \(materialName) stays selected until backend verification finishes."
    }

    private func materialSuggestionSupportMessage(
        for referenceContext: CaptureFeatureReferenceMarkerContext,
        referenceTarget: Int
    ) -> String {
        switch referenceContext.source {
        case .observed:
            let markerSummary = markerSummaryLabel(from: referenceContext.markerIDs)
            guard markerSummary.isEmpty == false else {
                return "Observed tagged references are lining up cleanly."
            }
            return "Tracking \(markerSummary) right now."
        case .estimated:
            switch referenceContext.maxVisibleTogether {
            case 2...:
                return "\(referenceContext.maxVisibleTogether) tagged references look available together."
            case 1:
                return "Only one tagged reference looks available right now. Bring a second one into frame."
            default:
                return "Keep \(referenceTarget) tagged references visible while you start the lap."
            }
        case .unavailable:
            return "Keep the selected pile and tagged references centered as the lap begins."
        }
    }

    private func makeWrongSceneFeedback(
        from sceneFit: StockpileCaptureGuidanceMetric?,
        materialName: String
    ) -> CaptureFeatureInlineStatusContent? {
        guard let sceneFit else {
            return nil
        }

        switch sceneFit.level {
        case .good:
            return nil
        case .watch:
            return CaptureFeatureInlineStatusContent(
                title: "Reframe toward the pile",
                message: "\(sceneFit.detail) Keep the \(materialName) pile filling most of the frame.",
                tone: .caution,
                systemImage: "camera.metering.center.weighted"
            )
        case .blocked:
            return CaptureFeatureInlineStatusContent(
                title: "Wrong scene likely",
                message: "This frame is unlikely to calibrate cleanly. \(sceneFit.detail) Keep the \(materialName) pile filling most of the frame before you seal the pass.",
                tone: .critical,
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    private func wrongSceneWarningLevel(
        for sceneFit: StockpileCaptureGuidanceMetric?
    ) -> CaptureFeatureSceneWarningLevel {
        guard let sceneFit else {
            return .none
        }

        switch sceneFit.level {
        case .good:
            return .none
        case .watch:
            return .watch
        case .blocked:
            return .blocked
        }
    }

    private func markerSummaryLabel(from markerIDs: [String]) -> String {
        switch markerIDs.count {
        case 0:
            return ""
        case 1:
            return markerIDs[0]
        case 2:
            return "\(markerIDs[0]) and \(markerIDs[1])"
        default:
            return "\(markerIDs[0]), \(markerIDs[1]), +\(markerIDs.count - 2) more"
        }
    }

    private func makeVector3Payload(
        _ vector: CaptureFeatureBufferedPoseSample.Vector3
    ) -> StockpileVector3Payload {
        StockpileVector3Payload(x: vector.x, y: vector.y, z: vector.z)
    }

    private var cameraDeviceTelemetrySnapshot: StockpileCaptureSensorSnapshot? {
        (cameraSession as? any StockpileCaptureDeviceTelemetryProviding)?.latestTelemetrySnapshot
    }

    private var mergedDeviceTelemetrySnapshot: StockpileCaptureSensorSnapshot? {
        let cameraTelemetry = cameraDeviceTelemetrySnapshot
        guard poseObservationController.hasBufferedSamples,
              let poseTelemetry = poseObservationController.latestTelemetrySnapshot else {
            return cameraTelemetry
        }

        return StockpileCaptureSensorSnapshot(
            sampleCount: max(cameraTelemetry?.sampleCount ?? 0, poseTelemetry.sampleCount),
            motionSignalsIncluded: cameraTelemetry?.motionSignalsIncluded ?? false || poseTelemetry.motionSignalsIncluded,
            gravityVectorIncluded: cameraTelemetry?.gravityVectorIncluded ?? false || poseTelemetry.gravityVectorIncluded,
            headingSignalsIncluded: cameraTelemetry?.headingSignalsIncluded ?? false || poseTelemetry.headingSignalsIncluded,
            cameraCalibrationIncluded: cameraTelemetry?.cameraCalibrationIncluded ?? false || poseTelemetry.cameraCalibrationIncluded,
            motionStable: poseTelemetry.motionStable,
            headingStable: poseTelemetry.headingSignalsIncluded
                ? poseTelemetry.headingStable
                : (cameraTelemetry?.headingStable ?? false),
            lidarAssistAvailable: poseTelemetry.lidarAssistAvailable || (cameraTelemetry?.lidarAssistAvailable ?? false),
            trackingState: poseTelemetry.trackingState ?? cameraTelemetry?.trackingState,
            sensorMetadata: mergeSensorMetadata(
                cameraTelemetry?.sensorMetadata,
                poseTelemetry.sensorMetadata
            )
        )
    }

    private func mobileFirstCaptureStage(for phase: CaptureFeaturePhase) -> StockpileMobileFirstCaptureStagePayload {
        switch phase {
        case .idle:
            return .ready
        case .guidedCapture:
            return .walkingPerimeter
        case .uploadInProgress:
            return .sealingCapture
        case .processing:
            return .uploading
        case .verifiedResult:
            return .provisionalResult
        case .reviewOnlyResult:
            return .reviewQueue
        case .blockedResult:
            return .recaptureRequired
        }
    }

    private func uploadPreparationMessage(
        for source: CaptureUploadSource?,
        cameraState: StockpileCameraCaptureSessionState? = nil
    ) -> String {
        switch source ?? plannedUploadSource {
        case .liveRecorded:
            switch cameraState?.recordingLifecycle {
            case .starting, .recording, .finalizing:
                return "Sealing the in-app recording on device and preparing the secure handoff."
            case .finished:
                return "Recording sealed. Starting the secure handoff now."
            case .failed:
                return "The in-app recording did not seal cleanly, so the handoff cannot start yet."
            case .idle, .none:
                return "Waiting for the recorded pass before the handoff begins."
            }
        case .importedVideo:
            if let selectedMovieFileDescriptor {
                return "\(selectedMovieFileDescriptor.fileName) is on standby as the internal recovery clip and is being prepared for handoff."
            }

            return "Preparing the imported recovery clip for handoff."
        case .fallbackVideo:
            return "Preparing the configured recovery recording source and secure handoff."
        }
    }

    private func sourceOperatorLabel(for source: CaptureUploadSource) -> String {
        switch source {
        case .liveRecorded:
            return "The recorded walkaround"
        case .importedVideo:
            return "The imported recovery clip"
        case .fallbackVideo:
            return "The configured recovery recording"
        }
    }

    private func uploadStageMessage(for stage: StockpileUploadTaskStage) -> String {
        guard let activeUploadSource else {
            return stage.detail
        }

        switch stage {
        case .completed:
            return "\(sourceOperatorLabel(for: activeUploadSource)) is secure on the server and result checks will begin automatically."
        case .handingOffToServer:
            return "\(sourceOperatorLabel(for: activeUploadSource)) transferred successfully. Waiting for the final server receipt."
        case .failed(let failure):
            return "\(sourceOperatorLabel(for: activeUploadSource)) could not finish the secure handoff. \(failure.detail)"
        default:
            return "\(sourceOperatorLabel(for: activeUploadSource)) is moving through the secure handoff. \(stage.detail)"
        }
    }

    private func processingStageMessage(detail: String) -> String {
        guard let activeUploadSource else {
            return detail
        }

        return "\(sourceOperatorLabel(for: activeUploadSource)) is secure on the server. \(detail)"
    }

    private func restoredUploadProgressContent(
        for pendingRun: CaptureFeaturePendingRunRecoveryState
    ) -> UploadProgressContent {
        let transferState: UploadTransferState = pendingRun.uploadCompletedAt == nil
            ? .uploading(progress: nil)
            : .complete

        return UploadProgressContent(
            transferState: transferState,
            processingState: .queued,
            statusTone: .neutral,
            primaryMessage: restoredPendingRunMessage(for: pendingRun)
        )
    }

    private func restoredProcessingContent(
        for pendingRun: CaptureFeaturePendingRunRecoveryState
    ) -> UploadProgressContent {
        let transferState: UploadTransferState = pendingRun.uploadCompletedAt == nil
            ? .uploading(progress: nil)
            : .complete

        return UploadProgressContent(
            transferState: transferState,
            processingState: .queued,
            statusTone: .neutral,
            primaryMessage: restoredPendingRunMessage(for: pendingRun)
        )
    }

    private func restoredPendingRunMessage(
        for pendingRun: CaptureFeaturePendingRunRecoveryState
    ) -> String {
        let sourceLabel = sourceOperatorLabel(for: pendingRun.source)
        if pendingRun.uploadCompletedAt != nil {
            return "\(sourceLabel) was already handed off before the app relaunched. Reconnecting to backend processing now."
        }

        return "\(sourceLabel) started its secure handoff before the app relaunched. Checking the latest upload and processing state now."
    }

    private func applyPendingRunStage(
        _ stage: StockpileUploadTaskStage,
        taskID: String
    ) {
        updatePendingRunRecoveryState { pendingRun in
            pendingRun.uploadTaskID = taskID

            switch stage {
            case .handingOffToServer(let handoff):
                pendingRun.serverUploadID = handoff.serverUploadID ?? pendingRun.serverUploadID
            case .completed(let completion):
                pendingRun.uploadCompletedAt = completion.completedAt
                pendingRun.serverReceiptID = completion.serverReceiptID
                pendingRun.serverUploadID = completion.serverUploadID ?? pendingRun.serverUploadID
            case .preparingLocalFile, .transferringBytes, .queuedForRetry, .failed:
                break
            }
        }
    }

    private func updatePendingRunRecoveryState(
        _ update: (inout CaptureFeaturePendingRunRecoveryState) -> Void
    ) {
        guard var pendingRunRecoveryState else {
            return
        }

        update(&pendingRunRecoveryState)
        self.pendingRunRecoveryState = pendingRunRecoveryState
    }

    private var usesSyntheticPreviewUploadProgress: Bool {
        configuration.pipeline.clientBuild.localizedCaseInsensitiveContains("preview")
    }

    private func pendingProcessingContent(
        for source: CaptureUploadSource?
    ) -> UploadProgressContent {
        let sourceLabel = source.map(sourceOperatorLabel(for:)) ?? "The recorded walkaround"

        return UploadProgressContent(
            transferState: .complete,
            processingState: .queued,
            statusTone: .neutral,
            primaryMessage: "\(sourceLabel) will move into server processing as soon as the secure handoff is confirmed."
        )
    }

    private func handlePoseObservationStateUpdated(_ state: CaptureFeatureDevicePoseObservationState) {
        // Always mirror the latest LiDAR quick estimate so the SwiftUI HUD
        // can react regardless of phase. The HUD card itself is gated on
        // markerless mode so it stays hidden when v1 captures run.
        if latestQuickVolumeEstimate != state.latestQuickEstimate {
            latestQuickVolumeEstimate = state.latestQuickEstimate
        }

        guard phase == .guidedCapture || (phase == .uploadInProgress && isFinalizingRecordedCapture) else {
            return
        }

        objectWillChange.send()
    }

    private func startPoseObservationIfNeeded() {
        guard phase == .guidedCapture else {
            return
        }

        if liveCameraState?.recordingLifecycle.isActive == true {
            CaptureFeatureTrace.log(
                "store.poseObservation.skippedCameraOwnedByRecording",
                state: liveCameraState,
                details: "ARKit pose/depth cannot run beside the AVFoundation movie recorder on device."
            )
            return
        }

        poseObservationController.start()
    }

    private func stopPoseObservation(retainingBufferedSamples: Bool) {
        poseObservationController.stop(retainingBufferedSamples: retainingBufferedSamples)
    }

    private func mergeSensorMetadata(
        _ cameraMetadata: StockpileCaptureSensorMetadata?,
        _ poseMetadata: StockpileCaptureSensorMetadata?
    ) -> StockpileCaptureSensorMetadata? {
        guard cameraMetadata != nil || poseMetadata != nil else {
            return nil
        }

        return StockpileCaptureSensorMetadata(
            deviceModelIdentifier: cameraMetadata?.deviceModelIdentifier ?? poseMetadata?.deviceModelIdentifier,
            videoWidth: cameraMetadata?.videoWidth ?? poseMetadata?.videoWidth,
            videoHeight: cameraMetadata?.videoHeight ?? poseMetadata?.videoHeight,
            videoFrameRate: cameraMetadata?.videoFrameRate ?? poseMetadata?.videoFrameRate,
            poseSamplingHz: poseMetadata?.poseSamplingHz ?? cameraMetadata?.poseSamplingHz,
            depthDataIncluded: poseMetadata?.depthDataIncluded ?? cameraMetadata?.depthDataIncluded,
            worldAlignment: poseMetadata?.worldAlignment ?? cameraMetadata?.worldAlignment,
            videoStabilizationMode: cameraMetadata?.videoStabilizationMode ?? poseMetadata?.videoStabilizationMode
        )
    }

    private func refreshCameraMonitoringState() {
        cameraMonitoringTask?.cancel()
        cameraMonitoringTask = nil

        guard cameraSession != nil else {
            return
        }

        guard phase == .guidedCapture || (phase == .uploadInProgress && isFinalizingRecordedCapture) else {
            return
        }

        cameraMonitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollCameraSessionState()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func pollCameraSessionState() {
        guard let cameraSession else {
            return
        }

        let state = cameraSession.state
        guard state != lastObservedCameraState else {
            return
        }
        CaptureFeatureTrace.log("store.pollCameraSessionState.changed", state: state)

        if phase == .guidedCapture,
           (state.permission.isGranted == false || state.phase == .failed) {
            stopPoseObservation(retainingBufferedSamples: false)
        }

        switch phase {
        case .guidedCapture:
            syncGuidedCaptureState(from: state)
        case .uploadInProgress where isFinalizingRecordedCapture:
            lastObservedCameraState = state
            configuration.uploading = UploadProgressContent(
                transferState: .preparing,
                processingState: .idle,
                statusTone: .neutral,
                primaryMessage: uploadPreparationMessage(
                    for: activeUploadSource,
                    cameraState: state
                )
            )
        default:
            lastObservedCameraState = state
        }
    }

    private func prepareAndStartGuidedCapture(
        using cameraSession: any StockpileCameraCaptureSessionServicing
    ) async {
        var permission = cameraSession.state.permission
        CaptureFeatureTrace.log(
            "store.prepareAndStart.enter",
            state: cameraSession.state
        )

        if !permission.isGranted && permission.canRequestAccess {
            CaptureFeatureTrace.log("store.prepareAndStart.requestPermission", state: cameraSession.state)
            permission = await cameraSession.requestCameraAccess()
            syncGuidedCaptureState(from: cameraSession.state)
            CaptureFeatureTrace.log("store.prepareAndStart.permissionReturned", state: cameraSession.state)
        }

        guard permission.isGranted else {
            syncGuidedCaptureState(from: cameraSession.state)
            CaptureFeatureTrace.log("store.prepareAndStart.permissionBlocked", state: cameraSession.state)
            return
        }

        stopPoseObservation(retainingBufferedSamples: false)
        CaptureFeatureTrace.log("store.prepareAndStart.callStartGuidedCapture", state: cameraSession.state)
        cameraSession.startGuidedCapture()
        syncGuidedCaptureState(from: cameraSession.state)
        CaptureFeatureTrace.log("store.prepareAndStart.afterStartGuidedCapture", state: cameraSession.state)
        startPoseObservationIfNeeded()
    }

    private func prepareAndStoreSelectedMovie(from fileURL: URL) async throws {
        let preparedMovie = try await Self.prepareSelectedMovieStorage(from: fileURL)
        selectedMovieStorage = preparedMovie
        selectedMovieFileDescriptor = preparedMovie.descriptor
        ownedSelectedMovieURLs.insert(preparedMovie.cachedFileURL)
        pruneOwnedSelectedMovieFiles()
    }

    private func pruneOwnedSelectedMovieFiles() {
        let retainedURLs = Set(
            [selectedMovieStorage?.cachedFileURL, activeUploadFileURL]
                .compactMap { $0 }
        )
        let removableURLs = ownedSelectedMovieURLs.filter { retainedURLs.contains($0) == false }
        guard removableURLs.isEmpty == false else { return }

        Self.removeOwnedFiles(removableURLs)
        removableURLs.forEach { ownedSelectedMovieURLs.remove($0) }
    }

    private nonisolated static func removeOwnedFiles<S: Sequence>(_ fileURLs: S) where S.Element == URL {
        let fileManager = FileManager.default
        for fileURL in fileURLs {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private nonisolated static func captureFileDates(
        for fileURL: URL
    ) -> (startedAt: Date?, completedAt: Date?) {
        guard let resourceValues = try? fileURL.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        ) else {
            return (nil, nil)
        }

        let startedAt = resourceValues.creationDate
        let completedAt = resourceValues.contentModificationDate ?? resourceValues.creationDate
        return (startedAt, completedAt)
    }

    private nonisolated static func prepareSelectedMovieStorage(from sourceURL: URL) async throws -> CaptureSelectedMovieStorage {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let standardizedSourceURL = sourceURL.standardizedFileURL
            let didAccessSecurityScope = standardizedSourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessSecurityScope {
                    standardizedSourceURL.stopAccessingSecurityScopedResource()
                }
            }

            guard fileManager.fileExists(atPath: standardizedSourceURL.path) else {
                throw CaptureSelectedMovieImportError.missingLocalMovie(standardizedSourceURL)
            }

            try Self.validateSelectedMovieType(at: standardizedSourceURL)

            let cacheDirectoryURL = try Self.selectedMovieCacheDirectory()
            let fileName = Self.sanitizedSelectedMovieFileName(standardizedSourceURL.lastPathComponent)
            let destinationURL = cacheDirectoryURL.appendingPathComponent("\(UUID().uuidString)-\(fileName)")

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            do {
                try fileManager.copyItem(at: standardizedSourceURL, to: destinationURL)
            } catch {
                throw CaptureSelectedMovieImportError.unreadableMovie(standardizedSourceURL)
            }

            let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
            guard let fileSize = (attributes[.size] as? NSNumber)?.int64Value else {
                throw CaptureSelectedMovieImportError.missingMovieAttributes(destinationURL)
            }

            let descriptor = StockpileUploadFileDescriptor(
                fileURL: destinationURL,
                fileName: fileName,
                byteCount: fileSize,
                contentType: Self.preferredContentType(for: destinationURL),
                checksumSHA256: nil
            )

            return CaptureSelectedMovieStorage(
                descriptor: descriptor,
                cachedFileURL: destinationURL
            )
        }.value
    }

    private nonisolated static func selectedMovieCacheDirectory() throws -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directoryURL = baseDirectory.appendingPathComponent(
            "StockpileOperatorSelectedMovies",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        return directoryURL
    }

    private nonisolated static func validateSelectedMovieType(at fileURL: URL) throws {
        let contentType = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: fileURL.pathExtension)

        if let contentType, contentType.conforms(to: .movie) {
            return
        }

        throw CaptureSelectedMovieImportError.unsupportedMovieType(fileURL)
    }

    private nonisolated static func preferredContentType(for fileURL: URL) -> String {
        let contentType = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: fileURL.pathExtension)

        if let preferredMIMEType = contentType?.preferredMIMEType {
            return preferredMIMEType
        }

        switch fileURL.pathExtension.lowercased() {
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        default:
            return "video/quicktime"
        }
    }

    private nonisolated static func sanitizedSelectedMovieFileName(_ fileName: String) -> String {
        let trimmedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedFileName.isEmpty == false else {
            return "selected-capture.mov"
        }

        return trimmedFileName.replacingOccurrences(
            of: "[/:]+",
            with: "-",
            options: .regularExpression
        )
    }

    private nonisolated static func isUserCancelledSelection(_ error: any Error) -> Bool {
        guard let cocoaError = error as? CocoaError else {
            return false
        }

        return cocoaError.code == .userCancelled
    }
}

@MainActor
extension CaptureFeatureStore: CaptureFeatureVideoImportStoreBridging {
    var selectedImportedVideo: CaptureImportedVideoSelection? {
        guard allowsImportedBackupVideo else {
            return nil
        }

        guard let descriptor = selectedMovieFileDescriptor else {
            return nil
        }

        let fileSize = ByteCountFormatter.string(fromByteCount: descriptor.byteCount, countStyle: .file)
        let formatDescription = UTType(mimeType: descriptor.contentType)?.localizedDescription
            ?? (!descriptor.fileURL.pathExtension.isEmpty ? "\(descriptor.fileURL.pathExtension.uppercased()) recording" : "Recording file")

        return CaptureImportedVideoSelection(
            displayName: descriptor.fileName,
            subtitle: "Internal recovery clip",
            statusMessage: selectedMovieImportErrorMessage
                ?? "This recovery clip stays available only if the live walkaround is not ready to hand off.",
            metadataItems: [
                CaptureImportedVideoMetadataItem(
                    title: "Format",
                    value: formatDescription,
                    systemImage: "film.fill"
                ),
                CaptureImportedVideoMetadataItem(
                    title: "Size",
                    value: fileSize,
                    systemImage: "externaldrive.fill"
                ),
                CaptureImportedVideoMetadataItem(
                    title: "Source",
                    value: "Internal recovery",
                    systemImage: "folder.fill"
                ),
            ]
        )
    }

    func importSelectedImportedVideo(from url: URL) async throws {
        guard allowsImportedBackupVideo else {
            selectedMovieImportErrorMessage = "Backup movie import is disabled in this build. Record the walkaround live in the app."
            throw CaptureSelectedMovieImportError.missingSelectedMovie(
                "Backup movie import is disabled in this build."
            )
        }

        isPreparingSelectedMovie = true
        selectedMovieImportErrorMessage = nil
        defer { isPreparingSelectedMovie = false }

        do {
            try await prepareAndStoreSelectedMovie(from: url)
        } catch {
            if let selectedMovieFileDescriptor {
                selectedMovieImportErrorMessage = "A new Files backup could not be imported. Keeping \(selectedMovieFileDescriptor.fileName) on standby. \(error.localizedDescription)"
            } else {
                selectedMovieImportErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func clearSelectedImportedVideo() {
        guard allowsImportedBackupVideo else {
            return
        }
        clearSelectedMovieSelection()
    }
}

private enum CaptureFeatureRecordedCaptureBridgeError: LocalizedError {
    case missingOutput
    case recordingFailed(String)
    case finalizeTimedOut

    var errorDescription: String? {
        switch self {
        case .missingOutput:
            return "No finalized recorded walkaround is available from the camera session yet."
        case .recordingFailed(let message):
            return "The live walkaround recording failed before a local file was finalized. \(message)"
        case .finalizeTimedOut:
            return "The live walkaround recording did not finish finalizing in time."
        }
    }
}

private enum CaptureFeatureRecordedCaptureBridge {
    static func descriptor(from output: StockpileCameraRecordingOutput?) -> StockpileUploadFileDescriptor? {
        guard let output else {
            return nil
        }

        let fileURL = output.fileURL.standardizedFileURL
        let fileName = fileURL.lastPathComponent.isEmpty ? "recorded-capture.mov" : fileURL.lastPathComponent
        let byteCount = output.fileSizeBytes ?? fileSize(at: fileURL) ?? 0

        return StockpileUploadFileDescriptor(
            fileURL: fileURL,
            fileName: fileName,
            byteCount: byteCount,
            contentType: preferredContentType(for: fileURL),
            checksumSHA256: nil
        )
    }

    @MainActor
    static func finalizeRecordedVideoIfNeeded(
        for session: any StockpileCameraCaptureSessionServicing
    ) async throws -> StockpileUploadFileDescriptor {
        if let descriptor = descriptor(from: session.state.recordingOutput) {
            return descriptor
        }

        switch session.state.recordingLifecycle {
        case .failed:
            throw CaptureFeatureRecordedCaptureBridgeError.recordingFailed(
                session.state.lastErrorDescription ?? "No additional recording detail was provided."
            )
        case .idle, .finished:
            throw CaptureFeatureRecordedCaptureBridgeError.missingOutput
        case .starting, .recording, .finalizing:
            if session.state.canStopRecording {
                session.stopRecording()
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let descriptor = descriptor(from: session.state.recordingOutput) {
                return descriptor
            }

            if session.state.recordingLifecycle == .failed {
                throw CaptureFeatureRecordedCaptureBridgeError.recordingFailed(
                    session.state.lastErrorDescription ?? "No additional recording detail was provided."
                )
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        throw CaptureFeatureRecordedCaptureBridgeError.finalizeTimedOut
    }

    private static func fileSize(at fileURL: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value else {
            return nil
        }

        return fileSize
    }

    private static func preferredContentType(for fileURL: URL) -> String {
        let contentType = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: fileURL.pathExtension)

        if let preferredMIMEType = contentType?.preferredMIMEType {
            return preferredMIMEType
        }

        switch fileURL.pathExtension.lowercased() {
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        default:
            return "video/quicktime"
        }
    }
}

@MainActor
extension StockpileCameraCaptureSessionLive: CaptureFeatureRecordedCaptureSessionBridging {
    var finalizedRecordedVideoDescriptor: StockpileUploadFileDescriptor? {
        CaptureFeatureRecordedCaptureBridge.descriptor(from: state.recordingOutput)
    }

    func finalizeRecordedVideoIfNeeded() async throws -> StockpileUploadFileDescriptor {
        try await CaptureFeatureRecordedCaptureBridge.finalizeRecordedVideoIfNeeded(for: self)
    }
}

@MainActor
extension StockpileCameraCaptureSessionMock: CaptureFeatureRecordedCaptureSessionBridging {
    var finalizedRecordedVideoDescriptor: StockpileUploadFileDescriptor? {
        CaptureFeatureRecordedCaptureBridge.descriptor(from: state.recordingOutput)
    }

    func finalizeRecordedVideoIfNeeded() async throws -> StockpileUploadFileDescriptor {
        try await CaptureFeatureRecordedCaptureBridge.finalizeRecordedVideoIfNeeded(for: self)
    }
}

private struct CaptureFeatureBufferedPoseSample: Equatable, Sendable {
    struct Vector3: Equatable, Sendable {
        let x: Double
        let y: Double
        let z: Double

        init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    let sequenceNumber: Int
    let capturedAt: Date
    let timeOffsetSec: TimeInterval
    let trackingState: String
    let positionM: Vector3
    let yawPitchRollDeg: Vector3
    let depthDataIncluded: Bool
}

private struct CaptureFeatureOnDeviceVisionSummary: Equatable, Sendable {
    let source: String
    let usesMachineLearning: Bool
    let pileSegmentationScore: Double?
    let toeSegmentationScore: Double?
    let segmentationConfidenceScore: Double?
    let foregroundCoverageRatio: Double?
    let lowerFrameOccupancyRatio: Double?
    let materialFamilyCode: String?
    let materialFamilyLabel: String?
    let materialConfidenceScore: Double?
    let guidanceHint: String?
}

#if canImport(StockpileMobileFirstCapture)
private extension CaptureFeatureOnDeviceVisionSummary {
    init?(_ summary: StockpileOnDeviceVisionSummary?) {
        guard let summary else {
            return nil
        }

        self.init(
            source: summary.source.rawValue,
            usesMachineLearning: summary.usesMachineLearning,
            pileSegmentationScore: summary.pileSegmentationScore,
            toeSegmentationScore: summary.toeSegmentationScore,
            segmentationConfidenceScore: summary.segmentationConfidenceScore,
            foregroundCoverageRatio: summary.foregroundCoverageRatio,
            lowerFrameOccupancyRatio: summary.lowerFrameOccupancyRatio,
            materialFamilyCode: summary.materialFamilyCode,
            materialFamilyLabel: summary.materialFamilyLabel,
            materialConfidenceScore: summary.materialConfidenceScore,
            guidanceHint: summary.guidanceHint
        )
    }
}
#endif

private struct CaptureFeatureDevicePoseObservationState: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case unavailable
        case idle
        case preparing
        case running
        case interrupted
        case stopped
        case failed
    }

    let status: Status
    let bufferedSamples: [CaptureFeatureBufferedPoseSample]
    let latestTelemetrySnapshot: StockpileCaptureSensorSnapshot?
    let latestQuickEstimate: CaptureFeatureLocalQuickEstimate?
    let latestOnDeviceVision: CaptureFeatureOnDeviceVisionSummary?
    let issueDescription: String?
    let updatedAt: Date

    init(
        status: Status,
        bufferedSamples: [CaptureFeatureBufferedPoseSample],
        latestTelemetrySnapshot: StockpileCaptureSensorSnapshot?,
        latestQuickEstimate: CaptureFeatureLocalQuickEstimate? = nil,
        latestOnDeviceVision: CaptureFeatureOnDeviceVisionSummary? = nil,
        issueDescription: String?,
        updatedAt: Date
    ) {
        self.status = status
        self.bufferedSamples = bufferedSamples
        self.latestTelemetrySnapshot = latestTelemetrySnapshot
        self.latestQuickEstimate = latestQuickEstimate
        self.latestOnDeviceVision = latestOnDeviceVision
        self.issueDescription = issueDescription
        self.updatedAt = updatedAt
    }

    static let idle = CaptureFeatureDevicePoseObservationState(
        status: .idle,
        bufferedSamples: [],
        latestTelemetrySnapshot: nil,
        latestQuickEstimate: nil,
        latestOnDeviceVision: nil,
        issueDescription: nil,
        updatedAt: .distantPast
    )
}

@MainActor
private final class CaptureFeatureDevicePoseObservationController {
    var onStateUpdated: ((CaptureFeatureDevicePoseObservationState) -> Void)?

    private let maximumBufferedSamples: Int
    private let runtimeConfiguration: CaptureFeatureDevicePoseRuntimeConfiguration
    private let runtimeFactory: @Sendable () -> any CaptureFeatureDevicePoseRuntime
    private var runtime: (any CaptureFeatureDevicePoseRuntime)?
    private var lastAcceptedSequenceNumber: Int?
    private var lastAcceptedTimeOffsetSec: TimeInterval?
    private var firstAcceptedTimeOffsetSec: TimeInterval?

    private(set) var state = CaptureFeatureDevicePoseObservationState.idle

    init(
        maximumBufferedSamples: Int = 900,
        runtimeConfiguration: CaptureFeatureDevicePoseRuntimeConfiguration = .alphaDefault,
        runtimeFactory: @escaping @Sendable () -> any CaptureFeatureDevicePoseRuntime = {
            CaptureFeatureDevicePoseRuntimeFactory.makeDefaultRuntime()
        }
    ) {
        self.maximumBufferedSamples = max(maximumBufferedSamples, 60)
        self.runtimeConfiguration = runtimeConfiguration
        self.runtimeFactory = runtimeFactory
    }

    var latestTelemetrySnapshot: StockpileCaptureSensorSnapshot? {
        state.latestTelemetrySnapshot
    }

    var latestQuickEstimate: CaptureFeatureLocalQuickEstimate? {
        state.latestQuickEstimate
    }

    var latestOnDeviceVision: CaptureFeatureOnDeviceVisionSummary? {
        state.latestOnDeviceVision
    }

    var bufferedSamples: [CaptureFeatureBufferedPoseSample] {
        state.bufferedSamples
    }

    var hasBufferedSamples: Bool {
        state.bufferedSamples.isEmpty == false
    }

    func start() {
        guard runtime == nil else {
            return
        }

        lastAcceptedSequenceNumber = nil
        lastAcceptedTimeOffsetSec = nil
        firstAcceptedTimeOffsetSec = nil
        state = CaptureFeatureDevicePoseObservationState(
            status: .preparing,
            bufferedSamples: [],
            latestTelemetrySnapshot: nil,
            latestQuickEstimate: nil,
            latestOnDeviceVision: nil,
            issueDescription: nil,
            updatedAt: Date()
        )
        onStateUpdated?(state)

        let runtime = runtimeFactory()
        runtime.onSnapshotUpdated = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.handle(snapshot)
            }
        }
        self.runtime = runtime

        do {
            try runtime.start(configuration: runtimeConfiguration)
            handle(runtime.latestSnapshot)
        } catch {
            let failureSnapshot = CaptureFeatureDevicePoseRuntimeSnapshot(
                status: .failed,
                sampleCount: 0,
                latestSample: nil,
                startedAt: nil,
                updatedAt: Date(),
                issueDescription: error.localizedDescription,
                lidarAssistAvailable: runtime.latestSnapshot.lidarAssistAvailable,
                depthDataIncluded: runtime.latestSnapshot.depthDataIncluded,
                worldAlignment: runtime.latestSnapshot.worldAlignment,
                trackingState: runtime.latestSnapshot.trackingState,
                motionStable: false,
                headingStable: false,
                onDeviceVision: nil
            )
            handle(failureSnapshot)
            self.runtime = nil
        }
    }

    func stop(retainingBufferedSamples: Bool) {
        runtime?.stop()
        runtime = nil
        lastAcceptedSequenceNumber = nil
        lastAcceptedTimeOffsetSec = nil
        firstAcceptedTimeOffsetSec = nil

        if retainingBufferedSamples {
            state = CaptureFeatureDevicePoseObservationState(
                status: state.bufferedSamples.isEmpty ? .idle : .stopped,
                bufferedSamples: state.bufferedSamples,
                latestTelemetrySnapshot: state.latestTelemetrySnapshot,
                latestQuickEstimate: state.latestQuickEstimate,
                latestOnDeviceVision: state.latestOnDeviceVision,
                issueDescription: state.issueDescription,
                updatedAt: Date()
            )
        } else {
            state = .idle
        }
        onStateUpdated?(state)
    }

    func reset() {
        stop(retainingBufferedSamples: false)
    }

    private func handle(_ snapshot: CaptureFeatureDevicePoseRuntimeSnapshot) {
        var bufferedSamples = state.bufferedSamples

        if let latestSample = snapshot.latestSample,
           shouldAppend(sample: latestSample) {
            if firstAcceptedTimeOffsetSec == nil {
                firstAcceptedTimeOffsetSec = latestSample.timeOffsetSec
            }
            bufferedSamples.append(makeBufferedSample(from: latestSample, using: snapshot))
            if bufferedSamples.count > maximumBufferedSamples {
                bufferedSamples.removeFirst(bufferedSamples.count - maximumBufferedSamples)
            }
            lastAcceptedSequenceNumber = latestSample.sequenceNumber
            lastAcceptedTimeOffsetSec = latestSample.timeOffsetSec
        }

        let nextState = CaptureFeatureDevicePoseObservationState(
            status: snapshot.status.observationStatus,
            bufferedSamples: bufferedSamples,
            latestTelemetrySnapshot: makeTelemetrySnapshot(from: snapshot, bufferedSampleCount: bufferedSamples.count),
            latestQuickEstimate: snapshot.quickVolumeEstimate,
            latestOnDeviceVision: snapshot.onDeviceVision,
            issueDescription: snapshot.issueDescription,
            updatedAt: snapshot.updatedAt
        )
        state = nextState
        onStateUpdated?(nextState)
    }

    private func shouldAppend(sample: CaptureFeatureDevicePoseRuntimeSample) -> Bool {
        if lastAcceptedSequenceNumber == sample.sequenceNumber {
            return false
        }

        guard let lastAcceptedTimeOffsetSec else {
            return true
        }

        let minimumInterval = 1.0 / max(runtimeConfiguration.targetSampleRateHz, 1)
        return (sample.timeOffsetSec - lastAcceptedTimeOffsetSec) >= (minimumInterval * 0.8)
    }

    private func makeBufferedSample(
        from sample: CaptureFeatureDevicePoseRuntimeSample,
        using snapshot: CaptureFeatureDevicePoseRuntimeSnapshot
    ) -> CaptureFeatureBufferedPoseSample {
        let normalizedTimeOffsetSec = max(0, sample.timeOffsetSec - (firstAcceptedTimeOffsetSec ?? sample.timeOffsetSec))
        let capturedAt = snapshot.startedAt?.addingTimeInterval(sample.timeOffsetSec) ?? snapshot.updatedAt
        return CaptureFeatureBufferedPoseSample(
            sequenceNumber: sample.sequenceNumber,
            capturedAt: capturedAt,
            timeOffsetSec: normalizedTimeOffsetSec,
            trackingState: sample.trackingState,
            positionM: sample.positionM,
            yawPitchRollDeg: sample.yawPitchRollDeg,
            depthDataIncluded: sample.depthDataIncluded
        )
    }

    private func makeTelemetrySnapshot(
        from snapshot: CaptureFeatureDevicePoseRuntimeSnapshot,
        bufferedSampleCount: Int
    ) -> StockpileCaptureSensorSnapshot? {
        guard snapshot.status != .unavailable || bufferedSampleCount > 0 else {
            return nil
        }

        return StockpileCaptureSensorSnapshot(
            sampleCount: bufferedSampleCount,
            motionSignalsIncluded: true,
            gravityVectorIncluded: true,
            headingSignalsIncluded: runtimeConfiguration.usesHeadingAlignment,
            cameraCalibrationIncluded: true,
            motionStable: snapshot.motionStable,
            headingStable: snapshot.headingStable,
            lidarAssistAvailable: snapshot.lidarAssistAvailable,
            trackingState: snapshot.trackingState,
            sensorMetadata: StockpileCaptureSensorMetadata(
                deviceModelIdentifier: nil,
                videoWidth: nil,
                videoHeight: nil,
                videoFrameRate: nil,
                poseSamplingHz: runtimeConfiguration.targetSampleRateHz,
                depthDataIncluded: snapshot.depthDataIncluded,
                worldAlignment: snapshot.worldAlignment,
                videoStabilizationMode: nil
            )
        )
    }
}

private struct CaptureFeatureDevicePoseRuntimeConfiguration: Sendable {
    let usesHeadingAlignment: Bool
    let prefersDepthIfAvailable: Bool
    let targetSampleRateHz: Double

    init(
        usesHeadingAlignment: Bool,
        prefersDepthIfAvailable: Bool,
        targetSampleRateHz: Double
    ) {
        self.usesHeadingAlignment = usesHeadingAlignment
        self.prefersDepthIfAvailable = prefersDepthIfAvailable
        self.targetSampleRateHz = min(max(targetSampleRateHz, 1), 30)
    }

    static let alphaDefault = CaptureFeatureDevicePoseRuntimeConfiguration(
        usesHeadingAlignment: false,
        prefersDepthIfAvailable: true,
        targetSampleRateHz: 10
    )
}

private protocol CaptureFeatureDevicePoseRuntime: AnyObject {
    var latestSnapshot: CaptureFeatureDevicePoseRuntimeSnapshot { get }
    var onSnapshotUpdated: (@Sendable (CaptureFeatureDevicePoseRuntimeSnapshot) -> Void)? { get set }

    func start(configuration: CaptureFeatureDevicePoseRuntimeConfiguration) throws
    func stop()
}

private enum CaptureFeatureDevicePoseRuntimeStatus: String, Sendable {
    case unavailable
    case idle
    case preparing
    case running
    case interrupted
    case stopped
    case failed

    var observationStatus: CaptureFeatureDevicePoseObservationState.Status {
        switch self {
        case .unavailable:
            return .unavailable
        case .idle:
            return .idle
        case .preparing:
            return .preparing
        case .running:
            return .running
        case .interrupted:
            return .interrupted
        case .stopped:
            return .stopped
        case .failed:
            return .failed
        }
    }
}

private struct CaptureFeatureDevicePoseRuntimeSample: Equatable, Sendable {
    let sequenceNumber: Int
    let timeOffsetSec: TimeInterval
    let trackingState: String
    let positionM: CaptureFeatureBufferedPoseSample.Vector3
    let yawPitchRollDeg: CaptureFeatureBufferedPoseSample.Vector3
    let depthDataIncluded: Bool
}

private struct CaptureFeatureDevicePoseRuntimeSnapshot: Equatable, Sendable {
    let status: CaptureFeatureDevicePoseRuntimeStatus
    let sampleCount: Int
    let latestSample: CaptureFeatureDevicePoseRuntimeSample?
    let startedAt: Date?
    let updatedAt: Date
    let issueDescription: String?
    let lidarAssistAvailable: Bool
    let depthDataIncluded: Bool
    let worldAlignment: String?
    let trackingState: String?
    let motionStable: Bool
    let headingStable: Bool
    let quickVolumeEstimate: CaptureFeatureLocalQuickEstimate?
    let onDeviceVision: CaptureFeatureOnDeviceVisionSummary?

    init(
        status: CaptureFeatureDevicePoseRuntimeStatus,
        sampleCount: Int,
        latestSample: CaptureFeatureDevicePoseRuntimeSample?,
        startedAt: Date?,
        updatedAt: Date,
        issueDescription: String?,
        lidarAssistAvailable: Bool,
        depthDataIncluded: Bool,
        worldAlignment: String?,
        trackingState: String?,
        motionStable: Bool,
        headingStable: Bool,
        quickVolumeEstimate: CaptureFeatureLocalQuickEstimate? = nil,
        onDeviceVision: CaptureFeatureOnDeviceVisionSummary? = nil
    ) {
        self.status = status
        self.sampleCount = sampleCount
        self.latestSample = latestSample
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.issueDescription = issueDescription
        self.lidarAssistAvailable = lidarAssistAvailable
        self.depthDataIncluded = depthDataIncluded
        self.worldAlignment = worldAlignment
        self.trackingState = trackingState
        self.motionStable = motionStable
        self.headingStable = headingStable
        self.quickVolumeEstimate = quickVolumeEstimate
        self.onDeviceVision = onDeviceVision
    }
}

private enum CaptureFeatureDevicePoseRuntimeFactory {
    static func makeDefaultRuntime() -> any CaptureFeatureDevicePoseRuntime {
        #if canImport(StockpileMobileFirstCapture)
        CaptureFeatureModuleDevicePoseRuntime()
        #elseif os(iOS) && canImport(ARKit)
        CaptureFeatureARKitDevicePoseRuntime()
        #else
        CaptureFeatureUnavailableDevicePoseRuntime()
        #endif
    }
}

private enum CaptureFeatureDevicePoseRuntimeError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

#if canImport(StockpileMobileFirstCapture)
private final class CaptureFeatureModuleDevicePoseRuntime: CaptureFeatureDevicePoseRuntime {
    var latestSnapshot: CaptureFeatureDevicePoseRuntimeSnapshot {
        snapshot
    }

    var onSnapshotUpdated: (@Sendable (CaptureFeatureDevicePoseRuntimeSnapshot) -> Void)?

    private let session: any StockpileDevicePoseCaptureSession
    private var snapshot: CaptureFeatureDevicePoseRuntimeSnapshot

    init(session: any StockpileDevicePoseCaptureSession = StockpileDevicePoseCaptureSessionFactory.makeDefaultSession()) {
        self.session = session
        snapshot = Self.makeSnapshot(from: session.latestSnapshot)
        self.session.onSnapshotUpdated = { [weak self] nextSnapshot in
            guard let self else { return }
            let mappedSnapshot = Self.makeSnapshot(from: nextSnapshot)
            self.snapshot = mappedSnapshot
            self.onSnapshotUpdated?(mappedSnapshot)
        }
    }

    func start(configuration: CaptureFeatureDevicePoseRuntimeConfiguration) throws {
        try session.start(
            configuration: StockpileDevicePoseCaptureConfiguration(
                worldAlignment: configuration.usesHeadingAlignment ? .gravityAndHeading : .gravity,
                depthMode: configuration.prefersDepthIfAvailable ? .ifAvailable : .disabled,
                preferSmoothedDepth: true,
                sceneMeshMode: .ifAvailable,
                targetSampleRateHz: configuration.targetSampleRateHz
            )
        )
        snapshot = Self.makeSnapshot(from: session.latestSnapshot)
    }

    func stop() {
        session.stop()
        let stoppedSnapshot = Self.makeSnapshot(from: session.latestSnapshot)
        snapshot = stoppedSnapshot
        onSnapshotUpdated?(stoppedSnapshot)
    }

    private static func makeSnapshot(
        from snapshot: StockpileDevicePoseCaptureSnapshot
    ) -> CaptureFeatureDevicePoseRuntimeSnapshot {
        let latestSample = snapshot.latestSample.map { sample in
            CaptureFeatureDevicePoseRuntimeSample(
                sequenceNumber: sample.sequenceNumber,
                timeOffsetSec: sample.sessionTimestamp,
                trackingState: sample.trackingState.phase.rawValue,
                positionM: .init(
                    x: Double(sample.transform.translationMeters.x),
                    y: Double(sample.transform.translationMeters.y),
                    z: Double(sample.transform.translationMeters.z)
                ),
                yawPitchRollDeg: .init(
                    x: Self.degrees(from: sample.transform.eulerAnglesRadians.x),
                    y: Self.degrees(from: sample.transform.eulerAnglesRadians.y),
                    z: Self.degrees(from: sample.transform.eulerAnglesRadians.z)
                ),
                depthDataIncluded: sample.depthSummary != nil
            )
        }

        return CaptureFeatureDevicePoseRuntimeSnapshot(
            status: Self.status(from: snapshot.status),
            sampleCount: snapshot.sampleCount,
            latestSample: latestSample,
            startedAt: snapshot.startedAt,
            updatedAt: snapshot.updatedAt,
            issueDescription: snapshot.issueDescription,
            lidarAssistAvailable: snapshot.capabilities.lidarAssistAvailable,
            depthDataIncluded: snapshot.resolvedConfiguration?.deliversDepth == true,
            worldAlignment: snapshot.configuration?.worldAlignment.rawValue,
            trackingState: latestSample?.trackingState,
            motionStable: snapshot.latestSample?.trackingState.isStable == true,
            headingStable: snapshot.configuration?.worldAlignment == .gravityAndHeading
                && snapshot.latestSample?.trackingState.isStable == true,
            quickVolumeEstimate: CaptureFeatureLocalQuickEstimate(snapshot.quickVolumeEstimate),
            onDeviceVision: CaptureFeatureOnDeviceVisionSummary(snapshot.onDeviceVision)
        )
    }

    private static func status(from status: StockpileDevicePoseCaptureStatus) -> CaptureFeatureDevicePoseRuntimeStatus {
        switch status {
        case .unavailable:
            return .unavailable
        case .idle:
            return .idle
        case .preparing:
            return .preparing
        case .running:
            return .running
        case .interrupted:
            return .interrupted
        case .stopped:
            return .stopped
        case .failed:
            return .failed
        }
    }

    private static func degrees(from radians: Float) -> Double {
        Double(radians) * 180 / Double.pi
    }
}
#endif

#if os(iOS) && canImport(ARKit)
private final class CaptureFeatureARKitDevicePoseRuntime: NSObject, CaptureFeatureDevicePoseRuntime {
    var latestSnapshot: CaptureFeatureDevicePoseRuntimeSnapshot {
        lock.withLock { snapshot }
    }

    var onSnapshotUpdated: (@Sendable (CaptureFeatureDevicePoseRuntimeSnapshot) -> Void)?

    private let lock = NSLock()
    private let session = ARSession()
    private var snapshot = CaptureFeatureDevicePoseRuntimeSnapshot(
        status: .idle,
        sampleCount: 0,
        latestSample: nil,
        startedAt: nil,
        updatedAt: Date(),
        issueDescription: nil,
        lidarAssistAvailable: false,
        depthDataIncluded: false,
        worldAlignment: nil,
        trackingState: nil,
        motionStable: false,
        headingStable: false
    )
    private var sampleCount = 0
    private var currentConfiguration = CaptureFeatureDevicePoseRuntimeConfiguration.alphaDefault

    override init() {
        super.init()
        session.delegate = self
        let capabilities = Self.currentCapabilities()
        snapshot = CaptureFeatureDevicePoseRuntimeSnapshot(
            status: capabilities.isSupported ? .idle : .unavailable,
            sampleCount: 0,
            latestSample: nil,
            startedAt: nil,
            updatedAt: Date(),
            issueDescription: capabilities.unavailableReason,
            lidarAssistAvailable: capabilities.lidarAssistAvailable,
            depthDataIncluded: false,
            worldAlignment: nil,
            trackingState: nil,
            motionStable: false,
            headingStable: false
        )
    }

    func start(configuration: CaptureFeatureDevicePoseRuntimeConfiguration) throws {
        currentConfiguration = configuration
        let capabilities = Self.currentCapabilities()
        guard capabilities.isSupported else {
            let nextSnapshot = CaptureFeatureDevicePoseRuntimeSnapshot(
                status: .unavailable,
                sampleCount: 0,
                latestSample: nil,
                startedAt: nil,
                updatedAt: Date(),
                issueDescription: capabilities.unavailableReason,
                lidarAssistAvailable: capabilities.lidarAssistAvailable,
                depthDataIncluded: false,
                worldAlignment: configuration.usesHeadingAlignment ? "gravityAndHeading" : "gravity",
                trackingState: nil,
                motionStable: false,
                headingStable: false
            )
            publish(nextSnapshot)
            throw CaptureFeatureDevicePoseRuntimeError.unavailable(
                capabilities.unavailableReason ?? "ARKit device pose capture is unavailable."
            )
        }

        let arConfiguration = ARWorldTrackingConfiguration()
        arConfiguration.worldAlignment = configuration.usesHeadingAlignment ? .gravityAndHeading : .gravity

        if configuration.prefersDepthIfAvailable {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                arConfiguration.frameSemantics.insert(.smoothedSceneDepth)
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                arConfiguration.frameSemantics.insert(.sceneDepth)
            }
        }

        sampleCount = 0
        publish(
            CaptureFeatureDevicePoseRuntimeSnapshot(
                status: .preparing,
                sampleCount: 0,
                latestSample: nil,
                startedAt: Date(),
                updatedAt: Date(),
                issueDescription: nil,
                lidarAssistAvailable: capabilities.lidarAssistAvailable,
                depthDataIncluded: arConfiguration.frameSemantics.contains(.sceneDepth)
                    || arConfiguration.frameSemantics.contains(.smoothedSceneDepth),
                worldAlignment: configuration.usesHeadingAlignment ? "gravityAndHeading" : "gravity",
                trackingState: "initializing",
                motionStable: false,
                headingStable: false
            )
        )

        session.run(arConfiguration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        let current = latestSnapshot
        publish(
            CaptureFeatureDevicePoseRuntimeSnapshot(
                status: current.sampleCount > 0 ? .stopped : .idle,
                sampleCount: current.sampleCount,
                latestSample: current.latestSample,
                startedAt: current.startedAt,
                updatedAt: Date(),
                issueDescription: current.issueDescription,
                lidarAssistAvailable: current.lidarAssistAvailable,
                depthDataIncluded: current.depthDataIncluded,
                worldAlignment: current.worldAlignment,
                trackingState: current.trackingState,
                motionStable: current.motionStable,
                headingStable: current.headingStable
            )
        )
    }

    private func publish(_ snapshot: CaptureFeatureDevicePoseRuntimeSnapshot) {
        lock.withLock {
            self.snapshot = snapshot
        }
        onSnapshotUpdated?(snapshot)
    }
}

extension CaptureFeatureARKitDevicePoseRuntime: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        sampleCount += 1

        let depthDataIncluded = frame.smoothedSceneDepth != nil || frame.sceneDepth != nil
        let trackingState = Self.trackingStateLabel(for: frame.camera.trackingState)
        let latestSample = CaptureFeatureDevicePoseRuntimeSample(
            sequenceNumber: sampleCount,
            timeOffsetSec: frame.timestamp,
            trackingState: trackingState,
            positionM: .init(
                x: Double(frame.camera.transform.columns.3.x),
                y: Double(frame.camera.transform.columns.3.y),
                z: Double(frame.camera.transform.columns.3.z)
            ),
            yawPitchRollDeg: .init(
                x: Self.degrees(from: frame.camera.eulerAngles.x),
                y: Self.degrees(from: frame.camera.eulerAngles.y),
                z: Self.degrees(from: frame.camera.eulerAngles.z)
            ),
            depthDataIncluded: depthDataIncluded
        )

        publish(
            CaptureFeatureDevicePoseRuntimeSnapshot(
                status: .running,
                sampleCount: sampleCount,
                latestSample: latestSample,
                startedAt: latestSnapshot.startedAt ?? Date(),
                updatedAt: Date(),
                issueDescription: nil,
                lidarAssistAvailable: Self.currentCapabilities().lidarAssistAvailable,
                depthDataIncluded: depthDataIncluded,
                worldAlignment: currentConfiguration.usesHeadingAlignment ? "gravityAndHeading" : "gravity",
                trackingState: trackingState,
                motionStable: Self.isStable(frame.camera.trackingState),
                headingStable: currentConfiguration.usesHeadingAlignment && Self.isStable(frame.camera.trackingState)
            )
        )
    }

    func sessionWasInterrupted(_ session: ARSession) {
        let current = latestSnapshot
        publish(
            CaptureFeatureDevicePoseRuntimeSnapshot(
                status: .interrupted,
                sampleCount: current.sampleCount,
                latestSample: current.latestSample,
                startedAt: current.startedAt,
                updatedAt: Date(),
                issueDescription: "ARKit tracking was interrupted.",
                lidarAssistAvailable: current.lidarAssistAvailable,
                depthDataIncluded: current.depthDataIncluded,
                worldAlignment: current.worldAlignment,
                trackingState: current.trackingState,
                motionStable: false,
                headingStable: false
            )
        )
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        let current = latestSnapshot
        publish(
            CaptureFeatureDevicePoseRuntimeSnapshot(
                status: .preparing,
                sampleCount: current.sampleCount,
                latestSample: current.latestSample,
                startedAt: current.startedAt,
                updatedAt: Date(),
                issueDescription: "Re-establishing device pose tracking.",
                lidarAssistAvailable: current.lidarAssistAvailable,
                depthDataIncluded: current.depthDataIncluded,
                worldAlignment: current.worldAlignment,
                trackingState: "initializing",
                motionStable: false,
                headingStable: false
            )
        )
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let current = latestSnapshot
        publish(
            CaptureFeatureDevicePoseRuntimeSnapshot(
                status: .failed,
                sampleCount: current.sampleCount,
                latestSample: current.latestSample,
                startedAt: current.startedAt,
                updatedAt: Date(),
                issueDescription: error.localizedDescription,
                lidarAssistAvailable: current.lidarAssistAvailable,
                depthDataIncluded: current.depthDataIncluded,
                worldAlignment: current.worldAlignment,
                trackingState: current.trackingState,
                motionStable: false,
                headingStable: false
            )
        )
    }
}

private extension CaptureFeatureARKitDevicePoseRuntime {
    struct Capabilities {
        let isSupported: Bool
        let lidarAssistAvailable: Bool
        let unavailableReason: String?
    }

    static func currentCapabilities() -> Capabilities {
        let supportsWorldTracking = ARWorldTrackingConfiguration.isSupported
        return Capabilities(
            isSupported: supportsWorldTracking,
            lidarAssistAvailable: lidarAssistAvailable,
            unavailableReason: supportsWorldTracking ? nil : "ARKit world tracking is unavailable on this device."
        )
    }

    static func trackingStateLabel(for trackingState: ARCamera.TrackingState) -> String {
        switch trackingState {
        case .normal:
            return "tracking"
        case .notAvailable:
            return "unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing:
                return "initializing"
            case .relocalizing:
                return "relocalizing"
            case .excessiveMotion, .insufficientFeatures:
                return "limited"
            @unknown default:
                return "limited"
            }
        }
    }

    static func isStable(_ trackingState: ARCamera.TrackingState) -> Bool {
        if case .normal = trackingState {
            return true
        }
        return false
    }

    static func degrees(from radians: Float) -> Double {
        Double(radians) * 180 / Double.pi
    }

    static var lidarAssistAvailable: Bool {
        AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil
    }
}
#endif

private final class CaptureFeatureUnavailableDevicePoseRuntime: CaptureFeatureDevicePoseRuntime {
    var latestSnapshot = CaptureFeatureDevicePoseRuntimeSnapshot(
        status: .unavailable,
        sampleCount: 0,
        latestSample: nil,
        startedAt: nil,
        updatedAt: Date(),
        issueDescription: "Device pose capture is unavailable in this runtime.",
        lidarAssistAvailable: false,
        depthDataIncluded: false,
        worldAlignment: nil,
        trackingState: nil,
        motionStable: false,
        headingStable: false
    )

    var onSnapshotUpdated: (@Sendable (CaptureFeatureDevicePoseRuntimeSnapshot) -> Void)?

    func start(configuration _: CaptureFeatureDevicePoseRuntimeConfiguration) throws {
        onSnapshotUpdated?(latestSnapshot)
        throw CaptureFeatureDevicePoseRuntimeError.unavailable(
            latestSnapshot.issueDescription ?? "Device pose capture is unavailable in this runtime."
        )
    }

    func stop() {}
}

private extension String {
    var stockpileNonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
