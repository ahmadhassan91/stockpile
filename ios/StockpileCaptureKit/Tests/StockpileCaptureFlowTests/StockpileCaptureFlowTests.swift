import XCTest
@testable import StockpileCaptureFlow

final class StockpileCaptureFlowTests: XCTestCase {
    func testCaptureHomePreviewUsesGuidedCapturePrimaryAction() {
        let content = CaptureHomeContent.preview

        XCTAssertEqual(content.primaryActionTitle, "Start Guided Capture")
        XCTAssertEqual(content.quickTips.count, 3)
        XCTAssertEqual(content.recentRuns.count, 2)
        XCTAssertEqual(content.readinessHeadline, "Review-grade likely")
    }

    func testGuidedCaptureReadyToFinishRequiresBalancedSignalQuality() {
        let ready = GuidedCaptureContent.preview
        let notReady = GuidedCaptureContent(
            pileName: "North Yard 03",
            sessionLabel: "Walkaround in progress",
            referencesVisible: 1,
            referenceTarget: 3,
            perimeterCoverage: 0.42,
            stabilityScore: 0.58,
            activePrompt: "Keep 2-3 tagged references visible together.",
            captureChecks: [
                GuidedCaptureCheck(
                    title: "Reference visibility",
                    status: .needsAttention,
                    detail: "Only one tagged reference is visible.",
                    operatorAction: "Move until two tagged references stay in frame together."
                ),
                GuidedCaptureCheck(
                    title: "Perimeter coverage",
                    status: .needsAttention,
                    detail: "Less than half the toe is covered.",
                    operatorAction: "Complete the far edge before finishing the walkaround."
                ),
            ]
        )

        XCTAssertTrue(ready.isReadyToFinish)
        XCTAssertFalse(notReady.isReadyToFinish)
        XCTAssertEqual(notReady.readinessSummary, "Needs more coverage")
    }

    func testGuidedCaptureReadinessSummaryCallsOutTaggedReferenceShortfall() {
        let content = GuidedCaptureContent(
            pileName: "North Yard 03",
            sessionLabel: "Walkaround in progress",
            referencesVisible: 1,
            referenceTarget: 4,
            perimeterCoverage: 0.84,
            stabilityScore: 0.86,
            activePrompt: "Pan until two tagged references share the frame.",
            captureChecks: [
                GuidedCaptureCheck(
                    title: "Reference visibility",
                    status: .needsAttention,
                    detail: "Only one tagged reference is visible.",
                    operatorAction: "Pan until two tagged references share the frame."
                ),
                GuidedCaptureCheck(
                    title: "Perimeter coverage",
                    status: .ready,
                    detail: "Coverage is already strong."
                ),
                GuidedCaptureCheck(
                    title: "Motion stability",
                    status: .ready,
                    detail: "Motion is steady enough for reconstruction."
                ),
            ]
        )

        XCTAssertFalse(content.isReadyToFinish)
        XCTAssertEqual(content.readinessSummary, "Needs more tagged references")
        XCTAssertEqual(
            content.checklistContent.primaryOperatorAction,
            "Pan until two tagged references share the frame."
        )
    }

    func testGuidedCaptureChecklistPrioritizesBlockedSceneFitBeforeOtherChecks() {
        let content = GuidedCaptureContent(
            pileName: "North Yard 03",
            sessionLabel: "Walkaround in progress",
            referencesVisible: 3,
            referenceTarget: 3,
            perimeterCoverage: 0.86,
            stabilityScore: 0.88,
            activePrompt: "Point back at the stockpile before finishing the lap.",
            captureChecks: [
                GuidedCaptureCheck(
                    title: "Scene fit",
                    status: .blocked,
                    detail: "Nearby equipment dominates the shot.",
                    operatorAction: "Point back at the stockpile before finishing the lap."
                ),
                GuidedCaptureCheck(
                    title: "Reference visibility",
                    status: .ready,
                    detail: "Three tagged references are visible together."
                ),
                GuidedCaptureCheck(
                    title: "Motion stability",
                    status: .ready,
                    detail: "Motion is steady enough for reconstruction."
                ),
            ]
        )

        XCTAssertFalse(content.isReadyToFinish)
        XCTAssertEqual(content.readinessSummary, "Fix blocked issues first")
        XCTAssertEqual(
            content.checklistContent.primaryOperatorAction,
            "Point back at the stockpile before finishing the lap."
        )
        XCTAssertEqual(content.checklistContent.highlightedItems.map(\.title), ["Scene fit"])
    }

    func testCaptureChecklistPrioritizesBlockedActionsFirst() {
        let checklist = CaptureChecklistContent(
            title: "Capture checklist",
            summary: "Field-ready guidance.",
            items: [
                GuidedCaptureCheck(
                    title: "Reference visibility",
                    status: .needsAttention,
                    detail: "Only one reference is visible.",
                    operatorAction: "Hold two references together."
                ),
                GuidedCaptureCheck(
                    title: "Toe coverage",
                    status: .blocked,
                    detail: "The far edge is missing.",
                    operatorAction: "Retake the far edge with the full toe visible."
                ),
                GuidedCaptureCheck(
                    title: "Motion stability",
                    status: .ready,
                    detail: "Movement is steady."
                ),
            ]
        )

        XCTAssertTrue(checklist.isBlocked)
        XCTAssertEqual(checklist.blockedCount, 1)
        XCTAssertEqual(checklist.primaryOperatorAction, "Retake the far edge with the full toe visible.")
        XCTAssertEqual(checklist.highlightedItems.map(\.title), ["Toe coverage"])
    }

    func testGuidedCaptureChecklistExposesNextOperatorAction() {
        let content = GuidedCaptureContent(
            pileName: "North Yard 03",
            sessionLabel: "Walkaround in progress",
            referencesVisible: 2,
            referenceTarget: 3,
            perimeterCoverage: 0.71,
            stabilityScore: 0.81,
            activePrompt: "Keep moving around the toe.",
            captureChecks: [
                GuidedCaptureCheck(
                    title: "Reference visibility",
                    status: .ready,
                    detail: "Two tagged references are visible."
                ),
                GuidedCaptureCheck(
                    title: "Perimeter coverage",
                    status: .needsAttention,
                    detail: "The last quarter of the toe is still missing.",
                    operatorAction: "Complete the last quarter of the perimeter before finishing."
                ),
            ]
        )

        XCTAssertEqual(content.checklistContent.primaryOperatorAction, "Complete the last quarter of the perimeter before finishing.")
        XCTAssertFalse(content.isReadyToFinish)
    }

    func testUploadProgressPreviewSeparatesUploadFromProcessing() {
        let uploading = UploadProgressContent.uploadingPreview
        let processing = UploadProgressContent.processingPreview
        let review = UploadProgressContent.reviewPreview
        let blocked = UploadProgressContent.blockedPreview

        XCTAssertEqual(uploading.phase, .uploading)
        XCTAssertEqual(uploading.uploadStatusLabel, "Uploading to server")
        XCTAssertEqual(
            uploading.uploadStatusDetail,
            "Uploading the recorded capture to the server. 35% transferred so far."
        )
        XCTAssertEqual(uploading.processingStatusLabel, "Waiting for upload")
        XCTAssertEqual(uploading.overallProgress, 0.1575, accuracy: 0.0001)
        XCTAssertFalse(uploading.canOpenResults)

        XCTAssertEqual(processing.phase, .processing)
        XCTAssertEqual(processing.uploadStatusLabel, "Upload complete")
        XCTAssertEqual(processing.processingStatusLabel, "Reconstructing stockpile geometry")
        XCTAssertEqual(processing.processingProgress, 0.58, accuracy: 0.0001)

        XCTAssertEqual(review.phase, .review)
        XCTAssertTrue(review.canOpenResults)
        XCTAssertEqual(review.statusTone, .warning)

        XCTAssertEqual(blocked.phase, .blocked)
        XCTAssertEqual(blocked.statusTone, .warning)
        XCTAssertNotNil(blocked.recaptureGuidance)
        XCTAssertFalse(blocked.canOpenResults)
    }

    func testAwaitingSelectionUsesLiveCaptureFirstLanguage() {
        let content = UploadProgressContent(
            transferState: .awaitingSelection,
            processingState: .idle,
            statusTone: .neutral,
            primaryMessage: "Waiting for a capture source."
        )

        XCTAssertEqual(content.uploadStatusLabel, "Waiting for capture")
        XCTAssertEqual(
            content.uploadStatusDetail,
            "Finish the live walkaround first, or keep a Files backup ready before upload starts."
        )
    }

    func testBlockedRecaptureGuidanceIncludesActionableSteps() {
        let guidance = RecaptureGuidanceContent.blockedPreview

        XCTAssertEqual(guidance.primaryActionTitle, "Retake capture")
        XCTAssertEqual(guidance.reasons.count, 2)
        XCTAssertEqual(guidance.steps.count, 3)
        XCTAssertEqual(guidance.primaryReason, "Only one tagged reference stayed visible through most of the walkaround.")
    }
}
