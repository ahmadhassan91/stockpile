import SwiftUI
import StockpileDesignSystem

public enum StockpileCaptureFlowNamespace {}

public struct CaptureHomeContent: Sendable {
    public struct RecentRun: Identifiable, Sendable {
        public let id: String
        public let pileName: String
        public let statusLabel: String
        public let capturedAt: String

        public init(id: String, pileName: String, statusLabel: String, capturedAt: String) {
            self.id = id
            self.pileName = pileName
            self.statusLabel = statusLabel
            self.capturedAt = capturedAt
        }
    }

    public let siteName: String
    public let pileName: String
    public let materialName: String
    public let readinessHeadline: String
    public let readinessSummary: String
    public let primaryActionTitle: String
    public let quickTips: [String]
    public let recentRuns: [RecentRun]

    public init(
        siteName: String,
        pileName: String,
        materialName: String,
        readinessHeadline: String,
        readinessSummary: String,
        primaryActionTitle: String,
        quickTips: [String],
        recentRuns: [RecentRun]
    ) {
        self.siteName = siteName
        self.pileName = pileName
        self.materialName = materialName
        self.readinessHeadline = readinessHeadline
        self.readinessSummary = readinessSummary
        self.primaryActionTitle = primaryActionTitle
        self.quickTips = quickTips
        self.recentRuns = recentRuns
    }

    public static let preview = CaptureHomeContent(
        siteName: "QPMC North Yard",
        pileName: "North Yard 03",
        materialName: "Backfill 0-75 mm",
        readinessHeadline: "Review-grade likely",
        readinessSummary: "Keep 2-3 tagged references visible and cover the full toe boundary for the strongest result.",
        primaryActionTitle: "Start Guided Capture",
        quickTips: [
            "Keep the full base of the pile in frame.",
            "Move steadily around the perimeter.",
            "Keep 2-3 tagged references visible together.",
        ],
        recentRuns: [
            RecentRun(id: "run-001", pileName: "North Yard 03", statusLabel: "Review only", capturedAt: "Today, 14:20"),
            RecentRun(id: "run-000", pileName: "North Yard 03", statusLabel: "Blocked", capturedAt: "Yesterday, 16:05"),
        ]
    )
}

public enum GuidedCaptureCheckStatus: Equatable, Sendable {
    case ready
    case needsAttention
    case blocked
}

public struct GuidedCaptureCheck: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let status: GuidedCaptureCheckStatus
    public let detail: String
    public let operatorAction: String

    public init(
        id: String? = nil,
        title: String,
        status: GuidedCaptureCheckStatus,
        detail: String,
        operatorAction: String? = nil
    ) {
        self.id = id ?? title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        self.title = title
        self.status = status
        self.detail = detail
        self.operatorAction = operatorAction ?? detail
    }
}

public struct CaptureChecklistContent: Sendable {
    public let title: String
    public let summary: String
    public let items: [GuidedCaptureCheck]

    public init(title: String, summary: String, items: [GuidedCaptureCheck]) {
        self.title = title
        self.summary = summary
        self.items = items
    }

    public var readyCount: Int {
        items.filter { $0.status == .ready }.count
    }

    public var needsAttentionCount: Int {
        items.filter { $0.status == .needsAttention }.count
    }

    public var blockedCount: Int {
        items.filter { $0.status == .blocked }.count
    }

    public var isBlocked: Bool {
        blockedCount > 0
    }

    public var primaryOperatorAction: String {
        if let blocked = items.first(where: { $0.status == .blocked }) {
            return blocked.operatorAction
        }

        if let attention = items.first(where: { $0.status == .needsAttention }) {
            return attention.operatorAction
        }

        return "Capture quality is balanced. Finish the remaining perimeter coverage."
    }

    public var highlightedItems: [GuidedCaptureCheck] {
        let blocked = items.filter { $0.status == .blocked }
        if !blocked.isEmpty {
            return blocked
        }

        let attention = items.filter { $0.status == .needsAttention }
        return attention.isEmpty ? items : attention
    }

    public static let preview = CaptureChecklistContent(
        title: "Capture checklist",
        summary: "The operator should always know the next best capture action.",
        items: [
            GuidedCaptureCheck(
                title: "Reference visibility",
                status: .needsAttention,
                detail: "Only one tagged reference is visible in the current angle.",
                operatorAction: "Move slightly left until two tagged references are visible together."
            ),
            GuidedCaptureCheck(
                title: "Toe coverage",
                status: .ready,
                detail: "Most of the base perimeter is already covered."
            ),
            GuidedCaptureCheck(
                title: "Motion stability",
                status: .ready,
                detail: "Camera movement is steady enough for reconstruction."
            ),
        ]
    )
}

public struct GuidedCaptureContent: Sendable {
    public let pileName: String
    public let sessionLabel: String
    public let referencesVisible: Int
    public let referenceTarget: Int
    public let perimeterCoverage: Double
    public let stabilityScore: Double
    public let activePrompt: String
    public let captureChecks: [GuidedCaptureCheck]

    public init(
        pileName: String,
        sessionLabel: String,
        referencesVisible: Int,
        referenceTarget: Int,
        perimeterCoverage: Double,
        stabilityScore: Double,
        activePrompt: String,
        captureChecks: [GuidedCaptureCheck]
    ) {
        self.pileName = pileName
        self.sessionLabel = sessionLabel
        self.referencesVisible = referencesVisible
        self.referenceTarget = referenceTarget
        self.perimeterCoverage = perimeterCoverage
        self.stabilityScore = stabilityScore
        self.activePrompt = activePrompt
        self.captureChecks = captureChecks
    }

    public var isReadyToFinish: Bool {
        referencesVisible >= max(2, min(referenceTarget, 3))
            && perimeterCoverage >= 0.75
            && stabilityScore >= 0.75
            && !captureChecks.contains(where: { $0.status == .blocked })
    }

    public var readinessSummary: String {
        if isReadyToFinish {
            return "Ready to finish"
        }

        if captureChecks.contains(where: { $0.status == .blocked }) {
            return "Fix blocked issues first"
        }

        if perimeterCoverage < 0.65 {
            return "Needs more coverage"
        }

        if referencesVisible < 2 {
            return "Needs more tagged references"
        }

        return "Needs steadier motion"
    }

    public var checklistContent: CaptureChecklistContent {
        CaptureChecklistContent(
            title: "Capture checklist",
            summary: "Review the highest-priority capture issue first so we don't waste the walkaround.",
            items: captureChecks
        )
    }

    public static let preview = GuidedCaptureContent(
        pileName: "North Yard 03",
        sessionLabel: "Walkaround in progress",
        referencesVisible: 3,
        referenceTarget: 3,
        perimeterCoverage: 0.83,
        stabilityScore: 0.88,
        activePrompt: "Good coverage. Finish the last quarter of the toe boundary.",
        captureChecks: [
            GuidedCaptureCheck(title: "Reference visibility", status: .ready, detail: "Three tagged references are visible together."),
            GuidedCaptureCheck(title: "Perimeter coverage", status: .ready, detail: "Most of the pile toe is already covered."),
            GuidedCaptureCheck(title: "Motion stability", status: .ready, detail: "Camera movement is steady enough for reconstruction."),
        ]
    )
}

public enum UploadProgressPhase: String, Equatable, Sendable {
    case preparing
    case uploading
    case processing
    case review
    case blocked
}

public typealias UploadPhase = UploadProgressPhase

public enum UploadProgressTone: Equatable, Sendable {
    case neutral
    case success
    case warning
}

public enum UploadTransferState: Equatable, Sendable {
    case awaitingSelection
    case preparing
    case uploading(progress: Double?)
    case queuedForRetry
    case retrying
    case complete

    var label: String {
        switch self {
        case .awaitingSelection:
            return "Waiting for capture"
        case .preparing:
            return "Preparing upload"
        case .uploading:
            return "Uploading to server"
        case .queuedForRetry:
            return "Waiting to retry upload"
        case .retrying:
            return "Retrying upload"
        case .complete:
            return "Upload complete"
        }
    }

    var detail: String {
        switch self {
        case .awaitingSelection:
            return "Finish the live walkaround first, or keep a Files backup ready before upload starts."
        case .preparing:
            return "Checking the file and preparing a stable upload session."
        case let .uploading(progress):
            if let progress {
                return "Uploading the recorded capture to the server. \(Int(progress * 100))% transferred so far."
            }
            return "Uploading the recorded capture to the server."
        case .queuedForRetry:
            return "Connection dropped. The upload is queued locally and will retry automatically."
        case .retrying:
            return "Trying the upload again. The capture remains saved on this device."
        case .complete:
            return "The recorded capture is safely on the server. You do not need to keep this screen open."
        }
    }

    public var progress: Double {
        switch self {
        case .awaitingSelection:
            return 0.0
        case .preparing:
            return 0.08
        case let .uploading(progress):
            return max(0.12, min(progress ?? 0.35, 0.92))
        case .queuedForRetry:
            return 0.18
        case .retrying:
            return 0.24
        case .complete:
            return 1.0
        }
    }

    var isComplete: Bool {
        if case .complete = self {
            return true
        }
        return false
    }
}

public enum ProcessingStageState: Equatable, Sendable {
    case idle
    case queued
    case preparingFrames
    case detectingReferences
    case reconstructing
    case calibrating
    case computingVolume
    case reviewReady
    case blocked

    var label: String {
        switch self {
        case .idle:
            return "Waiting for upload"
        case .queued:
            return "Queued on server"
        case .preparingFrames:
            return "Preparing frames"
        case .detectingReferences:
            return "Detecting tagged references"
        case .reconstructing:
            return "Reconstructing stockpile geometry"
        case .calibrating:
            return "Calibrating scale"
        case .computingVolume:
            return "Computing volume"
        case .reviewReady:
            return "Review result ready"
        case .blocked:
            return "Capture blocked"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "Processing begins only after the upload finishes."
        case .queued:
            return "The file is already on the server and waiting for a worker."
        case .preparingFrames:
            return "Extracting frames and checking capture coverage."
        case .detectingReferences:
            return "Finding tagged references and assessing whether scale can be trusted."
        case .reconstructing:
            return "Building the 3D stockpile surface from the selected frames."
        case .calibrating:
            return "Cross-checking scale before we allow a report-grade result."
        case .computingVolume:
            return "Finalizing pile segmentation and grid integration."
        case .reviewReady:
            return "Processing completed with limited confidence. Review before reporting."
        case .blocked:
            return "Processing finished, but we could not verify this capture strongly enough to report it."
        }
    }

    public var progress: Double {
        switch self {
        case .idle:
            return 0.0
        case .queued:
            return 0.08
        case .preparingFrames:
            return 0.18
        case .detectingReferences:
            return 0.32
        case .reconstructing:
            return 0.58
        case .calibrating:
            return 0.76
        case .computingVolume:
            return 0.9
        case .reviewReady, .blocked:
            return 1.0
        }
    }

    var isTerminal: Bool {
        switch self {
        case .reviewReady, .blocked:
            return true
        default:
            return false
        }
    }
}

public struct RecaptureGuidanceStep: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String? = nil, title: String, detail: String) {
        self.id = id ?? title.lowercased().replacingOccurrences(of: " ", with: "-")
        self.title = title
        self.detail = detail
    }
}

public struct RecaptureGuidanceContent: Sendable {
    public let title: String
    public let summary: String
    public let reasons: [String]
    public let steps: [RecaptureGuidanceStep]
    public let primaryActionTitle: String

    public init(
        title: String,
        summary: String,
        reasons: [String],
        steps: [RecaptureGuidanceStep],
        primaryActionTitle: String
    ) {
        self.title = title
        self.summary = summary
        self.reasons = reasons
        self.steps = steps
        self.primaryActionTitle = primaryActionTitle
    }

    public var primaryReason: String {
        reasons.first ?? summary
    }

    public static let blockedPreview = RecaptureGuidanceContent(
        title: "Recapture guidance",
        summary: "This capture could not be verified. Retake it with stronger reference coverage.",
        reasons: [
            "Only one tagged reference stayed visible through most of the walkaround.",
            "The far toe edge dropped out for part of the orbit."
        ],
        steps: [
            RecaptureGuidanceStep(title: "Start wider", detail: "Begin with the full pile toe visible before moving around the perimeter."),
            RecaptureGuidanceStep(title: "Keep 2-3 references together", detail: "Hold at least two tagged references in view whenever you change angle."),
            RecaptureGuidanceStep(title: "Move slower", detail: "Reduce camera swing so reconstruction has cleaner overlap.")
        ],
        primaryActionTitle: "Retake capture"
    )
}

public struct UploadProgressContent: Sendable {
    public let transferState: UploadTransferState
    public let processingState: ProcessingStageState
    public let statusTone: UploadProgressTone
    public let primaryMessage: String
    public let recaptureGuidance: RecaptureGuidanceContent?

    public init(
        transferState: UploadTransferState,
        processingState: ProcessingStageState,
        statusTone: UploadProgressTone,
        primaryMessage: String,
        recaptureGuidance: RecaptureGuidanceContent? = nil
    ) {
        self.transferState = transferState
        self.processingState = processingState
        self.statusTone = statusTone
        self.primaryMessage = primaryMessage
        self.recaptureGuidance = recaptureGuidance
    }

    public var phase: UploadProgressPhase {
        switch processingState {
        case .reviewReady:
            return .review
        case .blocked:
            return .blocked
        case .idle where !transferState.isComplete:
            return transferState.progress < 0.12 ? .preparing : .uploading
        case .idle:
            return .processing
        default:
            return transferState.isComplete ? .processing : .uploading
        }
    }

    public var phaseLabel: String {
        switch phase {
        case .preparing:
            return "Preparing upload"
        case .uploading:
            return "Uploading capture"
        case .processing:
            return "Processing on server"
        case .review:
            return "Review-only result ready"
        case .blocked:
            return "Capture blocked"
        }
    }

    public var detail: String {
        primaryMessage
    }

    public var overallProgress: Double {
        switch phase {
        case .preparing, .uploading:
            return min(transferState.progress * 0.45, 0.45)
        case .processing:
            return 0.45 + (processingState.progress * 0.5)
        case .review, .blocked:
            return 1.0
        }
    }

    public var canOpenResults: Bool {
        processingState == .reviewReady
    }

    public var uploadStatusLabel: String {
        transferState.label
    }

    public var uploadStatusDetail: String {
        transferState.detail
    }

    public var uploadProgress: Double {
        transferState.progress
    }

    public var processingStatusLabel: String {
        processingState.label
    }

    public var processingStatusDetail: String {
        transferState.isComplete ? processingState.detail : "Processing starts only after the upload is safely on the server."
    }

    public var processingProgress: Double {
        transferState.isComplete ? processingState.progress : 0.0
    }

    public var serverSafetyMessage: String {
        transferState.isComplete
            ? "Your capture is already safe on the server. You do not need to keep this screen open."
            : "Keep this screen open until the upload completes."
    }

    public static let uploadingPreview = UploadProgressContent(
        transferState: .uploading(progress: 0.35),
        processingState: .idle,
        statusTone: .neutral,
        primaryMessage: "Uploading the recorded capture to the server. Processing will begin automatically when the handoff finishes."
    )

    public static let processingPreview = UploadProgressContent(
        transferState: .complete,
        processingState: .reconstructing,
        statusTone: .neutral,
        primaryMessage: "Upload complete. The server is now reconstructing the stockpile."
    )

    public static let reviewPreview = UploadProgressContent(
        transferState: .complete,
        processingState: .reviewReady,
        statusTone: .warning,
        primaryMessage: "This run completed, but confidence is limited. Review before reporting."
    )

    public static let blockedPreview = UploadProgressContent(
        transferState: .complete,
        processingState: .blocked,
        statusTone: .warning,
        primaryMessage: "We could not verify this capture. Retake it with clearer base coverage and more visible references.",
        recaptureGuidance: .blockedPreview
    )
}

public struct CaptureHomeView: View {
    private let content: CaptureHomeContent

    public init(content: CaptureHomeContent) {
        self.content = content
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StockpileSpacing.large) {
                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    StockpileBadge(content.readinessHeadline, tone: .caution)

                    Text(content.pileName)
                        .font(StockpileTypography.hero.font)
                        .foregroundStyle(StockpilePalette.ink.color)

                    Text("\(content.siteName) • \(content.materialName)")
                        .font(StockpileTypography.body.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                }

                StockpileCard {
                    VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                        Text(content.readinessSummary)
                            .font(StockpileTypography.callout.font)
                            .foregroundStyle(StockpilePalette.ink.color)

                        Button(content.primaryActionTitle) {}
                            .buttonStyle(StockpileActionButtonStyle(role: .primary))
                    }
                }

                StockpileCard(appearance: .outlined) {
                    VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                        Text("Quick tips")
                            .font(StockpileTypography.sectionTitle.font)
                            .foregroundStyle(StockpilePalette.ink.color)

                        ForEach(content.quickTips, id: \.self) { tip in
                            Label(tip, systemImage: "checkmark.circle.fill")
                                .font(StockpileTypography.body.font)
                                .foregroundStyle(StockpilePalette.ink.color)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                    Text("Recent runs")
                        .font(StockpileTypography.sectionTitle.font)
                        .foregroundStyle(StockpilePalette.ink.color)

                    ForEach(content.recentRuns) { run in
                        StockpileCard {
                            HStack {
                                VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                                    Text(run.pileName)
                                        .font(StockpileTypography.callout.font)
                                        .foregroundStyle(StockpilePalette.ink.color)

                                    Text(run.capturedAt)
                                        .font(StockpileTypography.caption.font)
                                        .foregroundStyle(StockpilePalette.mutedInk.color)
                                }

                                Spacer()

                                StockpileBadge(run.statusLabel, tone: badgeTone(for: run.statusLabel))
                            }
                        }
                    }
                }
            }
            .stockpileFieldScreen()
        }
    }

    private func badgeTone(for label: String) -> StockpileStatusTone {
        if label.lowercased().contains("blocked") {
            return .critical
        }

        if label.lowercased().contains("review") {
            return .caution
        }

        return .success
    }
}

public typealias CaptureHomeScreen = CaptureHomeView

public struct GuidedCaptureView: View {
    private let content: GuidedCaptureContent

    public init(content: GuidedCaptureContent) {
        self.content = content
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StockpileSpacing.large) {
                HStack {
                    VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                        Text(content.sessionLabel)
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)

                        Text(content.pileName)
                            .font(StockpileTypography.hero.font)
                            .foregroundStyle(StockpilePalette.ink.color)
                    }

                    Spacer()

                    StockpileBadge(content.readinessSummary, tone: content.isReadyToFinish ? .success : .caution)
                }

                StockpileGuidanceCard(
                    title: "Next best action",
                    message: content.checklistContent.primaryOperatorAction,
                    tone: content.checklistContent.isBlocked ? .critical : (content.isReadyToFinish ? .success : .caution)
                )

                HStack(spacing: StockpileSpacing.medium) {
                    StockpileMetricStat(title: "Tagged references", value: "\(content.referencesVisible)/\(content.referenceTarget)")
                    StockpileMetricStat(title: "Coverage", value: "\(Int(content.perimeterCoverage * 100))%")
                    StockpileMetricStat(title: "Stability", value: "\(Int(content.stabilityScore * 100))%")
                }

                CaptureChecklistView(content: content.checklistContent)

                HStack(spacing: StockpileSpacing.medium) {
                    Button("Pause") {}
                        .buttonStyle(StockpileActionButtonStyle(role: .secondary))
                    Button(content.isReadyToFinish ? "Finish capture" : "Keep capturing") {}
                        .buttonStyle(StockpileActionButtonStyle(role: .primary))
                }
            }
            .stockpileFieldScreen()
        }
    }
}

public typealias GuidedCaptureScreen = GuidedCaptureView

public struct UploadProgressView: View {
    private let content: UploadProgressContent

    public init(content: UploadProgressContent) {
        self.content = content
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StockpileSpacing.large) {
                Text(content.phaseLabel)
                    .font(StockpileTypography.hero.font)
                    .foregroundStyle(StockpilePalette.ink.color)

                StockpileGuidanceCard(
                    title: statusTitle,
                    message: content.detail,
                    tone: guidanceTone
                )

                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    ProgressView(value: content.overallProgress)
                        .tint(StockpilePalette.accent.color)

                    Text("\(Int(content.overallProgress * 100))% complete")
                        .font(StockpileTypography.callout.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                }

                StockpileCard {
                    VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                        Text("Upload")
                            .font(StockpileTypography.sectionTitle.font)
                            .foregroundStyle(StockpilePalette.ink.color)

                        UploadStateRow(
                            title: content.uploadStatusLabel,
                            message: content.uploadStatusDetail,
                            progress: content.uploadProgress,
                            tone: content.transferState.isComplete ? .success : .info
                        )
                    }
                }

                StockpileCard {
                    VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                        Text("Server processing")
                            .font(StockpileTypography.sectionTitle.font)
                            .foregroundStyle(StockpilePalette.ink.color)

                        UploadStateRow(
                            title: content.processingStatusLabel,
                            message: content.processingStatusDetail,
                            progress: content.processingProgress,
                            tone: processingTone
                        )
                    }
                }

                StockpileGuidanceCard(
                    title: "What happens now",
                    message: content.serverSafetyMessage,
                    tone: .info
                )

                if let recaptureGuidance = content.recaptureGuidance {
                    RecaptureGuidanceView(content: recaptureGuidance)
                }

                if content.canOpenResults {
                    Button("Open results") {}
                        .buttonStyle(StockpileActionButtonStyle(role: .primary))
                }
            }
            .stockpileFieldScreen()
        }
    }

    private var guidanceTone: StockpileStatusTone {
        switch content.statusTone {
        case .neutral:
            return .info
        case .success:
            return .success
        case .warning:
            return .caution
        }
    }

    private var processingTone: StockpileStatusTone {
        switch content.processingState {
        case .blocked:
            return .critical
        case .reviewReady:
            return .caution
        default:
            return .info
        }
    }

    private var statusTitle: String {
        switch content.phase {
        case .blocked:
            return "Recapture needed"
        case .review:
            return "Result needs review"
        case .processing:
            return "Processing on server"
        case .uploading, .preparing:
            return "Upload in progress"
        }
    }
}

public typealias UploadProgressScreen = UploadProgressView

public struct CaptureChecklistView: View {
    private let content: CaptureChecklistContent

    public init(content: CaptureChecklistContent) {
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
            HStack {
                VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                    Text(content.title)
                        .font(StockpileTypography.sectionTitle.font)
                        .foregroundStyle(StockpilePalette.ink.color)

                    Text(content.summary)
                        .font(StockpileTypography.body.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                }

                Spacer()

                StockpileBadge(
                    content.isBlocked ? "Blocked" : "\(content.readyCount)/\(content.items.count) ready",
                    tone: content.isBlocked ? .critical : (content.needsAttentionCount > 0 ? .caution : .success)
                )
            }

            StockpileGuidanceCard(
                title: "Do this next",
                message: content.primaryOperatorAction,
                tone: content.isBlocked ? .critical : .caution
            )

            ForEach(content.items) { check in
                StockpileCard {
                    VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                        HStack(alignment: .top, spacing: StockpileSpacing.small) {
                            Image(systemName: iconName(for: check.status))
                                .foregroundStyle(iconTone(for: check.status).theme.accent.color)

                            VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                                HStack {
                                    Text(check.title)
                                        .font(StockpileTypography.callout.font)
                                        .foregroundStyle(StockpilePalette.ink.color)

                                    Spacer()

                                    StockpileBadge(statusLabel(for: check.status), tone: iconTone(for: check.status))
                                }

                                Text(check.detail)
                                    .font(StockpileTypography.body.font)
                                    .foregroundStyle(StockpilePalette.mutedInk.color)

                                if check.status != .ready,
                                   check.operatorAction != check.detail {
                                    Text(check.operatorAction)
                                        .font(StockpileTypography.caption.font)
                                        .foregroundStyle(StockpilePalette.ink.color)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func iconName(for status: GuidedCaptureCheckStatus) -> String {
        switch status {
        case .ready:
            return "checkmark.circle.fill"
        case .needsAttention:
            return "exclamationmark.triangle.fill"
        case .blocked:
            return "xmark.octagon.fill"
        }
    }

    private func iconTone(for status: GuidedCaptureCheckStatus) -> StockpileStatusTone {
        switch status {
        case .ready:
            return .success
        case .needsAttention:
            return .caution
        case .blocked:
            return .critical
        }
    }

    private func statusLabel(for status: GuidedCaptureCheckStatus) -> String {
        switch status {
        case .ready:
            return "Ready"
        case .needsAttention:
            return "Needs attention"
        case .blocked:
            return "Blocked"
        }
    }
}

public struct RecaptureGuidanceView: View {
    private let content: RecaptureGuidanceContent

    public init(content: RecaptureGuidanceContent) {
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
            Text(content.title)
                .font(StockpileTypography.sectionTitle.font)
                .foregroundStyle(StockpilePalette.ink.color)

            StockpileGuidanceCard(
                title: "Why this run was blocked",
                message: content.primaryReason,
                tone: .critical
            )

            StockpileCard {
                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    Text(content.summary)
                        .font(StockpileTypography.body.font)
                        .foregroundStyle(StockpilePalette.ink.color)

                    ForEach(content.reasons, id: \.self) { reason in
                        Label(reason, systemImage: "xmark.circle.fill")
                            .font(StockpileTypography.body.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)
                    }
                }
            }

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
                    }
                }
            }

            Button(content.primaryActionTitle) {}
                .buttonStyle(StockpileActionButtonStyle(role: .primary))
        }
    }
}

public struct UploadStateRow: View {
    private let title: String
    private let message: String
    private let progress: Double
    private let tone: StockpileStatusTone

    public init(title: String, message: String, progress: Double, tone: StockpileStatusTone) {
        self.title = title
        self.message = message
        self.progress = progress
        self.tone = tone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.small) {
            HStack {
                Text(title)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.ink.color)

                Spacer()

                StockpileBadge("\(Int(progress * 100))%", tone: tone)
            }

            Text(message)
                .font(StockpileTypography.body.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)

            ProgressView(value: progress)
                .tint(tone.theme.accent.color)
        }
    }
}

public struct StockpileMetricStat: View {
    private let title: String
    private let value: String

    public init(title: String, value: String) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        StockpileCard {
            VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                Text(title)
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Text(value)
                    .font(StockpileTypography.sectionTitle.font)
                    .foregroundStyle(StockpilePalette.ink.color)
            }
        }
    }
}

public struct StockpileGuidanceCard: View {
    private let title: String
    private let message: String
    private let tone: StockpileStatusTone

    public init(title: String, message: String, tone: StockpileStatusTone) {
        self.title = title
        self.message = message
        self.tone = tone
    }

    public var body: some View {
        let theme = tone.theme

        return HStack(alignment: .top, spacing: StockpileSpacing.small) {
            Circle()
                .fill(theme.accent.color)
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                Text(title)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.ink.color)

                Text(message)
                    .font(StockpileTypography.body.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
            }
        }
        .padding(StockpileSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background.color, in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card))
    }
}

#if DEBUG
#Preview("Capture Home") {
    NavigationStack {
        CaptureHomeView(content: .preview)
    }
}

#Preview("Guided Capture") {
    NavigationStack {
        GuidedCaptureView(content: .preview)
    }
}

#Preview("Upload Progress") {
    NavigationStack {
        UploadProgressView(content: .uploadingPreview)
    }
}

#Preview("Server Processing") {
    NavigationStack {
        UploadProgressView(content: .processingPreview)
    }
}

#Preview("Review Result") {
    NavigationStack {
        UploadProgressView(content: .reviewPreview)
    }
}

#Preview("Blocked Result") {
    NavigationStack {
        UploadProgressView(content: .blockedPreview)
    }
}
#endif
