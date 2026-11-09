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

    // MARK: - Remedy, agent action, credential provider (D-01)

    func test_chatGPTDisconnected_credentialProviderIsChatGPT() {
        XCTAssertEqual(BrokerProviderFault.chatGPTDisconnected.credentialProvider, .chatGPT)
    }

    func test_claudeAccountDisconnected_credentialProviderIsClaude() {
        XCTAssertEqual(
            BrokerProviderFault.claudeAccountDisconnected(label: "Work").credentialProvider, .claude
        )
    }

    func test_chatGPTDisconnected_operatorRemedy_namesSiteAndRescanAndCodexDependency() {
        XCTAssertEqual(
            BrokerProviderFault.chatGPTDisconnected.operatorRemedy,
            "Codex routes use the ChatGPT account. Sign in at chatgpt.com in your browser, then choose Rescan browsers in Pinemeter."
        )
    }

    func test_claudeAccountDisconnected_operatorRemedy_namesSiteLabelAndRescan() {
        XCTAssertEqual(
            BrokerProviderFault.claudeAccountDisconnected(label: "Work").operatorRemedy,
            "Sign in to the Claude account \"Work\" at claude.ai in your browser, then choose Rescan browsers in Pinemeter."
        )
    }

    func test_chatGPTDisconnected_agentAction_asksOperatorAndNamesCodexDependency() {
        XCTAssertEqual(
            BrokerProviderFault.chatGPTDisconnected.agentAction,
            "Ask the operator to sign in at chatgpt.com in a browser and choose Rescan browsers in Pinemeter, then call pick again with the same role and caller. Codex routes use the ChatGPT account."
        )
    }

    func test_claudeAccountDisconnected_agentAction_asksOperatorWithLabel() {
        XCTAssertEqual(
            BrokerProviderFault.claudeAccountDisconnected(label: "Work").agentAction,
            "Ask the operator to sign in to the Claude account \"Work\" at claude.ai in a browser and choose Rescan browsers in Pinemeter, then call pick again with the same role and caller."
        )
    }
}

// MARK: - decide() suggested_action (D-01)
//
// The remedy and agent action only matter if `decide()` actually surfaces
// them on the winning decision. These lock that wiring end to end.

final class BrokerProviderFaultDecideTests: XCTestCase {
    private func executionPolicy() -> BrokerPolicy {
        BrokerFixture.policy(
            roles: ["execution": ["codex/gpt-5.6-sol", "native/claude-sonnet-5"]],
            usageLanes: ["codex/gpt-5.6-sol": .chatGPT(labelContains: "codex weekly")]
        )
    }

    func test_erroredChatGPTOracle_decisionCarriesFaultSuggestedAction() throws {
        let decision = try recordedDecide(
            role: "execution",
            caller: nil,
            policy: executionPolicy(),
            oracle: BrokerFixture.oracle(chatGPTState: .error),
            cooldowns: [:],
            now: BrokerFixture.now,
            t3: [:]
        )

        XCTAssertEqual(decision.model, "codex/gpt-5.6-sol")
        XCTAssertTrue(decision.degraded)
        XCTAssertEqual(decision.retryable, true)
        XCTAssertEqual(decision.suggestedAction, BrokerProviderFault.chatGPTDisconnected.agentAction)
    }

    func test_staleChatGPTOracle_decisionKeepsRefreshAndRepickAction() throws {
        let decision = try recordedDecide(
            role: "execution",
            caller: nil,
            policy: executionPolicy(),
            oracle: BrokerFixture.oracle(chatGPTState: .stale),
            cooldowns: [:],
            now: BrokerFixture.now,
            t3: [:]
        )

        XCTAssertEqual(decision.model, "codex/gpt-5.6-sol")
        XCTAssertTrue(decision.degraded)
        XCTAssertEqual(decision.retryable, true)
        XCTAssertEqual(decision.suggestedAction, BrokerDecision.refreshAndRepickAction)
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
            "codex/gpt-6-astra ChatGPT usage poll is failing (account disconnected); failing open. "
                + "Codex routes use the ChatGPT account. Sign in at chatgpt.com in your browser, "
                + "then choose Rescan browsers in Pinemeter."
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
