import Foundation
import XCTest
@testable import Pinemeter

/// Issue 291: usage-lane keys are exact candidate ids, so a lane saved for an
/// older Fable model must still gate the model the chains now name.
final class FableLaneFamilyTests: XCTestCase {
    private let now = BrokerFixture.now
    private let primary = BrokerUsageLane.claudeAccount(accountId: "acct-primary", labelContains: nil, isPrimary: true)

    private func policy(lanes: [String: BrokerUsageLane]) -> BrokerPolicy {
        var p = BrokerSettings.default.policy
        p.usageLanes = lanes
        return p
    }

    func testOlderFableLaneResolvesForNewerModels() {
        let p = policy(lanes: ["t3/claude-fable-5": primary, "t3:inst-a/claude-fable-5": primary])
        for model in ["claude-fable-5", "claude-fable-5-1", "claude-fable-5-2"] {
            XCTAssertEqual(p.usageLane(for: BrokerCandidate(route: .t3, model: model)), primary, model)
            XCTAssertEqual(p.usageLane(for: BrokerCandidate(route: .t3, instance: "inst-a", model: model)), primary, model)
        }
        XCTAssertNil(p.usageLane(for: BrokerCandidate(route: .t3, instance: "inst-b", model: "claude-fable-5-1")))
    }

    func testResolvedLaneAppliesQuotaCap() throws {
        let p = policy(lanes: ["t3:inst-a/claude-fable-5": primary])
        let candidate = BrokerCandidate(route: .t3, instance: "inst-a", model: "claude-fable-5-1")
        let over = BrokerFixture.oracle(accounts: [BrokerFixture.account(weekly: 20, fable: 99)])
        let verdict = try XCTUnwrap(BrokerEngine.laneVerdict(for: candidate, policy: p, oracle: over, now: now))
        XCTAssertFalse(verdict.available)
    }

    func testExactKeyWinsAndNothingIsRewritten() {
        let exact = BrokerUsageLane.claudeAccount(accountId: "acct-other", labelContains: nil, isPrimary: nil)
        let lanes: [String: BrokerUsageLane] = ["t3/claude-fable-5": primary, "t3/claude-fable-5-1": exact]
        let p = policy(lanes: lanes)
        XCTAssertEqual(p.usageLane(for: BrokerCandidate(route: .t3, model: "claude-fable-5-1")), exact)
        XCTAssertEqual(p.usageLane(for: BrokerCandidate(route: .t3, model: "claude-fable-5-2")), exact)
        XCTAssertEqual(p.usageLanes, lanes)
    }

    func testNonFableLanesAreUntouched() {
        let p = policy(lanes: ["t3/claude-fable-5": primary])
        XCTAssertNil(p.usageLane(for: BrokerCandidate(route: .t3, model: "claude-opus-5")))
        XCTAssertNil(p.usageLane(for: BrokerCandidate(route: .codex, model: "claude-fable-5-1")))
    }

    /// Family boundary: `claude-fable-50` is not a Fable 5 model in either direction.
    func testFamilyMatchStopsAtTheModelBoundary() {
        let p = policy(lanes: ["t3/claude-fable-5": primary])
        XCTAssertNil(p.usageLane(for: BrokerCandidate(route: .t3, model: "claude-fable-50")))
        let q = policy(lanes: ["t3/claude-fable-50": primary])
        XCTAssertNil(q.usageLane(for: BrokerCandidate(route: .t3, model: "claude-fable-5-2")))
    }

    /// Several family lanes: the greatest key wins, so the choice is stable.
    func testGreatestFamilyKeyWins() {
        let other = BrokerUsageLane.claudeAccount(accountId: "acct-other", labelContains: nil, isPrimary: false)
        let p = policy(lanes: ["t3/claude-fable-5": primary, "t3/claude-fable-5-2": other])
        XCTAssertEqual(p.usageLane(for: BrokerCandidate(route: .t3, model: "claude-fable-5-1")), other)
    }

    func testOldSavedSettingsDecodeAndStillResolve() throws {
        var saved = BrokerSettings.default
        saved.policy.usageLanes = ["t3/claude-fable-5": primary]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        object.removeValue(forKey: "applied_routing_migrations")
        let settings = try JSONDecoder().decode(BrokerSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(settings.policy.usageLanes.keys.sorted(), ["t3/claude-fable-5"])
        XCTAssertEqual(settings.policy.usageLane(for: BrokerCandidate(route: .t3, model: "claude-fable-5-2")), primary)
    }
}
