import XCTest
@testable import StockpileMobileFirstCapture

final class StockpileCaptureBundleContractTests: XCTestCase {
    func testManifestBuilderProducesSchemaVersionedManifestWithFrameMediaTrackingAndEstimate() throws {
        let frame = StockpileCaptureBundleFrameIndexEntry(
            frameID: "frame-000042",
            frameNumber: 42,
            timestampSec: 1.4,
            rgb: StockpileCaptureBundleRGBMetadata(
                relativePath: "rgb/frame-000042.heic",
                width: 1920,
                height: 1440,
                colorSpace: "display_p3",
                byteSize: 512_000
            ),
            depth: StockpileCaptureBundleDepthMetadata(
                relativePath: "depth/frame-000042.depth",
                width: 256,
                height: 192,
                pixelFormat: "depth_float32",
                minDepthM: 0.35,
                maxDepthM: 8.2,
                isSmoothed: true,
                byteSize: 196_608
            ),
            confidence: StockpileCaptureBundleConfidenceMetadata(
                relativePath: "confidence/frame-000042.confidence",
                width: 256,
                height: 192,
                pixelFormat: "confidence_uint8",
                coverageRatio: 0.74,
                byteSize: 49_152
            ),
            poseID: "pose-000042"
        )

        let manifest = StockpileCaptureBundleManifestBuilder(
            captureID: "capture-123",
            siteID: "qpmc-yard-3",
            materialCode: "sand",
            densityKgPerM3: 1600,
            pileSizeMode: "small",
            createdAt: Date(timeIntervalSince1970: 100),
            device: StockpileCaptureBundleDeviceMetadata(
                manufacturer: "Apple",
                modelIdentifier: "iPhone16,2",
                operatingSystem: "iOS",
                operatingSystemVersion: "18.4",
                appVersion: "1.2.3",
                captureKitVersion: "0.4.0",
                supportsLiDAR: true
            ),
            frameIndex: [frame],
            trackingSummary: StockpileCaptureBundleTrackingSummary(
                totalFrameCount: 10,
                trackedFrameCount: 8,
                limitedFrameCount: 2,
                lostFrameCount: 0,
                averageTrackingConfidence: 0.82
            ),
            groundAnchorID: "anchor-ground",
            onDeviceQuickEstimate: StockpileCaptureBundleQuickEstimate(
                volumeM3: 12.5,
                footprintAreaM2: 8.4,
                peakHeightM: 2.1,
                confidenceScore: 0.71,
                sampledPointCount: 2_048,
                cameraPathDistanceM: 6.3
            )
        ).build()

        XCTAssertEqual(manifest.schemaVersion, "1.0")
        XCTAssertEqual(manifest.manifestFileName, "manifest.json")
        XCTAssertEqual(manifest.posesFileName, "poses.json")
        XCTAssertEqual(manifest.anchorsFileName, "anchors.json")
        XCTAssertEqual(manifest.siteID, "qpmc-yard-3")
        XCTAssertEqual(manifest.materialCode, "sand")
        XCTAssertEqual(manifest.densityKgPerM3, 1600)
        XCTAssertEqual(manifest.pileSizeMode, "small")
        XCTAssertEqual(manifest.frameIndex, [frame])
        XCTAssertEqual(manifest.trackingSummary.trackingRatio, 0.8, accuracy: 0.0001)
        XCTAssertEqual(manifest.groundAnchorID, "anchor-ground")
        XCTAssertEqual(manifest.onDeviceQuickEstimate?.volumeM3, 12.5)

        let payload = try StockpileCaptureBundleJSONEncoder().encodeJSONObject(manifest)

        XCTAssertEqual(payload["schema_version"] as? String, "1.0")
        XCTAssertEqual(payload["manifest_file"] as? String, "manifest.json")
        XCTAssertEqual(payload["poses_file"] as? String, "poses.json")
        XCTAssertEqual(payload["anchors_file"] as? String, "anchors.json")
        XCTAssertEqual(payload["site_id"] as? String, "qpmc-yard-3")
        XCTAssertEqual(payload["material_code"] as? String, "sand")
        XCTAssertEqual(payload["density_kg_per_m3"] as? Int, 1600)
        XCTAssertEqual(payload["pile_size_mode"] as? String, "small")
        XCTAssertEqual(payload["ground_anchor_id"] as? String, "anchor-ground")
        XCTAssertNotNil(payload["on_device_quick_estimate"])

        let trackingSummary = try XCTUnwrap(payload["tracking_summary"] as? [String: Any])
        XCTAssertEqual(trackingSummary["total_frame_count"] as? Int, 10)
        XCTAssertEqual(trackingSummary["tracked_frame_count"] as? Int, 8)
        XCTAssertEqual(trackingSummary["limited_frame_count"] as? Int, 2)
        XCTAssertEqual(trackingSummary["lost_frame_count"] as? Int, 0)
        XCTAssertEqual(try XCTUnwrap(trackingSummary["tracking_ratio"] as? Double), 0.8, accuracy: 0.0001)
        XCTAssertNil(trackingSummary["trackedFrameCount"])

        let frameIndex = try XCTUnwrap(payload["frame_index"] as? [[String: Any]])
        XCTAssertEqual(frameIndex.first?["frame_id"] as? String, "frame-000042")
        XCTAssertNotNil(frameIndex.first?["rgb"])
        XCTAssertNotNil(frameIndex.first?["depth"])
        XCTAssertNotNil(frameIndex.first?["confidence"])
    }

    func testPoseAndAnchorDocumentsCarrySchemaVersionAndGroundAnchorContract() throws {
        let transform = StockpileCaptureBundleTransform(
            matrix4x4: Array(0..<16).map(Float.init),
            translationMeters: StockpileCaptureBundleVector3(x: 1, y: 2, z: 3),
            eulerAnglesRadians: StockpileCaptureBundleVector3(x: 0.1, y: 0.2, z: 0.3)
        )
        let pose = StockpileCaptureBundlePoseSample(
            poseID: "pose-000042",
            frameID: "frame-000042",
            frameNumber: 42,
            timestampSec: 1.4,
            transform: transform,
            trackingState: .normal,
            trackingConfidence: 0.9
        )
        let anchor = StockpileCaptureBundleAnchor(
            anchorID: "anchor-ground",
            anchorType: .groundPlane,
            transform: transform,
            extentMeters: StockpileCaptureBundleSize3(width: 4, height: 0.02, depth: 5),
            confidenceScore: 0.88,
            observedFrameIDs: ["frame-000040", "frame-000042"]
        )

        let poses = StockpileCaptureBundlePoseDocument(poses: [pose])
        let anchors = StockpileCaptureBundleAnchorDocument(
            groundAnchorID: "anchor-ground",
            anchors: [anchor]
        )

        XCTAssertEqual(poses.schemaVersion, "1.0")
        XCTAssertEqual(anchors.schemaVersion, "1.0")
        XCTAssertEqual(anchors.groundAnchorID, "anchor-ground")
        XCTAssertEqual(anchors.groundAnchor?.anchorID, "anchor-ground")

        let encoder = StockpileCaptureBundleJSONEncoder()
        let posesPayload = try encoder.encodeJSONObject(poses)
        let anchorsPayload = try encoder.encodeJSONObject(anchors)

        XCTAssertEqual(posesPayload["schema_version"] as? String, "1.0")
        XCTAssertNotNil(posesPayload["poses"])
        XCTAssertEqual(anchorsPayload["schema_version"] as? String, "1.0")
        XCTAssertEqual(anchorsPayload["ground_anchor_id"] as? String, "anchor-ground")

        let encodedAnchors = try XCTUnwrap(anchorsPayload["anchors"] as? [[String: Any]])
        XCTAssertEqual(encodedAnchors.first?["anchor_type"] as? String, "ground_plane")
    }

    func testBundleBuilderProducesNamedJSONDocumentsForStockpileCaptureArchive() throws {
        let documents = StockpileCaptureBundleBuilder(
            manifest: StockpileCaptureBundleManifestBuilder(
                captureID: "capture-123",
                materialCode: "backfill",
                densityKgPerM3: StockpileCaptureBundleMaterialPreset.backfill.defaultDensityKgPerM3,
                createdAt: Date(timeIntervalSince1970: 100),
                device: StockpileCaptureBundleDeviceMetadata(
                    manufacturer: "Apple",
                    modelIdentifier: "iPhone16,2",
                    operatingSystem: "iOS",
                    operatingSystemVersion: "18.4"
                ),
                frameIndex: [],
                trackingSummary: .empty,
                groundAnchorID: "anchor-ground",
                onDeviceQuickEstimate: nil
            ).build(),
            poses: StockpileCaptureBundlePoseDocument(poses: []),
            anchors: StockpileCaptureBundleAnchorDocument(
                groundAnchorID: "anchor-ground",
                anchors: []
            )
        ).build()

        XCTAssertEqual(documents.schemaVersion, "1.0")
        XCTAssertEqual(documents.fileNames, ["manifest.json", "poses.json", "anchors.json"])
        XCTAssertEqual(documents.manifest.schemaVersion, "1.0")
        XCTAssertEqual(documents.poses.schemaVersion, "1.0")
        XCTAssertEqual(documents.anchors.schemaVersion, "1.0")

        let encoded = try documents.encodedJSONFiles()
        XCTAssertEqual(Set(encoded.keys), ["manifest.json", "poses.json", "anchors.json"])
        XCTAssertTrue(try XCTUnwrap(String(data: encoded["manifest.json"] ?? Data(), encoding: .utf8)).contains("\"schema_version\":\"1.0\""))
    }

    func testMaterialPresetsAreCanonicalAndDensityCanBeEditedWithinSaneBounds() {
        XCTAssertEqual(
            StockpileCaptureBundleMaterialPreset.allCases.map(\.rawValue),
            ["sand", "gravel", "backfill", "aggregate", "soil", "other"]
        )
        XCTAssertTrue(StockpileCaptureBundleMaterialPreset.contains(code: " Sand "))
        XCTAssertFalse(StockpileCaptureBundleMaterialPreset.contains(code: "backfill-0-75-mm"))
        XCTAssertTrue(StockpileCaptureBundleMaterialPreset.densityIsInSaneBounds(1_750))
        XCTAssertFalse(StockpileCaptureBundleMaterialPreset.densityIsInSaneBounds(0))
        XCTAssertFalse(StockpileCaptureBundleMaterialPreset.densityIsInSaneBounds(3_001))
    }

    func testManifestPreservesExplicitMaterialInputsWithoutSilentFallbackOrDensityClamp() throws {
        let manifest = StockpileCaptureBundleManifestBuilder(
            captureID: "capture-123",
            materialCode: "  ",
            densityKgPerM3: 0,
            createdAt: Date(timeIntervalSince1970: 100),
            device: StockpileCaptureBundleDeviceMetadata(
                manufacturer: "Apple",
                modelIdentifier: "iPhone16,2",
                operatingSystem: "iOS",
                operatingSystemVersion: "18.4"
            ),
            frameIndex: [],
            trackingSummary: .empty,
            groundAnchorID: "anchor-ground"
        ).build()

        XCTAssertEqual(manifest.materialCode, "")
        XCTAssertEqual(manifest.densityKgPerM3, 0)

        let payload = try StockpileCaptureBundleJSONEncoder().encodeJSONObject(manifest)
        XCTAssertEqual(payload["material_code"] as? String, "")
        XCTAssertEqual(payload["density_kg_per_m3"] as? Int, 0)
    }

    func testVisionMaterialSuggestionSerializesSeparatelyFromUserSelectedMaterial() throws {
        let manifest = StockpileCaptureBundleManifestBuilder(
            captureID: "capture-123",
            materialCode: "gravel",
            densityKgPerM3: 1_850,
            createdAt: Date(timeIntervalSince1970: 100),
            device: StockpileCaptureBundleDeviceMetadata(
                manufacturer: "Apple",
                modelIdentifier: "iPhone16,2",
                operatingSystem: "iOS",
                operatingSystemVersion: "18.4"
            ),
            frameIndex: [],
            trackingSummary: .empty,
            groundAnchorID: "anchor-ground",
            visionMaterialSuggestion: StockpileCaptureBundleVisionMaterialSuggestion(
                suggestedMaterialCode: "sand",
                confidenceScore: 0.64,
                source: "vision_foreground_instance_mask"
            )
        ).build()

        XCTAssertEqual(manifest.materialCode, "gravel")
        XCTAssertEqual(manifest.visionMaterialSuggestion?.suggestedMaterialCode, "sand")

        let payload = try StockpileCaptureBundleJSONEncoder().encodeJSONObject(manifest)
        XCTAssertEqual(payload["material_code"] as? String, "gravel")
        let suggestion = try XCTUnwrap(payload["vision_material_suggestion"] as? [String: Any])
        XCTAssertEqual(suggestion["suggested_material_code"] as? String, "sand")
        XCTAssertEqual(suggestion["source"] as? String, "vision_foreground_instance_mask")
    }
}
