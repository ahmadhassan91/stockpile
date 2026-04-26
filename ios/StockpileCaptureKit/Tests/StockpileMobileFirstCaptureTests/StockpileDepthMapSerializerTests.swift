import XCTest
@testable import StockpileMobileFirstCapture

final class StockpileDepthMapSerializerTests: XCTestCase {
    func testDepthSamplesSerializeAsLittleEndianFloat16Bytes() {
        let data = StockpileDepthMapSerializer.float16LittleEndianData(
            fromDepthSamplesMeters: [0, 1, 2, -2, 0.5]
        )

        XCTAssertEqual(
            [UInt8](data),
            [
                0x00, 0x00,
                0x00, 0x3c,
                0x00, 0x40,
                0x00, 0xc0,
                0x00, 0x38,
            ]
        )
    }

    func testSerializeCarriesDimensionsDepthDataAndOptionalConfidenceMap() throws {
        let payload = try StockpileDepthMapSerializer.serialize(
            width: 2,
            height: 2,
            depthSamplesMeters: [0, 1, 2, 0.5],
            confidenceSamples: [0, 1, 2, 255]
        )

        XCTAssertEqual(payload.width, 2)
        XCTAssertEqual(payload.height, 2)
        XCTAssertEqual(
            [UInt8](payload.depthF16LittleEndianData),
            [
                0x00, 0x00,
                0x00, 0x3c,
                0x00, 0x40,
                0x00, 0x38,
            ]
        )
        XCTAssertEqual([UInt8](try XCTUnwrap(payload.confidenceMapUInt8Data)), [0, 1, 2, 255])
    }

    func testSerializeRejectsMismatchedDepthAndConfidenceSampleCounts() {
        XCTAssertThrowsError(
            try StockpileDepthMapSerializer.serialize(
                width: 2,
                height: 2,
                depthSamplesMeters: [1, 2, 3],
                confidenceSamples: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? StockpileDepthMapSerializer.SerializationError,
                .depthSampleCountMismatch(expected: 4, actual: 3)
            )
        }

        XCTAssertThrowsError(
            try StockpileDepthMapSerializer.serialize(
                width: 2,
                height: 2,
                depthSamplesMeters: [1, 2, 3, 4],
                confidenceSamples: [2, 2, 2]
            )
        ) { error in
            XCTAssertEqual(
                error as? StockpileDepthMapSerializer.SerializationError,
                .confidenceSampleCountMismatch(expected: 4, actual: 3)
            )
        }
    }
}
