//
//  BrokerEngineTests.swift
//  PinemeterTests
//
//  Table-driven decision-semantics suite for the pure broker engine. Every
//  input is injected (policy, oracle snapshot, cooldown map, clock, T3
//  liveness), so nothing here touches the filesystem, the network or the
//  wall clock — the same test architecture the reference broker CLI uses.
//
//  The port contract is 07-RESEARCH.md "Reference Implementation: Decision
//  Semantics"; byte-parity with the CLI is deliberately not an acceptance bar.
//

import XCTest
@testable import Pinemeter

// MARK: - Fixtures

/// Small builders so each case declares only what it varies.
enum BrokerFixture {
    /// The single instant every case is evaluated at. No test may read the clock.
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func candidates(_ ids: [String]) -> [BrokerCandidate] {
        ids.map { id in
            guard let candidate = BrokerCandidate(id: id) else {
                fatalError("fixture used a malformed candidate id '\(id)'")
            }
            return candidate
        }
    }

    static func policy(
        roles: [String: [String]],
        thresholds: BrokerThresholds = .default,
        callers: [String: BrokerCallerPolicy] = [:],
        t3: BrokerT3Config = BrokerT3Config(instanceByModel: [:], defaultInstance: "claudeAgent"),
        t3Instances: [T3InstanceConfig] = [],
        usageLanes: [String: BrokerUsageLane] = [:],
        agentModelAliases: [String: String] = [
            "claude-fable-5": "fable",
            "claude-opus-5": "opus",
            "claude-sonnet-5": "sonnet",
        ],
        allowForcedDegraded: [String: Bool] = [:]
    ) -> BrokerPolicy {
        BrokerPolicy(
            roles: roles.mapValues { candidates($0) },
            thresholds: thresholds,
            callers: callers,
            t3: t3,
            t3Instances: t3Instances,
            usageLanes: usageLanes,
            agentModelAliases: agentModelAliases,
            allowForcedDegraded: allowForcedDegraded
        )
    }

    static func account(
        id: String = "acct-primary",
        label: String = "Primary",
        isPrimary: Bool = true,
        age: TimeInterval = 60,
        state: BrokerQuotaState = .fresh,
        session: Double? = 10,
        weekly: Double? = 20,
        sonnet: Double? = nil,
        fable: Double? = nil,
        sessionResetAt: Date? = nil,
        weeklyResetAt: Date? = nil,
        sonnetResetAt: Date? = nil,
        fableResetAt: Date? = nil
    ) -> OracleSnapshot.AccountRow {
        OracleSnapshot.AccountRow(
            id: id,
            label: label,
            isPrimary: isPrimary,
            lastUpdated: now.addingTimeInterval(-age),
            state: state,
            session: session,
            weekly: weekly,
            sonnet: sonnet,
            fable: fable,
            sessionResetAt: sessionResetAt,
            weeklyResetAt: weeklyResetAt,
            sonnetResetAt: sonnetResetAt,
            fableResetAt: fableResetAt
        )
    }

    static func oracle(
        generatedAt: Date = now,
        accounts: [OracleSnapshot.AccountRow] = [account()],
        chatGPTState: BrokerQuotaState = .fresh,
        chatGPTRows: [OracleSnapshot.ChatGPTRow] = [],
        chatGPTConfigured: Bool = false
    ) -> OracleSnapshot {
        OracleSnapshot(
            generatedAt: generatedAt,
            accounts: accounts,
            chatGPTState: chatGPTState,
            chatGPTRows: chatGPTRows,
            chatGPTConfigured: chatGPTConfigured
        )
    }

    /// Cooldown map from key → offset in seconds relative to `now`.
    /// A positive offset cools; a negative one is a self-expired entry.
    static func cooldowns(_ offsets: [String: TimeInterval]) -> [String: Date] {
        offsets.mapValues { now.addingTimeInterval($0) }
    }

    static func reachable(_ instances: String...) -> [String: T3Liveness] {
        var signal: [String: T3Liveness] = [:]
        for instance in instances {
            signal[instance] = T3Liveness(reachable: true, why: "http 200")
        }
        return signal
    }
}

// MARK: - Suite

final class BrokerEngineTests: XCTestCase {

    func testPaceBlockedFableFallsThroughInConfiguredOrder() throws {
        let chain = ["native/claude-fable-5", "native/claude-opus-5"]
        let policy = BrokerFixture.policy(roles: ["planning": chain])
        let originalChain = policy.roles["planning"]?.map(\.id)
        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(
                    session: 5,
                    weekly: 5,
                    fable: 61,
                    sessionResetAt: BrokerFixture.now.addingTimeInterval(4 * 60 * 60),
                    weeklyResetAt: BrokerFixture.now.addingTimeInterval(6 * 24 * 60 * 60),
                    fableResetAt: BrokerFixture.now.addingTimeInterval(3.5 * 24 * 60 * 60)
                )
            ])
        )

        XCTAssertEqual(decision.model, "native/claude-opus-5")
        XCTAssertEqual(decision.candidatesTried.map(\.candidate), chain)
        XCTAssertTrue(try tried(decision, chain[0]).why.contains("pacing"))
        XCTAssertEqual(policy.roles["planning"]?.map(\.id), originalChain)
    }

    func testEveryQuotaBackedHardCapPacesAfterCapWithKnownWindow() throws {
        let fiveHourReset = BrokerFixture.now.addingTimeInterval(3.75 * 60 * 60)
        let weeklyReset = BrokerFixture.now.addingTimeInterval(5.25 * 24 * 60 * 60)

        let nativeCases: [(model: String, account: OracleSnapshot.AccountRow, reason: String)] = [
            (
                "claude-opus-5",
                BrokerFixture.account(session: 31, weekly: 1, sessionResetAt: fiveHourReset),
                "session"
            ),
            (
                "claude-opus-5",
                BrokerFixture.account(session: 1, weekly: 31, weeklyResetAt: weeklyReset),
                "weekly"
            ),
            (
                "claude-sonnet-5",
                BrokerFixture.account(session: 1, weekly: 1, sonnet: 31, sonnetResetAt: weeklyReset),
                "sonnet"
            ),
            (
                "claude-fable-5",
                BrokerFixture.account(session: 1, weekly: 1, fable: 31, fableResetAt: weeklyReset),
                "fable"
            ),
        ]
        for testCase in nativeCases {
            let candidate = "native/\(testCase.model)"
            let decision = try decide(
                policy: BrokerFixture.policy(roles: ["planning": [candidate, "t3/escape-hatch"]]),
                oracle: BrokerFixture.oracle(accounts: [testCase.account]),
                t3: BrokerFixture.reachable("claudeAgent")
            )
            XCTAssertTrue(try tried(decision, candidate).why.contains("\(testCase.reason)"))
            XCTAssertTrue(try tried(decision, candidate).why.contains("pacing"))
        }

        let mappedCases: [(model: String, account: OracleSnapshot.AccountRow, reason: String)] = nativeCases
        for testCase in mappedCases {
            let candidate = "t3:quota/\(testCase.model)"
            let policy = BrokerFixture.policy(
                roles: ["planning": [candidate, "native/claude-opus-5"]],
                t3Instances: [T3InstanceConfig(id: "quota", name: "Quota", boundAccountId: "mapped")],
                usageLanes: [candidate: .claudeAccount(accountId: nil, labelContains: nil, isPrimary: nil)]
            )
            let mapped = OracleSnapshot.AccountRow(
                id: "mapped",
                label: "Mapped",
                isPrimary: false,
                lastUpdated: testCase.account.lastUpdated,
                state: .fresh,
                session: testCase.account.session,
                weekly: testCase.account.weekly,
                sonnet: testCase.account.sonnet,
                fable: testCase.account.fable,
                sessionResetAt: testCase.account.sessionResetAt,
                weeklyResetAt: testCase.account.weeklyResetAt,
                sonnetResetAt: testCase.account.sonnetResetAt,
                fableResetAt: testCase.account.fableResetAt
            )
            let decision = try decide(
                policy: policy,
                oracle: BrokerFixture.oracle(accounts: [BrokerFixture.account(), mapped]),
                t3: BrokerFixture.reachable("quota")
            )
            XCTAssertTrue(try tried(decision, candidate).why.contains("\(testCase.reason)"))
            XCTAssertTrue(try tried(decision, candidate).why.contains("pacing"))
        }

        let chatGPTCases: [(ChatGPTUsageData.MenuBarQuotaRole, Date)] = [
            (.chatGPT5h, fiveHourReset),
            (.chatGPTWeekly, weeklyReset),
            (.chatGPTPro, weeklyReset),
            (.chatGPTCodexSpark, weeklyReset),
        ]
        for (role, resetAt) in chatGPTCases {
            let candidate = "codex/gpt-5.6-sol"
            let policy = BrokerFixture.policy(
                roles: ["execution": [candidate, "native/claude-opus-5"]],
                usageLanes: [candidate: .chatGPT(labelContains: nil)]
            )
            let decision = try decide(
                role: "execution",
                policy: policy,
                oracle: BrokerFixture.oracle(chatGPTRows: [
                    .init(label: role.rawValue, usedPercent: 31, resetAt: resetAt, windowRole: role)
                ])
            )
            XCTAssertTrue(try tried(decision, candidate).why.contains("pacing"), role.rawValue)
        }

        let unknownRolePolicy = BrokerFixture.policy(
            roles: ["execution": ["codex/gpt-5.6-sol"]],
            usageLanes: ["codex/gpt-5.6-sol": .chatGPT(labelContains: nil)]
        )
        let unknownRole = try decide(
            role: "execution",
            policy: unknownRolePolicy,
            oracle: BrokerFixture.oracle(chatGPTRows: [
                .init(label: "unknown", usedPercent: 89, resetAt: weeklyReset, windowRole: nil)
            ])
        )
        XCTAssertTrue(try tried(unknownRole, "codex/gpt-5.6-sol").available)
    }

    func testHardCapsAndForcedDegradedSafetySurvivePacing() throws {
        let fiveHourReset = BrokerFixture.now.addingTimeInterval(2.5 * 60 * 60)
        let weeklyReset = BrokerFixture.now.addingTimeInterval(3.5 * 24 * 60 * 60)
        let hardCapCases: [(model: String, account: OracleSnapshot.AccountRow, cap: String)] = [
            (
                "claude-opus-5",
                BrokerFixture.account(session: 90, weekly: 1, sessionResetAt: fiveHourReset),
                "session 90% >= 90%"
            ),
            (
                "claude-opus-5",
                BrokerFixture.account(session: 1, weekly: 85, weeklyResetAt: weeklyReset),
                "weekly 85% >= 85%"
            ),
            (
                "claude-sonnet-5",
                BrokerFixture.account(session: 1, weekly: 1, sonnet: 90, sonnetResetAt: weeklyReset),
                "sonnet pool 90% >= 90%"
            ),
            (
                "claude-fable-5",
                BrokerFixture.account(session: 1, weekly: 1, fable: 90, fableResetAt: weeklyReset),
                "fable pool 90% >= 90%"
            ),
        ]
        for testCase in hardCapCases {
            let candidate = "native/\(testCase.model)"
            let decision = try decide(
                policy: BrokerFixture.policy(roles: ["planning": [candidate, "t3/escape-hatch"]]),
                oracle: BrokerFixture.oracle(accounts: [testCase.account]),
                t3: BrokerFixture.reachable("claudeAgent")
            )
            let why = try tried(decision, candidate).why
            XCTAssertTrue(why.contains(testCase.cap), why)
            XCTAssertFalse(why.contains("pacing"), why)
        }

        for testCase in hardCapCases {
            let candidate = "t3:quota/\(testCase.model)"
            let policy = BrokerFixture.policy(
                roles: ["planning": [candidate, "native/claude-opus-5"]],
                t3Instances: [T3InstanceConfig(id: "quota", name: "Quota", boundAccountId: "mapped")],
                usageLanes: [candidate: .claudeAccount(accountId: nil, labelContains: nil, isPrimary: nil)]
            )
            let mapped = OracleSnapshot.AccountRow(
                id: "mapped",
                label: "Mapped",
                isPrimary: false,
                lastUpdated: testCase.account.lastUpdated,
                state: .fresh,
                session: testCase.account.session,
                weekly: testCase.account.weekly,
                sonnet: testCase.account.sonnet,
                fable: testCase.account.fable,
                sessionResetAt: testCase.account.sessionResetAt,
                weeklyResetAt: testCase.account.weeklyResetAt,
                sonnetResetAt: testCase.account.sonnetResetAt,
                fableResetAt: testCase.account.fableResetAt
            )
            let decision = try decide(
                policy: policy,
                oracle: BrokerFixture.oracle(accounts: [BrokerFixture.account(), mapped]),
                t3: BrokerFixture.reachable("quota")
            )
            let why = try tried(decision, candidate).why
            XCTAssertTrue(why.contains(testCase.cap), why)
            XCTAssertFalse(why.contains("pacing"), why)
        }

        let chatGPTCandidate = "codex/gpt-5.6-sol"
        let chatGPTPolicy = BrokerFixture.policy(
            roles: ["execution": [chatGPTCandidate, "native/claude-opus-5"]],
            usageLanes: [chatGPTCandidate: .chatGPT(labelContains: nil)]
        )
        let chatGPTCap = try decide(
            role: "execution",
            policy: chatGPTPolicy,
            oracle: BrokerFixture.oracle(chatGPTRows: [
                .init(
                    label: "Codex 5h",
                    usedPercent: 90,
                    resetAt: fiveHourReset,
                    windowRole: .chatGPT5h
                )
            ])
        )
        let chatGPTWhy = try tried(chatGPTCap, chatGPTCandidate).why
        XCTAssertTrue(chatGPTWhy.contains("90% >= 90%"), chatGPTWhy)
        XCTAssertFalse(chatGPTWhy.contains("pacing"), chatGPTWhy)

        let stale = try decide(
            policy: BrokerFixture.policy(roles: ["planning": ["native/claude-fable-5"]]),
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(
                    age: 5_000,
                    fable: 89,
                    fableResetAt: weeklyReset
                )
            ])
        )
        XCTAssertEqual(stale.source, .policy)
        XCTAssertTrue(stale.degraded)

        let missingReset = try decide(
            policy: BrokerFixture.policy(roles: ["planning": ["native/claude-fable-5"]]),
            oracle: BrokerFixture.oracle(accounts: [BrokerFixture.account(fable: 89)])
        )
        XCTAssertEqual(missingReset.source, .policy)

        let paced = BrokerFixture.account(
            session: 31,
            weekly: 31,
            sessionResetAt: BrokerFixture.now.addingTimeInterval(3.75 * 60 * 60),
            weeklyResetAt: BrokerFixture.now.addingTimeInterval(5.25 * 24 * 60 * 60)
        )
        let forced = try decide(
            policy: BrokerFixture.policy(
                roles: ["planning": ["t3/unreachable", "native/claude-opus-5"]]
            ),
            oracle: BrokerFixture.oracle(accounts: [paced]),
            t3: [:]
        )
        XCTAssertEqual(forced.source, .forcedDegraded)
        XCTAssertEqual(forced.model, "native/claude-opus-5")
        XCTAssertTrue(forced.degraded)
    }

    /// Every case funnels through here so the injected world is explicit and
    /// the clock is always the fixture instant.
    @discardableResult
    private func decide(
        role: String = "planning",
        caller: String? = nil,
        policy: BrokerPolicy,
        oracle: OracleSnapshot? = nil,
        cooldowns: [String: Date] = [:],
        now: Date = BrokerFixture.now,
        t3: [String: T3Liveness] = [:]
    ) throws -> BrokerDecision {
        try BrokerEngine.decide(
            role: role,
            caller: caller,
            policy: policy,
            oracle: oracle,
            cooldowns: cooldowns,
            now: now,
            t3: t3
        )
    }

    private func tried(_ decision: BrokerDecision, _ candidate: String) throws -> BrokerCandidateTried {
        try XCTUnwrap(
            decision.candidatesTried.first { $0.candidate == candidate },
            "expected '\(candidate)' in candidatesTried: \(decision.candidatesTried.map(\.candidate))"
        )
    }

    // MARK: - Test 1: fail-loud role handling

    func test_unknownRole_throwsUnknownRoleWithTheSortedKnownRoles() {
        let policy = BrokerFixture.policy(roles: [
            "planning": ["native/claude-fable-5"],
            "execution": ["native/claude-sonnet-5"],
            "heavy": ["native/claude-opus-5"],
        ])

        XCTAssertThrowsError(try decide(role: "plannng", policy: policy)) { error in
            guard case BrokerError.unknownRole(let role, let known) = error else {
                return XCTFail("expected unknownRole, got \(error)")
            }
            XCTAssertEqual(role, "plannng")
            XCTAssertEqual(known, ["execution", "heavy", "planning"], "known roles must be sorted")
        }
    }

    func test_roleWithAnEmptyCandidateList_throwsConfigError() {
        let policy = BrokerFixture.policy(roles: ["planning": []])

        XCTAssertThrowsError(try decide(policy: policy)) { error in
            guard case BrokerError.configError(let message) = error else {
                return XCTFail("expected configError, got \(error)")
            }
            XCTAssertTrue(message.contains("planning"), "the error must name the role: \(message)")
        }
    }

    // MARK: - Test 2: caller resolution

    func test_absentOrEmptyCaller_resolvesToTheDefaultCaller() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["native/claude-fable-5"]],
            callers: ["claude-code": BrokerCallerPolicy(routes: [.native, .codex, .t3])]
        )

        for caller in [nil, "", "   "] as [String?] {
            let decision = try decide(caller: caller, policy: policy)
            XCTAssertEqual(decision.caller, BrokerPolicy.defaultCaller)
            XCTAssertEqual(decision.model, "native/claude-fable-5")
        }
    }

    func test_unknownCaller_failsLoudInsteadOfGainingEveryRoute() {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["native/claude-fable-5"]],
            callers: [
                "claude-code": BrokerCallerPolicy(routes: [.native, .codex, .t3]),
                "codex": BrokerCallerPolicy(routes: [.t3]),
            ]
        )

        XCTAssertThrowsError(try decide(caller: "codx", policy: policy)) { error in
            guard case BrokerError.unknownCaller(let caller, let known) = error else {
                return XCTFail("expected unknownCaller, got \(error)")
            }
            XCTAssertEqual(caller, "codx")
            XCTAssertEqual(known, ["claude-code", "codex"], "known callers must be sorted")
        }
    }

    func test_unknownCaller_isAcceptedWhenThePolicyHasNoCallersBlock() throws {
        let policy = BrokerFixture.policy(roles: ["planning": ["native/claude-fable-5"]])

        let decision = try decide(caller: "some-new-harness", policy: policy)

        XCTAssertEqual(decision.caller, "some-new-harness", "the caller echo is verbatim")
        XCTAssertEqual(decision.model, "native/claude-fable-5")
    }

    // MARK: - Test 3: structural caller filters

    func test_routeOutsideTheCallersRoutes_isCallerFilteredNotAQuotaEvent() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["native/claude-fable-5", "t3/claude-fable-5"]],
            callers: ["codex": BrokerCallerPolicy(routes: [.t3])]
        )

        let decision = try decide(
            caller: "codex",
            policy: policy,
            t3: BrokerFixture.reachable("claudeAgent")
        )

        XCTAssertEqual(decision.model, "t3/claude-fable-5")
        let filtered = try tried(decision, "native/claude-fable-5")
        XCTAssertFalse(filtered.available)
        XCTAssertTrue(filtered.callerFiltered, "a structural filter is never a quota event")
        XCTAssertTrue(filtered.why.contains("native"), "the why must name the route: \(filtered.why)")
    }

    func test_deniedCandidate_isCallerFilteredEvenWhenItsRouteIsAllowed() throws {
        let denied = BrokerFixture.candidates(["t3/gpt-5.6-sol"])
        let policy = BrokerFixture.policy(
            roles: ["execution": ["t3/gpt-5.6-sol", "t3/claude-fable-5"]],
            callers: [
                "codex": BrokerCallerPolicy(routes: [.t3], denyCandidates: denied)
            ]
        )

        let decision = try decide(
            role: "execution",
            caller: "codex",
            policy: policy,
            t3: BrokerFixture.reachable("claudeAgent")
        )

        XCTAssertEqual(decision.model, "t3/claude-fable-5")
        let filtered = try tried(decision, "t3/gpt-5.6-sol")
        XCTAssertTrue(filtered.callerFiltered)
        XCTAssertFalse(filtered.available)
    }

    // MARK: - Test 4: deny_instances is judged on the RESOLVED instance

    func test_denyInstances_isJudgedOnTheResolvedInstance() throws {
        // `t3/gpt-5.6-sol` carries no inline qualifier: it reaches the denied
        // `codex` instance only through instance_by_model. A deny keyed on the
        // candidate string alone would silently reopen here.
        let policy = BrokerFixture.policy(
            roles: ["execution": ["t3/gpt-5.6-sol", "t3/claude-fable-5"]],
            callers: [
                "codex": BrokerCallerPolicy(routes: [.t3], denyInstances: ["codex"])
            ],
            t3: BrokerT3Config(
                instanceByModel: ["gpt-5.6-sol": "codex"],
                defaultInstance: "claudeAgent"
            )
        )

        let decision = try decide(
            role: "execution",
            caller: "codex",
            policy: policy,
            t3: BrokerFixture.reachable("claudeAgent", "codex")
        )

        XCTAssertEqual(decision.model, "t3/claude-fable-5")
        let filtered = try tried(decision, "t3/gpt-5.6-sol")
        XCTAssertTrue(filtered.callerFiltered)
        XCTAssertTrue(
            filtered.why.contains("codex"),
            "the why must name the resolved instance: \(filtered.why)"
        )
    }

    // MARK: - Test 5: cooldown key precedence and self-expiry

    func test_cooldownKeyPrecedence_fullIdBeatsInstanceIdBeatsBareRoute() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3/claude-fable-5", "native/claude-opus-5"]]
        )
        let signal = BrokerFixture.reachable("claudeAgent")

        // Bare route only.
        let routeOnly = try decide(
            policy: policy,
            cooldowns: BrokerFixture.cooldowns(["t3": 600]),
            t3: signal
        )
        XCTAssertTrue(try tried(routeOnly, "t3/claude-fable-5").why.contains("key t3)"))

        // Instance-resolved id wins over the bare route.
        let instanceKey = try decide(
            policy: policy,
            cooldowns: BrokerFixture.cooldowns([
                "t3": 600,
                "t3:claudeAgent/claude-fable-5": 900,
            ]),
            t3: signal
        )
        XCTAssertTrue(
            try tried(instanceKey, "t3/claude-fable-5").why
                .contains("key t3:claudeAgent/claude-fable-5"),
            "the instance-resolved key must win over the bare route"
        )

        // The full candidate id wins over both.
        let fullId = try decide(
            policy: policy,
            cooldowns: BrokerFixture.cooldowns([
                "t3": 600,
                "t3:claudeAgent/claude-fable-5": 900,
                "t3/claude-fable-5": 1200,
            ]),
            t3: signal
        )
        XCTAssertTrue(
            try tried(fullId, "t3/claude-fable-5").why.contains("key t3/claude-fable-5"),
            "the full candidate id must win over every derived key"
        )
    }

    func test_bareRouteCooldown_coolsEveryT3Lane() throws {
        let policy = BrokerFixture.policy(
            roles: [
                "planning": [
                    "t3:claude_secondary/claude-fable-5",
                    "t3/claude-fable-5",
                    "native/claude-opus-5",
                ]
            ]
        )

        let decision = try decide(
            policy: policy,
            cooldowns: BrokerFixture.cooldowns(["t3": 600]),
            t3: BrokerFixture.reachable("claudeAgent", "claude_secondary")
        )

        XCTAssertEqual(decision.model, "native/claude-opus-5")
        XCTAssertFalse(try tried(decision, "t3:claude_secondary/claude-fable-5").available)
        XCTAssertFalse(try tried(decision, "t3/claude-fable-5").available)
    }

    func test_pastCooldownEntry_selfExpiresWithoutACleanupPass() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3/claude-fable-5", "native/claude-opus-5"]]
        )

        let decision = try decide(
            policy: policy,
            cooldowns: BrokerFixture.cooldowns(["t3/claude-fable-5": -1]),
            t3: BrokerFixture.reachable("claudeAgent")
        )

        XCTAssertEqual(
            decision.model, "t3/claude-fable-5",
            "an availableAt in the past no longer cools"
        )
    }

    // MARK: - Test 6: cooldown beats the native fail-open gate

    func test_coolingNativeCandidate_isSkippedBeforeTheFailOpenGateAdmitsIt() throws {
        // With no oracle at all the native gate fails OPEN, so only the
        // cooldown can keep this candidate out of the pick.
        let policy = BrokerFixture.policy(
            roles: ["planning": ["native/claude-fable-5", "native/claude-opus-5"]]
        )

        let decision = try decide(
            policy: policy,
            oracle: nil,
            cooldowns: BrokerFixture.cooldowns(["native/claude-fable-5": 600])
        )

        XCTAssertEqual(decision.model, "native/claude-opus-5")
        let skipped = try tried(decision, "native/claude-fable-5")
        XCTAssertFalse(skipped.available)
        XCTAssertFalse(skipped.callerFiltered, "a cooldown is a live gate, not a structural filter")
        XCTAssertTrue(skipped.why.contains("cooldown"), skipped.why)
    }

    // MARK: - Test 7: one model on two instances = two candidates

    func test_sameModelOnTwoT3Instances_areDistinctCandidatesWithIndependentCooldowns() throws {
        let policy = BrokerFixture.policy(
            roles: [
                "planning": [
                    "t3:claude_secondary/claude-fable-5",
                    "t3/claude-fable-5",
                    "native/claude-opus-5",
                ]
            ]
        )
        let signal = BrokerFixture.reachable("claudeAgent", "claude_secondary")

        let secondaryDown = try decide(
            policy: policy,
            cooldowns: BrokerFixture.cooldowns(["t3:claude_secondary/claude-fable-5": 600]),
            t3: signal
        )
        XCTAssertEqual(
            secondaryDown.model, "t3/claude-fable-5",
            "cooling the qualified lane must not cool the default-instance lane"
        )

        let defaultDown = try decide(
            policy: policy,
            cooldowns: BrokerFixture.cooldowns(["t3:claudeAgent/claude-fable-5": 600]),
            t3: signal
        )
        XCTAssertEqual(
            defaultDown.model, "t3:claude_secondary/claude-fable-5",
            "cooling the claudeAgent instance must not cool the secondary lane"
        )
    }

    // MARK: - Availability gates

    /// A chain whose second candidate is an ungated, reachable t3 lane, so the
    /// first candidate's verdict is observable without dragging the decision
    /// into the forced-degraded path.
    private func nativeGateChain(_ model: String) -> BrokerPolicy {
        BrokerFixture.policy(roles: ["planning": ["native/\(model)", "t3/escape-hatch"]])
    }

    private func nativeVerdict(
        model: String,
        oracle: OracleSnapshot?
    ) throws -> BrokerCandidateTried {
        let decision = try decide(
            policy: nativeGateChain(model),
            oracle: oracle,
            t3: BrokerFixture.reachable("claudeAgent")
        )
        return try tried(decision, "native/\(model)")
    }

    // MARK: Test 1: native gate order

    func test_nativeWithFreshOracleBelowEveryThreshold_isAvailableAndNotDegraded() throws {
        let decision = try decide(
            policy: nativeGateChain("claude-fable-5"),
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(session: 10, weekly: 20, sonnet: 5, fable: 30)
            ])
        )

        XCTAssertEqual(decision.model, "native/claude-fable-5")
        XCTAssertEqual(decision.source, .policy)
        XCTAssertFalse(decision.degraded, "a fresh in-budget oracle is not a degraded pick")
        XCTAssertTrue(decision.reason.contains("ok"), decision.reason)
    }

    func test_nativeGateOrder_surfacesWeeklyThenSessionThenSonnetThenFable() throws {
        // Weekly first, even when session is also capped.
        let weekly = try nativeVerdict(
            model: "claude-fable-5",
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(session: 95, weekly: 91)
            ])
        )
        XCTAssertFalse(weekly.available)
        XCTAssertTrue(weekly.why.contains("weekly 91% >= 85%"), weekly.why)

        let session = try nativeVerdict(
            model: "claude-fable-5",
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(session: 95, weekly: 20)
            ])
        )
        XCTAssertFalse(session.available)
        XCTAssertTrue(session.why.contains("session 95% >= 90%"), session.why)

        let sonnet = try nativeVerdict(
            model: "claude-sonnet-5",
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(session: 10, weekly: 20, sonnet: 95)
            ])
        )
        XCTAssertFalse(sonnet.available)
        XCTAssertTrue(sonnet.why.contains("sonnet pool 95% >= 90%"), sonnet.why)

        let fable = try nativeVerdict(
            model: "claude-fable-5",
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(session: 10, weekly: 20, fable: 95)
            ])
        )
        XCTAssertFalse(fable.available)
        XCTAssertTrue(fable.why.contains("fable pool 95% >= 90%"), fable.why)
    }

    func test_perModelPools_gateOnlyTheirOwnModelAndOnlyWhenTheDatumIsPresent() throws {
        // A capped sonnet pool must not gate a fable model, and vice versa.
        let fableUnderCappedSonnet = try nativeVerdict(
            model: "claude-fable-5",
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(session: 10, weekly: 20, sonnet: 99, fable: 5)
            ])
        )
        XCTAssertTrue(fableUnderCappedSonnet.available, fableUnderCappedSonnet.why)

        let sonnetUnderCappedFable = try nativeVerdict(
            model: "claude-sonnet-5",
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(session: 10, weekly: 20, sonnet: 5, fable: 99)
            ])
        )
        XCTAssertTrue(sonnetUnderCappedFable.available, sonnetUnderCappedFable.why)

        // Datum absent: the pool gate cannot fire at all.
        let noDatum = try nativeVerdict(
            model: "claude-sonnet-5",
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(session: 10, weekly: 20, sonnet: nil)
            ])
        )
        XCTAssertTrue(noDatum.available, noDatum.why)
    }

    // MARK: Test 2: native fails OPEN

    func test_nativeFailsOpenOnAbsentStaleOrIncompleteOracle_flaggingDegraded() throws {
        let policy = BrokerFixture.policy(roles: ["planning": ["native/claude-fable-5"]])

        let cases: [(name: String, oracle: OracleSnapshot?)] = [
            ("absent oracle", nil),
            (
                "stale oracle",
                BrokerFixture.oracle(accounts: [BrokerFixture.account(age: 1500)])
            ),
            (
                "non-fresh row state",
                BrokerFixture.oracle(accounts: [BrokerFixture.account(state: .error)])
            ),
            (
                "missing session datum",
                BrokerFixture.oracle(accounts: [BrokerFixture.account(session: nil)])
            ),
            (
                "missing weekly datum",
                BrokerFixture.oracle(accounts: [BrokerFixture.account(weekly: nil)])
            ),
            (
                "future-dated row",
                BrokerFixture.oracle(accounts: [BrokerFixture.account(age: -1)])
            ),
        ]

        for testCase in cases {
            let decision = try decide(policy: policy, oracle: testCase.oracle)
            XCTAssertEqual(decision.model, "native/claude-fable-5", testCase.name)
            XCTAssertEqual(decision.source, .policy, "\(testCase.name): fail-open is not forced")
            XCTAssertTrue(decision.degraded, "\(testCase.name): a quota-blind pick is degraded")
        }
    }

    // MARK: Test 3: t3 fails CLOSED

    func test_t3WithoutAReachableSignal_isUnavailableEvenWhenEverythingElseIsCapped() throws {
        // The native fallback keeps the decision resolvable; without it the
        // role would have nothing invocable at all (pinned separately).
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3/claude-fable-5", "native/claude-opus-5"]]
        )
        let cappedOracle = BrokerFixture.oracle(accounts: [
            BrokerFixture.account(session: 99, weekly: 99)
        ])

        // No entry at all for the resolved instance.
        let absent = try decide(policy: policy, oracle: cappedOracle, t3: [:])
        let absentEntry = try tried(absent, "t3/claude-fable-5")
        XCTAssertFalse(absentEntry.available, "no signal means fail closed, never fail open")
        XCTAssertFalse(absentEntry.callerFiltered, "reachability is a live gate, not a structural filter")
        XCTAssertTrue(absent.degraded, "nothing had headroom, so the pick cannot be clean")

        // Present but unreachable — the liveness why must survive into the audit trail.
        let unreachable = try decide(
            policy: policy,
            oracle: cappedOracle,
            t3: ["claudeAgent": T3Liveness(reachable: false, why: "connect failed: refused")]
        )
        let entry = try tried(unreachable, "t3/claude-fable-5")
        XCTAssertFalse(entry.available)
        XCTAssertTrue(entry.why.contains("connect failed: refused"), entry.why)
    }

    // MARK: Test 4: claude-account lane oracle

    func test_reachableT3MappedToAClaudeAccountLane_gatesOnThatAccountsFreshRow() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3:claude_secondary/claude-fable-5", "native/claude-opus-5"]],
            t3Instances: [
                T3InstanceConfig(id: "claude_secondary", name: "Claude (second account)", boundAccountId: "acct-secondary")
            ],
            usageLanes: [
                "t3:claude_secondary/claude-fable-5": .claudeAccount(
                    accountId: nil, labelContains: nil, isPrimary: nil
                )
            ]
        )
        let signal = BrokerFixture.reachable("claude_secondary")

        func laneVerdict(
            session: Double?, weekly: Double?, fable: Double?
        ) throws -> BrokerCandidateTried {
            let decision = try decide(
                policy: policy,
                oracle: BrokerFixture.oracle(accounts: [
                    BrokerFixture.account(),
                    BrokerFixture.account(
                        id: "acct-secondary", label: "Second account", isPrimary: false,
                        session: session, weekly: weekly, fable: fable
                    ),
                ]),
                t3: signal
            )
            return try tried(decision, "t3:claude_secondary/claude-fable-5")
        }

        let ok = try laneVerdict(session: 10, weekly: 20, fable: 30)
        XCTAssertTrue(ok.available, ok.why)

        let cappedWeekly = try laneVerdict(session: 10, weekly: 90, fable: 30)
        XCTAssertFalse(cappedWeekly.available)
        XCTAssertTrue(cappedWeekly.why.contains("weekly 90% >= 85%"), cappedWeekly.why)

        let cappedSession = try laneVerdict(session: 95, weekly: 20, fable: 30)
        XCTAssertFalse(cappedSession.available)
        XCTAssertTrue(cappedSession.why.contains("session 95% >= 90%"), cappedSession.why)

        // The fable pool gates because the MODEL NAME contains "fable".
        let cappedFable = try laneVerdict(session: 10, weekly: 20, fable: 95)
        XCTAssertFalse(cappedFable.available)
        XCTAssertTrue(cappedFable.why.contains("fable pool 95% >= 90%"), cappedFable.why)
    }

    func test_claudeAccountLaneWithNoFreshRow_isAvailableButDegraded() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3:claude_secondary/claude-fable-5"]],
            t3Instances: [
                T3InstanceConfig(id: "claude_secondary", name: "Claude (second account)", boundAccountId: "acct-secondary")
            ],
            usageLanes: [
                "t3:claude_secondary/claude-fable-5": .claudeAccount(
                    accountId: nil, labelContains: nil, isPrimary: nil
                )
            ]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(),
                BrokerFixture.account(
                    id: "acct-secondary", label: "Second account", isPrimary: false, state: .stale
                ),
            ]),
            t3: BrokerFixture.reachable("claude_secondary")
        )

        XCTAssertEqual(decision.model, "t3:claude_secondary/claude-fable-5")
        XCTAssertEqual(decision.source, .policy)
        XCTAssertTrue(decision.degraded, "a mapped claude lane with no fresh row fails OPEN")
    }

    func test_claudeAccountLaneWithMissingSharedMetric_isAvailableButDegraded() throws {
        let candidate = "t3:claude_secondary/claude-fable-5"
        let policy = BrokerFixture.policy(
            roles: ["planning": [candidate]],
            t3Instances: [
                T3InstanceConfig(id: "claude_secondary", name: "Claude (second account)", boundAccountId: "acct-secondary")
            ],
            usageLanes: [
                candidate: .claudeAccount(accountId: nil, labelContains: nil, isPrimary: nil)
            ]
        )

        for account in [
            BrokerFixture.account(id: "acct-secondary", isPrimary: false, session: nil),
            BrokerFixture.account(id: "acct-secondary", isPrimary: false, weekly: nil),
        ] {
            let decision = try decide(
                policy: policy,
                oracle: BrokerFixture.oracle(accounts: [account]),
                t3: BrokerFixture.reachable("claude_secondary")
            )
            let evaluation = try tried(decision, candidate)
            XCTAssertTrue(evaluation.available)
            XCTAssertTrue(evaluation.why.contains("session/weekly utilization missing"), evaluation.why)
            XCTAssertTrue(decision.degraded)
        }
    }

    func test_ambiguousClaudeLabelLaneDoesNotDependOnAccountOrder() throws {
        let candidate = "t3/claude-fable-5"
        let policy = BrokerFixture.policy(
            roles: ["planning": [candidate]],
            usageLanes: [
                candidate: .claudeAccount(accountId: nil, labelContains: "team", isPrimary: nil)
            ]
        )
        let accounts = [
            BrokerFixture.account(id: "capped", label: "Team Capped", weekly: 99),
            BrokerFixture.account(id: "available", label: "Team Available", weekly: 10),
        ]

        for orderedAccounts in [accounts, Array(accounts.reversed())] {
            let decision = try decide(
                policy: policy,
                oracle: BrokerFixture.oracle(accounts: orderedAccounts),
                t3: BrokerFixture.reachable("claudeAgent")
            )
            XCTAssertEqual(decision.source, .policy)
            XCTAssertTrue(decision.degraded)
            XCTAssertTrue(decision.reason.contains("no fresh data"), decision.reason)
        }
    }

    func test_staleSnapshotsDoNotGateNonNativeLanes() throws {
        let claudeCandidate = "t3:claude_secondary/claude-fable-5"
        let claudePolicy = BrokerFixture.policy(
            roles: ["planning": [claudeCandidate]],
            t3Instances: [
                T3InstanceConfig(id: "claude_secondary", name: "Claude (second account)", boundAccountId: "acct-secondary")
            ],
            usageLanes: [
                claudeCandidate: .claudeAccount(accountId: nil, labelContains: nil, isPrimary: nil)
            ]
        )
        let cappedAccount = BrokerFixture.account(
            id: "acct-secondary", label: "Second account", isPrimary: false, weekly: 99, fable: 99
        )

        for oracle in [
            BrokerFixture.oracle(
                generatedAt: BrokerFixture.now.addingTimeInterval(1),
                accounts: [cappedAccount]
            ),
            BrokerFixture.oracle(accounts: [
                BrokerFixture.account(
                    id: "acct-secondary", label: "Second account", isPrimary: false,
                    age: -1, weekly: 99, fable: 99
                )
            ]),
            BrokerFixture.oracle(
                generatedAt: BrokerFixture.now.addingTimeInterval(-1_201),
                accounts: [cappedAccount]
            ),
            BrokerFixture.oracle(accounts: [
                BrokerFixture.account(
                    id: "acct-secondary", label: "Second account", isPrimary: false,
                    age: 1_201, weekly: 99, fable: 99
                )
            ]),
        ] {
            let decision = try decide(
                policy: claudePolicy,
                oracle: oracle,
                t3: BrokerFixture.reachable("claude_secondary")
            )
            XCTAssertEqual(decision.model, claudeCandidate)
            XCTAssertTrue(decision.degraded)
        }

        let codexCandidate = "codex/gpt-5.6-sol"
        let codexDecision = try decide(
            role: "execution",
            policy: BrokerFixture.policy(
                roles: ["execution": [codexCandidate]],
                usageLanes: [codexCandidate: .chatGPT(labelContains: "codex weekly")]
            ),
            oracle: BrokerFixture.oracle(
                generatedAt: BrokerFixture.now.addingTimeInterval(-1_201),
                chatGPTRows: [OracleSnapshot.ChatGPTRow(label: "Codex Weekly", usedPercent: 99)]
            )
        )
        XCTAssertEqual(codexDecision.model, codexCandidate)
        XCTAssertFalse(try tried(codexDecision, codexCandidate).why.contains("99%"))
    }

    // MARK: Test 5: chatgpt lane oracle

    func test_chatGPTLane_gatesOnTheWorstMatchingRow() throws {
        let policy = BrokerFixture.policy(
            roles: ["execution": ["codex/gpt-5.6-sol", "native/claude-sonnet-5"]],
            usageLanes: ["codex/gpt-5.6-sol": .chatGPT(labelContains: "codex weekly")]
        )

        func verdict(_ rows: [OracleSnapshot.ChatGPTRow], state: BrokerQuotaState = .fresh) throws
            -> BrokerCandidateTried
        {
            let decision = try decide(
                role: "execution",
                policy: policy,
                oracle: BrokerFixture.oracle(chatGPTState: state, chatGPTRows: rows)
            )
            return try tried(decision, "codex/gpt-5.6-sol")
        }

        let worstCapped = try verdict([
            OracleSnapshot.ChatGPTRow(label: "Codex Weekly", usedPercent: 40),
            OracleSnapshot.ChatGPTRow(label: "codex weekly tasks", usedPercent: 96),
        ])
        XCTAssertFalse(worstCapped.available, "if any shared window is capped, the lane is capped")
        XCTAssertTrue(worstCapped.why.contains("96% >= 90%"), worstCapped.why)

        let underLimit = try verdict([
            OracleSnapshot.ChatGPTRow(label: "Codex Weekly", usedPercent: 40)
        ])
        XCTAssertTrue(underLimit.available, underLimit.why)

        // Rows that do not match the label are ignored entirely.
        let unmatched = try verdict([
            OracleSnapshot.ChatGPTRow(label: "GPT-5 weekly", usedPercent: 99)
        ])
        XCTAssertTrue(unmatched.available, unmatched.why)
    }

    func test_chatGPTLaneWithNoData_isAvailableButDegraded() throws {
        let policy = BrokerFixture.policy(
            roles: ["execution": ["codex/gpt-5.6-sol"]],
            usageLanes: ["codex/gpt-5.6-sol": .chatGPT(labelContains: "codex weekly")]
        )

        let decision = try decide(
            role: "execution",
            policy: policy,
            oracle: BrokerFixture.oracle(chatGPTState: .stale, chatGPTRows: [])
        )

        XCTAssertEqual(
            decision.model, "codex/gpt-5.6-sol",
            "a lane with no data still stays available: absent quota never blocks"
        )
        XCTAssertTrue(
            decision.degraded,
            "but it is flagged, like every other quota-blind pick. This test "
                + "previously asserted the opposite as a deliberate asymmetry; "
                + "an unflagged fail-open reports a blind pick as a verified one."
        )
    }

    // MARK: Test 6 & 7: codex and unmapped candidates

    func test_codexWithNoLaneVerdict_isAvailable() throws {
        let policy = BrokerFixture.policy(roles: ["execution": ["codex/gpt-5.6-sol"]])

        let decision = try decide(role: "execution", policy: policy, oracle: BrokerFixture.oracle())

        XCTAssertEqual(decision.model, "codex/gpt-5.6-sol")
        XCTAssertEqual(decision.source, .policy)
        XCTAssertFalse(decision.degraded)
    }

    func test_unmappedCandidate_fallsThroughWithNoVerdict() throws {
        // No usage_lanes entry at all: lane matching is a pure tightening, so
        // its absence must never block what cooldowns would allow.
        let policy = BrokerFixture.policy(roles: ["execution": ["t3/gpt-5.6-sol"]])

        let available = try decide(
            role: "execution",
            policy: policy,
            oracle: BrokerFixture.oracle(
                chatGPTState: .fresh,
                chatGPTRows: [OracleSnapshot.ChatGPTRow(label: "Codex weekly", usedPercent: 99)]
            ),
            t3: BrokerFixture.reachable("claudeAgent")
        )
        XCTAssertEqual(available.model, "t3/gpt-5.6-sol")
        XCTAssertFalse(available.degraded)

        let cooled = try decide(
            role: "execution",
            policy: policy,
            cooldowns: BrokerFixture.cooldowns(["t3/gpt-5.6-sol": 600]),
            t3: BrokerFixture.reachable("claudeAgent")
        )
        XCTAssertFalse(try tried(cooled, "t3/gpt-5.6-sol").available)
    }

    // MARK: - Pitfall 3: degraded has two distinct sources

    func test_degradedMatrix_separatesFailOpenFromForcedDegraded() throws {
        struct Row {
            let name: String
            let role: String
            let policy: BrokerPolicy
            let oracle: OracleSnapshot?
            let t3: [String: T3Liveness]
            let model: String
            let source: BrokerDecisionSource
            let degraded: Bool
        }

        let nativeThenT3 = BrokerFixture.policy(
            roles: ["planning": ["native/claude-fable-5", "t3:claude_secondary/claude-fable-5"]],
            t3Instances: [
                T3InstanceConfig(id: "claude_secondary", name: "Claude (second account)", boundAccountId: "acct-secondary")
            ],
            usageLanes: [
                "t3:claude_secondary/claude-fable-5": .claudeAccount(
                    accountId: nil, labelContains: nil, isPrimary: nil
                )
            ]
        )
        let cappedPrimary = BrokerFixture.account(session: 10, weekly: 99)
        let staleSecondary = BrokerFixture.account(
            id: "acct-secondary", label: "Second account", isPrimary: false, state: .stale
        )

        let rows: [Row] = [
            Row(
                name: "fresh oracle in budget",
                role: "planning",
                policy: nativeThenT3,
                oracle: BrokerFixture.oracle(accounts: [BrokerFixture.account()]),
                t3: [:],
                model: "native/claude-fable-5",
                source: .policy,
                degraded: false
            ),
            Row(
                name: "stale oracle fails open",
                role: "planning",
                policy: nativeThenT3,
                oracle: BrokerFixture.oracle(accounts: [BrokerFixture.account(age: 5000)]),
                t3: [:],
                model: "native/claude-fable-5",
                source: .policy,
                degraded: true
            ),
            Row(
                name: "missing oracle fails open",
                role: "planning",
                policy: nativeThenT3,
                oracle: nil,
                t3: [:],
                model: "native/claude-fable-5",
                source: .policy,
                degraded: true
            ),
            Row(
                name: "lane-mapped t3 without a fresh row fails open",
                role: "planning",
                policy: nativeThenT3,
                oracle: BrokerFixture.oracle(accounts: [cappedPrimary, staleSecondary]),
                t3: BrokerFixture.reachable("claude_secondary"),
                model: "t3:claude_secondary/claude-fable-5",
                source: .policy,
                degraded: true
            ),
            Row(
                name: "everything capped forces the top invocable candidate",
                role: "planning",
                policy: nativeThenT3,
                oracle: BrokerFixture.oracle(accounts: [cappedPrimary, staleSecondary]),
                t3: [:],
                model: "native/claude-fable-5",
                source: .forcedDegraded,
                degraded: true
            ),
        ]

        for row in rows {
            let decision = try decide(
                role: row.role,
                policy: row.policy,
                oracle: row.oracle,
                t3: row.t3
            )
            XCTAssertEqual(decision.model, row.model, row.name)
            XCTAssertEqual(decision.source, row.source, row.name)
            XCTAssertEqual(decision.degraded, row.degraded, row.name)
        }
    }

    func test_everyDecisionCarriesAPopulatedOracleBlock() throws {
        let policy = BrokerFixture.policy(roles: ["planning": ["native/claude-fable-5"]])

        let populated = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(age: 120, session: 12.5, weekly: 61.5, sonnet: 3, fable: 7.25)
            ])
        )
        XCTAssertTrue(populated.oracle.present)
        XCTAssertFalse(populated.oracle.stale)
        XCTAssertEqual(populated.oracle.ageSeconds, 120)
        XCTAssertEqual(populated.oracle.session, 12.5)
        XCTAssertEqual(populated.oracle.weekly, 61.5)
        XCTAssertEqual(populated.oracle.sonnet, 3)
        XCTAssertEqual(populated.oracle.fable, 7.25)

        let absent = try decide(policy: policy, oracle: nil)
        XCTAssertEqual(absent.oracle, .absent)
    }

    // MARK: - Forced-degraded

    /// An oracle that caps every native pool, so nothing has headroom.
    private var cappedOracle: OracleSnapshot {
        BrokerFixture.oracle(accounts: [BrokerFixture.account(session: 99, weekly: 99)])
    }

    func test_whenNothingHasHeadroom_theTopRankedInvocableCandidateIsForced() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["native/claude-fable-5", "native/claude-opus-5"]]
        )

        let decision = try decide(policy: policy, oracle: cappedOracle)

        XCTAssertEqual(decision.model, "native/claude-fable-5", "the forced pick is rank-ordered")
        XCTAssertEqual(decision.source, .forcedDegraded)
        XCTAssertTrue(decision.degraded)
        XCTAssertTrue(decision.candidatesTried.allSatisfy { !$0.available })
    }

    func test_forcedDegraded_neverForcesAnUninvocableCandidate() throws {
        // An unreachable t3 lane outranks the native fallback, but forcing it
        // would hand back a pick the caller cannot execute.
        let unreachableTop = BrokerFixture.policy(
            roles: ["planning": ["t3/claude-fable-5", "native/claude-opus-5"]]
        )
        let forcedPastT3 = try decide(policy: unreachableTop, oracle: cappedOracle, t3: [:])
        XCTAssertEqual(forcedPastT3.model, "native/claude-opus-5", "fail-closed holds in the fallback")
        XCTAssertEqual(forcedPastT3.source, .forcedDegraded)

        // Same for a structurally filtered candidate.
        let filteredTop = BrokerFixture.policy(
            roles: ["planning": ["native/claude-fable-5", "t3/claude-fable-5"]],
            callers: ["codex": BrokerCallerPolicy(routes: [.t3])]
        )
        let forcedPastFilter = try decide(
            caller: "codex",
            policy: filteredTop,
            oracle: cappedOracle,
            cooldowns: BrokerFixture.cooldowns(["t3/claude-fable-5": 600]),
            t3: BrokerFixture.reachable("claudeAgent")
        )
        XCTAssertEqual(forcedPastFilter.model, "t3/claude-fable-5")

        // Nothing survives at all: fail loud rather than return an unactionable pick.
        let nothingInvocable = BrokerFixture.policy(
            roles: ["planning": ["native/claude-fable-5", "t3/claude-fable-5"]],
            callers: ["codex": BrokerCallerPolicy(routes: [.t3])]
        )
        XCTAssertThrowsError(
            try decide(caller: "codex", policy: nothingInvocable, oracle: cappedOracle, t3: [:])
        ) { error in
            guard case BrokerError.configError(let message) = error else {
                return XCTFail("expected configError, got \(error)")
            }
            XCTAssertTrue(message.contains("codex"), "the error must name the caller: \(message)")
            XCTAssertTrue(message.contains("invocable"), message)
        }
    }

    func test_roleWithForcedDegradedDisabled_surfacesTheNoHeadroomErrorInstead() {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["native/claude-fable-5", "native/claude-opus-5"]],
            allowForcedDegraded: ["planning": false]
        )

        XCTAssertThrowsError(try decide(policy: policy, oracle: cappedOracle)) { error in
            guard case BrokerError.configError(let message) = error else {
                return XCTFail("expected configError, got \(error)")
            }
            XCTAssertTrue(message.contains("headroom"), message)
            XCTAssertTrue(message.contains("forced-degraded"), message)
        }
    }

    // MARK: - Reason construction

    func test_forcedReason_distinguishesNoHeadroomFromNoReachableHeadroom() throws {
        let plain = BrokerFixture.policy(
            roles: ["planning": ["native/claude-fable-5", "native/claude-opus-5"]]
        )
        let plainReason = try decide(policy: plain, oracle: cappedOracle).reason
        XCTAssertTrue(plainReason.contains("no candidate had headroom"), plainReason)
        XCTAssertTrue(plainReason.contains("native/claude-fable-5"), plainReason)
        XCTAssertTrue(plainReason.contains("(degraded)"), plainReason)

        let filtered = BrokerFixture.policy(
            roles: ["planning": ["t3/claude-fable-5", "native/claude-fable-5"]],
            callers: ["restricted": BrokerCallerPolicy(routes: [.native])]
        )
        let filteredReason = try decide(
            caller: "restricted", policy: filtered, oracle: cappedOracle
        ).reason
        XCTAssertTrue(
            filteredReason.contains("no reachable candidate had headroom"),
            "a structurally filtered entry changes which claim the reason can make: \(filteredReason)"
        )
    }

    func test_nativeFailOpenPick_marksItsReasonDegraded() throws {
        let policy = BrokerFixture.policy(roles: ["planning": ["native/claude-fable-5"]])

        let decision = try decide(policy: policy, oracle: nil)

        XCTAssertTrue(decision.degraded)
        XCTAssertTrue(decision.reason.hasSuffix("(degraded)"), decision.reason)
    }

    func test_nonNativeReason_prefersTheQuotaSkipOverTheCallerFilterSkip() throws {
        let policy = BrokerFixture.policy(
            roles: [
                "planning": [
                    "codex/gpt-5.6-sol",
                    "native/claude-fable-5",
                    "t3/claude-fable-5",
                ]
            ],
            callers: ["restricted": BrokerCallerPolicy(routes: [.native, .t3])]
        )

        let decision = try decide(
            caller: "restricted",
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(session: 10, weekly: 20, fable: 95)
            ]),
            t3: BrokerFixture.reachable("claudeAgent")
        )

        XCTAssertEqual(decision.model, "t3/claude-fable-5")
        XCTAssertTrue(
            decision.reason.contains("fable pool"),
            "the structural filter must not mask the real quota event: \(decision.reason)"
        )
        XCTAssertTrue(decision.reason.contains("routing to t3"), decision.reason)
    }

    // MARK: - Aliases and invocations

    func test_agentModelAliasesApplyToNativePicksOnly() throws {
        let aliases = [
            "claude-fable-5": "fable",
            "claude-opus-5": "opus",
            "claude-sonnet-5": "sonnet",
            "claude-haiku-4-5-20251001": "haiku",
        ]
        for (model, alias) in aliases {
            let policy = BrokerFixture.policy(
                roles: ["planning": ["native/\(model)"]],
                agentModelAliases: aliases
            )
            let decision = try decide(policy: policy, oracle: BrokerFixture.oracle())
            XCTAssertEqual(decision.agentModel, alias)
            XCTAssertEqual(decision.invocation, .agent(model: alias))
        }

        let t3Policy = BrokerFixture.policy(
            roles: ["planning": ["t3:claude_secondary/claude-fable-5"]],
            agentModelAliases: aliases
        )
        let t3Decision = try decide(
            policy: t3Policy,
            oracle: BrokerFixture.oracle(),
            t3: BrokerFixture.reachable("claude_secondary")
        )
        XCTAssertNil(t3Decision.agentModel, "only native picks carry an agent alias")
        XCTAssertEqual(
            t3Decision.invocation,
            .t3Dispatch(model: "claude-fable-5", instanceId: "claude_secondary")
        )

        let codexPolicy = BrokerFixture.policy(
            roles: ["execution": ["codex/gpt-5.6-sol"]],
            agentModelAliases: aliases
        )
        let codexDecision = try decide(
            role: "execution", policy: codexPolicy, oracle: BrokerFixture.oracle()
        )
        XCTAssertNil(codexDecision.agentModel)
        XCTAssertEqual(codexDecision.invocation, .codexExec(model: "gpt-5.6-sol"))
    }

    func test_t3InvocationCarriesTheResolvedInstanceEvenWithoutAnInlineQualifier() throws {
        let policy = BrokerFixture.policy(
            roles: ["execution": ["t3/gpt-5.6-sol"]],
            t3: BrokerT3Config(
                instanceByModel: ["gpt-5.6-sol": "codex"], defaultInstance: "claudeAgent"
            )
        )

        let decision = try decide(
            role: "execution",
            policy: policy,
            oracle: BrokerFixture.oracle(),
            t3: BrokerFixture.reachable("codex")
        )

        XCTAssertEqual(
            decision.invocation, .t3Dispatch(model: "gpt-5.6-sol", instanceId: "codex")
        )
    }

    // MARK: - Bundled policy seed

    func test_bundledSeed_carriesTheDistilledRoleChains() {
        let seed = BrokerPolicy.bundledDefault
        let fableChain = [
            "native/claude-fable-5",
            "t3:*/claude-fable-5",
            "t3/claude-fable-5",
            "native/claude-opus-5",
            "native/claude-sonnet-5",
        ]

        for role in ["planning", "architecture", "design", "research"] {
            XCTAssertEqual(seed.roles[role]?.map(\.id), fableChain, role)
        }
        // `review` leads with Opus rather than Fable: the reviewer gate is the
        // highest-volume judgment role, so it is the one chain deliberately not
        // spending the reasoning tier first. Fable still ranks above Sonnet.
        XCTAssertEqual(
            seed.roles["review"]?.map(\.id),
            [
                "native/claude-opus-5",
                "native/claude-fable-5",
                "t3:*/claude-fable-5",
                "t3/claude-fable-5",
                "native/claude-sonnet-5",
            ]
        )
        XCTAssertEqual(
            seed.roles["execution"]?.map(\.id),
            [
                "t3/gpt-5.6-sol",
                "codex/gpt-5.6-sol",
                "native/claude-sonnet-5",
                "native/claude-haiku-4-5-20251001",
            ]
        )
        XCTAssertEqual(
            seed.roles["heavy"]?.map(\.id),
            ["native/claude-opus-5", "native/claude-sonnet-5"]
        )
        XCTAssertEqual(
            seed.roles["standard"]?.map(\.id),
            ["native/claude-sonnet-5", "native/claude-haiku-4-5-20251001"]
        )
        XCTAssertEqual(seed.thresholds, .default)
    }

    func test_bundledSeed_carriesTheResearchBackedEffortMatrix() {
        let seed = BrokerPolicy.bundledDefault

        for role in ["planning", "architecture", "design", "research"] {
            XCTAssertEqual(
                seed.roles[role]?.map(\.effort),
                [nil, nil, nil, .xhigh, .xhigh],
                "\(role): fable stays adaptive, the substitutes escalate"
            )
        }
        XCTAssertEqual(
            seed.roles["review"]?.map(\.effort),
            [.xhigh, nil, nil, nil, .xhigh],
            "review: the Opus lead escalates, the Fable fallbacks stay adaptive"
        )
        XCTAssertEqual(seed.roles["execution"]?.map(\.effort), [.high, .high, .high, nil])
        XCTAssertEqual(seed.roles["heavy"]?.map(\.effort), [.xhigh, .high])
        XCTAssertEqual(seed.roles["standard"]?.map(\.effort), [.high, nil])

        let candidates = seed.roles.values.flatMap { $0 }
        XCTAssertTrue(
            candidates.filter { $0.model.contains("fable") }.allSatisfy { $0.effort == nil },
            "Fable's thinking is adaptive; the seed leaves every Fable candidate unset"
        )
        XCTAssertTrue(
            candidates.filter { $0.model.contains("haiku") }.allSatisfy { $0.effort == nil },
            "Haiku 4.5 supports no effort parameter, so an effort there is unactionable"
        )
    }

    func test_bundledSeed_carriesTheCallerRouteSetsT3WiringAndUnboundLanes() throws {
        let seed = BrokerPolicy.bundledDefault

        XCTAssertEqual(seed.callers["claude-code"]?.routes, [.native, .codex, .t3])
        XCTAssertEqual(
            seed.callers["codex"]?.routes, [.t3],
            "the codex route is deliberately withheld from a codex caller"
        )

        XCTAssertEqual(seed.t3.instanceByModel["gpt-5.6-sol"], "codex")
        XCTAssertEqual(seed.t3.defaultInstance, "claudeAgent")
        XCTAssertEqual(seed.t3Instances.map(\.id), ["claudeAgent", "codex"])
        XCTAssertTrue(
            seed.roles.values.flatMap { $0 }.allSatisfy { $0.instance == nil || $0.isAnyInstance },
            "no shipped chain may name a T3 instance id: which row is which is per-Mac"
        )
        XCTAssertTrue(
            seed.t3Instances.allSatisfy { $0.boundAccountId == nil },
            "a shipped seed must not assume this machine's account ids"
        )

        XCTAssertEqual(
            seed.usageLanes["t3/claude-fable-5"],
            .claudeAccount(accountId: nil, labelContains: nil, isPrimary: true)
        )
        XCTAssertTrue(
            seed.usageLanes.keys.allSatisfy { !$0.contains(":") },
            "a lane keyed on an instance id would assume a row this Mac may not have"
        )
        for lane in ["t3/gpt-5.6-sol", "codex/gpt-5.6-sol"] {
            XCTAssertEqual(seed.usageLanes[lane], .chatGPT(labelContains: "codex weekly"), lane)
        }

        // The seed must survive a persistence round-trip unchanged.
        let data = try JSONEncoder().encode(BrokerPolicy.bundledDefault)
        XCTAssertEqual(try JSONDecoder().decode(BrokerPolicy.self, from: data), seed)
    }

    func test_seedEndToEnd_planningFallsFromACappedFablePoolToAnAnyInstanceT3Lane() throws {
        let decision = try decide(
            role: "planning",
            caller: "claude-code",
            policy: .bundledDefault,
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(session: 10, weekly: 20, sonnet: 5, fable: 95)
            ]),
            t3: BrokerFixture.reachable("claudeAgent")
        )

        XCTAssertEqual(
            decision.model, "t3:claudeAgent/claude-fable-5",
            "the seed's rank-2 `t3:*` expands to the one reachable instance"
        )
        XCTAssertEqual(decision.route, .t3)
        XCTAssertEqual(decision.source, .policy)
        XCTAssertTrue(
            decision.degraded,
            "the seeded instance ships unbound, so the expanded pick is quota-blind"
        )
        XCTAssertEqual(
            decision.invocation,
            .t3Dispatch(model: "claude-fable-5", instanceId: "claudeAgent")
        )

        let skipped = try tried(decision, "native/claude-fable-5")
        XCTAssertFalse(skipped.available)
        XCTAssertTrue(skipped.why.contains("fable pool 95% >= 90%"), skipped.why)
    }

    // MARK: - Any-instance expansion

    /// Two bound instances, both healthy: the one with more headroom is the one
    /// the walk reaches first, so the other is never even evaluated.
    func test_anyInstance_ranksTheInstanceWithTheMostHeadroomFirst() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3:*/claude-fable-5"]],
            t3Instances: [
                T3InstanceConfig(
                    id: "alpha", name: "Alpha", boundAccountId: "acct-a",
                    detectedModels: ["claude-fable-5"]
                ),
                T3InstanceConfig(
                    id: "beta", name: "Beta", boundAccountId: "acct-b",
                    detectedModels: ["claude-fable-5"]
                ),
                T3InstanceConfig(
                    id: "gamma", name: "Codex", detectedModels: ["gpt-5.6-sol"]
                ),
            ]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(id: "acct-a", label: "A", session: 10, weekly: 60),
                BrokerFixture.account(
                    id: "acct-b", label: "B", isPrimary: false, session: 10, weekly: 10
                ),
            ]),
            t3: BrokerFixture.reachable("alpha", "beta", "gamma")
        )

        XCTAssertEqual(decision.model, "t3:beta/claude-fable-5")
        XCTAssertEqual(
            decision.candidatesTried.map(\.candidate), ["t3:beta/claude-fable-5"],
            "the roomier lane ranks first, so nothing below it is reached"
        )
        XCTAssertFalse(decision.degraded, "a bound instance's headroom is verified, not guessed")
    }

    /// An instance whose model list does not carry the candidate's model is not
    /// a lane at all — expansion must not invent one.
    func test_anyInstance_skipsInstancesThatDoNotServeTheModel() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3:*/claude-fable-5", "native/claude-opus-5"]],
            t3Instances: [
                T3InstanceConfig(id: "gamma", name: "Codex", detectedModels: ["gpt-5.6-sol"])
            ]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(),
            t3: BrokerFixture.reachable("gamma")
        )

        XCTAssertEqual(decision.model, "native/claude-opus-5")
        XCTAssertEqual(
            decision.candidatesTried.map(\.candidate), ["native/claude-opus-5"],
            "no t3 candidate exists to try once the sentinel expands to nothing"
        )
    }

    /// A row no scan has inspected keeps its chance: `detected_models` is empty
    /// because nothing looked, not because the instance serves nothing.
    func test_anyInstance_includesAnInstanceWithNoDetectedModels() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3:*/claude-fable-5"]],
            t3Instances: [T3InstanceConfig(id: "alpha", name: "Alpha")]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(),
            t3: BrokerFixture.reachable("alpha")
        )

        XCTAssertEqual(decision.model, "t3:alpha/claude-fable-5")
    }

    /// Unknown headroom sorts last but is never dropped, and the pick it
    /// produces is flagged: nothing here can see what that lane spends.
    func test_anyInstance_unknownHeadroomRanksLastAndItsPickIsQuotaBlind() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3:*/claude-fable-5"]],
            t3Instances: [
                T3InstanceConfig(
                    id: "alpha", name: "Alpha", boundAccountId: "acct-a",
                    detectedModels: ["claude-fable-5"]
                ),
                T3InstanceConfig(id: "beta", name: "Beta", detectedModels: ["claude-fable-5"]),
            ]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(id: "acct-a", label: "A", session: 10, weekly: 90)
            ]),
            t3: BrokerFixture.reachable("alpha", "beta")
        )

        XCTAssertEqual(
            decision.candidatesTried.map(\.candidate),
            ["t3:alpha/claude-fable-5", "t3:beta/claude-fable-5"],
            "the lane with data ranks above the lane without, even when it is capped"
        )
        XCTAssertEqual(decision.model, "t3:beta/claude-fable-5")
        XCTAssertTrue(decision.degraded)
        let won = try tried(decision, "t3:beta/claude-fable-5")
        XCTAssertTrue(won.why.contains("has no bound account"), won.why)
    }

    /// Expanding onto an instance the chain also names explicitly must rank it
    /// once, at the earlier position.
    func test_anyInstance_dedupesAgainstAnExplicitCandidateForTheSameInstance() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3:*/claude-fable-5", "t3:alpha/claude-fable-5"]],
            t3Instances: [
                T3InstanceConfig(id: "alpha", name: "Alpha", detectedModels: ["claude-fable-5"])
            ]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(),
            t3: BrokerFixture.reachable("alpha")
        )

        XCTAssertEqual(decision.candidatesTried.map(\.candidate), ["t3:alpha/claude-fable-5"])
    }

    /// A chain that is nothing but a sentinel with nothing to expand onto fails
    /// loud: silently returning no pick would read as a quota event.
    func test_anyInstance_withNothingToExpandOnto_throwsConfigError() {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3:*/claude-fable-5"]],
            t3Instances: []
        )

        XCTAssertThrowsError(try decide(policy: policy, oracle: BrokerFixture.oracle())) { error in
            guard case BrokerError.configError(let message) = error else {
                return XCTFail("expected configError, got \(error)")
            }
            XCTAssertTrue(message.contains("any instance"), message)
        }
    }

    /// Rank is not availability: the roomiest lane still loses to its own
    /// cooldown, and the walk falls to the next expanded instance.
    func test_anyInstance_topRankedLaneStillLosesToItsCooldown() throws {
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3:*/claude-fable-5"]],
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
                BrokerFixture.account(id: "acct-a", label: "A", session: 10, weekly: 60),
                BrokerFixture.account(
                    id: "acct-b", label: "B", isPrimary: false, session: 10, weekly: 10
                ),
            ]),
            cooldowns: BrokerFixture.cooldowns(["t3:beta/claude-fable-5": 600]),
            t3: BrokerFixture.reachable("alpha", "beta")
        )

        XCTAssertEqual(decision.model, "t3:alpha/claude-fable-5")
        XCTAssertFalse(try tried(decision, "t3:beta/claude-fable-5").available)
    }

    // MARK: - Effort pass-through

    /// A one-role policy declared with explicit candidates, so a case can vary
    /// the effort each candidate recommends.
    private func effortPolicy(_ chain: [BrokerCandidate]) -> BrokerPolicy {
        BrokerPolicy(
            roles: ["planning": chain],
            t3: BrokerT3Config(instanceByModel: [:], defaultInstance: "claudeAgent"),
            agentModelAliases: ["claude-fable-5": "fable", "claude-opus-5": "opus"]
        )
    }

    func test_winnersEffort_reachesBothTheDecisionAndTheInvocation() throws {
        let native = try decide(
            policy: effortPolicy([
                BrokerCandidate(route: .native, model: "claude-fable-5", effort: .xhigh)
            ]),
            oracle: BrokerFixture.oracle()
        )
        XCTAssertEqual(native.effort, .xhigh)
        XCTAssertEqual(native.invocation, .agent(model: "fable", effort: .xhigh))

        let t3 = try decide(
            policy: effortPolicy([
                BrokerCandidate(
                    route: .t3, instance: "claude_secondary", model: "claude-fable-5", effort: .medium
                )
            ]),
            oracle: BrokerFixture.oracle(),
            t3: BrokerFixture.reachable("claude_secondary")
        )
        XCTAssertEqual(t3.effort, .medium)
        XCTAssertEqual(
            t3.invocation,
            .t3Dispatch(model: "claude-fable-5", instanceId: "claude_secondary", effort: .medium)
        )

        let codex = try decide(
            policy: effortPolicy([
                BrokerCandidate(route: .codex, model: "gpt-5.6-sol", effort: .low)
            ]),
            oracle: BrokerFixture.oracle()
        )
        XCTAssertEqual(codex.effort, .low)
        XCTAssertEqual(codex.invocation, .codexExec(model: "gpt-5.6-sol", effort: .low))
    }

    func test_onlyTheWinnersEffortSurfaces_andAnUnsetEffortStaysNil() throws {
        let policy = effortPolicy([
            BrokerCandidate(route: .native, model: "claude-fable-5", effort: .low),
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .high),
        ])

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [BrokerFixture.account(fable: 95)])
        )

        XCTAssertEqual(decision.model, "native/claude-opus-5")
        XCTAssertEqual(decision.effort, .high, "the skipped candidate's effort must not leak")

        let unset = try decide(
            policy: effortPolicy([BrokerCandidate(route: .native, model: "claude-opus-5")]),
            oracle: BrokerFixture.oracle()
        )
        XCTAssertNil(unset.effort)
        XCTAssertNil(unset.invocation.effort)
    }

    func test_effortOnAModelWithNoEffortParameter_isDroppedAtTheDispatchBoundary() throws {
        // A policy the editor never wrote — hand-edited JSON, an import, or a
        // build from before the editor clamped — can hand-carry an effort on
        // Haiku, which has no effort parameter. Nothing unactionable may reach
        // a provider, so the decision and its invocation both come back bare.
        let policy = effortPolicy([
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001", effort: .high)
        ])

        let decision = try decide(policy: policy, oracle: BrokerFixture.oracle())

        XCTAssertEqual(decision.model, "native/claude-haiku-4-5-20251001")
        XCTAssertNil(decision.effort)
        XCTAssertNil(decision.invocation.effort)
        XCTAssertEqual(decision.invocation, .agent(model: "claude-haiku-4-5-20251001"))

        // Fail soft in the other direction: an unrecognised model keeps its
        // effort, because the broker must never guess a model's capabilities.
        let unknown = try decide(
            policy: effortPolicy([BrokerCandidate(route: .codex, model: "vendor/mystery-model", effort: .low)]),
            oracle: BrokerFixture.oracle()
        )
        XCTAssertEqual(unknown.effort, .low)
        XCTAssertEqual(unknown.invocation, .codexExec(model: "vendor/mystery-model", effort: .low))
    }

    func test_forcedDegradedPick_carriesTheForcedCandidatesEffort() throws {
        let policy = effortPolicy([
            BrokerCandidate(route: .native, model: "claude-fable-5", effort: .xhigh),
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .low),
        ])

        let decision = try decide(policy: policy, oracle: cappedOracle)

        XCTAssertEqual(decision.source, .forcedDegraded)
        XCTAssertEqual(decision.model, "native/claude-fable-5")
        XCTAssertEqual(decision.effort, .xhigh)
        XCTAssertEqual(decision.invocation, .agent(model: "fable", effort: .xhigh))
        XCTAssertFalse(decision.reason.contains("xhigh"), "no reason string reads effort")
    }

    func test_effortNeverChangesAvailabilityOrCooldownKeying() throws {
        // Two entries for the same candidate id differing only in effort are
        // one lane: the cooldown keyed on that id cools both, so the chain
        // falls through to the third candidate.
        let policy = effortPolicy([
            BrokerCandidate(route: .t3, model: "claude-fable-5", effort: .low),
            BrokerCandidate(route: .t3, model: "claude-fable-5", effort: .xhigh),
            BrokerCandidate(route: .native, model: "claude-opus-5"),
        ])

        let cooled = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(),
            cooldowns: BrokerFixture.cooldowns(["t3/claude-fable-5": 600]),
            t3: BrokerFixture.reachable("claudeAgent")
        )

        XCTAssertEqual(cooled.model, "native/claude-opus-5")
        XCTAssertNil(cooled.effort)
        XCTAssertEqual(
            cooled.candidatesTried.filter { $0.candidate == "t3/claude-fable-5" }.count,
            2,
            "both entries are tried, and both are keyed on the effort-free id"
        )
        XCTAssertTrue(
            cooled.candidatesTried.filter { $0.candidate == "t3/claude-fable-5" }
                .allSatisfy { !$0.available && $0.why.contains("in cooldown") },
            "the cooldown gate is blind to effort"
        )

        // Same chain, no cooldown: the top entry wins with its own effort and
        // the same availability verdict it would have had without one.
        let warm = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(),
            t3: BrokerFixture.reachable("claudeAgent")
        )
        XCTAssertEqual(warm.model, "t3/claude-fable-5")
        XCTAssertEqual(warm.effort, .low)
    }

    // MARK: - Unconfigured lanes rank below verified candidates

    /// The shipped `execution` chain, minus the t3 entry that already fails
    /// closed off a T3 host. This is the fresh-install shape.
    private func executionPolicy() -> BrokerPolicy {
        BrokerFixture.policy(
            roles: ["execution": ["codex/gpt-5.6-sol", "native/claude-sonnet-5"]],
            usageLanes: ["codex/gpt-5.6-sol": .chatGPT(labelContains: "codex weekly")]
        )
    }

    func test_codexLaneWithNoChatGPTAccount_losesToTheVerifiedNativeCandidate() throws {
        // The regression this whole change exists for: on a machine that has
        // never connected a ChatGPT account, the codex candidate used to
        // evaluate plainly available and win, handing back a `/codex-exec`
        // invocation for a CLI the user does not have.
        let decision = try decide(
            role: "execution",
            policy: executionPolicy(),
            oracle: BrokerFixture.oracle(chatGPTState: .unavailable)
        )

        XCTAssertEqual(decision.model, "native/claude-sonnet-5")
        XCTAssertEqual(decision.route, .native)
        XCTAssertFalse(decision.degraded, "the winner's own quota was verified")
        let codex = try tried(decision, "codex/gpt-5.6-sol")
        XCTAssertTrue(codex.available, "it stays available — it is demoted, not excluded")
        XCTAssertTrue(codex.why.contains("no configured quota source"))
        XCTAssertTrue(
            codex.why.contains("held back for a source-verified candidate"),
            "the audit row must explain why an available candidate was passed over"
        )
    }

    func test_unconfiguredLaneStillWins_whenNothingVerifiedCanServeTheRole() throws {
        // Demotion, not exclusion: with the native tail capped, the codex
        // candidate is still the answer rather than a forced-degraded pick.
        let decision = try decide(
            role: "execution",
            policy: executionPolicy(),
            oracle: BrokerFixture.oracle(
                accounts: [BrokerFixture.account(session: 99, weekly: 99)],
                chatGPTState: .unavailable
            )
        )

        XCTAssertEqual(decision.model, "codex/gpt-5.6-sol")
        XCTAssertEqual(decision.source, .policy, "a demoted candidate is not a forced pick")
        XCTAssertTrue(decision.degraded, "but it is quota-blind, so it is flagged")
    }

    func test_staleChatGPTOracle_isNotTreatedAsUnconfigured() throws {
        // The narrowness that keeps a configured machine byte-identical: a poll
        // that merely aged out must not migrate execution work onto Claude
        // quota. `.stale` and `.error` both mean the account exists.
        for state in [BrokerQuotaState.stale, .error] {
            let decision = try decide(
                role: "execution",
                policy: executionPolicy(),
                oracle: BrokerFixture.oracle(chatGPTState: state)
            )

            XCTAssertEqual(
                decision.model, "codex/gpt-5.6-sol",
                "\(state) must keep the rank-1 candidate"
            )
            XCTAssertTrue(decision.degraded, "\(state) is still a quota-blind pick")
            XCTAssertTrue(
                try tried(decision, "codex/gpt-5.6-sol").why.contains("no fresh data"),
                "\(state) reads as stale data, never as an absent account"
            )
        }
    }

    func test_freshChatGPTVerdict_isUnaffected() throws {
        // A real verdict still decides the lane in both directions.
        let rows = [OracleSnapshot.ChatGPTRow(label: "Codex weekly", usedPercent: 10)]
        let healthy = try decide(
            role: "execution",
            policy: executionPolicy(),
            oracle: BrokerFixture.oracle(chatGPTRows: rows)
        )
        XCTAssertEqual(healthy.model, "codex/gpt-5.6-sol")
        XCTAssertFalse(healthy.degraded, "a verified lane is not degraded")

        let capped = try decide(
            role: "execution",
            policy: executionPolicy(),
            oracle: BrokerFixture.oracle(
                chatGPTRows: [OracleSnapshot.ChatGPTRow(label: "Codex weekly", usedPercent: 99)]
            )
        )
        XCTAssertEqual(capped.model, "native/claude-sonnet-5")
        XCTAssertFalse(try tried(capped, "codex/gpt-5.6-sol").available)
    }

    func test_chatGPTConfiguredButNotYetPolled_isNotDemoted() throws {
        // The launch window. ChatGPT usage is never restored from cache, so a
        // fully configured machine reports `.unavailable` from launch until its
        // first fetch lands. Demoting there would reroute execution work onto
        // Claude quota once per launch, on the very machines that do have Codex.
        let decision = try decide(
            role: "execution",
            policy: executionPolicy(),
            oracle: BrokerFixture.oracle(chatGPTState: .unavailable, chatGPTConfigured: true)
        )

        XCTAssertEqual(decision.model, "codex/gpt-5.6-sol")
        XCTAssertTrue(decision.degraded, "still quota-blind, just not unconfigured")
    }

    func test_absentOracle_isIgnoranceNotEvidence() throws {
        // No snapshot at all must not demote anything: that is the same mistake
        // as gating a route on a probe that cannot see it. Only a snapshot that
        // positively reports no source demotes.
        let decision = try decide(
            role: "execution",
            policy: executionPolicy(),
            oracle: nil
        )

        XCTAssertEqual(decision.model, "codex/gpt-5.6-sol")
        XCTAssertFalse(
            BrokerEngine.laneSourceUnconfigured(
                for: try XCTUnwrap(BrokerCandidate(id: "codex/gpt-5.6-sol")),
                policy: executionPolicy(),
                oracle: nil
            )
        )
    }

    func test_demotedLoser_isVisibleInTheDecisionNotJustTheTriedRow() throws {
        // `reason` is what RecentPick and the popover surface, so a permanent
        // routing change must be legible there too.
        let decision = try decide(
            role: "execution",
            policy: executionPolicy(),
            oracle: BrokerFixture.oracle(chatGPTState: .unavailable)
        )

        XCTAssertEqual(decision.model, "native/claude-sonnet-5")
        XCTAssertEqual(
            decision.candidatesTried.map(\.candidate),
            ["codex/gpt-5.6-sol", "native/claude-sonnet-5"],
            "the passed-over candidate stays in the audit trail"
        )
        XCTAssertTrue(
            try tried(decision, "codex/gpt-5.6-sol").why.contains("held back"),
            "and its row says it was held back rather than rejected"
        )
    }

    func test_nativeCandidate_isNeverDemotedEvenWhenMappedToAnAbsentLane() throws {
        // `native` is invocable by construction, so a user-authored lane
        // mapping must not demote it — in the walk or in the forced fallback,
        // which is route-blind and would otherwise disagree with the walk.
        let policy = BrokerFixture.policy(
            roles: ["execution": ["native/claude-sonnet-5", "native/claude-opus-5"]],
            usageLanes: ["native/claude-sonnet-5": .chatGPT(labelContains: "codex weekly")]
        )
        let oracle = BrokerFixture.oracle(chatGPTState: .unavailable)

        XCTAssertFalse(
            BrokerEngine.laneSourceUnconfigured(
                for: try XCTUnwrap(BrokerCandidate(id: "native/claude-sonnet-5")),
                policy: policy,
                oracle: oracle
            )
        )
        let decision = try decide(role: "execution", policy: policy, oracle: oracle)
        XCTAssertEqual(decision.model, "native/claude-sonnet-5", "rank 1 keeps its rank")

        // Same answer on the forced path, with every native pool capped.
        let forced = try decide(
            role: "execution",
            policy: policy,
            oracle: BrokerFixture.oracle(
                accounts: [BrokerFixture.account(session: 99, weekly: 99)],
                chatGPTState: .unavailable
            )
        )
        XCTAssertEqual(forced.source, .forcedDegraded)
        XCTAssertEqual(forced.model, "native/claude-sonnet-5")
    }

    func test_unmappedCandidate_isNotDemoted() throws {
        // Absence of a `usage_lanes` entry is a policy gap, not a quota event:
        // an unmapped codex candidate keeps winning on rank alone.
        let unmapped = BrokerFixture.policy(
            roles: ["execution": ["codex/gpt-5.6-sol", "native/claude-sonnet-5"]]
        )
        let decision = try decide(
            role: "execution",
            policy: unmapped,
            oracle: BrokerFixture.oracle(chatGPTState: .unavailable)
        )

        XCTAssertEqual(decision.model, "codex/gpt-5.6-sol")
        XCTAssertFalse(decision.degraded)
    }

    func test_mappedT3LaneWithNoVerdict_isFlaggedFailOpen() throws {
        // Previously only `.claudeAccount` lanes were flagged; a ChatGPT-mapped
        // t3 lane reported a quota-blind pick as if it were verified.
        let policy = BrokerFixture.policy(
            roles: ["execution": ["t3/gpt-5.6-sol"]],
            usageLanes: ["t3/gpt-5.6-sol": .chatGPT(labelContains: "codex weekly")]
        )
        let decision = try decide(
            role: "execution",
            policy: policy,
            oracle: BrokerFixture.oracle(chatGPTState: .stale),
            t3: BrokerFixture.reachable("claudeAgent")
        )

        XCTAssertEqual(decision.model, "t3/gpt-5.6-sol")
        XCTAssertTrue(decision.degraded, "reachable is not the same as verified")
    }

    func test_forcedDegraded_prefersACandidateWithAConfiguredQuotaSource() throws {
        // Nothing is available, so the fallback runs: the rank-1 lane is cooled
        // AND has no configured quota source, while the rank-2 candidate is
        // merely capped. Forcing the cooled ChatGPT lane on a machine with no
        // ChatGPT account hands back an unactionable pick; the capped native
        // candidate is the better thing to force.
        let policy = executionPolicy()
        let decision = try decide(
            role: "execution",
            policy: policy,
            oracle: BrokerFixture.oracle(
                accounts: [BrokerFixture.account(session: 99, weekly: 99)],
                chatGPTState: .unavailable
            ),
            cooldowns: BrokerFixture.cooldowns(["codex/gpt-5.6-sol": 600])
        )

        XCTAssertEqual(decision.source, .forcedDegraded)
        XCTAssertEqual(decision.model, "native/claude-sonnet-5")
        XCTAssertTrue(decision.degraded)
    }

    func test_forcedDegraded_stillFallsBackToAnUnconfiguredCandidate() throws {
        // The preference is a preference, not a filter: when the unconfigured
        // lane is the only invocable candidate, it is still forced.
        let policy = BrokerFixture.policy(
            roles: ["execution": ["codex/gpt-5.6-sol"]],
            usageLanes: ["codex/gpt-5.6-sol": .chatGPT(labelContains: "codex weekly")]
        )
        let decision = try decide(
            role: "execution",
            policy: policy,
            oracle: BrokerFixture.oracle(chatGPTState: .unavailable),
            cooldowns: BrokerFixture.cooldowns(["codex/gpt-5.6-sol": 600])
        )

        XCTAssertEqual(decision.source, .forcedDegraded)
        XCTAssertEqual(decision.model, "codex/gpt-5.6-sol")
    }

    func test_claudeLaneWithAccountsPresent_isNeverUnconfigured() throws {
        // An unresolvable matcher is a misconfiguration, not an absent source:
        // an unbound `claude_secondary` keeps its rank rather than being
        // demoted behind the rest of the chain.
        let policy = BrokerFixture.policy(
            roles: ["planning": ["t3:claude_secondary/claude-fable-5", "native/claude-opus-5"]],
            t3Instances: [T3InstanceConfig(id: "claude_secondary", name: "Claude (second account)")],
            usageLanes: [
                "t3:claude_secondary/claude-fable-5": .claudeAccount(
                    accountId: nil, labelContains: nil, isPrimary: nil
                )
            ]
        )
        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(),
            t3: BrokerFixture.reachable("claude_secondary")
        )

        XCTAssertEqual(decision.model, "t3:claude_secondary/claude-fable-5")
        XCTAssertTrue(decision.degraded, "unresolvable still means quota-blind")
    }

    // MARK: - Caller intake validation

    func test_malformedCaller_isRejectedBeforeItReachesAnySink() {
        // The broker port is loopback but unauthenticated, and the resolved
        // caller is echoed into the decision, rendered, and persisted.
        let policy = BrokerFixture.policy(roles: ["planning": ["native/claude-fable-5"]])
        let malformed = [
            "claude code",                        // whitespace
            "claude/code",                        // splits a candidate id
            "claude:code",                        // splits a route qualifier
            "claude\u{202E}edoc",                 // bidi override
            "claude\ncode",                       // newline
            String(repeating: "a", count: 65),    // over the length cap
        ]

        for caller in malformed {
            XCTAssertThrowsError(
                try decide(caller: caller, policy: policy, oracle: BrokerFixture.oracle()),
                "'\(caller)' must be rejected"
            ) { error in
                guard case BrokerError.malformedCaller = error else {
                    return XCTFail("expected malformedCaller for '\(caller)', got \(error)")
                }
            }
        }
    }

    func test_malformedCallerMessage_neverEchoesRawControlCharacters() {
        let policy = BrokerFixture.policy(roles: ["planning": ["native/claude-fable-5"]])

        XCTAssertThrowsError(
            try decide(caller: "evil\u{202E}\u{0007}", policy: policy, oracle: BrokerFixture.oracle())
        ) { error in
            let message = (error as? BrokerError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("evil??"), "unsafe scalars are replaced, got: \(message)")
            XCTAssertFalse(message.unicodeScalars.contains { $0.properties.isDefaultIgnorableCodePoint })
            XCTAssertFalse(message.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        }
    }

    func test_redactedCaller_boundsCombiningMarksNotJustGraphemes() {
        // A grapheme-counted prefix would bound the visible length while
        // letting one Character carry unbounded combining marks — none of which
        // are control, newline, or default-ignorable, so none get replaced.
        let zalgo = "a" + String(repeating: "\u{0301}", count: 5_000)
        let redacted = BrokerPolicy.redactedCaller(zalgo)

        XCTAssertLessThanOrEqual(
            redacted.unicodeScalars.count,
            BrokerPolicy.maxCallerLength,
            "truncation must count scalars, not Characters"
        )
    }

    func test_policyDeclaredCaller_survivesIntakeEvenIfUnusual() throws {
        // Hand-authored policy is user config, at the same trust level as an
        // instance name — the charset rule exists for unauthenticated port
        // input, and there is no callers editor to author ids through yet.
        let declared = "my harness"
        let policy = BrokerFixture.policy(
            roles: ["planning": ["native/claude-fable-5"]],
            callers: [declared: BrokerCallerPolicy(routes: [.native])]
        )

        let decision = try decide(caller: declared, policy: policy, oracle: BrokerFixture.oracle())
        XCTAssertEqual(decision.caller, declared)

        // An undeclared id with the same shape is still rejected.
        XCTAssertThrowsError(
            try decide(caller: "other harness", policy: policy, oracle: BrokerFixture.oracle())
        ) { error in
            guard case BrokerError.malformedCaller = error else {
                return XCTFail("expected malformedCaller, got \(error)")
            }
        }
    }

    func test_wellFormedCallers_stillResolve() throws {
        let policy = BrokerFixture.policy(roles: ["planning": ["native/claude-fable-5"]])

        // Both contract callers, the omitted default, and a plausible
        // third-party id all survive intake.
        for caller in [nil, "claude-code", "codex", "some_other.harness-3"] as [String?] {
            let decision = try decide(
                caller: caller,
                policy: policy,
                oracle: BrokerFixture.oracle()
            )
            XCTAssertEqual(decision.caller, caller ?? BrokerPolicy.defaultCaller)
        }
    }
}
