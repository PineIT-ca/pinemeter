//
//  BrokerContractTests.swift
//  PinemeterTests
//
//  Pins the broker's wire contract. The decision JSON field names are matched
//  by every consumer of the `pick` tool, so a rename here is a breaking change:
//  these tests exist to make that break loud and deliberate.
//

import XCTest
@testable import Pinemeter

final class BrokerContractTests: XCTestCase {

    // MARK: - Test 1: decision top-level key set

    func test_fullyPopulatedDecision_encodesExactlyTheContractKeys() throws {
        let json = try encodeToObject(Self.fullyPopulatedDecision)

        XCTAssertEqual(
            Set(json.keys),
            [
                "role", "caller", "model", "route", "agentModel", "invocation",
                "reason", "source", "oracle", "degraded", "candidatesTried",
            ],
            "decision JSON gained/lost/renamed a top-level key"
        )
        XCTAssertEqual(json["role"] as? String, "planning")
        XCTAssertEqual(json["caller"] as? String, "codex")
        XCTAssertEqual(json["model"] as? String, "t3:claude_autimo/claude-fable-5")
        XCTAssertEqual(json["route"] as? String, "t3")
        XCTAssertEqual(json["agentModel"] as? String, "fable")
        XCTAssertEqual(json["source"] as? String, "forced-degraded")
        XCTAssertEqual(json["degraded"] as? Bool, true)
    }

    func test_decisionSource_encodesPolicyAndForcedDegradedSpellings() throws {
        XCTAssertEqual(BrokerDecisionSource.policy.rawValue, "policy")
        XCTAssertEqual(BrokerDecisionSource.forcedDegraded.rawValue, "forced-degraded")
    }

    // MARK: - Test 2: oracle block and candidatesTried entries

    func test_oracleBlock_encodesEveryContractKey() throws {
        let json = try encodeToObject(Self.fullyPopulatedDecision)
        let oracle = try XCTUnwrap(json["oracle"] as? [String: Any])

        XCTAssertEqual(
            Set(oracle.keys),
            ["present", "stale", "ageSeconds", "session", "weekly", "sonnet", "fable"]
        )
        XCTAssertEqual(oracle["present"] as? Bool, true)
        XCTAssertEqual(oracle["stale"] as? Bool, false)
        XCTAssertEqual(oracle["ageSeconds"] as? Double, 42)
        XCTAssertEqual(oracle["weekly"] as? Double, 61.5)
    }

    func test_absentOracle_stillEncodesEveryKeyWithNullValues() throws {
        let json = try encodeToObject(BrokerOracleBlock.absent)

        XCTAssertEqual(
            Set(json.keys),
            ["present", "stale", "ageSeconds", "session", "weekly", "sonnet", "fable"]
        )
        XCTAssertEqual(json["present"] as? Bool, false)
        XCTAssertTrue(json["weekly"] is NSNull, "an absent value must encode as null, not be omitted")
    }

    func test_candidatesTried_encodesCallerFilteredOnlyWhenTrue() throws {
        let json = try encodeToObject(Self.fullyPopulatedDecision)
        let tried = try XCTUnwrap(json["candidatesTried"] as? [[String: Any]])
        XCTAssertEqual(tried.count, 2)

        XCTAssertEqual(Set(tried[0].keys), ["candidate", "available", "why"],
                       "a non-caller-filtered entry must omit callerFiltered")
        XCTAssertEqual(tried[0]["candidate"] as? String, "native/claude-fable-5")
        XCTAssertEqual(tried[0]["available"] as? Bool, false)

        XCTAssertEqual(Set(tried[1].keys), ["candidate", "available", "callerFiltered", "why"])
        XCTAssertEqual(tried[1]["callerFiltered"] as? Bool, true)
    }

    // MARK: - Test 3: invocation shapes

    func test_nativeInvocation_encodesAgentKindWithTheAgentAlias() throws {
        let json = try encodeToObject(BrokerInvocation.agent(model: "fable"))

        XCTAssertEqual(Set(json.keys), ["kind", "model"])
        XCTAssertEqual(json["kind"] as? String, "agent")
        XCTAssertEqual(json["model"] as? String, "fable")
    }

    func test_codexInvocation_encodesCodexExecKindWithCommand() throws {
        let json = try encodeToObject(BrokerInvocation.codexExec(model: "gpt-5.6-sol"))

        XCTAssertEqual(Set(json.keys), ["kind", "command", "model"])
        XCTAssertEqual(json["kind"] as? String, "codex-exec")
        XCTAssertEqual(json["command"] as? String, "/codex-exec")
        XCTAssertEqual(json["model"] as? String, "gpt-5.6-sol")
    }

    func test_t3Invocation_encodesT3DispatchKindWithCommandAndInstance() throws {
        let json = try encodeToObject(
            BrokerInvocation.t3Dispatch(model: "claude-fable-5", instanceId: "claude_autimo")
        )

        XCTAssertEqual(Set(json.keys), ["kind", "command", "model", "instanceId"])
        XCTAssertEqual(json["kind"] as? String, "t3-dispatch")
        XCTAssertEqual(json["command"] as? String, "/t3-dispatch")
        XCTAssertEqual(json["model"] as? String, "claude-fable-5")
        XCTAssertEqual(json["instanceId"] as? String, "claude_autimo")
    }

    func test_invocationRoundTrips_forEveryVariant() throws {
        let variants: [BrokerInvocation] = [
            .agent(model: "opus"),
            .codexExec(model: "gpt-5.6-sol"),
            .t3Dispatch(model: "claude-fable-5", instanceId: "claudeAgent"),
        ]
        for variant in variants {
            let data = try BrokerDecision.makeEncoder().encode(variant)
            let decoded = try JSONDecoder().decode(BrokerInvocation.self, from: data)
            XCTAssertEqual(decoded, variant)
        }
    }

    // MARK: - Test 4: candidate id parsing

    func test_candidateId_splitsAtTheFirstSlashSoModelsMayContainSlashes() throws {
        let candidate = try XCTUnwrap(BrokerCandidate(id: "codex/openai/gpt-5.6-sol"))

        XCTAssertEqual(candidate.route, .codex)
        XCTAssertNil(candidate.instance)
        XCTAssertEqual(candidate.model, "openai/gpt-5.6-sol")
        XCTAssertEqual(candidate.id, "codex/openai/gpt-5.6-sol")
    }

    func test_candidateId_splitsTheRoutePartAtItsFirstColon() throws {
        let candidate = try XCTUnwrap(BrokerCandidate(id: "t3:claude_autimo:extra/claude-fable-5"))

        XCTAssertEqual(candidate.route, .t3)
        XCTAssertEqual(candidate.instance, "claude_autimo:extra")
        XCTAssertEqual(candidate.model, "claude-fable-5")
        XCTAssertEqual(candidate.id, "t3:claude_autimo:extra/claude-fable-5")
    }

    func test_candidateId_emptyQualifierYieldsNoInstanceAndRoundTripsCanonically() throws {
        let candidate = try XCTUnwrap(BrokerCandidate(id: "t3:/m"))

        XCTAssertEqual(candidate.route, .t3)
        XCTAssertNil(candidate.instance)
        XCTAssertEqual(candidate.model, "m")
        XCTAssertEqual(candidate.id, "t3/m", "the canonical form drops an empty qualifier")
    }

    func test_candidateId_rejectsMalformedAndUnknownRoutes() {
        XCTAssertNil(BrokerCandidate(id: "native"), "no slash")
        XCTAssertNil(BrokerCandidate(id: "native/"), "empty model")
        XCTAssertNil(BrokerCandidate(id: "/model"), "empty route part")
        XCTAssertNil(BrokerCandidate(id: "llmproxy/claude-fable-5"), "dropped route")
    }

    func test_route_hasExactlyTheThreeSupportedCases() {
        XCTAssertEqual(BrokerPolicy.Route.allCases, [.native, .t3, .codex])
    }

    func test_candidateInit_dropsInstanceQualifierWhenRouteIsNotT3() {
        // Regression for CR-01: the policy editor's route picker carries the
        // prior `instance` forward when a candidate's route changes. A t3
        // candidate with an instance switched to `native` must yield the
        // bare "native/model" id, never a stale ":instance" qualifier.
        let switched = BrokerCandidate(
            route: .native, instance: "claude_autimo", model: "claude-sonnet-5"
        )

        XCTAssertNil(switched.instance)
        XCTAssertEqual(switched.id, "native/claude-sonnet-5")

        let codexCandidate = BrokerCandidate(
            route: .codex, instance: "claude_autimo", model: "gpt-5.6-sol"
        )
        XCTAssertNil(codexCandidate.instance)
        XCTAssertEqual(codexCandidate.id, "codex/gpt-5.6-sol")
    }

    func test_candidateId_decodingAMalformedNonT3QualifierNormalizesSafely() throws {
        // Regression for CR-01: a persisted malformed id (e.g. from a build
        // predating the instance-clearing fix) must decode to the
        // normalized, unqualified form rather than round-tripping the
        // corruption forever.
        let candidate = try XCTUnwrap(BrokerCandidate(id: "native:foo/model"))

        XCTAssertEqual(candidate.route, .native)
        XCTAssertNil(candidate.instance)
        XCTAssertEqual(candidate.model, "model")
        XCTAssertEqual(candidate.id, "native/model")
    }

    // MARK: - Test 5: threshold decode safety

    func test_policyMissingAnyThresholdKey_fallsBackToTheSeededDefault() throws {
        let defaults = BrokerThresholds.default
        let json = """
        {
            "roles": { "planning": ["native/claude-fable-5"] },
            "thresholds": { "weekly_pct": 70 }
        }
        """
        let policy = try JSONDecoder().decode(BrokerPolicy.self, from: Data(json.utf8))

        XCTAssertEqual(policy.thresholds.weeklyPct, 70, "an explicit key must win")
        XCTAssertEqual(policy.thresholds.sessionPct, defaults.sessionPct)
        XCTAssertEqual(policy.thresholds.sonnetWeeklyPct, defaults.sonnetWeeklyPct)
        XCTAssertEqual(policy.thresholds.fableWeeklyPct, defaults.fableWeeklyPct)
        XCTAssertEqual(policy.thresholds.chatgptWeeklyPct, defaults.chatgptWeeklyPct)
        XCTAssertEqual(policy.thresholds.stalenessSeconds, defaults.stalenessSeconds)
    }

    func test_policyWithNoThresholdsBlockAtAll_usesEverySeededDefault() throws {
        let json = #"{ "roles": { "planning": ["native/claude-fable-5"] } }"#
        let policy = try JSONDecoder().decode(BrokerPolicy.self, from: Data(json.utf8))

        XCTAssertEqual(policy.thresholds, .default)
        XCTAssertEqual(policy.thresholds.sessionPct, 90)
        XCTAssertEqual(policy.thresholds.weeklyPct, 85)
        XCTAssertEqual(policy.thresholds.stalenessSeconds, 1200)
    }

    func test_policyWithNoCallersOrLanes_decodesToTheSeededDefaults() throws {
        let json = #"{ "roles": { "planning": ["native/claude-fable-5"] } }"#
        let policy = try JSONDecoder().decode(BrokerPolicy.self, from: Data(json.utf8))

        XCTAssertEqual(policy.callers, BrokerPolicy.default.callers)
        XCTAssertEqual(policy.usageLanes, BrokerPolicy.default.usageLanes)
        XCTAssertEqual(policy.t3, BrokerPolicy.default.t3)
        XCTAssertEqual(policy.agentModelAliases, BrokerPolicy.default.agentModelAliases)
    }

    func test_allowForcedDegraded_defaultsToTrueForAnUnlistedRole() {
        var policy = BrokerPolicy.default
        policy.allowForcedDegraded = ["execution": false]

        XCTAssertTrue(policy.allowsForcedDegraded(role: "planning"))
        XCTAssertFalse(policy.allowsForcedDegraded(role: "execution"))
    }

    // MARK: - Test 6: policy round-trip

    func test_defaultPolicy_roundTripsThroughJSONUnchanged() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(BrokerPolicy.default)
        let decoded = try decoder.decode(BrokerPolicy.self, from: data)

        XCTAssertEqual(decoded, BrokerPolicy.default)
    }

    func test_seededPolicy_carriesTheSurvivingRoutesAndT3Wiring() {
        let policy = BrokerPolicy.default

        let planning = try? XCTUnwrap(policy.roles["planning"])
        XCTAssertEqual(planning?.first?.id, "native/claude-fable-5")
        XCTAssertEqual(policy.callers[BrokerPolicy.defaultCaller]?.routes, [.native, .codex, .t3])
        XCTAssertEqual(policy.callers["codex"]?.routes, [.t3])
        XCTAssertEqual(policy.t3.defaultInstance, "claudeAgent")
        XCTAssertEqual(policy.t3.instanceByModel["gpt-5.6-sol"], "codex")
        XCTAssertTrue(policy.t3Instances.contains { $0.id == "claude_autimo" })
        XCTAssertTrue(
            policy.t3Instances.allSatisfy { $0.boundAccountId == nil },
            "a shipped seed must not assume this machine's account ids"
        )
    }

    func test_resolvedInstance_prefersTheInlineQualifierThenTheModelMapThenTheDefault() throws {
        let policy = BrokerPolicy.default

        let inline = try XCTUnwrap(BrokerCandidate(id: "t3:claude_autimo/claude-fable-5"))
        XCTAssertEqual(policy.resolvedInstance(for: inline), "claude_autimo")

        let byModel = try XCTUnwrap(BrokerCandidate(id: "t3/gpt-5.6-sol"))
        XCTAssertEqual(policy.resolvedInstance(for: byModel), "codex")

        let fallback = try XCTUnwrap(BrokerCandidate(id: "t3/claude-fable-5"))
        XCTAssertEqual(policy.resolvedInstance(for: fallback), "claudeAgent")
    }

    func test_removeT3Instance_blocksEveryActiveReferenceWithoutMutatingPolicy() throws {
        var policy = BrokerPolicy(
            roles: [
                "zeta-role": [BrokerCandidate(route: .t3, instance: "shared", model: "inline-model")],
                "alpha-role": [BrokerCandidate(route: .t3, model: "z-model")],
                "beta-role": [BrokerCandidate(route: .t3, model: "fallback-model")],
            ],
            t3: BrokerT3Config(
                instanceByModel: ["z-model": "shared", "a-model": "shared"],
                defaultInstance: "shared"
            ),
            t3Instances: [
                T3InstanceConfig(id: "shared", name: "Shared"),
                T3InstanceConfig(id: "spare", name: "Spare"),
            ]
        )
        let before = policy

        let error = policy.removeT3Instance(id: "shared")

        XCTAssertEqual(
            error,
            "Cannot delete T3 instance \"shared\": roles: alpha-role, beta-role, zeta-role; "
                + "instance_by_model: a-model, z-model; default_instance. "
                + "Update these references before deleting."
        )
        XCTAssertEqual(policy, before)
    }

    func test_removeT3Instance_removesOnlyAnUnreferencedInstance() {
        var policy = BrokerPolicy(
            roles: ["planning": [BrokerCandidate(route: .t3, model: "model")]],
            t3: BrokerT3Config(instanceByModel: ["model": "shared"], defaultInstance: "shared"),
            t3Instances: [
                T3InstanceConfig(id: "shared", name: "Shared"),
                T3InstanceConfig(id: "spare", name: "Spare"),
            ]
        )
        var expected = policy
        expected.t3Instances.removeAll { $0.id == "spare" }

        XCTAssertNil(policy.removeT3Instance(id: "spare"))
        XCTAssertEqual(policy, expected)
    }

    // MARK: - Frozen engine signature

    func test_decide_acceptsTheFrozenWorldInputsAndEchoesTheCaller() throws {
        let decision = try BrokerEngine.decide(
            role: "planning",
            caller: nil,
            policy: .default,
            oracle: nil,
            cooldowns: [:],
            now: Date(timeIntervalSince1970: 1_700_000_000),
            t3: [:]
        )

        XCTAssertEqual(decision.caller, BrokerPolicy.defaultCaller)
        XCTAssertEqual(decision.role, "planning")
        XCTAssertEqual(decision.model, "native/claude-fable-5")
        XCTAssertEqual(decision.agentModel, "fable")
    }

    func test_decide_throwsUnknownRoleListingTheKnownRoles() {
        XCTAssertThrowsError(
            try BrokerEngine.decide(
                role: "nope",
                caller: "claude-code",
                policy: .default,
                oracle: nil,
                cooldowns: [:],
                now: Date(),
                t3: [:]
            )
        ) { error in
            guard case BrokerError.unknownRole(let role, let known) = error else {
                return XCTFail("expected unknownRole, got \(error)")
            }
            XCTAssertEqual(role, "nope")
            XCTAssertTrue(known.contains("planning"))
        }
    }

    func test_oracleSnapshotAndT3Liveness_areValueTypesTheEngineCanTake() throws {
        let snapshot = OracleSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            accounts: [
                OracleSnapshot.AccountRow(
                    id: "acct-1",
                    label: "primary",
                    isPrimary: true,
                    lastUpdated: Date(timeIntervalSince1970: 1_699_999_000),
                    state: .fresh,
                    session: 10,
                    weekly: 20,
                    sonnet: 30,
                    fable: 40
                )
            ],
            chatGPTState: .stale,
            chatGPTRows: [OracleSnapshot.ChatGPTRow(label: "Codex weekly", usedPercent: 55)]
        )

        let decision = try BrokerEngine.decide(
            role: "execution",
            caller: "codex",
            policy: .default,
            oracle: snapshot,
            cooldowns: ["t3/gpt-5.6-sol": Date(timeIntervalSince1970: 1_800_000_000)],
            now: Date(timeIntervalSince1970: 1_700_000_000),
            t3: ["codex": T3Liveness(reachable: true, why: "http 200")]
        )

        XCTAssertEqual(decision.caller, "codex")
        XCTAssertEqual(snapshot.accounts.first?.state, .fresh)
    }

    // MARK: - Fixtures & helpers

    private static let fullyPopulatedDecision = BrokerDecision(
        role: "planning",
        caller: "codex",
        model: "t3:claude_autimo/claude-fable-5",
        route: .t3,
        agentModel: "fable",
        invocation: .t3Dispatch(model: "claude-fable-5", instanceId: "claude_autimo"),
        reason: "no candidate had headroom; forcing top choice (degraded)",
        source: .forcedDegraded,
        oracle: BrokerOracleBlock(
            present: true,
            stale: false,
            ageSeconds: 42,
            session: 12.5,
            weekly: 61.5,
            sonnet: 3,
            fable: 7.25
        ),
        degraded: true,
        candidatesTried: [
            BrokerCandidateTried(
                candidate: "native/claude-fable-5",
                available: false,
                why: "native weekly 91% >= 85%"
            ),
            BrokerCandidateTried(
                candidate: "codex/gpt-5.6-sol",
                available: false,
                callerFiltered: true,
                why: "route \"codex\" not invocable by caller \"codex\""
            ),
        ]
    )

    private func encodeToObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try BrokerDecision.makeEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "encoded value was not a JSON object"
        )
    }
}
