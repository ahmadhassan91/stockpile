import AVFoundation
import Foundation
#if os(iOS) && canImport(CoreMotion)
import CoreMotion
#endif
#if canImport(Darwin)
import Darwin
#endif

public struct StockpileCaptureSensorMetadata: Codable, Equatable, Sendable {
    public let deviceModelIdentifier: String?
    public let videoWidth: Int?
    public let videoHeight: Int?
    public let videoFrameRate: Double?
    public let poseSamplingHz: Double?
    public let depthDataIncluded: Bool?
    public let worldAlignment: String?
    public let videoStabilizationMode: String?

    public init(
        deviceModelIdentifier: String? = nil,
        videoWidth: Int? = nil,
        videoHeight: Int? = nil,
        videoFrameRate: Double? = nil,
        poseSamplingHz: Double? = nil,
        depthDataIncluded: Bool? = nil,
        worldAlignment: String? = nil,
        videoStabilizationMode: String? = nil
    ) {
        self.deviceModelIdentifier = deviceModelIdentifier
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFrameRate = videoFrameRate
        self.poseSamplingHz = poseSamplingHz
        self.depthDataIncluded = depthDataIncluded
        self.worldAlignment = worldAlignment
        self.videoStabilizationMode = videoStabilizationMode
    }
}

public struct StockpileCaptureSensorSnapshot: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let motionSignalsIncluded: Bool
    public let gravityVectorIncluded: Bool
    public let headingSignalsIncluded: Bool
    public let cameraCalibrationIncluded: Bool
    public let motionStable: Bool
    public let headingStable: Bool
    public let lidarAssistAvailable: Bool
    public let trackingState: String?
    public let sensorMetadata: StockpileCaptureSensorMetadata?

    public init(
        sampleCount: Int,
        motionSignalsIncluded: Bool,
        gravityVectorIncluded: Bool,
        headingSignalsIncluded: Bool,
        cameraCalibrationIncluded: Bool,
        motionStable: Bool,
        headingStable: Bool,
        lidarAssistAvailable: Bool,
        trackingState: String? = nil,
        sensorMetadata: StockpileCaptureSensorMetadata? = nil
    ) {
        self.sampleCount = max(0, sampleCount)
        self.motionSignalsIncluded = motionSignalsIncluded
        self.gravityVectorIncluded = gravityVectorIncluded
        self.headingSignalsIncluded = headingSignalsIncluded
        self.cameraCalibrationIncluded = cameraCalibrationIncluded
        self.motionStable = motionStable
        self.headingStable = headingStable
        self.lidarAssistAvailable = lidarAssistAvailable
        self.trackingState = trackingState
        self.sensorMetadata = sensorMetadata
    }
}

public protocol StockpileCaptureDeviceTelemetryProviding: AnyObject {
    var latestTelemetrySnapshot: StockpileCaptureSensorSnapshot? { get }
}

protocol StockpileCaptureDeviceTelemetryRuntime: AnyObject {
    var latestSnapshot: StockpileCaptureSensorSnapshot? { get }
    var onSnapshotUpdated: (@Sendable (StockpileCaptureSensorSnapshot) -> Void)? { get set }

    func startSampling(configuration: StockpileCaptureDeviceTelemetryConfiguration)
    func stopSampling()
}

struct StockpileCaptureDeviceTelemetryConfiguration: Sendable {
    var lidarAssistEnabled: Bool
    var cameraCalibrationIncluded: Bool
    var depthDataIncluded: Bool
    var videoWidth: Int?
    var videoHeight: Int?
    var videoFrameRate: Double?
    var videoStabilizationMode: String?
}

final class StockpileMotionAndCapabilityTelemetryRuntime: StockpileCaptureDeviceTelemetryRuntime {
    var latestSnapshot: StockpileCaptureSensorSnapshot? {
        lock.withLock {
            state.latestSnapshot
        }
    }

    var onSnapshotUpdated: (@Sendable (StockpileCaptureSensorSnapshot) -> Void)?

    private struct State {
        var latestSnapshot: StockpileCaptureSensorSnapshot?
        var sampleCount = 0
        var motionSamples: [Bool] = []
        var headingSamples: [Bool] = []
        var lastYaw: Double?
        var configuration: StockpileCaptureDeviceTelemetryConfiguration?
        var headingSignalsIncluded = false
        var worldAlignment: String?
    }

    private let lock = NSLock()
    private let stateQueue: OperationQueue
    #if os(iOS) && canImport(CoreMotion)
    private let motionManager = CMMotionManager()
    #endif
    private var state = State()

    init() {
        let queue = OperationQueue()
        queue.name = "com.clustox.stockpile.capture.telemetry"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        self.stateQueue = queue
    }

    func startSampling(configuration: StockpileCaptureDeviceTelemetryConfiguration) {
        stopSampling()

        let headingSignalsIncluded = Self.headingSignalsAvailable
        let worldAlignment = Self.preferredWorldAlignment()
        lock.withLock {
            state = State(
                latestSnapshot: nil,
                sampleCount: 0,
                motionSamples: [],
                headingSamples: [],
                lastYaw: nil,
                configuration: configuration,
                headingSignalsIncluded: headingSignalsIncluded,
                worldAlignment: worldAlignment
            )
        }

        updateSnapshot(
            sampleCount: 0,
            motionSignalsIncluded: Self.deviceMotionAvailable,
            gravityVectorIncluded: Self.deviceMotionAvailable,
            headingSignalsIncluded: headingSignalsIncluded,
            motionStable: false,
            headingStable: false,
            lidarAssistAvailable: configuration.lidarAssistEnabled && Self.lidarAssistAvailable,
            trackingState: Self.deviceMotionAvailable ? "sensor_sampling_ready" : "device_motion_unavailable"
        )

        #if os(iOS) && canImport(CoreMotion)
        guard motionManager.isDeviceMotionAvailable else {
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 15.0
        let referenceFrame = Self.preferredReferenceFrame()
        if let referenceFrame {
            motionManager.startDeviceMotionUpdates(using: referenceFrame, to: stateQueue) { [weak self] motion, _ in
                self?.handleDeviceMotion(motion)
            }
        } else {
            motionManager.startDeviceMotionUpdates(to: stateQueue) { [weak self] motion, _ in
                self?.handleDeviceMotion(motion)
            }
        }
        #endif
    }

    func stopSampling() {
        #if os(iOS) && canImport(CoreMotion)
        motionManager.stopDeviceMotionUpdates()
        #endif
    }

    #if os(iOS) && canImport(CoreMotion)
    private func handleDeviceMotion(_ motion: CMDeviceMotion?) {
        guard let motion else {
            return
        }

        let update = lock.withLock {
            () -> (
                configuration: StockpileCaptureDeviceTelemetryConfiguration,
                sampleCount: Int,
                motionSignalsIncluded: Bool,
                gravityVectorIncluded: Bool,
                headingSignalsIncluded: Bool,
                motionStable: Bool,
                headingStable: Bool,
                trackingState: String?
            )? in
            guard let configuration = state.configuration else {
                return nil
            }

            state.sampleCount += 1

            let rotationMagnitude = sqrt(
                pow(motion.rotationRate.x, 2)
                    + pow(motion.rotationRate.y, 2)
                    + pow(motion.rotationRate.z, 2)
            )
            let userAccelerationMagnitude = sqrt(
                pow(motion.userAcceleration.x, 2)
                    + pow(motion.userAcceleration.y, 2)
                    + pow(motion.userAcceleration.z, 2)
            )
            let stableMotionSample = rotationMagnitude < 1.15 && userAccelerationMagnitude < 0.28
            state.motionSamples = Self.appendingSample(stableMotionSample, to: state.motionSamples)

            let headingSignalsIncluded = state.headingSignalsIncluded
            let stableHeadingSample: Bool
            if headingSignalsIncluded {
                if let lastYaw = state.lastYaw {
                    let delta = abs(Self.normalizeAngle(motion.attitude.yaw - lastYaw))
                    stableHeadingSample = delta < 0.14
                } else {
                    stableHeadingSample = true
                }
                state.lastYaw = motion.attitude.yaw
                state.headingSamples = Self.appendingSample(stableHeadingSample, to: state.headingSamples)
            } else {
                stableHeadingSample = false
                state.headingSamples.removeAll(keepingCapacity: true)
                state.lastYaw = nil
            }

            let motionStable = Self.passingRatio(for: state.motionSamples) >= 0.65
            let headingStable = headingSignalsIncluded
                ? Self.passingRatio(for: state.headingSamples) >= 0.65
                : false

            return (
                configuration,
                state.sampleCount,
                true,
                true,
                headingSignalsIncluded,
                motionStable,
                headingStable,
                headingStable ? "sensor_sampling_active" : "sensor_sampling_needs_heading_settle"
            )
        }

        guard let update else {
            return
        }

        updateSnapshot(
            sampleCount: update.sampleCount,
            motionSignalsIncluded: update.motionSignalsIncluded,
            gravityVectorIncluded: update.gravityVectorIncluded,
            headingSignalsIncluded: update.headingSignalsIncluded,
            motionStable: update.motionStable,
            headingStable: update.headingStable,
            lidarAssistAvailable: update.configuration.lidarAssistEnabled && Self.lidarAssistAvailable,
            trackingState: update.trackingState
        )
    }
    #endif

    private func updateSnapshot(
        sampleCount: Int,
        motionSignalsIncluded: Bool,
        gravityVectorIncluded: Bool,
        headingSignalsIncluded: Bool,
        motionStable: Bool,
        headingStable: Bool,
        lidarAssistAvailable: Bool,
        trackingState: String?
    ) {
        let snapshot = lock.withLock { () -> StockpileCaptureSensorSnapshot in
            let configuration = state.configuration
            let metadata = StockpileCaptureSensorMetadata(
                deviceModelIdentifier: Self.deviceModelIdentifier(),
                videoWidth: configuration?.videoWidth,
                videoHeight: configuration?.videoHeight,
                videoFrameRate: configuration?.videoFrameRate,
                poseSamplingHz: motionSignalsIncluded ? 15.0 : nil,
                depthDataIncluded: configuration?.depthDataIncluded,
                worldAlignment: state.worldAlignment,
                videoStabilizationMode: configuration?.videoStabilizationMode
            )

            let snapshot = StockpileCaptureSensorSnapshot(
                sampleCount: sampleCount,
                motionSignalsIncluded: motionSignalsIncluded,
                gravityVectorIncluded: gravityVectorIncluded,
                headingSignalsIncluded: headingSignalsIncluded,
                cameraCalibrationIncluded: configuration?.cameraCalibrationIncluded ?? false,
                motionStable: motionStable,
                headingStable: headingStable,
                lidarAssistAvailable: lidarAssistAvailable,
                trackingState: trackingState,
                sensorMetadata: metadata
            )
            state.latestSnapshot = snapshot
            return snapshot
        }

        onSnapshotUpdated?(snapshot)
    }

    private static func appendingSample(_ sample: Bool, to existing: [Bool]) -> [Bool] {
        let maxSampleWindow = 24
        var values = existing
        values.append(sample)
        if values.count > maxSampleWindow {
            values.removeFirst(values.count - maxSampleWindow)
        }
        return values
    }

    private static func passingRatio(for samples: [Bool]) -> Double {
        guard samples.isEmpty == false else {
            return 0
        }

        let passingSamples = samples.filter { $0 }.count
        return Double(passingSamples) / Double(samples.count)
    }

    private static func normalizeAngle(_ angle: Double) -> Double {
        var normalized = angle
        while normalized > .pi {
            normalized -= (.pi * 2)
        }
        while normalized < -.pi {
            normalized += (.pi * 2)
        }
        return normalized
    }

    #if os(iOS) && canImport(CoreMotion)
    private static func preferredReferenceFrame() -> CMAttitudeReferenceFrame? {
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        if frames.contains(.xArbitraryCorrectedZVertical) {
            return .xArbitraryCorrectedZVertical
        }
        if frames.contains(.xMagneticNorthZVertical) {
            return .xMagneticNorthZVertical
        }
        if frames.contains(.xArbitraryZVertical) {
            return .xArbitraryZVertical
        }
        return nil
    }
    #endif

    private static func preferredWorldAlignment() -> String? {
        #if os(iOS) && canImport(CoreMotion)
        guard let referenceFrame = preferredReferenceFrame() else {
            return nil
        }

        switch referenceFrame {
        case .xMagneticNorthZVertical, .xArbitraryCorrectedZVertical:
            return "gravityAndHeading"
        case .xArbitraryZVertical, .xTrueNorthZVertical:
            return "gravity"
        default:
            return "gravity"
        }
        #else
        return nil
        #endif
    }

    private static var headingSignalsAvailable: Bool {
        preferredWorldAlignment() == "gravityAndHeading"
    }

    private static var deviceMotionAvailable: Bool {
        #if os(iOS) && canImport(CoreMotion)
        CMMotionManager().isDeviceMotionAvailable
        #else
        false
        #endif
    }

    private static var lidarAssistAvailable: Bool {
        #if os(iOS)
        AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil
        #else
        false
        #endif
    }

    private static func deviceModelIdentifier() -> String? {
        #if canImport(Darwin)
        var size: size_t = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else {
                return nil
            }
            return String(validatingCString: baseAddress)
        }
        #else
        return nil
        #endif
    }
}

private extension NSLock {
    func withLock<T>(_ work: () -> T) -> T {
        lock()
        defer { unlock() }
        return work()
    }
}
