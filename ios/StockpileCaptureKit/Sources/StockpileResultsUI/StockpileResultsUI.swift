import SwiftUI
import StockpileDesignSystem

public enum StockpileResultsUINamespace {}

public enum StockpileResultOutcome: String, Codable, Sendable {
    case verified
    case reviewOnly = "review_only"
    case blocked
}

public enum StockpileResultBannerTone: String, Sendable {
    case green
    case amber
    case red
}

public enum StockpileResultRuntimeState: String, Codable, Sendable, Equatable {
    case empty
    case processing
    case ready
}

public struct StockpileConfidenceSummary: Codable, Sendable, Equatable {
    public let score: Int
    public let label: String
    public let summary: String

    public init(score: Int, label: String, summary: String) {
        self.score = score
        self.label = label
        self.summary = summary
    }
}

public enum StockpileConfidenceLensState: String, Codable, Sendable, Equatable {
    case high
    case medium
    case low

    public var title: String {
        switch self {
        case .high:
            return "High"
        case .medium:
            return "Medium"
        case .low:
            return "Low"
        }
    }

    public var tone: StockpileStatusTone {
        switch self {
        case .high:
            return .success
        case .medium:
            return .caution
        case .low:
            return .critical
        }
    }
}

public struct StockpileConfidenceLens: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let state: StockpileConfidenceLensState
    public let detail: String

    public init(id: String, label: String, state: StockpileConfidenceLensState, detail: String) {
        self.id = id
        self.label = label
        self.state = state
        self.detail = detail
    }
}

public struct StockpileMeasurement: Codable, Sendable, Equatable {
    public let volumeM3: Double
    public let weightTonnes: Double
    public let densityKgPerM3: Int

    public init(volumeM3: Double, weightTonnes: Double, densityKgPerM3: Int) {
        self.volumeM3 = volumeM3
        self.weightTonnes = weightTonnes
        self.densityKgPerM3 = densityKgPerM3
    }
}

public struct StockpileResultScreenModel: Codable, Sendable, Equatable {
    public let runID: String
    public let pileName: String
    public let outcome: StockpileResultOutcome
    public let runtimeState: StockpileResultRuntimeState
    public let confidence: StockpileConfidenceSummary
    public let measurement: StockpileMeasurement?
    public let warnings: [String]
    public let blockers: [String]
    public let recommendedAction: String
    public let confidenceLenses: [StockpileConfidenceLens]
    public let reportURL: URL?
    public let updatedAt: Date?
    public let reconstruction: StockpileResultReconstruction?

    enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case pileName
        case outcome
        case runtimeState
        case confidence
        case measurement
        case warnings
        case blockers
        case recommendedAction
        case confidenceLenses
        case reportURL
        case updatedAt
        case reconstruction
    }

    public init(
        runID: String,
        pileName: String,
        outcome: StockpileResultOutcome,
        runtimeState: StockpileResultRuntimeState = .ready,
        confidence: StockpileConfidenceSummary,
        measurement: StockpileMeasurement?,
        warnings: [String],
        blockers: [String],
        recommendedAction: String,
        confidenceLenses: [StockpileConfidenceLens] = [],
        reportURL: URL? = nil,
        updatedAt: Date? = nil,
        reconstruction: StockpileResultReconstruction? = nil
    ) {
        self.runID = runID
        self.pileName = pileName
        self.outcome = outcome
        self.runtimeState = runtimeState
        self.confidence = confidence
        self.measurement = measurement
        self.warnings = warnings
        self.blockers = blockers
        self.recommendedAction = recommendedAction
        self.confidenceLenses = confidenceLenses
        self.reportURL = reportURL
        self.updatedAt = updatedAt
        self.reconstruction = reconstruction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(String.self, forKey: .runID)
        pileName = try container.decode(String.self, forKey: .pileName)
        outcome = try container.decode(StockpileResultOutcome.self, forKey: .outcome)
        runtimeState = try container.decodeIfPresent(StockpileResultRuntimeState.self, forKey: .runtimeState) ?? .ready
        confidence = try container.decode(StockpileConfidenceSummary.self, forKey: .confidence)
        measurement = try container.decodeIfPresent(StockpileMeasurement.self, forKey: .measurement)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        blockers = try container.decodeIfPresent([String].self, forKey: .blockers) ?? []
        recommendedAction = try container.decode(String.self, forKey: .recommendedAction)
        confidenceLenses = try container.decodeIfPresent([StockpileConfidenceLens].self, forKey: .confidenceLenses) ?? []
        reportURL = try container.decodeIfPresent(URL.self, forKey: .reportURL)
        if let directDate = try? container.decode(Date.self, forKey: .updatedAt) {
            updatedAt = directDate
        } else if let rawDateString = try container.decodeIfPresent(String.self, forKey: .updatedAt) {
            updatedAt = Self.decodeUpdatedAt(from: rawDateString)
        } else {
            updatedAt = nil
        }
        reconstruction = try container.decodeIfPresent(StockpileResultReconstruction.self, forKey: .reconstruction)
    }

    private static func decodeUpdatedAt(from value: String) -> Date? {
        let fractionalSecondsFormatter = ISO8601DateFormatter()
        fractionalSecondsFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalSecondsFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        if let date = fractionalSecondsFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value)
    }

    public var bannerTitle: String {
        switch runtimeState {
        case .empty:
            return "Awaiting first run"
        case .processing:
            return "Processing live"
        case .ready:
            break
        }

        switch outcome {
        case .verified:
            return "Verified result"
        case .reviewOnly:
            return "Review required"
        case .blocked:
            return "Capture blocked"
        }
    }

    public var bannerSummary: String {
        switch runtimeState {
        case .empty:
            return "Nothing has been handed off for review yet. Once the first capture reaches the backend, this screen becomes the operator decision surface automatically."
        case .processing:
            return "The upload is already in motion and the result will replace this state automatically as soon as backend processing finishes."
        case .ready:
            break
        }

        switch outcome {
        case .verified:
            return "This run is ready for reporting with a strong confidence profile."
        case .reviewOnly:
            return "This run completed, but it still needs an operator cross-check before it is treated as final."
        case .blocked:
            return "We could not verify this run confidently enough to report it. Retake the capture with stronger reference visibility and toe coverage."
        }
    }

    public var showsMeasurement: Bool {
        runtimeState == .ready && outcome != .blocked && measurement != nil
    }

    public var bannerTone: StockpileResultBannerTone {
        switch outcome {
        case .verified:
            return .green
        case .reviewOnly:
            return .amber
        case .blocked:
            return .red
        }
    }

    var primaryStatusLabel: String {
        switch runtimeState {
        case .empty:
            return "Awaiting run"
        case .processing:
            return "Processing"
        case .ready:
            break
        }

        switch outcome {
        case .verified:
            return "Ready to report"
        case .reviewOnly:
            return "Needs review"
        case .blocked:
            return "Retake needed"
        }
    }

    var resultSummary: String {
        confidence.summary
    }

    var highlights: [StockpileResultHighlight] {
        guard runtimeState == .ready else {
            return []
        }

        var result: [StockpileResultHighlight] = []

        if let measurement, showsMeasurement {
            result.append(
                StockpileResultHighlight(
                    id: "volume",
                    label: "Volume",
                    value: String(format: "%.2f m³", measurement.volumeM3),
                    note: "Preferred report value"
                )
            )
            result.append(
                StockpileResultHighlight(
                    id: "weight",
                    label: "Weight",
                    value: String(format: "%.2f t", measurement.weightTonnes),
                    note: "\(measurement.densityKgPerM3) kg/m³ density"
                )
            )
        }

        result.append(
            StockpileResultHighlight(
                id: "confidence",
                label: "Confidence",
                value: "\(confidence.score)/100",
                note: "\(confidence.label) confidence",
                isEmphasized: true
            )
        )

        return result
    }

    var attentionTitle: String? {
        guard !attentionItems.isEmpty else {
            return nil
        }

        switch outcome {
        case .verified:
            return "Review notes"
        case .reviewOnly:
            return "Before you finalize"
        case .blocked:
            return "What to fix"
        }
    }

    var attentionItems: [StockpileResultAttentionItem] {
        guard runtimeState == .ready else {
            return []
        }

        return blockers.map { StockpileResultAttentionItem(kind: .blocker, message: $0) } +
            warnings.map { StockpileResultAttentionItem(kind: .warning, message: $0) }
    }

    public static let mockVerified = StockpileResultScreenModel(
        runID: "run_verified_001",
        pileName: "North Yard 03",
        outcome: .verified,
        runtimeState: .ready,
        confidence: StockpileConfidenceSummary(
            score: 92,
            label: "High",
            summary: "Capture quality, reference tracking, and reconstruction all passed the reporting threshold."
        ),
        measurement: StockpileMeasurement(volumeM3: 1711.20, weightTonnes: 3593.52, densityKgPerM3: 2100),
        warnings: [],
        blockers: [],
        recommendedAction: "Share the verified report with the site team.",
        confidenceLenses: [
            StockpileConfidenceLens(id: "surface", label: "Surface", state: .high, detail: "Surface coverage is strong across the stockpile crest and flanks."),
            StockpileConfidenceLens(id: "toe", label: "Toe", state: .high, detail: "Toe boundary stayed visible through the full perimeter sweep.")
        ],
        reportURL: nil,
        reconstruction: .demoVerified
    )

    public static let mockReviewOnly = StockpileResultScreenModel(
        runID: "run_review_001",
        pileName: "North Yard 03",
        outcome: .reviewOnly,
        runtimeState: .ready,
        confidence: StockpileConfidenceSummary(
            score: 58,
            label: "Moderate",
            summary: "Calibration recovered but still needs a benchmark cross-check."
        ),
        measurement: StockpileMeasurement(volumeM3: 2528.43, weightTonnes: 5309.70, densityKgPerM3: 2100),
        warnings: ["Toe coverage is partial on the north edge."],
        blockers: ["Projection and camera-height checks are not fully aligned."],
        recommendedAction: "Compare this run against the latest benchmark before treating it as final.",
        confidenceLenses: [
            StockpileConfidenceLens(id: "surface", label: "Surface", state: .medium, detail: "Surface reconstruction is usable, but the far edge needs a quick visual review."),
            StockpileConfidenceLens(id: "toe", label: "Toe", state: .low, detail: "Toe visibility dropped on one side, so this should stay review-only.")
        ],
        reportURL: nil,
        reconstruction: .demoReview
    )

    public static let mockBlocked = StockpileResultScreenModel(
        runID: "run_blocked_001",
        pileName: "North Yard 03",
        outcome: .blocked,
        runtimeState: .ready,
        confidence: StockpileConfidenceSummary(
            score: 29,
            label: "Low",
            summary: "Reference recovery was too weak to publish a trustworthy result."
        ),
        measurement: nil,
        warnings: ["Only one tagged reference was visible through most of the walkaround."],
        blockers: ["Scale disagreement exceeded the reporting threshold."],
        recommendedAction: "Retake the capture with 2-3 tagged references visible together and full toe coverage.",
        confidenceLenses: [
            StockpileConfidenceLens(id: "surface", label: "Surface", state: .low, detail: "The reconstructed surface has gaps that should not be used for reporting."),
            StockpileConfidenceLens(id: "toe", label: "Toe", state: .low, detail: "Toe coverage was too weak to verify the footprint.")
        ],
        reportURL: nil,
        reconstruction: .demoBlocked
    )

    public static func emptyOperational(
        pileName: String,
        usesLiveCapture: Bool
    ) -> StockpileResultScreenModel {
        StockpileResultScreenModel(
            runID: "",
            pileName: pileName,
            outcome: .reviewOnly,
            runtimeState: .empty,
            confidence: StockpileConfidenceSummary(
                score: 0,
                label: "Pending",
                summary: usesLiveCapture
                    ? "Record one complete walkaround and the review tab will switch over automatically once processing starts."
                    : "Upload one walkaround clip and the review tab will switch over automatically once processing starts."
            ),
            measurement: nil,
            warnings: [],
            blockers: [],
            recommendedAction: usesLiveCapture
                ? "Start a steady perimeter capture with tagged references visible early in the lap."
                : "Select the next walkaround clip and finish the upload handoff.",
            reportURL: nil
        )
    }

    public static func processingOperational(
        pileName: String,
        summary: String,
        nextStep: String
    ) -> StockpileResultScreenModel {
        StockpileResultScreenModel(
            runID: "",
            pileName: pileName,
            outcome: .reviewOnly,
            runtimeState: .processing,
            confidence: StockpileConfidenceSummary(
                score: 0,
                label: "In progress",
                summary: summary
            ),
            measurement: nil,
            warnings: [],
            blockers: [],
            recommendedAction: nextStep,
            reportURL: nil
        )
    }
}

public enum StockpileResultScreenStyle: Sendable, Equatable {
    case operational
    case presentation
}

struct StockpileResultHighlight: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
    let note: String?
    let isEmphasized: Bool

    init(
        id: String,
        label: String,
        value: String,
        note: String? = nil,
        isEmphasized: Bool = false
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.note = note
        self.isEmphasized = isEmphasized
    }
}

struct StockpileResultAttentionItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case blocker
        case warning

        var label: String {
            switch self {
            case .blocker:
                return "Blocker"
            case .warning:
                return "Warning"
            }
        }

        var systemImage: String {
            switch self {
            case .blocker:
                return "xmark.octagon.fill"
            case .warning:
                return "exclamationmark.triangle.fill"
            }
        }

        var tone: StockpileStatusTone {
            switch self {
            case .blocker:
                return .critical
            case .warning:
                return .caution
            }
        }
    }

    let kind: Kind
    let message: String

    var id: String {
        "\(kind.rawValue)-\(message)"
    }
}

public struct StockpileResultScreenView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let model: StockpileResultScreenModel
    private let style: StockpileResultScreenStyle
    private let usesScrollView: Bool

    public init(
        model: StockpileResultScreenModel,
        style: StockpileResultScreenStyle = .operational,
        usesScrollView: Bool = true
    ) {
        self.model = model
        self.style = style
        self.usesScrollView = usesScrollView
    }

    public var body: some View {
        Group {
            if usesScrollView {
                ScrollView {
                    resultContent
                }
                .scrollIndicators(.hidden)
            } else {
                resultContent
            }
        }
        .background(StockpilePalette.canvas.color.ignoresSafeArea())
    }

    private var sectionSpacing: CGFloat {
        switch style {
        case .presentation:
            return StockpileSpacing.medium
        case .operational:
            return horizontalSizeClass == .compact ? StockpileSpacing.medium : StockpileSpacing.large
        }
    }

    private var designTone: StockpileStatusTone {
        guard model.runtimeState == .ready else {
            return .info
        }

        switch model.bannerTone {
        case .green:
            return .success
        case .amber:
            return .caution
        case .red:
            return .critical
        }
    }

    private var resultContent: some View {
        LazyVStack(alignment: .leading, spacing: sectionSpacing) {
            if model.runtimeState == .ready {
                ResultSummaryCard(
                    model: model,
                    tone: designTone,
                    style: style
                )

                if let measurement = model.measurement, model.showsMeasurement, style == .operational {
                    ResultMeasurementCard(
                        measurement: measurement,
                        outcome: model.outcome,
                        style: style
                    )
                }

                if model.showsInspectionSection {
                    ResultInspectionCard(
                        model: model,
                        style: style
                    )
                }

                if let reconstruction = model.reconstruction, model.showsReconstruction {
                    StockpileResultReconstructionCard(
                        reconstruction: reconstruction,
                        tone: designTone,
                        style: style
                    )
                }
            } else {
                ResultRuntimeStateCard(
                    model: model,
                    tone: designTone,
                    style: style
                )
            }
        }
        .modifier(ResultScreenLayoutModifier(style: style))
    }
}

private struct ResultRuntimeStateCard: View {
    let model: StockpileResultScreenModel
    let tone: StockpileStatusTone
    let style: StockpileResultScreenStyle

    var body: some View {
        let theme = tone.theme

        return StockpileCard(appearance: style == .presentation ? .elevated : .outlined) {
            VStack(alignment: .leading, spacing: style == .presentation ? StockpileSpacing.medium : StockpileSpacing.large) {
                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    StockpileBadge(model.primaryStatusLabel, tone: tone)

                    Text(model.statusHeadline)
                        .font(style == .presentation ? StockpileTypography.sectionTitle.font.weight(.bold) : StockpileTypography.hero.font)
                        .foregroundStyle(StockpilePalette.ink.color)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(model.bannerSummary)
                        .font(StockpileTypography.body.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }

                runtimeSupportPanel(theme: theme)

                ResultNextStepPanel(
                    title: model.nextActionTitle,
                    message: model.recommendedAction,
                    tone: tone,
                    systemImage: model.nextActionSystemImage,
                    style: style
                )
                .background(
                    theme.background.color.opacity(style == .presentation ? 0.54 : 0.72),
                    in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                )
            }
        }
    }

    @ViewBuilder
    private func runtimeSupportPanel(theme: StockpileStatusTheme) -> some View {
        switch model.runtimeState {
        case .empty:
            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                Text("What happens next")
                    .font(StockpileTypography.caption.font.weight(.semibold))
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                    runtimeChecklistRow(
                        title: "Capture or upload a walkaround",
                        detail: "The review screen stays quiet until the first handoff has durable content on the server.",
                        systemImage: "camera.aperture"
                    )
                    runtimeChecklistRow(
                        title: "Processing opens automatically",
                        detail: "As soon as the backend acknowledges the run, this tab shifts into live processing and then into the final decision state.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
            }
            .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                StockpilePalette.surface.color.opacity(style == .presentation ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                    .stroke(StockpilePalette.border.color.opacity(0.65), lineWidth: 1)
            )
        case .processing:
            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                Text("Live processing")
                    .font(StockpileTypography.caption.font.weight(.semibold))
                    .foregroundStyle(theme.accent.color)

                Text(model.confidence.summary)
                    .font(style == .presentation ? StockpileTypography.callout.font : StockpileTypography.body.font)
                    .foregroundStyle(StockpilePalette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)

                Text("This tab will switch to the decision-ready report as soon as the worker returns a result.")
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.background.color.opacity(style == .presentation ? 0.46 : 0.68),
                in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
            )
        case .ready:
            EmptyView()
        }
    }

    private func runtimeChecklistRow(title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: StockpileSpacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(tone.theme.accent.color)
                .frame(width: 18, alignment: .center)
                .padding(.top, StockpileSpacing.xxxSmall)

            VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
                Text(title)
                    .font(StockpileTypography.callout.font.weight(.semibold))
                    .foregroundStyle(StockpilePalette.ink.color)

                Text(detail)
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ResultScreenLayoutModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let style: StockpileResultScreenStyle

    func body(content: Content) -> some View {
        switch style {
        case .operational:
            content
                .padding(.horizontal, operationalHorizontalPadding)
                .padding(.top, operationalTopPadding)
                .padding(.bottom, operationalBottomPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(StockpilePalette.canvas.color.ignoresSafeArea())
        case .presentation:
            content
                .padding(.horizontal, StockpileSpacing.medium)
                .padding(.top, StockpileSpacing.large)
                .padding(.bottom, StockpileSpacing.large)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var operationalHorizontalPadding: CGFloat {
        horizontalSizeClass == .compact ? StockpileSpacing.medium : StockpileSpacing.large
    }

    private var operationalTopPadding: CGFloat {
        horizontalSizeClass == .compact ? StockpileSpacing.small : StockpileSpacing.medium
    }

    private var operationalBottomPadding: CGFloat {
        horizontalSizeClass == .compact ? StockpileSpacing.xLarge : StockpileSpacing.large
    }
}

private struct ResultSummaryCard: View {
    let model: StockpileResultScreenModel
    let tone: StockpileStatusTone
    let style: StockpileResultScreenStyle

    var body: some View {
        let theme = tone.theme

        StockpileCard {
            VStack(alignment: .leading, spacing: style == .presentation ? StockpileSpacing.medium : StockpileSpacing.large) {
                VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                    StockpileBadge(model.primaryStatusLabel, tone: tone)

                    Text(model.statusHeadline)
                        .font(style == .presentation ? StockpileTypography.sectionTitle.font.weight(.bold) : StockpileTypography.hero.font)
                        .foregroundStyle(StockpilePalette.ink.color)
                        .lineLimit(style == .presentation ? 3 : nil)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(model.bannerSummary)
                        .font(StockpileTypography.body.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if style == .presentation, let measurement = model.measurement, model.showsMeasurement {
                    ResultHeroMeasurementLockup(
                        measurement: measurement,
                        tone: tone,
                        style: style
                    )
                }

                if style == .presentation {
                    ResultNextStepPanel(
                        title: model.nextActionTitle,
                        message: model.recommendedAction,
                        tone: tone,
                        systemImage: model.nextActionSystemImage,
                        style: style
                    )
                    .background(
                        theme.background.color.opacity(model.outcome == .blocked ? 0.54 : 0.64),
                        in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                    )

                    confidenceSection

                    ResultContextStrip(
                        pileName: model.pileName,
                        runID: model.runID,
                        tone: tone,
                        style: style
                    )
                } else {
                    ResultContextStrip(
                        pileName: model.pileName,
                        runID: model.runID,
                        tone: tone,
                        style: style
                    )

                    confidenceSection

                    ResultNextStepPanel(
                        title: model.nextActionTitle,
                        message: model.recommendedAction,
                        tone: tone,
                        systemImage: model.nextActionSystemImage,
                        style: style
                    )
                    .background(
                        theme.background.color.opacity(model.outcome == .blocked ? 0.72 : 1),
                        in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                    )

                    if let reportURL = model.reportURL {
                        ResultBackendReportCard(
                            reportURL: reportURL,
                            tone: tone
                        )
                    }
                }
            }
        }
    }

    private var confidenceSection: some View {
        VStack(alignment: .leading, spacing: style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium) {
            Text(style == .presentation ? "Release confidence" : "Confidence")
                .font(StockpileTypography.caption.font.weight(style == .presentation ? .semibold : .regular))
                .foregroundStyle(StockpilePalette.mutedInk.color)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                    ResultConfidenceScore(
                        score: model.confidence.score,
                        tone: tone,
                        style: style
                    )

                    confidenceNarrative
                }

                VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                    ResultConfidenceScore(
                        score: model.confidence.score,
                        tone: tone,
                        style: style
                    )

                    confidenceNarrative
                }
            }
        }
    }

    private var confidenceNarrative: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
            Text(model.confidenceSummaryTitle)
                .font(StockpileTypography.sectionTitle.font)
                .foregroundStyle(StockpilePalette.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            Text(model.resultSummary)
                .font(StockpileTypography.body.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StockpileSpacing.small) {
                    StockpileBadge(model.confidence.label, tone: tone)

                    if let confidenceNote = model.confidenceNote {
                        Text(confidenceNote)
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)
                            .lineLimit(1)
                    }
                }

                VStack(alignment: .leading, spacing: StockpileSpacing.xxSmall) {
                    StockpileBadge(model.confidence.label, tone: tone)

                    if let confidenceNote = model.confidenceNote {
                        Text(confidenceNote)
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct ResultContextStrip: View {
    let pileName: String
    let runID: String
    let tone: StockpileStatusTone
    let style: StockpileResultScreenStyle

    var body: some View {
        if style == .presentation {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: StockpileSpacing.small) {
                    presentationContextLabel(
                        title: "Pile",
                        value: pileName,
                        systemImage: "shippingbox.fill",
                        tone: tone
                    )

                    Circle()
                        .fill(StockpilePalette.border.color)
                        .frame(width: 4, height: 4)

                    presentationRunCaption

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                    presentationContextLabel(
                        title: "Pile",
                        value: pileName,
                        systemImage: "shippingbox.fill",
                        tone: tone
                    )

                    presentationRunCaption
                }
            }
        } else {
            let theme = tone.theme

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StockpileSpacing.medium) {
                    ResultMetaPill(
                        title: "Pile",
                        value: pileName,
                        tone: tone,
                        systemImage: "shippingbox.fill"
                    )

                    ResultMetaPill(
                        title: "Run ID",
                        value: runID,
                        tone: tone,
                        systemImage: "number"
                    )
                }

                VStack(spacing: StockpileSpacing.small) {
                    ResultMetaPill(
                        title: "Pile",
                        value: pileName,
                        tone: tone,
                        systemImage: "shippingbox.fill"
                    )

                    ResultMetaPill(
                        title: "Run ID",
                        value: runID,
                        tone: tone,
                        systemImage: "number"
                    )
                }
            }
            .background(
                theme.background.color.opacity(0.38),
                in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
            )
        }
    }

    private func presentationContextLabel(
        title: String,
        value: String,
        systemImage: String,
        tone: StockpileStatusTone
    ) -> some View {
        HStack(spacing: StockpileSpacing.xSmall) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(tone.theme.accent.color)

            Text(title.uppercased())
                .font(StockpileTypography.caption.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)

            Text(value)
                .font(StockpileTypography.callout.font.weight(.semibold))
                .foregroundStyle(StockpilePalette.ink.color)
                .lineLimit(style == .presentation ? 2 : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var presentationRunCaption: some View {
        HStack(spacing: StockpileSpacing.xSmall) {
            Image(systemName: "number")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(StockpilePalette.mutedInk.color)

            Text("Run \(runID)")
                .font(StockpileTypography.caption.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
                .lineLimit(1)
        }
    }
}

private struct ResultHeroMeasurementLockup: View {
    let measurement: StockpileMeasurement
    let tone: StockpileStatusTone
    let style: StockpileResultScreenStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: StockpileSpacing.medium) {
                    metricColumn(
                        title: "Volume",
                        value: String(format: "%.2f m³", measurement.volumeM3),
                        note: "Preferred report value"
                    )

                    metricColumn(
                        title: "Weight",
                        value: String(format: "%.2f t", measurement.weightTonnes),
                        note: "\(measurement.densityKgPerM3) kg/m³ density"
                    )
                }

                VStack(spacing: StockpileSpacing.small) {
                    metricColumn(
                        title: "Volume",
                        value: String(format: "%.2f m³", measurement.volumeM3),
                        note: "Preferred report value"
                    )

                    metricColumn(
                        title: "Weight",
                        value: String(format: "%.2f t", measurement.weightTonnes),
                        note: "\(measurement.densityKgPerM3) kg/m³ density"
                    )
                }
            }

            if style == .presentation {
                Text("Using \(measurement.densityKgPerM3) kg/m³ bulk density")
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metricColumn(title: String, value: String, note: String) -> some View {
        let theme = tone.theme

        return VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
            Text(title.uppercased())
                .font(StockpileTypography.caption.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)

            Text(value)
                .font(
                    style == .presentation
                        ? .system(size: 36, weight: .bold, design: .rounded)
                        : StockpileTypography.metric.font
                )
                .foregroundStyle(StockpilePalette.ink.color)
                .minimumScaleFactor(0.82)
                .lineLimit(1)

            Text(note)
                .font(StockpileTypography.caption.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
        .padding(.vertical, style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
        .background(
            (style == .presentation ? StockpilePalette.surface.color.opacity(0.7) : theme.background.color.opacity(0.46)),
            in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StockpileCornerRadius.card, style: .continuous)
                .stroke(
                    style == .presentation ? StockpilePalette.border.color.opacity(0.6) : theme.accent.color.opacity(0.08),
                    lineWidth: 1
                )
        )
    }
}

private struct ResultNextStepPanel: View {
    let title: String
    let message: String
    let tone: StockpileStatusTone
    let systemImage: String
    let style: StockpileResultScreenStyle

    var body: some View {
        let theme = tone.theme

        return HStack(alignment: .top, spacing: StockpileSpacing.medium) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent.color)
                .padding(.top, StockpileSpacing.xxxSmall)

            VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                Text(title)
                    .font(style == .presentation ? StockpileTypography.caption.font.weight(.semibold) : StockpileTypography.callout.font.weight(.semibold))
                    .textCase(style == .presentation ? .uppercase : nil)
                    .foregroundStyle(StockpilePalette.ink.color)

                Text(message)
                    .font(style == .presentation ? StockpileTypography.callout.font.weight(.medium) : StockpileTypography.body.font)
                    .foregroundStyle(StockpilePalette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ResultConfidenceScore: View {
    let score: Int
    let tone: StockpileStatusTone
    let style: StockpileResultScreenStyle

    var body: some View {
        let theme = tone.theme

        return VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: StockpileSpacing.xxxSmall) {
                Text("\(score)")
                    .font(
                        style == .presentation
                            ? .system(size: 36, weight: .bold, design: .rounded)
                            : StockpileTypography.metric.font
                    )
                    .foregroundStyle(StockpilePalette.ink.color)

                Text("/100")
                    .font(StockpileTypography.callout.font.weight(.semibold))
                    .foregroundStyle(StockpilePalette.mutedInk.color)
            }

            Text("confidence")
                .font(StockpileTypography.caption.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
        }
        .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
        .background(
            style == .presentation ? StockpilePalette.surface.color.opacity(0.78) : theme.background.color,
            in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                .stroke(
                    style == .presentation ? StockpilePalette.border.color.opacity(0.65) : theme.accent.color.opacity(0.2),
                    lineWidth: 1
                )
        )
    }
}

private struct ResultMetaPill: View {
    let title: String
    let value: String
    let tone: StockpileStatusTone
    let systemImage: String

    var body: some View {
        let theme = tone.theme

        return HStack(alignment: .top, spacing: StockpileSpacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Text(value)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.ink.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, StockpileSpacing.medium)
        .padding(.vertical, StockpileSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.background.color.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

private struct ResultMeasurementCard: View {
    let measurement: StockpileMeasurement
    let outcome: StockpileResultOutcome
    let style: StockpileResultScreenStyle

    var body: some View {
        StockpileCard(appearance: .outlined) {
            VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
                    Text("Measurements")
                        .font(StockpileTypography.sectionTitle.font)
                        .foregroundStyle(StockpilePalette.ink.color)

                    Text(subtitle)
                        .font(StockpileTypography.callout.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if style == .presentation {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: StockpileSpacing.small) {
                            ResultMeasurementRow(
                                title: "Volume",
                                value: String(format: "%.2f m³", measurement.volumeM3)
                            )

                            ResultMeasurementRow(
                                title: "Weight",
                                value: String(format: "%.2f t", measurement.weightTonnes)
                            )
                        }

                        VStack(spacing: StockpileSpacing.small) {
                            ResultMeasurementRow(
                                title: "Volume",
                                value: String(format: "%.2f m³", measurement.volumeM3)
                            )

                            ResultMeasurementRow(
                                title: "Weight",
                                value: String(format: "%.2f t", measurement.weightTonnes)
                            )
                        }
                    }

                    ResultMeasurementRow(
                        title: "Density",
                        value: "\(measurement.densityKgPerM3) kg/m³"
                    )
                } else {
                    VStack(spacing: StockpileSpacing.small) {
                        ResultMeasurementRow(
                            title: "Volume",
                            value: String(format: "%.2f m³", measurement.volumeM3)
                        )

                        ResultMeasurementRow(
                            title: "Weight",
                            value: String(format: "%.2f t", measurement.weightTonnes)
                        )

                        ResultMeasurementRow(
                            title: "Density",
                            value: "\(measurement.densityKgPerM3) kg/m³"
                        )
                    }
                }
            }
        }
    }

    private var subtitle: String {
        switch outcome {
        case .verified:
            return "These values are ready to carry into the site report."
        case .reviewOnly:
            return "Treat these as provisional until the operator review is complete."
        case .blocked:
            return "Measurements are unavailable for blocked runs."
        }
    }
}

private struct ResultBackendReportCard: View {
    let reportURL: URL
    let tone: StockpileStatusTone

    var body: some View {
        let theme = tone.theme

        return StockpileCard(appearance: .outlined) {
            VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                ViewThatFits(in: .horizontal) {
                    backendReportHeader(theme: theme, stacksVertically: false)
                    backendReportHeader(theme: theme, stacksVertically: true)
                }

                Link(destination: reportURL) {
                    HStack(spacing: StockpileSpacing.small) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Open backend report")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(StockpileActionButtonStyle(role: .secondary))
            }
        }
    }

    @ViewBuilder
    private func backendReportHeader(
        theme: StockpileStatusTheme,
        stacksVertically: Bool
    ) -> some View {
        if stacksVertically {
            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                headerIcon(theme: theme)
                headerCopy
            }
        } else {
            HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                headerIcon(theme: theme)
                headerCopy
            }
        }
    }

    private func headerIcon(theme: StockpileStatusTheme) -> some View {
        Image(systemName: "doc.text.magnifyingglass")
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.accent.color)
            .frame(width: 24, height: 24)
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
            Text("Backend report")
                .font(StockpileTypography.callout.font.weight(.semibold))
                .foregroundStyle(StockpilePalette.ink.color)

            Text("Open the stored server report for this run to review the backend output and supporting diagnostics.")
                .font(StockpileTypography.caption.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ResultMeasurementRow: View {
    let title: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: StockpileSpacing.medium) {
                Text(title)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Spacer(minLength: 0)

                Text(value)
                    .font(StockpileTypography.sectionTitle.font)
                    .foregroundStyle(StockpilePalette.ink.color)
                    .multilineTextAlignment(.trailing)
            }

            VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
                Text(title)
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Text(value)
                    .font(StockpileTypography.sectionTitle.font)
                    .foregroundStyle(StockpilePalette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, StockpileSpacing.medium)
        .padding(.vertical, StockpileSpacing.small)
        .background(
            StockpilePalette.surface.color,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StockpilePalette.border.color, lineWidth: 1)
        )
    }
}

private struct ResultInspectionCard: View {
    let model: StockpileResultScreenModel
    let style: StockpileResultScreenStyle

    var body: some View {
        StockpileCard(appearance: style == .presentation ? .elevated : .outlined) {
            VStack(alignment: .leading, spacing: style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium) {
                VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
                    Text(model.inspectionTitle)
                        .font(StockpileTypography.sectionTitle.font)
                        .foregroundStyle(StockpilePalette.ink.color)

                    Text(model.inspectionSummary)
                        .font(StockpileTypography.callout.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.confidenceLenses.isEmpty {
                    VStack(alignment: .leading, spacing: style == .presentation ? StockpileSpacing.xSmall : StockpileSpacing.small) {
                        if style == .presentation {
                            Text("Confidence checks")
                                .font(StockpileTypography.caption.font.weight(.semibold))
                                .foregroundStyle(StockpilePalette.mutedInk.color)
                        }

                        ForEach(model.confidenceLenses) { lens in
                            ResultInspectionLensRow(
                                lens: lens,
                                style: style
                            )
                        }
                    }
                }

                if !model.attentionItems.isEmpty {
                    if !model.confidenceLenses.isEmpty {
                        Divider()
                            .overlay(StockpilePalette.border.color.opacity(0.7))
                    }

                    VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                        Text(model.attentionSectionTitle)
                            .font(style == .presentation ? StockpileTypography.caption.font.weight(.semibold) : StockpileTypography.callout.font.weight(.semibold))
                            .foregroundStyle(style == .presentation ? StockpilePalette.mutedInk.color : StockpilePalette.ink.color)

                        ForEach(model.attentionItems) { item in
                            ResultAttentionRow(
                                item: item,
                                style: style
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct ResultInspectionLensRow: View {
    let lens: StockpileConfidenceLens
    let style: StockpileResultScreenStyle

    var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: StockpileSpacing.medium) {
                    Text(lens.label)
                        .font(StockpileTypography.callout.font.weight(.semibold))
                        .foregroundStyle(StockpilePalette.ink.color)

                    Spacer(minLength: 0)

                    StockpileBadge(lens.state.title, tone: lens.state.tone)
                }

                VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                    Text(lens.label)
                        .font(StockpileTypography.callout.font.weight(.semibold))
                        .foregroundStyle(StockpilePalette.ink.color)

                    StockpileBadge(lens.state.title, tone: lens.state.tone)
                }
            }

            Text(lens.detail)
                .font(style == .presentation ? StockpileTypography.caption.font : StockpileTypography.callout.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if style == .presentation {
                Capsule()
                    .fill(lens.state.tone.theme.accent.color.opacity(0.9))
                    .frame(width: 4)
                    .padding(.vertical, StockpileSpacing.small)
                    .padding(.leading, 2)
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if style == .presentation {
            RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                .fill(StockpilePalette.surface.color.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                        .stroke(StockpilePalette.border.color.opacity(0.55), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                .fill(lens.state.tone.theme.background.color.opacity(0.5))
        }
    }
}

private struct ResultAttentionRow: View {
    let item: StockpileResultAttentionItem
    let style: StockpileResultScreenStyle

    var body: some View {
        let theme = item.kind.tone.theme

        return HStack(alignment: .top, spacing: StockpileSpacing.medium) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent.color)
                .frame(width: 20, alignment: .center)
                .padding(.top, StockpileSpacing.xxxSmall)

            VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
                Text(item.kind.label.uppercased())
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(theme.accent.color)

                Text(item.message)
                    .font(style == .presentation ? StockpileTypography.callout.font : StockpileTypography.body.font)
                    .foregroundStyle(StockpilePalette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(theme: theme))
        .overlay(alignment: .leading) {
            if style == .presentation {
                Capsule()
                    .fill(theme.accent.color.opacity(0.92))
                    .frame(width: 4)
                    .padding(.vertical, StockpileSpacing.small)
                    .padding(.leading, 2)
            }
        }
    }

    @ViewBuilder
    private func rowBackground(theme: StockpileStatusTheme) -> some View {
        if style == .presentation {
            RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                .fill(StockpilePalette.surface.color.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                        .stroke(StockpilePalette.border.color.opacity(0.55), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                .fill(theme.background.color.opacity(0.48))
        }
    }
}

private extension StockpileResultScreenModel {
    var statusHeadline: String {
        switch runtimeState {
        case .empty:
            return "Your next result will appear here"
        case .processing:
            return "This capture is being turned into a result"
        case .ready:
            break
        }

        switch outcome {
        case .verified:
            return "Verified and ready to report"
        case .reviewOnly:
            return "Review before you treat this as final"
        case .blocked:
            return "Retake this run before reporting"
        }
    }

    var confidenceSummaryTitle: String {
        switch runtimeState {
        case .empty:
            return "Awaiting first handoff"
        case .processing:
            return "Processing is live"
        case .ready:
            break
        }

        switch outcome {
        case .verified:
            return "Strong reporting confidence"
        case .reviewOnly:
            return "Usable, but still operator-led"
        case .blocked:
            return "Not strong enough to publish"
        }
    }

    var confidenceNote: String? {
        switch runtimeState {
        case .empty:
            return "No report yet"
        case .processing:
            return "Updates automatically"
        case .ready:
            break
        }

        switch outcome {
        case .verified:
            return "Clear to share"
        case .reviewOnly:
            return "Benchmark cross-check advised"
        case .blocked:
            return "Retake required"
        }
    }

    var nextActionTitle: String {
        switch runtimeState {
        case .empty:
            return "Next capture"
        case .processing:
            return "Processing status"
        case .ready:
            break
        }

        switch outcome {
        case .verified:
            return "Next action"
        case .reviewOnly:
            return "Operator decision"
        case .blocked:
            return "Retake action"
        }
    }

    var nextActionSystemImage: String {
        switch runtimeState {
        case .empty:
            return "camera.fill"
        case .processing:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .ready:
            break
        }

        switch outcome {
        case .verified:
            return "arrow.up.right.circle.fill"
        case .reviewOnly:
            return "person.badge.shield.checkmark.fill"
        case .blocked:
            return "arrow.clockwise.circle.fill"
        }
    }

    var inspectionTitle: String {
        guard runtimeState == .ready else {
            return "Inspection"
        }

        switch outcome {
        case .verified:
            return "Inspection summary"
        case .reviewOnly:
            return "What to verify before finalizing"
        case .blocked:
            return "Why this run was blocked"
        }
    }

    var inspectionSummary: String {
        guard runtimeState == .ready else {
            return "Inspection details will appear here once a result is ready."
        }

        switch outcome {
        case .verified:
            return "A quick read on the surfaces and edges that supported this outcome."
        case .reviewOnly:
            return "Use these checks to decide whether the provisional result is acceptable."
        case .blocked:
            return "These issues are the clearest reasons the run should be retaken."
        }
    }

    var attentionSectionTitle: String {
        guard runtimeState == .ready else {
            return "Notes"
        }

        switch outcome {
        case .verified:
            return "Notes"
        case .reviewOnly:
            return "Needs attention"
        case .blocked:
            return "Explicit blockers"
        }
    }

    var showsInspectionSection: Bool {
        runtimeState == .ready && (!confidenceLenses.isEmpty || !attentionItems.isEmpty)
    }

    var showsReconstruction: Bool {
        runtimeState == .ready && outcome != .blocked
    }
}
