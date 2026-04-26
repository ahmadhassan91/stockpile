import Foundation

public enum StockpileBackgroundUploadEventCoordinator {
    private static let storage = BackgroundUploadCompletionHandlerStorage()

    public static func registerCompletionHandler(
        _ completionHandler: @escaping () -> Void,
        forSessionIdentifier sessionIdentifier: String
    ) {
        storage.register(completionHandler, forSessionIdentifier: sessionIdentifier)
    }

    static func finishEvents(forSessionIdentifier sessionIdentifier: String) {
        storage.finishEvents(forSessionIdentifier: sessionIdentifier)
    }
}

private final class BackgroundUploadCompletionHandlerStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var completionHandlers: [String: () -> Void] = [:]

    func register(
        _ completionHandler: @escaping () -> Void,
        forSessionIdentifier sessionIdentifier: String
    ) {
        lock.lock()
        completionHandlers[sessionIdentifier] = completionHandler
        lock.unlock()
    }

    func finishEvents(forSessionIdentifier sessionIdentifier: String) {
        let completionHandler: (() -> Void)?

        lock.lock()
        completionHandler = completionHandlers.removeValue(forKey: sessionIdentifier)
        lock.unlock()

        guard let completionHandler else {
            return
        }

        DispatchQueue.main.async {
            completionHandler()
        }
    }
}
