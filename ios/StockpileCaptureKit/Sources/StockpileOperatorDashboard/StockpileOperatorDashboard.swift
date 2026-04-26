import Foundation
import SwiftUI
import StockpileDesignSystem

public enum StockpileOperatorDashboardNamespace {}

public enum OperatorDashboardViewStyle: Sendable {
    case operational
    case presentation

    var screenPadding: CGFloat {
        switch self {
        case .operational:
            return StockpileSpacing.medium
        case .presentation:
            return StockpileSpacing.small
        }
    }

    var sectionSpacing: CGFloat {
        switch self {
        case .operational:
            return StockpileSpacing.medium
        case .presentation:
            return StockpileSpacing.medium
        }
    }

    var cardStackSpacing: CGFloat {
        switch self {
        case .operational:
            return StockpileSpacing.small
        case .presentation:
            return StockpileSpacing.small
        }
    }

    var topContentPadding: CGFloat {
        switch self {
        case .operational:
            return StockpileSpacing.medium
        case .presentation:
            return StockpileSpacing.small
        }
    }

    var bottomContentPadding: CGFloat {
        switch self {
        case .operational:
            return StockpileSpacing.large
        case .presentation:
            return StockpileSpacing.large
        }
    }

    var maxContentWidth: CGFloat {
        switch self {
        case .operational:
            return .greatestFiniteMagnitude
        case .presentation:
            return 760
        }
    }

    var heroStyle: OperatorDashboardHeroStyle {
        switch self {
        case .operational:
            return .prominent
        case .presentation:
            return .compact
        }
    }

    var sectionTitleFont: Font {
        switch self {
        case .operational:
            return StockpileTypography.sectionTitle.font
        case .presentation:
            return StockpileTypography.callout.font.weight(.semibold)
        }
    }

    var sectionSubtitleFont: Font {
        switch self {
        case .operational:
            return StockpileTypography.callout.font
        case .presentation:
            return StockpileTypography.caption.font
        }
    }
}

public enum OperatorDashboardHeroStyle: Sendable {
    case prominent
    case compact
}

public enum OperatorDashboardRuntimeState: String, Codable, Sendable, Equatable {
    case empty
    case loading
    case live
}

public enum OperatorDashboardTrustState: String, CaseIterable, Codable, Sendable {
    case verified
    case reviewOnly = "review_only"
    case blocked
    case processing

    public var title: String {
        switch self {
        case .verified:
            return "Verified"
        case .reviewOnly:
            return "Review required"
        case .blocked:
            return "Recapture required"
        case .processing:
            return "Processing"
        }
    }

    public var tone: StockpileStatusTone {
        switch self {
        case .verified:
            return .success
        case .reviewOnly:
            return .caution
        case .blocked:
            return .critical
        case .processing:
            return .info
        }
    }

    public var actionTitle: String {
        switch self {
        case .verified:
            return "Open report"
        case .reviewOnly:
            return "Review result"
        case .blocked:
            return "Plan recapture"
        case .processing:
            return "Track progress"
        }
    }
}

public enum OperatorActionKind: String, Codable, Sendable {
    case review
    case recapture
    case monitor
    case share

    public var dashboardLabel: String {
        switch self {
        case .review:
            return "Review"
        case .recapture:
            return "Recapture"
        case .monitor:
            return "Monitor"
        case .share:
            return "Share"
        }
    }

    public var systemImage: String {
        switch self {
        case .review:
            return "doc.text.magnifyingglass"
        case .recapture:
            return "camera.viewfinder"
        case .monitor:
            return "waveform.path.ecg"
        case .share:
            return "square.and.arrow.up"
        }
    }
}

public struct OperatorDashboardAction: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let kind: OperatorActionKind
    public let trustState: OperatorDashboardTrustState

    public init(
        id: String,
        title: String,
        detail: String,
        kind: OperatorActionKind,
        trustState: OperatorDashboardTrustState
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.trustState = trustState
    }
}

public enum OperatorJobStage: String, Codable, Sendable {
    case upload
    case referenceScan = "reference_scan"
    case reconstruction
    case calibration
    case reporting

    public var title: String {
        switch self {
        case .upload:
            return "Uploading"
        case .referenceScan:
            return "Scanning references"
        case .reconstruction:
            return "Reconstructing"
        case .calibration:
            return "Calibrating"
        case .reporting:
            return "Preparing report"
        }
    }
}

public struct OperatorFacilitySummary: Hashable, Codable, Sendable {
    public let facilityName: String
    public let operatorLabel: String
    public let activeSites: Int
    public let activeJobs: Int
    public let reviewQueue: Int
    public let blockedRuns: Int
    public let verifiedToday: Int
    public let lastSyncLabel: String

    public init(
        facilityName: String,
        operatorLabel: String,
        activeSites: Int,
        activeJobs: Int,
        reviewQueue: Int,
        blockedRuns: Int,
        verifiedToday: Int,
        lastSyncLabel: String
    ) {
        self.facilityName = facilityName
        self.operatorLabel = operatorLabel
        self.activeSites = activeSites
        self.activeJobs = activeJobs
        self.reviewQueue = reviewQueue
        self.blockedRuns = blockedRuns
        self.verifiedToday = verifiedToday
        self.lastSyncLabel = lastSyncLabel
    }

    public var healthHeadline: String {
        if blockedRuns > 0 {
            return "\(blockedRuns) capture\(blockedRuns == 1 ? "" : "s") need recapture"
        }

        if reviewQueue > 0 {
            return "\(reviewQueue) run\(reviewQueue == 1 ? "" : "s") ready for operator review"
        }

        return "Field operations are clear to proceed"
    }

    public var healthTone: StockpileStatusTone {
        if blockedRuns > 0 {
            return .critical
        }

        if reviewQueue > 0 {
            return .caution
        }

        return .success
    }

    public var healthStatusLabel: String {
        if blockedRuns > 0 {
            return "Recapture needed"
        }

        if reviewQueue > 0 {
            return "Review queue live"
        }

        return "Healthy"
    }

    public var queueHeadline: String {
        if blockedRuns > 0, reviewQueue > 0 {
            return "\(runLabel(blockedRuns)) blocked, \(runLabel(reviewQueue)) waiting for review"
        }

        if blockedRuns > 0 {
            return blockedRuns == 1 ? "1 run needs recapture" : "\(blockedRuns) runs need recapture"
        }

        if reviewQueue > 0 {
            return reviewQueue == 1 ? "1 run is ready for review" : "\(reviewQueue) runs are ready for review"
        }

        return "Operations are clear for release"
    }

    public var queueMessage: String {
        if blockedRuns > 0, reviewQueue > 0 {
            return "Set the recapture plan first, then clear the review queue before any final report is shared."
        }

        if blockedRuns > 0 {
            return "These runs should be recaptured before they are treated as final."
        }

        if reviewQueue > 0 {
            return "Open the queued runs, compare confidence notes, and release only the trusted reports."
        }

        return "Capture flow is clear, verified reports are moving, and no urgent operator intervention is needed."
    }

    public var operationsFootnote: String {
        if activeJobs == 0 {
            return activeSites == 1 ? "1 site connected" : "\(activeSites) sites connected"
        }

        let jobsLabel = activeJobs == 1 ? "1 live job" : "\(activeJobs) live jobs"
        let sitesLabel = activeSites == 1 ? "1 site" : "\(activeSites) sites"

        return "\(jobsLabel) across \(sitesLabel)"
    }

    public var displayFacilityName: String {
        let trimmed = facilityName.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["QPMC ", "Qatar Primary Materials Company "] where trimmed.hasPrefix(prefix) {
            let candidate = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }

        return trimmed
    }

    public var brandLabel: String {
        let trimmed = facilityName.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("QPMC ") || trimmed.hasPrefix("Qatar Primary Materials Company ") {
            return "QPMC"
        }

        return "Operations"
    }

    public var blockedMetricTone: StockpileStatusTone {
        blockedRuns > 0 ? .critical : .success
    }

    public var reviewMetricTone: StockpileStatusTone {
        reviewQueue > 0 ? .caution : .success
    }

    public var verifiedMetricTone: StockpileStatusTone {
        verifiedToday > 0 ? .success : .info
    }

    private func runLabel(_ count: Int) -> String {
        count == 1 ? "1 run" : "\(count) runs"
    }
}

public struct OperatorActiveJob: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let pileName: String
    public let stage: OperatorJobStage
    public let progress: Double
    public let trustState: OperatorDashboardTrustState
    public let etaLabel: String
    public let detail: String

    public init(
        id: String,
        pileName: String,
        stage: OperatorJobStage,
        progress: Double,
        trustState: OperatorDashboardTrustState,
        etaLabel: String,
        detail: String
    ) {
        self.id = id
        self.pileName = pileName
        self.stage = stage
        self.progress = progress
        self.trustState = trustState
        self.etaLabel = etaLabel
        self.detail = detail
    }

    public var clampedProgress: Double {
        min(max(progress, 0), 1)
    }
}

public struct OperatorRecentRun: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let pileName: String
    public let trustState: OperatorDashboardTrustState
    public let confidenceLabel: String
    public let volumeLabel: String?
    public let relativeTimeLabel: String
    public let detail: String

    public init(
        id: String,
        pileName: String,
        trustState: OperatorDashboardTrustState,
        confidenceLabel: String,
        volumeLabel: String?,
        relativeTimeLabel: String,
        detail: String
    ) {
        self.id = id
        self.pileName = pileName
        self.trustState = trustState
        self.confidenceLabel = confidenceLabel
        self.volumeLabel = volumeLabel
        self.relativeTimeLabel = relativeTimeLabel
        self.detail = detail
    }
}

public struct OperatorDashboardContent: Hashable, Codable, Sendable {
    public let runtimeState: OperatorDashboardRuntimeState
    public let summary: OperatorFacilitySummary
    public let actionQueue: [OperatorDashboardAction]
    public let activeJobs: [OperatorActiveJob]
    public let recentRuns: [OperatorRecentRun]

    public init(
        runtimeState: OperatorDashboardRuntimeState = .live,
        summary: OperatorFacilitySummary,
        actionQueue: [OperatorDashboardAction],
        activeJobs: [OperatorActiveJob],
        recentRuns: [OperatorRecentRun]
    ) {
        self.runtimeState = runtimeState
        self.summary = summary
        self.actionQueue = actionQueue
        self.activeJobs = activeJobs
        self.recentRuns = recentRuns
    }

    public var hasLiveContent: Bool {
        !actionQueue.isEmpty || !activeJobs.isEmpty || !recentRuns.isEmpty
    }

    public var emptyStateTitle: String {
        "No capture has reached review yet"
    }

    public var emptyStateMessage: String {
        "Home will light up as soon as the first walkaround is uploaded or recorded and handed off successfully."
    }

    public var loadingStateTitle: String {
        "Capture is moving through processing"
    }

    public var loadingStateMessage: String {
        if let activeJob = activeJobs.first {
            return "\(activeJob.pileName) is in \(activeJob.stage.title.lowercased()) and this screen will switch to live review content when the backend finishes."
        }

        return "The latest walkaround is already in handoff and the result cards will appear here automatically."
    }

    public var urgentActionCount: Int {
        summary.blockedRuns + summary.reviewQueue
    }

    public var prioritizedActionQueue: [OperatorDashboardAction] {
        actionQueue.sorted { lhs, rhs in
            actionPriority(for: lhs.trustState) < actionPriority(for: rhs.trustState)
        }
    }

    public var attentionActions: [OperatorDashboardAction] {
        prioritizedActionQueue.filter { $0.trustState == .blocked || $0.trustState == .reviewOnly }
    }

    public var secondaryActions: [OperatorDashboardAction] {
        prioritizedActionQueue.filter { $0.trustState != .blocked && $0.trustState != .reviewOnly }
    }

    public var primaryActionTitle: String {
        if let first = prioritizedActionQueue.first {
            return first.trustState.actionTitle
        }

        if let job = activeJobs.first {
            return job.trustState.actionTitle
        }

        return "Start capture"
    }

    public var statusBannerTitle: String {
        if summary.blockedRuns > 0, summary.reviewQueue > 0 {
            return "\(summary.blockedRuns) blocked, \(summary.reviewQueue) awaiting review"
        }

        if summary.blockedRuns > 0 {
            return summary.blockedRuns == 1 ? "1 run needs recapture" : "\(summary.blockedRuns) runs need recapture"
        }

        if summary.reviewQueue > 0 {
            return summary.reviewQueue == 1 ? "1 run is ready for review" : "\(summary.reviewQueue) runs are ready for review"
        }

        return "Facility is clear for release"
    }

    public var statusBannerMessage: String {
        summary.queueMessage
    }

    public var attentionSectionTitle: String {
        if summary.blockedRuns > 0, summary.reviewQueue > 0 {
            return "Urgent queue"
        }

        if summary.blockedRuns > 0 {
            return "Recapture queue"
        }

        return "Review queue"
    }

    public var attentionSectionMessage: String {
        if summary.blockedRuns > 0, summary.reviewQueue > 0 {
            return "Blocked runs come first. Review-ready runs can be released after the recapture plan is set."
        }

        if summary.blockedRuns > 0 {
            return "Resolve these recaptures before any final report is handed off."
        }

        return "Review confidence notes, then release only the trusted runs."
    }

    public var secondarySectionTitle: String {
        if secondaryActions.contains(where: { $0.kind == .share || $0.trustState == .verified }) {
            return "Ready to share"
        }

        return "Follow-up"
    }

    public var secondarySectionMessage: String {
        if secondaryActions.contains(where: { $0.kind == .share || $0.trustState == .verified }) {
            return "Trusted reports and handoff items that do not block the current shift."
        }

        return "Lower-priority monitoring items to check after the urgent queue is clear."
    }

    private func actionPriority(for trustState: OperatorDashboardTrustState) -> Int {
        switch trustState {
        case .blocked:
            return 0
        case .reviewOnly:
            return 1
        case .processing:
            return 2
        case .verified:
            return 3
        }
    }

    public static let preview = OperatorDashboardContent(
        runtimeState: .live,
        summary: OperatorFacilitySummary(
            facilityName: "QPMC North Yard",
            operatorLabel: "Shift lead: Mais",
            activeSites: 4,
            activeJobs: 2,
            reviewQueue: 1,
            blockedRuns: 1,
            verifiedToday: 6,
            lastSyncLabel: "Synced 2 min ago"
        ),
        actionQueue: [
            OperatorDashboardAction(
                id: "review-run-412",
                title: "Run 412 is ready for operator review",
                detail: "Confidence is moderate. Cross-check the benchmark before releasing the report.",
                kind: .review,
                trustState: .reviewOnly
            ),
            OperatorDashboardAction(
                id: "blocked-run-409",
                title: "Run 409 needs recapture planning",
                detail: "Toe coverage was incomplete and reference visibility dropped during the final pass.",
                kind: .recapture,
                trustState: .blocked
            ),
            OperatorDashboardAction(
                id: "verified-run-404",
                title: "Run 404 is ready to share",
                detail: "Verified output is complete and the final report is ready for the site team.",
                kind: .share,
                trustState: .verified
            )
        ],
        activeJobs: [
            OperatorActiveJob(
                id: "job-778",
                pileName: "North Yard 03",
                stage: .reconstruction,
                progress: 0.61,
                trustState: .processing,
                etaLabel: "ETA 6 min",
                detail: "Camera path and references look healthy so far."
            ),
            OperatorActiveJob(
                id: "job-779",
                pileName: "North Yard 07",
                stage: .calibration,
                progress: 0.84,
                trustState: .reviewOnly,
                etaLabel: "ETA 2 min",
                detail: "Confidence is recovering, but the final result may still require review."
            )
        ],
        recentRuns: [
            OperatorRecentRun(
                id: "run-412",
                pileName: "North Yard 07",
                trustState: .reviewOnly,
                confidenceLabel: "Moderate confidence",
                volumeLabel: "2,528 m³",
                relativeTimeLabel: "12 min ago",
                detail: "Hold before release until the latest benchmark is checked."
            ),
            OperatorRecentRun(
                id: "run-409",
                pileName: "North Yard 05",
                trustState: .blocked,
                confidenceLabel: "Blocked",
                volumeLabel: nil,
                relativeTimeLabel: "24 min ago",
                detail: "Retake with wider toe coverage and 2-3 tagged references visible together."
            ),
            OperatorRecentRun(
                id: "run-404",
                pileName: "North Yard 01",
                trustState: .verified,
                confidenceLabel: "High confidence",
                volumeLabel: "1,842 m³",
                relativeTimeLabel: "1 hr ago",
                detail: "Released to reporting after passing all trust gates."
            )
        ]
    )
}

public struct OperatorDashboardView: View {
    private let content: OperatorDashboardContent
    private let style: OperatorDashboardViewStyle

    public init(
        content: OperatorDashboardContent,
        style: OperatorDashboardViewStyle = .operational
    ) {
        self.content = content
        self.style = style
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: style.sectionSpacing) {
                OperatorFacilityHero(summary: content.summary, style: style.heroStyle)

                if content.runtimeState == .empty || (content.runtimeState == .live && !content.hasLiveContent) {
                    OperatorDashboardStateCard(
                        title: content.emptyStateTitle,
                        message: content.emptyStateMessage,
                        tone: .info,
                        style: style,
                        systemImage: "tray.and.arrow.down"
                    )
                }

                if content.runtimeState == .loading {
                    OperatorDashboardStateCard(
                        title: content.loadingStateTitle,
                        message: content.loadingStateMessage,
                        tone: .info,
                        style: style,
                        systemImage: "arrow.triangle.2.circlepath.circle.fill"
                    )
                }

                if !content.attentionActions.isEmpty {
                    OperatorDashboardSection(
                        title: content.attentionSectionTitle,
                        subtitle: style == .presentation ? nil : content.attentionSectionMessage,
                        style: style
                    ) {
                        VStack(spacing: style.cardStackSpacing) {
                            ForEach(content.attentionActions) { action in
                                OperatorActionCard(action: action, style: style)
                            }
                        }
                    }
                }

                if !content.activeJobs.isEmpty {
                    OperatorDashboardSection(
                        title: "Live processing",
                        subtitle: style == .presentation ? nil : content.summary.operationsFootnote,
                        style: style
                    ) {
                        VStack(spacing: style.cardStackSpacing) {
                            ForEach(content.activeJobs) { job in
                                OperatorActiveJobCard(job: job, style: style)
                            }
                        }
                    }
                }

                if !content.secondaryActions.isEmpty {
                    OperatorDashboardSection(
                        title: content.secondarySectionTitle,
                        subtitle: style == .presentation ? nil : content.secondarySectionMessage,
                        style: style
                    ) {
                        VStack(spacing: style.cardStackSpacing) {
                            ForEach(content.secondaryActions) { action in
                                OperatorActionCard(action: action, style: style)
                            }
                        }
                    }
                }

                if !content.recentRuns.isEmpty {
                    OperatorDashboardSection(
                        title: "Recent outcomes",
                        subtitle: style == .presentation ? nil : "Latest trust decisions and released volumes.",
                        style: style
                    ) {
                        VStack(spacing: style.cardStackSpacing) {
                            ForEach(content.recentRuns) { run in
                                OperatorRecentRunCard(run: run, style: style)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, style.screenPadding)
            .padding(.top, style.topContentPadding)
            .padding(.bottom, style.bottomContentPadding)
            .frame(maxWidth: style.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(StockpilePalette.canvas.color.ignoresSafeArea())
    }
}

private struct OperatorDashboardStateCard: View {
    let title: String
    let message: String
    let tone: StockpileStatusTone
    let style: OperatorDashboardViewStyle
    let systemImage: String

    var body: some View {
        let theme = tone.theme

        return StockpileCard(appearance: .elevated) {
            HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accent.color)
                    .padding(.top, StockpileSpacing.xxxSmall)

                VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                    Text(title)
                        .font(style == .presentation ? StockpileTypography.callout.font.weight(.semibold) : StockpileTypography.sectionTitle.font)
                        .foregroundStyle(StockpilePalette.ink.color)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(message)
                        .font(style == .presentation ? StockpileTypography.callout.font : StockpileTypography.body.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.background.color.opacity(style == .presentation ? 0.18 : 0.36),
                in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
            )
        }
    }
}

public struct OperatorFacilityHero: View {
    private let summary: OperatorFacilitySummary
    private let style: OperatorDashboardHeroStyle

    public init(
        summary: OperatorFacilitySummary,
        style: OperatorDashboardHeroStyle = .prominent
    ) {
        self.summary = summary
        self.style = style
    }

    public var body: some View {
        let theme = summary.healthTone.theme

        return StockpileCard(appearance: cardAppearance) {
            ZStack(alignment: .topTrailing) {
                if style == .prominent {
                    Circle()
                        .fill(theme.accent.color.opacity(0.06))
                        .frame(width: 160, height: 160)
                        .offset(x: 56, y: -96)
                }

                    VStack(alignment: .leading, spacing: heroContentSpacing) {
                        heroIdentityBlock(theme: theme)

                        VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                            Text(summary.queueHeadline)
                                .font(queueHeadlineFont)
                                .foregroundStyle(StockpilePalette.ink.color)

                            Text(summary.queueMessage)
                                .font(StockpileTypography.body.font)
                                .foregroundStyle(StockpilePalette.mutedInk.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        OperatorHeroMetricsRow(summary: summary, style: style)

                        if style == .prominent {
                            heroFootnoteRow(theme: theme)
                        }
                    }
            }
        }
    }

    private var cardAppearance: StockpileCardAppearance {
        switch style {
        case .prominent:
            return .elevated
        case .compact:
            return .elevated
        }
    }

    private var heroContentSpacing: CGFloat {
        switch style {
        case .prominent:
            return StockpileSpacing.medium
        case .compact:
            return StockpileSpacing.small
        }
    }

    private var facilityTitleFont: Font {
        switch style {
        case .prominent:
            return .system(size: 24, weight: .semibold, design: .rounded)
        case .compact:
            return .system(size: 19, weight: .semibold, design: .rounded)
        }
    }

    private var queueHeadlineFont: Font {
        switch style {
        case .prominent:
            return .system(size: 21, weight: .semibold, design: .rounded)
        case .compact:
            return StockpileTypography.callout.font.weight(.semibold)
        }
    }

    @ViewBuilder
    private func heroIdentityBlock(theme: StockpileStatusTheme) -> some View {
        if style == .prominent {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                    heroIdentityCopy(theme: theme)

                    Spacer(minLength: StockpileSpacing.medium)

                    StockpileBadge(summary.healthStatusLabel, tone: summary.healthTone)
                }

                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    heroIdentityCopy(theme: theme)
                    StockpileBadge(summary.healthStatusLabel, tone: summary.healthTone)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                compactIdentityContent(theme: theme)
                compactStatusStack
            }
        }
    }

    private func compactIdentityContent(theme: StockpileStatusTheme) -> some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
            HStack(spacing: StockpileSpacing.xSmall) {
                Image(systemName: "building.2.crop.circle")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accent.color)

                Text(summary.brandLabel)
                    .font(StockpileTypography.caption.font.weight(.semibold))
                    .foregroundStyle(theme.accent.color)
            }

            Text(summary.displayFacilityName)
                .font(facilityTitleFont)
                .foregroundStyle(StockpilePalette.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            Text(summary.operatorLabel)
                .font(StockpileTypography.callout.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
        }
    }

    private var compactStatusStack: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StockpileSpacing.xSmall) {
                StockpileBadge(summary.healthStatusLabel, tone: summary.healthTone)

                Text(summary.lastSyncLabel)
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: StockpileSpacing.xxSmall) {
                StockpileBadge(summary.healthStatusLabel, tone: summary.healthTone)

                Text(summary.lastSyncLabel)
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func heroIdentityCopy(theme: StockpileStatusTheme) -> some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.small) {
            Text(summary.brandLabel)
                .font(StockpileTypography.caption.font.weight(.semibold))
                .foregroundStyle(theme.accent.color)
                .textCase(.uppercase)

            Text(summary.displayFacilityName)
                .font(facilityTitleFont)
                .foregroundStyle(StockpilePalette.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            Text(summary.operatorLabel)
                .font(StockpileTypography.callout.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func heroFootnoteRow(theme: StockpileStatusTheme) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: StockpileSpacing.small) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accent.color)

                Text(summary.operationsFootnote)
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Spacer(minLength: StockpileSpacing.medium)

                Text(summary.lastSyncLabel)
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                HStack(alignment: .center, spacing: StockpileSpacing.small) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.accent.color)

                    Text(summary.operationsFootnote)
                        .font(StockpileTypography.caption.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(summary.lastSyncLabel)
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

public struct OperatorActionCard: View {
    private let action: OperatorDashboardAction
    private let style: OperatorDashboardViewStyle

    public init(action: OperatorDashboardAction, style: OperatorDashboardViewStyle = .operational) {
        self.action = action
        self.style = style
    }

    public var body: some View {
        let theme = action.trustState.tone.theme
        let isUrgent = action.trustState == .blocked || action.trustState == .reviewOnly

        return StockpileCard(appearance: isUrgent ? .elevated : .outlined) {
            VStack(alignment: .leading, spacing: style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium) {
                actionHeader(theme: theme)

                VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                    Text(action.title)
                        .font(StockpileTypography.callout.font.weight(.semibold))
                        .foregroundStyle(StockpilePalette.ink.color)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(action.detail)
                        .font(StockpileTypography.callout.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actionPrompt(theme: theme)
            }
            .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
            .background(
                theme.background.color.opacity(presentationSurfaceOpacity(isUrgent: isUrgent)),
                in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
            )
            .overlay(alignment: .leading) {
                if style == .presentation {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.accent.color.opacity(isUrgent ? 0.85 : 0.45))
                        .frame(width: 3)
                        .padding(.vertical, StockpileSpacing.small)
                        .padding(.leading, StockpileSpacing.xSmall)
                }
            }
        }
    }

    private func presentationSurfaceOpacity(isUrgent: Bool) -> Double {
        if style == .presentation {
            return isUrgent ? 0.14 : 0.06
        }
        return isUrgent ? 0.28 : 0.12
    }

    @ViewBuilder
    private func actionHeader(theme: StockpileStatusTheme) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: StockpileSpacing.small) {
                actionLabel(theme: theme)

                Spacer(minLength: StockpileSpacing.xSmall)

                StockpileBadge(action.trustState.title, tone: action.trustState.tone)
            }

            VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                actionLabel(theme: theme)
                StockpileBadge(action.trustState.title, tone: action.trustState.tone)
            }
        }
    }

    private func actionLabel(theme: StockpileStatusTheme) -> some View {
        HStack(spacing: StockpileSpacing.xSmall) {
            Image(systemName: action.kind.systemImage)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent.color)

            Text(action.kind.dashboardLabel)
                .font(StockpileTypography.caption.font.weight(.semibold))
                .foregroundStyle(theme.accent.color)
        }
    }

    private func actionPrompt(theme: StockpileStatusTheme) -> some View {
        HStack(spacing: StockpileSpacing.xSmall) {
            Text(action.trustState.actionTitle)
                .font(StockpileTypography.caption.font.weight(.semibold))
                .foregroundStyle(theme.accent.color)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent.color)
        }
    }
}

public struct OperatorActiveJobCard: View {
    private let job: OperatorActiveJob
    private let style: OperatorDashboardViewStyle

    public init(job: OperatorActiveJob, style: OperatorDashboardViewStyle = .operational) {
        self.job = job
        self.style = style
    }

    public var body: some View {
        let theme = job.trustState.tone.theme

        return StockpileCard(appearance: .outlined) {
            VStack(alignment: .leading, spacing: style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium) {
                jobHeader

                Text(job.detail)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)

                ProgressView(value: job.clampedProgress)
                    .tint(theme.accent.color)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: StockpileSpacing.small) {
                        Text("\(Int(job.clampedProgress * 100))% complete")
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)

                        Spacer(minLength: 0)

                        if job.trustState == .reviewOnly {
                            Text("Review likely at completion")
                                .font(StockpileTypography.caption.font)
                                .foregroundStyle(theme.accent.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                        Text("\(Int(job.clampedProgress * 100))% complete")
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)

                        if job.trustState == .reviewOnly {
                            Text("Review likely at completion")
                                .font(StockpileTypography.caption.font)
                                .foregroundStyle(theme.accent.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
            .background(
                theme.background.color.opacity(style == .presentation ? 0.08 : (job.trustState == .processing ? 0.14 : 0.22)),
                in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
            )
            .overlay(alignment: .leading) {
                if style == .presentation {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.accent.color.opacity(0.5))
                        .frame(width: 3)
                        .padding(.vertical, StockpileSpacing.small)
                        .padding(.leading, StockpileSpacing.xSmall)
                }
            }
        }
    }

    @ViewBuilder
    private var jobHeader: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
            Text(job.pileName)
                .font(StockpileTypography.callout.font.weight(.semibold))
                .foregroundStyle(StockpilePalette.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: StockpileSpacing.small) {
                    StockpileBadge(job.stage.title, tone: job.trustState.tone)

                    Text(job.etaLabel)
                        .font(StockpileTypography.caption.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: StockpileSpacing.xxSmall) {
                    StockpileBadge(job.stage.title, tone: job.trustState.tone)

                    Text(job.etaLabel)
                        .font(StockpileTypography.caption.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

public struct OperatorRecentRunCard: View {
    private let run: OperatorRecentRun
    private let style: OperatorDashboardViewStyle

    public init(run: OperatorRecentRun, style: OperatorDashboardViewStyle = .operational) {
        self.run = run
        self.style = style
    }

    public var body: some View {
        let theme = run.trustState.tone.theme
        let emphasized = run.trustState != .verified

        return StockpileCard(appearance: emphasized ? .elevated : .outlined) {
            VStack(alignment: .leading, spacing: style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium) {
                Text(run.pileName)
                    .font(StockpileTypography.callout.font.weight(.semibold))
                    .foregroundStyle(StockpilePalette.ink.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                runMetaBlock(theme: theme)

                if let volumeLabel = run.volumeLabel {
                    runMeasurementTag(volumeLabel: volumeLabel, theme: theme)
                }

                Text(run.detail)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
            .background(
                theme.background.color.opacity(style == .presentation ? (emphasized ? 0.12 : 0.05) : (emphasized ? 0.24 : 0.10)),
                in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
            )
            .overlay(alignment: .leading) {
                if style == .presentation {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.accent.color.opacity(emphasized ? 0.75 : 0.35))
                        .frame(width: 3)
                        .padding(.vertical, StockpileSpacing.small)
                        .padding(.leading, StockpileSpacing.xSmall)
                }
            }
        }
    }

    @ViewBuilder
    private func runMetaBlock(theme: StockpileStatusTheme) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: StockpileSpacing.small) {
                StockpileBadge(run.trustState.title, tone: run.trustState.tone)
                runConfidenceLabel(theme: theme)
                runTimeLabel
            }

            VStack(alignment: .leading, spacing: StockpileSpacing.xxSmall) {
                StockpileBadge(run.trustState.title, tone: run.trustState.tone)
                runConfidenceLabel(theme: theme)
                runTimeLabel
            }
        }
    }

    @ViewBuilder
    private func runConfidenceLabel(theme: StockpileStatusTheme) -> some View {
        Text(run.confidenceLabel)
            .font(StockpileTypography.caption.font.weight(.semibold))
            .foregroundStyle(theme.accent.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var runTimeLabel: some View {
        Text(run.relativeTimeLabel)
            .font(StockpileTypography.caption.font)
            .foregroundStyle(StockpilePalette.mutedInk.color)
            .lineLimit(1)
    }

    private func runMeasurementTag(volumeLabel: String, theme: StockpileStatusTheme) -> some View {
        HStack(spacing: StockpileSpacing.xSmall) {
            Text("Volume")
                .font(StockpileTypography.caption.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)

            Text(volumeLabel)
                .font(style == .presentation ? StockpileTypography.callout.font.weight(.semibold) : StockpileTypography.body.font.weight(.semibold))
                .foregroundStyle(StockpilePalette.ink.color)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, StockpileSpacing.small)
        .padding(.vertical, StockpileSpacing.xSmall)
        .background(
            theme.background.color.opacity(style == .presentation ? 0.12 : 0.16),
            in: Capsule(style: .continuous)
        )
    }
}

private struct OperatorDashboardSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let style: OperatorDashboardViewStyle
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        style: OperatorDashboardViewStyle = .operational,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium) {
            VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                Text(title)
                    .font(style.sectionTitleFont)
                    .foregroundStyle(StockpilePalette.ink.color)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(style.sectionSubtitleFont)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
    }
}

private struct OperatorHeroMetricsRow: View {
    let summary: OperatorFacilitySummary
    let style: OperatorDashboardHeroStyle

    private let columns = [
        GridItem(.flexible(minimum: 120), spacing: StockpileSpacing.medium, alignment: .top),
        GridItem(.flexible(minimum: 120), spacing: StockpileSpacing.medium, alignment: .top)
    ]

    private let compactColumns = [
        GridItem(.flexible(minimum: 108), spacing: StockpileSpacing.small, alignment: .top),
        GridItem(.flexible(minimum: 108), spacing: StockpileSpacing.small, alignment: .top)
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: style == .prominent ? StockpileSpacing.small : StockpileSpacing.xSmall) {
                metricTiles
            }

            if style == .prominent {
                LazyVGrid(columns: columns, alignment: .leading, spacing: StockpileSpacing.small) {
                    metricTiles
                }
            } else {
                LazyVGrid(columns: compactColumns, alignment: .leading, spacing: StockpileSpacing.small) {
                    metricTiles
                }
            }
        }
    }

    @ViewBuilder
    private var metricTiles: some View {
        OperatorHeroMetricTile(
            label: "Recapture",
            value: "\(summary.blockedRuns)",
            note: summary.blockedRuns == 0 ? "Clear" : "Before release",
            tone: summary.blockedMetricTone,
            style: style
        )
        OperatorHeroMetricTile(
            label: "Review queue",
            value: "\(summary.reviewQueue)",
            note: summary.reviewQueue == 0 ? "Clear" : "Awaiting operator",
            tone: summary.reviewMetricTone,
            style: style
        )
        OperatorHeroMetricTile(
            label: "Verified today",
            value: "\(summary.verifiedToday)",
            note: "Released reports",
            tone: summary.verifiedMetricTone,
            style: style
        )
    }
}

private struct OperatorHeroMetricTile: View {
    let label: String
    let value: String
    let note: String
    let tone: StockpileStatusTone
    let style: OperatorDashboardHeroStyle

    var body: some View {
        let theme = tone.theme

        return VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
            Text(label)
                .font(StockpileTypography.caption.font)
                .foregroundStyle(theme.accent.color)
                .fixedSize(horizontal: false, vertical: true)

            Text(value)
                .font(valueFont)
                .minimumScaleFactor(0.7)
                .foregroundStyle(StockpilePalette.ink.color)

            Text(note)
                .font(noteFont)
                .foregroundStyle(StockpilePalette.mutedInk.color)
        }
        .padding(tilePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background.color.opacity(0.78), in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                .stroke(theme.accent.color.opacity(0.18), lineWidth: 1)
        )
    }

    private var valueFont: Font {
        switch style {
        case .prominent:
            return .system(size: 30, weight: .semibold, design: .rounded)
        case .compact:
            return StockpileTypography.sectionTitle.font.weight(.semibold)
        }
    }

    private var noteFont: Font {
        switch style {
        case .prominent:
            return StockpileTypography.caption.font
        case .compact:
            return StockpileTypography.caption.font
        }
    }

    private var tilePadding: CGFloat {
        switch style {
        case .prominent:
            return StockpileSpacing.small
        case .compact:
            return StockpileSpacing.small
        }
    }
}
