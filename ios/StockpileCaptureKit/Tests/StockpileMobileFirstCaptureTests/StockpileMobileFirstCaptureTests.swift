import XCTest
@testable import StockpileMobileFirstCapture

final class StockpileMobileFirstCaptureTests: XCTestCase {
    func testLiveCaptureQualityRequiresStrongSignalsForProvisionalMeasurement() {
        let weak = StockpileLiveCaptureQuality(
            referenceRecoveryScore: 0.4,
            toeCoverageScore: 0.8,
            perimeterCoverageScore: 0.8,
            motionStabilityScore: 0.8
        )
        XCTAssertFalse(weak.isReadyForProvisionalMeasurement)

        let strong = StockpileLiveCaptureQuality(
            referenceRecoveryScore: 0.82,
            toeCoverageScore: 0.78,
            perimeterCoverageScore: 0.8,
            motionStabilityScore: 0.74
        )
        XCTAssertTrue(strong.isReadyForProvisionalMeasurement)
    }

    func testLiveCaptureQualityAcceptsExactReadinessThresholds() {
        let threshold = StockpileLiveCaptureQuality(
            referenceRecoveryScore: 0.6,
            toeCoverageScore: 0.65,
            perimeterCoverageScore: 0.65,
            motionStabilityScore: 0.55
        )

        XCTAssertTrue(threshold.isReadyForProvisionalMeasurement)
    }

    func testHandoffSummaryReflectsCaptureReadiness() {
        let ready = StockpileProvisionalMeasurementHandoff(
            sessionID: "session-1",
            pileName: "North Yard 03",
            stage: .provisionalResult,
            quality: StockpileLiveCaptureQuality(
                referenceRecoveryScore: 0.8,
                toeCoverageScore: 0.8,
                perimeterCoverageScore: 0.8,
                motionStabilityScore: 0.8
            ),
            markerSnapshots: [
                StockpileReferenceMarkerSnapshot(
                    markerID: "tag-01",
                    visibleCount: 5,
                    confidence: 0.93,
                    quality: .confirmed
                )
            ],
            telemetry: StockpileDevicePoseTelemetry(
                samplesCaptured: 140,
                headingStable: true,
                motionStable: true,
                lidarAssistAvailable: true
            )
        )
        XCTAssertEqual(
            ready.operatorSummary,
            "Capture is strong enough to request a provisional result."
        )
    }

    func testHandoffSummaryKeepsGuidanceMessageWhenCaptureIsNotReady() {
        let notReady = StockpileProvisionalMeasurementHandoff(
            sessionID: "session-2",
            pileName: "North Yard 07",
            stage: .recaptureRequired,
            quality: StockpileLiveCaptureQuality(
                referenceRecoveryScore: 0.59,
                toeCoverageScore: 0.65,
                perimeterCoverageScore: 0.65,
                motionStabilityScore: 0.55
            ),
            markerSnapshots: [
                StockpileReferenceMarkerSnapshot(
                    markerID: "tag-02",
                    visibleCount: 1,
                    confidence: 0.72,
                    quality: .weak
                )
            ],
            telemetry: StockpileDevicePoseTelemetry(
                samplesCaptured: 96,
                headingStable: true,
                motionStable: true,
                lidarAssistAvailable: true
            )
        )

        XCTAssertEqual(
            notReady.operatorSummary,
            "Keep recording until tagged references and toe coverage stabilize."
        )
    }
}
