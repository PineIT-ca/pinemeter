//
//  BrokerBackupOptionTests.swift
//  PinemeterTests
//
//  `BrokerEngine.collectBackups` ranks up to two fallbacks from what is left
//  of the chain after the winner, so a caller whose primary invocation fails
//  can act without a second `pick` call. These tests pin the ranking rules:
//  verified beats unverified beats gated, a structural caller filter is never
//  crossed, `t3:*` always expands to a concrete instance, both the policy and
//  forced-degraded paths carry backups, and the list is capped at two.
//
//  Reuses `BrokerFixture` from BrokerEngineTests.swift — same test target,
//  same table-driven fixture style.
//

import XCTest
@testable import Pinemeter

final class BrokerBackupOptionTests: XCTestCase {

    private func decide(
        role: String = "planning",
        caller: String? = nil,
        policy: BrokerPolicy,
        oracle: OracleSnapshot? = nil,
        cooldowns: [String: Date] = [:],
        t3: [String: T3Liveness] = [:]
    ) throws -> BrokerDecision {
        try BrokerEngine.decide(
            role: role,
            caller: caller,
            policy: policy,
            oracle: oracle,
            cooldowns: cooldowns,
            now: BrokerFixture.now,
            t3: t3
        )
    }

    // MARK: - Ranking

    func test_backups_rankedInChainOrderWhenEveryAlternateIsVerifiedAvailable() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": [
                "native/claude-fable-5", "native/claude-opus-5", "native/claude-sonnet-5",
            ]]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [BrokerFixture.account(session: 10, weekly: 20)])
        )

        XCTAssertEqual(decision.model, "native/claude-fable-5")
        XCTAssertEqual(
            decision.backups.map(\.candidate),
            ["native/claude-opus-5", "native/claude-sonnet-5"]
        )
        XCTAssertEqual(decision.backups.map(\.why), ["next in chain", "next in chain"])
        XCTAssertTrue(decision.backups.allSatisfy { $0.route == .native })
    }

    func test_backups_preferVerifiedOverUnverifiedOverGated() throws {
        // opus: verified (fresh oracle, in budget). codex: mapped to a chatGPT
        // lane with no fresh data, so it fails open (unverified but reachable).
        // t3: unmapped and otherwise fine, but put in cooldown so it is gated
        // outright — the strongest signal, checked before any route gate.
        let policy = BrokerFixture.policy(
            roles: ["planning": [
                "native/claude-fable-5",
                "t3/claude-fable-5",
                "codex/gpt-5.6-sol",
                "native/claude-opus-5",
            ]],
            usageLanes: ["codex/gpt-5.6-sol": .chatGPT(labelContains: nil)]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(
                accounts: [BrokerFixture.account(session: 10, weekly: 20)],
                chatGPTState: .stale,
                chatGPTRows: []
            ),
            cooldowns: BrokerFixture.cooldowns(["t3/claude-fable-5": 600]),
            t3: BrokerFixture.reachable("claudeAgent")
        )

        XCTAssertEqual(decision.model, "native/claude-fable-5")
        XCTAssertEqual(
            decision.backups.map(\.candidate),
            ["native/claude-opus-5", "codex/gpt-5.6-sol"],
            "the verified native pick and the unverified-but-reachable codex lane fill both slots"
        )
        XCTAssertEqual(decision.backups[0].why, "next in chain")
        XCTAssertTrue(decision.backups[1].why.hasPrefix("headroom unverified"), decision.backups[1].why)
        XCTAssertFalse(
            decision.backups.contains { $0.candidate == "t3/claude-fable-5" },
            "the cooling candidate is strictly worse than two better alternates, so it never fills a slot"
        )
    }

    // MARK: - Empty chain

    func test_backups_emptyWhenTheChainHasOnlyOneCandidate() throws {
        let policy = BrokerFixture.policy(roles: ["planning": ["native/claude-fable-5"]])

        let decision = try decide(policy: policy, oracle: BrokerFixture.oracle())

        XCTAssertTrue(decision.backups.isEmpty)
    }

    // MARK: - Caller filter

    func test_backups_neverIncludeAStructurallyFilteredCandidate() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3/claude-fable-5", "native/claude-opus-5"]],
            callers: ["codex": BrokerCallerPolicy(routes: [.t3])]
        )

        let decision = try decide(
            caller: "codex",
            policy: policy,
            oracle: BrokerFixture.oracle(),
            t3: BrokerFixture.reachable("claudeAgent")
        )

        XCTAssertEqual(decision.model, "t3/claude-fable-5")
        XCTAssertTrue(
            decision.backups.isEmpty,
            "the only remaining candidate is a route the caller cannot invoke at all"
        )
    }

    func test_backups_skipADeniedCandidateButOfferTheNextOne() throws {
        let denied = BrokerFixture.candidates(["t3/gpt-5.6-sol"])
        let policy = BrokerFixture.policy(
            roles: ["execution": ["t3/claude-fable-5", "t3/gpt-5.6-sol", "codex/gpt-5.6-sol"]],
            callers: ["codex": BrokerCallerPolicy(routes: [.t3, .codex], denyCandidates: denied)]
        )

        let decision = try decide(
            role: "execution",
            caller: "codex",
            policy: policy,
            oracle: BrokerFixture.oracle(),
            t3: BrokerFixture.reachable("claudeAgent")
        )

        XCTAssertEqual(decision.model, "t3/claude-fable-5")
        XCTAssertEqual(
            decision.backups.map(\.candidate), ["codex/gpt-5.6-sol"],
            "the denied candidate is skipped, but the next invocable one still fills the slot"
        )
        XCTAssertEqual(decision.backups.first?.invocation, .agent(model: "gpt-5.6-sol"))
    }

    // MARK: - `t3:*` expansion

    func test_backups_expandAnyInstanceToAConcreteInstanceId() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["native/claude-fable-5", "t3:*/claude-fable-5"]],
            t3Instances: [
                T3InstanceConfig(
                    id: "alpha", name: "Alpha", boundAccountId: "acct-a",
                    detectedModels: ["claude-fable-5"]
                ),
                T3InstanceConfig(
                    id: "beta", name: "Beta", boundAccountId: "acct-b",
                    detectedModels: ["claude-fable-5"]
                ),
            ]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(session: 5, weekly: 5),
                BrokerFixture.account(id: "acct-a", label: "A", isPrimary: false, session: 10, weekly: 60),
                BrokerFixture.account(id: "acct-b", label: "B", isPrimary: false, session: 10, weekly: 10),
            ]),
            t3: BrokerFixture.reachable("alpha", "beta")
        )

        XCTAssertEqual(decision.model, "native/claude-fable-5")
        XCTAssertEqual(
            decision.backups.map(\.candidate),
            ["t3:beta/claude-fable-5", "t3:alpha/claude-fable-5"],
            "a backup must name a concrete instance, ranked by headroom like the primary walk"
        )
        XCTAssertTrue(decision.backups.allSatisfy { $0.route == .t3 })
        XCTAssertEqual(
            decision.backups.map(\.invocation),
            [
                .t3Dispatch(model: "claude-fable-5", instanceId: "beta"),
                .t3Dispatch(model: "claude-fable-5", instanceId: "alpha"),
            ]
        )
    }

    // MARK: - Forced-degraded

    func test_backups_stillPresentOnAForcedDegradedDecision() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": [
                "native/claude-fable-5", "native/claude-opus-5", "native/claude-sonnet-5",
            ]]
        )
        let cappedOracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(session: 99, weekly: 99)])

        let decision = try decide(policy: policy, oracle: cappedOracle)

        XCTAssertEqual(decision.source, .forcedDegraded)
        XCTAssertEqual(decision.model, "native/claude-fable-5")
        XCTAssertEqual(
            decision.backups.map(\.candidate),
            ["native/claude-opus-5", "native/claude-sonnet-5"]
        )
        XCTAssertTrue(
            decision.backups.allSatisfy { $0.why.contains("gated") },
            "nothing had headroom, so every offered backup is a last resort and must say so"
        )
    }

    // MARK: - Cap

    func test_backups_capAtTwoEvenWithMoreVerifiedAlternatesInTheChain() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": [
                "native/claude-fable-5", "native/claude-opus-5",
                "native/claude-sonnet-5", "codex/gpt-5.6-sol",
            ]]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [BrokerFixture.account(session: 10, weekly: 20)])
        )

        XCTAssertEqual(decision.backups.count, 2)
        XCTAssertEqual(
            decision.backups.map(\.candidate),
            ["native/claude-opus-5", "native/claude-sonnet-5"]
        )
    }

    // MARK: - Gated candidates as a last resort only

    func test_backups_includeAGatedCandidateOnlyToFillARemainingSlot() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": [
                "native/claude-fable-5", "native/claude-opus-5", "t3/claude-fable-5",
            ]]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [BrokerFixture.account(session: 10, weekly: 20)]),
            cooldowns: BrokerFixture.cooldowns(["t3/claude-fable-5": 600]),
            t3: BrokerFixture.reachable("claudeAgent")
        )

        XCTAssertEqual(
            decision.backups.map(\.candidate),
            ["native/claude-opus-5", "t3/claude-fable-5"],
            "only one verified alternate exists, so the cooling candidate fills the open second slot"
        )
        XCTAssertTrue(decision.backups[1].why.contains("gated"), decision.backups[1].why)
        XCTAssertTrue(decision.backups[1].why.contains("cooldown"), decision.backups[1].why)
    }

    func test_backups_excludeAGatedCandidateWhenTwoBetterAlternatesFillTheCap() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": [
                "native/claude-fable-5", "native/claude-opus-5",
                "native/claude-sonnet-5", "t3/claude-fable-5",
            ]]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [BrokerFixture.account(session: 10, weekly: 20)]),
            cooldowns: BrokerFixture.cooldowns(["t3/claude-fable-5": 600]),
            t3: BrokerFixture.reachable("claudeAgent")
        )

        XCTAssertEqual(
            decision.backups.map(\.candidate),
            ["native/claude-opus-5", "native/claude-sonnet-5"]
        )
        XCTAssertFalse(
            decision.backups.contains { $0.candidate == "t3/claude-fable-5" },
            "two verified alternates already fill the cap, so the gated candidate is never offered"
        )
    }
}
