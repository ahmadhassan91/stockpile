import AVFoundation
import SwiftUI
import StockpileCameraCapture
import StockpileCaptureFlow
import StockpileDesignSystem
import StockpileResultsUI
import UIKit

@MainActor
struct CaptureFeatureView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var store: CaptureFeatureStore

    init(store: CaptureFeatureStore) {
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        ZStack {
            CaptureFeatureBackground()
            contentContainer
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsActionBar {
                CaptureFeatureActionBar(
                    phase: store.phase,
                    actionHint: store.currentActionHint,
                    actionTitle: store.currentActionTitle,
                    action: store.performPrimaryAction
                )
            }
        }
        .animation(.easeInOut(duration: 0.22), value: store.phase)
    }

    @ViewBuilder
    private var contentContainer: some View {
        switch store.phase {
        case .verifiedResult, .reviewOnlyResult:
            if let result = store.currentResult {
                StockpileResultScreenView(model: result)
            } else {
                CaptureResultEmptyStateView(
                    phase: store.phase,
                    pileName: store.configuration.home.pileName
                )
            }
        case .blockedResult:
            ScrollView {
                VStack(alignment: .leading, spacing: StockpileSpacing.large) {
                    if let result = store.currentResult {
                        StockpileResultScreenView(
                            model: result,
                            usesScrollView: false
                        )
                    } else {
                        CaptureResultEmptyStateView(
                            phase: store.phase,
                            pileName: store.configuration.home.pileName
                        )
                        .padding(.horizontal, contentHorizontalPadding)
                    }

                    if let recaptureGuidance = store.currentRecaptureGuidance {
                        CaptureRecaptureChecklistView(content: recaptureGuidance)
                            .padding(.horizontal, contentHorizontalPadding)
                    }
                }
                .padding(.bottom, contentBottomPadding)
            }
            .scrollIndicators(.hidden)
        case .guidedCapture:
            CaptureGuidedStateView(
                preview: guidedCapturePreview,
                cameraState: liveCameraState,
                content: store.configuration.guidedCapture,
                sceneIntelligence: store.currentSceneIntelligence,
                primaryActionTitle: store.currentActionTitle,
                primaryAction: store.performPrimaryAction,
                restartAction: store.reset,
                fallbackMovie: fallbackMovieState,
                liveQuickEstimate: liveQuickVolumeReadout
            )
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: StockpileSpacing.large) {
                    CaptureFeatureHeroCard(
                        phase: store.phase,
                        home: store.configuration.home,
                        guidedCapture: store.configuration.guidedCapture
                    )

                    CaptureWorkflowStrip(phase: store.phase)

                    screenContent
                }
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.top, StockpileSpacing.medium)
                .padding(.bottom, contentBottomPadding)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var showsActionBar: Bool {
        switch store.phase {
        case .guidedCapture, .verifiedResult, .reviewOnlyResult:
            return false
        default:
            return true
        }
    }

    private var contentBottomPadding: CGFloat {
        switch store.phase {
        case .idle, .guidedCapture:
            return StockpileSpacing.xLarge
        case .uploadInProgress, .processing, .blockedResult:
            return StockpileSpacing.large
        case .verifiedResult, .reviewOnlyResult:
            return 0
        }
    }

    private var contentHorizontalPadding: CGFloat {
        horizontalSizeClass == .compact ? StockpileSpacing.medium : StockpileSpacing.large
    }

    private var guidedContentHorizontalPadding: CGFloat {
        horizontalSizeClass == .compact ? StockpileSpacing.small : StockpileSpacing.medium
    }

    @ViewBuilder
    private var screenContent: some View {
        switch store.phase {
        case .idle:
            CaptureIdleStateView(
                home: store.configuration.home,
                cameraState: liveCameraState,
                sceneIntelligence: store.currentSceneIntelligence,
                primaryActionTitle: store.currentActionTitle,
                liveCaptureHint: store.currentActionHint,
                startLiveCapture: store.performPrimaryAction,
                fallbackMovie: fallbackMovieState,
                liveQuickEstimate: liveQuickVolumeReadout
            )
        case .guidedCapture:
            CaptureGuidedStateView(
                preview: guidedCapturePreview,
                cameraState: liveCameraState,
                content: store.configuration.guidedCapture,
                sceneIntelligence: store.currentSceneIntelligence,
                primaryActionTitle: store.currentActionTitle,
                primaryAction: store.performPrimaryAction,
                restartAction: store.reset,
                fallbackMovie: fallbackMovieState,
                liveQuickEstimate: liveQuickVolumeReadout
            )
        case .uploadInProgress:
            CaptureProgressStateView(content: store.currentProgressContent)
        case .processing:
            if let provisionalResult = provisionalProcessingResult {
                StockpileResultScreenView(
                    model: provisionalResult,
                    usesScrollView: false
                )
            } else {
                CaptureProgressStateView(content: store.currentProgressContent)
            }
        case .verifiedResult, .reviewOnlyResult, .blockedResult:
            EmptyView()
        }
    }

    private var fallbackMovieState: CaptureFallbackMovieState? {
        guard store.configuration.pipeline.allowsImportedBackupVideo else {
            return nil
        }

        guard store.hasSelectedMovie || store.selectedMovieImportErrorMessage != nil else {
            return nil
        }

        return CaptureFallbackMovieState(
            title: store.selectedMovieDisplayName ?? "Recovery clip ready",
            message: store.selectedMovieStatusSummary,
            tone: store.selectedMovieImportErrorMessage == nil ? .caution : .critical
        )
    }

    private var guidedCapturePreview: CaptureGuidedPreviewState {
        Self.resolveGuidedPreviewState(from: store.livePreviewSource)
    }

    private var liveCameraState: StockpileCameraCaptureSessionState? {
        store.liveCameraState
    }

    /// Resolve the live LiDAR readout for the HUD card. Returns nil when the
    /// markerless capture mode is disabled or the ARKit pose runtime has not
    /// yet emitted an estimate, which keeps the v1 path's HUD untouched.
    private var liveQuickVolumeReadout: CaptureLiveQuickVolumeReadout? {
        guard store.isMarkerlessCaptureEnabled else {
            return nil
        }
        guard let estimate = store.latestQuickVolumeEstimate else {
            return nil
        }
        return CaptureLiveQuickVolumeReadout(
            volumeM3: estimate.volumeM3,
            footprintAreaM2: estimate.footprintAreaM2,
            peakHeightM: estimate.peakHeightM,
            confidencePercent: estimate.confidencePercentage
        )
    }

    private var provisionalProcessingResult: StockpileResultScreenModel? {
        guard store.phase == .processing else {
            return nil
        }

        return store.currentResult
    }

    private static func resolveGuidedPreviewState(
        from previewSource: (any CaptureFeatureLivePreviewSessionBridging)?
    ) -> CaptureGuidedPreviewState {
        guard let previewSource else {
            return CaptureGuidedPreviewState(
                captureSession: nil,
                badgeLabel: "Live camera missing",
                tone: .critical,
                title: "A live rear-camera session is required",
                message: "This run is not attached to an active rear-camera session yet, so in-app recording cannot begin until the live camera runtime is available.",
                systemImage: "camera.metering.unknown",
                metricItems: [
                    CaptureMetricItem(title: "Feed", value: "Not attached", note: "No live rear-camera session", displayStyle: .status),
                    CaptureMetricItem(title: "Guidance", value: "Waiting", note: "Live prompts start after camera attach", displayStyle: .status),
                    CaptureMetricItem(title: "Mode", value: "Live capture required", note: "No demo fallback in this flow", displayStyle: .status),
                ]
            )
        }

        let state = previewSource.livePreviewState
        let deviceLabel = state.activeDeviceName ?? "Rear camera"

        var metricItems = [
            CaptureMetricItem(
                title: "Lens",
                value: deviceLabel,
                note: state.permission.isGranted ? "Active device" : "Waiting for access",
                displayStyle: .status
            ),
            CaptureMetricItem(
                title: "Session",
                value: state.sessionStatusLabel,
                note: state.phase.title,
                displayStyle: .status
            ),
            CaptureMetricItem(
                title: "Recording",
                value: state.recordingStatusLabel,
                note: state.recordingOutput == nil ? "Awaiting sealed capture" : "Handoff file is ready",
                displayStyle: .status
            ),
        ]
        if let debugTraceSummary = state.debugTraceSummary,
           debugTraceSummary.isEmpty == false {
            metricItems.append(
                CaptureMetricItem(
                    title: "Trace",
                    value: state.operatorStageLabel,
                    note: debugTraceSummary,
                    displayStyle: .status
                )
            )
        }

        if let captureSession = previewSource.livePreviewCaptureSession,
           state.permission.isGranted,
           state.isPreviewAvailable {
            return CaptureGuidedPreviewState(
                captureSession: captureSession,
                badgeLabel: Self.livePreviewBadgeLabel(for: state),
                tone: Self.livePreviewTone(for: state),
                title: Self.livePreviewTitle(for: state),
                message: state.activePrompt,
                systemImage: Self.livePreviewSystemImage(for: state),
                metricItems: metricItems
            )
        }

        if let lastErrorDescription = state.lastErrorDescription, lastErrorDescription.isEmpty == false {
            return CaptureGuidedPreviewState(
                captureSession: nil,
                badgeLabel: "Camera failed",
                tone: .critical,
                title: "Camera preview is unavailable right now",
                message: lastErrorDescription,
                systemImage: "camera.badge.xmark",
                metricItems: metricItems
            )
        }

        if state.permission.requiresSettingsVisit {
            return CaptureGuidedPreviewState(
                captureSession: nil,
                badgeLabel: "Access blocked",
                tone: .critical,
                title: "Camera access is required to record in app",
                message: state.permission.operatorHint,
                systemImage: "camera.fill.badge.xmark",
                metricItems: metricItems
            )
        }

        if state.permission.canRequestAccess || state.permission.status == .notDetermined {
            return CaptureGuidedPreviewState(
                captureSession: nil,
                badgeLabel: "Needs access",
                tone: .caution,
                title: "Camera permission is still pending",
                message: "Allow camera access on this device to show the live preview and record the walkaround.",
                systemImage: "camera.badge.ellipsis",
                metricItems: metricItems
            )
        }

        if state.sessionLifecycle == .configuring || state.sessionLifecycle == .ready {
            return CaptureGuidedPreviewState(
                captureSession: nil,
                badgeLabel: "Opening",
                tone: .info,
                title: "Preparing the rear camera",
                message: "The preview will appear as soon as the rear camera finishes configuring.",
                systemImage: "camera.aperture",
                metricItems: metricItems
            )
        }

        return CaptureGuidedPreviewState(
            captureSession: nil,
            badgeLabel: "Stand by",
            tone: .info,
            title: "Live preview is waiting on the camera session",
            message: state.activePrompt,
            systemImage: "viewfinder.circle",
            metricItems: metricItems
        )
    }

    private static func livePreviewBadgeLabel(for state: StockpileCameraCaptureSessionState) -> String {
        switch state.operatorStage {
        case .failed:
            return "Recording failed"
        case .openingCamera:
            return "Starting"
        case .recordingLive:
            return "Recording live"
        case .readyToFinish, .recordingSaved:
            return "Ready to finish"
        default:
            return "Camera ready"
        }
    }

    private static func livePreviewTone(for state: StockpileCameraCaptureSessionState) -> StockpileStatusTone {
        switch state.operatorStage {
        case .failed:
            return .critical
        case .openingCamera:
            return .caution
        case .readyToFinish, .recordingSaved:
            return .success
        default:
            return .info
        }
    }

    private static func livePreviewTitle(for state: StockpileCameraCaptureSessionState) -> String {
        switch state.operatorStage {
        case .failed:
            return "Recording did not start"
        case .openingCamera:
            return "Starting the recording"
        case .recordingLive:
            return "Rear camera recording is live"
        case .readyToFinish:
            return "This pass is ready to finish"
        case .recordingSaved:
            return "Recording saved on device"
        default:
            return "Rear camera preview is ready"
        }
    }

    private static func livePreviewSystemImage(for state: StockpileCameraCaptureSessionState) -> String {
        switch state.operatorStage {
        case .failed:
            return "exclamationmark.circle.fill"
        case .openingCamera:
            return "record.circle"
        case .recordingLive:
            return "dot.radiowaves.left.and.right"
        case .readyToFinish, .recordingSaved:
            return "checkmark.circle.fill"
        default:
            return "camera.viewfinder"
        }
    }
}

private struct CaptureResultEmptyStateView: View {
    let phase: CaptureFeaturePhase
    let pileName: String

    var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.large) {
            StockpileCard(appearance: .outlined) {
                VStack(alignment: .leading, spacing: StockpileSpacing.large) {
                    HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                        VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                            Text("Result status")
                                .font(StockpileTypography.caption.font)
                                .foregroundStyle(StockpilePalette.mutedInk.color)

                            Text(title)
                                .font(StockpileTypography.sectionTitle.font)
                                .foregroundStyle(StockpilePalette.ink.color)
                        }

                        Spacer(minLength: 0)

                        StockpileBadge(badgeLabel, tone: badgeTone)
                    }

                    CaptureInlineStatusMessage(
                        title: pileName,
                        message: message,
                        tone: badgeTone,
                        systemImage: systemImage
                    )
                }
            }
        }
    }

    private var title: String {
        switch phase {
        case .verifiedResult:
            return "Waiting for the verified result payload"
        case .reviewOnlyResult:
            return "Waiting for the review payload"
        case .blockedResult:
            return "Capture stopped before a blocked result arrived"
        case .idle, .guidedCapture, .uploadInProgress, .processing:
            return "Result not ready"
        }
    }

    private var message: String {
        switch phase {
        case .verifiedResult, .reviewOnlyResult:
            return "The live run finished, but the server has not returned the final result details yet. Stay in the app and refresh once processing completes."
        case .blockedResult:
            return "The live run did not complete cleanly enough to produce a backend result payload. Use the recovery steps below, then retry the walkaround when the device and connection are ready."
        case .idle, .guidedCapture, .uploadInProgress, .processing:
            return "No result is available yet."
        }
    }

    private var badgeLabel: String {
        switch phase {
        case .verifiedResult:
            return "Pending verified"
        case .reviewOnlyResult:
            return "Pending review"
        case .blockedResult:
            return "Recovery needed"
        case .idle, .guidedCapture, .uploadInProgress, .processing:
            return "Pending"
        }
    }

    private var badgeTone: StockpileStatusTone {
        switch phase {
        case .blockedResult:
            return .critical
        case .verifiedResult, .reviewOnlyResult, .idle, .guidedCapture, .uploadInProgress, .processing:
            return .info
        }
    }

    private var systemImage: String {
        switch phase {
        case .verifiedResult, .reviewOnlyResult:
            return "clock.badge.checkmark"
        case .blockedResult:
            return "clock.badge.exclamationmark"
        case .idle, .guidedCapture, .uploadInProgress, .processing:
            return "hourglass"
        }
    }
}

private struct CaptureFallbackMovieState {
    let title: String
    let message: String
    let tone: StockpileStatusTone
}

private struct CaptureGuidedPreviewState {
    let captureSession: AVCaptureSession?
    let badgeLabel: String
    let tone: StockpileStatusTone
    let title: String
    let message: String
    let systemImage: String
    let metricItems: [CaptureMetricItem]

    var showsLivePreview: Bool {
        captureSession != nil
    }

    init(
        captureSession: AVCaptureSession?,
        badgeLabel: String,
        tone: StockpileStatusTone,
        title: String,
        message: String,
        systemImage: String,
        metricItems: [CaptureMetricItem]
    ) {
        self.captureSession = captureSession
        self.badgeLabel = badgeLabel
        self.tone = tone
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.metricItems = metricItems
    }
}

private struct CaptureActionConfiguration {
    let title: String
    let systemImage: String
    let action: () -> Void
    let isDisabled: Bool
}

private enum CaptureSystemActions {
    static func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        UIApplication.shared.open(settingsURL)
    }
}

private enum CaptureWorkflowStepStatus {
    case current
    case upcoming
    case complete

    var tone: StockpileStatusTone {
        switch self {
        case .current:
            return .info
        case .upcoming:
            return .caution
        case .complete:
            return .success
        }
    }

    var label: String {
        switch self {
        case .current:
            return "Now"
        case .upcoming:
            return "Next"
        case .complete:
            return "Done"
        }
    }

    var systemImage: String {
        switch self {
        case .current:
            return "arrow.right.circle.fill"
        case .upcoming:
            return "clock.fill"
        case .complete:
            return "checkmark.circle.fill"
        }
    }
}

private extension StockpileCameraOperatorStage {
    var statusTone: StockpileStatusTone {
        switch self {
        case .idle, .openingCamera, .recordingLive, .finalizingRecording:
            return .info
        case .permissionRequired:
            return .caution
        case .readyToFinish, .recordingSaved:
            return .success
        case .accessBlocked, .failed:
            return .critical
        }
    }
}

private extension GuidedCaptureCheckStatus {
    var statusTone: StockpileStatusTone {
        switch self {
        case .ready:
            return .success
        case .needsAttention:
            return .caution
        case .blocked:
            return .critical
        }
    }

    var systemImage: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .needsAttention:
            return "exclamationmark.triangle.fill"
        case .blocked:
            return "xmark.octagon.fill"
        }
    }
}

private struct CaptureWorkflowStep: Identifiable {
    let title: String
    let detail: String
    let status: CaptureWorkflowStepStatus

    var id: String { title }
}

private struct CaptureWorkflowStrip: View {
    let phase: CaptureFeaturePhase

    var body: some View {
        StockpileCard(appearance: .outlined) {
            VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                HStack(alignment: .center, spacing: StockpileSpacing.medium) {
                    VStack(alignment: .leading, spacing: StockpileSpacing.xxSmall) {
                        Text("Live flow")
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)

                        Text(summaryLine)
                            .font(StockpileTypography.callout.font.weight(.semibold))
                            .foregroundStyle(StockpilePalette.ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    StockpileBadge(stepLabel, tone: phase.badgeTone)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: StockpileSpacing.small) {
                        ForEach(steps) { step in
                            CaptureWorkflowStepCard(step: step)
                        }
                    }

                    VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                        ForEach(steps) { step in
                            CaptureWorkflowStepCard(step: step)
                        }
                    }
                }
            }
        }
    }

    private var steps: [CaptureWorkflowStep] {
        [
            CaptureWorkflowStep(
                title: "Record",
                detail: recordDetail,
                status: status(for: 0)
            ),
            CaptureWorkflowStep(
                title: "Seal",
                detail: sealDetail,
                status: status(for: 1)
            ),
            CaptureWorkflowStep(
                title: "Result",
                detail: resultDetail,
                status: status(for: 2)
            ),
        ]
    }

    private var recordDetail: String {
        switch phase {
        case .idle:
            return "Open the rear camera"
        case .guidedCapture:
            return "Walk one steady lap"
        default:
            return "Walkaround recorded"
        }
    }

    private var sealDetail: String {
        switch phase {
        case .idle, .guidedCapture:
            return "Finish when refs look locked"
        case .uploadInProgress, .processing:
            return "Handled automatically"
        default:
            return "Recording secured"
        }
    }

    private var resultDetail: String {
        switch phase {
        case .idle, .guidedCapture:
            return "Opens after checks"
        case .uploadInProgress:
            return "Checks come next"
        case .processing:
            return "Building now"
        case .verifiedResult, .reviewOnlyResult, .blockedResult:
            return "Ready"
        }
    }

    private var summaryLine: String {
        switch phase {
        case .idle:
            return "One in-app recording starts the run."
        case .guidedCapture:
            return "Stay on one clean lap until the pile reads ready."
        case .uploadInProgress:
            return "Your recorded pass is sealing and handing off automatically."
        case .processing:
            return "Server checks are building the result now."
        case .verifiedResult, .reviewOnlyResult, .blockedResult:
            return "The recorded pass is complete and ready to review."
        }
    }

    private var stepLabel: String {
        "Step \(phase.workflowStepIndex + 1) of 3"
    }

    private func status(for index: Int) -> CaptureWorkflowStepStatus {
        if index < phase.workflowStepIndex {
            return .complete
        }

        if index == phase.workflowStepIndex {
            return .current
        }

        return .upcoming
    }
}

private struct CaptureWorkflowStepCard: View {
    let step: CaptureWorkflowStep

    var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
            HStack(spacing: StockpileSpacing.xSmall) {
                Image(systemName: step.status.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(step.status.tone.theme.accent.color)

                Text(step.title.uppercased())
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Spacer(minLength: 0)

                Text(step.status.label)
                    .font(StockpileTypography.caption.font.weight(.semibold))
                    .foregroundStyle(step.status.tone.theme.accent.color)
            }

            Text(step.detail)
                .font(StockpileTypography.callout.font.weight(.semibold))
                .foregroundStyle(StockpilePalette.ink.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, StockpileSpacing.medium)
        .padding(.vertical, StockpileSpacing.small)
        .frame(minWidth: 118, maxWidth: .infinity, alignment: .leading)
        .background(
            step.status.tone.theme.background.color.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

private struct CaptureFeatureBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    StockpilePalette.canvas.color,
                    StockpilePalette.elevatedSurface.color.opacity(0.82),
                    StockpilePalette.surface.color.opacity(0.92)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RoundedRectangle(cornerRadius: 160, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            StockpilePalette.surface.color.opacity(0.55),
                            StockpilePalette.accent.color.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 420, height: 280)
                .rotationEffect(.degrees(-14))
                .blur(radius: 20)
                .offset(x: 170, y: -250)

            Circle()
                .fill(StockpilePalette.accent.color.opacity(0.12))
                .frame(width: 260, height: 260)
                .blur(radius: 42)
                .offset(x: 140, y: -160)

            Circle()
                .fill(StockpilePalette.success.color.opacity(0.10))
                .frame(width: 220, height: 220)
                .blur(radius: 36)
                .offset(x: -150, y: 240)
        }
        .ignoresSafeArea()
    }
}

private struct CaptureFeatureHeroCard: View {
    let phase: CaptureFeaturePhase
    let home: CaptureHomeContent
    let guidedCapture: GuidedCaptureContent

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: StockpileCornerRadius.card + 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            phase.badgeTone.theme.background.color,
                            StockpilePalette.surface.color,
                            StockpilePalette.elevatedSurface.color.opacity(0.9)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StockpileCornerRadius.card + 6, style: .continuous)
                        .stroke(StockpilePalette.border.color.opacity(0.8), lineWidth: 1)
                )
                .shadow(
                    color: StockpilePalette.ink.color.opacity(0.08),
                    radius: 20,
                    y: 12
                )

            Circle()
                .fill(phase.badgeTone.theme.accent.color.opacity(0.14))
                .frame(width: 210, height: 210)
                .blur(radius: 18)
                .offset(x: 65, y: -48)

            Circle()
                .fill(StockpilePalette.surface.color.opacity(0.7))
                .frame(width: 128, height: 128)
                .blur(radius: 6)
                .offset(x: 60, y: -36)

            VStack(alignment: .leading, spacing: StockpileSpacing.large) {
                HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                    VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                        StockpileBadge(phase.badgeLabel, tone: phase.badgeTone)

                        Text(contextLine)
                            .font(StockpileTypography.caption.font.weight(.semibold))
                            .foregroundStyle(StockpilePalette.mutedInk.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: phase.heroSystemImage)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(phase.badgeTone.theme.accent.color)
                        .frame(width: 54, height: 54)
                        .background(
                            phase.badgeTone.theme.background.color.opacity(0.96),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(phase.badgeTone.theme.accent.color.opacity(0.16), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    Text(phase.title)
                        .font(StockpileTypography.hero.font)
                        .foregroundStyle(StockpilePalette.ink.color)

                    Text(phase.summary)
                        .font(StockpileTypography.body.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: StockpileSpacing.small) {
                        ForEach(metadataItems) { item in
                            CaptureHeroMetadataPill(item: item)
                        }
                    }

                    VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                        ForEach(metadataItems) { item in
                            CaptureHeroMetadataPill(item: item)
                        }
                    }
                }
            }
            .padding(StockpileSpacing.large)
        }
    }

    private var contextLine: String {
        "\(home.siteName) • \(guidedCapture.sessionLabel)"
    }

    private var metadataItems: [CaptureHeroMetadata] {
        [
            CaptureHeroMetadata(
                title: "Pile",
                value: home.pileName,
                systemImage: "shippingbox.fill"
            ),
            CaptureHeroMetadata(
                title: "Material",
                value: home.materialName,
                systemImage: "cube.box.fill"
            )
        ]
    }
}

private struct CaptureIdleStateView: View {
    let home: CaptureHomeContent
    let cameraState: StockpileCameraCaptureSessionState?
    let sceneIntelligence: CaptureFeatureSceneIntelligence
    let primaryActionTitle: String
    let liveCaptureHint: String
    let startLiveCapture: () -> Void
    let fallbackMovie: CaptureFallbackMovieState?
    let liveQuickEstimate: CaptureLiveQuickVolumeReadout?

    var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.large) {
            CaptureLiveEntryCard(
                cameraState: cameraState,
                wrongSceneFeedback: sceneIntelligence.wrongSceneFeedback,
                primaryActionTitle: primaryActionTitle,
                liveCaptureHint: liveCaptureHint,
                startLiveCapture: startLiveCapture,
                liveQuickEstimate: liveQuickEstimate
            )

            CaptureReadinessCard(
                home: home,
                materialSuggestion: sceneIntelligence.materialSuggestion
            )

            if let fallbackMovie {
                CaptureFallbackMovieCard(state: fallbackMovie)
            }
        }
    }
}

private struct CaptureReadinessCard: View {
    let home: CaptureHomeContent
    let materialSuggestion: CaptureFeatureInlineStatusContent

    var body: some View {
        StockpileCard {
            VStack(alignment: .leading, spacing: StockpileSpacing.large) {
                HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                    VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                        Text("Before you record")
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)

                        Text(home.readinessHeadline)
                            .font(StockpileTypography.sectionTitle.font)
                            .foregroundStyle(StockpilePalette.ink.color)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "checklist.checked")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(StockpilePalette.accent.color)
                        .frame(width: 46, height: 46)
                        .background(
                            StockpilePalette.accent.color.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }

                CaptureInlineStatusMessage(
                    title: "Run context confirmed",
                    message: home.readinessSummary,
                    tone: .info,
                    systemImage: "viewfinder.circle.fill"
                )

                CaptureInlineStatusMessage(
                    title: materialSuggestion.title,
                    message: materialSuggestion.message,
                    tone: materialSuggestion.tone,
                    systemImage: materialSuggestion.systemImage
                )

                CaptureContextGrid(
                    items: [
                        CaptureContextItem(
                            title: "Site",
                            value: home.siteName,
                            systemImage: "building.2.fill"
                        ),
                        CaptureContextItem(
                            title: "Pile",
                            value: home.pileName,
                            systemImage: "shippingbox.fill"
                        ),
                        CaptureContextItem(
                            title: "Material",
                            value: home.materialName,
                            systemImage: "cube.box.fill"
                        )
                    ]
                )

                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    Text("Three quick checks")
                        .font(StockpileTypography.callout.font.weight(.semibold))
                        .foregroundStyle(StockpilePalette.ink.color)

                    ForEach(Array(home.quickTips.prefix(3).enumerated()), id: \.offset) { index, item in
                        CaptureEssentialRow(
                            index: index + 1,
                            text: item
                        )
                    }
                }
            }
        }
    }
}

private struct CaptureContextItem: Identifiable {
    let title: String
    let value: String
    let systemImage: String

    var id: String { title }
}

private struct CaptureContextGrid: View {
    let items: [CaptureContextItem]

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 150), spacing: StockpileSpacing.medium)
            ],
            spacing: StockpileSpacing.medium
        ) {
            ForEach(items) { item in
                CaptureContextCard(item: item)
            }
        }
    }
}

private struct CaptureContextCard: View {
    let item: CaptureContextItem

    var body: some View {
        HStack(alignment: .top, spacing: StockpileSpacing.small) {
            Image(systemName: item.systemImage)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(StockpilePalette.accent.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.uppercased())
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Text(item.value)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, StockpileSpacing.medium)
        .padding(.vertical, StockpileSpacing.small)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .background(
            StockpilePalette.canvas.color.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StockpilePalette.border.color.opacity(0.5), lineWidth: 1)
        )
    }
}

private struct CaptureEssentialRow: View {
    let index: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: StockpileSpacing.small) {
            Text("\(index)")
                .font(StockpileTypography.caption.font.weight(.semibold))
                .foregroundStyle(StockpilePalette.accent.color)
                .frame(width: 22, height: 22)
                .background(StockpilePalette.accent.color.opacity(0.12), in: Circle())

            Text(text)
                .font(StockpileTypography.body.font)
                .foregroundStyle(StockpilePalette.ink.color)

            Spacer(minLength: 0)
        }
    }
}

private struct CaptureLiveEntryCard: View {
    let cameraState: StockpileCameraCaptureSessionState?
    let wrongSceneFeedback: CaptureFeatureInlineStatusContent?
    let primaryActionTitle: String
    let liveCaptureHint: String
    let startLiveCapture: () -> Void
    let liveQuickEstimate: CaptureLiveQuickVolumeReadout?

    var body: some View {
        StockpileCard(appearance: .outlined) {
            VStack(alignment: .leading, spacing: StockpileSpacing.large) {
                HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                    VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                        Text("Live recording")
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)

                        Text("Start one clean walkaround in app")
                            .font(StockpileTypography.sectionTitle.font)
                            .foregroundStyle(StockpilePalette.ink.color)
                    }

                    Spacer(minLength: 0)

                    StockpileBadge("Primary path", tone: .success)
                }

                if let cameraState {
                    CaptureLiveSessionStatusCard(
                        state: cameraState,
                        heading: "Camera state",
                        wrongSceneFeedback: wrongSceneFeedback
                    )
                } else {
                    CaptureInlineStatusMessage(
                        title: "Start one clean perimeter sweep",
                        message: liveCaptureHint,
                        tone: .info,
                        systemImage: "record.circle.fill"
                    )
                }

                if let liveQuickEstimate {
                    CaptureLiveVolumeReadoutCard(readout: liveQuickEstimate)
                }

                CaptureInstructionGrid(
                    items: [
                        CaptureInstructionItem(
                            title: "Camera",
                            headline: "Rear wide lens",
                            detail: "Record the full walkaround in the app.",
                            systemImage: "camera.aperture",
                            tone: .info
                        ),
                        CaptureInstructionItem(
                            title: "Pass",
                            headline: "One steady lap",
                            detail: "Follow the toe boundary without cutting corners.",
                            systemImage: "figure.walk.motion",
                            tone: .caution
                        ),
                        CaptureInstructionItem(
                            title: "Finish",
                            headline: "Auto handoff",
                            detail: "Upload begins automatically once the lap is sealed.",
                            systemImage: "arrow.up.circle",
                            tone: .success
                        )
                    ]
                )

                Button(action: primaryActionConfiguration.action) {
                    HStack(spacing: StockpileSpacing.small) {
                        Image(systemName: primaryActionConfiguration.systemImage)
                        Text(primaryActionConfiguration.title)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(primaryActionConfiguration.isDisabled)
                .buttonStyle(StockpileActionButtonStyle(role: .primary))
            }
        }
    }

    private var primaryActionConfiguration: CaptureActionConfiguration {
        guard let cameraState else {
            return CaptureActionConfiguration(
                title: primaryActionTitle,
                systemImage: "record.circle.fill",
                action: startLiveCapture,
                isDisabled: false
            )
        }

        switch cameraState.operatorStage {
        case .accessBlocked:
            return CaptureActionConfiguration(
                title: "Open Settings",
                systemImage: "gearshape.fill",
                action: CaptureSystemActions.openAppSettings,
                isDisabled: false
            )
        case .openingCamera, .finalizingRecording:
            return CaptureActionConfiguration(
                title: primaryActionTitle,
                systemImage: cameraState.operatorSystemImage,
                action: {},
                isDisabled: true
            )
        case .failed:
            return CaptureActionConfiguration(
                title: "Retry camera",
                systemImage: "arrow.clockwise.circle.fill",
                action: startLiveCapture,
                isDisabled: false
            )
        case .permissionRequired:
            return CaptureActionConfiguration(
                title: primaryActionTitle,
                systemImage: cameraState.operatorSystemImage,
                action: startLiveCapture,
                isDisabled: false
            )
        case .idle, .recordingLive, .readyToFinish, .recordingSaved:
            return CaptureActionConfiguration(
                title: primaryActionTitle,
                systemImage: "record.circle.fill",
                action: startLiveCapture,
                isDisabled: false
            )
        }
    }
}

private struct CaptureFallbackMovieCard: View {
    let state: CaptureFallbackMovieState

    var body: some View {
        StockpileCard(appearance: .outlined) {
            VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                    VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                        Text("Internal recovery")
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)

                        Text(state.title)
                            .font(StockpileTypography.sectionTitle.font)
                            .foregroundStyle(StockpilePalette.ink.color)
                    }

                    Spacer(minLength: 0)

                    StockpileBadge("Internal only", tone: state.tone)
                }

                Text(state.message)
                    .font(StockpileTypography.body.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
            }
        }
    }
}

private extension GuidedCaptureContent {
    var focusedChecklistContent: CaptureChecklistContent? {
        let prioritizedItems = checklistContent.highlightedItems
        guard prioritizedItems.isEmpty == false, isReadyToFinish == false else {
            return nil
        }

        return CaptureChecklistContent(
            title: checklistContent.title,
            summary: checklistContent.summary,
            items: prioritizedItems
        )
    }
}

private struct CaptureReadyToFinishCard: View {
    var body: some View {
        StockpileGuidanceBanner(
            title: "Capture looks strong",
            message: "References, coverage, and stability look strong enough to seal this pass and start the automatic handoff.",
            tone: .success
        )
    }
}

private struct CaptureRecordingStep: Identifiable {
    let title: String
    let detail: String
    let status: CaptureWorkflowStepStatus

    var id: String { title }
}

private struct CaptureRecordingStepStrip: View {
    let preview: CaptureGuidedPreviewState
    let cameraState: StockpileCameraCaptureSessionState?
    let content: GuidedCaptureContent

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StockpileSpacing.small) {
                ForEach(steps) { step in
                    CaptureRecordingStepCard(step: step)
                }
            }

            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                ForEach(steps) { step in
                    CaptureRecordingStepCard(step: step)
                }
            }
        }
    }

    private var steps: [CaptureRecordingStep] {
        [
            CaptureRecordingStep(
                title: "Camera",
                detail: cameraDetail,
                status: cameraStatus
            ),
            CaptureRecordingStep(
                title: "Lap",
                detail: lapDetail,
                status: lapStatus
            ),
            CaptureRecordingStep(
                title: "Finish",
                detail: finishDetail,
                status: finishStatus
            ),
        ]
    }

    private var cameraStatus: CaptureWorkflowStepStatus {
        cameraReady ? .complete : .current
    }

    private var lapStatus: CaptureWorkflowStepStatus {
        if content.isReadyToFinish {
            return .complete
        }

        return cameraReady ? .current : .upcoming
    }

    private var finishStatus: CaptureWorkflowStepStatus {
        finishIsUnlocked ? .current : .upcoming
    }

    private var cameraReady: Bool {
        if let cameraState {
            switch cameraState.operatorStage {
            case .idle, .recordingLive, .readyToFinish, .finalizingRecording, .recordingSaved:
                return true
            case .permissionRequired, .accessBlocked, .openingCamera, .failed:
                return false
            }
        }

        return preview.showsLivePreview
    }

    private var finishIsUnlocked: Bool {
        if content.isReadyToFinish {
            return true
        }

        if let cameraState {
            switch cameraState.operatorStage {
            case .readyToFinish, .finalizingRecording, .recordingSaved:
                return true
            default:
                return false
            }
        }

        return false
    }

    private var cameraDetail: String {
        if let cameraState {
            switch cameraState.operatorStage {
            case .permissionRequired:
                return "Allow rear-camera access"
            case .accessBlocked:
                return "Open Settings to continue"
            case .openingCamera:
                return "Opening rear camera"
            case .failed:
                return "Restart the camera"
            case .idle, .recordingLive, .readyToFinish, .finalizingRecording, .recordingSaved:
                return "Rear camera is ready"
            }
        }

        return preview.showsLivePreview ? "Preview is live" : preview.badgeLabel
    }

    private var lapDetail: String {
        content.isReadyToFinish ? "Perimeter looks covered" : "Keep one steady lap going"
    }

    private var finishDetail: String {
        finishIsUnlocked ? "Seal and continue automatically" : "Unlocks when coverage is strong"
    }
}

private struct CaptureRecordingStepCard: View {
    let step: CaptureRecordingStep

    var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.xxSmall) {
            HStack(spacing: StockpileSpacing.xSmall) {
                Image(systemName: step.status.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(step.status.tone.theme.accent.color)

                Text(step.title.uppercased())
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Spacer(minLength: 0)
            }

            Text(step.detail)
                .font(StockpileTypography.callout.font.weight(.semibold))
                .foregroundStyle(StockpilePalette.ink.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, StockpileSpacing.medium)
        .padding(.vertical, StockpileSpacing.small)
        .frame(minWidth: 132, maxWidth: .infinity, alignment: .leading)
        .background(
            step.status.tone.theme.background.color.opacity(0.68),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

private struct CaptureLiveSessionStatusCard: View {
    let state: StockpileCameraCaptureSessionState
    let heading: String
    let wrongSceneFeedback: CaptureFeatureInlineStatusContent?

    var body: some View {
        StockpileCard(appearance: .outlined) {
            VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                    VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                        Text(heading)
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)

                        Text(state.operatorHeadline)
                            .font(StockpileTypography.callout.font.weight(.semibold))
                            .foregroundStyle(StockpilePalette.ink.color)
                    }

                    Spacer(minLength: 0)

                    StockpileBadge(state.operatorStageLabel, tone: state.operatorStage.statusTone)
                }

                CaptureInlineStatusMessage(
                    title: state.statusLabel,
                    message: state.operatorStageDetail,
                    tone: state.operatorStage.statusTone,
                    systemImage: state.operatorSystemImage
                )

                if let wrongSceneFeedback {
                    CaptureInlineStatusMessage(
                        title: wrongSceneFeedback.title,
                        message: wrongSceneFeedback.message,
                        tone: wrongSceneFeedback.tone,
                        systemImage: wrongSceneFeedback.systemImage
                    )
                }

                if let sensorHealth = sensorHealthSummary {
                    CaptureInlineStatusMessage(
                        title: sensorHealth.title,
                        message: sensorHealth.message,
                        tone: sensorHealth.tone,
                        systemImage: sensorHealth.systemImage
                    )
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                        ForEach(subsystemItems) { item in
                            CaptureSubsystemStatusCard(item: item)
                        }
                    }

                    VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                        ForEach(subsystemItems) { item in
                            CaptureSubsystemStatusCard(item: item)
                        }
                    }
                }

                if state.operatorShowsIndeterminateActivity {
                    HStack(spacing: StockpileSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(state.operatorStage.statusTone.theme.accent.color)

                        Text(state.operatorProgressLabel ?? state.recordingStatusLabel)
                            .font(StockpileTypography.callout.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)
                    }
                } else if let progressValue = state.operatorProgressValue {
                    VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                        HStack(alignment: .center, spacing: StockpileSpacing.small) {
                            Text(state.operatorProgressLabel ?? "Capture progress")
                                .font(StockpileTypography.callout.font.weight(.semibold))
                                .foregroundStyle(StockpilePalette.ink.color)

                            Spacer(minLength: 0)

                            if let progressSummary = state.operatorProgressSummary {
                                StockpileBadge(progressSummary, tone: state.operatorStage.statusTone)
                            }
                        }

                        ProgressView(value: progressValue)
                            .tint(state.operatorStage.statusTone.theme.accent.color)
                    }
                }

                CaptureMetricGrid(items: metricItems)
            }
        }
    }

    private var subsystemItems: [CaptureSubsystemStatusItem] {
        [
            CaptureSubsystemStatusItem(
                title: "Session",
                value: state.sessionStatusLabel,
                note: state.statusLabel,
                tone: subsystemTone(for: state.sessionStatusLabel)
            ),
            CaptureSubsystemStatusItem(
                title: "Recorder",
                value: state.recordingStatusLabel,
                note: state.operatorProgressLabel ?? state.operatorStageDetail,
                tone: subsystemTone(for: state.recordingStatusLabel)
            ),
        ]
    }

    private var metricItems: [CaptureMetricItem] {
        var items: [CaptureMetricItem] = []

        if let activeDeviceName = state.activeDeviceName {
            items.append(
                CaptureMetricItem(
                    title: "Camera",
                    value: activeDeviceName,
                    note: "Rear camera feed",
                    displayStyle: .status
                )
            )
        }

        if let sensorSnapshot = state.sensorSnapshot {
            items.append(
                CaptureMetricItem(
                    title: "Tracking",
                    value: trackingValue(for: sensorSnapshot),
                    note: sensorSnapshot.trackingState?.replacingOccurrences(of: "_", with: " "),
                    displayStyle: .status
                )
            )
            items.append(
                CaptureMetricItem(
                    title: "Motion",
                    value: sensorSnapshot.motionStable ? "Stable" : "Needs settle",
                    note: sensorSnapshot.sensorMetadata?.poseSamplingHz.map { "\($0.formatted(.number.precision(.fractionLength(0)))) Hz sampling" } ?? "Live motion guidance",
                    displayStyle: .status
                )
            )
            items.append(
                CaptureMetricItem(
                    title: "LiDAR",
                    value: sensorSnapshot.lidarAssistAvailable ? "Available" : "Optional",
                    note: sensorSnapshot.sensorMetadata?.depthDataIncluded == true
                        ? "Depth assist is active"
                        : "Capture still works without depth",
                    displayStyle: .status
                )
            )
        }

        return items
    }

    private func subsystemTone(for value: String) -> StockpileStatusTone {
        let normalized = value.lowercased()
        if normalized.contains("interrupt") || normalized.contains("unavailable") || normalized.contains("blocked") {
            return .critical
        }
        if normalized.contains("waiting") || normalized.contains("pending") || normalized.contains("ready") == false {
            return .caution
        }
        return .info
    }

    private var sensorHealthSummary: CaptureSensorHealthSummary? {
        guard let sensorSnapshot = state.sensorSnapshot else {
            return nil
        }

        if sensorSnapshot.motionSignalsIncluded == false {
            return CaptureSensorHealthSummary(
                title: "Motion guidance unavailable",
                message: "Rear-camera recording still works, but the app cannot score device stability yet.",
                tone: .caution,
                systemImage: "waveform.path.ecg"
            )
        }

        if sensorSnapshot.motionStable == false {
            return CaptureSensorHealthSummary(
                title: "Steady the device",
                message: "Slow down and keep the phone level so the walkaround stays reconstruction-ready.",
                tone: .caution,
                systemImage: "hand.raised.fill"
            )
        }

        if sensorSnapshot.headingSignalsIncluded && sensorSnapshot.headingStable == false {
            return CaptureSensorHealthSummary(
                title: "Let tracking settle",
                message: "Hold the phone steady for a moment so pose and direction stabilize before you continue.",
                tone: .caution,
                systemImage: "location.north.line.fill"
            )
        }

        if sensorSnapshot.lidarAssistAvailable == false {
            return CaptureSensorHealthSummary(
                title: "LiDAR is optional here",
                message: "This pass can still complete, but keep tagged references and the full toe clearly visible together.",
                tone: .info,
                systemImage: "sensor.tag.radiowaves.forward"
            )
        }

        return CaptureSensorHealthSummary(
            title: "Capture health looks good",
            message: "Motion, tracking, and depth assist are aligned for a strong guided pass.",
            tone: .success,
            systemImage: "checkmark.circle.fill"
        )
    }

    private func trackingValue(for sensorSnapshot: StockpileCaptureSensorSnapshot) -> String {
        guard let trackingState = sensorSnapshot.trackingState else {
            return "Unknown"
        }

        switch trackingState {
        case let value where value.contains("ready"):
            return "Ready"
        case let value where value.contains("active"):
            return "Active"
        case let value where value.contains("settle"):
            return "Settling"
        case let value where value.contains("unavailable"):
            return "Offline"
        default:
            return trackingState.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private struct CaptureSensorHealthSummary {
    let title: String
    let message: String
    let tone: StockpileStatusTone
    let systemImage: String
}

private struct CaptureSubsystemStatusItem: Identifiable {
    let title: String
    let value: String
    let note: String?
    let tone: StockpileStatusTone

    var id: String { title }
}

private struct CaptureSubsystemStatusCard: View {
    let item: CaptureSubsystemStatusItem

    var body: some View {
        let theme = item.tone.theme

        VStack(alignment: .leading, spacing: StockpileSpacing.small) {
            Text(item.title.uppercased())
                .font(StockpileTypography.caption.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)

            Text(item.value)
                .font(StockpileTypography.sectionTitle.font.weight(.semibold))
                .foregroundStyle(StockpilePalette.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            if let note = item.note, note.isEmpty == false {
                Text(note)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(StockpileSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.background.color.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(StockpilePalette.border.color.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct CaptureGuidedStateView: View {
    let preview: CaptureGuidedPreviewState
    let cameraState: StockpileCameraCaptureSessionState?
    let content: GuidedCaptureContent
    let sceneIntelligence: CaptureFeatureSceneIntelligence
    let primaryActionTitle: String
    let primaryAction: () -> Void
    let restartAction: () -> Void
    let fallbackMovie: CaptureFallbackMovieState?
    let liveQuickEstimate: CaptureLiveQuickVolumeReadout?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                CaptureFieldPreviewSurface(preview: preview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .top)

                CaptureFieldCameraShade()

                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    CaptureFieldTopOverlay(
                        preview: preview,
                        cameraState: cameraState,
                        content: content,
                        sceneIntelligence: sceneIntelligence
                    )
                    .padding(.horizontal, StockpileSpacing.medium)
                    .padding(.top, StockpileSpacing.small)

                    if let liveQuickEstimate {
                        CaptureLiveVolumeOverlayCard(readout: liveQuickEstimate)
                            .padding(.horizontal, StockpileSpacing.medium)
                    }

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    CaptureGuidedBottomPanel(
                        preview: preview,
                        cameraState: cameraState,
                        content: content,
                        sceneIntelligence: sceneIntelligence,
                        primaryActionTitle: primaryActionTitle,
                        primaryAction: primaryAction,
                        restartAction: restartAction
                    )

                    if let fallbackMovie {
                        CaptureFallbackMovieCard(state: fallbackMovie)
                    }
                }
                .padding(.horizontal, bottomPanelHorizontalPadding(for: geometry.size.width))
                .padding(.bottom, bottomPanelPadding(for: geometry.size.height))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black)
        }
    }

    private func bottomPanelHorizontalPadding(for width: CGFloat) -> CGFloat {
        width < 390 ? StockpileSpacing.small : StockpileSpacing.medium
    }

    private func bottomPanelPadding(for height: CGFloat) -> CGFloat {
        if height < 760 {
            return StockpileSpacing.xSmall
        }

        return StockpileSpacing.small
    }
}

private struct CaptureFieldPreviewSurface: View {
    let preview: CaptureGuidedPreviewState

    var body: some View {
        Group {
            if let captureSession = preview.captureSession, preview.showsLivePreview {
                CaptureLiveCameraPreviewRepresentable(captureSession: captureSession)
            } else {
                CaptureLivePreviewUnavailableSurface(preview: preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipped()
    }
}

private struct CaptureFieldCameraShade: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.34), location: 0.0),
                .init(color: Color.clear, location: 0.20),
                .init(color: Color.clear, location: 0.46),
                .init(color: Color.black.opacity(0.70), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

private struct CaptureFieldTopOverlay: View {
    let preview: CaptureGuidedPreviewState
    let cameraState: StockpileCameraCaptureSessionState?
    let content: GuidedCaptureContent
    let sceneIntelligence: CaptureFeatureSceneIntelligence

    var body: some View {
        HStack(spacing: StockpileSpacing.small) {
            Label(statusLabel, systemImage: systemImage)
                .font(StockpileTypography.caption.font.weight(.semibold))
                .foregroundStyle(tone.theme.accent.color)
                .lineLimit(1)
                .padding(.horizontal, StockpileSpacing.medium)
                .padding(.vertical, StockpileSpacing.xSmall)
                .background(
                    tone.theme.background.color.opacity(0.92),
                    in: Capsule(style: .continuous)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )

            Spacer(minLength: 0)
        }
    }

    private var statusLabel: String {
        guard preview.showsLivePreview else {
            return preview.badgeLabel
        }

        if cameraState?.operatorStage == .failed {
            return "Retry needed"
        }

        switch sceneIntelligence.wrongSceneLevel {
        case .blocked:
            return "Wrong scene"
        case .watch:
            return "Reframe"
        case .none:
            break
        }

        if content.isReadyToFinish {
            return "Ready to finish"
        }

        switch cameraState?.operatorStage {
        case .recordingLive:
            return "Recording"
        case .openingCamera:
            return "Opening camera"
        case .readyToFinish, .recordingSaved:
            return "Ready to finish"
        default:
            return preview.badgeLabel
        }
    }

    private var tone: StockpileStatusTone {
        guard preview.showsLivePreview else {
            return preview.tone
        }

        if cameraState?.operatorStage == .failed {
            return .critical
        }

        if content.isReadyToFinish {
            return .success
        }

        switch sceneIntelligence.wrongSceneLevel {
        case .blocked:
            return .critical
        case .watch:
            return .caution
        case .none:
            return cameraState?.operatorStage.statusTone ?? preview.tone
        }
    }

    private var systemImage: String {
        guard preview.showsLivePreview else {
            return preview.systemImage
        }

        if cameraState?.operatorStage == .failed {
            return "exclamationmark.circle.fill"
        }

        switch sceneIntelligence.wrongSceneLevel {
        case .blocked, .watch:
            return "viewfinder"
        case .none:
            break
        }

        if content.isReadyToFinish {
            return "checkmark.circle.fill"
        }

        switch cameraState?.operatorStage {
        case .recordingLive:
            return "record.circle.fill"
        case .openingCamera:
            return "camera.aperture"
        default:
            return preview.systemImage
        }
    }
}

private struct CaptureGuidedBottomPanel: View {
    let preview: CaptureGuidedPreviewState
    let cameraState: StockpileCameraCaptureSessionState?
    let content: GuidedCaptureContent
    let sceneIntelligence: CaptureFeatureSceneIntelligence
    let primaryActionTitle: String
    let primaryAction: () -> Void
    let restartAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.small) {
            HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
                    Text(panelEyebrow)
                        .font(StockpileTypography.caption.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)

                    Text(panelHeadline)
                        .font(StockpileTypography.sectionTitle.font)
                        .foregroundStyle(StockpilePalette.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                StockpileBadge(panelBadgeLabel, tone: panelTone)
            }

            HStack(alignment: .top, spacing: StockpileSpacing.small) {
                Image(systemName: panelSystemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(panelTone.theme.accent.color)
                    .padding(.top, 1)

                Text(panelMessage)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)

                Spacer(minLength: 0)
            }

            actionButtons
        }
        .padding(.horizontal, StockpileSpacing.medium)
        .padding(.vertical, StockpileSpacing.small)
        .background(
            StockpilePalette.surface.color.opacity(0.92),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(StockpilePalette.border.color.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: StockpilePalette.ink.color.opacity(0.10), radius: 16, x: 0, y: 10)
    }

    private var panelEyebrow: String {
        guard preview.showsLivePreview else {
            return "Camera status"
        }

        if cameraState?.operatorStage == .failed {
            return "Capture needs attention"
        }

        switch cameraState?.operatorStage {
        case .recordingLive:
            return "Live capture"
        case .readyToFinish, .recordingSaved:
            return "Capture ready"
        case .failed:
            return "Capture needs attention"
        default:
            return "Capture guidance"
        }
    }

    private var panelHeadline: String {
        guard preview.showsLivePreview else {
            return preview.title
        }

        if cameraState?.operatorStage == .failed {
            return "Recording did not start"
        }

        switch sceneIntelligence.wrongSceneLevel {
        case .blocked:
            return "Wrong scene likely"
        case .watch:
            return "Reframe on the pile"
        case .none:
            break
        }

        if content.isReadyToFinish {
            return "Ready to finish"
        }

        if content.checklistContent.isBlocked {
            return "Adjust this pass"
        }

        return "Keep one steady lap"
    }

    private var panelBadgeLabel: String {
        guard preview.showsLivePreview else {
            return preview.badgeLabel
        }

        if cameraState?.operatorStage == .failed {
            return "Hold"
        }

        switch sceneIntelligence.wrongSceneLevel {
        case .blocked:
            return "Wrong scene"
        case .watch:
            return "Reframe"
        case .none:
            break
        }

        if content.isReadyToFinish {
            return "Ready"
        }

        if content.checklistContent.isBlocked {
            return "Adjust"
        }

        switch cameraState?.operatorStage {
        case .recordingLive:
            return "Recording"
        case .failed:
            return "Hold"
        default:
            return "Watch"
        }
    }

    private var panelTone: StockpileStatusTone {
        guard preview.showsLivePreview else {
            return preview.tone
        }

        if cameraState?.operatorStage == .failed {
            return .critical
        }

        if content.isReadyToFinish {
            return .success
        }

        switch sceneIntelligence.wrongSceneLevel {
        case .blocked:
            return .critical
        case .watch:
            return .caution
        case .none:
            break
        }

        if content.checklistContent.isBlocked {
            return .caution
        }

        return .info
    }

    private var panelMessage: String {
        guard preview.showsLivePreview else {
            return preview.message
        }

        if cameraState?.operatorStage == .failed {
            return cameraState?.lastErrorDescription
                ?? cameraState?.operatorStageDetail
                ?? "Restart recording. If it happens again, restart the camera and keep the phone unlocked."
        }

        if let wrongSceneFeedback = sceneIntelligence.wrongSceneFeedback {
            return wrongSceneFeedback.message
        }

        return content.activePrompt.isEmpty
            ? (content.focusedChecklistContent?.primaryOperatorAction ?? "Keep the pile centered and walk the toe boundary steadily.")
            : content.activePrompt
    }

    private var panelSystemImage: String {
        guard preview.showsLivePreview else {
            return preview.systemImage
        }

        if cameraState?.operatorStage == .failed {
            return "exclamationmark.circle.fill"
        }

        if let wrongSceneFeedback = sceneIntelligence.wrongSceneFeedback {
            return wrongSceneFeedback.systemImage
        }

        if content.isReadyToFinish {
            return "checkmark.circle.fill"
        }

        if content.checklistContent.isBlocked || cameraState?.operatorStage == .failed {
            return "exclamationmark.circle.fill"
        }

        return "dot.radiowaves.left.and.right"
    }

    @ViewBuilder
    private var actionButtons: some View {
        if showsPrimaryActionButton || showsRestartAction {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: StockpileSpacing.medium) {
                    if showsPrimaryActionButton {
                        primaryActionButton
                    }
                    if showsRestartAction {
                        restartActionButton
                    }
                }

                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    if showsPrimaryActionButton {
                        primaryActionButton
                    }
                    if showsRestartAction {
                        restartActionButton
                    }
                }
            }
        }
    }

    private var primaryActionButton: some View {
        Button(action: primaryActionConfiguration.action) {
            HStack(spacing: StockpileSpacing.small) {
                Image(systemName: primaryActionConfiguration.systemImage)
                Text(primaryActionConfiguration.title)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 156, maxWidth: .infinity)
        .disabled(primaryActionConfiguration.isDisabled)
        .buttonStyle(StockpileActionButtonStyle(role: .primary))
    }

    private var restartActionButton: some View {
        Button(action: restartAction) {
            HStack(spacing: StockpileSpacing.small) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                Text(restartActionTitle)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 156, maxWidth: .infinity)
        .buttonStyle(StockpileActionButtonStyle(role: .secondary))
    }

    private var restartActionTitle: String {
        guard let cameraState else {
            return "Restart capture"
        }

        switch cameraState.operatorStage {
        case .openingCamera, .failed:
            return "Restart camera"
        case .idle, .permissionRequired, .accessBlocked, .recordingLive, .readyToFinish, .finalizingRecording, .recordingSaved:
            return "Restart capture"
        }
    }

    private var primaryActionConfiguration: CaptureActionConfiguration {
        if let cameraState {
            switch cameraState.operatorStage {
            case .accessBlocked:
                return CaptureActionConfiguration(
                    title: "Open Settings",
                    systemImage: "gearshape.fill",
                    action: CaptureSystemActions.openAppSettings,
                    isDisabled: false
                )
            case .openingCamera, .finalizingRecording:
                return CaptureActionConfiguration(
                    title: primaryActionTitle,
                    systemImage: cameraState.operatorSystemImage,
                    action: {},
                    isDisabled: true
                )
            case .failed:
                return CaptureActionConfiguration(
                    title: "Restart recording",
                    systemImage: "arrow.clockwise.circle.fill",
                    action: primaryAction,
                    isDisabled: false
                )
            case .readyToFinish, .recordingSaved:
                return CaptureActionConfiguration(
                    title: primaryActionTitle,
                    systemImage: "checkmark.circle.fill",
                    action: primaryAction,
                    isDisabled: false
                )
            case .permissionRequired:
                return CaptureActionConfiguration(
                    title: primaryActionTitle,
                    systemImage: cameraState.operatorSystemImage,
                    action: primaryAction,
                    isDisabled: false
                )
            case .idle, .recordingLive:
                return CaptureActionConfiguration(
                    title: "Keep recording",
                    systemImage: "record.circle.fill",
                    action: {},
                    isDisabled: true
                )
            }
        }

        return CaptureActionConfiguration(
            title: primaryActionTitle,
            systemImage: content.isReadyToFinish ? "checkmark.circle.fill" : "record.circle.fill",
            action: primaryAction,
            isDisabled: false
        )
    }

    private var showsPrimaryActionButton: Bool {
        guard let cameraState else {
            return false
        }

        switch cameraState.operatorStage {
        case .permissionRequired, .accessBlocked, .readyToFinish, .recordingSaved, .failed:
            return true
        case .openingCamera:
            return true
        case .recordingLive:
            return false
        case .idle, .finalizingRecording:
            return false
        }
    }

    private var showsRestartAction: Bool {
        guard let cameraState else {
            return true
        }

        switch cameraState.operatorStage {
        case .permissionRequired, .accessBlocked, .finalizingRecording:
            return false
        case .idle, .openingCamera, .recordingLive, .readyToFinish, .recordingSaved, .failed:
            return true
        }
    }
}

private struct CaptureGuidedMaterialSuggestionView: View {
    let content: CaptureFeatureInlineStatusContent

    var body: some View {
        HStack(alignment: .top, spacing: StockpileSpacing.small) {
            Image(systemName: content.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(content.tone.theme.accent.color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(content.title.uppercased())
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Text(content.message)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, StockpileSpacing.medium)
        .padding(.vertical, StockpileSpacing.small)
        .background(
            content.tone.theme.background.color.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

private struct CaptureGuidedQuickStat: Identifiable {
    let title: String
    let value: String
    let systemImage: String

    var id: String { title }
}

private struct CaptureGuidedCompactStatsRow: View {
    let items: [CaptureGuidedQuickStat]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StockpileSpacing.small) {
                ForEach(items) { item in
                    CaptureGuidedCompactStatPill(item: item)
                }
            }

            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                ForEach(items) { item in
                    CaptureGuidedCompactStatPill(item: item)
                }
            }
        }
    }
}

private struct CaptureGuidedCompactStatPill: View {
    let item: CaptureGuidedQuickStat

    var body: some View {
        HStack(alignment: .center, spacing: StockpileSpacing.small) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StockpilePalette.accent.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.uppercased())
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Text(item.value)
                    .font(StockpileTypography.callout.font.weight(.semibold))
                    .foregroundStyle(StockpilePalette.ink.color)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, StockpileSpacing.medium)
        .padding(.vertical, StockpileSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            StockpilePalette.surface.color.opacity(0.9),
            in: Capsule(style: .continuous)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(StockpilePalette.border.color.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct CaptureLivePreviewCard: View {
    let preview: CaptureGuidedPreviewState

    var body: some View {
        ZStack(alignment: .topLeading) {
            previewSurface

            HStack(spacing: StockpileSpacing.small) {
                Label(preview.badgeLabel, systemImage: preview.systemImage)
                    .font(StockpileTypography.caption.font.weight(.semibold))
                    .foregroundStyle(preview.tone.theme.accent.color)
                    .padding(.horizontal, StockpileSpacing.medium)
                    .padding(.vertical, StockpileSpacing.xSmall)
                    .background(
                        preview.tone.theme.background.color.opacity(0.96),
                        in: Capsule(style: .continuous)
                    )

                Spacer(minLength: 0)
            }
            .padding(StockpileSpacing.medium)
        }
        .shadow(color: StockpilePalette.ink.color.opacity(0.08), radius: 18, x: 0, y: 12)
    }

    @ViewBuilder
    private var previewSurface: some View {
        Group {
            if let captureSession = preview.captureSession, preview.showsLivePreview {
                CaptureLiveCameraPreviewRepresentable(captureSession: captureSession)
            } else {
                CaptureLivePreviewUnavailableSurface(preview: preview)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(preview.showsLivePreview ? (9.0 / 16.0) : (4.0 / 3.0), contentMode: .fit)
        .background(StockpilePalette.canvas.color, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(StockpilePalette.border.color.opacity(0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct CaptureLivePreviewUnavailableSurface: View {
    let preview: CaptureGuidedPreviewState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    StockpilePalette.surface.color,
                    preview.tone.theme.background.color.opacity(0.72),
                    StockpilePalette.elevatedSurface.color
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(preview.tone.theme.accent.color.opacity(0.14))
                .frame(width: 180, height: 180)
                .blur(radius: 16)
                .offset(x: 120, y: -84)

            VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                HStack(spacing: StockpileSpacing.medium) {
                    Image(systemName: preview.systemImage)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(preview.tone.theme.accent.color)
                        .frame(width: 58, height: 58)
                        .background(
                            preview.tone.theme.background.color.opacity(0.94),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                        Text(preview.badgeLabel)
                            .font(StockpileTypography.caption.font.weight(.semibold))
                            .foregroundStyle(preview.tone.theme.accent.color)

                        Text(preview.title)
                            .font(StockpileTypography.callout.font.weight(.semibold))
                            .foregroundStyle(StockpilePalette.ink.color)
                    }

                    Spacer(minLength: 0)
                }

                Text(preview.message)
                    .font(StockpileTypography.body.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(StockpileSpacing.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

@MainActor
private struct CaptureLiveCameraPreviewRepresentable: UIViewRepresentable {
    let captureSession: AVCaptureSession

    func makeUIView(context: Context) -> CaptureLiveCameraPreviewView {
        let previewView = CaptureLiveCameraPreviewView()
        previewView.previewLayer.videoGravity = .resizeAspectFill
        previewView.previewLayer.session = captureSession
        return previewView
    }

    func updateUIView(_ uiView: CaptureLiveCameraPreviewView, context: Context) {
        uiView.previewLayer.videoGravity = .resizeAspectFill
        if uiView.previewLayer.session !== captureSession {
            uiView.previewLayer.session = captureSession
        }
    }
}

@MainActor
private final class CaptureLiveCameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

private struct CaptureProgressStateView: View {
    let content: UploadProgressContent

    var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.large) {
            StockpileCard {
                VStack(alignment: .leading, spacing: StockpileSpacing.large) {
                    HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                        VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                            Text("Recorded pass")
                                .font(StockpileTypography.caption.font)
                                .foregroundStyle(StockpilePalette.mutedInk.color)

                            Text(content.phaseLabel)
                                .font(StockpileTypography.sectionTitle.font)
                                .foregroundStyle(StockpilePalette.ink.color)
                        }

                        Spacer(minLength: 0)

                        StockpileBadge(content.safetyBadgeLabel, tone: content.safetyBadgeTone)
                    }

                    Text(content.detail)
                        .font(StockpileTypography.body.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)

                    HStack(alignment: .firstTextBaseline, spacing: StockpileSpacing.xxSmall) {
                        Text("\(Int(content.overallProgress * 100))")
                            .font(StockpileTypography.metric.font)
                            .foregroundStyle(StockpilePalette.ink.color)

                        Text("%")
                            .font(StockpileTypography.sectionTitle.font)
                            .foregroundStyle(StockpilePalette.ink.color)

                        Spacer(minLength: 0)

                        Text(progressLabel)
                            .font(StockpileTypography.callout.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)
                    }

                    ProgressView(value: content.overallProgress)
                        .tint(StockpilePalette.accent.color)

                    CaptureInlineStatusMessage(
                        title: content.safetyBadgeLabel,
                        message: content.serverSafetyMessage,
                        tone: content.safetyBadgeTone,
                        systemImage: content.safetySystemImage
                    )
                }
            }

            StockpileCard(appearance: .outlined) {
                VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                    HStack {
                        Text("Stage status")
                            .font(StockpileTypography.sectionTitle.font)
                            .foregroundStyle(StockpilePalette.ink.color)

                        Spacer(minLength: 0)

                        Text(activeStepLabel)
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)
                    }

                    CapturePipelineRow(
                        title: content.uploadStatusLabel,
                        message: content.uploadStatusDetail,
                        progress: content.uploadProgress,
                        tone: content.transferStateRowTone,
                        isActive: content.uploadProgress < 1
                    )

                    Divider()
                        .overlay(StockpilePalette.border.color.opacity(0.6))

                    CapturePipelineRow(
                        title: content.processingStatusLabel,
                        message: content.processingStatusDetail,
                        progress: content.processingProgress,
                        tone: content.processingStateRowTone,
                        isActive: content.uploadProgress >= 1 && content.processingProgress < 1
                    )
                }
            }

            if let guidance = content.recaptureGuidance {
                CaptureRecaptureChecklistView(content: guidance)
            }
        }
    }

    private var progressLabel: String {
        content.uploadProgress >= 1 ? "Result checks are running" : "Secure handoff is running"
    }

    private var activeStepLabel: String {
        content.uploadProgress >= 1 ? "Result stage" : "Handoff stage"
    }
}

private struct CaptureHeroMetadata: Identifiable {
    let title: String
    let value: String
    let systemImage: String

    var id: String { title }
}

private struct CaptureHeroMetadataPill: View {
    let item: CaptureHeroMetadata

    var body: some View {
        HStack(alignment: .center, spacing: StockpileSpacing.small) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(StockpilePalette.accent.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.uppercased())
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Text(item.value)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, StockpileSpacing.medium)
        .padding(.vertical, StockpileSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            StockpilePalette.surface.color.opacity(0.88),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StockpilePalette.border.color.opacity(0.55), lineWidth: 1)
        )
    }
}

private struct CaptureInlineStatusMessage: View {
    let title: String
    let message: String
    let tone: StockpileStatusTone
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: StockpileSpacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone.theme.accent.color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: StockpileSpacing.xxSmall) {
                Text(title)
                    .font(StockpileTypography.callout.font.weight(.semibold))
                    .foregroundStyle(StockpilePalette.ink.color)

                Text(message)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
            }

            Spacer(minLength: 0)
        }
        .padding(StockpileSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tone.theme.background.color.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

private struct CapturePipelineRow: View {
    let title: String
    let message: String
    let progress: Double
    let tone: StockpileStatusTone
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: StockpileSpacing.small) {
            Image(systemName: statusIconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone.theme.accent.color)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: StockpileSpacing.small) {
                        titleRow
                    }

                    VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                        Text(title)
                            .font(StockpileTypography.callout.font)
                            .foregroundStyle(StockpilePalette.ink.color)

                        HStack(spacing: StockpileSpacing.small) {
                            if isActive {
                                Text("Now")
                                    .font(StockpileTypography.caption.font.weight(.semibold))
                                    .foregroundStyle(tone.theme.accent.color)
                            }

                            StockpileBadge("\(Int(progress * 100))%", tone: tone)
                        }
                    }
                }

                Text(message)
                    .font(StockpileTypography.body.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)

                ProgressView(value: progress)
                    .tint(tone.theme.accent.color)
            }
        }
        .opacity(isActive || progress >= 1 ? 1 : 0.82)
    }

    private var titleRow: some View {
        Group {
            Text(title)
                .font(StockpileTypography.callout.font)
                .foregroundStyle(StockpilePalette.ink.color)

            Spacer(minLength: 0)

            if isActive {
                Text("Now")
                    .font(StockpileTypography.caption.font.weight(.semibold))
                    .foregroundStyle(tone.theme.accent.color)
            }

            StockpileBadge("\(Int(progress * 100))%", tone: tone)
        }
    }

    private var statusIconName: String {
        if progress >= 1 {
            return "checkmark.circle.fill"
        }

        return isActive ? "waveform.path" : "clock.fill"
    }
}

private extension CaptureFeaturePhase {
    var workflowStepIndex: Int {
        switch self {
        case .idle, .guidedCapture:
            return 0
        case .uploadInProgress:
            return 1
        case .processing, .verifiedResult, .reviewOnlyResult, .blockedResult:
            return 2
        }
    }

    var heroSystemImage: String {
        switch self {
        case .idle:
            return "camera.aperture"
        case .guidedCapture:
            return "viewfinder.circle.fill"
        case .uploadInProgress:
            return "arrow.up.circle.fill"
        case .processing:
            return "server.rack"
        case .verifiedResult:
            return "checkmark.seal.fill"
        case .reviewOnlyResult:
            return "exclamationmark.shield.fill"
        case .blockedResult:
            return "arrow.clockwise.circle.fill"
        }
    }

    var isWaitingForBackgroundWork: Bool {
        self == .uploadInProgress || self == .processing
    }
}

private extension UploadProgressContent {
    var statusBannerTone: StockpileStatusTone {
        switch statusTone {
        case .neutral:
            return .info
        case .success:
            return .success
        case .warning:
            return .caution
        }
    }

    var transferStateRowTone: StockpileStatusTone {
        switch transferState {
        case .complete:
            return .success
        default:
            return .info
        }
    }

    var processingStateRowTone: StockpileStatusTone {
        switch processingState {
        case .blocked:
            return .critical
        case .reviewReady:
            return .caution
        case .computingVolume, .calibrating, .reconstructing:
            return .info
        case .detectingReferences, .preparingFrames, .queued, .idle:
            return uploadIsComplete ? .info : .caution
        }
    }

    var safetyBadgeTone: StockpileStatusTone {
        uploadIsComplete ? .success : .info
    }

    var safetyBadgeLabel: String {
        uploadIsComplete ? "Safe on server" : "Keep app open"
    }

    var safetySystemImage: String {
        uploadIsComplete ? "lock.shield.fill" : "iphone.gen3.radiowaves.left.and.right"
    }

    private var uploadIsComplete: Bool {
        if case .complete = transferState {
            return true
        }

        return false
    }
}

private struct CaptureRecaptureChecklistView: View {
    let content: RecaptureGuidanceContent

    var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
            Text(content.title)
                .font(StockpileTypography.sectionTitle.font)
                .foregroundStyle(StockpilePalette.ink.color)

            StockpileGuidanceBanner(
                title: "Why this run was blocked",
                message: content.primaryReason,
                tone: .critical
            )

            CaptureBulletCard(
                title: "What changed",
                tone: .critical,
                iconName: "xmark.circle.fill",
                items: content.reasons
            )

            StockpileCard(appearance: .outlined) {
                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    Text("Retake checklist")
                        .font(StockpileTypography.callout.font)
                        .foregroundStyle(StockpilePalette.ink.color)

                    ForEach(content.steps) { step in
                        VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                            Text(step.title)
                                .font(StockpileTypography.callout.font)
                                .foregroundStyle(StockpilePalette.ink.color)

                            Text(step.detail)
                                .font(StockpileTypography.body.font)
                                .foregroundStyle(StockpilePalette.mutedInk.color)
                        }
                        .padding(.vertical, StockpileSpacing.xxSmall)
                    }
                }
            }
        }
    }
}

private struct CaptureBulletCard: View {
    let title: String
    let tone: StockpileStatusTone
    let iconName: String
    let items: [String]

    var body: some View {
        StockpileCard(appearance: .outlined) {
            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                HStack {
                    Text(title)
                        .font(StockpileTypography.sectionTitle.font)
                        .foregroundStyle(StockpilePalette.ink.color)

                    Spacer()

                    StockpileBadge(titleBadge, tone: tone)
                }

                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: StockpileSpacing.small) {
                        Image(systemName: iconName)
                            .foregroundStyle(tone.theme.accent.color)
                            .padding(.top, 2)

                        Text(item)
                            .font(StockpileTypography.body.font)
                            .foregroundStyle(StockpilePalette.ink.color)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var titleBadge: String {
        switch tone {
        case .info:
            return "Info"
        case .success:
            return "Ready"
        case .caution:
            return "Attention"
        case .critical:
            return "Blocked"
        }
    }
}

private struct CaptureMetricItem: Identifiable {
    enum DisplayStyle {
        case status
        case metric
    }

    let title: String
    let value: String
    let note: String?
    let displayStyle: DisplayStyle

    var id: String { title }
}

private struct CaptureMetricGrid: View {
    let items: [CaptureMetricItem]

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 132), spacing: StockpileSpacing.medium)
            ],
            spacing: StockpileSpacing.medium
        ) {
            ForEach(items) { item in
                CaptureMetricCard(item: item)
            }
        }
    }
}

private struct CaptureMetricCard: View {
    let item: CaptureMetricItem

    var body: some View {
        StockpileCard {
            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                Text(item.title.uppercased())
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Text(item.value)
                    .font(valueFont)
                    .lineLimit(item.displayStyle == .metric ? 2 : 4)
                    .minimumScaleFactor(item.displayStyle == .metric ? 0.8 : 0.92)
                    .foregroundStyle(StockpilePalette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)

                if let note = item.note {
                    Text(note)
                        .font(StockpileTypography.callout.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: item.displayStyle == .metric ? 132 : 122, alignment: .topLeading)
        }
    }

    private var valueFont: Font {
        switch item.displayStyle {
        case .metric:
            return StockpileTypography.metric.font
        case .status:
            return Font.system(size: 24, weight: .semibold, design: .rounded)
        }
    }
}

private struct CaptureInstructionItem: Identifiable {
    let title: String
    let headline: String
    let detail: String
    let systemImage: String
    let tone: StockpileStatusTone

    var id: String { title }
}

private struct CaptureInstructionGrid: View {
    let items: [CaptureInstructionItem]

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 150), spacing: StockpileSpacing.medium)
            ],
            spacing: StockpileSpacing.medium
        ) {
            ForEach(items) { item in
                CaptureInstructionCard(item: item)
            }
        }
    }
}

private struct CaptureInstructionCard: View {
    let item: CaptureInstructionItem

    var body: some View {
        let theme = item.tone.theme

        VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
            HStack(spacing: StockpileSpacing.small) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
                    .frame(width: 34, height: 34)
                    .background(theme.background.color.opacity(0.95), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(item.title.uppercased())
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .tracking(0.4)

                Spacer(minLength: 0)
            }

            Text(item.headline)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(StockpilePalette.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            Text(item.detail)
                .font(StockpileTypography.callout.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
        .padding(StockpileSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(StockpilePalette.surface.color)
                .shadow(
                    color: StockpilePalette.ink.color.opacity(0.05),
                    radius: 18,
                    x: 0,
                    y: 10
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(theme.background.color.opacity(0.9), lineWidth: 1)
        )
    }
}

private struct CaptureFeatureActionBar: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let phase: CaptureFeaturePhase
    let actionHint: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    StockpilePalette.canvas.color.opacity(0),
                    StockpilePalette.canvas.color.opacity(0.74),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: StockpileSpacing.large)
            .allowsHitTesting(false)

            StockpileCard(appearance: .outlined) {
                Group {
                    if phase.isWaitingForBackgroundWork {
                        automaticStatusContent
                    } else {
                        manualActionContent
                    }
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, bottomPadding)
        }
        .background {
            LinearGradient(
                colors: [
                    StockpilePalette.canvas.color.opacity(0.02),
                    StockpilePalette.canvas.color.opacity(0.94),
                    StockpilePalette.canvas.color,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var horizontalPadding: CGFloat {
        horizontalSizeClass == .compact ? StockpileSpacing.medium : StockpileSpacing.large
    }

    private var bottomPadding: CGFloat {
        horizontalSizeClass == .compact ? StockpileSpacing.small : StockpileSpacing.medium
    }

    private var automaticStatusContent: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: StockpileSpacing.medium) {
                    automaticStatusHeader
                }

                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                        Text("Recording handoff")
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)

                        Text(buttonTitle)
                            .font(StockpileTypography.callout.font.weight(.semibold))
                            .foregroundStyle(StockpilePalette.ink.color)
                    }

                    HStack(spacing: StockpileSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(phase.badgeTone.theme.accent.color)

                        StockpileBadge(phase.badgeLabel, tone: phase.badgeTone)
                    }
                }
            }

            Text(actionHint)
                .font(StockpileTypography.caption.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var automaticStatusHeader: some View {
        Group {
            VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                Text("Recording handoff")
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Text(buttonTitle)
                    .font(StockpileTypography.callout.font.weight(.semibold))
                    .foregroundStyle(StockpilePalette.ink.color)
            }

            Spacer(minLength: 0)

            ProgressView()
                .controlSize(.small)
                .tint(phase.badgeTone.theme.accent.color)

            StockpileBadge(phase.badgeLabel, tone: phase.badgeTone)
        }
    }

    private var manualActionContent: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
            HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                    Text("Primary action")
                        .font(StockpileTypography.caption.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)

                    StockpileBadge(phase.badgeLabel, tone: phase.badgeTone)
                }

                Spacer(minLength: 0)
            }

            Text(actionHint)
                .font(StockpileTypography.callout.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)

            Button(action: action) {
                Text(buttonTitle)
            }
            .buttonStyle(StockpileActionButtonStyle(role: .primary))
            .accessibilityLabel(actionTitle)
            .accessibilityIdentifier("capture-action-\(phase.id)")
        }
    }

    private var buttonTitle: String {
        switch phase {
        case .uploadInProgress:
            return "Sealing automatically"
        case .processing:
            return "Building result automatically"
        default:
            return actionTitle
        }
    }
}

/// Snapshot of the on-device LiDAR quick estimate prepared for the HUD readout.
/// We model this in the view layer so unit tests can construct previews without
/// pulling in the StockpileMobileFirstCapture pose runtime.
struct CaptureLiveQuickVolumeReadout: Equatable {
    let volumeM3: Double
    let footprintAreaM2: Double
    let peakHeightM: Double
    let confidencePercent: Int

    var formattedVolume: String {
        Self.measurementFormatter.string(from: NSNumber(value: volumeM3.rounded())) ?? "\(Int(volumeM3.rounded()))"
    }

    var formattedFootprint: String {
        Self.measurementFormatter.string(from: NSNumber(value: footprintAreaM2.rounded())) ?? "\(Int(footprintAreaM2.rounded()))"
    }

    var formattedPeakHeight: String {
        String(format: "%.2f", peakHeightM)
    }

    var clampedConfidencePercent: Int {
        min(max(confidencePercent, 0), 100)
    }

    var confidenceTone: StockpileStatusTone {
        switch clampedConfidencePercent {
        case 75...:
            return .success
        case 45..<75:
            return .caution
        default:
            return .critical
        }
    }

    private static let measurementFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

/// Card variant rendered inside the idle `CaptureLiveEntryCard`. Matches the
/// existing camera state panel's visual rhythm (outlined card, caption +
/// section title pairing, status badge) so it slots in without introducing a
/// new design language.
private struct CaptureLiveVolumeReadoutCard: View {
    let readout: CaptureLiveQuickVolumeReadout

    var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.small) {
            HStack(alignment: .top, spacing: StockpileSpacing.small) {
                VStack(alignment: .leading, spacing: StockpileSpacing.xxSmall) {
                    Text("On-device LiDAR")
                        .font(StockpileTypography.caption.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)

                    Text("Provisional volume")
                        .font(StockpileTypography.callout.font.weight(.semibold))
                        .foregroundStyle(StockpilePalette.ink.color)
                }

                Spacer(minLength: 0)

                StockpileBadge(
                    "\(readout.clampedConfidencePercent)%",
                    tone: readout.confidenceTone
                )
            }

            CaptureLiveVolumeReadoutMetrics(readout: readout)

            CaptureLiveVolumeConfidenceBar(readout: readout)
        }
        .padding(StockpileSpacing.medium)
        .background(
            StockpilePalette.canvas.color.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(StockpilePalette.border.color.opacity(0.55), lineWidth: 1)
        )
    }
}

/// Compact overlay variant rendered above the field preview during the
/// `.guidedCapture` phase so the operator can watch the volume number tick up
/// while walking. The visual treatment mirrors the existing top status capsule
/// in `CaptureFieldTopOverlay`.
private struct CaptureLiveVolumeOverlayCard: View {
    let readout: CaptureLiveQuickVolumeReadout

    var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
            HStack(spacing: StockpileSpacing.xSmall) {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(readout.confidenceTone.theme.accent.color)

                Text("LiDAR readout")
                    .font(StockpileTypography.caption.font.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.92))

                Spacer(minLength: 0)

                Text("\(readout.clampedConfidencePercent)%")
                    .font(StockpileTypography.caption.font.weight(.bold))
                    .foregroundStyle(readout.confidenceTone.theme.accent.color)
                    .contentTransition(.numericText())
            }

            CaptureLiveVolumeReadoutMetrics(readout: readout, useOverlayPalette: true)
        }
        .padding(.horizontal, StockpileSpacing.medium)
        .padding(.vertical, StockpileSpacing.small)
        .background(
            Color.black.opacity(0.42),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

/// Internal grid of the three measurement values. Animates between values via
/// `.contentTransition(.numericText())` so the operator sees the volume tick up
/// instead of a hard cut.
private struct CaptureLiveVolumeReadoutMetrics: View {
    let readout: CaptureLiveQuickVolumeReadout
    var useOverlayPalette: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: StockpileSpacing.small) {
            CaptureLiveVolumeReadoutMetric(
                title: "Volume",
                value: readout.formattedVolume,
                unit: "m³",
                useOverlayPalette: useOverlayPalette
            )

            CaptureLiveVolumeReadoutMetric(
                title: "Footprint",
                value: readout.formattedFootprint,
                unit: "m²",
                useOverlayPalette: useOverlayPalette
            )

            CaptureLiveVolumeReadoutMetric(
                title: "Peak height",
                value: readout.formattedPeakHeight,
                unit: "m",
                useOverlayPalette: useOverlayPalette
            )
        }
    }
}

private struct CaptureLiveVolumeReadoutMetric: View {
    let title: String
    let value: String
    let unit: String
    let useOverlayPalette: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
            Text(title.uppercased())
                .font(StockpileTypography.caption.font)
                .foregroundStyle(useOverlayPalette ? Color.white.opacity(0.7) : StockpilePalette.mutedInk.color)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(StockpileTypography.sectionTitle.font.weight(.semibold))
                    .foregroundStyle(useOverlayPalette ? Color.white : StockpilePalette.ink.color)
                    .contentTransition(.numericText())

                Text(unit)
                    .font(StockpileTypography.caption.font.weight(.medium))
                    .foregroundStyle(useOverlayPalette ? Color.white.opacity(0.75) : StockpilePalette.mutedInk.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Subtle horizontal bar that visualises the live confidence percentage so the
/// operator gets a quick at-a-glance signal. Uses the same status tone palette
/// as the rest of the design system.
private struct CaptureLiveVolumeConfidenceBar: View {
    let readout: CaptureLiveQuickVolumeReadout

    var body: some View {
        GeometryReader { geometry in
            let percent = Double(readout.clampedConfidencePercent) / 100.0
            let filledWidth = max(geometry.size.width * percent, 2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StockpilePalette.border.color.opacity(0.55))

                Capsule()
                    .fill(readout.confidenceTone.theme.accent.color)
                    .frame(width: filledWidth)
            }
        }
        .frame(height: 6)
        .animation(.easeInOut(duration: 0.18), value: readout.clampedConfidencePercent)
    }
}

#Preview("Idle") {
    CaptureFeatureView(store: .preview(phase: .idle))
}

#Preview("Guided Capture") {
    CaptureFeatureView(store: .preview(phase: .guidedCapture))
}

#Preview("Upload") {
    CaptureFeatureView(store: .preview(phase: .uploadInProgress))
}

#Preview("Processing") {
    CaptureFeatureView(store: .preview(phase: .processing))
}

#Preview("Review Only") {
    CaptureFeatureView(store: .preview(phase: .reviewOnlyResult))
}

#Preview("Blocked") {
    CaptureFeatureView(store: .blockedPreview(phase: .blockedResult))
}
