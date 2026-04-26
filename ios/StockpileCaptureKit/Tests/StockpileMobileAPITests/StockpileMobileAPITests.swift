import XCTest
@testable import StockpileMobileAPI

final class StockpileMobileAPITests: XCTestCase {
    func testReferenceMarkerSnapshotBuilderMergesAndSortsObservedMarkers() {
        let snapshots = StockpileReferenceMarkerSnapshotBuilder.makeSnapshots(
            from: [
                StockpileObservedReferenceMarker(
                    markerID: "  tag-02  ",
                    visibleCount: 1,
                    confidence: 0.42
                ),
                StockpileObservedReferenceMarker(
                    markerID: "tag-01",
                    visibleCount: 2,
                    confidence: 0.86
                ),
                StockpileObservedReferenceMarker(
                    markerID: "tag-02",
                    visibleCount: 3,
                    confidence: 0.78
                ),
                StockpileObservedReferenceMarker(
                    markerID: "tag-03",
                    visibleCount: 0,
                    confidence: 0,
                    qualityHint: .missing
                ),
                StockpileObservedReferenceMarker(
                    markerID: "   ",
                    visibleCount: 4,
                    confidence: 1.0
                )
            ]
        )

        XCTAssertEqual(snapshots.map(\.markerID), ["tag-02", "tag-01", "tag-03"])
        XCTAssertEqual(snapshots[0].visibleCount, 3)
        XCTAssertEqual(snapshots[0].confidence, 0.78, accuracy: 0.0001)
        XCTAssertEqual(snapshots[0].quality, .confirmed)
        XCTAssertEqual(snapshots[1].quality, .confirmed)
        XCTAssertEqual(snapshots[2].quality, .missing)
    }

    func testReferenceMarkerSnapshotBuilderPreservesExplicitQualityHints() {
        let snapshots = StockpileReferenceMarkerSnapshotBuilder.makeSnapshots(
            from: [
                StockpileObservedReferenceMarker(
                    markerID: "tag-weak",
                    visibleCount: 1,
                    confidence: 0.91,
                    qualityHint: .weak
                ),
                StockpileObservedReferenceMarker(
                    markerID: "tag-confirmed",
                    visibleCount: 1,
                    confidence: 0.45,
                    qualityHint: .confirmed
                )
            ]
        )

        XCTAssertEqual(
            snapshots,
            [
                StockpileReferenceMarkerSnapshotPayload(
                    markerID: "tag-confirmed",
                    visibleCount: 1,
                    confidence: 0.45,
                    quality: .confirmed
                ),
                StockpileReferenceMarkerSnapshotPayload(
                    markerID: "tag-weak",
                    visibleCount: 1,
                    confidence: 0.91,
                    quality: .weak
                )
            ]
        )
    }

    func testReferenceObservationPayloadNormalizesMarkerObservationDetails() throws {
        let payload = StockpileReferenceObservationPayload(
            referenceID: "QPMC-02",
            family: "   ",
            frameTimeSec: 1.75,
            poseSampleIndex: -3,
            hamming: -1,
            confidence: 1.4,
            state: .weak
        )

        XCTAssertEqual(payload.family, "unspecified")
        XCTAssertEqual(payload.poseSampleIndex, 0)
        XCTAssertEqual(payload.hamming, 0)
        XCTAssertEqual(try XCTUnwrap(payload.confidence), 1, accuracy: 0.0001)

        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["referenceId"] as? String, "QPMC-02")
        XCTAssertEqual(json["family"] as? String, "unspecified")
        XCTAssertEqual(json["poseSampleIndex"] as? Int, 0)
        XCTAssertEqual(json["hamming"] as? Int, 0)
        XCTAssertEqual(try XCTUnwrap(json["confidence"] as? Double), 1, accuracy: 0.0001)
        XCTAssertEqual(json["state"] as? String, "weak")
    }

    func testCaptureSessionCreateRequestEncodesServerFieldNames() throws {
        let request = StockpileCaptureSessionCreateRequest(
            siteID: "qpmc-north-yard",
            pileName: "North Yard 03",
            materialCode: "backfill-0-75",
            densityKgPerM3: 2100,
            referenceCountGoal: 3,
            clientBuild: "ios-alpha",
            taggedReferenceStrategy: makeTaggedReferenceStrategy(),
            captureMetadata: makeCaptureMetadata(source: .liveRecordedVideo),
            qualityInput: makeQualityInput(referenceVisibilityScore: 0.91)
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["siteId"] as? String, "qpmc-north-yard")
        XCTAssertEqual(json["pileName"] as? String, "North Yard 03")
        XCTAssertEqual(json["materialCode"] as? String, "backfill-0-75")
        let taggedReferenceStrategy = try XCTUnwrap(json["taggedReferenceStrategy"] as? [String: Any])
        XCTAssertEqual(taggedReferenceStrategy["mode"] as? String, "concurrent_visibility")
        XCTAssertEqual(taggedReferenceStrategy["minimumVisibleReferenceCount"] as? Int, 2)
        let qualityInput = try XCTUnwrap(json["qualityInput"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap(qualityInput["referenceVisibilityScore"] as? Double),
            0.91,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(qualityInput["toeCoverageScore"] as? Double),
            0.88,
            accuracy: 0.0001
        )
        XCTAssertEqual(qualityInput["estimatedConcurrentReferenceCount"] as? Int, 3)
        let mobileFirstCapture = try XCTUnwrap(qualityInput["mobileFirstCapture"] as? [String: Any])
        XCTAssertEqual(mobileFirstCapture["stage"] as? String, "walking_perimeter")
        XCTAssertEqual(
            try XCTUnwrap(mobileFirstCapture["pileSegmentationScore"] as? Double),
            0.74,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(mobileFirstCapture["toeSegmentationScore"] as? Double),
            0.69,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(mobileFirstCapture["segmentationConfidenceScore"] as? Double),
            0.715,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(mobileFirstCapture["quickVolumeM3"] as? Double),
            19.64,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(mobileFirstCapture["quickConfidenceScore"] as? Double),
            0.68,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(mobileFirstCapture["quickCameraPathDistanceM"] as? Double),
            6.4,
            accuracy: 0.0001
        )
        let referenceMarkerSnapshots = try XCTUnwrap(
            mobileFirstCapture["referenceMarkerSnapshots"] as? [[String: Any]]
        )
        XCTAssertEqual(referenceMarkerSnapshots.count, 1)
        XCTAssertEqual(referenceMarkerSnapshots[0]["markerId"] as? String, "tag-01")
        XCTAssertEqual(referenceMarkerSnapshots[0]["quality"] as? String, "confirmed")
        let captureMetadata = try XCTUnwrap(json["captureMetadata"] as? [String: Any])
        XCTAssertEqual(captureMetadata["source"] as? String, "live_recorded_video")
        XCTAssertEqual(captureMetadata["mode"] as? String, "guided_walkaround")
        let sensorMetadata = try XCTUnwrap(captureMetadata["sensorMetadata"] as? [String: Any])
        XCTAssertEqual(sensorMetadata["deviceModelIdentifier"] as? String, "iPhone17,2")
        XCTAssertEqual(try XCTUnwrap(sensorMetadata["poseSamplingHz"] as? Double), 15, accuracy: 0.0001)
        XCTAssertNil(json["siteID"])
    }

    func testUploadRequestEncodesChecksumUsingLiveAPIKey() throws {
        let request = StockpileUploadRequest(
            sessionID: "session_123",
            fileName: "north-yard-03.mov",
            byteCount: 287_548_015,
            contentType: "video/quicktime",
            checksumSHA256: "abc123",
            taggedReferenceStrategy: makeTaggedReferenceStrategy(),
            captureMetadata: makeCaptureMetadata(source: .importedVideo),
            qualityInput: makeQualityInput(referenceVisibilityScore: nil),
            poseSamples: makePoseSamples(),
            referenceObservations: makeReferenceObservations(),
            referenceEvidenceJPEGFrames: makeReferenceEvidenceJPEGFrames()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter().string(from: date))
        }

        let data = try encoder.encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["sessionId"] as? String, "session_123")
        XCTAssertEqual(json["checksumSha256"] as? String, "abc123")
        let captureMetadata = try XCTUnwrap(json["captureMetadata"] as? [String: Any])
        XCTAssertEqual(captureMetadata["source"] as? String, "imported_video")
        let qualityInput = try XCTUnwrap(json["qualityInput"] as? [String: Any])
        let deviceSensors = try XCTUnwrap(qualityInput["deviceSensors"] as? [String: Any])
        XCTAssertEqual(deviceSensors["motionSignalsIncluded"] as? Bool, false)
        XCTAssertEqual(deviceSensors["cameraCalibrationIncluded"] as? Bool, false)
        let mobileFirstCapture = try XCTUnwrap(qualityInput["mobileFirstCapture"] as? [String: Any])
        let telemetry = try XCTUnwrap(mobileFirstCapture["devicePoseTelemetry"] as? [String: Any])
        XCTAssertEqual(telemetry["lidarAssistAvailable"] as? Bool, true)
        XCTAssertEqual(telemetry["headingStable"] as? Bool, true)
        XCTAssertEqual(mobileFirstCapture["quickGeometryPointCount"] as? Int, 155_551)
        XCTAssertEqual(
            try XCTUnwrap(mobileFirstCapture["quickCameraPathDistanceM"] as? Double),
            6.4,
            accuracy: 0.0001
        )
        let poseSamples = try XCTUnwrap(json["poseSamples"] as? [[String: Any]])
        XCTAssertEqual(poseSamples.count, 1)
        XCTAssertEqual(poseSamples[0]["sampleIndex"] as? Int, 7)
        XCTAssertEqual(
            try XCTUnwrap(poseSamples[0]["timeOffsetSec"] as? Double),
            2.5,
            accuracy: 0.0001
        )
        let yawPitchRollDeg = try XCTUnwrap(poseSamples[0]["yawPitchRollDeg"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(yawPitchRollDeg["x"] as? Double), 90, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(yawPitchRollDeg["y"] as? Double), -4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(yawPitchRollDeg["z"] as? Double), 1, accuracy: 0.0001)
        let referenceObservations = try XCTUnwrap(json["referenceObservations"] as? [[String: Any]])
        XCTAssertEqual(referenceObservations.count, 1)
        XCTAssertEqual(referenceObservations[0]["referenceId"] as? String, "QPMC-01")
        XCTAssertEqual(referenceObservations[0]["family"] as? String, "apriltag")
        XCTAssertEqual(referenceObservations[0]["state"] as? String, "confirmed")
        XCTAssertEqual(
            try XCTUnwrap(referenceObservations[0]["pixelAreaPx"] as? Double),
            1800,
            accuracy: 0.0001
        )
        let referenceEvidenceJPEGFrames = try XCTUnwrap(
            json["referenceEvidenceJPEGFrames"] as? [[String: Any]]
        )
        XCTAssertEqual(referenceEvidenceJPEGFrames.count, 1)
        XCTAssertEqual(referenceEvidenceJPEGFrames[0]["frameId"] as? String, "frame_0010")
        XCTAssertEqual(
            try XCTUnwrap(referenceEvidenceJPEGFrames[0]["timeOffsetSec"] as? Double),
            2.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(referenceEvidenceJPEGFrames[0]["poseSampleIndex"] as? Int, 7)
        XCTAssertEqual(referenceEvidenceJPEGFrames[0]["widthPx"] as? Int, 1440)
        XCTAssertEqual(referenceEvidenceJPEGFrames[0]["heightPx"] as? Int, 810)
        XCTAssertEqual(referenceEvidenceJPEGFrames[0]["jpegBase64"] as? String, "jpeg-frame-0010")
        XCTAssertEqual(referenceEvidenceJPEGFrames[0]["capturedAt"] as? String, "2024-04-21T11:10:45Z")
        XCTAssertNil(json["checksumSHA256"])
    }

    func testReferenceEvidenceJPEGFramePayloadCodableRoundTripPreservesBackendFieldNames() throws {
        let payload = StockpileReferenceEvidenceJPEGFramePayload(
            frameID: "frame_0010",
            timeOffsetSec: 2.5,
            poseSampleIndex: 7,
            capturedAt: Date(timeIntervalSince1970: 1_713_697_845),
            widthPx: 1440,
            heightPx: 810,
            jpegBase64: "jpeg-frame-0010"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter().string(from: date))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: rawValue) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported ISO-8601 date string: \(rawValue)"
            )
        }

        let data = try encoder.encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["frameId"] as? String, "frame_0010")
        XCTAssertEqual(try XCTUnwrap(json["timeOffsetSec"] as? Double), 2.5, accuracy: 0.0001)
        XCTAssertEqual(json["poseSampleIndex"] as? Int, 7)
        XCTAssertEqual(json["widthPx"] as? Int, 1440)
        XCTAssertEqual(json["heightPx"] as? Int, 810)
        XCTAssertEqual(json["jpegBase64"] as? String, "jpeg-frame-0010")

        let decoded = try decoder.decode(StockpileReferenceEvidenceJPEGFramePayload.self, from: data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.frameID, "frame_0010")
        XCTAssertEqual(decoded.poseSampleIndex, 7)
        XCTAssertEqual(decoded.jpegBase64, "jpeg-frame-0010")
    }

    func testUploadRequestDecodesPoseSamplesAndReferenceObservationsUsingBackendFieldNames() throws {
        let data = """
        {
          "sessionId": "session_123",
          "fileName": "north-yard-03.mov",
          "byteCount": 287548015,
          "contentType": "video/quicktime",
          "checksumSha256": "abc123",
          "taggedReferenceStrategy": {
            "mode": "concurrent_visibility",
            "referenceCountGoal": 3,
            "minimumVisibleReferenceCount": 2,
            "preferredVisibleReferenceCount": 3
          },
          "captureMetadata": {
            "source": "live_recorded_video",
            "mode": "guided_walkaround",
            "timeZoneIdentifier": "Asia/Karachi"
          },
          "qualityInput": {
            "deviceSensors": {
              "motionSignalsIncluded": false,
              "gravityVectorIncluded": false,
              "headingSignalsIncluded": false,
              "cameraCalibrationIncluded": false
            }
          },
          "poseSamples": [
            {
              "sampleIndex": 7,
              "timeOffsetSec": 2.5,
              "positionM": { "x": 3.0, "y": 4.0, "z": 5.0 },
              "yawPitchRollDeg": { "x": 90.0, "y": -4.0, "z": 1.0 },
              "horizontalAccuracyM": 0.4,
              "verticalAccuracyM": 0.8,
              "headingDegrees": 12.0,
              "trackingState": "running"
            }
          ],
          "referenceObservations": [
            {
              "referenceId": "QPMC-01",
              "family": "apriltag",
              "frameTimeSec": 2.5,
              "poseSampleIndex": 7,
              "decisionMargin": 92.5,
              "hamming": 0,
              "edgeLengthPx": 144.0,
              "frameId": "frame_0010",
              "pixelAreaPx": 1800.0,
              "confidence": 0.92,
              "estimatedDistanceM": 4.2,
              "state": "confirmed"
            }
          ],
          "referenceEvidenceJPEGFrames": [
            {
              "frameId": "frame_0010",
              "timeOffsetSec": 2.5,
              "poseSampleIndex": 7,
              "capturedAt": "2024-04-21T11:10:45Z",
              "widthPx": 1440,
              "heightPx": 810,
              "jpegBase64": "jpeg-frame-0010"
            }
          ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: rawValue) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported ISO-8601 date string: \(rawValue)"
            )
        }

        let request = try decoder.decode(StockpileUploadRequest.self, from: data)

        XCTAssertEqual(request.poseSamples.count, 1)
        XCTAssertEqual(request.poseSamples[0].sampleIndex, 7)
        XCTAssertEqual(request.poseSamples[0].timeOffsetSec, 2.5, accuracy: 0.0001)
        XCTAssertEqual(
            request.poseSamples[0].positionM,
            StockpileVector3Payload(x: 3, y: 4, z: 5)
        )
        XCTAssertEqual(
            request.poseSamples[0].yawPitchRollDeg,
            StockpileVector3Payload(x: 90, y: -4, z: 1)
        )
        XCTAssertEqual(request.poseSamples[0].trackingState, "running")
        XCTAssertEqual(request.referenceObservations.count, 1)
        XCTAssertEqual(request.referenceObservations[0].referenceID, "QPMC-01")
        XCTAssertEqual(request.referenceObservations[0].family, "apriltag")
        XCTAssertEqual(request.referenceObservations[0].poseSampleIndex, 7)
        XCTAssertEqual(request.referenceObservations[0].frameID, "frame_0010")
        XCTAssertEqual(request.referenceObservations[0].state, .confirmed)
        XCTAssertEqual(request.referenceEvidenceJPEGFrames.count, 1)
        XCTAssertEqual(request.referenceEvidenceJPEGFrames[0].frameID, "frame_0010")
        XCTAssertEqual(request.referenceEvidenceJPEGFrames[0].poseSampleIndex, 7)
        XCTAssertEqual(request.referenceEvidenceJPEGFrames[0].widthPx, 1440)
        XCTAssertEqual(request.referenceEvidenceJPEGFrames[0].heightPx, 810)
        XCTAssertEqual(request.referenceEvidenceJPEGFrames[0].jpegBase64, "jpeg-frame-0010")
        XCTAssertEqual(
            request.referenceEvidenceJPEGFrames[0].capturedAt,
            Date(timeIntervalSince1970: 1_713_697_845)
        )
    }

    func testMobileFirstCapturePayloadDecodesQuickCameraPathDistanceField() throws {
        let data = """
        {
          "stage": "walking_perimeter",
          "toeCoverageScore": 0.88,
          "pileSegmentationScore": 0.74,
          "toeSegmentationScore": 0.69,
          "segmentationConfidenceScore": 0.715,
          "quickVolumeM3": 19.64,
          "quickFootprintAreaM2": 11.8,
          "quickPeakHeightM": 2.3,
          "quickConfidenceScore": 0.68,
          "quickGeometryPointCount": 155551,
          "quickCameraPathDistanceM": 6.4
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(StockpileMobileFirstCapturePayload.self, from: data)

        XCTAssertEqual(payload.stage, .walkingPerimeter)
        XCTAssertEqual(try XCTUnwrap(payload.pileSegmentationScore), 0.74, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(payload.toeSegmentationScore), 0.69, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(payload.segmentationConfidenceScore), 0.715, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(payload.quickVolumeM3), 19.64, accuracy: 0.0001)
        XCTAssertEqual(payload.quickGeometryPointCount, 155_551)
        XCTAssertEqual(try XCTUnwrap(payload.quickCameraPathDistanceM), 6.4, accuracy: 0.0001)
    }

    func testMobileFirstCapturePayloadRoundTripsOnDeviceVision() throws {
        let payload = StockpileMobileFirstCapturePayload(
            stage: .walkingPerimeter,
            onDeviceVision: StockpileOnDeviceVisionPayload(
                source: "vision_foreground_instance_mask",
                usesMachineLearning: true,
                pileSegmentationScore: 0.83,
                toeSegmentationScore: 0.77,
                segmentationConfidenceScore: 0.8,
                foregroundCoverageRatio: 0.41,
                lowerFrameOccupancyRatio: 0.58,
                materialFamilyCode: "aggregate_rock",
                materialFamilyLabel: "Coarse aggregate / rock",
                materialConfidenceScore: 0.69,
                guidanceHint: "Keep the segmented pile toe in the lower third."
            )
        )

        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let onDeviceVision = try XCTUnwrap(json["onDeviceVision"] as? [String: Any])

        XCTAssertEqual(onDeviceVision["source"] as? String, "vision_foreground_instance_mask")
        XCTAssertEqual(onDeviceVision["usesMachineLearning"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(onDeviceVision["pileSegmentationScore"] as? Double), 0.83, accuracy: 0.0001)
        XCTAssertEqual(onDeviceVision["materialFamilyCode"] as? String, "aggregate_rock")

        let decoded = try JSONDecoder().decode(StockpileMobileFirstCapturePayload.self, from: data)
        XCTAssertEqual(decoded.onDeviceVision?.source, "vision_foreground_instance_mask")
        XCTAssertEqual(decoded.onDeviceVision?.usesMachineLearning, true)
        XCTAssertEqual(decoded.onDeviceVision?.materialFamilyLabel, "Coarse aggregate / rock")
    }

    func testUploadAuthorizationDecodesCamelCaseResponseFields() throws {
        let data = """
        {
          "uploadId": "upload_123",
          "sessionId": "session_456",
          "jobId": "job_789",
          "uploadUrl": "https://uploads.example.com/upload_123",
          "httpMethod": "PUT",
          "headers": {
            "Content-Type": "video/quicktime"
          },
          "expiresAt": "2024-04-21T17:10:45Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let authorization = try decoder.decode(
            StockpileUploadAuthorization.self,
            from: data
        )

        XCTAssertEqual(authorization.uploadID, "upload_123")
        XCTAssertEqual(authorization.sessionID, "session_456")
        XCTAssertEqual(authorization.jobID, "job_789")
        XCTAssertNil(authorization.runID)
        XCTAssertEqual(
            authorization.uploadURL.absoluteString,
            "https://uploads.example.com/upload_123"
        )
        XCTAssertEqual(authorization.headers["Content-Type"], "video/quicktime")
    }

    func testResultPayloadDecodesReviewOnlyOutcomeAndMeasurements() throws {
        let data = """
        {
          "runId": "run_456",
          "pileName": "North Yard 03",
          "outcome": "review_only",
          "confidence": {
            "score": 58,
            "label": "Moderate",
            "summary": "Benchmark cross-check still needed."
          },
          "measurement": {
            "volumeM3": 2528.43,
            "weightTonnes": 5309.7,
            "densityKgPerM3": 2100
          },
          "warnings": ["Toe coverage is partial on the north edge."],
          "blockers": ["Projection and camera-height checks are not fully aligned."],
          "recommendedAction": "Review against the latest site benchmark before treating as final.",
          "siteId": "qpmc-north-yard",
          "sessionId": "session_123",
          "jobId": "job_789"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(StockpileResultPayload.self, from: data)

        XCTAssertEqual(result.runID, "run_456")
        XCTAssertEqual(result.outcome, .reviewOnly)
        XCTAssertEqual(
            try XCTUnwrap(result.measurement).volumeM3,
            2528.43,
            accuracy: 0.001
        )
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.blockers.count, 1)
        XCTAssertEqual(result.siteID, "qpmc-north-yard")
        XCTAssertEqual(result.sessionID, "session_123")
        XCTAssertEqual(result.jobID, "job_789")
    }

    func testResultPayloadPreservesProvisionalMeasurementFields() throws {
        let data = """
        {
          "runId": "run_789",
          "pileName": "North Yard 11",
          "outcome": "verified",
          "confidence": {
            "score": 90,
            "label": "High",
            "summary": "The run is ready for reporting."
          },
          "measurement": {
            "volumeM3": 1988.5,
            "weightTonnes": 4175.85,
            "densityKgPerM3": 2100
          },
          "warnings": [],
          "blockers": [],
          "recommendedAction": "Share the verified report.",
          "provisionalMeasurement": {
            "status": "ready",
            "basis": "tagged_reference_and_toe_coverage",
            "volumeM3": 1990.25,
            "weightTonnes": 4179.53,
            "confidenceScore": 87,
            "reason": "Enough signal was available for a provisional estimate."
          }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(StockpileResultPayload.self, from: data)

        XCTAssertEqual(result.provisionalMeasurement?.status, "ready")
        XCTAssertEqual(
            result.provisionalMeasurement?.basis,
            "tagged_reference_and_toe_coverage"
        )
        XCTAssertEqual(try XCTUnwrap(result.provisionalMeasurement?.volumeM3), 1990.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.provisionalMeasurement?.weightTonnes), 4179.53, accuracy: 0.0001)
        XCTAssertEqual(result.provisionalMeasurement?.confidenceScore, 87)
        XCTAssertEqual(
            result.provisionalMeasurement?.reason,
            "Enough signal was available for a provisional estimate."
        )
    }

    func testResultPayloadDecodesReconstructionPreview() throws {
        let data = """
        {
          "runId": "run_mesh_123",
          "pileName": "North Yard 03",
          "outcome": "review_only",
          "confidence": {
            "score": 58,
            "label": "Moderate",
            "summary": "Benchmark cross-check still needed."
          },
          "measurement": {
            "volumeM3": 2528.43,
            "weightTonnes": 5309.7,
            "densityKgPerM3": 2100
          },
          "warnings": [],
          "blockers": [],
          "recommendedAction": "Review before release.",
          "reconstruction": {
            "summary": "Preview mesh from 320 reconstructed pile points.",
            "footprintAreaM2": 843.2,
            "peakHeightM": 5.3,
            "defaultMode": "toe",
            "vertices": [
              { "x": 0.0, "y": 0.0, "z": 0.0 },
              { "x": 1.0, "y": 0.0, "z": 0.5 },
              { "x": 0.0, "y": 1.0, "z": 0.4 }
            ],
            "triangles": [
              { "a": 0, "b": 1, "c": 2 }
            ],
            "pointCloud": [
              { "x": 0.5, "y": 0.4, "z": 0.2 }
            ],
            "toeMarkers": [
              { "x": 1.0, "y": 1.0, "z": 0.1 }
            ],
            "surfaceRiskMarkers": [
              { "x": 0.2, "y": 0.2, "z": 0.9 }
            ]
          }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(StockpileResultPayload.self, from: data)

        XCTAssertEqual(result.reconstruction?.defaultMode, "toe")
        XCTAssertEqual(result.reconstruction?.vertices.count, 3)
        XCTAssertEqual(result.reconstruction?.triangles.count, 1)
        XCTAssertEqual(result.reconstruction?.toeMarkers.count, 1)
    }

    func testResultPayloadDecodesReferenceObservationSummary() throws {
        let data = """
        {
          "runId": "run_refs_123",
          "pileName": "North Yard 03",
          "outcome": "review_only",
          "confidence": {
            "score": 63,
            "label": "Moderate",
            "summary": "Reference coverage was usable, but still needs review."
          },
          "measurement": {
            "volumeM3": 2528.43,
            "weightTonnes": 5309.7,
            "densityKgPerM3": 2100
          },
          "warnings": [],
          "blockers": [],
          "recommendedAction": "Review the reference diagnostics before reporting.",
          "referenceDiagnostics": {
            "targetCount": 3,
            "minimumVisibleTogether": 2,
            "preferredVisibleCount": 3,
            "framesMeetingVisibilityGoal": 18,
            "framesChecked": 24,
            "calibrationBasis": "tagged_references",
            "calibrationStatus": "needs_review",
            "referenceStrategy": "tagged_references",
            "referencesUsed": 2,
            "observationSummary": {
              "observedReferenceCount": 3,
              "framesWithObservations": 21,
              "maxVisibleTogether": 2,
              "usedForCalibrationCount": 2
            }
          }
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(StockpileResultPayload.self, from: data)

        XCTAssertEqual(result.referenceDiagnostics?.referenceStrategy, "tagged_references")
        XCTAssertEqual(result.referenceDiagnostics?.referencesUsed, 2)
        XCTAssertEqual(result.referenceDiagnostics?.observationSummary?.observedReferenceCount, 3)
        XCTAssertEqual(result.referenceDiagnostics?.observationSummary?.framesWithObservations, 21)
        XCTAssertEqual(result.referenceDiagnostics?.observationSummary?.maxVisibleTogether, 2)
        XCTAssertEqual(result.referenceDiagnostics?.observationSummary?.usedForCalibrationCount, 2)
    }

    func testResultPayloadAcceptsFutureMaterialSuggestionDataWithoutBreakingKnownFields() throws {
        let data = """
        {
          "runId": "run_material_123",
          "pileName": "North Yard 03",
          "outcome": "review_only",
          "confidence": {
            "score": 71,
            "label": "Moderate",
            "summary": "Processing completed with a material recommendation."
          },
          "measurement": {
            "volumeM3": 2420.5,
            "weightTonnes": 5083.05,
            "densityKgPerM3": 2100
          },
          "warnings": [],
          "blockers": [],
          "recommendedAction": "Confirm the suggested material before treating the weight as final.",
          "materialSuggestion": {
            "materialCode": "backfill-0-75",
            "materialName": "Backfill 0-75 mm",
            "densityKgPerM3": 2100
          }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let result = try decoder.decode(StockpileResultPayload.self, from: data)

        XCTAssertEqual(result.runID, "run_material_123")
        XCTAssertEqual(result.pileName, "North Yard 03")
        XCTAssertEqual(result.measurement?.densityKgPerM3, 2100)
        XCTAssertEqual(
            result.recommendedAction,
            "Confirm the suggested material before treating the weight as final."
        )

        let roundTripData = try JSONEncoder().encode(result)
        let roundTripJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: roundTripData) as? [String: Any])
        if let materialSuggestion = roundTripJSON["materialSuggestion"] as? [String: Any] {
            XCTAssertEqual(materialSuggestion["materialCode"] as? String, "backfill-0-75")
            XCTAssertEqual(materialSuggestion["materialName"] as? String, "Backfill 0-75 mm")
            XCTAssertEqual(materialSuggestion["densityKgPerM3"] as? Int, 2100)
        }
    }

    func testProcessingJobStatusPreservesProvisionalMeasurementFields() throws {
        let formatter = ISO8601DateFormatter()
        let expectedUpdatedAt = try XCTUnwrap(formatter.date(from: "2026-04-22T09:35:00Z"))
        let data = """
        {
          "jobId": "job_789",
          "runId": "run_789",
          "phase": "upload_received",
          "progress": 0.4,
          "headline": "Upload received",
          "detail": "Processing is warming up.",
          "provisionalMeasurement": {
            "status": "review",
            "basis": "partial_reference_visibility",
            "volumeM3": 1642.1,
            "weightTonnes": 3448.41,
            "confidenceScore": 61,
            "reason": "The estimate is usable but still needs operator review.",
            "quickVolumeM3": 1588.0,
            "quickFootprintAreaM2": 742.8,
            "quickPeakHeightM": 4.1,
            "quickConfidenceScore": 0.61,
            "quickGeometryPointCount": 155551,
            "quickCameraPathDistanceM": 6.4,
            "updatedAt": "2026-04-22T09:35:00Z"
          },
          "updatedAt": "2026-04-22T09:35:01Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(StockpileProcessingJobStatus.self, from: data)

        XCTAssertEqual(status.phase, .uploadReceived)
        XCTAssertEqual(status.provisionalMeasurement?.status, "review")
        XCTAssertEqual(
            status.provisionalMeasurement?.basis,
            "partial_reference_visibility"
        )
        XCTAssertEqual(try XCTUnwrap(status.provisionalMeasurement?.volumeM3), 1642.1, accuracy: 0.0001)
        XCTAssertEqual(status.provisionalMeasurement?.confidenceScore, 61)
        XCTAssertEqual(
            status.provisionalMeasurement?.reason,
            "The estimate is usable but still needs operator review."
        )
        XCTAssertEqual(
            try XCTUnwrap(status.provisionalMeasurement?.quickVolumeM3),
            1588.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(status.provisionalMeasurement?.quickFootprintAreaM2),
            742.8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(status.provisionalMeasurement?.quickConfidenceScore),
            0.61,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(status.provisionalMeasurement?.quickCameraPathDistanceM),
            6.4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(status.provisionalMeasurement?.updatedAt).timeIntervalSince1970,
            expectedUpdatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testProvisionalMeasurementPayloadCodableRoundTripPreservesOptionalFields() throws {
        let payload = StockpileProvisionalMeasurementPayload(
            status: "retake",
            basis: nil,
            volumeM3: nil,
            weightTonnes: nil,
            confidenceScore: 24,
            reason: "Too little tagged-reference visibility for a field-trustworthy estimate.",
            quickVolumeM3: 1588.0,
            quickFootprintAreaM2: 742.8,
            quickPeakHeightM: 4.1,
            quickConfidenceScore: 0.61,
            quickGeometryPointCount: 155_551,
            quickCameraPathDistanceM: 6.4,
            updatedAt: Date(timeIntervalSince1970: 1_745_315_900)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(StockpileProvisionalMeasurementPayload.self, from: data)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.status, "retake")
        XCTAssertNil(decoded.basis)
        XCTAssertNil(decoded.volumeM3)
        XCTAssertNil(decoded.weightTonnes)
        XCTAssertEqual(decoded.confidenceScore, 24)
        XCTAssertEqual(try XCTUnwrap(decoded.quickVolumeM3), 1588.0, accuracy: 0.0001)
        XCTAssertEqual(decoded.quickGeometryPointCount, 155_551)
        XCTAssertEqual(try XCTUnwrap(decoded.quickCameraPathDistanceM), 6.4, accuracy: 0.0001)
        XCTAssertEqual(
            decoded.reason,
            "Too little tagged-reference visibility for a field-trustworthy estimate."
        )
    }

    func testEnvironmentConfigurationDefaultsStayOperationalAndAvoidDuplicateMobilePrefix() {
        let configuration = StockpileLiveMobileAPIConfiguration.environment(
            environment: [
                "STOCKPILE_MOBILE_API_BASE_URL": "https://example.com/stockpile/api/mobile"
            ]
        )

        XCTAssertEqual(
            configuration.baseURL.absoluteString,
            "https://example.com/stockpile/api/mobile"
        )
        XCTAssertEqual(configuration.pathPrefix, "")
        XCTAssertTrue(configuration.pathPrefixComponents.isEmpty)
        XCTAssertEqual(configuration.timeoutInterval, 30, accuracy: 0.001)
    }
}

private func makeTaggedReferenceStrategy() -> StockpileTaggedReferenceStrategyPayload {
    StockpileTaggedReferenceStrategyPayload(
        mode: .concurrentVisibility,
        referenceCountGoal: 3,
        minimumVisibleReferenceCount: 2,
        preferredVisibleReferenceCount: 3
    )
}

private func makeCaptureMetadata(
    source: StockpileCaptureSourcePayload
) -> StockpileCaptureMetadataPayload {
    StockpileCaptureMetadataPayload(
        source: source,
        mode: .guidedWalkaround,
        startedAt: nil,
        completedAt: nil,
        timeZoneIdentifier: "Asia/Karachi",
        activeDeviceName: "Back Camera",
        capturePhase: "completed",
        sessionLifecycle: "running",
        recordingLifecycle: "finished",
        sensorMetadata: StockpileCaptureSensorMetadataPayload(
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
}

private func makeQualityInput(
    referenceVisibilityScore: Double?
) -> StockpileCaptureQualityInputPayload {
    StockpileCaptureQualityInputPayload(
        referenceVisibilityScore: referenceVisibilityScore,
        coverageScore: 0.84,
        motionStabilityScore: 0.79,
        overallGuidanceScore: 0.85,
        toeCoverageScore: 0.88,
        estimatedConcurrentReferenceCount: 3,
        deviceSensors: .reserved,
        mobileFirstCapture: StockpileMobileFirstCapturePayload(
            stage: .walkingPerimeter,
            referenceMarkerSnapshots: [
                StockpileReferenceMarkerSnapshotPayload(
                    markerID: "tag-01",
                    visibleCount: 4,
                    confidence: 0.93,
                    quality: .confirmed
                )
            ],
            devicePoseTelemetry: StockpileDevicePoseTelemetryPayload(
                sampleCount: nil,
                motionStable: true,
                headingStable: true,
                lidarAssistAvailable: true,
                trackingState: "running"
            ),
            toeCoverageScore: 0.88,
            pileSegmentationScore: 0.74,
            toeSegmentationScore: 0.69,
            segmentationConfidenceScore: 0.715,
            estimatedConcurrentReferenceCount: 3,
            quickVolumeM3: 19.64,
            quickFootprintAreaM2: 11.8,
            quickPeakHeightM: 2.3,
            quickConfidenceScore: 0.68,
            quickGeometryPointCount: 155_551,
            quickCameraPathDistanceM: 6.4
        )
    )
}

private func makePoseSamples() -> [StockpileDevicePoseSamplePayload] {
    [
        StockpileDevicePoseSamplePayload(
            sampleIndex: 7,
            timeOffsetSec: 2.5,
            positionM: StockpileVector3Payload(x: 3, y: 4, z: 5),
            headingDegrees: 12,
            trackingState: "running",
            yawPitchRollDeg: StockpileVector3Payload(x: 90, y: -4, z: 1),
            horizontalAccuracyM: 0.4,
            verticalAccuracyM: 0.8
        )
    ]
}

private func makeReferenceObservations() -> [StockpileReferenceObservationPayload] {
    [
        StockpileReferenceObservationPayload(
            referenceID: "QPMC-01",
            family: "apriltag",
            frameTimeSec: 2.5,
            poseSampleIndex: 7,
            decisionMargin: 92.5,
            hamming: 0,
            edgeLengthPx: 144,
            frameID: "frame_0010",
            pixelAreaPx: 1800,
            confidence: 0.92,
            estimatedDistanceM: 4.2,
            state: .confirmed
        )
    ]
}

private func makeReferenceEvidenceJPEGFrames() -> [StockpileReferenceEvidenceJPEGFramePayload] {
    [
        StockpileReferenceEvidenceJPEGFramePayload(
            frameID: "frame_0010",
            timeOffsetSec: 2.5,
            poseSampleIndex: 7,
            capturedAt: Date(timeIntervalSince1970: 1_713_697_845),
            widthPx: 1440,
            heightPx: 810,
            jpegBase64: "jpeg-frame-0010"
        )
    ]
}
