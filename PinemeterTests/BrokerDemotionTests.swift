import Foundation
import XCTest
@testable import Pinemeter

final class BrokerDemotionTests: XCTestCase {
    private let now = BrokerFixture.now
    private let head = "claude-opus-5-5"
    private let next = "gpt-6-astra"

    private func world() -> (BrokerPolicy, OracleSnapshot) {
        let policy = BrokerFixture.policy(roles: ["review": ["native/claude-opus-5-5", "codex/gpt-6-astra"]],
            models: ["gpt-6-astra": .init(quota: .chatGPT(labelContains: nil))])
        let oracle = BrokerFixture.oracle(chatGPTRows: [.init(label: "Weekly", usedPercent: 20,
            windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
        return (policy, oracle)
    }

    private func health(_ models: [String], roles: [String] = [],
                        expiresAt: Date? = nil, validUntil: Date? = nil) -> BrokerHealthSnapshot {
        .init(validUntil: validUntil ?? now.addingTimeInterval(3600), demotions: models.map {
            .init(model: $0, roles: roles, expiresAt: expiresAt ?? now.addingTimeInterval(600))
        })
    }

    func test_executionDemotion_keepsPiDefaultLast() throws {
        let policy = BrokerPolicy.bundledDefault
        let order = BrokerEngine.expandingModelChoices(policy.roles["execution"]!, policy: policy, oracle: nil, now: now)
        let partition = BrokerDemotion.apply(order, unpriced: order, health: health(["gpt-6.1-sol"]),
            role: "execution", policy: policy, oracle: nil, now: now)
        XCTAssertEqual(partition.order.last?.id, "t3:pi/default")
        let pick = try recordedDecide(role: "execution", caller: nil, policy: policy, oracle: nil,
            cooldowns: ["native": now.addingTimeInterval(3600)], now: now,
            t3: ["pi": .init(reachable: true, why: "fixture"),
                 "t3:pi/default": .init(reachable: true, why: "infer http 200")],
            health: health(["gpt-6.1-sol"]))
        XCTAssertEqual(pick.model, "codex/gpt-6.1-sol")
        XCTAssertEqual(pick.backups.first?.candidate, "t3:pi/default")
    }

    func test_customExecutionPiFirst_demotionKeepsOrder() throws {
        var policy = BrokerPolicy.bundledDefault
        policy.thresholds.useModelHealth = true
        policy.scoring.roles.removeValue(forKey: "execution")
        policy.roles["execution"] = [
            .init(route: .t3, instance: "pi", model: "default"),
            .init(route: .codex, model: "gpt-6.1-sol")]
        let order = policy.roles["execution"]!
        let partition = BrokerDemotion.apply(order, unpriced: order, health: health(["gpt-6.1-sol"]),
            role: "execution", policy: policy, oracle: nil, now: now)
        XCTAssertEqual(partition.order, order)
        XCTAssertFalse(partition.applied)
        XCTAssertFalse(partition.skipped)
        let pick = try recordedDecide(role: "execution", caller: nil, policy: policy, oracle: nil,
            cooldowns: [:], now: now,
            t3: ["pi": .init(reachable: true, why: "fixture"),
                 "t3:pi/default": .init(reachable: true, why: "infer http 200")],
            health: health(["gpt-6.1-sol"]))
        XCTAssertEqual(pick.model, "t3:pi/default")
        XCTAssertEqual(pick.backups.first?.candidate, "codex/gpt-6.1-sol")
    }

    func test_demotedHead_movesBehindWithDriftBasis() throws {
        let (policy, oracle) = world()
        let pick = try recordedDecide(role: "review", caller: nil, policy: policy, oracle: oracle,
            cooldowns: [:], now: now, t3: [:], health: health([head]))
        XCTAssertEqual(pick.model, "codex/gpt-6-astra")
        XCTAssertEqual(pick.pickBasis, .drift)
        XCTAssertTrue(pick.reason.hasSuffix("; model health favoured codex/gpt-6-astra over native/claude-opus-5-5"))
        XCTAssertEqual(pick.backups.first?.candidate, "native/claude-opus-5-5")
    }

    private func pick(_ snapshot: BrokerHealthSnapshot?, policy: BrokerPolicy? = nil,
                      oracle: OracleSnapshot? = nil, role: String = "review", at: Date? = nil,
                      cooldowns: [String: Date] = [:], demand: BrokerDemand? = nil,
                      caller: String? = nil) throws -> BrokerDecision {
        let world = world()
        return try recordedDecide(role: role, caller: caller, policy: policy ?? world.0,
            oracle: oracle ?? world.1, cooldowns: cooldowns, now: at ?? now, t3: [:],
            demand: demand, health: snapshot)
    }

    private func assertUnchanged(_ decision: BrokerDecision, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(decision.model, "native/claude-opus-5-5", file: file, line: line)
        XCTAssertEqual(decision.pickBasis, .quality, file: file, line: line)
        XCTAssertFalse(decision.reason.contains("model health favoured"), file: file, line: line)
    }

    func test_absentSnapshot_keepsOrder() throws { assertUnchanged(try pick(nil)) }
    func test_emptyDemotions_keepsOrder() throws { assertUnchanged(try pick(health([]))) }
    func test_absentModel_isNoOp() throws { assertUnchanged(try pick(health(["unknown-model"]))) }
    func test_everyModelDemoted_keepsOrder() throws { assertUnchanged(try pick(health([head, next]))) }

    func test_onlyEligibleModelDemoted_skipsRole() throws {
        var (policy, oracle) = world()
        policy.scoring.roles["review"] = .init(floor: 500, quality: [
            head: ["_default": 512], next: ["_default": 496]])
        let order = policy.roles["review"]!
        let partition = BrokerDemotion.apply(order, unpriced: order, health: health([head]),
            role: "review", policy: policy, oracle: oracle, now: now)
        XCTAssertTrue(partition.skipped)
        XCTAssertFalse(partition.applied)
        XCTAssertEqual(partition.order, order)
        assertUnchanged(try pick(health([head]), policy: policy, oracle: oracle))
    }

    func test_nonDemotedQuotaGated_fallsBackToDemoted() throws {
        let oracle = BrokerFixture.oracle(chatGPTRows: [.init(label: "Weekly", usedPercent: 100,
            windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
        let decision = try pick(health([head]), oracle: oracle)
        assertUnchanged(decision)
        XCTAssertEqual(decision.candidatesTried.map(\.candidate), ["codex/gpt-6-astra", "native/claude-opus-5-5"])
        XCTAssertFalse(decision.candidatesTried[0].available)
    }

    func test_nonDemotedCooldown_fallsBackToDemoted() throws {
        let decision = try pick(health([head]), cooldowns: ["codex/gpt-6-astra": now.addingTimeInterval(60)])
        assertUnchanged(decision)
        XCTAssertTrue(decision.candidatesTried[0].why.contains("cooldown"))
    }

    func test_demotedCallerFiltered_isNeverBackup() throws {
        var (policy, _) = world()
        policy.callers["codex"] = .init(routes: [.codex])
        let decision = try pick(health([head]), policy: policy, caller: "codex")
        XCTAssertEqual(decision.model, "codex/gpt-6-astra")
        XCTAssertEqual(decision.pickBasis, .quality)
        XCTAssertFalse(decision.backups.contains { $0.candidate == "native/claude-opus-5-5" })
        XCTAssertFalse(decision.reason.contains("model health favoured"))
    }

    func test_oneSecondBeforeExpiry_applies() throws {
        let expiry = now.addingTimeInterval(1)
        let decision = try pick(health([head], expiresAt: expiry))
        XCTAssertEqual(decision.model, "codex/gpt-6-astra")
        XCTAssertEqual(decision.pickBasis, .drift)
    }

    func test_atExpiry_keepsOrder() throws {
        assertUnchanged(try pick(health([head], expiresAt: now)))
    }

    func test_validUntilPassed_keepsOrder() throws {
        assertUnchanged(try pick(health([head], validUntil: now.addingTimeInterval(-1))))
    }

    func test_atValidUntil_keepsOrder() throws { assertUnchanged(try pick(health([head], validUntil: now))) }

    func test_roleScoped_appliesToNamedRole() throws {
        XCTAssertEqual(try pick(health([head], roles: ["review"])).pickBasis, .drift)
    }

    func test_roleScoped_ignoresOtherRole() throws {
        assertUnchanged(try pick(health([head], roles: ["planning"])))
    }

    func test_architectureAlias_matchesPlanningEntry() throws {
        var (policy, _) = world()
        policy.roles["planning"] = policy.roles.removeValue(forKey: "review")
        let decision = try pick(health([head], roles: ["planning"]), policy: policy, role: "architecture")
        XCTAssertEqual(decision.role, "architecture")
        XCTAssertEqual(decision.model, "codex/gpt-6-astra")
        XCTAssertEqual(decision.pickBasis, .drift)
    }

    func test_useModelHealthFalse_keepsOrder() throws {
        var (policy, _) = world()
        policy.thresholds.useModelHealth = false
        assertUnchanged(try pick(health([head]), policy: policy))
    }

    func test_override_beatsDrift() throws {
        let (policy, oracle) = world()
        let decision = try recordedDecideOverride(role: "review", caller: nil,
            overrideCandidate: "native/claude-opus-5-5", policy: policy, oracle: oracle,
            cooldowns: [:], now: now, t3: [:], health: health([head]))
        XCTAssertEqual(decision.model, "native/claude-opus-5-5")
        XCTAssertEqual(decision.pickBasis, .humanOverride)
        XCTAssertFalse(decision.reason.contains("model health favoured"))
    }

    func test_forcedDegraded_usesPartitionWithoutDriftBasis() throws {
        var (policy, _) = world()
        policy.allowForcedDegraded["review"] = true
        let oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(session: 100, weekly: 100)],
            chatGPTRows: [.init(label: "Weekly", usedPercent: 100,
                windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
        let decision = try pick(health([head]), policy: policy, oracle: oracle)
        XCTAssertEqual(decision.model, "codex/gpt-6-astra")
        XCTAssertEqual(decision.source, .forcedDegraded)
        XCTAssertEqual(decision.pickBasis, .quality)
        XCTAssertFalse(decision.reason.contains("model health favoured"))
    }

    func test_cheapDemotedHead_staysBehindWithPricingOn() throws {
        var (policy, oracle, demand) = BrokerScoringTests.crossModelWorld()
        policy.roles["review"] = BrokerFixture.candidates(["codex/gpt-6-astra", "native/claude-opus-5-5"])
        policy.scoring.roles["review"] = .init(quality: [head: ["_default": 500], next: ["_default": 500]])
        let prices = BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: demand, now: now)
        XCTAssertEqual(prices.first { $0.pool == "chatgpt:Workspace A:Weekly" }?.priceLevel, 0)
        XCTAssertGreaterThan(try XCTUnwrap(prices.first { $0.pool == "claude:acct-primary:weekly" }?.priceLevel), 0)
        let decision = try pick(health([next]), policy: policy, oracle: oracle, demand: demand)
        XCTAssertEqual(decision.model, "native/claude-opus-5-5")
        XCTAssertEqual(decision.pickBasis, .drift)
        XCTAssertFalse(decision.reason.contains("quota price favoured"))
        XCTAssertTrue(decision.reason.hasSuffix("; model health favoured native/claude-opus-5-5 over codex/gpt-6-astra"))
    }

    func test_quotaAndDriftClauses_areOrdered() throws {
        var (policy, oracle, demand) = BrokerScoringTests.crossModelWorld()
        policy.scoring.roles["review"] = .init(quality: [head: ["_default": 512], next: ["_default": 496]])
        let decision = try pick(health([next]), policy: policy, oracle: oracle, demand: demand)
        XCTAssertEqual(decision.model, "native/claude-opus-5-5")
        XCTAssertEqual(decision.pickBasis, .drift)
        XCTAssertTrue(decision.reason.hasSuffix("; quota price favoured codex/gpt-6-astra over native/claude-opus-5-5; model health favoured native/claude-opus-5-5 over codex/gpt-6-astra"))
    }

    func test_stablePartition_preservesBothParts() throws {
        var (policy, oracle) = world()
        let order = BrokerFixture.candidates(["native/claude-opus-5-5", "codex/gpt-6-astra",
            "native/claude-sonnet-5-5", "codex/gpt-6.1-sol"])
        policy.roles["review"] = order
        policy.models["gpt-6.1-sol"] = .init(quota: .chatGPT(labelContains: nil))
        let snapshot = health([head, "claude-sonnet-5-5"])
        let partition = BrokerDemotion.apply(order, unpriced: order, health: snapshot,
            role: "review", policy: policy, oracle: oracle, now: now)
        XCTAssertEqual(partition.order.map(\.id), ["codex/gpt-6-astra", "codex/gpt-6.1-sol",
            "native/claude-opus-5-5", "native/claude-sonnet-5-5"])
        XCTAssertTrue(partition.applied)
        XCTAssertFalse(partition.skipped)
        let decision = try pick(snapshot, policy: policy, oracle: oracle)
        XCTAssertEqual(decision.model, "codex/gpt-6-astra")
        XCTAssertEqual(decision.backups.map(\.candidate), ["codex/gpt-6.1-sol", "native/claude-opus-5-5"])
    }
}
