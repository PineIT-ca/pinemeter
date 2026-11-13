import Foundation
import XCTest
@testable import Pinemeter

final class BrokerShippedTablePropertyTests: XCTestCase {
    private func liveScores() throws -> [(String, BrokerScoredRole)] {
        let url = try XCTUnwrap(BrokerPresetManifestTests.bundledManifestURL())
        let presets = try BrokerPresetManifest.decode(from: Data(contentsOf: url)).presets
        XCTAssertEqual(presets.count, 7)
        let now = BrokerFixture.now
        let reset = now.addingTimeInterval(96 * 3600)
        let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(
            session: 0, weekly: 0, sonnet: 0, fable: 0,
            weeklyResetAt: reset, sonnetResetAt: reset, fableResetAt: reset)],
            chatGPTRows: [.init(label: "Codex weekly", usedPercent: 0, resetAt: reset,
                windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
        let keys = ["claude:acct-primary:weekly", "claude:acct-primary:sonnet",
            "claude:acct-primary:fable", "chatgpt:Workspace A:Codex weekly"]
        return try presets.flatMap { preset in
            var policy = BrokerPolicy.bundledDefault
            policy.assignExactRules(preset.rules)
            XCTAssertEqual(policy.roles.count, 10, preset.name)
            XCTAssertEqual(Set(policy.scoring.roles.keys), Set(policy.roles.keys), preset.name)
            let demand = BrokerDemand(historyDays: 3, historySufficient: true,
                roles: policy.roles.mapValues { _ in 100 },
                pools: Dictionary(uniqueKeysWithValues: keys.map {
                    ($0, BrokerDemand.PoolDemand(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12))
                }))
            let prices = BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: demand, now: now)
            XCTAssertEqual(prices.count, 4, preset.name)
            XCTAssertTrue(prices.allSatisfy { $0.price == 500 }, preset.name)
            return try policy.roles.keys.sorted().map { role in
                (preset.name, try BrokerScoringEngine.scoredRole(role: role, policy: policy,
                    oracle: oracle, demand: demand, now: now))
            }
        }
    }

    func test_everyRoleUsesExplicitTables() throws {
        for (preset, role) in try liveScores() {
            XCTAssertFalse(role.derived, "\(preset)/\(role.role)")
            XCTAssertFalse(role.rows.isEmpty, "\(preset)/\(role.role)")
        }
    }

    func test_pricingIsActive() throws {
        for (preset, role) in try liveScores() {
            XCTAssertEqual(role.pricing, "active", "\(preset)/\(role.role)")
        }
    }

    func test_baseRowsAreEligibleExceptExecutionFallback() throws {
        for (preset, role) in try liveScores() {
            for row in role.rows {
                let context = "\(preset)/\(role.role)/\(row.candidate)"
                if role.role == "execution", row.candidate == "t3:pi/default" {
                    XCTAssertFalse(row.eligible, context)
                    XCTAssertEqual(row.quality, 0, context)
                    XCTAssertEqual(row.reason, "belowFloor", context)
                } else {
                    XCTAssertTrue(row.eligible, context)
                }
            }
        }
    }

    func test_neutralPricesKeepEveryRowPosition() throws {
        for (preset, role) in try liveScores() {
            for row in role.rows {
                XCTAssertEqual(row.position, row.neutralPosition, "\(preset)/\(role.role)/\(row.candidate)")
            }
        }
    }

    func test_neutralPricesNeverRaiseEffort() throws {
        for (preset, role) in try liveScores() {
            for row in role.rows {
                XCTAssertNil(row.raise, "\(preset)/\(role.role)/\(row.candidate)")
            }
        }
    }
}
