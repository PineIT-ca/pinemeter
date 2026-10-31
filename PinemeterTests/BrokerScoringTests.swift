import Foundation
import XCTest
@testable import Pinemeter

final class BrokerScoringTests: XCTestCase {
    func test_piDefaultQuality_remainsVisibleInScoreSnapshot() throws {
        let p = BrokerPolicy.bundledDefault
        let scored = try BrokerScoringEngine.scoredRole(role: "execution", policy: p,
            oracle: nil, demand: nil, now: BrokerFixture.now)
        let snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: p)
        let table = try XCTUnwrap(snapshot.modelTables.first { $0.model == "default" })
        XCTAssertTrue(table.hasBaseEstimate)
        XCTAssertEqual(table.rows.first { $0.isBase }?.quality, 0)
    }

    func test_piDefaultQuality_doesNotCapOtherDefaultModels() throws {
        var p = BrokerPolicy.bundledDefault
        p.roles["execution"] = BrokerFixture.candidates(["t3:pi/default", "t3:other/default"])
        let unestimated = BrokerScoringEngine.scoredRows(p.roles["execution"]!, role: "execution", policy: p,
            oracle: nil, demand: nil, now: BrokerFixture.now)
        XCTAssertNil(unestimated[1].quality)
        XCTAssertEqual(unestimated[1].reason, "noEstimate")
        p.scoring.roles["execution"]!.quality["default"] = ["_default": 300]
        let rows = BrokerScoringEngine.scoredRows(p.roles["execution"]!, role: "execution", policy: p,
            oracle: nil, demand: nil, now: BrokerFixture.now)
        XCTAssertEqual(rows[0].quality, 0)
        XCTAssertEqual(rows[0].effective, 0)
        XCTAssertEqual(rows[1].quality, 300)
        XCTAssertEqual(rows[1].effective, 300)
        XCTAssertEqual(BrokerScoringEngine.scoredOrder(p.roles["execution"]!, role: "execution", policy: p,
            oracle: nil, demand: nil, now: BrokerFixture.now).first?.id, "t3:other/default")
    }

    private let now = BrokerFixture.now

    private func shippedExpiringWorld(role: String) -> (BrokerPolicy, OracleSnapshot, BrokerDemand) {
        let policy = GoldenFrozenTables.bundledDefault
        let reset = now.addingTimeInterval(10 * 3600)
        let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(
            weekly: 10, sonnet: 10, fable: 10,
            weeklyResetAt: reset, sonnetResetAt: reset, fableResetAt: reset)],
            chatGPTRows: [.init(label: "Codex weekly", usedPercent: 10, resetAt: reset,
                windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
        let keys = ["claude:acct-primary:weekly", "claude:acct-primary:sonnet",
            "claude:acct-primary:fable", "chatgpt:Workspace A:Codex weekly"]
        let demand = BrokerDemand(historyDays: 3, historySufficient: true, roles: [role: 100],
            pools: Dictionary(uniqueKeysWithValues: keys.map {
                ($0, BrokerDemand.PoolDemand(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12))
            }))
        return (policy, oracle, demand)
    }

    func test_shippedBalancedExplore_neverRaised() throws {
        let (policy, oracle, demand) = shippedExpiringWorld(role: "explore")
        let prices = BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: demand, now: now)
        XCTAssertEqual(prices.count, 4)
        XCTAssertTrue(prices.allSatisfy { $0.priceLevel == 0 })
        let pick = try BrokerEngine.decide(role: "explore", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
        XCTAssertEqual(pick.model, "codex/gpt-6-luna")
        XCTAssertEqual(pick.effort, .medium)
        XCTAssertEqual(pick.invocation.effort, .medium)
        XCTAssertEqual(pick.pickBasis, .quality)
        XCTAssertFalse(pick.reason.contains("; quota price raised effort"))
        XCTAssertEqual(try recordedDecide(role: "explore", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand), pick)
    }

    func test_shippedBalancedHeavy_raisesBeforeSwitch() throws {
        let (policy, oracle, demand) = shippedExpiringWorld(role: "heavy")
        let prices = BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: demand, now: now)
        XCTAssertEqual(prices.count, 4)
        XCTAssertTrue(prices.allSatisfy { $0.priceLevel == 0 })
        let plain = try BrokerEngine.decide(role: "heavy", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:])
        let pick = try BrokerEngine.decide(role: "heavy", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
        XCTAssertEqual(plain.model, "codex/gpt-6.1-sol")
        XCTAssertEqual(plain.effort, .high)
        XCTAssertEqual(pick.model, plain.model)
        XCTAssertEqual(pick.effort, .xhigh)
        XCTAssertEqual(pick.invocation.effort, .xhigh)
        XCTAssertEqual(pick.pickBasis, .quota)
        XCTAssertFalse(pick.reason.contains("; quota price favoured"))
        XCTAssertTrue(pick.reason.hasSuffix("; quota price raised effort on codex/gpt-6.1-sol from high to xhigh"))
        XCTAssertEqual(pick.candidatesTried, plain.candidatesTried)
        XCTAssertEqual(pick.backups, plain.backups)
        XCTAssertEqual(try recordedDecide(role: "heavy", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand), pick)
    }

    static func crossModelWorld() -> (BrokerPolicy, OracleSnapshot, BrokerDemand) {
        let now = BrokerFixture.now
        var policy = BrokerFixture.policy(
            roles: ["review": ["auto/claude-opus-5-5", "auto/gpt-6-astra"]],
            models: ["gpt-6-astra": .init(quota: .chatGPT(labelContains: nil))])
        policy.scoring = .empty
        policy.agentModelAliases["claude-opus-5-5"] = "opus"
        policy.thresholds.preferExpiringQuota = true
        let oracle = BrokerFixture.oracle(
            accounts: [BrokerFixture.account(label: "Account A", weekly: 70,
                                              weeklyResetAt: now.addingTimeInterval(60 * 3600))],
            chatGPTRows: [.init(label: "Weekly", usedPercent: 30,
                               resetAt: now.addingTimeInterval(10 * 3600),
                               windowRole: .chatGPTWeekly, account: "Workspace A")],
            chatGPTConfigured: true)
        let demand = BrokerDemand(historyDays: 3, historySufficient: true, roles: ["review": 100], pools: [
            "claude:acct-primary:weekly": .init(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12),
            "chatgpt:Workspace A:Weekly": .init(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12)])
        return (policy, oracle, demand)
    }

    static func raiseWorld() -> (BrokerPolicy, OracleSnapshot, BrokerDemand) {
        var (policy, oracle, demand) = scoringWorld()
        policy.roles["review"] = [.init(route: .codex, model: "gpt-6-astra", effort: .medium)]
        policy.models["gpt-6-astra"] = .init(quota: .chatGPT(labelContains: nil),
            effort: .init(levels: [.low, .medium, .high, .xhigh], nilLabel: "Provider default"))
        policy.scoring.roles["review"] = .init(latencyLimit: 96,
            quality: ["gpt-6-astra": ["medium": 496, "high": 509, "xhigh": 524]])
        policy.scoring.latency = ["gpt-6-astra": ["medium": 15, "high": 36, "xhigh": 96]]
        return (policy, oracle, demand)
    }

    func test_expiringPool_raisesWinnerEffort() throws {
        let (policy, oracle, demand) = Self.raiseWorld()
        let rows = BrokerScoringEngine.scoredRows(policy.roles["review"]!, role: "review", policy: policy,
            oracle: oracle, demand: demand, now: now)
        XCTAssertEqual(rows.map(\.level), [0])
        let pick = try BrokerEngine.decide(role: "review", caller: "codex", policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
        XCTAssertEqual(pick.model, "codex/gpt-6-astra")
        XCTAssertEqual(pick.effort, .xhigh)
        XCTAssertEqual(pick.invocation.effort, .xhigh)
        XCTAssertEqual(pick.pickBasis, .quota)
        XCTAssertTrue(pick.reason.hasSuffix("; quota price raised effort on codex/gpt-6-astra from medium to xhigh"))
        XCTAssertEqual(try recordedDecide(role: "review", caller: "codex", policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand), pick)
    }

    func test_explicitTable_movesPricedPickAcrossModels() throws {
        var (policy, oracle, demand) = Self.crossModelWorld()
        policy.scoring.roles["review"] = .init(quality: [
            "claude-opus-5-5": ["_default": 512], "gpt-6-astra": ["_default": 496]])
        let decision = try recordedDecide(role: "review", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
        XCTAssertEqual(decision.model, "codex/gpt-6-astra")
        XCTAssertEqual(decision.pickBasis, .quota)
        XCTAssertTrue(decision.reason.hasSuffix("; quota price favoured codex/gpt-6-astra over native/claude-opus-5-5"))
    }

    static func scoringWorld() -> (BrokerPolicy, OracleSnapshot, BrokerDemand) {
        var (policy, oracle, demand) = crossModelWorld()
        policy.t3.defaultInstance = "alpha"
        policy.scoring.roles["review"] = .init(quality: [
            "claude-opus-5-5": ["_default": 512], "gpt-6-astra": ["_default": 496]])
        return (policy, oracle, demand)
    }

    func test_floorBlocksCheaperCandidate() throws {
        var (policy, oracle, demand) = Self.scoringWorld()
        policy.scoring.roles["review"] = .init(floor: 500, quality: [
            "claude-opus-5-5": ["_default": 512], "gpt-6-astra": ["_default": 496]])
        let decision = try recordedDecide(role: "review", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
        XCTAssertEqual(decision.model, "native/claude-opus-5-5")
        XCTAssertEqual(decision.pickBasis, .quality)
        XCTAssertFalse(decision.reason.contains("; quota price favoured"))
    }

    func test_noTable_noGroups_keepsChainOrder() throws {
        let (policy, oracle, demand) = Self.crossModelWorld()
        let decision = try BrokerEngine.decide(role: "review", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
        XCTAssertEqual(decision.model, "native/claude-opus-5-5")
    }

    func test_materializedDerivedTables_reproduceEveryCommittedDecision() throws {
        try XCTSkipIf(GoldenFixture.exportDirectory() != nil, "Replay runs after the exporter exits.")
        let directory = GoldenFixture.decisionsDirectory
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".input.json") }.sorted { $0.path < $1.path }
        var legacyCount = 0
        var materializedCount = 0
        var compared = 0
        for url in files {
            let input = try GoldenFixture.decoder().decode(GoldenInput.self, from: Data(contentsOf: url))
            var policy = input.policy
            let oracle = try input.oracle?.snapshot()
            let resolved = policy.resolveRole(input.role)
            // G2 concerns the previous schema; explicit-table and override inputs replay unchanged.
            if input.overrideCandidate == nil && policy.scoring.role(resolved) == nil {
                legacyCount += 1
                let expanded = BrokerEngine.expandingModelChoices(policy.roles[resolved] ?? [], policy: policy,
                    oracle: oracle, now: input.now)
                let ranked = BrokerEngine.rankingEquivalentCandidatesByHeadroom(expanded, policy: policy,
                    oracle: oracle, now: input.now)
                policy.scoring.roles[resolved] = BrokerScoringEngine.derivedTable(ranked, role: input.role, policy: policy)
                materializedCount += 1
            }
            let name = String(url.lastPathComponent.dropLast(".input.json".count))
            let bytes: Data
            let suffix: String
            do {
                let pick: BrokerDecision
                if let override = input.overrideCandidate {
                    pick = try BrokerEngine.decideOverride(role: input.role, caller: input.caller, overrideCandidate: override,
                        policy: policy, oracle: oracle, cooldowns: input.cooldowns, now: input.now, t3: input.liveness(), local: input.local, residency: input.residency, executionContext: input.executionContext)
                } else {
                    pick = try BrokerEngine.decide(role: input.role, caller: input.caller, policy: policy, oracle: oracle,
                        cooldowns: input.cooldowns, now: input.now, t3: input.liveness(), demand: input.demand, health: input.health, local: input.local, residency: input.residency, executionContext: input.executionContext)
                }
                bytes = try GoldenFixture.canonicalEncoder().encode(pick)
                suffix = "decision.json"
            } catch let error as BrokerError {
                bytes = try GoldenFixture.canonicalEncoder().encode(try XCTUnwrap(GoldenErrorFixture(error)))
                suffix = "error.json"
            }
            XCTAssertEqual(bytes, try Data(contentsOf: directory.appendingPathComponent("\(name).\(suffix)")), name)
            compared += 1
        }
        XCTAssertGreaterThan(legacyCount, 0)
        XCTAssertEqual(materializedCount, legacyCount)
        XCTAssertEqual(compared, files.count)
        XCTAssertGreaterThanOrEqual(compared, 130)
    }

    func test_derivedTable_usesAdjacentTiersAndOnlyFirstChainEfforts() {
        var policy = BrokerFixture.policy(roles: ["review": ["native/a", "native/b", "native/c"]])
        policy.scoring = .empty
        policy.roles["review"]![0] = .init(route: .native, model: "a", effort: .high)
        let ranked = policy.roles["review"]!
        policy.equalQuality = ["review": [["a", "b"]]]
        var table = BrokerScoringEngine.derivedTable(ranked, role: "review", policy: policy)
        XCTAssertEqual(table, .init(floor: 21, quality: ["a": ["high": 42], "b": ["_default": 42], "c": ["_default": 21]]))
        policy.equalQuality = ["review": [["a", "c"]]]
        table = BrokerScoringEngine.derivedTable(ranked, role: "review", policy: policy)
        XCTAssertEqual(table.quality, ["a": ["high": 63], "b": ["_default": 42], "c": ["_default": 21]])
        XCTAssertTrue(table.quality.values.allSatisfy { $0.count == 1 })
    }

    func test_scoredOrder_passBoundaryAndCandidatePermutation() {
        var (policy, oracle, demand) = Self.crossModelWorld()
        let ranked = BrokerFixture.candidates(["native/claude-opus-5-5", "codex/gpt-6-astra"])
        for gap in [20, 19] {
            policy.scoring.roles["review"] = .init(quality: [
                "claude-opus-5-5": ["_default": 512], "gpt-6-astra": ["_default": 512 - gap]])
            let rows = BrokerScoringEngine.scoredRows(ranked, role: "review", policy: policy, oracle: oracle, demand: demand, now: now)
            XCTAssertEqual(rows.map(\.level), [4, 0])
            let sorted = BrokerScoringEngine.scoredOrder(ranked, role: "review", policy: policy, oracle: oracle, demand: demand, now: now)
            XCTAssertEqual(sorted, gap == 20 ? ranked : Array(ranked.reversed()))
            XCTAssertEqual(Set(sorted), Set(ranked))
            XCTAssertEqual(sorted.count, ranked.count)
            XCTAssertEqual(BrokerScoringEngine.scoredOrder(ranked, role: "review", policy: policy, oracle: oracle, demand: nil, now: now), ranked)
        }
        policy.thresholds.preferExpiringQuota = false
        XCTAssertEqual(BrokerScoringEngine.scoredOrder(ranked, role: "review", policy: policy, oracle: oracle, demand: demand, now: now), ranked)
    }

    func test_scoredOrder_emptyExplicitTableAndLeadingUnknownRemainPriceBlind() {
        var (policy, oracle, demand) = Self.crossModelWorld()
        let ranked = BrokerFixture.candidates(["native/claude-opus-5-5", "codex/gpt-6-astra"])
        policy.scoring.roles["review"] = .init()
        XCTAssertEqual(BrokerScoringEngine.scoredOrder(ranked, role: "review", policy: policy, oracle: oracle, demand: demand, now: now), ranked)
        policy.scoring.roles["review"] = .init(quality: ["gpt-6-astra": ["_default": 496]])
        let rows = BrokerScoringEngine.scoredRows(ranked, role: "review", policy: policy, oracle: oracle, demand: demand, now: now)
        XCTAssertFalse(rows[0].eligible)
        XCTAssertEqual(rows[0].effective, Int.max)
        XCTAssertEqual(rows[0].score, Int.max)
        XCTAssertEqual(BrokerScoringEngine.scoredOrder(ranked, role: "review", policy: policy, oracle: oracle, demand: demand, now: now), ranked)
        policy.scoring.roles["review"] = .init(quality: ["claude-opus-5-5": ["_default": 512]])
        let trailing = BrokerScoringEngine.scoredRows(ranked, role: "review", policy: policy, oracle: oracle, demand: demand, now: now)
        XCTAssertEqual(trailing.map(\.score), [492, 492])
        XCTAssertFalse(trailing[1].eligible)
    }

    func test_scoredOrder_capsQualityAndUsesFirstChainEffortForDuplicateRoutes() {
        var (policy, oracle, demand) = Self.crossModelWorld()
        policy.roles["review"]![0] = .init(route: .auto, model: "claude-opus-5-5", effort: .high)
        policy.roles["review"]!.append(.init(route: .native, model: "claude-opus-5-5", effort: .low))
        policy.scoring.roles["review"] = .init(quality: ["claude-opus-5-5": ["high": 512, "low": 10000], "gpt-6-astra": ["_default": 10000]])
        let ranked = BrokerFixture.candidates(["native/claude-opus-5-5", "codex/gpt-6-astra", "t3:alpha/claude-opus-5-5"])
        let rows = BrokerScoringEngine.scoredRows(ranked, role: "review", policy: policy, oracle: oracle, demand: demand, now: now)
        XCTAssertEqual(rows.map(\.effective), [512, 512, 512])
        XCTAssertEqual(rows.map(\.baseKey), ["high", "_default", "high"])
        let neutral = BrokerDemand(historyDays: 0, historySufficient: false, roles: [:], pools: [:])
        XCTAssertEqual(BrokerScoringEngine.scoredOrder(ranked, role: "review", policy: policy, oracle: oracle, demand: neutral, now: now), ranked)
    }
    private func assertAndRecord(_ policy: BrokerPolicy, _ oracle: OracleSnapshot, _ demand: BrokerDemand,
                                 winner: String, basis: BrokerPickBasis, suffix: String = "session 10% ok",
                                 caller: String? = nil, cooldowns: [String: Date] = [:],
                                 t3: [String: T3Liveness] = [:]) throws -> BrokerDecision {
        let pick = try BrokerEngine.decide(role: "review", caller: caller, policy: policy,
            oracle: oracle, cooldowns: cooldowns, now: now, t3: t3, demand: demand)
        XCTAssertEqual(pick.model, winner)
        XCTAssertEqual(pick.pickBasis, basis)
        XCTAssertTrue(pick.reason.hasSuffix(suffix), pick.reason)
        let recorded = try recordedDecide(role: "review", caller: caller, policy: policy,
            oracle: oracle, cooldowns: cooldowns, now: now, t3: t3, demand: demand)
        XCTAssertEqual(recorded, pick)
        return pick
    }

    func test_gap20_keepsChainOrder() throws {
        var (policy, oracle, demand) = Self.scoringWorld()
        policy.scoring.roles["review"]!.quality["gpt-6-astra"] = ["_default": 492]
        _ = try assertAndRecord(policy, oracle, demand, winner: "native/claude-opus-5-5", basis: .quality)
    }

    func test_gap19_movesAhead() throws {
        var (policy, oracle, demand) = Self.scoringWorld()
        policy.scoring.roles["review"]!.quality["gpt-6-astra"] = ["_default": 493]
        _ = try assertAndRecord(policy, oracle, demand, winner: "codex/gpt-6-astra", basis: .quota,
            suffix: "; quota price favoured codex/gpt-6-astra over native/claude-opus-5-5")
    }

    func test_latencyLimitBlocksSlowerCheaperCandidate() throws {
        var (policy, oracle, demand) = Self.scoringWorld()
        policy.scoring.roles["review"]!.latencyLimit = 50
        policy.scoring.latency = ["claude-opus-5-5": ["_default": 20], "gpt-6-astra": ["_default": 51]]
        _ = try assertAndRecord(policy, oracle, demand, winner: "native/claude-opus-5-5", basis: .quality)
    }

    func test_unknownEstimateNeverMovesAhead() throws {
        var (policy, oracle, demand) = Self.scoringWorld()
        policy.scoring.roles["review"]!.quality.removeValue(forKey: "gpt-6-astra")
        _ = try assertAndRecord(policy, oracle, demand, winner: "native/claude-opus-5-5", basis: .quality)
    }

    func test_loweredEffortWithoutEstimateCannotMoveAhead() throws {
        var (policy, oracle, demand) = Self.scoringWorld()
        policy.equalQuality = ["review": [["claude-opus-5-5", "gpt-6-astra"]]]
        policy.roles["review"]![1] = .init(route: .auto, model: "gpt-6-astra", effort: .low)
        policy.scoring.roles["review"]!.quality["gpt-6-astra"] = ["medium": 496]
        _ = try assertAndRecord(policy, oracle, demand, winner: "native/claude-opus-5-5", basis: .quality)
    }

    func test_chainDuplicateKeepsFirstOccurrence() throws {
        var (policy, oracle, demand) = Self.scoringWorld()
        policy.roles["review"] = [
            .init(route: .auto, model: "claude-opus-5-5", effort: .high),
            .init(route: .auto, model: "gpt-6-astra"),
            .init(route: .auto, model: "claude-opus-5-5", effort: .low)]
        policy.scoring.roles["review"]!.quality = [
            "claude-opus-5-5": ["high": 512, "low": 100], "gpt-6-astra": ["_default": 490]]
        let pick = try assertAndRecord(policy, oracle, demand, winner: "native/claude-opus-5-5", basis: .quality)
        XCTAssertEqual(pick.effort, .high)
        XCTAssertEqual(pick.candidatesTried.filter { $0.candidate == "native/claude-opus-5-5" }.count, 1)
    }

    func test_cheapestEligibleCallerFiltered_isPassedOver() throws {
        var (policy, oracle, demand) = Self.scoringWorld()
        policy.callers["limited"] = .init(routes: [.native])
        let pick = try assertAndRecord(policy, oracle, demand, winner: "native/claude-opus-5-5", basis: .quality,
            caller: "limited")
        XCTAssertEqual(pick.candidatesTried.first?.callerFiltered, true)
    }

    func test_cheapestEligibleCooledDown_isPassedOver() throws {
        let (policy, oracle, demand) = Self.scoringWorld()
        let pick = try assertAndRecord(policy, oracle, demand, winner: "native/claude-opus-5-5", basis: .quality,
            cooldowns: ["codex": now.addingTimeInterval(60)])
        XCTAssertEqual(pick.candidatesTried.first?.available, false)
    }

    func test_pacedCheaperEligible_isStillHeldBack() throws {
        var (policy, oracle, demand) = Self.scoringWorld()
        policy.roles["review"] = BrokerFixture.candidates(["native/claude-opus-5-5", "t3:alpha/claude-opus-5-5"])
        policy.scoring.roles["review"]!.quality.removeValue(forKey: "gpt-6-astra")
        policy.t3Instances = [.init(id: "alpha", name: "Alpha", boundAccountId: "acct-secondary")]
        oracle = BrokerFixture.oracle(accounts: oracle.accounts + [
            BrokerFixture.account(id: "acct-secondary", label: "Account B", isPrimary: false,
                session: 70, weekly: 0, sessionResetAt: now.addingTimeInterval(4 * 3600),
                weeklyResetAt: now.addingTimeInterval(10 * 3600))])
        demand.pools["claude:acct-secondary:weekly"] = .init(rateMilli: 0, windowDecisions: 6, ledgerDecisions: 12)
        let pick = try assertAndRecord(policy, oracle, demand, winner: "native/claude-opus-5-5", basis: .quota,
            t3: BrokerFixture.reachable("alpha"))
        XCTAssertEqual(pick.candidatesTried.first?.candidate, "t3:alpha/claude-opus-5-5")
        XCTAssertTrue(pick.candidatesTried.first?.why.hasSuffix("; held back for a lane with spare pace") == true)
    }

    func test_forcedDegraded_usesScoredOrder() throws {
        var (policy, oracle, demand) = Self.scoringWorld()
        oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(weekly: 90)],
            chatGPTRows: oracle.chatGPTRows + [.init(label: "Session", usedPercent: 100, windowSeconds: 18000)],
            chatGPTConfigured: true)
        let pick = try assertAndRecord(policy, oracle, demand, winner: "codex/gpt-6-astra", basis: .quality,
            suffix: "forcing top choice codex/gpt-6-astra (degraded)")
        XCTAssertEqual(pick.source, .forcedDegraded)
    }

    func test_overrideIgnoresScoring() throws {
        let (policy, oracle, demand) = Self.scoringWorld()
        let plain = try BrokerEngine.decide(role: "review", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
        XCTAssertEqual(plain.model, "codex/gpt-6-astra")
        let pick = try BrokerEngine.decideOverride(role: "review", caller: nil,
            overrideCandidate: "native/claude-opus-5-5", policy: policy, oracle: oracle,
            cooldowns: [:], now: now, t3: [:])
        XCTAssertEqual(pick.model, "native/claude-opus-5-5")
        XCTAssertEqual(pick.pickBasis, .humanOverride)
        XCTAssertTrue(pick.reason.hasSuffix("explicit human override: quota gates bypassed"), pick.reason)
        XCTAssertEqual(try recordedDecideOverride(role: "review", caller: nil,
            overrideCandidate: "native/claude-opus-5-5", policy: policy, oracle: oracle,
            cooldowns: [:], now: now, t3: [:]), pick)
    }

    private func assertRaiseDecision(_ policy: BrokerPolicy, _ oracle: OracleSnapshot, _ demand: BrokerDemand,
                                     target: BrokerEffort?, level: Int = 0,
                                     source: BrokerDecisionSource = .policy,
                                     cooldowns: [String: Date] = [:]) throws -> BrokerDecision {
        let chain = try XCTUnwrap(policy.roles["review"])
        let winner = try XCTUnwrap(chain.first)
        let rows = BrokerScoringEngine.scoredRows(chain, role: "review", policy: policy,
            oracle: oracle, demand: demand, now: now)
        XCTAssertEqual(rows.first?.level, level)
        let pick = try BrokerEngine.decide(role: "review", caller: "codex", policy: policy,
            oracle: oracle, cooldowns: cooldowns, now: now, t3: [:], demand: demand)
        XCTAssertEqual(pick.model, winner.id)
        XCTAssertEqual(pick.route, winner.route)
        XCTAssertEqual(pick.source, source)
        XCTAssertEqual(pick.effort, target ?? winner.effort)
        XCTAssertEqual(pick.invocation.effort, pick.effort)
        XCTAssertEqual(pick.pickBasis, target == nil ? .quality : .quota)
        XCTAssertFalse(pick.reason.contains("; quota price favoured"))
        if let target {
            XCTAssertTrue(pick.reason.hasSuffix("; quota price raised effort on \(winner.id) from \(winner.effort?.rawValue ?? "default") to \(target.rawValue)"))
        } else {
            XCTAssertFalse(pick.reason.contains("; quota price raised effort"))
        }
        var baseOnly = policy
        for model in Set(chain.map(\.model)) {
            let keys = Set(chain.filter { $0.model == model }.map { BrokerScoring.effortKey($0.effort) })
            if let quality = baseOnly.scoring.roles["review"]?.quality[model] {
                baseOnly.scoring.roles["review"]!.quality[model] = quality.filter { keys.contains($0.key) }
            }
        }
        let basePick = try BrokerEngine.decide(role: "review", caller: "codex", policy: baseOnly,
            oracle: oracle, cooldowns: cooldowns, now: now, t3: [:], demand: demand)
        XCTAssertEqual(pick.candidatesTried, basePick.candidatesTried)
        XCTAssertEqual(pick.backups, basePick.backups)
        XCTAssertEqual(try recordedDecide(role: "review", caller: "codex", policy: policy,
            oracle: oracle, cooldowns: cooldowns, now: now, t3: [:], demand: demand), pick)
        return pick
    }

    func test_levelOneDoesNotRaise() throws {
        let (policy, _, demand) = Self.raiseWorld()
        let oracle = BrokerFixture.oracle(chatGPTRows: [.init(label: "Weekly", usedPercent: 50,
            resetAt: now.addingTimeInterval(10 * 3600), windowRole: .chatGPTWeekly, account: "Workspace A")],
            chatGPTConfigured: true)
        _ = try assertRaiseDecision(policy, oracle, demand, target: nil, level: 1)
    }

    static func limitedRaiseWorld() -> (BrokerPolicy, OracleSnapshot, BrokerDemand) {
        var (policy, oracle, demand) = raiseWorld()
        policy.roles["review"] = [.init(route: .codex, model: "gpt-6-luna", effort: .medium)]
        policy.models["gpt-6-luna"] = .init(quota: .chatGPT(labelContains: nil),
            effort: .init(levels: [.low, .medium, .high, .xhigh]))
        policy.scoring.roles["review"] = .init(latencyLimit: 6,
            quality: ["gpt-6-luna": ["medium": 299, "high": 329]])
        policy.scoring.latency = ["gpt-6-luna": ["high": 14]]
        return (policy, oracle, demand)
    }

    func test_raiseBlockedByLatencyLimit() throws {
        let (policy, oracle, demand) = Self.limitedRaiseWorld()
        _ = try assertRaiseDecision(policy, oracle, demand, target: nil)
    }

    func test_raiseBlockedByUnknownLatencyUnderLimit() throws {
        var (policy, oracle, demand) = Self.limitedRaiseWorld()
        policy.scoring.latency = [:]
        _ = try assertRaiseDecision(policy, oracle, demand, target: nil)
    }

    static func defaultRaiseWorld() -> (BrokerPolicy, OracleSnapshot, BrokerDemand) {
        var (policy, oracle, demand) = raiseWorld()
        policy.roles["review"] = [.init(route: .codex, model: "gpt-6-astra")]
        policy.scoring.roles["review"] = .init(quality: ["gpt-6-astra": ["_default": 512, "xhigh": 532]])
        policy.scoring.latency = ["gpt-6-astra": ["xhigh": 57]]
        return (policy, oracle, demand)
    }

    func test_raiseFromDefault() throws {
        let (policy, oracle, demand) = Self.defaultRaiseWorld()
        let pick = try assertRaiseDecision(policy, oracle, demand, target: .xhigh)
        XCTAssertTrue(pick.reason.hasSuffix("from default to xhigh"))
    }

    static func supportedRaiseWorld() -> (BrokerPolicy, OracleSnapshot, BrokerDemand) {
        var (policy, oracle, demand) = raiseWorld()
        policy.models["gpt-6-astra"] = .init(quota: .chatGPT(labelContains: nil),
            effort: .init(levels: [.low, .medium, .high]))
        policy.scoring.roles["review"]!.quality["gpt-6-astra"] = ["medium": 480, "high": 550, "xhigh": 600]
        return (policy, oracle, demand)
    }

    func test_raiseSkipsUnsupportedLevel() throws {
        let (policy, oracle, demand) = Self.supportedRaiseWorld()
        _ = try assertRaiseDecision(policy, oracle, demand, target: .high)
    }

    func test_raiseEqualQualityUsesByteOrder() throws {
        var (policy, oracle, demand) = Self.raiseWorld()
        policy.scoring.roles["review"]!.quality["gpt-6-astra"]!["high"] = 524
        policy.models["gpt-6-astra"] = .init(quota: .chatGPT(labelContains: nil),
            effort: .init(levels: [.xhigh, .medium, .low, .high]))
        _ = try assertRaiseDecision(policy, oracle, demand, target: .high)
    }

    func test_derivedTableDoesNotRaise() throws {
        var (policy, oracle, demand) = Self.raiseWorld()
        policy.scoring = .empty
        _ = try assertRaiseDecision(policy, oracle, demand, target: nil)
    }

    func test_ineligibleWinnerDoesNotRaise() throws {
        var (policy, oracle, demand) = Self.raiseWorld()
        policy.scoring.roles["review"]!.floor = 497
        _ = try assertRaiseDecision(policy, oracle, demand, target: nil)
    }

    func test_unknownBaseDoesNotRaise() throws {
        var (policy, oracle, demand) = Self.raiseWorld()
        policy.scoring.roles["review"]!.quality["gpt-6-astra"]!.removeValue(forKey: "medium")
        _ = try assertRaiseDecision(policy, oracle, demand, target: nil)
    }

    func test_raiseKeepsBackupEfforts() throws {
        var (policy, oracle, demand) = Self.raiseWorld()
        policy.roles["review"]!.append(.init(route: .codex, model: "gpt-6.1-sol", effort: .high))
        policy.models["gpt-6.1-sol"] = .init(quota: .chatGPT(labelContains: nil),
            effort: .init(levels: [.low, .medium, .high, .xhigh]))
        policy.scoring.roles["review"]!.quality["gpt-6.1-sol"] = ["high": 502, "xhigh": 510]
        policy.scoring.latency["gpt-6.1-sol"] = ["high": 32, "xhigh": 73]
        let pick = try assertRaiseDecision(policy, oracle, demand, target: .xhigh)
        XCTAssertEqual(pick.backups.count, 1)
        XCTAssertEqual(pick.backups.first?.candidate, "codex/gpt-6.1-sol")
        XCTAssertEqual(pick.backups.first?.effort, .high)
        XCTAssertEqual(pick.backups.first?.invocation.effort, .high)
    }

    func test_forcedDegradedDoesNotRaise() throws {
        let (policy, oracle, demand) = Self.raiseWorld()
        _ = try assertRaiseDecision(policy, oracle, demand, target: nil, source: .forcedDegraded,
            cooldowns: ["codex": now.addingTimeInterval(60)])
    }

    func test_overrideDoesNotRaise() throws {
        let (policy, oracle, demand) = Self.raiseWorld()
        XCTAssertEqual(BrokerScoringEngine.scoredRows(policy.roles["review"]!, role: "review", policy: policy,
            oracle: oracle, demand: demand, now: now).first?.level, 0)
        let pick = try BrokerEngine.decideOverride(role: "review", caller: "codex",
            overrideCandidate: "codex/gpt-6-astra", policy: policy, oracle: oracle, cooldowns: [:], now: now, t3: [:])
        XCTAssertEqual(pick.effort, .medium)
        XCTAssertEqual(pick.invocation.effort, .medium)
        XCTAssertEqual(pick.pickBasis, .humanOverride)
        XCTAssertEqual(pick.source, .humanOverride)
        XCTAssertFalse(pick.reason.contains("; quota price raised effort"))
        XCTAssertEqual(try recordedDecideOverride(role: "review", caller: "codex",
            overrideCandidate: "codex/gpt-6-astra", policy: policy, oracle: oracle, cooldowns: [:], now: now, t3: [:]), pick)
    }

    func test_raiseBeforeModelSwitch() throws {
        var (policy, _, demand) = Self.raiseWorld()
        policy.roles["review"] = [
            .init(route: .codex, model: "gpt-6.1-sol", effort: .high),
            .init(route: .native, model: "claude-sonnet-5-5", effort: .xhigh)]
        policy.models["gpt-6.1-sol"] = .init(quota: .chatGPT(labelContains: nil),
            effort: .init(levels: [.low, .medium, .high, .xhigh]))
        policy.scoring.roles["review"] = .init(latencyLimit: 73, quality: [
            "gpt-6.1-sol": ["high": 502, "xhigh": 510], "claude-sonnet-5-5": ["xhigh": 519]])
        policy.scoring.latency = ["gpt-6.1-sol": ["high": 32, "xhigh": 73], "claude-sonnet-5-5": ["xhigh": 19]]
        let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(label: "Account A", weekly: 30, sonnet: 30,
            weeklyResetAt: now.addingTimeInterval(10 * 3600), sonnetResetAt: now.addingTimeInterval(10 * 3600))],
            chatGPTRows: [.init(label: "Weekly", usedPercent: 30, resetAt: now.addingTimeInterval(10 * 3600),
                windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
        demand.pools["claude:acct-primary:sonnet"] = .init(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12)
        XCTAssertTrue(BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: demand, now: now)
            .allSatisfy { $0.priceLevel == 0 })
        _ = try assertRaiseDecision(policy, oracle, demand, target: .xhigh)
    }

    func test_pricedModelSwitchThenRaiseRecordsBothReasons() throws {
        var (policy, oracle, demand) = Self.raiseWorld()
        policy.roles["review"]!.insert(.init(route: .native, model: "claude-opus-5-5"), at: 0)
        policy.scoring.roles["review"]!.quality["claude-opus-5-5"] = ["_default": 512]
        XCTAssertEqual(BrokerScoringEngine.scoredRows(policy.roles["review"]!, role: "review", policy: policy,
            oracle: oracle, demand: demand, now: now).map(\.level), [4, 0])
        let pick = try BrokerEngine.decide(role: "review", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
        XCTAssertEqual(pick.model, "codex/gpt-6-astra")
        XCTAssertEqual(pick.effort, .xhigh)
        XCTAssertEqual(pick.invocation.effort, .xhigh)
        XCTAssertEqual(pick.pickBasis, .quota)
        XCTAssertTrue(pick.reason.hasSuffix("; quota price favoured codex/gpt-6-astra over native/claude-opus-5-5; quota price raised effort on codex/gpt-6-astra from medium to xhigh"))
        XCTAssertEqual(try recordedDecide(role: "review", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand), pick)
    }

}
