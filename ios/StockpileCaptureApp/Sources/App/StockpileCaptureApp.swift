import SwiftUI

@main
struct StockpileCaptureApp: App {
    @UIApplicationDelegateAdaptor(StockpileCaptureAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: StockpileAppSession

    init() {
        let configuration = StockpileAppConfiguration.current()
        let launchMode = configuration.resolvedLaunchMode()
        _session = StateObject(
            wrappedValue: StockpileAppSession.bootstrap(
                configuration: configuration,
                launchMode: launchMode
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            StockpileRootView(session: session)
                .task {
                    await session.prepareForLaunch()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    Task {
                        await session.refreshForForegroundIfNeeded()
                    }
                }
        }
    }
}
