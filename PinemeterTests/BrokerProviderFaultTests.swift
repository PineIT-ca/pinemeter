//
//  BrokerProviderFaultTests.swift
//  PinemeterTests
//
//  The shared classifier behind two consumers: the prose the calling agent
//  reads in `degraded_reason`, and the title the operator sees on the
//  degraded-pick modal. Both must name the same cause, so both read this.
//
//  The distinction under test is the one PR #96 drew for the native oracle
//  path and never carried to the quota-blind path: a poll that FAILED is not
//  the same event as data that is merely OLD. Only the former is a fault, and
//  only the former needs a human.
//

import XCTest
@testable import Pinemeter

final class BrokerProviderFaultTests: XCTestCase {
    private func candidate(_ id: String) -> BrokerCandidate {
        BrokerFixture.candidates([id])[0]
    }

    // MARK: - ChatGPT lanes

    func test_chatGPTLane_withErroredPoll_reportsDisconnected() {
        let policy = BrokerFixture.policy(
            roles: ["heavy": ["codex/gpt-6-astra"]],
            usageLanes: ["codex/gpt-6-astra": .chatGPT(labelContains: nil)]
        )
        let oracle = BrokerFixture.oracle(chatGPTState: .error, chatGPTConfigured: true)

        XCTAssertEqual(
            BrokerEngine.providerFault(
                for: candidate("codex/gpt-6-astra"),
                policy: policy,
                oracle: oracle
            ),
            .chatGPTDisconnected
        )
    }

    func test_chatGPTLane_withStaleData_reportsNoFault() {
        let policy = BrokerFixture.policy(
            roles: ["heavy": ["codex/gpt-6-astra"]],
            usageLanes: ["codex/gpt-6-astra": .chatGPT(labelContains: nil)]
        )
        let oracle = BrokerFixture.oracle(chatGPTState: .stale, chatGPTConfigured: true)

        XCTAssertNil(
            BrokerEngine.providerFault(
                for: candidate("codex/gpt-6-astra"),
                policy: policy,
                oracle: oracle
            ),
            "stale data means the account still answers; waiting fixes it and no human is needed"
        )
    }

    func test_chatGPTLane_neverFetched_reportsNoFault() {
        let policy = BrokerFixture.policy(
            roles: ["heavy": ["codex/gpt-6-astra"]],
            usageLanes: ["codex/gpt-6-astra": .chatGPT(labelContains: nil)]
        )
        let oracle = BrokerFixture.oracle(chatGPTState: .unavailable, chatGPTConfigured: false)

        XCTAssertNil(
            BrokerEngine.providerFault(
                for: candidate("codex/gpt-6-astra"),
                policy: policy,
                oracle: oracle
            ),
            "a machine that never fetched is unconfigured, not broken; claiming a disconnect would be a lie"
        )
    }

    // MARK: - Claude account lanes

    func test_claudeAccountLane_withErroredRow_reportsDisconnectedWithLabel() {
        let policy = BrokerFixture.policy(
            roles: ["review": ["t3:claudeAgent/claude-opus-5"]],
            t3Instances: [T3InstanceConfig(id: "claudeAgent", name: "Claude Agent", boundAccountId: "acct-work")],
            usageLanes: [
                "t3:claudeAgent/claude-opus-5": .claudeAccount(
                    accountId: "acct-work", labelContains: nil, isPrimary: nil
                )
            ]
        )
        let oracle = BrokerFixture.oracle(accounts: [
            BrokerFixture.account(id: "acct-work", label: "work-account", isPrimary: false, state: .error)
        ])

        XCTAssertEqual(
            BrokerEngine.providerFault(
                for: candidate("t3:claudeAgent/claude-opus-5"),
                policy: policy,
                oracle: oracle
            ),
            .claudeAccountDisconnected(label: "work-account")
        )
    }

    func test_claudeAccountLane_withFreshRow_reportsNoFault() {
        let policy = BrokerFixture.policy(
            roles: ["review": ["t3:claudeAgent/claude-opus-5"]],
            t3Instances: [T3InstanceConfig(id: "claudeAgent", name: "Claude Agent", boundAccountId: "acct-work")],
            usageLanes: [
                "t3:claudeAgent/claude-opus-5": .claudeAccount(
                    accountId: "acct-work", labelContains: nil, isPrimary: nil
                )
            ]
        )
        let oracle = BrokerFixture.oracle(accounts: [
            BrokerFixture.account(id: "acct-work", label: "work-account", isPrimary: false, state: .fresh)
        ])

        XCTAssertNil(
            BrokerEngine.providerFault(
                for: candidate("t3:claudeAgent/claude-opus-5"),
                policy: policy,
                oracle: oracle
            )
        )
    }

    // MARK: - Absent inputs

    func test_unmappedCandidate_reportsNoFault() {
        let policy = BrokerFixture.policy(roles: ["heavy": ["native/claude-opus-5"]])

        XCTAssertNil(
            BrokerEngine.providerFault(
                for: candidate("native/claude-opus-5"),
                policy: policy,
                oracle: BrokerFixture.oracle(chatGPTState: .error)
            ),
            "no lane means no claim about a provider; an errored ChatGPT poll says nothing about a native pick"
        )
    }

    func test_absentOracle_reportsNoFault() {
        let policy = BrokerFixture.policy(
            roles: ["heavy": ["codex/gpt-6-astra"]],
            usageLanes: ["codex/gpt-6-astra": .chatGPT(labelContains: nil)]
        )

        XCTAssertNil(
            BrokerEngine.providerFault(
                for: candidate("codex/gpt-6-astra"),
                policy: policy,
                oracle: nil
            ),
            "not knowing is not evidence of a fault, matching the rule the rest of the walk already follows"
        )
    }
}

// MARK: - Reason rendering
//
// The classifier only earns its place if the caller actually reads the cause.
// These lock the prose that reaches `degraded_reason`, which the MCP contract
// requires callers to render verbatim.

final class BrokerProviderFaultReasonTests: XCTestCase {
    private func candidate(_ id: String) -> BrokerCandidate {
        BrokerFixture.candidates([id])[0]
    }

    private func chatGPTPolicy() -> BrokerPolicy {
        BrokerFixture.policy(
            roles: ["heavy": ["codex/gpt-6-astra"]],
            usageLanes: ["codex/gpt-6-astra": .chatGPT(labelContains: nil)]
        )
    }

    func test_quotaBlind_withErroredPoll_namesTheCauseNotTheSymptom() throws {
        let evaluation = try XCTUnwrap(
            BrokerEngine.quotaBlindEvaluation(
                for: candidate("codex/gpt-6-astra"),
                policy: chatGPTPolicy(),
                oracle: BrokerFixture.oracle(chatGPTState: .error, chatGPTConfigured: true),
                suffix: "failing open"
            )
        )

        XCTAssertTrue(evaluation.available)
        XCTAssertTrue(evaluation.failOpen)
        XCTAssertEqual(
            evaluation.why,
            "codex/gpt-6-astra ChatGPT usage poll is failing (account disconnected); failing open"
        )
        XCTAssertFalse(
            evaluation.why.contains("no fresh data"),
            "an agent told only that data is missing cannot tell whether waiting helps"
        )
    }

    func test_quotaBlind_withStaleData_keepsTheOriginalNoFreshDataWording() throws {
        let evaluation = try XCTUnwrap(
            BrokerEngine.quotaBlindEvaluation(
                for: candidate("codex/gpt-6-astra"),
                policy: chatGPTPolicy(),
                oracle: BrokerFixture.oracle(chatGPTState: .stale, chatGPTConfigured: true),
                suffix: "failing open"
            )
        )

        XCTAssertEqual(
            evaluation.why,
            "codex/gpt-6-astra lane oracle has no fresh data; failing open",
            "staleness is not a fault and must not be reported as a disconnect"
        )
    }

    func test_quotaBlind_withErroredPoll_staysFailOpenAndNotUnconfigured() throws {
        let evaluation = try XCTUnwrap(
            BrokerEngine.quotaBlindEvaluation(
                for: candidate("codex/gpt-6-astra"),
                policy: chatGPTPolicy(),
                oracle: BrokerFixture.oracle(chatGPTState: .error, chatGPTConfigured: true),
                suffix: "failing open"
            )
        )

        XCTAssertFalse(
            evaluation.unconfigured,
            "an errored poll proves the account exists, so it must not be demoted as unconfigured"
        )
    }
}
