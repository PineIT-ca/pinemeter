import Foundation
import XCTest
@testable import Pinemeter

final class FableCampaignTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOverlayIsPureAndExpiresWithoutRestoration() throws {
        var settings = BrokerSettings.default
        let base = settings.policy
        XCTAssertEqual(settings.effectivePolicy(now: now), base)
        settings.fableCampaign = FableCampaign(expiresAt: now.addingTimeInterval(60), accountDeadlines: ["account-a": now.addingTimeInterval(60)])
        let active = settings.effectivePolicy(now: now)
        XCTAssertEqual(active.roles["review"]?.first?.model, "claude-fable-5-2")
        XCTAssertEqual(active.thresholds.fableWeeklyPct, 95)
        XCTAssertEqual(active.thresholds.weeklyPct, base.thresholds.weeklyPct)
        XCTAssertEqual(active.scoring, base.scoring)
        XCTAssertEqual(active.roles["explore"], base.roles["explore"])
        XCTAssertEqual(active.roles["execution"]?.first, base.roles["execution"]?.first)
        XCTAssertEqual(active.agentModelAliases["claude-fable-5-2"], base.agentModelAliases["claude-fable-5-2"] ?? "claude-fable-5-2")
        XCTAssertEqual(active.usageLanes["t3/claude-fable-5-2"], base.usageLanes["t3/claude-fable-5-2"] ?? base.usageLanes["t3/claude-fable-5-1"])
        XCTAssertEqual(settings.policy, base)
        settings.policy.thresholds.weeklyPct = 72
        XCTAssertEqual(settings.effectivePolicy(now: now.addingTimeInterval(60)), settings.policy)
        XCTAssertEqual(settings.effectivePolicy(now: now).thresholds.weeklyPct, 72)
    }

    func testWaiverIsAccountModelAndDeadlineScoped() {
        var settings = BrokerSettings.default
        settings.fableCampaign = FableCampaign(expiresAt: now.addingTimeInterval(60), accountDeadlines: ["account-a": now.addingTimeInterval(30)])
        let p = settings.effectivePolicy(now: now)
        XCTAssertTrue(p.waivesFablePacing(accountID: "account-a", model: "claude-fable-5-2", now: now))
        XCTAssertFalse(p.waivesFablePacing(accountID: "account-b", model: "claude-fable-5-2", now: now))
        XCTAssertFalse(p.waivesFablePacing(accountID: "account-a", model: "claude-sonnet-5-5", now: now))
        XCTAssertFalse(p.waivesFablePacing(accountID: "account-a", model: "claude-fable-5-2", now: now.addingTimeInterval(30)))
    }

    func testLocalPersistenceAndPolicyExportIsolation() throws {
        var settings = BrokerSettings.default
        settings.fableCampaign = FableCampaign(expiresAt: now.addingTimeInterval(60), accountDeadlines: ["account-a": now.addingTimeInterval(60)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try JSONDecoder().decode(BrokerSettings.self, from: encoder.encode(settings)).fableCampaign, settings.fableCampaign)
        let exported = try encoder.encode(settings.policy)
        XCTAssertEqual(exported, try encoder.encode(BrokerSettings.default.policy))
        let effectiveExport = try encoder.encode(settings.effectivePolicy(now: now))
        XCTAssertFalse(String(decoding: effectiveExport, as: UTF8.self).contains("account-a"))
        XCTAssertNil(try JSONDecoder().decode(BrokerSettings.self, from: Data("{}".utf8)).fableCampaign)
        XCTAssertNil(try JSONDecoder().decode(BrokerSettings.self, from: Data("{\"fable_campaign\":false}".utf8)).fableCampaign)
    }
    func testNativeAndAccountWaiverNeverBypassHardCapsOrSharedPacing() throws {
        let now = BrokerFixture.now
        var settings = BrokerSettings.default
        settings.fableCampaign = FableCampaign(expiresAt: now.addingTimeInterval(3600), accountDeadlines: ["acct-primary": now.addingTimeInterval(3600)])
        let p = settings.effectivePolicy(now: now)
        let candidate = BrokerCandidate(route: .t3, model: FableCampaign.model)
        for (weekly, session, fable, available, paced) in [
            (20.0, 10.0, 90.0, true, false),
            (95, 10, 90, false, false),
            (20, 99, 90, false, false),
            (20, 10, 95, false, false)
        ] {
            let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(session: session, weekly: weekly, fable: fable, fableResetAt: now.addingTimeInterval(6 * 86400))])
            let native = BrokerEngine.evaluateNativePools(model: FableCampaign.model, thresholds: p.thresholds,
                block: BrokerEngine.oracleBlock(from: oracle, thresholds: p.thresholds, now: now),
                rowState: .fresh, waiveFablePacing: true, now: now)
            XCTAssertEqual(native.available, available)
            XCTAssertEqual(native.paced, paced)
            let lane = try XCTUnwrap(BrokerEngine.laneVerdict(for: candidate, policy: p, oracle: oracle, now: now))
            XCTAssertEqual(lane.available, available)
            XCTAssertEqual(lane.paced, paced)
        }
        let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(weekly: 70, fable: 90,
            weeklyResetAt: now.addingTimeInterval(6 * 86400), fableResetAt: now.addingTimeInterval(6 * 86400))])
        XCTAssertTrue(try XCTUnwrap(BrokerEngine.laneVerdict(for: candidate, policy: p, oracle: oracle, now: now)).paced)
    }

    func testUnmeasuredHeadPreservesScoringAndNilDemandRank() throws {
        var settings = BrokerSettings.default
        settings.fableCampaign = FableCampaign(expiresAt: now.addingTimeInterval(60), accountDeadlines: [:])
        var p = settings.effectivePolicy(now: now)
        for role in ["planning", "review", "research", "design", "heavy", "legal-review"] {
            // This test isolates an unmeasured head even after upstream tables arrive.
            p.scoring.roles[role]?.quality.removeValue(forKey: FableCampaign.model)
            let chain = try XCTUnwrap(p.roles[role])
            let rows = BrokerScoringEngine.scoredRows(chain, role: role, policy: p, oracle: nil, demand: nil, now: now)
            XCTAssertNil(rows.first?.quality)
            XCTAssertEqual(BrokerScoringEngine.scoredOrder(chain, role: role, policy: p, oracle: nil, demand: nil, now: now).first?.model, FableCampaign.model)
        }
    }

    func testBoundAndUnboundExpandedT3DiscoveryAndQuotaMapping() throws {
        var settings = BrokerSettings.default
        settings.policy.t3Instances = [
            T3InstanceConfig(id: "bound", name: "Bound", boundAccountId: "account-b", detectedModels: [FableCampaign.model]),
            T3InstanceConfig(id: "unbound", name: "Unbound", detectedModels: [FableCampaign.model]),
            T3InstanceConfig(id: "old", name: "Old", detectedModels: ["claude-fable-5-1"])
        ]
        settings.fableCampaign = FableCampaign(expiresAt: now.addingTimeInterval(60), accountDeadlines: [:])
        let p = settings.effectivePolicy(now: now)
        let bound = BrokerCandidate(route: .t3, instance: "bound", model: FableCampaign.model)
        let unbound = BrokerCandidate(route: .t3, instance: "unbound", model: FableCampaign.model)
        XCTAssertEqual(p.usageLane(for: bound), .claudeAccount(accountId: "account-b", labelContains: nil, isPrimary: nil))
        XCTAssertNil(p.usageLane(for: unbound))
        let expanded = BrokerEngine.expandingModelChoices([BrokerCandidate(route: .auto, model: FableCampaign.model)], policy: p, oracle: nil, now: now)
        XCTAssertTrue(expanded.contains(bound))
        XCTAssertTrue(expanded.contains(unbound))
        XCTAssertFalse(expanded.contains { $0.instance == "old" })
    }

    func testFableHeadWinsAtEveryObservedPriceLevelWithoutInventingQuality() throws {
        let now = BrokerFixture.now
        var settings = BrokerSettings.default
        settings.fableCampaign = FableCampaign(expiresAt: now.addingTimeInterval(60), accountDeadlines: [:])
        var p = settings.effectivePolicy(now: now)
        p.scoring.roles["review"]?.quality.removeValue(forKey: FableCampaign.model)
        let demand = BrokerDemand(historyDays: 3, historySufficient: true, roles: ["review": 1000], pools: [
            "claude:acct-primary:weekly": .init(rateMilli: 1000, windowDecisions: 10, ledgerDecisions: 12),
            "claude:acct-primary:fable": .init(rateMilli: 1000, windowDecisions: 10, ledgerDecisions: 12)
        ])
        let head = BrokerCandidate(route: .native, model: FableCampaign.model)
        let chain = [head] + (p.roles["review"] ?? []).dropFirst()
        var levels = Set<Int>()
        for used in 0...94 {
            let reset = now.addingTimeInterval(86400)
            let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(weekly: 0, fable: Double(used), weeklyResetAt: reset, fableResetAt: reset)])
            let rows = BrokerScoringEngine.scoredRows(chain, role: "review", policy: p, oracle: oracle, demand: demand, now: now)
            levels.insert(try XCTUnwrap(rows.first).level)
            XCTAssertNil(rows.first?.quality)
            XCTAssertEqual(BrokerScoringEngine.scoredOrder(chain, role: "review", policy: p, oracle: oracle, demand: demand, now: now).first, head)
        }
        XCTAssertEqual(levels, Set(0...4))
    }

    func testOverlayPreservesOnboardedMetadataAndDeduplicatesBothFableVersions() {
        var settings = BrokerSettings.default
        let spec = BrokerModelSpec(effort: BrokerEffortCapability(levels: [.low, .medium], nilLabel: "Existing default"))
        settings.policy.models[FableCampaign.model] = spec
        settings.policy.agentModelAliases[FableCampaign.model] = "fable"
        let lane = BrokerUsageLane.claudeAccount(accountId: "account-b", labelContains: nil, isPrimary: nil)
        settings.policy.usageLanes["t3/claude-fable-5-2"] = lane
        let old = BrokerCandidate(route: .auto, model: "claude-fable-5-1")
        let current = BrokerCandidate(route: .auto, model: FableCampaign.model)
        settings.policy.roles["review"] = [old, current, current]
        settings.policy.roles["execution"] = [current, BrokerCandidate(route: .auto, model: "gpt-6.1-sol"), old, current]
        let base = settings.policy
        settings.fableCampaign = FableCampaign(expiresAt: now.addingTimeInterval(60), accountDeadlines: [:])
        let active = settings.effectivePolicy(now: now)
        XCTAssertEqual(active.models[FableCampaign.model], spec)
        XCTAssertEqual(active.agentModelAliases[FableCampaign.model], "fable")
        XCTAssertEqual(active.usageLanes["t3/claude-fable-5-2"], lane)
        XCTAssertEqual(active.roles["review"], [current])
        XCTAssertEqual(active.roles["execution"]?.map(\.model), ["gpt-6.1-sol", FableCampaign.model])
        XCTAssertEqual(settings.policy, base)
        XCTAssertEqual(settings.effectivePolicy(now: now.addingTimeInterval(60)), base)
    }

    func testOverlayPreservesEitherBaseChainGenerationAndItsMeasuredTables() {
        let promoted = ["planning", "review", "research", "design", "heavy", "legal-review"]
        for baseModel in ["claude-fable-5-1", "claude-fable-5-2"] {
            var settings = BrokerSettings.default
            let sol = BrokerCandidate(route: .auto, model: "gpt-6.1-sol")
            let fable = BrokerCandidate(route: .auto, model: baseModel)
            let sonnet = BrokerCandidate(route: .auto, model: "claude-sonnet-5-5")
            for role in promoted { settings.policy.roles[role] = [sol, fable, sonnet] }
            settings.policy.roles["execution"] = [sol, fable, sonnet]
            let base = settings.policy
            settings.fableCampaign = FableCampaign(expiresAt: now.addingTimeInterval(60), accountDeadlines: [:])
            let effective = settings.effectivePolicy(now: now)
            for role in promoted {
                XCTAssertEqual(effective.roles[role]?.map(\.model), [FableCampaign.model, sol.model, sonnet.model])
            }
            XCTAssertEqual(effective.roles["execution"]?.map(\.model), [sol.model, FableCampaign.model, sonnet.model])
            XCTAssertEqual(effective.scoring, base.scoring)
            XCTAssertEqual(effective.equalQuality, base.equalQuality)
            XCTAssertEqual(effective.agentModelAliases, base.agentModelAliases)
            XCTAssertEqual(effective.models, base.models)
            XCTAssertEqual(settings.policy, base)
            XCTAssertEqual(settings.effectivePolicy(now: now.addingTimeInterval(60)), base)
            settings.policy.roles["execution"] = [fable, fable]
            XCTAssertEqual(settings.effectivePolicy(now: now).roles["execution"]?.map(\.model), [FableCampaign.model])
        }
    }

}
