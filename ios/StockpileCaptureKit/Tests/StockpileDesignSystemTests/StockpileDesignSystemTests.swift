import SwiftUI
import XCTest
@testable import StockpileDesignSystem

final class StockpileDesignSystemTests: XCTestCase {
    func testNamespaceExists() {
        XCTAssertNotNil(StockpileDesignSystemNamespace.self)
    }

    func testPaletteProvidesDaylightReadableFoundationColors() {
        XCTAssertEqual(
            StockpilePalette.canvas,
            StockpileColorValue(red: 0.97, green: 0.95, blue: 0.92)
        )
        XCTAssertEqual(
            StockpilePalette.surface,
            StockpileColorValue(red: 1.0, green: 1.0, blue: 1.0)
        )
        XCTAssertEqual(
            StockpilePalette.ink,
            StockpileColorValue(red: 0.12, green: 0.13, blue: 0.15)
        )
        XCTAssertEqual(
            StockpilePalette.accent,
            StockpileColorValue(red: 0.49, green: 0.19, blue: 0.21)
        )
    }

    func testSpacingScaleRemainsOrdered() {
        XCTAssertEqual(StockpileSpacing.xxxSmall, 4)
        XCTAssertEqual(StockpileSpacing.medium, 16)
        XCTAssertEqual(StockpileSpacing.xxxLarge, 48)
        XCTAssertLessThan(StockpileSpacing.xSmall, StockpileSpacing.medium)
        XCTAssertLessThan(StockpileSpacing.large, StockpileSpacing.xxxLarge)
    }

    func testTypographyRolesFavorTrustAndHierarchy() {
        XCTAssertEqual(StockpileTypography.hero.size, 34)
        XCTAssertEqual(StockpileTypography.sectionTitle.weight, .semibold)
        XCTAssertEqual(StockpileTypography.body.size, 17)
        XCTAssertEqual(StockpileTypography.caption.size, 13)
        XCTAssertGreaterThan(StockpileTypography.metric.size, StockpileTypography.body.size)
    }

    func testStatusThemesStayDistinctAndSemantic() {
        let success = StockpileStatusTone.success.theme
        let caution = StockpileStatusTone.caution.theme
        let critical = StockpileStatusTone.critical.theme

        XCTAssertEqual(success.accent, StockpilePalette.success)
        XCTAssertEqual(caution.accent, StockpilePalette.caution)
        XCTAssertEqual(critical.accent, StockpilePalette.critical)
        XCTAssertNotEqual(success.background, caution.background)
        XCTAssertNotEqual(caution.background, critical.background)
    }

    func testPrimaryButtonMetricsMeetTouchTargetRequirements() {
        let primary = StockpileButtonRole.primary.tokens
        let secondary = StockpileButtonRole.secondary.tokens

        XCTAssertEqual(primary.minimumHeight, 56)
        XCTAssertEqual(primary.cornerRadius, StockpileCornerRadius.button)
        XCTAssertEqual(primary.background, StockpilePalette.accent)
        XCTAssertNotEqual(primary.background, secondary.background)
    }

    func testCardAppearancesExposeExpectedSurfaceTreatment() {
        let elevated = StockpileCardAppearance.elevated.tokens
        let outlined = StockpileCardAppearance.outlined.tokens

        XCTAssertEqual(elevated.cornerRadius, StockpileCornerRadius.card)
        XCTAssertGreaterThan(elevated.shadow.opacity, 0)
        XCTAssertEqual(outlined.shadow.opacity, 0)
        XCTAssertNotEqual(elevated.background, outlined.background)
    }

    func testReusableSwiftUIViewTypesAreAvailable() {
        let card = StockpileCard {
            Text("Stockpile summary")
        }
        let badge = StockpileBadge("Review only", tone: .caution)
        let button = Button("Continue") {}
            .buttonStyle(StockpileActionButtonStyle(role: .primary))

        XCTAssertNotNil(card)
        XCTAssertNotNil(badge)
        XCTAssertNotNil(button)
    }
}
