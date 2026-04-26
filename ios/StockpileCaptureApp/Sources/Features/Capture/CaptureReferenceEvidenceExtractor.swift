import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CaptureReferenceEvidence: Identifiable, Sendable, Equatable {
    let id: String
    let frameIndex: Int
    let requestedTimeSeconds: Double
    let actualTimeSeconds: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let jpegByteCount: Int
    let jpegBase64: String

    init(
        frameIndex: Int,
        requestedTimeSeconds: Double,
        actualTimeSeconds: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        jpegData: Data
    ) {
        self.id = "frame-\(frameIndex)"
        self.frameIndex = frameIndex
        self.requestedTimeSeconds = requestedTimeSeconds
        self.actualTimeSeconds = actualTimeSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.jpegByteCount = jpegData.count
        self.jpegBase64 = jpegData.base64EncodedString()
    }

    var dimensionsDescription: String {
        "\(pixelWidth)x\(pixelHeight)"
    }

    var uploadMetadata: [String: String] {
        [
            "frame_index": String(frameIndex),
            "requested_time_seconds": Self.posixSecondsString(requestedTimeSeconds),
            "actual_time_seconds": Self.posixSecondsString(actualTimeSeconds),
            "dimensions": dimensionsDescription,
            "jpeg_byte_count": String(jpegByteCount),
        ]
    }

    private static func posixSecondsString(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

final class CaptureReferenceEvidenceExtractor {
    struct Configuration: Sendable, Equatable {
        var sampleCount: Int
        var maximumSamplesPerClip: Int
        var maximumImageDimension: CGFloat
        var jpegCompressionQuality: CGFloat
        var requestedTimeScale: CMTimeScale

        init(
            sampleCount: Int = 3,
            maximumSamplesPerClip: Int = 5,
            maximumImageDimension: CGFloat = 640,
            jpegCompressionQuality: CGFloat = 0.72,
            requestedTimeScale: CMTimeScale = 600
        ) {
            self.sampleCount = sampleCount
            self.maximumSamplesPerClip = maximumSamplesPerClip
            self.maximumImageDimension = maximumImageDimension
            self.jpegCompressionQuality = jpegCompressionQuality
            self.requestedTimeScale = requestedTimeScale
        }
    }

    enum Error: Swift.Error, LocalizedError, Sendable {
        case emptyDuration
        case frameGenerationFailed(requestedSeconds: Double)
        case jpegEncodingFailed
        case noFramesGenerated

        var errorDescription: String? {
            switch self {
            case .emptyDuration:
                return "The movie does not contain a usable duration."
            case let .frameGenerationFailed(requestedSeconds):
                return "Unable to generate a frame near \(requestedSeconds) seconds."
            case .jpegEncodingFailed:
                return "Unable to encode the sampled frame as JPEG."
            case .noFramesGenerated:
                return "No evidence frames could be generated from the movie."
            }
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    func extractEvidence(from movieURL: URL) async throws -> [CaptureReferenceEvidence] {
        let asset = AVURLAsset(url: movieURL)
        let duration = try await asset.load(.duration)

        guard duration.isNumeric, duration.seconds > 0 else {
            throw Error.emptyDuration
        }

        let sampleCount = normalizedSampleCount
        guard sampleCount > 0 else {
            return []
        }

        let requestedTimes = Self.sampleTimes(
            for: duration,
            count: sampleCount,
            timescale: normalizedRequestedTimeScale
        )

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(
            width: normalizedMaximumImageDimension,
            height: normalizedMaximumImageDimension
        )
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        var evidence: [CaptureReferenceEvidence] = []
        evidence.reserveCapacity(requestedTimes.count)

        for (frameIndex, requestedTime) in requestedTimes.enumerated() {
            do {
                let generated = try await Self.generateJPEGEvidence(
                    from: imageGenerator,
                    frameIndex: frameIndex,
                    requestedTime: requestedTime,
                    jpegCompressionQuality: configuration.jpegCompressionQuality
                )
                evidence.append(generated)
            } catch {
                continue
            }
        }

        guard evidence.isEmpty == false else {
            throw Error.noFramesGenerated
        }

        return evidence
    }

    private var normalizedSampleCount: Int {
        max(0, min(configuration.sampleCount, configuration.maximumSamplesPerClip))
    }

    private var normalizedMaximumImageDimension: CGFloat {
        max(1, configuration.maximumImageDimension)
    }

    private var normalizedRequestedTimeScale: CMTimeScale {
        max(1, configuration.requestedTimeScale)
    }

    private static func sampleTimes(
        for duration: CMTime,
        count: Int,
        timescale: CMTimeScale
    ) -> [CMTime] {
        guard count > 0 else {
            return []
        }

        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return []
        }

        if count == 1 {
            return [CMTime(seconds: durationSeconds / 2, preferredTimescale: timescale)]
        }

        return (0..<count).map { index in
            let fraction = Double(index + 1) / Double(count + 1)
            return CMTime(seconds: durationSeconds * fraction, preferredTimescale: timescale)
        }
    }

    private static func generateJPEGEvidence(
        from imageGenerator: AVAssetImageGenerator,
        frameIndex: Int,
        requestedTime: CMTime,
        jpegCompressionQuality: CGFloat
    ) async throws -> CaptureReferenceEvidence {
        let (cgImage, actualTime) = try await generateCGImage(
            from: imageGenerator,
            requestedTime: requestedTime
        )

        let jpegData = try makeJPEGData(from: cgImage, compressionQuality: jpegCompressionQuality)
        return CaptureReferenceEvidence(
            frameIndex: frameIndex,
            requestedTimeSeconds: requestedTime.seconds,
            actualTimeSeconds: actualTime.seconds,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            jpegData: jpegData
        )
    }

    private static func generateCGImage(
        from imageGenerator: AVAssetImageGenerator,
        requestedTime: CMTime
    ) async throws -> (CGImage, CMTime) {
        try await withCheckedThrowingContinuation { continuation in
            imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: requestedTime)]) {
                _, cgImage, actualTime, result, error in
                switch result {
                case .succeeded:
                    if let cgImage {
                        continuation.resume(returning: (cgImage, actualTime))
                    } else {
                        continuation.resume(throwing: error ?? Error.frameGenerationFailed(requestedSeconds: requestedTime.seconds))
                    }
                case .failed, .cancelled:
                    continuation.resume(throwing: error ?? Error.frameGenerationFailed(requestedSeconds: requestedTime.seconds))
                @unknown default:
                    continuation.resume(throwing: error ?? Error.frameGenerationFailed(requestedSeconds: requestedTime.seconds))
                }
            }
        }
    }

    private static func makeJPEGData(
        from image: CGImage,
        compressionQuality: CGFloat
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw Error.jpegEncodingFailed
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0, min(compressionQuality, 1))
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw Error.jpegEncodingFailed
        }

        return data as Data
    }
}
