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
