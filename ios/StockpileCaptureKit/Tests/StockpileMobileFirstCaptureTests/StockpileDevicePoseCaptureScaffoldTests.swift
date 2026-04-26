import XCTest
@testable import StockpileMobileFirstCapture

final class StockpileDevicePoseCaptureScaffoldTests: XCTestCase {
    func testResolvedConfigurationUsesSmoothedDepthWhenAvailable() {
        let capabilities = StockpileDevicePoseCaptureCapabilities(
            platformLabel: "iOS",
            supportsWorldTracking: true,
            supportsGravityAndHeading: true,
            supportsSceneDepth: true,
            supportsSmoothedSceneDepth: true,
            supportsSceneMesh: false,
            lidarAssistAvailable: true
        )

        let resolved = StockpileDevicePoseCaptureConfiguration(
            worldAlignment: .gravityAndHeading,
            depthMode: .required,
            preferSmoothedDepth: true,
            sceneMeshMode: .ifAvailable
        ).resolved(using: capabilities)

        XCTAssertTrue(resolved.isRunnable)
        XCTAssertTrue(resolved.deliversDepth)
        XCTAssertTrue(resolved.usesSmoothedDepth)
        XCTAssertFalse(resolved.deliversSceneMesh)
        XCTAssertNil(resolved.unmetRequirement)
    }

    func testResolvedConfigurationRejectsMissingRequiredDepth() {
        let capabilities = StockpileDevicePoseCaptureCapabilities(
            platformLabel: "iOS",
            supportsWorldTracking: true,
            supportsGravityAndHeading: true,
            supportsSceneDepth: false,
            supportsSmoothedSceneDepth: false,
            supportsSceneMesh: false,
            lidarAssistAvailable: false
        )

        let resolved = StockpileDevicePoseCaptureConfiguration(
            depthMode: .required,
            sceneMeshMode: .disabled
        ).resolved(using: capabilities)

        XCTAssertFalse(resolved.isRunnable)
        XCTAssertEqual(
            resolved.unmetRequirement,
            "Scene depth is required but unavailable on this device."
        )
    }

    func testSnapshotBridgesToExistingTelemetryShape() {
        let capabilities = StockpileDevicePoseCaptureCapabilities(
            platformLabel: "iOS",
            supportsWorldTracking: true,
            supportsGravityAndHeading: true,
            supportsSceneDepth: true,
            supportsSmoothedSceneDepth: true,
            supportsSceneMesh: true,
            lidarAssistAvailable: true
        )
        let snapshot = StockpileDevicePoseCaptureSnapshot(
            status: .running,
            capabilities: capabilities,
            configuration: StockpileDevicePoseCaptureConfiguration(worldAlignment: .gravityAndHeading),
            resolvedConfiguration: StockpileDevicePoseCaptureConfiguration.alphaDefault.resolved(using: capabilities),
            sampleCount: 24,
            latestSample: StockpileDevicePoseSample(
                sequenceNumber: 24,
                sessionTimestamp: 3.2,
                trackingState: StockpileDevicePoseTrackingState(phase: .tracking),
                transform: StockpileDevicePoseTransform(
                    matrix: Array(repeating: 0, count: 16),
                    translationMeters: StockpileDevicePoseVector3(x: 0, y: 0, z: 0),
                    eulerAnglesRadians: StockpileDevicePoseVector3(x: 0, y: 0, z: 0)
                )
            )
        )

        XCTAssertEqual(snapshot.telemetry.samplesCaptured, 24)
        XCTAssertTrue(snapshot.telemetry.headingStable)
        XCTAssertTrue(snapshot.telemetry.motionStable)
        XCTAssertTrue(snapshot.telemetry.lidarAssistAvailable)
    }

    func testOnDeviceVisionSummaryClampsScoresAndCarriesMLSource() throws {
        let summary = StockpileOnDeviceVisionSummary(
            source: .visionForegroundInstanceMask,
            usesMachineLearning: true,
            pileSegmentationScore: 1.4,
            toeSegmentationScore: -0.2,
            segmentationConfidenceScore: 0.72,
            foregroundCoverageRatio: 0.38,
            lowerFrameOccupancyRatio: 0.55,
            materialFamilyCode: "aggregate_rock",
            materialFamilyLabel: "Coarse aggregate / rock",
            materialConfidenceScore: 1.2,
            guidanceHint: "Keep the segmented pile face centered."
        )

        XCTAssertEqual(summary.source, .visionForegroundInstanceMask)
        XCTAssertTrue(summary.usesMachineLearning)
        XCTAssertEqual(try XCTUnwrap(summary.pileSegmentationScore), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.toeSegmentationScore), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.segmentationConfidenceScore), 0.72, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.materialConfidenceScore), 1, accuracy: 0.0001)
        XCTAssertEqual(summary.materialFamilyCode, "aggregate_rock")
    }

    func testSnapshotCarriesOnDeviceVisionSummary() {
        let capabilities = StockpileDevicePoseCaptureCapabilities(
            platformLabel: "iOS",
            supportsWorldTracking: true,
            supportsGravityAndHeading: true,
            supportsSceneDepth: true,
            supportsSmoothedSceneDepth: true,
            supportsSceneMesh: true,
            lidarAssistAvailable: true
        )
        let visionSummary = StockpileOnDeviceVisionSummary(
            source: .visionForegroundInstanceMask,
            usesMachineLearning: true,
            pileSegmentationScore: 0.81,
            toeSegmentationScore: 0.76,
            segmentationConfidenceScore: 0.78,
            foregroundCoverageRatio: 0.42,
            lowerFrameOccupancyRatio: 0.61,
            materialFamilyCode: "sand_soil_fines",
            materialFamilyLabel: "Sand / soil / fines",
            materialConfidenceScore: 0.66,
            guidanceHint: "Slow down and keep the toe line in the lower third."
        )

        let snapshot = StockpileDevicePoseCaptureSnapshot(
            status: .running,
            capabilities: capabilities,
            configuration: .alphaDefault,
            resolvedConfiguration: StockpileDevicePoseCaptureConfiguration.alphaDefault.resolved(using: capabilities),
            sampleCount: 9,
            onDeviceVision: visionSummary
        )

        XCTAssertEqual(snapshot.onDeviceVision, visionSummary)
        XCTAssertEqual(snapshot.onDeviceVision?.source, .visionForegroundInstanceMask)
    }

    func testARKitPrimaryRecordingSnapshotCarriesSingleCameraOwnerMetadata() {
        let outputURL = URL(fileURLWithPath: "/tmp/stockpile-arkit-primary.mov")
        let startedAt = Date(timeIntervalSince1970: 100)
        let finishedAt = Date(timeIntervalSince1970: 108.4)
        let output = StockpileARKitPrimaryRecordingOutput(
            fileURL: outputURL,
            fileSizeBytes: 4_096,
            startedAt: startedAt,
            finishedAt: finishedAt,
            frameCount: 252
        )

        let snapshot = StockpileARKitPrimaryRecordingSnapshot(
            status: .finished,
            output: output,
            frameCount: 252,
            droppedFrameCount: 4,
            usesSingleCameraOwner: true,
            includesDepth: true,
            includesOnDeviceVision: true,
            issueDescription: nil
        )

        XCTAssertEqual(snapshot.status, .finished)
        XCTAssertEqual(snapshot.output, output)
        XCTAssertEqual(snapshot.frameCount, 252)
        XCTAssertEqual(snapshot.droppedFrameCount, 4)
        XCTAssertTrue(snapshot.usesSingleCameraOwner)
        XCTAssertTrue(snapshot.includesDepth)
        XCTAssertTrue(snapshot.includesOnDeviceVision)
        XCTAssertEqual(output.durationSec, 8.4, accuracy: 0.0001)
    }

    func testARKitPrimaryRecordingModelsClampInvalidCountsAndDurations() {
        let output = StockpileARKitPrimaryRecordingOutput(
            fileURL: URL(fileURLWithPath: "/tmp/bad.mov"),
            fileSizeBytes: -10,
            startedAt: Date(timeIntervalSince1970: 50),
            finishedAt: Date(timeIntervalSince1970: 40),
            frameCount: -3
        )
        let snapshot = StockpileARKitPrimaryRecordingSnapshot(
            status: .recording,
            output: output,
            frameCount: -10,
            droppedFrameCount: -5,
            usesSingleCameraOwner: true,
            includesDepth: false,
            includesOnDeviceVision: false,
            issueDescription: " "
        )

        XCTAssertEqual(output.fileSizeBytes, 0)
        XCTAssertEqual(output.frameCount, 0)
        XCTAssertEqual(output.durationSec, 0)
        XCTAssertEqual(snapshot.frameCount, 0)
        XCTAssertEqual(snapshot.droppedFrameCount, 0)
        XCTAssertEqual(snapshot.issueDescription, "")
    }

    func testUnsupportedARKitPrimaryRecordingReportsUnavailable() {
        #if !os(iOS)
        let session = StockpileARKitDevicePoseCaptureSession()
        XCTAssertEqual(session.latestRecordingSnapshot.status, .idle)

        XCTAssertThrowsError(
            try session.startRecording(to: URL(fileURLWithPath: "/tmp/unsupported.mov"))
        ) { error in
            XCTAssertEqual(
                error as? StockpileDevicePoseCaptureError,
                .unavailable("ARKit primary recording is available only in the iOS app runtime.")
            )
        }
        XCTAssertEqual(session.latestRecordingSnapshot.status, .failed)
        XCTAssertEqual(
            session.latestRecordingSnapshot.issueDescription,
            "ARKit primary recording is available only in the iOS app runtime."
        )
        #endif
    }
}
