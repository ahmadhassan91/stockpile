import Foundation

#if os(iOS) && canImport(CoreVideo)
import CoreVideo
#endif

#if os(iOS) && canImport(ARKit)
import ARKit
#endif

public struct StockpileSerializedDepthMap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let depthF16LittleEndianData: Data
    public let confidenceMapUInt8Data: Data?

    public init(
        width: Int,
        height: Int,
        depthF16LittleEndianData: Data,
        confidenceMapUInt8Data: Data? = nil
    ) {
        self.width = width
        self.height = height
        self.depthF16LittleEndianData = depthF16LittleEndianData
        self.confidenceMapUInt8Data = confidenceMapUInt8Data
    }
}

public enum StockpileDepthMapSerializer {
    public enum SerializationError: Error, Equatable, LocalizedError, Sendable {
        case invalidDimensions(width: Int, height: Int)
        case depthSampleCountMismatch(expected: Int, actual: Int)
        case confidenceSampleCountMismatch(expected: Int, actual: Int)
        case pixelBufferBaseAddressUnavailable
        case pixelBufferDimensionMismatch(
            depthWidth: Int,
            depthHeight: Int,
            confidenceWidth: Int,
            confidenceHeight: Int
        )
        case unsupportedDepthPixelFormat(UInt32)
        case unsupportedConfidencePixelFormat(UInt32)

        public var errorDescription: String? {
            switch self {
            case let .invalidDimensions(width, height):
                return "Depth map dimensions must be positive; received \(width)x\(height)."
            case let .depthSampleCountMismatch(expected, actual):
                return "Depth sample count mismatch: expected \(expected), received \(actual)."
            case let .confidenceSampleCountMismatch(expected, actual):
                return "Confidence sample count mismatch: expected \(expected), received \(actual)."
            case .pixelBufferBaseAddressUnavailable:
                return "Depth map pixel buffer base address is unavailable."
            case let .pixelBufferDimensionMismatch(depthWidth, depthHeight, confidenceWidth, confidenceHeight):
                return "Confidence map dimensions \(confidenceWidth)x\(confidenceHeight) do not match depth map dimensions \(depthWidth)x\(depthHeight)."
            case let .unsupportedDepthPixelFormat(pixelFormat):
                return "Unsupported depth pixel format: \(pixelFormat)."
            case let .unsupportedConfidencePixelFormat(pixelFormat):
                return "Unsupported confidence pixel format: \(pixelFormat)."
            }
        }
    }

    public static func serialize(
        width: Int,
        height: Int,
        depthSamplesMeters: [Float],
        confidenceSamples: [UInt8]? = nil
    ) throws -> StockpileSerializedDepthMap {
        let expectedCount = try expectedSampleCount(width: width, height: height)
        guard depthSamplesMeters.count == expectedCount else {
            throw SerializationError.depthSampleCountMismatch(
                expected: expectedCount,
                actual: depthSamplesMeters.count
            )
        }

        if let confidenceSamples, confidenceSamples.count != expectedCount {
            throw SerializationError.confidenceSampleCountMismatch(
                expected: expectedCount,
                actual: confidenceSamples.count
            )
        }

        return StockpileSerializedDepthMap(
            width: width,
            height: height,
            depthF16LittleEndianData: float16LittleEndianData(fromDepthSamplesMeters: depthSamplesMeters),
            confidenceMapUInt8Data: confidenceSamples.map(uint8Data(fromConfidenceSamples:))
        )
    }

    public static func float16LittleEndianData(fromDepthSamplesMeters depthSamplesMeters: [Float]) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(depthSamplesMeters.count * MemoryLayout<UInt16>.size)

        for sample in depthSamplesMeters {
            let bitPattern = Float16(sample).bitPattern
            bytes.append(UInt8(truncatingIfNeeded: bitPattern))
            bytes.append(UInt8(truncatingIfNeeded: bitPattern >> 8))
        }

        return Data(bytes)
    }

    public static func uint8Data(fromConfidenceSamples confidenceSamples: [UInt8]) -> Data {
        Data(confidenceSamples)
    }

    private static func expectedSampleCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else {
            throw SerializationError.invalidDimensions(width: width, height: height)
        }

        let product = width.multipliedReportingOverflow(by: height)
        guard product.overflow == false else {
            throw SerializationError.invalidDimensions(width: width, height: height)
        }

        return product.partialValue
    }
}

#if os(iOS) && canImport(CoreVideo)
public extension StockpileDepthMapSerializer {
    static func serialize(
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer? = nil
    ) throws -> StockpileSerializedDepthMap {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        let confidenceSamples: [UInt8]?
        if let confidenceMap {
            let confidenceWidth = CVPixelBufferGetWidth(confidenceMap)
            let confidenceHeight = CVPixelBufferGetHeight(confidenceMap)
            guard confidenceWidth == width, confidenceHeight == height else {
                throw SerializationError.pixelBufferDimensionMismatch(
                    depthWidth: width,
                    depthHeight: height,
                    confidenceWidth: confidenceWidth,
                    confidenceHeight: confidenceHeight
                )
            }
            confidenceSamples = try uint8Samples(fromConfidenceMap: confidenceMap)
        } else {
            confidenceSamples = nil
        }

        return try serialize(
            width: width,
            height: height,
            depthSamplesMeters: float32Samples(fromDepthMap: depthMap),
            confidenceSamples: confidenceSamples
        )
    }

    static func float32Samples(fromDepthMap depthMap: CVPixelBuffer) throws -> [Float] {
        let pixelFormat = CVPixelBufferGetPixelFormatType(depthMap)
        guard pixelFormat == kCVPixelFormatType_DepthFloat32
                || pixelFormat == kCVPixelFormatType_OneComponent32Float else {
            throw SerializationError.unsupportedDepthPixelFormat(UInt32(pixelFormat))
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw SerializationError.pixelBufferBaseAddressUnavailable
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        var samples: [Float] = []
        samples.reserveCapacity(width * height)

        for y in 0..<height {
            let rowAddress = baseAddress.advanced(by: y * bytesPerRow)
            let row = rowAddress.assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                samples.append(row[x])
            }
        }

        return samples
    }

    static func uint8Samples(fromConfidenceMap confidenceMap: CVPixelBuffer) throws -> [UInt8] {
        let pixelFormat = CVPixelBufferGetPixelFormatType(confidenceMap)
        guard pixelFormat == kCVPixelFormatType_OneComponent8 else {
            throw SerializationError.unsupportedConfidencePixelFormat(UInt32(pixelFormat))
        }

        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(confidenceMap) else {
            throw SerializationError.pixelBufferBaseAddressUnavailable
        }

        let width = CVPixelBufferGetWidth(confidenceMap)
        let height = CVPixelBufferGetHeight(confidenceMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        var samples: [UInt8] = []
        samples.reserveCapacity(width * height)

        for y in 0..<height {
            let rowAddress = baseAddress.advanced(by: y * bytesPerRow)
            let row = rowAddress.assumingMemoryBound(to: UInt8.self)
            let rowSamples = UnsafeBufferPointer(start: row, count: width)
            samples.append(contentsOf: rowSamples)
        }

        return samples
    }
}
#endif

#if os(iOS) && canImport(ARKit)
public extension StockpileDepthMapSerializer {
    static func serialize(depthData: ARDepthData) throws -> StockpileSerializedDepthMap {
        try serialize(
            depthMap: depthData.depthMap,
            confidenceMap: depthData.confidenceMap
        )
    }
}
#endif
