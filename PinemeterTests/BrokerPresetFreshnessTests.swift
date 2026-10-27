import XCTest
@testable import Pinemeter

final class BrokerPresetFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    func test_exactlyFreezeWarningDaysHasNoWarning() {
        XCTAssertNil(BrokerPresetFreshness.warning(
            issuedAt: now.addingTimeInterval(-Double(BrokerPresetDistribution.freezeWarningDays) * day), now: now))
    }

    func test_oneSecondPastThresholdUsesWholeDays() {
        XCTAssertEqual(BrokerPresetFreshness.warning(
            issuedAt: now.addingTimeInterval(-14 * day - 1), now: now),
            "Official presets were last published 14 days ago. Updates may be blocked; current presets stay in use.")
    }

    func test_thirtyDaysUsesWholeDays() {
        XCTAssertEqual(BrokerPresetFreshness.warning(issuedAt: now.addingTimeInterval(-30 * day), now: now),
            "Official presets were last published 30 days ago. Updates may be blocked; current presets stay in use.")
    }

    func test_futureIssueHasNoWarning() {
        XCTAssertNil(BrokerPresetFreshness.warning(issuedAt: now.addingTimeInterval(day), now: now))
    }

    func test_missingVerifiedIssueHasNoWarning() {
        XCTAssertNil(BrokerPresetFreshness.warning(issuedAt: nil, now: now))
    }
}
