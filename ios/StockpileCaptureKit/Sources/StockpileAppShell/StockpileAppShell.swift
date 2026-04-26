import Combine
import SwiftUI
import StockpileCaptureFlow
import StockpileOperatorDashboard
import StockpileResultsUI
import StockpileDesignSystem

public enum StockpileAppShellNamespace {}

public struct StockpileRunSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let pileName: String
    public let statusLabel: String
    public let confidenceLabel: String

    public init(id: String, pileName: String, statusLabel: String, confidenceLabel: String) {
        self.id = id
        self.pileName = pileName
        self.statusLabel = statusLabel
        self.confidenceLabel = confidenceLabel
    }
}

public enum StockpileShellSection: String, CaseIterable, Hashable, Sendable {
    case dashboard
    case capture
    case review

    public var title: String {
        switch self {
        case .dashboard:
            return "Home"
        case .capture:
            return "Capture"
        case .review:
            return "Review"
        }
    }

    public var navigationTitle: String {
        switch self {
        case .dashboard:
            return "Home"
        case .capture:
            return "Capture"
        case .review:
            return "Review"
        }
    }

    public var systemImage: String {
        switch self {
        case .dashboard:
            return "house.fill"
        case .capture:
            return "camera.fill"
        case .review:
            return "checkmark.circle"
        }
    }
}

public enum StockpileShellDestination: Hashable, Sendable {
    case run(String)
}

@MainActor
public final class StockpileShellStore: ObservableObject {
    @Published public var selectedSection: StockpileShellSection
    @Published public var path: [StockpileShellDestination]
    @Published public var runs: [StockpileRunSummary]
    public let dashboardContent: OperatorDashboardContent
    public let activeFacility: String

    public init(
        selectedSection: StockpileShellSection,
        path: [StockpileShellDestination] = [],
        runs: [StockpileRunSummary],
        dashboardContent: OperatorDashboardContent,
        activeFacility: String
    ) {
        self.selectedSection = selectedSection
        self.path = path
        self.runs = runs
        self.dashboardContent = dashboardContent
        self.activeFacility = activeFacility
    }

    public var featuredRun: StockpileRunSummary? {
        runs.first
    }

    public var reviewQueueCount: Int {
        runs.filter { $0.statusLabel.localizedCaseInsensitiveContains("review") }.count
    }

    public var activeRunCount: Int {
        runs.filter { !$0.statusLabel.localizedCaseInsensitiveContains("blocked") }.count
    }

    public func openRun(_ run: StockpileRunSummary) {
        path.append(.run(run.id))
    }

    public static let demo = StockpileShellStore(
        selectedSection: .review,
        runs: OperatorDashboardContent.preview.recentRuns.map {
            StockpileRunSummary(
                id: $0.id,
                pileName: $0.pileName,
                statusLabel: $0.trustState.title,
                confidenceLabel: $0.confidenceLabel
            )
        },
        dashboardContent: .preview,
        activeFacility: "QPMC North Yard"
    )
}

public struct StockpileAppShellView: View {
    @StateObject private var store: StockpileShellStore

    public init(store: StockpileShellStore = .demo) {
        _store = StateObject(wrappedValue: store)
    }

    public var body: some View {
        TabView(selection: $store.selectedSection) {
            dashboardTab
            captureTab
            reviewTab
        }
        .tint(StockpilePalette.accent.color)
        .background {
            StockpileShellBackground()
        }
        .modifier(StockpileShellTabBarStyling())
    }

    private var dashboardTab: some View {
        NavigationStack(path: $store.path) {
            dashboardView
                .navigationDestination(for: StockpileShellDestination.self) { destination in
                    switch destination {
                    case let .run(runID):
                        StockpileResultScreenView(model: resultModel(for: runID))
                            .navigationTitle("Run \(runID)")
                    }
                }
        }
        .tabItem {
            Label(StockpileShellSection.dashboard.title, systemImage: StockpileShellSection.dashboard.systemImage)
        }
        .tag(StockpileShellSection.dashboard)
    }

    private var captureTab: some View {
        NavigationStack {
            CaptureHomeView(content: .preview)
                .navigationTitle(StockpileShellSection.capture.navigationTitle)
        }
        .tabItem {
            Label(StockpileShellSection.capture.title, systemImage: StockpileShellSection.capture.systemImage)
        }
        .tag(StockpileShellSection.capture)
    }

    private var reviewTab: some View {
        NavigationStack {
            StockpileResultScreenView(model: .mockReviewOnly)
                .navigationTitle(StockpileShellSection.review.navigationTitle)
        }
        .tabItem {
            Label(StockpileShellSection.review.title, systemImage: StockpileShellSection.review.systemImage)
        }
        .tag(StockpileShellSection.review)
    }

    private var dashboardView: some View {
        OperatorDashboardView(content: store.dashboardContent)
    }

    private func resultModel(for runID: String) -> StockpileResultScreenModel {
        switch runID {
        case "run_118":
            return .mockVerified
        case "run_117":
            return .mockBlocked
        default:
            return .mockReviewOnly
        }
    }
}

private struct StockpileShellTabBarStyling: ViewModifier {
    func body(content: Content) -> some View {
#if os(iOS)
        content
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarBackground(.thinMaterial, for: .tabBar)
#else
        content
#endif
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
