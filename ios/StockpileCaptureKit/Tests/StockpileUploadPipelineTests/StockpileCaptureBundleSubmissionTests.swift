import XCTest
@testable import StockpileUploadPipeline

final class StockpileCaptureBundleSubmissionTests: XCTestCase {

    // MARK: - Receipt decoding

    func testReceiptDecodesFromBackendCamelCaseJSON() throws {
        let json = Data("""
        {"captureId":"abc","jobId":"job_1","resultId":"r_1","status":"completed"}
        """.utf8)
        let receipt = try JSONDecoder().decode(
            StockpileCaptureBundleSubmissionReceipt.self,
            from: json
        )
        XCTAssertEqual(receipt.captureID, "abc")
        XCTAssertEqual(receipt.jobID, "job_1")
        XCTAssertEqual(receipt.resultID, "r_1")
        XCTAssertEqual(receipt.status, "completed")
    }

    func testReceiptDecodesWhenResultIDIsAbsent() throws {
        let json = Data("""
        {"captureId":"abc","jobId":"job_1","status":"queued"}
        """.utf8)
        let receipt = try JSONDecoder().decode(
            StockpileCaptureBundleSubmissionReceipt.self,
            from: json
        )
        XCTAssertNil(receipt.resultID)
        XCTAssertEqual(receipt.status, "queued")
    }

    // MARK: - Request shape

    func testRequestBuilderAddsV2HeadersAndBoundary() {
        let endpoint = URL(string: "https://api.example.com/api/v2/captures")!
        let submitter = URLSessionCaptureBundleSubmitter(
            configuration: .init(endpointURL: endpoint),
            session: ThrowingMockSession()
        )
        let request = submitter.makeRequest(
            boundary: "B",
            captureID: "cap123",
            siteID: "site9",
            materialCode: "aggregate_5_14",
            densityKgPerM3: 1650,
            pileSizeMode: "small"
        )
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=B"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Stockpile-Capture-Mode"),
            "markerless"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Stockpile-Capture-ID"),
            "cap123"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Stockpile-Site-ID"),
            "site9"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Stockpile-Material-Code"),
            "aggregate_5_14"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Stockpile-Density-Kg-Per-M3"),
            "1650"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Stockpile-Pile-Size-Mode"),
            "small"
        )
    }

    func testRequestBuilderForwardsAdditionalHeaders() {
        let endpoint = URL(string: "https://api.example.com/api/v2/captures")!
        let submitter = URLSessionCaptureBundleSubmitter(
            configuration: .init(
                endpointURL: endpoint,
                additionalHeaders: ["Authorization": "Bearer token-xyz"]
            ),
            session: ThrowingMockSession()
        )
        let request = submitter.makeRequest(
            boundary: "B",
            captureID: "c",
            siteID: "s",
            materialCode: "m",
            densityKgPerM3: 1700
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-xyz")
    }

    // MARK: - Multipart body shape

    func testMultipartBodyContainsBoundaryHeadersAndBundleBytes() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-\(UUID()).stockpilecapture")
        let payload = Data("ZIP_PAYLOAD_BYTES".utf8)
        try payload.write(to: bundleURL)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let bodyURL = try URLSessionCaptureBundleSubmitter.writeMultipartBody(
            bundleURL: bundleURL,
            boundary: "B"
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let body = try Data(contentsOf: bodyURL)
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("--B"), "boundary missing")
        XCTAssertTrue(bodyString.contains(#"name="bundle""#), "form field name missing")
        XCTAssertTrue(
            bodyString.contains("Content-Type: application/zip"),
            "ZIP content type missing"
        )
        XCTAssertTrue(
            bodyString.contains("ZIP_PAYLOAD_BYTES"),
            "bundle bytes were not streamed into the body"
        )
        XCTAssertTrue(bodyString.hasSuffix("\r\n--B--\r\n"), "closing boundary missing")
    }

    // MARK: - End-to-end stubbed submission

    func testSubmitDecodesReceiptFromStubbedHTTP202() async throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID()).stockpilecapture")
        try Data("fakezip".utf8).write(to: bundleURL)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let endpoint = URL(string: "https://api.example.com/api/v2/captures")!
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: 202,
            httpVersion: nil,
            headerFields: nil
        )!
        let body = Data(#"{"captureId":"c1","jobId":"j1","resultId":"r1","status":"completed"}"#.utf8)
        let session = StubSession(data: body, response: response)

        let submitter = URLSessionCaptureBundleSubmitter(
            configuration: .init(endpointURL: endpoint),
            session: session
        )
        let receipt = try await submitter.submitCaptureBundle(
            at: bundleURL,
            captureID: "c1",
            siteID: "s1",
            materialCode: "m1",
            densityKgPerM3: 1600
        )
        XCTAssertEqual(receipt.captureID, "c1")
        XCTAssertEqual(receipt.jobID, "j1")
        XCTAssertEqual(receipt.resultID, "r1")
        XCTAssertEqual(receipt.status, "completed")
    }

    func testSubmitThrowsOn400WithServerBodyAttached() async throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID()).stockpilecapture")
        try Data("fakezip".utf8).write(to: bundleURL)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let endpoint = URL(string: "https://api.example.com/api/v2/captures")!
        let response = HTTPURLResponse(
            url: endpoint,
            statusCode: 400,
            httpVersion: nil,
            headerFields: nil
        )!
        let serverBody = Data(#"{"detail":"manifest missing capture_id"}"#.utf8)
        let session = StubSession(data: serverBody, response: response)

        let submitter = URLSessionCaptureBundleSubmitter(
            configuration: .init(endpointURL: endpoint),
            session: session
        )
        do {
            _ = try await submitter.submitCaptureBundle(
                at: bundleURL,
                captureID: "c",
                siteID: "s",
                materialCode: "m",
                densityKgPerM3: 1600
            )
            XCTFail("expected an HTTP error to be thrown")
        } catch let StockpileCaptureBundleSubmissionError.httpError(statusCode, body) {
            XCTAssertEqual(statusCode, 400)
            XCTAssertTrue(body.contains("manifest missing capture_id"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSubmitThrowsBundleFileMissingWhenURLDoesNotExist() async throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID()).stockpilecapture")
        let endpoint = URL(string: "https://api.example.com/api/v2/captures")!
        let submitter = URLSessionCaptureBundleSubmitter(
            configuration: .init(endpointURL: endpoint),
            session: ThrowingMockSession()
        )
        do {
            _ = try await submitter.submitCaptureBundle(
                at: bundleURL,
                captureID: "c",
                siteID: "s",
                materialCode: "m",
                densityKgPerM3: 1600
            )
            XCTFail("expected bundleFileMissing")
        } catch StockpileCaptureBundleSubmissionError.bundleFileMissing {
            // pass
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSubmitThrowsBundleFileEmptyWhenZeroBytes() async throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID()).stockpilecapture")
        try Data().write(to: bundleURL)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let endpoint = URL(string: "https://api.example.com/api/v2/captures")!
        let submitter = URLSessionCaptureBundleSubmitter(
            configuration: .init(endpointURL: endpoint),
            session: ThrowingMockSession()
        )
        do {
            _ = try await submitter.submitCaptureBundle(
                at: bundleURL,
                captureID: "c",
                siteID: "s",
                materialCode: "m",
                densityKgPerM3: 1600
            )
            XCTFail("expected bundleFileEmpty")
        } catch StockpileCaptureBundleSubmissionError.bundleFileEmpty {
            // pass
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Mock submitter

    func testMockSubmitterReturnsConfiguredReceipt() async throws {
        let mock = MockStockpileCaptureBundleSubmitter(
            receipt: .init(captureID: "x", jobID: "y", resultID: "z", status: "completed")
        )
        let receipt = try await mock.submitCaptureBundle(
            at: URL(fileURLWithPath: "/tmp/anything.zip"),
            captureID: "x",
            siteID: "s",
            materialCode: "m",
            densityKgPerM3: 1600
        )
        XCTAssertEqual(receipt.captureID, "x")
        XCTAssertEqual(receipt.jobID, "y")
    }

    func testMockSubmitterCanThrowConfiguredError() async throws {
        let mock = MockStockpileCaptureBundleSubmitter(
            behaviour: .failure(.httpError(statusCode: 500, body: "boom"))
        )
        do {
            _ = try await mock.submitCaptureBundle(
                at: URL(fileURLWithPath: "/tmp/anything.zip"),
                captureID: "x",
                siteID: "s",
                materialCode: "m",
                densityKgPerM3: 1600
            )
            XCTFail("expected error")
        } catch StockpileCaptureBundleSubmissionError.httpError(let code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

// MARK: - Test doubles

private struct StubSession: StockpileCaptureBundleSubmissionSessioning {
    let data: Data
    let response: URLResponse

    func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        (data, response)
    }
}

private struct ThrowingMockSession: StockpileCaptureBundleSubmissionSessioning {
    func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        throw URLError(.networkConnectionLost)
    }
}
