import XCTest
@testable import StockpileCameraCapture

final class StockpileCameraCaptureTests: XCTestCase {
    func testMarkerlessGuidanceUsesDepthQuickVolumeAndTrackingInsteadOfReferenceBlocking() {
        let telemetry = StockpileCaptureSensorSnapshot(
            sampleCount: 32,
            motionSignalsIncluded: true,
            gravityVectorIncluded: true,
            headingSignalsIncluded: true,
            cameraCalibrationIncluded: true,
            motionStable: true,
            headingStable: true,
            lidarAssistAvailable: true,
            trackingState: "world_tracking_normal",
            sensorMetadata: StockpileCaptureSensorMetadata(
                depthDataIncluded: true,
                worldAlignment: "gravityAndHeading"
            )
        )
        let progress = StockpileLiveGuidanceEstimator.estimate(
            totalSteps: 3,
            manualCompletedSteps: 0,
            elapsedRecordingTime: 24,
            sceneCoverageAccumulator: 0.86,
            sceneAnalysis: StockpileCaptureSceneAnalysis(
                capturedAt: Date(timeIntervalSince1970: 10),
                referenceCandidateCount: 0,
                referenceCandidateConfidence: 0,
                brightnessScore: 0.56,
                sharpnessScore: 0.64,
                sceneChangeScore: 0.34,
                structuredArtifactScore: 0.08,
                sceneFitConfidence: 0.52,
                sceneRejectionConfidence: 0.08,
                pileSegmentationConfidence: 0.72,
                toeSegmentationConfidence: 0.72,
                depthConfidence: 0.84,
                quickVolumeConfidence: 0.78,
                trackingConfidence: 0.88
            ),
            telemetry: telemetry,
            markerlessCaptureEnabled: true
        )

        XCTAssertEqual(progress.phase, .readyToFinish)
        XCTAssertTrue(progress.guidance.isReadyToFinish)
        XCTAssertEqual(progress.guidance.referenceVisibility.level, .good)
        XCTAssertNil(progress.guidance.decodedReferenceQuality)
        XCTAssertEqual(progress.guidance.sceneFit?.level, .good)
        XCTAssertEqual(progress.guidance.sceneRejection?.level, .good)
    }

    func testDefaultGuidanceStillRequiresReferenceVisibilityBeforeFinish() {
        let telemetry = StockpileCaptureSensorSnapshot(
            sampleCount: 32,
            motionSignalsIncluded: true,
            gravityVectorIncluded: true,
            headingSignalsIncluded: true,
            cameraCalibrationIncluded: true,
            motionStable: true,
            headingStable: true,
            lidarAssistAvailable: true,
            trackingState: "world_tracking_normal",
            sensorMetadata: StockpileCaptureSensorMetadata(
                depthDataIncluded: true,
                worldAlignment: "gravityAndHeading"
            )
        )
        let progress = StockpileLiveGuidanceEstimator.estimate(
            totalSteps: 3,
            manualCompletedSteps: 0,
            elapsedRecordingTime: 24,
            sceneCoverageAccumulator: 0.86,
            sceneAnalysis: StockpileCaptureSceneAnalysis(
                capturedAt: Date(timeIntervalSince1970: 10),
                referenceCandidateCount: 0,
                referenceCandidateConfidence: 0,
                brightnessScore: 0.56,
                sharpnessScore: 0.64,
                sceneChangeScore: 0.34,
                structuredArtifactScore: 0.08,
                sceneFitConfidence: 0.52,
                sceneRejectionConfidence: 0.08,
                pileSegmentationConfidence: 0.72,
                toeSegmentationConfidence: 0.72,
                depthConfidence: 0.84,
                quickVolumeConfidence: 0.78,
                trackingConfidence: 0.88
            ),
            telemetry: telemetry
        )

        XCTAssertEqual(progress.phase, .capturing)
        XCTAssertFalse(progress.guidance.isReadyToFinish)
        XCTAssertEqual(progress.guidance.referenceVisibility.level, .blocked)
    }

    func testPermissionStateExplainsDeniedAccessClearly() {
        let permission = StockpileCameraPermissionState(status: .denied, canRequestAccess: false)

        XCTAssertFalse(permission.isGranted)
        XCTAssertTrue(permission.needsAttention)
        XCTAssertTrue(permission.requiresSettingsVisit)
        XCTAssertEqual(permission.statusLabel, "Denied")
        XCTAssertEqual(permission.operatorHint, "Turn on camera access in Settings to keep recording in app.")
    }

    func testGuidanceSummaryFlagsBlockedCoverageAndKeepsReferenceAndMotionSeparate() {
        let summary = StockpileCaptureGuidanceSummary(
            referenceVisibility: StockpileCaptureGuidanceMetric(
                title: "Reference visibility",
                score: 0.82,
                watchThreshold: 0.7,
                blockedThreshold: 0.45,
                detail: "References are visible."
            ),
            coverage: StockpileCaptureGuidanceMetric(
                title: "Coverage",
                score: 0.43,
                watchThreshold: 0.7,
                blockedThreshold: 0.5,
                detail: "Finish the far edge before wrapping up."
            ),
            motion: StockpileCaptureGuidanceMetric(
                title: "Motion",
                score: 0.77,
                watchThreshold: 0.72,
                blockedThreshold: 0.5,
                detail: "Motion is steady enough."
            )
        )

        XCTAssertEqual(summary.overallLevel, .blocked)
        XCTAssertFalse(summary.isReadyToFinish)
        XCTAssertEqual(summary.primaryOperatorAction, "Finish the far edge before wrapping up.")
    }

    func testGuidanceSummaryPrioritizesSceneMatchBeforeOtherBlockers() {
        let summary = StockpileCaptureGuidanceSummary(
            referenceVisibility: StockpileCaptureGuidanceMetric(
                title: "Reference visibility",
                score: 0.38,
                watchThreshold: 0.7,
                blockedThreshold: 0.45,
                detail: "Move until two tagged references are visible together."
            ),
            coverage: StockpileCaptureGuidanceMetric(
                title: "Coverage",
                score: 0.9,
                watchThreshold: 0.7,
                blockedThreshold: 0.5,
                detail: "Coverage is strong."
            ),
            motion: StockpileCaptureGuidanceMetric(
                title: "Motion",
                score: 0.88,
                watchThreshold: 0.72,
                blockedThreshold: 0.5,
                detail: "Motion is steady enough."
            ),
            decodedReferenceQuality: StockpileCaptureGuidanceMetric(
                title: "Reference quality",
                score: 0.5,
                watchThreshold: 0.76,
                blockedThreshold: 0.52,
                detail: "One tag decoded. Hold flatter until a second resolves."
            ),
            sceneFit: StockpileCaptureGuidanceMetric(
                title: "Scene framing",
                score: 0.86,
                watchThreshold: 0.72,
                blockedThreshold: 0.48,
                detail: "Pile framing looks steady."
            ),
            sceneRejection: StockpileCaptureGuidanceMetric(
                title: "Scene match",
                score: 0.16,
                watchThreshold: 0.78,
                blockedThreshold: 0.5,
                detail: "Wrong scene. Reframe on the pile and tagged refs."
            ),
            materialConfidence: StockpileCaptureGuidanceMetric(
                title: "Material confidence",
                score: 0.62,
                watchThreshold: 0.72,
                blockedThreshold: 0.12,
                detail: "Material read is settling. Keep the pile centered."
            )
        )

        XCTAssertEqual(summary.overallLevel, .blocked)
        XCTAssertFalse(summary.isReadyToFinish)
        XCTAssertEqual(summary.primaryOperatorAction, "Wrong scene. Reframe on the pile and tagged refs.")
    }

    func testGuidanceSummaryRequiresToeSegmentationBeforeFinish() {
        let summary = StockpileCaptureGuidanceSummary(
            referenceVisibility: StockpileCaptureGuidanceMetric(
                title: "Reference visibility",
                score: 0.92,
                watchThreshold: 0.7,
                blockedThreshold: 0.45,
                detail: "Two tagged references are locked."
            ),
            coverage: StockpileCaptureGuidanceMetric(
                title: "Coverage",
                score: 0.9,
                watchThreshold: 0.7,
                blockedThreshold: 0.5,
                detail: "Perimeter coverage looks strong."
            ),
            motion: StockpileCaptureGuidanceMetric(
                title: "Motion",
                score: 0.9,
                watchThreshold: 0.72,
                blockedThreshold: 0.5,
                detail: "Motion stability is strong enough for reconstruction."
            ),
            decodedReferenceQuality: StockpileCaptureGuidanceMetric(
                title: "Reference quality",
                score: 0.9,
                watchThreshold: 0.76,
                blockedThreshold: 0.52,
                detail: "Reference tags are decoding cleanly."
            ),
            pileSegmentation: StockpileCaptureGuidanceMetric(
                title: "Pile segmentation",
                score: 0.82,
                watchThreshold: 0.72,
                blockedThreshold: 0.48,
                detail: "Pile silhouette is mostly closed."
            ),
            toeSegmentation: StockpileCaptureGuidanceMetric(
                title: "Toe segmentation",
                score: 0.42,
                watchThreshold: 0.74,
                blockedThreshold: 0.5,
                detail: "Bring the toe edge back into view before finishing."
            ),
            sceneFit: StockpileCaptureGuidanceMetric(
                title: "Scene framing",
                score: 0.88,
                watchThreshold: 0.72,
                blockedThreshold: 0.48,
                detail: "Pile framing looks steady."
            ),
            sceneRejection: StockpileCaptureGuidanceMetric(
                title: "Scene match",
                score: 0.9,
                watchThreshold: 0.78,
                blockedThreshold: 0.5,
                detail: "Scene matches a stockpile capture."
            )
        )

        XCTAssertEqual(summary.overallLevel, .blocked)
        XCTAssertFalse(summary.isReadyToFinish)
        XCTAssertEqual(summary.primaryOperatorAction, "Bring the toe edge back into view before finishing.")
    }

    func testGuidanceSummaryPrioritizesPileSegmentationBeforeToeSegmentation() {
        let summary = StockpileCaptureGuidanceSummary(
            referenceVisibility: StockpileCaptureGuidanceMetric(
                title: "Reference visibility",
                score: 0.92,
                watchThreshold: 0.7,
                blockedThreshold: 0.45,
                detail: "Two tagged references are locked."
            ),
            coverage: StockpileCaptureGuidanceMetric(
                title: "Coverage",
                score: 0.9,
                watchThreshold: 0.7,
                blockedThreshold: 0.5,
                detail: "Perimeter coverage looks strong."
            ),
            motion: StockpileCaptureGuidanceMetric(
                title: "Motion",
                score: 0.9,
                watchThreshold: 0.72,
                blockedThreshold: 0.5,
                detail: "Motion stability is strong enough for reconstruction."
            ),
            decodedReferenceQuality: StockpileCaptureGuidanceMetric(
                title: "Reference quality",
                score: 0.9,
                watchThreshold: 0.76,
                blockedThreshold: 0.52,
                detail: "Reference tags are decoding cleanly."
            ),
            pileSegmentation: StockpileCaptureGuidanceMetric(
                title: "Pile segmentation",
                score: 0.69,
                watchThreshold: 0.72,
                blockedThreshold: 0.48,
                detail: "Keep the pile body centered until the silhouette closes."
            ),
            toeSegmentation: StockpileCaptureGuidanceMetric(
                title: "Toe segmentation",
                score: 0.44,
                watchThreshold: 0.74,
                blockedThreshold: 0.5,
                detail: "Bring the toe edge back into view before finishing."
            ),
            sceneFit: StockpileCaptureGuidanceMetric(
                title: "Scene framing",
                score: 0.88,
                watchThreshold: 0.72,
                blockedThreshold: 0.48,
                detail: "Pile framing looks steady."
            ),
            sceneRejection: StockpileCaptureGuidanceMetric(
                title: "Scene match",
                score: 0.9,
                watchThreshold: 0.78,
                blockedThreshold: 0.5,
                detail: "Scene matches a stockpile capture."
            )
        )

        XCTAssertEqual(summary.overallLevel, .blocked)
        XCTAssertFalse(summary.isReadyToFinish)
        XCTAssertEqual(summary.primaryOperatorAction, "Keep the pile body centered until the silhouette closes.")
    }

    func testGuidanceSummaryUsesMaterialAdvisoryWithoutBlockingReadiness() {
        let summary = StockpileCaptureGuidanceSummary(
            referenceVisibility: StockpileCaptureGuidanceMetric(
                title: "Reference visibility",
                score: 0.92,
                watchThreshold: 0.7,
                blockedThreshold: 0.45,
                detail: "Two tagged references are locked."
            ),
            coverage: StockpileCaptureGuidanceMetric(
                title: "Coverage",
                score: 0.9,
                watchThreshold: 0.7,
                blockedThreshold: 0.5,
                detail: "Perimeter coverage looks strong."
            ),
            motion: StockpileCaptureGuidanceMetric(
                title: "Motion",
                score: 0.9,
                watchThreshold: 0.72,
                blockedThreshold: 0.5,
                detail: "Motion stability is strong enough for reconstruction."
            ),
            decodedReferenceQuality: StockpileCaptureGuidanceMetric(
                title: "Reference quality",
                score: 0.9,
                watchThreshold: 0.76,
                blockedThreshold: 0.52,
                detail: "Reference tags are decoding cleanly."
            ),
            sceneFit: StockpileCaptureGuidanceMetric(
                title: "Scene framing",
                score: 0.88,
                watchThreshold: 0.72,
                blockedThreshold: 0.48,
                detail: "Pile framing looks steady."
            ),
            sceneRejection: StockpileCaptureGuidanceMetric(
                title: "Scene match",
                score: 0.9,
                watchThreshold: 0.78,
                blockedThreshold: 0.5,
                detail: "Scene matches a stockpile capture."
            ),
            materialConfidence: StockpileCaptureGuidanceMetric(
                title: "Material confidence",
                score: 0.64,
                watchThreshold: 0.72,
                blockedThreshold: 0.12,
                detail: "Material read is settling. Keep the pile centered."
            )
        )

        XCTAssertEqual(summary.overallLevel, .good)
        XCTAssertTrue(summary.isReadyToFinish)
        XCTAssertEqual(summary.primaryOperatorAction, "Material read is settling. Keep the pile centered.")
    }

    func testMarkerlessGuidanceUsesLidarTrackingInsteadOfTaggedReferences() {
        let progress = StockpileLiveGuidanceEstimator.estimate(
            totalSteps: 3,
            manualCompletedSteps: 1,
            elapsedRecordingTime: 28,
            sceneCoverageAccumulator: 0.72,
            sceneAnalysis: StockpileCaptureSceneAnalysis(
                capturedAt: Date(timeIntervalSince1970: 1_900),
                referenceCandidateCount: 0,
                referenceCandidateConfidence: 0,
                brightnessScore: 0.64,
                sharpnessScore: 0.72,
                sceneChangeScore: 0.42,
                structuredArtifactScore: 0.08,
                sceneFitConfidence: 0.78,
                sceneRejectionConfidence: 0.12,
                pileSegmentationConfidence: 0.9,
                toeSegmentationConfidence: 0.86
            ),
            telemetry: StockpileCaptureSensorSnapshot(
                sampleCount: 32,
                motionSignalsIncluded: true,
                gravityVectorIncluded: true,
                headingSignalsIncluded: true,
                cameraCalibrationIncluded: true,
                motionStable: true,
                headingStable: true,
                lidarAssistAvailable: true,
                trackingState: "sensor_sampling_active"
            ),
            modeConfig: .markerless
        )

        XCTAssertEqual(progress.guidance.referenceVisibility.level, .good)
        XCTAssertNil(progress.guidance.decodedReferenceQuality)
        XCTAssertEqual(progress.guidance.sceneRejection?.level, .good)
        XCTAssertFalse(progress.guidance.primaryOperatorAction.localizedCaseInsensitiveContains("tagged"))
        XCTAssertFalse(progress.guidance.primaryOperatorAction.localizedCaseInsensitiveContains("wrong scene"))
        XCTAssertTrue(progress.guidance.isReadyToFinish)
    }

    func testMarkerRequiredGuidanceStillBlocksWithoutTaggedReferences() {
        let progress = StockpileLiveGuidanceEstimator.estimate(
            totalSteps: 3,
            manualCompletedSteps: 1,
            elapsedRecordingTime: 28,
            sceneCoverageAccumulator: 0.72,
            sceneAnalysis: StockpileCaptureSceneAnalysis(
                capturedAt: Date(timeIntervalSince1970: 1_901),
                referenceCandidateCount: 0,
                referenceCandidateConfidence: 0,
                brightnessScore: 0.64,
                sharpnessScore: 0.72,
                sceneChangeScore: 0.42,
                structuredArtifactScore: 0.08,
                sceneFitConfidence: 0.78,
                sceneRejectionConfidence: 0.12,
                pileSegmentationConfidence: 0.9,
                toeSegmentationConfidence: 0.86
            ),
            telemetry: StockpileCaptureSensorSnapshot(
                sampleCount: 32,
                motionSignalsIncluded: true,
                gravityVectorIncluded: true,
                headingSignalsIncluded: true,
                cameraCalibrationIncluded: true,
                motionStable: true,
                headingStable: true,
                lidarAssistAvailable: true,
                trackingState: "sensor_sampling_active"
            )
        )

        XCTAssertEqual(progress.guidance.referenceVisibility.level, .blocked)
        XCTAssertEqual(progress.guidance.decodedReferenceQuality?.level, .blocked)
        XCTAssertTrue(progress.guidance.primaryOperatorAction.localizedCaseInsensitiveContains("tagged"))
        XCTAssertFalse(progress.guidance.isReadyToFinish)
    }

    func testMockSessionProgressesThroughGuidedCaptureAndCompletes() {
        let mock = StockpileCameraCaptureSessionMock(permission: .preview)

        XCTAssertEqual(mock.state.phase, .idle)
        XCTAssertEqual(mock.state.recordingLifecycle, .idle)

        mock.startGuidedCapture()
        XCTAssertEqual(mock.state.phase, .capturing)
        XCTAssertEqual(mock.state.progress, 0, accuracy: 0.0001)
        XCTAssertEqual(mock.state.activePrompt, "Walk the toe boundary and keep two tagged references visible together.")
        XCTAssertEqual(mock.state.recordingLifecycle, .recording)
        XCTAssertNil(mock.state.recordingOutput)

        mock.advanceGuidedCapture()
        XCTAssertEqual(mock.state.phase, .capturing)
        XCTAssertEqual(mock.state.completedSteps, 1)
        XCTAssertGreaterThan(mock.state.progress, 0)
        XCTAssertLessThan(mock.state.progress, 1)

        mock.advanceGuidedCapture()
        XCTAssertEqual(mock.state.phase, .readyToFinish)
        XCTAssertTrue(mock.state.guidance.isReadyToFinish)
        XCTAssertTrue(mock.state.canFinish)

        mock.finishGuidedCapture()
        XCTAssertEqual(mock.state.phase, .completed)
        XCTAssertEqual(mock.state.progress, 1, accuracy: 0.0001)
        XCTAssertEqual(mock.state.statusLabel, "Recording saved")
        XCTAssertEqual(mock.state.recordingLifecycle, .finished)
        XCTAssertNotNil(mock.state.recordingOutput)
    }

    func testMockSessionBlocksWhenPermissionIsDenied() {
        let mock = StockpileCameraCaptureSessionMock(permission: .blockedPreview)

        XCTAssertEqual(mock.state.phase, .blocked)
        XCTAssertEqual(mock.state.permission.status, .denied)

        mock.startGuidedCapture()

        XCTAssertEqual(mock.state.phase, .blocked)
        XCTAssertEqual(mock.state.activePrompt, "Turn on camera access in Settings to keep recording in app.")
    }

    func testMockSessionSupportsManualRecordingLifecycle() {
        let mock = StockpileCameraCaptureSessionMock(permission: .preview)

        XCTAssertTrue(mock.state.canStartRecording)
        XCTAssertFalse(mock.state.canStopRecording)

        mock.startRecording()

        XCTAssertEqual(mock.state.phase, .capturing)
        XCTAssertEqual(mock.state.recordingLifecycle, .recording)
        XCTAssertTrue(mock.state.canStopRecording)

        mock.stopRecording()

        XCTAssertEqual(mock.state.recordingLifecycle, .finished)
        XCTAssertNotNil(mock.state.recordingOutput)
        XCTAssertFalse(mock.state.canStopRecording)
    }
}
