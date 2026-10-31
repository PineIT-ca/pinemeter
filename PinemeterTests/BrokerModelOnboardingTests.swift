import Foundation
import XCTest
@testable import Pinemeter

final class BrokerModelOnboardingTests: XCTestCase {
    private let now = BrokerFixture.now
    private let haiku = "claude-haiku-5-5"
    private let sonnet = "claude-sonnet-5-5"
    private let luna = "gpt-6-luna"

    /// A new model must have an established model in the next two chain positions.
    private func violations(_ chain: [BrokerCandidate], established: Set<String>) -> [Int] {
        chain.indices.filter { index in
            !established.contains(chain[index].model) && chain[index].id != "t3:pi/default" &&
                !chain.dropFirst(index + 1).prefix(2).contains { established.contains($0.model) }
        }
    }

    func test_onboardingRule_flagsUnsafePlacements() {
        for (models, expected) in [
            (["new"], [0]), (["est", "new"], [1]),
            (["new", "new2", "new3", "est"], [0]),
            (["est", "new", "est"], []), (["new", "new2", "est"], []),
        ] {
            let chain = models.map { BrokerCandidate(route: .auto, model: $0) }
            XCTAssertEqual(violations(chain, established: ["est"]), expected, "\(models)")
        }
    }

    private func shippedPresets() throws -> [BrokerAgentProfile] {
        let url = try XCTUnwrap(BrokerPresetManifestTests.bundledManifestURL())
        let presets = try BrokerPresetManifest.decode(from: Data(contentsOf: url)).presets
        XCTAssertEqual(presets.count, 7)
        return presets
    }

    private func establishedModels() throws -> Set<String> {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("TestSupport/broker-presets-phase27-base.json")
        let presets = try BrokerPresetManifest.decode(from: Data(contentsOf: url)).presets
        XCTAssertEqual(presets.count, 7)
        return Set(presets.flatMap { $0.rules.roles.values.flatMap { $0.map(\.model) } })
    }

    func test_shippedPresets_newModelsHaveEstablishedFallbacks() throws {
        let established = try establishedModels()
        var onboarded = Set<String>()
        for preset in try shippedPresets() {
            for (role, chain) in preset.rules.roles {
                onboarded.formUnion(chain.filter { $0.id != "t3:pi/default" }.map(\.model).filter { !established.contains($0) })
                XCTAssertEqual(violations(chain, established: established), [], "\(preset.name)/\(role)")
            }
        }
        XCTAssertEqual(onboarded, [], "Routes verdict none: no new model may enter shipped chains.")
    }

    private func expandedPolicy(_ preset: BrokerAgentProfile, established: Set<String>) -> BrokerPolicy {
        var policy = BrokerPolicy.bundledDefault
        policy.apply(preset.rules)
        let models = Set(policy.roles.values.flatMap { $0.map(\.model) }).filter {
            (established.contains($0) && $0.hasPrefix("claude-")) ||
                (!established.contains($0) && policy.agentModelAliases[$0] == nil)
        }.sorted()
        policy.t3 = .init(instanceByModel: [:], defaultInstance: "alpha")
        policy.t3Instances = ["alpha", "beta"].map {
            .init(id: $0, name: $0, boundAccountId: "acct-primary", origin: .detected,
                  driver: "claudeAgent", detectedModels: models, lastSeenAt: now)
        }
        policy.usageLanes = [:]
        return policy
    }

    private func neutralWorld(_ policy: BrokerPolicy) -> (OracleSnapshot, BrokerDemand) {
        let reset = now.addingTimeInterval(96 * 3600)
        let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(
            session: 0, weekly: 0, sonnet: 0, fable: 0,
            weeklyResetAt: reset, sonnetResetAt: reset, fableResetAt: reset)],
            chatGPTRows: [.init(label: "Codex weekly", usedPercent: 0, resetAt: reset,
                windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
        let keys = ["claude:acct-primary:weekly", "claude:acct-primary:sonnet",
                    "claude:acct-primary:fable", "chatgpt:Workspace A:Codex weekly"]
        let demand = BrokerDemand(historyDays: 3, historySufficient: true,
            roles: policy.roles.mapValues { _ in 100 }, pools: Dictionary(uniqueKeysWithValues: keys.map {
                ($0, BrokerDemand.PoolDemand(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12))
            }))
        return (oracle, demand)
    }

    func test_shippedOnboardedModels_alwaysListEstablishedBackup() throws {
        let established = try establishedModels()
        var checked = 0
        for preset in try shippedPresets() {
            let policy = expandedPolicy(preset, established: established)
            let (oracle, _) = neutralWorld(policy)
            for (role, chain) in policy.roles {
                for index in chain.indices where !established.contains(chain[index].model) && chain[index].id != "t3:pi/default" {
                    checked += 1
                    let candidate = chain[index]
                    for caller in ["claude-code", "codex"] {
                        let heads = BrokerEngine.expandingModelChoices(Array(chain.prefix(index)), policy: policy,
                            oracle: oracle, now: now)
                        var cooldowns = Dictionary(uniqueKeysWithValues: heads.map { ($0.id, now.addingTimeInterval(3600)) })
                        let pick = try BrokerEngine.decide(role: role, caller: caller, policy: policy, oracle: oracle,
                            cooldowns: cooldowns, now: now, t3: BrokerFixture.reachable("alpha", "beta"))
                        XCTAssertEqual(String(pick.model.split(separator: "/", maxSplits: 1)[1]), candidate.model,
                            "\(preset.name)/\(role)/\(caller)")
                        XCTAssertTrue(pick.backups.contains { established.contains($0.model) }, "\(preset.name)/\(role)/\(caller)")
                        for route in BrokerEngine.expandingModelChoices([candidate], policy: policy, oracle: oracle, now: now) {
                            cooldowns[route.id] = now.addingTimeInterval(3600)
                        }
                        let fallback = try BrokerEngine.decide(role: role, caller: caller, policy: policy, oracle: oracle,
                            cooldowns: cooldowns, now: now, t3: BrokerFixture.reachable("alpha", "beta"))
                        XCTAssertTrue(established.contains(String(fallback.model.split(separator: "/", maxSplits: 1)[1])))
                    }
                }
            }
        }
        XCTAssertEqual(checked, 0, "Routes verdict none: no onboarded entries.")
    }

    func test_neutralPrices_keepShippedOrderWithT3RoutesExpanded() throws {
        let established = try establishedModels()
        var checked = 0
        for preset in try shippedPresets() {
            let policy = expandedPolicy(preset, established: established)
            let (oracle, demand) = neutralWorld(policy)
            let prices = BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: demand, now: now)
            XCTAssertEqual(prices.count, 4, preset.name)
            XCTAssertEqual(prices.map(\.price), [500, 500, 500, 500], preset.name)
            var plain = policy
            plain.scoring = .empty
            plain.equalQuality = [:]
            for role in policy.roles.keys.sorted() {
                for caller in ["claude-code", "codex"] {
                    checked += 1
                    let rows = try BrokerScoringEngine.scoredRole(role: role, policy: policy, oracle: oracle, demand: demand, now: now)
                    XCTAssertFalse(rows.rows.isEmpty, "\(preset.name)/\(role)")
                    XCTAssertEqual(rows.rows.map(\.position), rows.rows.map(\.neutralPosition), "\(preset.name)/\(role)/\(caller)")
                    let neutral = try BrokerEngine.decide(role: role, caller: caller, policy: plain, oracle: oracle,
                        cooldowns: [:], now: now, t3: BrokerFixture.reachable("alpha", "beta"))
                    let priced = try BrokerEngine.decide(role: role, caller: caller, policy: policy, oracle: oracle,
                        cooldowns: [:], now: now, t3: BrokerFixture.reachable("alpha", "beta"), demand: demand)
                    XCTAssertEqual(priced, neutral, "\(preset.name)/\(role)/\(caller)")
                }
            }
        }
        XCTAssertEqual(checked, 140)
    }

    private func fixedPolicy() -> BrokerPolicy {
        let levels = BrokerEffortCapability(levels: BrokerEffort.builtInLevels, nilLabel: "Provider default")
        var policy = BrokerFixture.policy(roles: ["explore": []],
            t3: .init(instanceByModel: [:], defaultInstance: "alpha"),
            t3Instances: ["alpha", "beta"].map {
                .init(id: $0, name: $0, boundAccountId: "acct-secondary", origin: .detected,
                      driver: "claudeAgent", detectedModels: [haiku, sonnet], lastSeenAt: now)
            },
            models: [luna: .init(quota: .chatGPT(labelContains: "codex weekly"), effort: levels),
                     haiku: .init(effort: levels), sonnet: .init(effort: levels)],
            agentModelAliases: [sonnet: "sonnet"])
        policy.roles["explore"] = [.init(route: .auto, model: luna, effort: .medium),
                                   .init(route: .auto, model: haiku, effort: .medium),
                                   .init(route: .auto, model: sonnet, effort: .low)]
        policy.scoring = .init(latency: [haiku: ["medium": 11], sonnet: ["low": 6]],
            roles: ["explore": .init(floor: 299, latencyLimit: 11,
                quality: [luna: ["medium": 299], haiku: ["medium": 345], sonnet: ["low": 359]])])
        return policy
    }

    private func fixedOracle(chatGPT: Double = 95, secondary: Double = 10, priced: Bool = false) -> OracleSnapshot {
        let reset = now.addingTimeInterval(10 * 3600)
        return BrokerFixture.oracle(accounts: [
            BrokerFixture.account(weekly: 10, weeklyResetAt: reset),
            BrokerFixture.account(id: "acct-secondary", label: "Secondary", isPrimary: false,
                                  weekly: secondary, weeklyResetAt: reset)],
            chatGPTRows: [.init(label: "Codex weekly", usedPercent: chatGPT,
                resetAt: priced ? now.addingTimeInterval(60 * 3600) : reset,
                windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
    }

    private func assertAndRecord(oracle: OracleSnapshot, cooldowns: [String: Date] = [:],
                                 liveness: [String: T3Liveness] = BrokerFixture.reachable("alpha", "beta"),
                                 demand: BrokerDemand? = nil, winner: String) throws {
        let policy = fixedPolicy()
        let prices = BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: demand, now: now)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: prices.map { ($0.pool, $0.priceLevel) }), [
            "claude:acct-primary:weekly": demand == nil ? 4 : 0,
            "claude:acct-secondary:weekly": demand == nil ? 4 : 0,
            "chatgpt:Workspace A:Codex weekly": 4,
        ])
        let pick = try BrokerEngine.decide(role: "explore", caller: "claude-code", policy: policy, oracle: oracle,
            cooldowns: cooldowns, now: now, t3: liveness, demand: demand)
        XCTAssertEqual(pick.model, winner)
        if winner.hasSuffix("/\(haiku)") {
            XCTAssertTrue(pick.backups.contains { [luna, sonnet].contains($0.model) })
            XCTAssertEqual(pick.effort, .medium)
        } else {
            XCTAssertEqual(pick.model, "native/\(sonnet)")
        }
        if demand != nil {
            XCTAssertEqual(pick.pickBasis, .quota)
            XCTAssertFalse(pick.reason.contains("; quota price raised effort"))
        }
        XCTAssertEqual(try recordedDecide(role: "explore", caller: "claude-code", policy: policy, oracle: oracle,
            cooldowns: cooldowns, now: now, t3: liveness, demand: demand), pick)
    }

    func test_onboardedModelBehindGatedHead_listsEstablishedBackup() throws {
        try assertAndRecord(oracle: fixedOracle(), winner: "t3:alpha/\(haiku)")
    }

    func test_onboardedModelPricedAhead_listsEstablishedBackup() throws {
        let demand = BrokerDemand(historyDays: 3, historySufficient: true, roles: ["explore": 100], pools: [
            "claude:acct-primary:weekly": .init(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12),
            "claude:acct-secondary:weekly": .init(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12),
            "chatgpt:Workspace A:Codex weekly": .init(rateMilli: 100, windowDecisions: 6, ledgerDecisions: 12),
        ])
        try assertAndRecord(oracle: fixedOracle(chatGPT: 70, priced: true), demand: demand, winner: "t3:alpha/\(haiku)")
    }

    func test_onboardedModelCooledDown_fallsBackToEstablished() throws {
        try assertAndRecord(oracle: fixedOracle(), cooldowns: BrokerFixture.cooldowns([
            "t3:alpha/\(haiku)": 3600, "t3:beta/\(haiku)": 3600]), winner: "native/\(sonnet)")
    }

    func test_onboardedModelInstancesUnreachable_fallsBackToEstablished() throws {
        try assertAndRecord(oracle: fixedOracle(), liveness: [
            "alpha": .init(reachable: false, why: "connection refused"),
            "beta": .init(reachable: false, why: "connection refused"),
        ], winner: "native/\(sonnet)")
    }

    func test_onboardedModelQuotaGated_fallsBackToEstablished() throws {
        try assertAndRecord(oracle: fixedOracle(secondary: 95), winner: "native/\(sonnet)")
    }
}
