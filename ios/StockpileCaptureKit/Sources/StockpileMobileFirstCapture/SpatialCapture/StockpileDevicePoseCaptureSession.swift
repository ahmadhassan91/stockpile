import Foundation

public protocol StockpileDevicePoseCaptureSession: AnyObject {
    var capabilities: StockpileDevicePoseCaptureCapabilities { get }
    var latestSnapshot: StockpileDevicePoseCaptureSnapshot { get }
    var onSnapshotUpdated: (@Sendable (StockpileDevicePoseCaptureSnapshot) -> Void)? { get set }

    func start(configuration: StockpileDevicePoseCaptureConfiguration) throws
    func stop()
}

public enum StockpileDevicePoseCaptureSessionFactory {
    public static func makeDefaultSession() -> any StockpileDevicePoseCaptureSession {
        StockpileARKitDevicePoseCaptureSession()
    }
}
