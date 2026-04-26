import AVFoundation
import XCTest
@testable import StockpileCameraCapture

final class StockpileCameraCaptureSessionLiveTests: XCTestCase {
    func testRequestCameraAccessTransitionsToIdleWhenPermissionIsGranted() async {
        let platform = TestCameraPlatform(
            currentPermission: StockpileCameraPermissionState(status: .notDetermined, canRequestAccess: true),
            requestedPermission: StockpileCameraPermissionState(status: .authorized, canRequestAccess: false)
        )
        let session = StockpileCameraCaptureSessionLive(platform: platform)

        XCTAssertEqual(session.state.phase, .idle)
        XCTAssertEqual(session.state.sessionLifecycle, .permissionRequired)
        XCTAssertEqual(session.state.activePrompt, "Allow rear-camera access to start recording in app.")

        let permission = await session.requestCameraAccess()

        XCTAssertEqual(permission.status, .authorized)
        XCTAssertEqual(session.state.phase, .idle)
        XCTAssertEqual(session.state.sessionLifecycle, .unconfigured)
        XCTAssertEqual(session.state.activePrompt, "Start recording when the full pile and two tagged references are in view.")
    }

    func testStartGuidedCaptureRunsSessionAndCompletesGuidanceFlow() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory()
        )

        session.startGuidedCapture()
        await waitUntil {
            session.state.phase == .capturing &&
            session.state.sessionLifecycle == .running &&
            session.state.recordingLifecycle == .recording
        }

        XCTAssertEqual(platform.makeSessionControllerCallCount, 1)
        XCTAssertEqual(controller.startRunningCallCount, 1)
        XCTAssertEqual(controller.startRecordingCallCount, 1)
        XCTAssertEqual(session.state.activeDeviceName, "Back Wide Camera")
        XCTAssertTrue(session.state.isPreviewAvailable)
        XCTAssertNil(session.state.recordingOutput)
        XCTAssertEqual(session.state.activePrompt, "Frame the pile and keep two references visible.")
        #if os(iOS)
        XCTAssertEqual(session.latestTelemetrySnapshot?.lidarAssistAvailable, true)
        #else
        XCTAssertEqual(session.latestTelemetrySnapshot?.lidarAssistAvailable, false)
        #endif
        XCTAssertEqual(session.latestTelemetrySnapshot?.cameraCalibrationIncluded, true)

        session.advanceGuidedCapture()
        session.advanceGuidedCapture()

        XCTAssertEqual(session.state.phase, .readyToFinish)
        XCTAssertTrue(session.state.canFinish)

        session.finishGuidedCapture()
        await waitUntil {
            session.state.phase == .completed &&
            session.state.sessionLifecycle == .stopped &&
            session.state.recordingLifecycle == .finished &&
            session.state.recordingOutput != nil
        }

        XCTAssertEqual(controller.stopRunningCallCount, 1)
        XCTAssertEqual(controller.stopRecordingCallCount, 1)
        XCTAssertEqual(session.state.statusLabel, "Recording saved")
        XCTAssertGreaterThan(try XCTUnwrap(session.state.recordingOutput).fileSizeBytes ?? 0, 0)
    }

    func testManualRecordingLifecycleFinalizesClipBeforeStoppingPreview() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory()
        )

        session.startCaptureSession()
        await waitUntil {
            session.state.sessionLifecycle == .running
        }

        session.startRecording()
        await waitUntil {
            session.state.recordingLifecycle == .recording
        }

        XCTAssertEqual(session.state.phase, .capturing)
        XCTAssertEqual(controller.startRecordingCallCount, 1)

        session.stopRecording()
        await waitUntil {
            session.state.recordingLifecycle == .finished &&
            session.state.sessionLifecycle == .running &&
            session.state.recordingOutput != nil
        }

        XCTAssertEqual(controller.stopRunningCallCount, 0)
        XCTAssertEqual(controller.stopRecordingCallCount, 1)

        session.stopCaptureSession()
        await waitUntil {
            session.state.sessionLifecycle == .stopped
        }
    }

    func testLiveGuidancePromotesCaptureToReadyToFinishFromSceneAnalysis() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let timeSource = TestTimeSource(now: Date(timeIntervalSince1970: 1_000))
        let telemetryRuntime = TestTelemetryRuntime(
            snapshot: StockpileCaptureSensorSnapshot(
                sampleCount: 24,
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
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory(),
            now: { timeSource.now },
            telemetryRuntime: telemetryRuntime
        )

        session.startGuidedCapture()
        await waitUntil {
            session.state.recordingLifecycle == .recording
        }

        timeSource.advance(by: 22)
        controller.setSceneAnalysis(
            StockpileCaptureSceneAnalysis(
                capturedAt: timeSource.now,
                referenceCandidateCount: 2,
                referenceCandidateConfidence: 0.84,
                brightnessScore: 0.58,
                sharpnessScore: 0.74,
                sceneChangeScore: 0.44
            )
        )

        await waitUntil(timeout: 2) {
            session.state.phase == .readyToFinish &&
            session.state.canFinish
        }

        XCTAssertTrue(session.state.guidance.isReadyToFinish)
        XCTAssertEqual(session.state.completedSteps, 2)
        XCTAssertEqual(session.state.activePrompt, "Scene and references look strong. Finish when the last edge is covered.")
    }

    func testMarkerlessLiveGuidanceReachesReadyWithoutTaggedReferences() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let timeSource = TestTimeSource(now: Date(timeIntervalSince1970: 1_080))
        let telemetryRuntime = TestTelemetryRuntime(
            snapshot: StockpileCaptureSensorSnapshot(
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
        )
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            markerlessCaptureEnabled: true,
            recordingsDirectory: makeTemporaryRecordingDirectory(),
            now: { timeSource.now },
            telemetryRuntime: telemetryRuntime
        )

        session.startGuidedCapture()
        await waitUntil {
            session.state.recordingLifecycle == .recording
        }

        timeSource.advance(by: 28)
        controller.setSceneAnalysis(
            StockpileCaptureSceneAnalysis(
                capturedAt: timeSource.now,
                referenceCandidateCount: 0,
                referenceCandidateConfidence: 0,
                brightnessScore: 0.64,
                sharpnessScore: 0.72,
                sceneChangeScore: 0.78,
                structuredArtifactScore: 0.08,
                sceneFitConfidence: 0.78,
                sceneRejectionConfidence: 0.08,
                pileSegmentationConfidence: 0.9,
                toeSegmentationConfidence: 0.86,
                depthConfidence: 0.84,
                quickVolumeConfidence: 0.78,
                trackingConfidence: 0.9
            )
        )

        await waitUntil(timeout: 2) {
            session.state.phase == .readyToFinish &&
            session.state.canFinish
        }

        XCTAssertEqual(session.state.guidance.referenceVisibility.title, "LiDAR tracking")
        XCTAssertEqual(session.state.guidance.referenceVisibility.level, .good)
        XCTAssertNil(session.state.guidance.decodedReferenceQuality)
        XCTAssertTrue(session.state.guidance.isReadyToFinish)
        XCTAssertEqual(
            session.state.activePrompt,
            "Depth tracking looks strong. Finish when the last edge is covered."
        )
    }

    func testLiveGuidanceUsesStrongSegmentationConfidenceToPromoteReadyToFinish() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let timeSource = TestTimeSource(now: Date(timeIntervalSince1970: 1_250))
        let telemetryRuntime = TestTelemetryRuntime(
            snapshot: StockpileCaptureSensorSnapshot(
                sampleCount: 24,
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
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory(),
            now: { timeSource.now },
            telemetryRuntime: telemetryRuntime
        )

        session.startGuidedCapture()
        await waitUntil {
            session.state.recordingLifecycle == .recording
        }

        timeSource.advance(by: 24)
        controller.setSceneAnalysis(
            StockpileCaptureSceneAnalysis(
                capturedAt: timeSource.now,
                referenceCandidateCount: 2,
                referenceCandidateConfidence: 0.63,
                brightnessScore: 0.36,
                sharpnessScore: 0.38,
                sceneChangeScore: 0.22,
                structuredArtifactScore: 0.16,
                pileSegmentationConfidence: 0.92,
                toeSegmentationConfidence: 0.88
            )
        )

        await waitUntil(timeout: 2) {
            session.state.phase == .readyToFinish &&
            session.state.guidance.sceneFit?.level == .good &&
            session.state.guidance.pileSegmentation?.level == .good &&
            session.state.guidance.toeSegmentation?.level == .good
        }

        XCTAssertTrue(session.state.canFinish)
        XCTAssertTrue(session.state.guidance.isReadyToFinish)
        XCTAssertEqual(session.state.completedSteps, 2)
        XCTAssertEqual(session.state.activePrompt, "Scene and references look strong. Finish when the last edge is covered.")
    }

    func testLiveGuidanceKeepsCaptureOpenWhenToeSegmentationConfidenceIsWeak() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let timeSource = TestTimeSource(now: Date(timeIntervalSince1970: 1_350))
        let telemetryRuntime = TestTelemetryRuntime(
            snapshot: StockpileCaptureSensorSnapshot(
                sampleCount: 24,
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
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory(),
            now: { timeSource.now },
            telemetryRuntime: telemetryRuntime
        )

        session.startGuidedCapture()
        await waitUntil {
            session.state.recordingLifecycle == .recording
        }

        timeSource.advance(by: 24)
        controller.setSceneAnalysis(
            StockpileCaptureSceneAnalysis(
                capturedAt: timeSource.now,
                referenceCandidateCount: 2,
                referenceCandidateConfidence: 0.84,
                brightnessScore: 0.6,
                sharpnessScore: 0.72,
                sceneChangeScore: 0.45,
                structuredArtifactScore: 0.04,
                pileSegmentationConfidence: 0.9,
                toeSegmentationConfidence: 0.22
            )
        )

        await waitUntil(timeout: 2) {
            session.state.guidance.toeSegmentation?.level == .blocked
        }

        XCTAssertEqual(session.state.phase, .capturing)
        XCTAssertFalse(session.state.canFinish)
        XCTAssertFalse(session.state.guidance.isReadyToFinish)
        XCTAssertEqual(
            session.state.activePrompt,
            "Keep the full toe boundary visible before you seal the clip."
        )
    }

    func testLiveGuidanceRequiresSecondStableReferenceBeforeFinishEvenWhenOneTagDecodes() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let timeSource = TestTimeSource(now: Date(timeIntervalSince1970: 1_500))
        let telemetryRuntime = TestTelemetryRuntime(
            snapshot: StockpileCaptureSensorSnapshot(
                sampleCount: 24,
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
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory(),
            now: { timeSource.now },
            telemetryRuntime: telemetryRuntime
        )

        session.startGuidedCapture()
        await waitUntil {
            session.state.recordingLifecycle == .recording
        }

        timeSource.advance(by: 23)
        controller.setSceneAnalysis(
            StockpileCaptureSceneAnalysis(
                capturedAt: timeSource.now,
                referenceCandidateCount: 2,
                referenceCandidateConfidence: 0.92,
                brightnessScore: 0.64,
                sharpnessScore: 0.79,
                sceneChangeScore: 0.46,
                structuredArtifactScore: 0.08,
                decodedReferenceMarkerCount: 1,
                decodedReferenceMarkerConfidence: 0.94,
                sceneFitConfidence: 0.9,
                sceneRejectionConfidence: 0.08
            )
        )

        await waitUntil(timeout: 2) {
            session.state.guidance.decodedReferenceQuality?.level == .watch &&
            session.state.completedSteps == 2
        }

        XCTAssertEqual(session.state.phase, .capturing)
        XCTAssertFalse(session.state.canFinish)
        XCTAssertFalse(session.state.guidance.isReadyToFinish)
        XCTAssertEqual(session.state.activePrompt, "Only one tagged reference is holding. Bring a second into view.")
    }

    func testLiveGuidanceAllowsReadyToFinishWhileMaterialReadSettles() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let timeSource = TestTimeSource(now: Date(timeIntervalSince1970: 1_750))
        let telemetryRuntime = TestTelemetryRuntime(
            snapshot: StockpileCaptureSensorSnapshot(
                sampleCount: 24,
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
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory(),
            now: { timeSource.now },
            telemetryRuntime: telemetryRuntime
        )

        session.startGuidedCapture()
        await waitUntil {
            session.state.recordingLifecycle == .recording
        }

        timeSource.advance(by: 23)
        controller.setSceneAnalysis(
            StockpileCaptureSceneAnalysis(
                capturedAt: timeSource.now,
                referenceCandidateCount: 2,
                referenceCandidateConfidence: 0.88,
                brightnessScore: 0.62,
                sharpnessScore: 0.76,
                sceneChangeScore: 0.44,
                structuredArtifactScore: 0.08,
                decodedReferenceMarkerCount: 2,
                decodedReferenceMarkerConfidence: 0.93,
                materialSuggestion: "Ore fines",
                materialSuggestionConfidence: 0.6,
                sceneFitConfidence: 0.88,
                sceneRejectionConfidence: 0.08
            )
        )

        await waitUntil(timeout: 2) {
            session.state.phase == .readyToFinish &&
            session.state.guidance.materialConfidence?.level == .watch
        }

        XCTAssertTrue(session.state.canFinish)
        XCTAssertTrue(session.state.guidance.isReadyToFinish)
        XCTAssertEqual(session.state.guidance.overallLevel, .good)
        XCTAssertEqual(session.state.activePrompt, "Material read is settling. Keep the pile centered.")
    }

    func testLiveGuidanceBlocksStructuredWrongScene() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let timeSource = TestTimeSource(now: Date(timeIntervalSince1970: 2_000))
        let telemetryRuntime = TestTelemetryRuntime(
            snapshot: StockpileCaptureSensorSnapshot(
                sampleCount: 18,
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
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory(),
            now: { timeSource.now },
            telemetryRuntime: telemetryRuntime
        )

        session.startGuidedCapture()
        await waitUntil {
            session.state.recordingLifecycle == .recording
        }

        timeSource.advance(by: 9)
        controller.setSceneAnalysis(
            StockpileCaptureSceneAnalysis(
                capturedAt: timeSource.now,
                referenceCandidateCount: 0,
                referenceCandidateConfidence: 0,
                brightnessScore: 0.64,
                sharpnessScore: 0.71,
                sceneChangeScore: 0.18,
                structuredArtifactScore: 0.91
            )
        )

        await waitUntil(timeout: 2) {
            session.state.guidance.sceneFit?.level == .blocked
        }

        XCTAssertFalse(session.state.canFinish)
        XCTAssertEqual(session.state.phase, .capturing)
        XCTAssertEqual(
            session.state.activePrompt,
            "Wrong scene. Reframe on the pile and tagged refs."
        )
    }

    func testLiveGuidanceWarnsBeforeStructuredWrongSceneBecomesBlocked() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let timeSource = TestTimeSource(now: Date(timeIntervalSince1970: 2_500))
        let telemetryRuntime = TestTelemetryRuntime(
            snapshot: StockpileCaptureSensorSnapshot(
                sampleCount: 18,
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
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory(),
            now: { timeSource.now },
            telemetryRuntime: telemetryRuntime
        )

        session.startGuidedCapture()
        await waitUntil {
            session.state.recordingLifecycle == .recording
        }

        timeSource.advance(by: 8)
        controller.setSceneAnalysis(
            StockpileCaptureSceneAnalysis(
                capturedAt: timeSource.now,
                referenceCandidateCount: 1,
                referenceCandidateConfidence: 0.79,
                brightnessScore: 0.59,
                sharpnessScore: 0.66,
                sceneChangeScore: 0.21,
                structuredArtifactScore: 0.58
            )
        )

        await waitUntil(timeout: 2) {
            session.state.guidance.sceneFit?.level == .watch
        }

        XCTAssertFalse(session.state.canFinish)
        XCTAssertEqual(session.state.phase, .capturing)
        XCTAssertEqual(session.state.guidance.sceneFit?.level, .watch)
    }

    func testLiveGuidanceRecoversFromStructuredWrongSceneAfterPileReturnsToFrame() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let timeSource = TestTimeSource(now: Date(timeIntervalSince1970: 4_000))
        let telemetryRuntime = TestTelemetryRuntime(
            snapshot: StockpileCaptureSensorSnapshot(
                sampleCount: 20,
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
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory(),
            now: { timeSource.now },
            telemetryRuntime: telemetryRuntime
        )

        session.startGuidedCapture()
        await waitUntil {
            session.state.recordingLifecycle == .recording
        }

        timeSource.advance(by: 7)
        controller.setSceneAnalysis(
            StockpileCaptureSceneAnalysis(
                capturedAt: timeSource.now,
                referenceCandidateCount: 0,
                referenceCandidateConfidence: 0,
                brightnessScore: 0.62,
                sharpnessScore: 0.7,
                sceneChangeScore: 0.18,
                structuredArtifactScore: 0.91
            )
        )

        await waitUntil(timeout: 2) {
            session.state.guidance.sceneFit?.level == .blocked
        }

        XCTAssertEqual(
            session.state.activePrompt,
            "Wrong scene. Reframe on the pile and tagged refs."
        )

        timeSource.advance(by: 18)
        controller.setSceneAnalysis(
            StockpileCaptureSceneAnalysis(
                capturedAt: timeSource.now,
                referenceCandidateCount: 2,
                referenceCandidateConfidence: 0.88,
                brightnessScore: 0.64,
                sharpnessScore: 0.76,
                sceneChangeScore: 0.47,
                structuredArtifactScore: 0.08
            )
        )

        await waitUntil(timeout: 2) {
            session.state.phase == .readyToFinish &&
            session.state.guidance.sceneFit?.level == .good &&
            session.state.canFinish
        }

        XCTAssertEqual(session.state.completedSteps, 2)
        XCTAssertEqual(
            session.state.activePrompt,
            "Scene and references look strong. Finish when the last edge is covered."
        )
    }

    func testLiveGuidanceCarriesObservedReferenceCount() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let timeSource = TestTimeSource(now: Date(timeIntervalSince1970: 3_000))
        let telemetryRuntime = TestTelemetryRuntime(
            snapshot: StockpileCaptureSensorSnapshot(
                sampleCount: 16,
                motionSignalsIncluded: true,
                gravityVectorIncluded: true,
                headingSignalsIncluded: false,
                cameraCalibrationIncluded: true,
                motionStable: true,
                headingStable: false,
                lidarAssistAvailable: true,
                trackingState: "sensor_sampling_active"
            )
        )
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory(),
            now: { timeSource.now },
            telemetryRuntime: telemetryRuntime
        )

        session.startGuidedCapture()
        await waitUntil {
            session.state.recordingLifecycle == .recording
        }

        timeSource.advance(by: 6)
        controller.setSceneAnalysis(
            StockpileCaptureSceneAnalysis(
                capturedAt: timeSource.now,
                referenceCandidateCount: 1,
                referenceCandidateConfidence: 0.67,
                brightnessScore: 0.56,
                sharpnessScore: 0.62,
                sceneChangeScore: 0.22,
                structuredArtifactScore: 0.12
            )
        )

        await waitUntil(timeout: 2) {
            session.state.guidance.referenceVisibility.observedCount == 1
        }

        XCTAssertEqual(session.state.guidance.referenceVisibility.observedCount, 1)
        XCTAssertEqual(session.state.guidance.referenceVisibility.targetCount, 2)
    }

    func testLiveGuidancePublishesObservedReferenceMarkersAndMaterialSuggestion() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let timeSource = TestTimeSource(now: Date(timeIntervalSince1970: 5_000))
        let telemetryRuntime = TestTelemetryRuntime(
            snapshot: StockpileCaptureSensorSnapshot(
                sampleCount: 24,
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
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory(),
            now: { timeSource.now },
            telemetryRuntime: telemetryRuntime
        )

        session.startGuidedCapture()
        await waitUntil {
            session.state.recordingLifecycle == .recording
        }

        let capturedAt = timeSource.now.addingTimeInterval(9)
        timeSource.advance(by: 9)
        controller.setSceneAnalysis(
            StockpileCaptureSceneAnalysis(
                capturedAt: capturedAt,
                referenceCandidateCount: 2,
                referenceCandidateConfidence: 0.9,
                brightnessScore: 0.62,
                sharpnessScore: 0.78,
                sceneChangeScore: 0.41,
                structuredArtifactScore: 0.06
            )
        )
        controller.setSceneDiagnostics(
            StockpileCaptureSceneDiagnostics(
                capturedAt: capturedAt,
                referenceObservations: [
                    StockpileCaptureReferenceObservation(
                        id: "track-a",
                        markerID: "ref-a",
                        source: .barcode,
                        confidence: 0.94,
                        stabilityScore: 0.86,
                        framesObserved: 3,
                        region: StockpileCaptureNormalizedRegion(
                            CGRect(x: 0.1, y: 0.15, width: 0.12, height: 0.16)
                        )
                    ),
                    StockpileCaptureReferenceObservation(
                        id: "track-b",
                        markerID: "ref-b",
                        source: .ocr,
                        confidence: 0.88,
                        stabilityScore: 0.81,
                        framesObserved: 2,
                        region: StockpileCaptureNormalizedRegion(
                            CGRect(x: 0.42, y: 0.2, width: 0.11, height: 0.15)
                        )
                    )
                ],
                materialFamilySuggestion: StockpileCaptureMaterialFamilySuggestion(
                    familyCode: "aggregate_rock",
                    label: "Coarse aggregate / rock",
                    confidence: 0.76
                ),
                screenLikelihood: 0.04,
                equipmentLikelihood: 0.08,
                textLikelihood: 0.05,
                rejectionReasons: [],
                supportingLabels: ["gravel", "rock"]
            )
        )

        await waitUntil(timeout: 2) {
            session.state.observedReferenceMarkers.count == 2 &&
            session.state.materialSuggestion?.materialCode == "aggregate_rock"
        }

        XCTAssertEqual(session.state.observedReferenceMarkers.map(\.markerID), ["ref-a", "ref-b"])
        XCTAssertEqual(session.state.observedReferenceMarkers.map(\.source), [.barcode, .opticalLabel])
        XCTAssertEqual(session.state.materialSuggestion?.materialName, "Coarse aggregate / rock")
        XCTAssertEqual(session.state.activePrompt, "Tagged references ref-a and ref-b are reading cleanly. Keep them in frame while you finish the lap.")
    }

    func testRefreshPermissionStateStopsRunningSessionWhenAccessIsRevoked() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let session = StockpileCameraCaptureSessionLive(platform: platform)

        session.startCaptureSession()
        await waitUntil {
            session.state.sessionLifecycle == .running
        }

        platform.setCurrentPermission(StockpileCameraPermissionState(status: .denied, canRequestAccess: false))
        session.refreshPermissionState()

        await waitUntil {
            session.state.phase == .blocked &&
            session.state.sessionLifecycle == .permissionRequired &&
            controller.stopRunningCallCount == 1
        }

        XCTAssertEqual(session.state.activePrompt, "Turn on camera access in Settings to keep recording in app.")
        XCTAssertEqual(session.state.permission.status, .denied)
    }

    func testStartCaptureSessionSurfacesConfigurationFailure() async {
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: {
                throw TestCameraError.unavailable
            }
        )
        let session = StockpileCameraCaptureSessionLive(platform: platform)

        session.startCaptureSession()

        await waitUntil {
            session.state.phase == .failed && session.state.sessionLifecycle == .failed
        }

        XCTAssertEqual(session.state.activePrompt, "Camera session is unavailable for this test.")
        XCTAssertEqual(session.state.lastErrorDescription, "Camera session is unavailable for this test.")
    }

    func testStartGuidedCaptureSurfacesRecordingFailure() async {
        let controller = TestCameraSessionController(
            deviceLabel: "Back Wide Camera",
            recordingStartError: TestCameraError.recordingUnavailable
        )
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory()
        )

        session.startGuidedCapture()

        await waitUntil {
            session.state.phase == .failed &&
            session.state.recordingLifecycle == .failed &&
            session.state.sessionLifecycle == .running
        }

        XCTAssertEqual(session.state.activePrompt, "Camera recording is unavailable for this test.")
        XCTAssertEqual(session.state.lastErrorDescription, "Camera recording is unavailable for this test.")
        XCTAssertTrue(session.state.isPreviewAvailable)
        XCTAssertEqual(controller.startRecordingCallCount, 1)
        XCTAssertEqual(controller.stopRunningCallCount, 0)
    }

    func testStartGuidedCaptureRecoversWhenDidStartCallbackIsDelayedButRecorderIsActive() async {
        let controller = TestCameraSessionController(
            deviceLabel: "Back Wide Camera",
            automaticallySignalsRecordingStart: false
        )
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingStartupTimeout: 0.05,
            recordingsDirectory: makeTemporaryRecordingDirectory()
        )

        session.startGuidedCapture()

        await waitUntil(timeout: 1) {
            session.state.phase == .capturing &&
            session.state.recordingLifecycle == .recording &&
            session.state.sessionLifecycle == .running
        }

        XCTAssertEqual(controller.startRecordingCallCount, 1)
        XCTAssertEqual(controller.stopRecordingCallCount, 0)
        XCTAssertEqual(controller.stopRunningCallCount, 0)
        XCTAssertTrue(session.state.isPreviewAvailable)
        XCTAssertEqual(
            session.state.debugTraceSummary,
            "recording live: recorder active before didStart callback"
        )
    }

    func testStartGuidedCaptureTimesOutWhenRecordingDoesNotStart() async {
        let controller = TestCameraSessionController(
            deviceLabel: "Back Wide Camera",
            automaticallySignalsRecordingStart: false,
            marksRecordingActive: false
        )
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingStartupTimeout: 0.05,
            recordingsDirectory: makeTemporaryRecordingDirectory()
        )

        session.startGuidedCapture()

        await waitUntil(timeout: 1) {
            session.state.phase == .failed &&
            session.state.recordingLifecycle == .failed &&
            session.state.sessionLifecycle == .running
        }

        XCTAssertEqual(
            session.state.activePrompt,
            "The rear camera took too long to start recording. Retry recording and keep the phone unlocked."
        )
        XCTAssertEqual(controller.startRecordingCallCount, 1)
        XCTAssertEqual(controller.stopRecordingCallCount, 0)
        XCTAssertEqual(controller.stopRunningCallCount, 0)
        XCTAssertTrue(session.state.isPreviewAvailable)
    }

    func testTelemetryRuntimeStartsAndStopsWithCaptureSession() async {
        let controller = TestCameraSessionController(deviceLabel: "Back Wide Camera")
        let telemetryRuntime = TestTelemetryRuntime(
            snapshot: StockpileCaptureSensorSnapshot(
                sampleCount: 12,
                motionSignalsIncluded: true,
                gravityVectorIncluded: true,
                headingSignalsIncluded: true,
                cameraCalibrationIncluded: true,
                motionStable: true,
                headingStable: true,
                lidarAssistAvailable: true,
                trackingState: "sensor_sampling_active",
                sensorMetadata: StockpileCaptureSensorMetadata(
                    deviceModelIdentifier: "iPhone17,2",
                    videoWidth: 1920,
                    videoHeight: 1080,
                    videoFrameRate: 60,
                    poseSamplingHz: 15,
                    depthDataIncluded: false,
                    worldAlignment: "gravityAndHeading",
                    videoStabilizationMode: "auto"
                )
            )
        )
        let platform = TestCameraPlatform(
            currentPermission: .preview,
            controllerFactory: { controller }
        )
        let session = StockpileCameraCaptureSessionLive(
            platform: platform,
            recordingsDirectory: makeTemporaryRecordingDirectory(),
            telemetryRuntime: telemetryRuntime
        )

        session.startCaptureSession()
        await waitUntil {
            session.state.sessionLifecycle == .running
        }

        XCTAssertEqual(telemetryRuntime.startSamplingCallCount, 1)
        XCTAssertEqual(session.latestTelemetrySnapshot?.sampleCount, 12)
        XCTAssertEqual(session.state.sensorSnapshot?.trackingState, "sensor_sampling_active")

        session.stopCaptureSession()
        await waitUntil {
            session.state.sessionLifecycle == .stopped
        }

        XCTAssertEqual(telemetryRuntime.stopSamplingCallCount, 1)
    }
}

private final class TestCameraPlatform: StockpileCameraPlatform {
    private let lock = NSLock()
    private var currentPermission: StockpileCameraPermissionState
    private let requestedPermission: StockpileCameraPermissionState
    private let controllerFactory: () throws -> any StockpileCameraSessionControlling
    private var controllerCreationCount = 0

    init(
        currentPermission: StockpileCameraPermissionState,
        requestedPermission: StockpileCameraPermissionState? = nil,
        controllerFactory: @escaping () throws -> any StockpileCameraSessionControlling = { TestCameraSessionController() }
    ) {
        self.currentPermission = currentPermission
        self.requestedPermission = requestedPermission ?? currentPermission
        self.controllerFactory = controllerFactory
    }

    var makeSessionControllerCallCount: Int {
        lock.withLock {
            controllerCreationCount
        }
    }

    func setCurrentPermission(_ permission: StockpileCameraPermissionState) {
        lock.withLock {
            currentPermission = permission
        }
    }

    func currentPermissionState() -> StockpileCameraPermissionState {
        lock.withLock {
            currentPermission
        }
    }

    func requestCameraAccess() async -> StockpileCameraPermissionState {
        lock.withLock {
            currentPermission = requestedPermission
            return currentPermission
        }
    }

    func makeSessionController(
        preferredPosition: StockpileCameraLensPosition,
        lidarAssistEnabled: Bool
    ) throws -> any StockpileCameraSessionControlling {
        try lock.withLock {
            controllerCreationCount += 1
            return try controllerFactory()
        }
    }
}

private final class TestCameraSessionController: StockpileCameraSessionControlling {
    let captureSession = AVCaptureSession()
    let deviceLabel: String

    private let lock = NSLock()
    private var running = false
    private var recording = false
    private var startCount = 0
    private var stopCount = 0
    private var startRecordingCount = 0
    private var stopRecordingCount = 0
    private let recordingStartError: Error?
    private let recordingStopError: Error?
    private let automaticallySignalsRecordingStart: Bool
    private let marksRecordingActive: Bool
    private var recordingDelegate: (any StockpileCameraSessionRecordingDelegate)?
    private var currentOutputURL: URL?
    private var sceneAnalysis: StockpileCaptureSceneAnalysis?
    private var sceneDiagnostics: StockpileCaptureSceneDiagnostics?

    init(
        deviceLabel: String = "Test Camera",
        recordingStartError: Error? = nil,
        recordingStopError: Error? = nil,
        automaticallySignalsRecordingStart: Bool = true,
        marksRecordingActive: Bool = true
    ) {
        self.deviceLabel = deviceLabel
        self.recordingStartError = recordingStartError
        self.recordingStopError = recordingStopError
        self.automaticallySignalsRecordingStart = automaticallySignalsRecordingStart
        self.marksRecordingActive = marksRecordingActive
    }

    var isRunning: Bool {
        lock.withLock {
            running
        }
    }

    var isRecording: Bool {
        lock.withLock {
            recording
        }
    }

    var videoWidth: Int? { 1920 }
    var videoHeight: Int? { 1080 }
    var videoFrameRate: Double? { 60 }
    var videoStabilizationModeLabel: String? { "auto" }
    var supportsDepthDataDelivery: Bool { true }
    var latestSceneAnalysis: StockpileCaptureSceneAnalysis? {
        lock.withLock {
            sceneAnalysis
        }
    }

    var latestSceneDiagnostics: StockpileCaptureSceneDiagnostics? {
        lock.withLock {
            sceneDiagnostics
        }
    }

    var startRunningCallCount: Int {
        lock.withLock {
            startCount
        }
    }

    var stopRunningCallCount: Int {
        lock.withLock {
            stopCount
        }
    }

    var startRecordingCallCount: Int {
        lock.withLock {
            startRecordingCount
        }
    }

    var stopRecordingCallCount: Int {
        lock.withLock {
            stopRecordingCount
        }
    }

    func setSceneAnalysis(_ analysis: StockpileCaptureSceneAnalysis?) {
        lock.withLock {
            sceneAnalysis = analysis
        }
    }

    func setSceneDiagnostics(_ diagnostics: StockpileCaptureSceneDiagnostics?) {
        lock.withLock {
            sceneDiagnostics = diagnostics
        }
    }

    func startRunning() {
        lock.withLock {
            startCount += 1
            running = true
        }
    }

    func stopRunning() {
        lock.withLock {
            stopCount += 1
            running = false
        }
    }

    func startRecording(
        to outputURL: URL,
        delegate: any StockpileCameraSessionRecordingDelegate
    ) throws {
        lock.withLock {
            startRecordingCount += 1
        }

        if let recordingStartError {
            throw recordingStartError
        }

        lock.withLock {
            recording = marksRecordingActive
            currentOutputURL = outputURL
            recordingDelegate = delegate
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("stockpile-alpha".utf8).write(to: outputURL)

        if automaticallySignalsRecordingStart {
            delegate.cameraSessionController(
                self,
                didStartRecordingTo: outputURL
            )
        }
    }

    func stopRecording() {
        let payload = lock.withLock { () -> (URL?, (any StockpileCameraSessionRecordingDelegate)?, Error?) in
            stopRecordingCount += 1
            recording = false
            return (currentOutputURL, recordingDelegate, recordingStopError)
        }

        guard let outputURL = payload.0,
              let delegate = payload.1 else {
            return
        }

        delegate.cameraSessionController(
            self,
            didFinishRecordingTo: outputURL,
            error: payload.2
        )

        lock.withLock {
            currentOutputURL = nil
            recordingDelegate = nil
        }
    }
}

private enum TestCameraError: LocalizedError {
    case unavailable
    case recordingUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Camera session is unavailable for this test."
        case .recordingUnavailable:
            return "Camera recording is unavailable for this test."
        }
    }
}

private final class TestTelemetryRuntime: StockpileCaptureDeviceTelemetryRuntime {
    var latestSnapshot: StockpileCaptureSensorSnapshot?
    var onSnapshotUpdated: (@Sendable (StockpileCaptureSensorSnapshot) -> Void)?

    private(set) var startSamplingCallCount = 0
    private(set) var stopSamplingCallCount = 0

    init(snapshot: StockpileCaptureSensorSnapshot? = nil) {
        self.latestSnapshot = snapshot
    }

    func startSampling(configuration: StockpileCaptureDeviceTelemetryConfiguration) {
        startSamplingCallCount += 1
        if let latestSnapshot {
            onSnapshotUpdated?(latestSnapshot)
        }
    }

    func stopSampling() {
        stopSamplingCallCount += 1
    }
}

private final class TestTimeSource: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date) {
        self.current = now
    }

    var now: Date {
        lock.withLock {
            current
        }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            current = current.addingTimeInterval(interval)
        }
    }
}

private func makeTemporaryRecordingDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "StockpileCameraCaptureTests-\(UUID().uuidString)",
        isDirectory: true
    )
}

private extension XCTestCase {
    func waitUntil(
        timeout: TimeInterval = 1,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if condition() {
                return
            }

            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Condition was not met before timeout.", file: file, line: line)
    }
}

private extension NSLock {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}
