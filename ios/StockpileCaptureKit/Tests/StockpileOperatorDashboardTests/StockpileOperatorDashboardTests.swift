import XCTest
@testable import StockpileOperatorDashboard

final class StockpileOperatorDashboardTests: XCTestCase {
    func testPreviewContentSurfacesUrgentOperationalState() {
        let content = OperatorDashboardContent.preview

        XCTAssertEqual(content.summary.facilityName, "QPMC North Yard")
        XCTAssertEqual(content.summary.reviewQueue, 1)
        XCTAssertEqual(content.summary.blockedRuns, 1)
        XCTAssertEqual(content.urgentActionCount, 2)
        XCTAssertEqual(content.primaryActionTitle, "Plan recapture")
        XCTAssertEqual(content.activeJobs.count, 2)
        XCTAssertEqual(content.recentRuns.count, 3)
    }

    func testFacilityHealthHeadlinePrioritizesBlockedRunsOverReviewQueue() {
        let blockedFirst = OperatorFacilitySummary(
            facilityName: "North Yard",
            operatorLabel: "Shift lead",
            activeSites: 2,
            activeJobs: 1,
            reviewQueue: 3,
            blockedRuns: 2,
            verifiedToday: 4,
            lastSyncLabel: "Synced now"
        )
        let reviewOnly = OperatorFacilitySummary(
            facilityName: "North Yard",
            operatorLabel: "Shift lead",
            activeSites: 2,
            activeJobs: 1,
            reviewQueue: 1,
            blockedRuns: 0,
            verifiedToday: 4,
            lastSyncLabel: "Synced now"
        )
        let healthy = OperatorFacilitySummary(
            facilityName: "North Yard",
            operatorLabel: "Shift lead",
            activeSites: 2,
            activeJobs: 0,
            reviewQueue: 0,
            blockedRuns: 0,
            verifiedToday: 4,
            lastSyncLabel: "Synced now"
        )

        XCTAssertEqual(blockedFirst.healthHeadline, "2 captures need recapture")
        XCTAssertEqual(blockedFirst.healthTone, .critical)
        XCTAssertEqual(reviewOnly.healthHeadline, "1 run ready for operator review")
        XCTAssertEqual(reviewOnly.healthTone, .caution)
        XCTAssertEqual(healthy.healthHeadline, "Field operations are clear to proceed")
        XCTAssertEqual(healthy.healthTone, .success)
    }

    func testFacilityQueueMessagingCallsOutBlockedAndReviewSequence() {
        let mixedQueue = OperatorFacilitySummary(
            facilityName: "North Yard",
            operatorLabel: "Shift lead",
            activeSites: 4,
            activeJobs: 2,
            reviewQueue: 1,
            blockedRuns: 2,
            verifiedToday: 4,
            lastSyncLabel: "Synced now"
        )
        let reviewOnly = OperatorFacilitySummary(
            facilityName: "North Yard",
            operatorLabel: "Shift lead",
            activeSites: 4,
            activeJobs: 1,
            reviewQueue: 1,
            blockedRuns: 0,
            verifiedToday: 4,
            lastSyncLabel: "Synced now"
        )

        XCTAssertEqual(mixedQueue.healthStatusLabel, "Recapture needed")
        XCTAssertEqual(mixedQueue.queueHeadline, "2 runs blocked, 1 run waiting for review")
        XCTAssertEqual(
            mixedQueue.queueMessage,
            "Set the recapture plan first, then clear the review queue before any final report is shared."
        )
        XCTAssertEqual(reviewOnly.healthStatusLabel, "Review queue live")
        XCTAssertEqual(reviewOnly.queueHeadline, "1 run is ready for review")
    }

    func testContentPrioritizesAttentionQueueBeforeSecondaryActions() {
        let content = OperatorDashboardContent.preview

        XCTAssertEqual(content.attentionSectionTitle, "Urgent queue")
        XCTAssertEqual(content.attentionActions.map(\.id), ["blocked-run-409", "review-run-412"])
        XCTAssertEqual(content.secondaryActions.map(\.id), ["verified-run-404"])
        XCTAssertEqual(content.secondarySectionTitle, "Ready to share")
    }

    func testTrustStatesExposePremiumDashboardSemantics() {
        XCTAssertEqual(OperatorDashboardTrustState.verified.title, "Verified")
        XCTAssertEqual(OperatorDashboardTrustState.verified.tone, .success)
        XCTAssertEqual(OperatorDashboardTrustState.reviewOnly.actionTitle, "Review result")
        XCTAssertEqual(OperatorDashboardTrustState.blocked.tone, .critical)
        XCTAssertEqual(OperatorDashboardTrustState.processing.actionTitle, "Track progress")
    }

    func testActiveJobProgressIsClampedForUIStability() {
        let over = OperatorActiveJob(
            id: "over",
            pileName: "North Yard 03",
            stage: .reconstruction,
            progress: 1.4,
            trustState: .processing,
            etaLabel: "ETA 1 min",
            detail: "Healthy capture"
        )
        let under = OperatorActiveJob(
            id: "under",
            pileName: "North Yard 04",
            stage: .upload,
            progress: -0.2,
            trustState: .processing,
            etaLabel: "ETA 8 min",
            detail: "Upload queued"
        )

        XCTAssertEqual(over.clampedProgress, 1)
        XCTAssertEqual(under.clampedProgress, 0)
    }
}
