import Foundation
import XCTest
@testable import Pinemeter

final class BrokerPoolPricingTests: XCTestCase {
    private let now = BrokerFixture.now

    private func shippedPresets() throws -> [BrokerAgentProfile] {
        let url = try XCTUnwrap(BrokerPresetManifestTests.bundledManifestURL())
        let presets = try BrokerPresetManifest.decode(from: Data(contentsOf: url)).presets
        XCTAssertEqual(presets.count, 7)
        return presets
    }

    func test_neutralPrices_keepEveryShippedPresetOrder() throws {
        let reset = now.addingTimeInterval(96 * 3600)
        let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(
            session: 0, weekly: 0, sonnet: 0, fable: 0,
            weeklyResetAt: reset, sonnetResetAt: reset, fableResetAt: reset)],
            chatGPTRows: [.init(label: "Codex weekly", usedPercent: 0, resetAt: reset,
                               windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
        let keys = ["claude:acct-primary:weekly", "claude:acct-primary:sonnet",
                    "claude:acct-primary:fable", "chatgpt:Workspace A:Codex weekly"]
        let short = BrokerDemand(historyDays: 0, historySufficient: false, roles: [:], pools: [:])
        var errorCount = 0
        for preset in try shippedPresets() {
            var policy = BrokerPolicy.bundledDefault
            policy.apply(preset.rules)
            let confident = BrokerDemand(historyDays: 3, historySufficient: true,
                roles: policy.roles.mapValues { _ in 100 },
                pools: Dictionary(uniqueKeysWithValues: keys.map {
                    ($0, BrokerDemand.PoolDemand(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12))
                }))
            let prices = BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: confident, now: now)
            XCTAssertEqual(prices.count, 4, preset.name)
            XCTAssertEqual(prices.map(\.price), [500, 500, 500, 500], preset.name)
            var chainsOnly = policy
            chainsOnly.scoring = .empty
            chainsOnly.equalQuality = [:]
            for role in policy.roles.keys.sorted() {
                let scored = try BrokerScoringEngine.scoredRole(role: role, policy: policy,
                    oracle: oracle, demand: confident, now: now)
                XCTAssertEqual(scored.rows.map(\.position), scored.rows.map(\.neutralPosition), "\(preset.name)/\(role)")
                for caller in [nil, "codex"] as [String?] {
                    func bytes(_ demand: BrokerDemand?, policy: BrokerPolicy) throws -> Data {
                        do {
                            let decision = try BrokerEngine.decide(role: role, caller: caller, policy: policy,
                                oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
                            return try GoldenFixture.canonicalEncoder().encode(decision)
                        } catch let error as BrokerError {
                            errorCount += 1
                            return try GoldenFixture.canonicalEncoder().encode(try XCTUnwrap(GoldenErrorFixture(error)))
                        }
                    }
                    let unpriced = try bytes(nil, policy: chainsOnly)
                    for demand in [nil, short, confident] {
                        XCTAssertEqual(try bytes(demand, policy: policy), unpriced, "\(preset.name)/\(role)/\(caller ?? "default")")
                    }
                }
            }
        }
        XCTAssertGreaterThan(errorCount, 0, "The invariant must cover errors as well as decisions.")
    }

    func test_shippedTablesListOnlyChainModels() throws {
        var roleCount = 0
        for preset in try shippedPresets() {
            XCTAssertTrue(preset.rules.equalQuality.isEmpty, preset.name)
            XCTAssertEqual(Set(preset.rules.scoring.roles.keys), Set(preset.rules.roles.keys), preset.name)
            for (role, table) in preset.rules.scoring.roles {
                roleCount += 1
                let chain = try XCTUnwrap(preset.rules.roles[role])
                XCTAssertFalse(table.quality.isEmpty, "\(preset.name)/\(role)")
                XCTAssertTrue(Set(table.quality.keys).isSubset(of: Set(chain.map { $0.id == "t3:pi/default" ? $0.id : $0.model })), "\(preset.name)/\(role)")
            }
        }
        XCTAssertEqual(roleCount, 70)
    }

    func test_shippedBalancedStandard_movesToExpiringCodexPool() throws {
        let policy = GoldenFrozenTables.bundledDefault
        let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(
            label: "Account A", weekly: 70, sonnet: 70,
            weeklyResetAt: now.addingTimeInterval(60 * 3600), sonnetResetAt: now.addingTimeInterval(60 * 3600))],
            chatGPTRows: [.init(label: "Codex weekly", usedPercent: 30,
                resetAt: now.addingTimeInterval(10 * 3600), windowRole: .chatGPTWeekly, account: "Workspace A")],
            chatGPTConfigured: true)
        let demand = BrokerDemand(historyDays: 3, historySufficient: true, roles: ["standard": 100], pools: [
            "claude:acct-primary:weekly": .init(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12),
            "claude:acct-primary:sonnet": .init(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12),
            "chatgpt:Workspace A:Codex weekly": .init(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12)
        ])
        let plain = try BrokerEngine.decide(role: "standard", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:])
        XCTAssertEqual(plain.model, "native/claude-sonnet-5-5")
        let priced = try BrokerEngine.decide(role: "standard", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
        XCTAssertEqual(priced.model, "codex/gpt-6.1-sol")
        XCTAssertEqual(priced.effort, .xhigh)
        XCTAssertEqual(priced.pickBasis, .quota)
        XCTAssertTrue(priced.reason.hasSuffix("; quota price favoured codex/gpt-6.1-sol over native/claude-sonnet-5-5; quota price raised effort on codex/gpt-6.1-sol from medium to xhigh"))
        let recorded = try recordedDecide(role: "standard", caller: nil, policy: policy,
            oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
        XCTAssertEqual(recorded, priced)
    }

    func test_manifestGroupsReachDecide_movesPricedPick() throws {
        let (source, oracle, demand) = crossModelWorld()
        let rules = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source.ruleSet))
        let data = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "presets": [["id": "00000000-0000-0000-0000-000000000001", "name": "Test Preset", "rules": rules]]
        ])
        let preset = try XCTUnwrap(BrokerPresetManifest.decode(from: data).presets.first)
        var policy = BrokerPolicy.bundledDefault
        policy.apply(preset.rules)
        let decision = try recordedDecide(role: "review", caller: nil, policy: policy,
                                          oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
        XCTAssertEqual(decision.model, "codex/gpt-6-astra")
        XCTAssertEqual(decision.pickBasis, .quota)
        XCTAssertTrue(decision.reason.hasSuffix("; quota price favoured codex/gpt-6-astra over native/claude-opus-5-5"))
    }

    private func crossModelWorld() -> (BrokerPolicy, OracleSnapshot, BrokerDemand) {
        var policy = BrokerFixture.policy(
            roles: ["review": ["auto/claude-opus-5-5", "auto/gpt-6-astra"]],
            models: ["gpt-6-astra": .init(quota: .chatGPT(labelContains: nil))])
        policy.equalQuality = ["review": [["claude-opus-5-5", "gpt-6-astra"]]]
        policy.agentModelAliases["claude-opus-5-5"] = "opus"
        policy.thresholds.preferExpiringQuota = true
        let oracle = BrokerFixture.oracle(
            accounts: [BrokerFixture.account(label: "Account A", weekly: 70,
                                              weeklyResetAt: now.addingTimeInterval(60 * 3600))],
            chatGPTRows: [.init(label: "Weekly", usedPercent: 30,
                               resetAt: now.addingTimeInterval(10 * 3600),
                               windowRole: .chatGPTWeekly, account: "Workspace A")],
            chatGPTConfigured: true)
        let demand = BrokerDemand(historyDays: 3, historySufficient: true, roles: ["review": 100],
                                  pools: ["claude:acct-primary:weekly": .init(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12),
                                          "chatgpt:Workspace A:Weekly": .init(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12)])
        return (policy, oracle, demand)
    }

    func test_crossModelMoveToExpiringPool_recordsQuotaBasis() throws {
        let (policy, oracle, demand) = crossModelWorld()
        let decision = try recordedDecide(role: "review", caller: nil, policy: policy,
                                          oracle: oracle, cooldowns: [:], now: now, t3: [:], demand: demand)
        XCTAssertEqual(decision.model, "codex/gpt-6-astra")
        XCTAssertEqual(decision.pickBasis, .quota)
        XCTAssertTrue(decision.reason.hasSuffix("; quota price favoured codex/gpt-6-astra over native/claude-opus-5-5"))
    }

    private struct PriceVector {
        let name: String
        var used: Double = 0
        var cap: Double = 100
        var t: Int = 3600
        var w: Int = 604800
        var rate: Int = 0
        var window: Int = 6
        var ledger: Int = 5
        var enabled: Bool = true
        var history: Bool = true
        var fresh: Bool = true
        var reset: Bool = true
        var price: Int = 50
        var level: Int = 0
        var state: String = "ok"
    }

    // These named vectors are shared verbatim with the Go price tests.
    private var boundaryVectors: [PriceVector] { [
        .init(name: "headroom-zero", cap: 0, price: 1000, level: 4),
        .init(name: "headroom-one", cap: 0.01, price: 1000, level: 4),
        .init(name: "reset-at-72h", t: 259200),
        .init(name: "reset-after-72h", t: 259201, price: 500, level: 2),
        .init(name: "elapsed-43199", t: 561601, price: 1000, level: 4, state: "early_window"),
        .init(name: "elapsed-43200", t: 561600, price: 500, level: 2),
        .init(name: "ledger-four", ledger: 4, price: 1000, level: 4, state: "new_pool"),
        .init(name: "ledger-five"),
        .init(name: "uncalibrated", rate: 1, window: 0, price: 1000, level: 4, state: "uncalibrated"),
        .init(name: "zero-rate-zero-window", window: 0),
        .init(name: "price-249", cap: 20.08, price: 249),
        .init(name: "price-250", cap: 20, price: 250, level: 1),
        .init(name: "price-999", used: 3.33, cap: 13.33, t: 302400, price: 999, level: 3),
        .init(name: "price-1000", used: 3.34, cap: 13.34, t: 302400, price: 1000, level: 4)
    ] }

    private var stateVectors: [PriceVector] { [
        .init(name: "off-before-history", rate: 1, window: 0, ledger: 0, enabled: false,
              history: false, fresh: false, reset: false, price: 1000, level: 4, state: "pricing_off"),
        .init(name: "history-before-stale", ledger: 0, history: false, fresh: false, reset: false,
              price: 1000, level: 4, state: "short_history"),
        .init(name: "stale-before-reset", ledger: 0, fresh: false, reset: false,
              price: 1000, level: 4, state: "stale_oracle"),
        .init(name: "reset-before-new", ledger: 0, reset: false, price: 1000, level: 4, state: "no_reset"),
        .init(name: "reset-at-now", t: 0, price: 1000, level: 4, state: "no_reset"),
        .init(name: "reset-in-past", t: -1, price: 1000, level: 4, state: "no_reset"),
        .init(name: "early-before-new", t: 561601, rate: 1, window: 0, ledger: 0,
              price: 1000, level: 4, state: "early_window"),
        .init(name: "new-before-uncalibrated", rate: 1, window: 0, ledger: 4,
              price: 1000, level: 4, state: "new_pool")
    ] }

    private func check(_ vectors: [PriceVector]) {
        for v in vectors {
            var policy = BrokerPolicy.default
            policy.thresholds.preferExpiringQuota = v.enabled
            let demand = BrokerDemand(historyDays: 3, historySufficient: v.history, roles: [:],
                                      pools: ["pool": .init(rateMilli: v.rate, windowDecisions: v.window, ledgerDecisions: v.ledger)])
            let row = BrokerPoolPricing.poolPrice(pool: "pool", label: "Pool", used: v.used, cap: v.cap,
                                                  resetAt: v.reset ? now.addingTimeInterval(Double(v.t)) : nil,
                                                  windowSeconds: v.w, fresh: v.fresh, policy: policy, demand: demand, now: now)
            XCTAssertEqual(row.price, v.price, v.name)
            XCTAssertEqual(row.priceLevel, v.level, v.name)
            XCTAssertEqual(row.forecast.state, v.state, v.name)
        }
    }

    func test_poolPriceBoundaries() { check(boundaryVectors) }
    func test_poolPriceStates() { check(stateVectors) }

    func test_poolPricePrecision() {
        check([
            .init(name: "half-away", used: 12.125, price: 58),
            .init(name: "used-below-zero", used: -10),
            .init(name: "used-above-100", used: 200, price: 1000, level: 4),
            .init(name: "rate-cap", used: 30, rate: 100000001, price: 1000, level: 4),
            .init(name: "window-cap", w: Int.max),
            .init(name: "counter-overflow", used: 30, rate: 100000000, window: Int.max, price: 75)
        ])
        var policy = BrokerPolicy.default
        policy.thresholds.preferExpiringQuota = true
        let demand = BrokerDemand(historyDays: 3, historySufficient: true, roles: [:], pools: [:])
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(weekly: value)])
            XCTAssertTrue(BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: demand, now: now).isEmpty)
        }
        let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(weekly: 12.125,
                                                                          weeklyResetAt: now.addingTimeInterval(3600.9))])
        let row = BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: demand,
                                               now: now.addingTimeInterval(0.2)).first!
        XCTAssertEqual(row.usedBp, 1213)
        XCTAssertEqual(row.secondsToReset, 3600)
        XCTAssertEqual(row.resetAt, now.addingTimeInterval(3600))
        XCTAssertEqual(row.forecast.state, "new_pool")
        XCTAssertTrue(BrokerPoolPricing.poolPrices(policy: policy, oracle: nil, demand: demand, now: now).isEmpty)
        let duplicate = OracleSnapshot.ChatGPTRow(label: "Weekly", usedPercent: 0,
                                                  resetAt: now.addingTimeInterval(3600), windowRole: .chatGPTWeekly)
        let other = OracleSnapshot.ChatGPTRow(label: "Weekly", usedPercent: 90, windowRole: .chatGPTWeekly)
        let short = OracleSnapshot.ChatGPTRow(label: "Session", usedPercent: 10, windowSeconds: 18000)
        let rows = BrokerPoolPricing.poolPrices(policy: policy,
            oracle: BrokerFixture.oracle(accounts: [], chatGPTRows: [duplicate, other, short]), demand: demand, now: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.usedBp, 0)
    }

    func test_qualityTiers() {
        let cases: [([String], [[String]], [Int])] = [
            (["a", "b", "c"], [["a", "c"]], [0, 1, 2]),
            (["a", "b", "c"], [["a", "b"], ["b", "c"]], [0, 0, 1]),
            (["a", "a", "b"], [], [0, 0, 1]),
            (["a", "b", "c"], [], [0, 1, 2]),
            (["a", "b", "c"], [["a", "b", "c"]], [0, 0, 0]),
            ([], [], [])
        ]
        for (models, groups, expected) in cases {
            XCTAssertEqual(BrokerPoolPricing.qualityTiers(models.map { .init(route: .codex, model: $0) }, groups: groups), expected)
        }
    }

    func test_equalLevelsKeepOrder() {
        let (policy, oracle, _) = crossModelWorld()
        let ranked = BrokerFixture.candidates(["codex/gpt-6-astra", "native/claude-opus-5-5"])
        let neutral = BrokerDemand(historyDays: 0, historySufficient: false, roles: [:], pools: [:])
        XCTAssertEqual(BrokerPoolPricing.pricedOrder(ranked, role: "review", policy: policy,
                                                    oracle: oracle, demand: neutral, now: now), ranked)
        XCTAssertEqual(BrokerPoolPricing.pricedOrder(ranked, role: "review", policy: policy,
                                                    oracle: oracle, demand: nil, now: now), ranked)
    }

    func test_pricedOrder_keepsTiersForPermutations() {
        let models = ["a", "b", "c", "d"]
        for run in 0..<100 {
            var order = Array(models[(run % 4)...]) + Array(models[..<(run % 4)])
            if run % 2 == 0 { order.reverse() }
            var policy = BrokerFixture.policy(roles: [:])
            policy.thresholds.preferExpiringQuota = true
            policy.equalQuality = ["review": [["a", "b"], ["c", "d"]]]
            let ranked = order.map { BrokerCandidate(route: .codex, model: $0) }
            var rows: [OracleSnapshot.ChatGPTRow] = []
            var pools: [String: BrokerDemand.PoolDemand] = [:]
            for (i, model) in order.enumerated() {
                policy.usageLanes["codex/\(model)"] = .chatGPT(labelContains: model)
                rows.append(.init(label: model, usedPercent: Double((run * 23 + i * 37) % 100),
                                  resetAt: now.addingTimeInterval(3600), windowRole: .chatGPTWeekly))
                pools["chatgpt::\(model)"] = .init(rateMilli: 0, windowDecisions: 6, ledgerDecisions: 5)
            }
            let tiers = BrokerPoolPricing.qualityTiers(ranked, groups: policy.equalQualityGroups(for: "review"))
            let byID = Dictionary(uniqueKeysWithValues: zip(ranked.map(\.id), tiers))
            let priced = BrokerPoolPricing.pricedOrder(ranked, role: "review", policy: policy,
                oracle: BrokerFixture.oracle(accounts: [], chatGPTRows: rows),
                demand: .init(historyDays: 3, historySufficient: true, roles: [:], pools: pools), now: now)
            XCTAssertEqual(priced.map { byID[$0.id]! }, tiers)
            XCTAssertEqual(Set(priced.map(\.id)), Set(ranked.map(\.id)))
        }
    }

    private func recordWorld(_ policy: BrokerPolicy, _ oracle: OracleSnapshot, _ demand: BrokerDemand,
                             cooldowns: [String: Date] = [:], t3: [String: T3Liveness] = [:], caller: String? = nil) throws -> BrokerDecision {
        try recordedDecide(role: "review", caller: caller, policy: policy, oracle: oracle,
                           cooldowns: cooldowns, now: now, t3: t3, demand: demand)
    }

    func test_nonAdjacentGroup_keepsChainOrder() throws {
        var (policy, oracle, demand) = crossModelWorld()
        policy.roles["review"]!.insert(.init(route: .native, model: "claude-middle"), at: 1)
        let pick = try recordWorld(policy, oracle, demand)
        XCTAssertEqual(pick.model, "native/claude-opus-5-5")
        XCTAssertEqual(pick.pickBasis, .quality)
    }

    func test_preferExpiringOff_keepsChainOrder() throws {
        var (policy, oracle, demand) = crossModelWorld()
        policy.thresholds.preferExpiringQuota = false
        let pick = try recordWorld(policy, oracle, demand)
        XCTAssertEqual(pick.model, "native/claude-opus-5-5")
        XCTAssertEqual(pick.pickBasis, .quality)
    }

    func test_pricingOffWithoutDemand_recordsSchemaOne() throws {
        var (policy, oracle, _) = crossModelWorld()
        policy.thresholds.preferExpiringQuota = false
        let pick = try recordedDecide(role: "review", caller: nil, policy: policy, oracle: oracle,
                                       cooldowns: [:], now: now, t3: [:])
        XCTAssertEqual(pick.model, "native/claude-opus-5-5")
        XCTAssertEqual(pick.pickBasis, .quality)
    }

    func test_shortHistory_keepsChainOrder() throws {
        var (policy, oracle, demand) = crossModelWorld()
        demand.historySufficient = false
        let pick = try recordWorld(policy, oracle, demand)
        XCTAssertEqual(pick.model, "native/claude-opus-5-5")
        XCTAssertEqual(pick.pickBasis, .quality)
    }

    func test_cheapestCandidateCapped_isPassedOver() throws {
        var (policy, oracle, demand) = crossModelWorld()
        // Its priced weekly pool is cheap; the independent session cap still gates.
        policy.thresholds.chatgptWeeklyPct = 100
        oracle = BrokerFixture.oracle(accounts: oracle.accounts, chatGPTRows: oracle.chatGPTRows + [
            .init(label: "Session", usedPercent: 100, windowSeconds: 18000)
        ], chatGPTConfigured: true)
        let pick = try recordWorld(policy, oracle, demand)
        XCTAssertEqual(pick.model, "native/claude-opus-5-5")
        XCTAssertEqual(pick.pickBasis, .quality)
        XCTAssertEqual(pick.candidatesTried.first?.candidate, "codex/gpt-6-astra")
        XCTAssertEqual(pick.candidatesTried.first?.available, false)
        XCTAssertFalse(pick.reason.contains("quota price favoured"))
    }

    func test_cheapestCandidateCooledDown_isPassedOver() throws {
        let (policy, oracle, demand) = crossModelWorld()
        let pick = try recordWorld(policy, oracle, demand, cooldowns: ["codex": now.addingTimeInterval(60)])
        XCTAssertEqual(pick.model, "native/claude-opus-5-5")
        XCTAssertEqual(pick.pickBasis, .quality)
    }

    func test_cheapestCandidateUnreachable_isPassedOver() throws {
        var (policy, oracle, demand) = crossModelWorld()
        policy.roles["review"]![1] = .init(route: .t3, instance: "alpha", model: "gpt-6-astra")
        let pick = try recordWorld(policy, oracle, demand)
        XCTAssertEqual(pick.model, "native/claude-opus-5-5")
        XCTAssertEqual(pick.pickBasis, .quality)
        XCTAssertEqual(pick.candidatesTried.first?.available, false)
    }

    func test_cheapestCandidateCallerFiltered_isPassedOver() throws {
        var (policy, oracle, demand) = crossModelWorld()
        policy.callers["limited"] = .init(routes: [.native])
        let pick = try recordWorld(policy, oracle, demand, caller: "limited")
        XCTAssertEqual(pick.model, "native/claude-opus-5-5")
        XCTAssertEqual(pick.pickBasis, .quality)
        XCTAssertEqual(pick.candidatesTried.first?.callerFiltered, true)
    }

    func test_pricedOrder_drivesBackups() throws {
        var (policy, oracle, demand) = crossModelWorld()
        policy.roles["review"]!.insert(.init(route: .native, model: "best"), at: 0)
        let pick = try recordWorld(policy, oracle, demand)
        XCTAssertEqual(pick.model, "native/best")
        XCTAssertEqual(pick.pickBasis, .quality)
        XCTAssertEqual(pick.backups.map(\.candidate), ["codex/gpt-6-astra", "native/claude-opus-5-5"])
    }

    func test_forcedDegraded_usesPricedOrderAndKeepsBasis() throws {
        var (policy, oracle, demand) = crossModelWorld()
        oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(weekly: 90)],
            chatGPTRows: oracle.chatGPTRows + [.init(label: "Session", usedPercent: 100, windowSeconds: 18000)],
            chatGPTConfigured: true)
        let pick = try recordWorld(policy, oracle, demand)
        XCTAssertEqual(pick.model, "codex/gpt-6-astra")
        XCTAssertEqual(pick.source, .forcedDegraded)
        XCTAssertEqual(pick.pickBasis, .quality)
        XCTAssertFalse(pick.reason.contains("quota price favoured"))
    }

    func test_pacedCheaperCandidate_isStillHeldBack() throws {
        var (policy, oracle, demand) = crossModelWorld()
        policy.roles["review"] = BrokerFixture.candidates(["native/claude-opus-5-5", "t3:alpha/claude-opus-5-5"])
        policy.t3Instances = [.init(id: "alpha", name: "Alpha", boundAccountId: "acct-secondary")]
        oracle = BrokerFixture.oracle(accounts: oracle.accounts + [
            BrokerFixture.account(id: "acct-secondary", label: "Account B", isPrimary: false,
                                  session: 70, weekly: 0, sessionResetAt: now.addingTimeInterval(4 * 3600),
                                  weeklyResetAt: now.addingTimeInterval(10 * 3600))
        ])
        demand.pools["claude:acct-secondary:weekly"] = .init(rateMilli: 0, windowDecisions: 6, ledgerDecisions: 12)
        let pick = try recordWorld(policy, oracle, demand, t3: BrokerFixture.reachable("alpha"))
        XCTAssertEqual(pick.candidatesTried.first?.candidate, "t3:alpha/claude-opus-5-5")
        XCTAssertEqual(pick.model, "native/claude-opus-5-5")
        XCTAssertEqual(pick.pickBasis, .quota)
        XCTAssertFalse(pick.reason.contains("quota price favoured"))
    }

    func test_sameModelRouteSwapByPrice_recordsQuotaBasis() throws {
        var (policy, oracle, demand) = crossModelWorld()
        policy.roles["review"] = BrokerFixture.candidates(["native/claude-opus-5-5", "t3:alpha/claude-opus-5-5"])
        policy.t3Instances = [.init(id: "alpha", name: "Alpha", boundAccountId: "acct-secondary")]
        // Headroom/hour favours native (80/10 > 90/20). Its high ledger rate
        // makes it expensive, so pool pricing favours the second account.
        oracle = BrokerFixture.oracle(accounts: [
            BrokerFixture.account(label: "Account A", weekly: 20, weeklyResetAt: now.addingTimeInterval(10 * 3600)),
            BrokerFixture.account(id: "acct-secondary", label: "Account B", isPrimary: false,
                                  weekly: 10, weeklyResetAt: now.addingTimeInterval(20 * 3600))
        ])
        demand.pools["claude:acct-primary:weekly"] = .init(rateMilli: 10000, windowDecisions: 6, ledgerDecisions: 12)
        demand.pools["claude:acct-secondary:weekly"] = .init(rateMilli: 0, windowDecisions: 6, ledgerDecisions: 12)
        let pick = try recordWorld(policy, oracle, demand, t3: BrokerFixture.reachable("alpha"))
        XCTAssertEqual(pick.model, "t3:alpha/claude-opus-5-5")
        XCTAssertEqual(pick.pickBasis, .quota)
        XCTAssertTrue(pick.reason.hasSuffix("; quota price favoured t3:alpha/claude-opus-5-5 over native/claude-opus-5-5"))
    }

    func test_shortHistoryDemand_reproducesEveryCommittedDecision() throws {
        try XCTSkipIf(GoldenFixture.exportDirectory() != nil, "Replay runs after the exporter exits.")
        let directory = GoldenFixture.decisionsDirectory
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".input.json") }.sorted { $0.path < $1.path }
        var count = 0
        for url in files {
            let input = try GoldenFixture.decoder().decode(GoldenInput.self, from: Data(contentsOf: url))
            guard input.schema == 1 else { continue }
            count += 1
            let name = String(url.lastPathComponent.dropLast(".input.json".count))
            let bytes: Data
            let suffix: String
            do {
                let pick: BrokerDecision
                if let override = input.overrideCandidate {
                    pick = try BrokerEngine.decideOverride(role: input.role, caller: input.caller, overrideCandidate: override,
                        policy: input.policy, oracle: input.oracle?.snapshot(), cooldowns: input.cooldowns,
                        now: input.now, t3: input.liveness(), executionContext: input.executionContext)
                } else {
                    pick = try BrokerEngine.decide(role: input.role, caller: input.caller, policy: input.policy,
                        oracle: input.oracle?.snapshot(), cooldowns: input.cooldowns, now: input.now, t3: input.liveness(),
                        demand: .init(historyDays: 0, historySufficient: false, roles: [:], pools: [:]), executionContext: input.executionContext)
                }
                bytes = try GoldenFixture.canonicalEncoder().encode(pick)
                suffix = "decision.json"
            } catch let error as BrokerError {
                bytes = try GoldenFixture.canonicalEncoder().encode(GoldenErrorFixture(error)!)
                suffix = "error.json"
            }
            XCTAssertEqual(bytes, try Data(contentsOf: directory.appendingPathComponent("\(name).\(suffix)")), name)
        }
        XCTAssertGreaterThan(count, 0)
    }
}
