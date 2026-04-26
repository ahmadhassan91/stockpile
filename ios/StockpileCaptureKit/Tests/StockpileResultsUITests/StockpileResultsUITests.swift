import XCTest
@testable import StockpileResultsUI

final class StockpileResultsUITests: XCTestCase {
    func testVerifiedOutcomeKeepsReportingActionInSummaryHierarchy() {
        let model = StockpileResultScreenModel.mockVerified

        XCTAssertEqual(model.outcome, .verified)
        XCTAssertEqual(model.bannerTitle, "Verified result")
        XCTAssertTrue(model.bannerSummary.contains("ready for reporting"))
        XCTAssertTrue(model.showsMeasurement)
        XCTAssertEqual(model.confidence.score, 92)
        XCTAssertEqual(model.primaryStatusLabel, "Ready to report")
        XCTAssertEqual(model.highlights.map(\.label), ["Volume", "Weight", "Confidence"])
        XCTAssertEqual(model.highlights.last?.isEmphasized, true)
        XCTAssertEqual(model.highlights.last?.note, "High confidence")
        XCTAssertEqual(model.recommendedAction, "Share the verified report with the site team.")
        XCTAssertEqual(model.confidenceLenses.map(\.label), ["Surface", "Toe"])
        XCTAssertNil(model.reportURL)
        XCTAssertNotNil(model.reconstruction)
        XCTAssertTrue(model.attentionItems.isEmpty)
        XCTAssertNil(model.attentionTitle)
    }

    func testReviewOnlyOutcomeKeepsActionFirstReviewMessaging() {
        let model = StockpileResultScreenModel.mockReviewOnly

        XCTAssertEqual(model.outcome, .reviewOnly)
        XCTAssertEqual(model.bannerTitle, "Review required")
        XCTAssertTrue(model.bannerSummary.contains("cross-check"))
        XCTAssertFalse(model.blockers.isEmpty)
        XCTAssertEqual(model.primaryStatusLabel, "Needs review")
        XCTAssertTrue(model.recommendedAction.contains("benchmark"))
        XCTAssertEqual(model.highlights.map(\.label), ["Volume", "Weight", "Confidence"])
        XCTAssertEqual(model.highlights.last?.isEmphasized, true)
        XCTAssertEqual(model.attentionTitle, "Before you finalize")
        XCTAssertEqual(model.attentionItems.map(\.kind), [.blocker, .warning])
        XCTAssertEqual(model.confidenceLenses.map(\.state), [.medium, .low])
        XCTAssertEqual(model.reconstruction?.defaultMode, .surface)
    }

    func testReviewOnlyOutcomeCanStayActionLedWithoutAttentionItems() {
        let model = StockpileResultScreenModel(
            runID: "run_review_clean",
            pileName: "North Yard 05",
            outcome: .reviewOnly,
            confidence: StockpileConfidenceSummary(
                score: 64,
                label: "Moderate",
                summary: "Useable result, but release still needs an operator decision."
            ),
            measurement: StockpileMeasurement(volumeM3: 1804.2, weightTonnes: 3788.82, densityKgPerM3: 2100),
            warnings: [],
            blockers: [],
            recommendedAction: "Compare the result against the current benchmark before release."
        )

        XCTAssertEqual(model.primaryStatusLabel, "Needs review")
        XCTAssertTrue(model.showsMeasurement)
        XCTAssertEqual(model.highlights.map(\.label), ["Volume", "Weight", "Confidence"])
        XCTAssertEqual(model.highlights.last?.isEmphasized, true)
        XCTAssertTrue(model.attentionItems.isEmpty)
        XCTAssertNil(model.attentionTitle)
        XCTAssertEqual(model.recommendedAction, "Compare the result against the current benchmark before release.")
    }

    func testBlockedOutcomeSuppressesMeasurementAndKeepsRecaptureActionPrimary() {
        let model = StockpileResultScreenModel.mockBlocked

        XCTAssertEqual(model.outcome, .blocked)
        XCTAssertEqual(model.bannerTitle, "Capture blocked")
        XCTAssertFalse(model.showsMeasurement)
        XCTAssertNil(model.measurement)
        XCTAssertTrue(model.recommendedAction.contains("Retake"))
        XCTAssertEqual(model.primaryStatusLabel, "Retake needed")
        XCTAssertEqual(model.highlights.map(\.label), ["Confidence"])
        XCTAssertEqual(model.highlights.last?.isEmphasized, true)
        XCTAssertEqual(model.attentionTitle, "What to fix")
        XCTAssertEqual(model.attentionItems.map(\.kind), [.blocker, .warning])
        XCTAssertEqual(model.confidenceLenses.map(\.state), [.low, .low])
        XCTAssertEqual(model.reconstruction?.defaultMode, .toe)
    }

    func testDecodedPayloadPreservesActionFirstReviewSemantics() throws {
        let json = """
        {
          "runId": "run_123",
          "pileName": "Stockpile 12",
          "outcome": "review_only",
          "confidence": {
            "score": 58,
            "label": "Moderate",
            "summary": "Calibration recovered but still needs a benchmark cross-check."
          },
          "measurement": {
            "volumeM3": 2528.43,
            "weightTonnes": 5309.70,
            "densityKgPerM3": 2100
          },
          "warnings": [
            "Toe coverage is partial on the north edge."
          ],
          "blockers": [],
          "recommendedAction": "Review against the latest site benchmark before treating as final."
        }
        """

        let payload = try JSONDecoder().decode(StockpileResultScreenModel.self, from: Data(json.utf8))

        XCTAssertEqual(payload.runID, "run_123")
        XCTAssertEqual(payload.outcome, .reviewOnly)
        XCTAssertEqual(payload.measurement?.volumeM3, 2528.43)
        XCTAssertEqual(payload.bannerTone, .amber)
        XCTAssertEqual(payload.primaryStatusLabel, "Needs review")
        XCTAssertEqual(payload.highlights.map(\.label), ["Volume", "Weight", "Confidence"])
        XCTAssertEqual(payload.highlights.last?.isEmphasized, true)
        XCTAssertEqual(payload.recommendedAction, "Review against the latest site benchmark before treating as final.")
        XCTAssertEqual(payload.attentionTitle, "Before you finalize")
        XCTAssertEqual(payload.attentionItems.map(\.kind), [.warning])
        XCTAssertNil(payload.reportURL)
        XCTAssertTrue(payload.confidenceLenses.isEmpty)
        XCTAssertNil(payload.reconstruction)
    }

    func testDecodedPayloadPreservesBackendReportURL() throws {
        let json = """
        {
          "runId": "run_456",
          "pileName": "North Yard 07",
          "outcome": "verified",
          "confidence": {
            "score": 88,
            "label": "High",
            "summary": "Backend review passed and the report is ready."
          },
          "measurement": {
            "volumeM3": 1801.45,
            "weightTonnes": 3783.05,
            "densityKgPerM3": 2100
          },
          "warnings": [],
          "blockers": [],
          "recommendedAction": "Open the backend report and share the released value.",
          "reportURL": "https://stockpile.theclustox.com/reports/run_456",
          "updatedAt": "2026-04-22T09:30:00Z"
        }
        """

        let payload = try JSONDecoder().decode(StockpileResultScreenModel.self, from: Data(json.utf8))

        XCTAssertEqual(payload.outcome, .verified)
        XCTAssertEqual(payload.reportURL?.absoluteString, "https://stockpile.theclustox.com/reports/run_456")
        XCTAssertNotNil(payload.updatedAt)
    }

    func testDemoReconstructionContainsRenderableGeometry() {
        let reconstruction = StockpileResultReconstruction.demoReview

        XCTAssertGreaterThan(reconstruction.vertices.count, 0)
        XCTAssertGreaterThan(reconstruction.triangles.count, 0)
        XCTAssertGreaterThan(reconstruction.pointCloud.count, 0)
        XCTAssertGreaterThan(reconstruction.peakHeightM, 0)
    }
}
