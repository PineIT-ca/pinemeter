//
//  UsageLimitRiskTests.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-16.
//

import XCTest
@testable import Pinemeter

final class UsageLimitRiskTests: XCTestCase {

    private let sessionWindow: TimeInterval = 5 * 60 * 60 // 5 hours

    func testFixedClockPaceThreshold() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resetAt = now.addingTimeInterval(sessionWindow / 2)

        XCTAssertFalse(
            UsageLimit(utilization: 60, resetAt: resetAt)
                .isAtRisk(windowDuration: sessionWindow, now: now)
        )
        XCTAssertTrue(
            UsageLimit(utilization: 60.000_001, resetAt: resetAt)
                .isAtRisk(windowDuration: sessionWindow, now: now)
        )
    }

    func testInvalidResetInputsFailOpen() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let halfwayReset = now.addingTimeInterval(sessionWindow / 2)

        for utilization in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(
                UsageLimit(utilization: utilization, resetAt: halfwayReset)
                    .isAtRisk(windowDuration: sessionWindow, now: now)
            )
        }
        for resetAt in [
            now,
            now.addingTimeInterval(-1),
            now.addingTimeInterval(sessionWindow + 1),
        ] {
            XCTAssertFalse(
                UsageLimit(utilization: 80, resetAt: resetAt)
                    .isAtRisk(windowDuration: sessionWindow, now: now)
            )
        }
        for duration in [0, -1, Double.nan, .infinity] {
            XCTAssertFalse(
                UsageLimit(utilization: 80, resetAt: halfwayReset)
                    .isAtRisk(windowDuration: duration, now: now)
            )
        }
    }

    func test_isAtRisk_whenUsingFasterThanSustainable_returnsTrue() {
        // 25% of time elapsed, 50% usage = ratio of 2.0 (> 1.2 threshold)
        let resetAt = Date().addingTimeInterval(3.75 * 60 * 60) // 3.75 hours remaining
        let usageLimit = UsageLimit(utilization: 50.0, resetAt: resetAt)

        XCTAssertTrue(usageLimit.isAtRisk(windowDuration: sessionWindow))
    }

    func test_isAtRisk_whenUsingAtSustainablePace_returnsFalse() {
        // 50% of time elapsed, 50% usage = ratio of 1.0 (< 1.2 threshold)
        let resetAt = Date().addingTimeInterval(2.5 * 60 * 60) // 2.5 hours remaining
        let usageLimit = UsageLimit(utilization: 50.0, resetAt: resetAt)

        XCTAssertFalse(usageLimit.isAtRisk(windowDuration: sessionWindow))
    }

    func test_isAtRisk_whenSlightlyAboveThreshold_returnsTrue() {
        // 50% of time elapsed, 65% usage = ratio of 1.3 (> 1.2 threshold)
        let resetAt = Date().addingTimeInterval(2.5 * 60 * 60) // 2.5 hours remaining
        let usageLimit = UsageLimit(utilization: 65.0, resetAt: resetAt)

        XCTAssertTrue(usageLimit.isAtRisk(windowDuration: sessionWindow))
    }

    func test_isAtRisk_whenPastResetTime_returnsFalse() {
        let resetAt = Date().addingTimeInterval(-60) // Already past
        let usageLimit = UsageLimit(utilization: 50.0, resetAt: resetAt)

        XCTAssertFalse(usageLimit.isAtRisk(windowDuration: sessionWindow))
    }

    func test_isAtRisk_whenBeforeWindowStart_returnsFalse() {
        // Reset is more than 5 hours away (window hasn't started yet)
        let resetAt = Date().addingTimeInterval(sessionWindow + 60)
        let usageLimit = UsageLimit(utilization: 50.0, resetAt: resetAt)

        XCTAssertFalse(usageLimit.isAtRisk(windowDuration: sessionWindow))
    }

    func test_resetDescription_whenUnderOneHour_showsRoundedUpMinutes() {
        XCTAssertEqual(
            UsageLimit.resetDescription(for: 45.2 * 60),
            "in 46 minutes"
        )
    }

    func test_resetDescription_whenUnderOneDay_showsRoundedUpHours() {
        XCTAssertEqual(
            UsageLimit.resetDescription(for: 3.1 * 60 * 60),
            "in 4 hours"
        )
    }

    func test_resetDescription_whenOverOneDay_showsDaysAndHours() {
        XCTAssertEqual(
            UsageLimit.resetDescription(for: 40 * 60 * 60),
            "in 1 day 16 hours"
        )
    }

    func test_resetDescription_whenExactlyWholeDays_omitsZeroHours() {
        XCTAssertEqual(
            UsageLimit.resetDescription(for: 2 * 24 * 60 * 60),
            "in 2 days"
        )
    }

    func test_resetDescription_whenPastResetTime_showsNow() {
        XCTAssertEqual(
            UsageLimit.resetDescription(for: -60),
            "now"
        )
    }
}
