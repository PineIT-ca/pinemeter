//
//  BrokerEngineTests.swift
//  PinemeterTests
//
//  Table-driven decision-semantics suite for the pure broker engine. Every
//  input is injected (policy, oracle snapshot, cooldown map, clock, T3
//  liveness), so nothing here touches the filesystem, the network or the
//  wall clock — the same test architecture the trixie-box reference uses.
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
        fable: Double? = nil
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
            fable: fable
        )
    }

    static func oracle(
        accounts: [OracleSnapshot.AccountRow] = [account()],
        chatGPTState: BrokerQuotaState = .fresh,
        chatGPTRows: [OracleSnapshot.ChatGPTRow] = []
    ) -> OracleSnapshot {
        OracleSnapshot(
            generatedAt: now,
            accounts: accounts,
            chatGPTState: chatGPTState,
            chatGPTRows: chatGPTRows
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
                    "t3:claude_autimo/claude-fable-5",
                    "t3/claude-fable-5",
                    "native/claude-opus-5",
                ]
            ]
        )

        let decision = try decide(
            policy: policy,
            cooldowns: BrokerFixture.cooldowns(["t3": 600]),
            t3: BrokerFixture.reachable("claudeAgent", "claude_autimo")
        )

        XCTAssertEqual(decision.model, "native/claude-opus-5")
        XCTAssertFalse(try tried(decision, "t3:claude_autimo/claude-fable-5").available)
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
                    "t3:claude_autimo/claude-fable-5",
                    "t3/claude-fable-5",
                    "native/claude-opus-5",
                ]
            ]
        )
        let signal = BrokerFixture.reachable("claudeAgent", "claude_autimo")

        let autimoDown = try decide(
            policy: policy,
            cooldowns: BrokerFixture.cooldowns(["t3:claude_autimo/claude-fable-5": 600]),
            t3: signal
        )
        XCTAssertEqual(
            autimoDown.model, "t3/claude-fable-5",
            "cooling the qualified lane must not cool the default-instance lane"
        )

        let defaultDown = try decide(
            policy: policy,
            cooldowns: BrokerFixture.cooldowns(["t3:claudeAgent/claude-fable-5": 600]),
            t3: signal
        )
        XCTAssertEqual(
            defaultDown.model, "t3:claude_autimo/claude-fable-5",
            "cooling the claudeAgent instance must not cool the autimo lane"
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
            roles: ["planning": ["t3:claude_autimo/claude-fable-5", "native/claude-opus-5"]],
            t3Instances: [
                T3InstanceConfig(id: "claude_autimo", name: "Claude (autimo)", boundAccountId: "acct-autimo")
            ],
            usageLanes: [
                "t3:claude_autimo/claude-fable-5": .claudeAccount(
                    accountId: nil, labelContains: nil, isPrimary: nil
                )
            ]
        )
        let signal = BrokerFixture.reachable("claude_autimo")

        func laneVerdict(
            session: Double?, weekly: Double?, fable: Double?
        ) throws -> BrokerCandidateTried {
            let decision = try decide(
                policy: policy,
                oracle: BrokerFixture.oracle(accounts: [
                    BrokerFixture.account(),
                    BrokerFixture.account(
                        id: "acct-autimo", label: "Autimo", isPrimary: false,
                        session: session, weekly: weekly, fable: fable
                    ),
                ]),
                t3: signal
            )
            return try tried(decision, "t3:claude_autimo/claude-fable-5")
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
            roles: ["planning": ["t3:claude_autimo/claude-fable-5"]],
            t3Instances: [
                T3InstanceConfig(id: "claude_autimo", name: "Claude (autimo)", boundAccountId: "acct-autimo")
            ],
            usageLanes: [
                "t3:claude_autimo/claude-fable-5": .claudeAccount(
                    accountId: nil, labelContains: nil, isPrimary: nil
                )
            ]
        )

        let decision = try decide(
            policy: policy,
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(),
                BrokerFixture.account(
                    id: "acct-autimo", label: "Autimo", isPrimary: false, state: .stale
                ),
            ]),
            t3: BrokerFixture.reachable("claude_autimo")
        )

        XCTAssertEqual(decision.model, "t3:claude_autimo/claude-fable-5")
        XCTAssertEqual(decision.source, .policy)
        XCTAssertTrue(decision.degraded, "a mapped claude lane with no fresh row fails OPEN")
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

    func test_chatGPTLaneWithNoData_isAvailableAndNotDegraded() throws {
        let policy = BrokerFixture.policy(
            roles: ["execution": ["codex/gpt-5.6-sol"]],
            usageLanes: ["codex/gpt-5.6-sol": .chatGPT(labelContains: "codex weekly")]
        )

        let decision = try decide(
            role: "execution",
            policy: policy,
            oracle: BrokerFixture.oracle(chatGPTState: .stale, chatGPTRows: [])
        )

        XCTAssertEqual(decision.model, "codex/gpt-5.6-sol")
        XCTAssertFalse(
            decision.degraded,
            "the chatgpt asymmetry is deliberate: no data does NOT degrade the lane"
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
            roles: ["planning": ["native/claude-fable-5", "t3:claude_autimo/claude-fable-5"]],
            t3Instances: [
                T3InstanceConfig(id: "claude_autimo", name: "Claude (autimo)", boundAccountId: "acct-autimo")
            ],
            usageLanes: [
                "t3:claude_autimo/claude-fable-5": .claudeAccount(
                    accountId: nil, labelContains: nil, isPrimary: nil
                )
            ]
        )
        let cappedPrimary = BrokerFixture.account(session: 10, weekly: 99)
        let staleAutimo = BrokerFixture.account(
            id: "acct-autimo", label: "Autimo", isPrimary: false, state: .stale
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
                oracle: BrokerFixture.oracle(accounts: [cappedPrimary, staleAutimo]),
                t3: BrokerFixture.reachable("claude_autimo"),
                model: "t3:claude_autimo/claude-fable-5",
                source: .policy,
                degraded: true
            ),
            Row(
                name: "everything capped forces the top invocable candidate",
                role: "planning",
                policy: nativeThenT3,
                oracle: BrokerFixture.oracle(accounts: [cappedPrimary, staleAutimo]),
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
            roles: ["planning": ["t3:claude_autimo/claude-fable-5"]],
            agentModelAliases: aliases
        )
        let t3Decision = try decide(
            policy: t3Policy,
            oracle: BrokerFixture.oracle(),
            t3: BrokerFixture.reachable("claude_autimo")
        )
        XCTAssertNil(t3Decision.agentModel, "only native picks carry an agent alias")
        XCTAssertEqual(
            t3Decision.invocation,
            .t3Dispatch(model: "claude-fable-5", instanceId: "claude_autimo")
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
            "t3:claude_autimo/claude-fable-5",
            "t3/claude-fable-5",
            "native/claude-opus-5",
            "native/claude-sonnet-5",
        ]

        for role in ["planning", "architecture", "design", "review", "research"] {
            XCTAssertEqual(seed.roles[role]?.map(\.id), fableChain, role)
        }
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

        for role in ["planning", "architecture", "design", "review", "research"] {
            XCTAssertEqual(
                seed.roles[role]?.map(\.effort),
                [nil, nil, nil, .xhigh, .xhigh],
                "\(role): fable stays adaptive, the substitutes escalate"
            )
        }
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
        XCTAssertEqual(seed.t3Instances.map(\.id), ["claudeAgent", "claude_autimo", "codex"])
        XCTAssertTrue(
            seed.t3Instances.allSatisfy { $0.boundAccountId == nil },
            "a shipped seed must not assume this machine's account ids"
        )

        XCTAssertEqual(
            seed.usageLanes["t3/claude-fable-5"],
            .claudeAccount(accountId: nil, labelContains: nil, isPrimary: true)
        )
        XCTAssertEqual(
            seed.usageLanes["t3:claude_autimo/claude-fable-5"],
            .claudeAccount(accountId: nil, labelContains: nil, isPrimary: nil),
            "the autimo lane resolves through the instance's bound account, seeded unbound"
        )
        for lane in ["t3/gpt-5.6-sol", "codex/gpt-5.6-sol"] {
            XCTAssertEqual(seed.usageLanes[lane], .chatGPT(labelContains: "codex weekly"), lane)
        }

        // The seed must survive a persistence round-trip unchanged.
        let data = try JSONEncoder().encode(BrokerPolicy.bundledDefault)
        XCTAssertEqual(try JSONDecoder().decode(BrokerPolicy.self, from: data), seed)
    }

    func test_seedEndToEnd_planningFallsFromACappedFablePoolToTheAutimoT3Lane() throws {
        let decision = try decide(
            role: "planning",
            caller: "claude-code",
            policy: .bundledDefault,
            oracle: BrokerFixture.oracle(accounts: [
                BrokerFixture.account(session: 10, weekly: 20, sonnet: 5, fable: 95)
            ]),
            t3: BrokerFixture.reachable("claude_autimo")
        )

        XCTAssertEqual(decision.model, "t3:claude_autimo/claude-fable-5")
        XCTAssertEqual(decision.route, .t3)
        XCTAssertEqual(decision.source, .policy)
        XCTAssertTrue(decision.degraded, "the autimo lane ships unbound, so the pick is quota-blind")
        XCTAssertEqual(
            decision.invocation,
            .t3Dispatch(model: "claude-fable-5", instanceId: "claude_autimo")
        )

        let skipped = try tried(decision, "native/claude-fable-5")
        XCTAssertFalse(skipped.available)
        XCTAssertTrue(skipped.why.contains("fable pool 95% >= 90%"), skipped.why)
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
                    route: .t3, instance: "claude_autimo", model: "claude-fable-5", effort: .medium
                )
            ]),
            oracle: BrokerFixture.oracle(),
            t3: BrokerFixture.reachable("claude_autimo")
        )
        XCTAssertEqual(t3.effort, .medium)
        XCTAssertEqual(
            t3.invocation,
            .t3Dispatch(model: "claude-fable-5", instanceId: "claude_autimo", effort: .medium)
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
}
