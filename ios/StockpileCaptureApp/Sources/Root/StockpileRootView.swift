import SwiftUI
import StockpileAppShell
import StockpileDesignSystem
import StockpileOperatorDashboard
import StockpileResultsUI

private enum StockpileRootTab: Hashable, CaseIterable {
    case dashboard
    case capture
    case review

    var title: String {
        switch self {
        case .dashboard:
            return "Home"
        case .capture:
            return "Capture"
        case .review:
            return "Review"
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
