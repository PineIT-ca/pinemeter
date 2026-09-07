//
//  MenuBarIconRendererTests.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import XCTest
@testable import Pinemeter

@MainActor
final class MenuBarIconRendererTests: XCTestCase {
    func test_quotaBarColorRolesAndNearLimitThreshold() {
        let fiveHour = MenuBarQuotaBar(label: "Claude 5h", percentage: 89, status: .critical, heading: "5h")
        let weekly = MenuBarQuotaBar(label: "Claude weekly", percentage: 90, status: .critical, heading: "Weekly")
        let special = MenuBarQuotaBar(label: "Claude Fable", percentage: 20, status: .safe, heading: "Fable")

        XCTAssertEqual(fiveHour.kind, .fiveHour)
        XCTAssertEqual(weekly.kind, .weekly)
        XCTAssertEqual(special.kind, .special)
        XCTAssertFalse(fiveHour.isNearLimit)
        XCTAssertTrue(weekly.isNearLimit)
        XCTAssertEqual(fiveHour.meterColor, .cyan)
        XCTAssertEqual(weekly.meterColor, .red)
        XCTAssertEqual(special.meterColor, .yellow)
    }

    func test_colorSchemesProvideThreeRoleColorsAndPreserveCriticalRed() {
        XCTAssertEqual(MenuBarColorScheme.allCases.count, 6)

        for scheme in MenuBarColorScheme.allCases {
            XCTAssertEqual(scheme.colors.count, 3)
            XCTAssertEqual(Set(scheme.colors).count, 3)

            let nearLimit = MenuBarQuotaBar(
                label: "Claude 5h",
                percentage: 90,
                status: .critical,
                heading: "5h",
                colorScheme: scheme
            )
            XCTAssertEqual(nearLimit.meterColor, .red)
        }
    }

    func test_quotaBarsGroupAdjacentMetersBySubscriptionIdentity() {
        func bar(_ heading: String, accountID: String = "work") -> MenuBarQuotaBar {
            MenuBarQuotaBar(
                label: "Work \(heading)",
                percentage: 20,
                status: .safe,
                heading: heading,
                owner: "Work",
                renameTarget: .claudeAccount(id: accountID)
            )
        }

        let bars = [
            bar("5h"),
            bar("Weekly"),
            bar("Fable"),
            bar("5h", accountID: "personal"),
        ]

        XCTAssertEqual(MenuBarQuotaBar.groupedByOwner(bars).map(\.count), [3, 1])
    }

    func test_popoverWidthStaysConsistentAcrossAccountCounts() {
        func bar(_ heading: String) -> MenuBarQuotaBar {
            MenuBarQuotaBar(
                label: "Claude \(heading)",
                percentage: 20,
                status: .safe,
                heading: heading,
                owner: "Claude"
            )
        }

        let twoBars = [bar("5h"), bar("Weekly")]
        let threeBars = twoBars + [bar("Fable")]
        let nineBars = (1...9).map { bar("Quota \($0)") }

        XCTAssertEqual(QuotaChartLayout.popoverWidth(for: twoBars), 400)
        XCTAssertEqual(QuotaChartLayout.popoverWidth(for: threeBars), 400)
        XCTAssertEqual(QuotaChartLayout.popoverWidth(for: nineBars), 400)
        XCTAssertEqual(QuotaChartLayout.popoverWidth(for: []), 400)
        XCTAssertEqual(QuotaChartLayout.popoverWidth(for: (1...40).map { bar("Quota \($0)") }), 400)
    }

    func test_usageFreshnessPreservesThresholdAndHandlesMissingOrFutureDates() {
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertFalse(UsageFreshness.isStale(lastUpdated: now.addingTimeInterval(-1200), now: now))
        XCTAssertTrue(UsageFreshness.isStale(lastUpdated: now.addingTimeInterval(-1201), now: now))
        XCTAssertTrue(UsageFreshness.isStale(lastUpdated: nil, now: now))
        XCTAssertFalse(UsageFreshness.isStale(lastUpdated: now.addingTimeInterval(60), now: now))
        XCTAssertEqual(UsageFreshness.ageDescription(lastUpdated: now.addingTimeInterval(60), now: now), "just now")
        XCTAssertEqual(UsageFreshness.ageDescription(lastUpdated: now.addingTimeInterval(-3600), now: now), "1 hr ago")
    }

    func test_menuBarIconRendersMeterStyle() {
        let renderer = MenuBarIconRenderer()

        let image = renderer.render(
            percentage: TestConstants.sessionPercentage,
            status: .safe,
            isLoading: false,
            isStale: false,
            iconStyle: .dualBar,
            weeklyPercentage: TestConstants.weeklyPercentage
        )

        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func test_menuBarIconRendersWhenLoadingOrStale() {
        let renderer = MenuBarIconRenderer()

        let loadingImage = renderer.render(
            percentage: TestConstants.sessionPercentage,
            status: .safe,
            isLoading: true,
            isStale: false,
            iconStyle: .dualBar,
            weeklyPercentage: TestConstants.weeklyPercentage
        )

        let staleImage = renderer.render(
            percentage: TestConstants.sessionPercentage,
            status: .safe,
            isLoading: false,
            isStale: true,
            iconStyle: .dualBar,
            weeklyPercentage: TestConstants.weeklyPercentage
        )

        XCTAssertGreaterThan(loadingImage.size.width, 0)
        XCTAssertGreaterThan(loadingImage.size.height, 0)
        XCTAssertGreaterThan(staleImage.size.width, 0)
        XCTAssertGreaterThan(staleImage.size.height, 0)
    }

    func test_menuBarIconIsRenderedAsNonTemplateImage() {
        let renderer = MenuBarIconRenderer()

        let image = renderer.render(
            percentage: TestConstants.sessionPercentage,
            status: .safe,
            isLoading: false,
            isStale: false,
            iconStyle: .dualBar,
            weeklyPercentage: TestConstants.weeklyPercentage
        )

        XCTAssertFalse(image.isTemplate)
    }

    func test_menuBarIconIsRenderedAsTemplateImageWhenMonochromeModeSelected() {
        let renderer = MenuBarIconRenderer()

        let image = renderer.render(
            percentage: TestConstants.sessionPercentage,
            status: .safe,
            isLoading: false,
            isStale: false,
            iconStyle: .dualBar,
            weeklyPercentage: TestConstants.weeklyPercentage,
            isColored: false
        )

        XCTAssertTrue(image.isTemplate)
    }

    func test_menuBarIconIsRenderedAsNonTemplateImageWhenColorModeSelected() {
        let renderer = MenuBarIconRenderer()

        let image = renderer.render(
            percentage: TestConstants.sessionPercentage,
            status: .safe,
            isLoading: false,
            isStale: false,
            iconStyle: .dualBar,
            weeklyPercentage: TestConstants.weeklyPercentage,
            isColored: true
        )

        XCTAssertFalse(image.isTemplate)
    }
}
