import StockpileUploadPipeline
import UIKit

final class StockpileCaptureAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        StockpileBackgroundUploadEventCoordinator.registerCompletionHandler(
            completionHandler,
            forSessionIdentifier: identifier
        )
    }
}
