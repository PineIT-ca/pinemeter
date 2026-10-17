import Foundation
import XCTest
@testable import Pinemeter

final class GoldenScoringFixtureTests: XCTestCase {
    struct Input: Codable {
        var schema = 1
        var now: Date
        var policy: BrokerPolicy
        var oracle: GoldenOracle
        var demand: BrokerDemand?
        var roles: [String]

        enum CodingKeys: String, CodingKey { case schema, now, policy, oracle, demand, roles }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schema, forKey: .schema)
            try c.encode(now, forKey: .now)
            try c.encode(policy, forKey: .policy)
            try c.encode(oracle, forKey: .oracle)
            try c.encode(demand, forKey: .demand)
            try c.encode(roles, forKey: .roles)
        }
        func scores() throws -> [BrokerScoredRole] {
            let snapshot = try oracle.snapshot()
            return try roles.map { try BrokerScoringEngine.scoredRole(role: $0, policy: policy,
                oracle: snapshot, demand: demand, now: now) }
        }
    }

    static func basic() -> Input {
        var (policy, oracle, demand) = BrokerScoringTests.scoringWorld()
        policy.scoring.roles["review"] = .init(floor: 500, quality: [
            "claude-opus-5-5": ["_default": 512], "gpt-6-astra": ["_default": 496]])
        return .init(now: BrokerFixture.now, policy: policy, oracle: GoldenOracle(oracle), demand: demand, roles: ["review"])
    }

    nonisolated(unsafe) private static var wiped = false
    private func write(_ name: String, input: Input, scores: [BrokerScoredRole]) throws {
        guard GoldenFixture.exportDirectory() != nil else { return }
        let directory = GoldenFixture.goldenDirectory.appendingPathComponent("scoring")
        if !Self.wiped { Self.wiped = true; try GoldenFixture.wipe(directory) }
        try GoldenFixture.write(try GoldenFixture.policyEncoder().encode(input), to: directory, named: name + ".input.json")
        try GoldenFixture.write(try GoldenFixture.canonicalEncoder().encode(scores), to: directory, named: name + ".scores.json")
    }

    func test_shippedPresets_neutralOrderAndEligibility() throws {
        let presets = try BrokerPresetManifest.decode(from: Data(contentsOf: XCTUnwrap(
            BrokerPresetManifestTests.bundledManifestURL()))).presets
        let slugs = ["Balanced": "balanced", "Conserve Quota": "conserve-quota",
            "Max Quality": "max-quality", "Offload Execution": "offload-execution",
            "Balanced (No Opus)": "balanced-no-opus", "Claude Only": "claude-only",
            "Balanced (No Fable)": "balanced-no-fable"]
        XCTAssertEqual(Set(presets.map(\.name)), Set(slugs.keys))
        let now = BrokerFixture.now
        let reset = now.addingTimeInterval(96 * 3600)
        let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(
            session: 0, weekly: 0, sonnet: 0, fable: 0,
            weeklyResetAt: reset, sonnetResetAt: reset, fableResetAt: reset)],
            chatGPTRows: [.init(label: "Codex weekly", usedPercent: 0, resetAt: reset,
                windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
        let keys = ["claude:acct-primary:weekly", "claude:acct-primary:sonnet",
            "claude:acct-primary:fable", "chatgpt:Workspace A:Codex weekly"]
        for preset in presets {
            var policy = BrokerPolicy.bundledDefault
            policy.assignExactRules(preset.rules)
            let demand = BrokerDemand(historyDays: 3, historySufficient: true,
                roles: policy.roles.mapValues { _ in 100 },
                pools: Dictionary(uniqueKeysWithValues: keys.map {
                    ($0, BrokerDemand.PoolDemand(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12))
                }))
            let prices = BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: demand, now: now)
            XCTAssertEqual(prices.count, 4, preset.name)
            XCTAssertTrue(prices.allSatisfy { $0.price == 500 }, preset.name)
            let input = Input(now: now, policy: policy, oracle: GoldenOracle(oracle),
                demand: demand, roles: policy.roles.keys.sorted())
            let scores = try input.scores()
            XCTAssertEqual(scores.count, 10, preset.name)
            for role in scores {
                XCTAssertFalse(role.derived)
                XCTAssertEqual(role.pricing, "active")
                XCTAssertFalse(role.rows.isEmpty)
                for row in role.rows {
                    if row.candidate == "t3:pi/default" {
                        XCTAssertFalse(row.eligible)
                        XCTAssertEqual(row.quality, 0)
                        XCTAssertEqual(row.reason, "belowFloor")
                    } else {
                        XCTAssertTrue(row.eligible, "\(preset.name)/\(role.role)/\(row.candidate)")
                    }
                    XCTAssertEqual(row.position, row.neutralPosition)
                    XCTAssertNil(row.raise)
                }
            }
            try write("shipped-" + XCTUnwrap(slugs[preset.name]), input: input, scores: scores)
        }
    }

    func test_reviewFloorBlocksMove() throws {
        let input = Self.basic()
        let scores = try input.scores()
        let rows = try XCTUnwrap(scores.first).rows
        XCTAssertEqual(rows.map(\.candidate), ["native/claude-opus-5-5", "codex/gpt-6-astra"])
        XCTAssertEqual(rows.map(\.position), [1, 2])
        XCTAssertEqual(rows.map(\.eligible), [true, false])
        XCTAssertEqual(rows[1].reason, "belowFloor")
        try write("review-floor-blocks-move", input: input, scores: scores)
    }
    static func vectors() -> [(String, Input)] {
        var cases: [(String, Input)] = [("review-floor-blocks-move", basic())]
        var input = basic()
        input.policy.scoring.roles["review"]!.floor = 496
        cases.append(("floor-exact-eligible", input))
        input.policy.scoring.roles["review"]!.floor = 497
        cases.append(("floor-one-below", input))
        input.policy.scoring.roles["review"]!.floor = nil
        input.policy.scoring.roles["review"]!.latencyLimit = 50
        input.policy.scoring.latency = ["claude-opus-5-5": ["_default": 20], "gpt-6-astra": ["_default": 50]]
        cases.append(("latency-at-limit", input))
        input.policy.scoring.latency["gpt-6-astra"]!["_default"] = 51
        cases.append(("latency-one-over", input))
        input.policy.scoring.latency.removeValue(forKey: "gpt-6-astra")
        cases.append(("latency-unknown-under-limit", input))
        input.policy.scoring.roles["review"]!.latencyWeight = 1
        input.policy.scoring.latency = ["claude-opus-5-5": ["_default": 10], "gpt-6-astra": ["_default": 1]]
        cases.append(("latency-weight", input))
        input = basic(); input.policy.scoring.roles["review"]!.floor = nil
        input.policy.scoring.roles["review"]!.quality.removeValue(forKey: "gpt-6-astra")
        cases.append(("unknown-estimate-price-blind", input))
        input = basic(); input.policy.scoring.roles["review"]!.quality.removeValue(forKey: "claude-opus-5-5")
        cases.append(("leading-unknown-model", input))
        input.policy.scoring.roles["review"] = .init()
        cases.append(("empty-explicit-table", input))
        input = basic(); input.policy.scoring.roles["review"]!.floor = nil
        input.policy.roles["review"] = [
            .init(route: .auto, model: "claude-opus-5-5", effort: .high),
            .init(route: .auto, model: "gpt-6-astra"),
            .init(route: .auto, model: "claude-opus-5-5", effort: .low)]
        input.policy.scoring.roles["review"]!.quality["claude-opus-5-5"] = ["high": 512, "low": 100]
        cases.append(("chain-duplicate-model", input))
        input = basic()
        let reset = input.now.addingTimeInterval(96 * 3600)
        input.oracle = GoldenOracle(BrokerFixture.oracle(accounts: [
            BrokerFixture.account(label: "Account A", weekly: 0, weeklyResetAt: reset)],
            chatGPTRows: [.init(label: "Weekly", usedPercent: 0, resetAt: reset,
                windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true))
        cases.append(("neutral-equal-levels", input))
        input = basic(); input.demand = nil
        cases.append(("pricing-off", input))
        input = basic(); input.policy.thresholds.preferExpiringQuota = false
        cases.append(("pricing-disabled", input))
        input = basic(); input.demand!.historySufficient = false; input.demand!.historyDays = 2
        cases.append(("short-history-unconfident", input))
        input = basic(); input.policy.scoring = .empty
        input.policy.equalQuality = ["review": [["claude-opus-5-5", "gpt-6-astra"]]]
        cases.append(("derived-with-groups", input))
        input = basic()
        input.policy.roles["review"] = BrokerFixture.candidates(["native/claude-opus-5-5", "t3:alpha/claude-opus-5-5"])
        input.policy.scoring.roles["review"]!.quality.removeValue(forKey: "gpt-6-astra")
        input.policy.t3Instances = [.init(id: "alpha", name: "Alpha", boundAccountId: "acct-secondary")]
        input.oracle = GoldenOracle(BrokerFixture.oracle(accounts: [
            BrokerFixture.account(label: "Account A", weekly: 20, weeklyResetAt: input.now.addingTimeInterval(10 * 3600)),
            BrokerFixture.account(id: "acct-secondary", label: "Account B", isPrimary: false,
                weekly: 10, weeklyResetAt: input.now.addingTimeInterval(20 * 3600))]))
        input.demand!.pools["claude:acct-primary:weekly"] = .init(rateMilli: 10000, windowDecisions: 6, ledgerDecisions: 12)
        input.demand!.pools["claude:acct-secondary:weekly"] = .init(rateMilli: 0, windowDecisions: 6, ledgerDecisions: 12)
        cases.append(("same-model-routes-by-level", input))
        for (name, world) in [
            ("raise-targets", BrokerScoringTests.raiseWorld()),
            ("raise-blocked-by-limit", BrokerScoringTests.limitedRaiseWorld()),
            ("raise-from-default", BrokerScoringTests.defaultRaiseWorld()),
            ("raise-unsupported-level", BrokerScoringTests.supportedRaiseWorld())] {
            cases.append((name, .init(now: BrokerFixture.now, policy: world.0,
                oracle: GoldenOracle(world.1), demand: world.2, roles: ["review"])))
        }
        return cases
    }

    func test_vectorEdges() throws {
        for (name, input) in Self.vectors() where name != "review-floor-blocks-move" {
            let scores = try input.scores()
            let role = try XCTUnwrap(scores.first)
            let rows = role.rows
            let astra = rows.first { $0.model == "gpt-6-astra" }
            switch name {
            case "floor-exact-eligible":
                XCTAssertEqual(astra?.effective, role.floor); XCTAssertEqual(astra?.eligible, true)
                XCTAssertEqual(astra?.position, 1)
            case "floor-one-below":
                XCTAssertEqual(astra?.effective, 496); XCTAssertEqual(astra?.reason, "belowFloor")
            case "latency-at-limit":
                XCTAssertEqual(astra?.latency, role.latencyLimit); XCTAssertEqual(astra?.eligible, true)
            case "latency-one-over":
                XCTAssertEqual(astra?.latency, 51); XCTAssertEqual(astra?.reason, "overLatencyLimit")
            case "latency-unknown-under-limit":
                XCTAssertNil(astra?.latency); XCTAssertTrue(rows.allSatisfy(\.eligible))
            case "latency-weight":
                XCTAssertEqual(rows.first { $0.model == "claude-opus-5-5" }?.effective, 502)
                XCTAssertEqual(astra?.effective, 495)
            case "unknown-estimate-price-blind":
                XCTAssertEqual(astra?.reason, "noEstimate"); XCTAssertNil(astra?.quality)
                XCTAssertNil(astra?.effective); XCTAssertNil(astra?.score); XCTAssertEqual(astra?.position, 2)
            case "leading-unknown-model":
                XCTAssertEqual(rows.first?.reason, "noEstimate"); XCTAssertNil(rows.first?.effective)
                XCTAssertNil(rows.first?.score); XCTAssertEqual(rows.first?.model, "claude-opus-5-5")
            case "empty-explicit-table":
                XCTAssertFalse(role.derived); XCTAssertTrue(rows.allSatisfy { $0.reason == "noEstimate" && $0.score == nil })
            case "chain-duplicate-model":
                let opus = rows.filter { $0.model == "claude-opus-5-5" }
                XCTAssertEqual(opus.count, 2); XCTAssertTrue(opus.allSatisfy { $0.quality == 512 && $0.effective == 512 })
                XCTAssertEqual(opus.map(\.neutralPosition), [1, 2]); XCTAssertEqual(opus.map(\.effort), ["high", "low"])
            case "neutral-equal-levels":
                XCTAssertEqual(rows.map(\.level), [2, 2]); XCTAssertEqual(rows.map(\.position), rows.map(\.neutralPosition))
            case "pricing-off", "pricing-disabled":
                XCTAssertEqual(role.pricing, "off"); XCTAssertTrue(rows.allSatisfy { $0.level == nil && $0.score == $0.effective })
            case "short-history-unconfident":
                XCTAssertEqual(role.pricing, "unconfident"); XCTAssertEqual(rows.map(\.level), [4, 4])
            case "derived-with-groups":
                XCTAssertTrue(role.derived); XCTAssertEqual(role.floor, 21)
                XCTAssertTrue(rows.allSatisfy { $0.quality == 21 }); XCTAssertEqual(astra?.position, 1)
            case "same-model-routes-by-level":
                XCTAssertEqual(rows.map(\.candidate), ["t3:alpha/claude-opus-5-5", "native/claude-opus-5-5"])
                XCTAssertEqual(rows.map(\.neutralPosition), [2, 1]); XCTAssertEqual(rows.map(\.quality), [512, 512])
            case "raise-targets", "raise-from-default":
                XCTAssertEqual(rows.map(\.raise), ["xhigh"])
                XCTAssertEqual(rows.map(\.level), [0])
            case "raise-blocked-by-limit":
                XCTAssertEqual(rows.map(\.raise), [nil])
                XCTAssertEqual(rows.map(\.level), [0])
            case "raise-unsupported-level":
                XCTAssertEqual(rows.map(\.raise), ["high"])
                XCTAssertEqual(rows.map(\.level), [0])
            default: XCTFail("unasserted vector \(name)")
            }
            try write(name, input: input, scores: scores)
        }
    }

    func test_scoringVectorProperties() throws {
        for (name, input) in Self.vectors() {
            for role in try input.scores() {
                let rows = role.rows
                let neutral = Set(rows.filter(\.eligible).compactMap(\.level)).count <= 1
                XCTAssertEqual(Set(rows.map(\.position)), Set(1...rows.count), name)
                XCTAssertEqual(Set(rows.map(\.neutralPosition)), Set(1...rows.count), name)
                for row in rows {
                    if neutral { XCTAssertEqual(row.position, row.neutralPosition, name) }
                    if !row.eligible { XCTAssertGreaterThanOrEqual(row.position, row.neutralPosition, name) }
                    if let target = row.raise {
                        XCTAssertFalse(role.derived, name)
                        XCTAssertEqual(role.pricing, "active", name)
                        XCTAssertTrue(row.eligible, name)
                        XCTAssertEqual(row.level, 0, name)
                        let effort = try XCTUnwrap(BrokerEffort(rawValue: target))
                        XCTAssertTrue(BrokerEffort.support(forModel: row.model, in: input.policy.models)
                            .selectableLevels.contains(effort), name)
                        let table = try XCTUnwrap(input.policy.scoring.role(role.role))
                        let key = row.effort ?? "_default"
                        XCTAssertGreaterThan(try XCTUnwrap(table.quality[row.model]?[target]),
                            try XCTUnwrap(table.quality[row.model]?[key]), name)
                        if let limit = role.latencyLimit {
                            XCTAssertLessThanOrEqual(try XCTUnwrap(input.policy.scoring.latency[row.model]?[target]), limit, name)
                        }
                    }
                    if row.eligible, row.level == 0 {
                        for later in rows where later.neutralPosition > row.neutralPosition {
                            XCTAssertGreaterThan(later.position, row.position, name)
                        }
                    }
                    for preceding in rows where preceding.neutralPosition < row.neutralPosition && preceding.position > row.position {
                        XCTAssertTrue(row.eligible, name)
                        let gap = try XCTUnwrap(preceding.effective) - XCTUnwrap(row.effective)
                        XCTAssertLessThanOrEqual(gap, 19, name)
                    }
                }
            }
        }
    }

}
