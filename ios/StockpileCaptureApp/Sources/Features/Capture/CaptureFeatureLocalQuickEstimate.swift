import Foundation
import StockpileMobileAPI
import StockpileResultsUI
#if canImport(StockpileMobileFirstCapture)
import StockpileMobileFirstCapture
#endif

struct CaptureFeatureLocalQuickEstimate: Codable, Equatable, Sendable {
    let volumeM3: Double
    let footprintAreaM2: Double
    let peakHeightM: Double
    let confidenceScore: Double
    let geometryPointCount: Int
    let cameraPathDistanceM: Double

    init(
        volumeM3: Double,
        footprintAreaM2: Double,
        peakHeightM: Double,
        confidenceScore: Double,
        geometryPointCount: Int,
        cameraPathDistanceM: Double
    ) {
        self.volumeM3 = max(0, volumeM3)
        self.footprintAreaM2 = max(0, footprintAreaM2)
        self.peakHeightM = max(0, peakHeightM)
        self.confidenceScore = min(max(confidenceScore, 0), 1)
        self.geometryPointCount = max(0, geometryPointCount)
        self.cameraPathDistanceM = max(0, cameraPathDistanceM)
    }

    var confidencePercentage: Int {
        Int((confidenceScore * 100).rounded())
    }

    func measurement(densityKgPerM3: Int) -> StockpileMeasurement {
        StockpileMeasurement(
            volumeM3: volumeM3,
            weightTonnes: (volumeM3 * Double(densityKgPerM3)) / 1000.0,
            densityKgPerM3: densityKgPerM3
        )
    }

    func mobilePayload() -> (
        quickVolumeM3: Double,
        quickFootprintAreaM2: Double,
        quickPeakHeightM: Double,
        quickConfidenceScore: Double,
        quickGeometryPointCount: Int,
        quickCameraPathDistanceM: Double
    ) {
        (
            quickVolumeM3: volumeM3,
            quickFootprintAreaM2: footprintAreaM2,
            quickPeakHeightM: peakHeightM,
            quickConfidenceScore: confidenceScore,
            quickGeometryPointCount: geometryPointCount,
            quickCameraPathDistanceM: cameraPathDistanceM
        )
    }

    var segmentationSummary: String {
        var details: [String] = []

        if footprintAreaM2 > 0, geometryPointCount > 0 {
            details.append(
                "On-device LiDAR segmented about \(Self.formattedMeasurement(footprintAreaM2)) m2 of pile footprint from \(Self.formattedPointCount(geometryPointCount)) native depth samples."
            )
        } else if footprintAreaM2 > 0 {
            details.append(
                "On-device LiDAR segmented about \(Self.formattedMeasurement(footprintAreaM2)) m2 of pile footprint."
            )
        } else if geometryPointCount > 0 {
            details.append(
                "On-device LiDAR segmented \(Self.formattedPointCount(geometryPointCount)) native depth samples into a provisional pile surface."
            )
        } else {
            details.append("On-device LiDAR produced a provisional pile segmentation estimate.")
        }

        if cameraPathDistanceM > 0 {
            details.append(
                "The phone covered roughly \(Self.formattedMeasurement(cameraPathDistanceM)) m of camera path."
            )
        }

        if peakHeightM > 0 {
            details.append(
                "Estimated peak height is \(Self.formattedMeasurement(peakHeightM)) m."
            )
        }

        return details.joined(separator: " ")
    }

    private static func formattedMeasurement(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func formattedPointCount(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

#if canImport(StockpileMobileFirstCapture)
extension CaptureFeatureLocalQuickEstimate {
    init?(_ estimate: StockpileDevicePoseQuickVolumeEstimate?) {
        guard let estimate, estimate.volumeM3 > 0 else {
            return nil
        }

        self.init(
            volumeM3: estimate.volumeM3,
            footprintAreaM2: estimate.footprintAreaM2,
            peakHeightM: estimate.peakHeightM,
            confidenceScore: estimate.confidenceScore,
            geometryPointCount: estimate.sampledPointCount,
            cameraPathDistanceM: estimate.cameraPathDistanceM
        )
    }
}
#endif

extension CaptureFeatureLocalQuickEstimate {
    init?(_ provisionalMeasurement: StockpileProvisionalMeasurementPayload?) {
        guard let provisionalMeasurement else {
            return nil
        }

        let hasSegmentationSignal =
            (provisionalMeasurement.quickFootprintAreaM2 ?? 0) > 0
            || (provisionalMeasurement.quickPeakHeightM ?? 0) > 0
            || (provisionalMeasurement.quickGeometryPointCount ?? 0) > 0
            || (provisionalMeasurement.quickCameraPathDistanceM ?? 0) > 0

        guard
            hasSegmentationSignal,
            let volumeM3 = provisionalMeasurement.quickVolumeM3 ?? provisionalMeasurement.volumeM3,
            volumeM3 > 0
        else {
            return nil
        }

        self.init(
            volumeM3: volumeM3,
            footprintAreaM2: provisionalMeasurement.quickFootprintAreaM2 ?? 0,
            peakHeightM: provisionalMeasurement.quickPeakHeightM ?? 0,
            confidenceScore: provisionalMeasurement.quickConfidenceScore
                ?? Double(provisionalMeasurement.confidenceScore ?? 0) / 100.0,
            geometryPointCount: provisionalMeasurement.quickGeometryPointCount ?? 0,
            cameraPathDistanceM: provisionalMeasurement.quickCameraPathDistanceM ?? 0
        )
    }
}
