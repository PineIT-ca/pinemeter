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

    func test_isAtRisk_whenWindowJustOpened_returnsFalse() {
        // 6.6 hours into a 7-day weekly window is 3.93% elapsed. 5% usage
        // scores 1.27 on the raw ratio, over the 1.2 threshold. Against the
        // clamped 0.1 divisor it scores 0.5: a sustainable start to the week.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let weeklyWindow: TimeInterval = 7 * 24 * 60 * 60
        let resetAt = now.addingTimeInterval(weeklyWindow - 6.6 * 60 * 60)

        XCTAssertFalse(
            UsageLimit(utilization: 5, resetAt: resetAt)
                .isAtRisk(windowDuration: weeklyWindow, now: now)
        )
    }

    func test_isAtRisk_belowTheFloor_judgesAgainstTheClampedDivisorNotTheRealOne() {
        // 10% of the 5-hour session window is 30 minutes, an exact number of
        // seconds, so the boundary is testable without float slop. At 15
        // minutes elapsed the real divisor is 0.05 and 11% usage scores 2.2 on
        // the raw ratio; against the clamped 0.1 divisor it scores 1.1 and is
        // correctly judged sustainable. The verdict matches what the same usage
        // gets at the floor itself, so the gate does not jump at the boundary.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let quarterHourIn = now.addingTimeInterval(sessionWindow - 15 * 60)
        let atFloor = now.addingTimeInterval(sessionWindow - 30 * 60)

        for resetAt in [quarterHourIn, atFloor] {
            XCTAssertFalse(
                UsageLimit(utilization: 11, resetAt: resetAt)
                    .isAtRisk(windowDuration: sessionWindow, now: now)
            )
        }
    }

    func test_isAtRisk_belowTheFloor_stillCatchesAnEarlyRunaway() {
        // Clamping is not abstaining. 13% of a session window burned in its
        // first 15 minutes scores 1.3 against the clamped divisor and is
        // gated, where returning false outright would have missed it.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let quarterHourIn = now.addingTimeInterval(sessionWindow - 15 * 60)

        XCTAssertTrue(
            UsageLimit(utilization: 13, resetAt: quarterHourIn)
                .isAtRisk(windowDuration: sessionWindow, now: now)
        )
    }

    func test_isAtRisk_pastTheFloor_stillCatchesAnUnsustainableWeeklyBurn() {
        // 17 hours into the weekly window is past the floor, so the ratio
        // counts again: 5% is sustainable, 13% is not.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let weeklyWindow: TimeInterval = 7 * 24 * 60 * 60
        let resetAt = now.addingTimeInterval(weeklyWindow - 17 * 60 * 60)

        XCTAssertFalse(
            UsageLimit(utilization: 5, resetAt: resetAt)
                .isAtRisk(windowDuration: weeklyWindow, now: now)
        )
        XCTAssertTrue(
            UsageLimit(utilization: 13, resetAt: resetAt)
                .isAtRisk(windowDuration: weeklyWindow, now: now)
        )
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
            "in 46m"
        )
    }

    func test_resetDescription_whenUnderOneDay_preservesMinutes() {
        XCTAssertEqual(
            UsageLimit.resetDescription(for: 3.1 * 60 * 60),
            "in 3h 6m"
        )
    }

    func test_resetDescription_whenOverOneDay_showsDaysAndHours() {
        XCTAssertEqual(
            UsageLimit.resetDescription(for: 40 * 60 * 60),
            "in 1d 16h"
        )
    }

    func test_resetDescription_whenExactlyWholeDays_omitsZeroHours() {
        XCTAssertEqual(
            UsageLimit.resetDescription(for: 2 * 24 * 60 * 60),
            "in 2d"
        )
    }

    func test_resetDescription_compactUnitsAndMinuteRollover() {
        let cases: [(TimeInterval, String)] = [
            (4 * 86400 + 6 * 3600 + 15 * 60, "in 4d 6h 15m"),
            (86400 + 60, "in 1d 1m"),
            (3599, "in 1h"),
            (86399, "in 1d"),
            (1, "in 1m"),
            (0, "now")
        ]
        for (remaining, expected) in cases {
            XCTAssertEqual(UsageLimit.resetDescription(for: remaining), expected)
        }
    }

    func test_resetDescription_whenPastResetTime_showsNow() {
        XCTAssertEqual(
            UsageLimit.resetDescription(for: -60),
            "now"
        )
    }
}
