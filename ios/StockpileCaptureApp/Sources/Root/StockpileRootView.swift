import SwiftUI
import StockpileAppShell
import StockpileDesignSystem
import StockpileOperatorDashboard
import StockpileResultsUI

private enum StockpileRootTab: Hashable, CaseIterable {
    case dashboard
    case capture
    case review
    case history

    var title: String {
        switch self {
        case .dashboard:
            return "Home"
        case .capture:
            return "Capture"
        case .review:
            return "Review"
        case .history:
            return "History"
        }
    }

    var navigationTitle: String {
        switch self {
        case .dashboard:
            return "Home"
        case .capture:
            return "Capture"
        case .review:
            return "Review"
        case .history:
            return "History"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            return "house.fill"
        case .capture:
            return "camera.fill"
        case .review:
            return "checkmark.circle"
        case .history:
            return "clock.arrow.circlepath"
        }
    }

    init(shellSection: StockpileShellSection) {
        switch shellSection {
        case .dashboard:
            self = .dashboard
        case .capture:
            self = .capture
        case .review:
            self = .review
        }
    }

    var shellSection: StockpileShellSection {
        switch self {
        case .dashboard:
            return .dashboard
        case .capture:
            return .capture
        case .review:
            return .review
        case .history:
            return .review
        }
    }
}

struct StockpileRootView: View {
    @ObservedObject var session: StockpileAppSession
    @State private var selectedTab: StockpileRootTab

    init(session: StockpileAppSession) {
        self.session = session
        let initialTab = StockpileRootTab(shellSection: session.preferredLandingSection)
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        operationalRoot
            .tint(StockpilePalette.accent.color)
            .background {
                StockpileShellBackground()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let banner = session.operationalStatusBanner {
                    StockpileGuidanceBanner(
                        title: banner.title,
                        message: banner.message,
                        tone: banner.tone
                    )
                    .padding(.horizontal, StockpileSpacing.medium)
                    .padding(.top, StockpileSpacing.xSmall)
                }
            }
            .onChange(of: selectedTab) { _, newValue in
                let shellSection = newValue.shellSection
                if session.shellStore.selectedSection != shellSection {
                    session.shellStore.selectedSection = shellSection
                }
            }
            .onChange(of: session.shellStore.selectedSection) { _, newValue in
                let mappedTab = StockpileRootTab(shellSection: newValue)
                if selectedTab != mappedTab {
                    selectedTab = mappedTab
                }
            }
    }

    private var operationalRoot: some View {
        TabView(selection: $selectedTab) {
            rootTab(.dashboard, showsNavigationTitle: false) {
                OperatorDashboardView(content: session.shellStore.dashboardContent)
            }

            rootTab(.capture) {
                CaptureFeatureView(store: session.captureFeatureStore)
            }

            rootTab(.review) {
                reviewScreen
            }

            rootTab(.history) {
                HistoryScreen(models: session.historyModels)
            }
        }
        .toolbar(.visible, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(.thinMaterial, for: .tabBar)
    }

    @ViewBuilder
    private func rootTab<Content: View>(
        _ tab: StockpileRootTab,
        showsNavigationTitle: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .modifier(NavigationTitleModifier(title: tab.navigationTitle, isEnabled: showsNavigationTitle))
        }
        .tabItem {
            Label(tab.title, systemImage: tab.systemImage)
        }
        .tag(tab)
    }

    private var reviewScreen: some View {
        StockpileResultScreenView(
            model: session.reviewQueueModel,
            style: .operational
        )
    }
}

private struct HistoryScreen: View {
    let models: [StockpileResultScreenModel]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                header

                if models.isEmpty {
                    emptyState
                } else {
                    ForEach(models, id: \.runID) { model in
                        NavigationLink {
                            StockpileResultScreenView(
                                model: model,
                                style: .operational
                            )
                        } label: {
                            HistoryRunRow(model: model)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(StockpileSpacing.large)
        }
        .scrollIndicators(.hidden)
        .background(StockpilePalette.canvas.color.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.small) {
            Text("Today’s tests")
                .font(StockpileTypography.hero.font)
                .foregroundStyle(StockpilePalette.ink.color)

            Text("Open any run to inspect its backend result and rotate the 3D preview.")
                .font(StockpileTypography.body.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, StockpileSpacing.small)
    }

    private var emptyState: some View {
        StockpileCard(appearance: .outlined) {
            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(StockpilePalette.accent.color)

                Text("No history yet")
                    .font(StockpileTypography.sectionTitle.font)
                    .foregroundStyle(StockpilePalette.ink.color)

                Text("Completed captures will appear here after upload and backend processing finish.")
                    .font(StockpileTypography.callout.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HistoryRunRow: View {
    let model: StockpileResultScreenModel

    var body: some View {
        StockpileCard(appearance: .outlined) {
            VStack(alignment: .leading, spacing: StockpileSpacing.medium) {
                HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(statusTone.theme.accent.color)
                        .frame(width: 32, height: 32)
                        .background(statusTone.theme.background.color, in: Circle())

                    VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                        Text(model.pileName)
                            .font(StockpileTypography.sectionTitle.font)
                            .foregroundStyle(StockpilePalette.ink.color)
                            .lineLimit(2)

                        Text(model.confidence.summary)
                            .font(StockpileTypography.caption.font)
                            .foregroundStyle(StockpilePalette.mutedInk.color)
                            .lineLimit(3)
                    }

                    Spacer(minLength: StockpileSpacing.small)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                }

                HStack(spacing: StockpileSpacing.small) {
                    StockpileBadge(statusLabel, tone: statusTone)

                    if model.reconstruction != nil {
                        StockpileBadge("3D preview", tone: .info)
                    }

                    Spacer(minLength: 0)
                }

                metrics
            }
        }
    }

    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StockpileSpacing.medium) {
                metric(label: "Volume", value: volumeLabel)
                metric(label: "Weight", value: weightLabel)
                metric(label: "Confidence", value: "\(model.confidence.score)/100")
            }

            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                metric(label: "Volume", value: volumeLabel)
                metric(label: "Weight", value: weightLabel)
                metric(label: "Confidence", value: "\(model.confidence.score)/100")
            }
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
            Text(label.uppercased())
                .font(StockpileTypography.caption.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)

            Text(value)
                .font(StockpileTypography.callout.font.weight(.semibold))
                .foregroundStyle(StockpilePalette.ink.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var volumeLabel: String {
        guard let measurement = model.measurement else {
            return "Blocked"
        }
        return String(format: "%.2f m³", measurement.volumeM3)
    }

    private var weightLabel: String {
        guard let measurement = model.measurement else {
            return "Retake"
        }
        return String(format: "%.2f t", measurement.weightTonnes)
    }

    private var statusLabel: String {
        switch model.outcome {
        case .verified:
            return "Verified"
        case .reviewOnly:
            return "Review"
        case .blocked:
            return "Blocked"
        }
    }

    private var statusTone: StockpileStatusTone {
        switch model.outcome {
        case .verified:
            return .success
        case .reviewOnly:
            return .caution
        case .blocked:
            return .critical
        }
    }

    private var statusIcon: String {
        switch model.outcome {
        case .verified:
            return "checkmark"
        case .reviewOnly:
            return "exclamationmark"
        case .blocked:
            return "arrow.counterclockwise"
        }
    }
}

private struct NavigationTitleModifier: ViewModifier {
    let title: String
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
                .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct StockpileShellBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                StockpilePalette.canvas.color,
                StockpilePalette.surface.color,
                StockpilePalette.elevatedSurface.color.opacity(0.85)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(StockpilePalette.accent.color.opacity(0.10))
                .frame(width: 280, height: 280)
                .blur(radius: 44)
                .offset(x: 120, y: -140)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(StockpilePalette.success.color.opacity(0.08))
                .frame(width: 220, height: 220)
                .blur(radius: 36)
                .offset(x: -80, y: 120)
        }
        .ignoresSafeArea()
    }
}

#Preview("Root") {
    StockpileRootView(
        session: StockpileAppSession.bootstrap()
    )
}
