import XCTest
@testable import StockpileAppShell

final class StockpileAppShellTests: XCTestCase {
    func testNamespaceExists() {
        XCTAssertNotNil(StockpileAppShellNamespace.self)
    }

    @MainActor
    func testDemoStoreStartsOnReview() {
        let store = StockpileShellStore.demo

        XCTAssertEqual(store.selectedSection, .review)
        XCTAssertEqual(store.activeFacility, "QPMC North Yard")
        XCTAssertFalse(store.runs.isEmpty)
    }

    @MainActor
    func testOpenRunPushesRunDestination() throws {
        let store = StockpileShellStore.demo
        let run = try XCTUnwrap(store.featuredRun)

        store.openRun(run)

        XCTAssertEqual(store.path.last, .run(run.id))
    }

    @MainActor
    func testDemoStoreProvidesReviewQueue() {
        let store = StockpileShellStore.demo

        XCTAssertGreaterThanOrEqual(store.reviewQueueCount, 1)
        XCTAssertGreaterThanOrEqual(store.activeRunCount, 1)
    }
}
