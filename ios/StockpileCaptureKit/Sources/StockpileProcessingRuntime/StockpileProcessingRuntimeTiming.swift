import Foundation

public protocol StockpileProcessingRuntimeSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SystemStockpileProcessingRuntimeSleeper: StockpileProcessingRuntimeSleeping {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

