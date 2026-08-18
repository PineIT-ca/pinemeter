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
                "reason", "source", "oracle", "degraded", "candidatesTried", "effort",
                "decision_id",
            ],
            "decision JSON gained/lost/renamed a top-level key"
        )
        XCTAssertEqual(json["role"] as? String, "planning")
        XCTAssertEqual(json["caller"] as? String, "codex")
        XCTAssertEqual(json["model"] as? String, "t3:claude_secondary/claude-fable-5")
        XCTAssertEqual(json["route"] as? String, "t3")
        XCTAssertEqual(json["agentModel"] as? String, "fable")
        XCTAssertEqual(json["source"] as? String, "forced-degraded")
        XCTAssertEqual(json["degraded"] as? Bool, true)
        XCTAssertEqual(json["effort"] as? String, "high")
    }

    func test_decisionWithoutAnEffort_omitsTheKeyEntirely() throws {
        // `effort` is additive: a decision that recommends none must encode
        // exactly the key set consumers saw before efforts existed.
        let json = try encodeToObject(Self.effortlessDecision)

        XCTAssertEqual(
            Set(json.keys),
            [
                "role", "caller", "model", "route", "agentModel", "invocation",
                "reason", "source", "oracle", "degraded", "candidatesTried",
            ],
            "an absent effort must be omitted, not encoded as null"
        )
        let invocation = try XCTUnwrap(json["invocation"] as? [String: Any])
        XCTAssertEqual(Set(invocation.keys), ["kind", "model"])
    }

    func test_decisionEffort_roundTripsThroughTheWireForm() throws {
        let data = try BrokerDecision.makeEncoder().encode(Self.fullyPopulatedDecision)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BrokerDecision.self, from: data)

        XCTAssertEqual(decoded.effort, .high)
        XCTAssertEqual(decoded.invocation.effort, .high)
        XCTAssertEqual(decoded, Self.fullyPopulatedDecision)
    }

    func testDecisionIDIsAdditiveAndLegacySafe() throws {
        let encoded = try encodeToObject(Self.fullyPopulatedDecision)
        XCTAssertEqual(encoded["decision_id"] as? String, "decision-123")

        let legacyData = try BrokerDecision.makeEncoder().encode(Self.effortlessDecision)
        let legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        )
        XCTAssertNil(legacyObject["decision_id"])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BrokerDecision.self, from: legacyData)
        XCTAssertNil(decoded.decisionID)
        XCTAssertEqual(decoded, Self.effortlessDecision)
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
            [
                "present", "stale", "ageSeconds", "session", "weekly", "sonnet", "fable",
                "sessionResetAt", "weeklyResetAt", "sonnetResetAt", "fableResetAt", "chatGPTRows",
            ]
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
            [
                "present", "stale", "ageSeconds", "session", "weekly", "sonnet", "fable",
                "sessionResetAt", "weeklyResetAt", "sonnetResetAt", "fableResetAt", "chatGPTRows",
            ]
        )
        XCTAssertEqual(json["present"] as? Bool, false)
        XCTAssertTrue(json["weekly"] is NSNull, "an absent value must encode as null, not be omitted")
    }

    func testOracleResetFieldsAreAdditiveAndLegacySafe() throws {
        let reset = Date(timeIntervalSince1970: 1_700_100_000)
        let block = BrokerOracleBlock(
            present: true,
            stale: false,
            session: 20,
            weekly: 30,
            sessionResetAt: reset,
            weeklyResetAt: reset,
            sonnetResetAt: reset,
            fableResetAt: reset,
            chatGPTRows: [
                OracleSnapshot.ChatGPTRow(
                    label: "Codex 5h",
                    usedPercent: 40,
                    resetAt: reset,
                    windowRole: .chatGPT5h
                )
            ]
        )
        let encoded = try encodeToObject(block)

        XCTAssertEqual(encoded["sessionResetAt"] as? String, "2023-11-16T02:00:00Z")
        let rows = try XCTUnwrap(encoded["chatGPTRows"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["windowRole"] as? String, "chatGPT5h")

        let legacy = #"{"present":true,"stale":false,"ageSeconds":1,"session":2,"weekly":3,"sonnet":null,"fable":null}"#
        let decoded = try JSONDecoder().decode(BrokerOracleBlock.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.sessionResetAt)
        XCTAssertNil(decoded.weeklyResetAt)
        XCTAssertNil(decoded.sonnetResetAt)
        XCTAssertNil(decoded.fableResetAt)
        XCTAssertEqual(decoded.chatGPTRows, [])
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
            BrokerInvocation.t3Dispatch(model: "claude-fable-5", instanceId: "claude_secondary")
        )

        XCTAssertEqual(Set(json.keys), ["kind", "command", "model", "instanceId"])
        XCTAssertEqual(json["kind"] as? String, "t3-dispatch")
        XCTAssertEqual(json["command"] as? String, "/t3-dispatch")
        XCTAssertEqual(json["model"] as? String, "claude-fable-5")
        XCTAssertEqual(json["instanceId"] as? String, "claude_secondary")
    }

    func test_invocationRoundTrips_forEveryVariant() throws {
        let variants: [BrokerInvocation] = [
            .agent(model: "opus"),
            .codexExec(model: "gpt-5.6-sol"),
            .t3Dispatch(model: "claude-fable-5", instanceId: "claudeAgent"),
            .agent(model: "opus", effort: .low),
            .codexExec(model: "gpt-5.6-sol", effort: .xhigh),
            .t3Dispatch(model: "claude-fable-5", instanceId: "claudeAgent", effort: .medium),
        ]
        for variant in variants {
            let data = try BrokerDecision.makeEncoder().encode(variant)
            let decoded = try JSONDecoder().decode(BrokerInvocation.self, from: data)
            XCTAssertEqual(decoded, variant)
        }
    }

    func test_invocationWithAnEffort_encodesItAlongsideTheExistingKeys() throws {
        let agent = try encodeToObject(BrokerInvocation.agent(model: "fable", effort: .high))
        XCTAssertEqual(Set(agent.keys), ["kind", "model", "effort"])
        XCTAssertEqual(agent["effort"] as? String, "high")

        let codex = try encodeToObject(BrokerInvocation.codexExec(model: "gpt-5.6-sol", effort: .xhigh))
        XCTAssertEqual(Set(codex.keys), ["kind", "command", "model", "effort"])
        XCTAssertEqual(codex["effort"] as? String, "xhigh")

        let t3 = try encodeToObject(
            BrokerInvocation.t3Dispatch(model: "claude-fable-5", instanceId: "claude_secondary", effort: .low)
        )
        XCTAssertEqual(Set(t3.keys), ["kind", "command", "model", "instanceId", "effort"])
        XCTAssertEqual(t3["effort"] as? String, "low")
    }

    func test_invocationWithoutAnEffort_omitsTheKeyForEveryVariant() throws {
        for variant in [
            BrokerInvocation.agent(model: "fable"),
            .codexExec(model: "gpt-5.6-sol"),
            .t3Dispatch(model: "claude-fable-5", instanceId: "claude_secondary"),
        ] {
            let json = try encodeToObject(variant)
            XCTAssertFalse(json.keys.contains("effort"), "\(variant.kind) encoded an absent effort")
            XCTAssertNil(variant.effort)
        }
    }

    // MARK: - Effort levels

    func test_effort_hasExactlyTheFourLevelsAndNoNoneCase() {
        XCTAssertEqual(BrokerEffort.allCases, [.low, .medium, .high, .xhigh])
        XCTAssertEqual(BrokerEffort.allCases.map(\.rawValue), ["low", "medium", "high", "xhigh"])
        XCTAssertNil(
            BrokerEffort(rawValue: "none"),
            "absence is expressed by a nil effort, never by a 'none' level"
        )
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
        let candidate = try XCTUnwrap(BrokerCandidate(id: "t3:claude_secondary:extra/claude-fable-5"))

        XCTAssertEqual(candidate.route, .t3)
        XCTAssertEqual(candidate.instance, "claude_secondary:extra")
        XCTAssertEqual(candidate.model, "claude-fable-5")
        XCTAssertEqual(candidate.id, "t3:claude_secondary:extra/claude-fable-5")
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
            route: .native, instance: "claude_secondary", model: "claude-sonnet-5"
        )

        XCTAssertNil(switched.instance)
        XCTAssertEqual(switched.id, "native/claude-sonnet-5")

        let codexCandidate = BrokerCandidate(
            route: .codex, instance: "claude_secondary", model: "gpt-5.6-sol"
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

    // MARK: - Candidate effort encoding

    func test_legacyBareStringCandidate_decodesWithNoEffort() throws {
        let decoded = try JSONDecoder().decode(
            [BrokerCandidate].self, from: Data(#"["native/claude-fable-5"]"#.utf8)
        )

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, "native/claude-fable-5")
        XCTAssertNil(decoded[0].effort)
    }

    func test_keyedCandidateForm_decodesTheEffortAndKeepsItOutOfTheId() throws {
        let json = #"[{ "id": "t3:claude_secondary/claude-fable-5", "effort": "xhigh" }]"#
        let decoded = try JSONDecoder().decode([BrokerCandidate].self, from: Data(json.utf8))

        XCTAssertEqual(decoded[0].id, "t3:claude_secondary/claude-fable-5")
        XCTAssertEqual(decoded[0].route, .t3)
        XCTAssertEqual(decoded[0].instance, "claude_secondary")
        XCTAssertEqual(decoded[0].effort, .xhigh)
    }

    func test_keyedCandidateFormWithoutAnEffortKey_decodesWithNoEffort() throws {
        let json = #"[{ "id": "codex/gpt-5.6-sol" }]"#
        let decoded = try JSONDecoder().decode([BrokerCandidate].self, from: Data(json.utf8))

        XCTAssertEqual(decoded[0].id, "codex/gpt-5.6-sol")
        XCTAssertNil(decoded[0].effort)
    }

    func test_unknownEffortString_failsDecodeLoudly() {
        // Same posture as an unknown route: a silently dropped level would
        // route work at the wrong effort forever.
        let json = #"[{ "id": "native/claude-fable-5", "effort": "ultra" }]"#
        XCTAssertThrowsError(
            try JSONDecoder().decode([BrokerCandidate].self, from: Data(json.utf8))
        )
    }

    func test_keyedCandidateFormWithAMalformedId_failsDecodeLoudly() {
        let json = #"[{ "id": "llmproxy/claude-fable-5", "effort": "high" }]"#
        XCTAssertThrowsError(
            try JSONDecoder().decode([BrokerCandidate].self, from: Data(json.utf8))
        )
    }

    func test_candidateWithoutAnEffort_encodesAsTheBareIdString() throws {
        let data = try BrokerDecision.makeEncoder().encode(
            [BrokerCandidate(route: .native, model: "claude-fable-5")]
        )

        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["native/claude-fable-5"]"#)
    }

    func test_candidateWithAnEffort_encodesTheKeyedForm() throws {
        let data = try BrokerDecision.makeEncoder().encode(
            [BrokerCandidate(route: .native, model: "claude-opus-5", effort: .high)]
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )

        XCTAssertEqual(Set(json[0].keys), ["id", "effort"])
        XCTAssertEqual(json[0]["id"] as? String, "native/claude-opus-5")
        XCTAssertEqual(json[0]["effort"] as? String, "high")
    }

    func test_chainMixingBothCandidateForms_decodes() throws {
        let json = """
        [
            "native/claude-fable-5",
            { "id": "t3/claude-fable-5", "effort": "medium" },
            "codex/gpt-5.6-sol"
        ]
        """
        let decoded = try JSONDecoder().decode([BrokerCandidate].self, from: Data(json.utf8))

        XCTAssertEqual(decoded.map(\.id), [
            "native/claude-fable-5", "t3/claude-fable-5", "codex/gpt-5.6-sol",
        ])
        XCTAssertEqual(decoded.map(\.effort), [nil, .medium, nil])
    }

    func test_policyCarryingEfforts_roundTripsThroughJSONUnchanged() throws {
        var policy = BrokerPolicy.default
        policy.roles["planning"] = [
            BrokerCandidate(route: .native, model: "claude-fable-5", effort: .xhigh),
            BrokerCandidate(route: .t3, instance: "claude_secondary", model: "claude-fable-5"),
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol", effort: .low),
        ]

        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(BrokerPolicy.self, from: data)

        XCTAssertEqual(decoded, policy)
        XCTAssertEqual(decoded.roles["planning"]?.map(\.effort), [.xhigh, nil, .low])
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
        XCTAssertTrue(policy.t3Instances.contains { $0.id == "claude_secondary" })
        XCTAssertTrue(
            policy.t3Instances.allSatisfy { $0.boundAccountId == nil },
            "a shipped seed must not assume this machine's account ids"
        )
        // The seed's efforts are the research-backed matrix, not a blanket
        // default: Fable and Haiku candidates stay unset by design.
        XCTAssertEqual(policy.roles["planning"]?.map(\.effort), [nil, nil, nil, .xhigh, .xhigh])
        XCTAssertEqual(policy.roles["execution"]?.map(\.effort), [.high, .high, .high, nil])
        XCTAssertEqual(policy.roles["heavy"]?.map(\.effort), [.xhigh, .high])
        XCTAssertEqual(policy.roles["standard"]?.map(\.effort), [.high, nil])
    }

    func test_resolvedInstance_prefersTheInlineQualifierThenTheModelMapThenTheDefault() throws {
        let policy = BrokerPolicy.default

        let inline = try XCTUnwrap(BrokerCandidate(id: "t3:claude_secondary/claude-fable-5"))
        XCTAssertEqual(policy.resolvedInstance(for: inline), "claude_secondary")

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
        expected.t3.ignoredInstances.append("spare")

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
        model: "t3:claude_secondary/claude-fable-5",
        route: .t3,
        agentModel: "fable",
        invocation: .t3Dispatch(
            model: "claude-fable-5", instanceId: "claude_secondary", effort: .high
        ),
        reason: "no candidate had headroom; forcing top choice (degraded)",
        source: .forcedDegraded,
        oracle: BrokerOracleBlock(
            present: true,
            stale: false,
            ageSeconds: 42,
            session: 12.5,
            weekly: 61.5,
            sonnet: 3,
            fable: 7.25,
            sessionResetAt: Date(timeIntervalSince1970: 1_700_100_000),
            weeklyResetAt: Date(timeIntervalSince1970: 1_700_200_000),
            sonnetResetAt: Date(timeIntervalSince1970: 1_700_300_000),
            fableResetAt: Date(timeIntervalSince1970: 1_700_400_000),
            chatGPTRows: [
                OracleSnapshot.ChatGPTRow(
                    label: "Codex weekly",
                    usedPercent: 55,
                    resetAt: Date(timeIntervalSince1970: 1_700_500_000),
                    windowRole: .chatGPTWeekly
                )
            ]
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
        ],
        effort: .high,
        decisionID: "decision-123"
    )

    /// The same decision shape with no effort recommendation, pinning the
    /// pre-effort key set.
    private static let effortlessDecision = BrokerDecision(
        role: "planning",
        caller: "claude-code",
        model: "native/claude-fable-5",
        route: .native,
        agentModel: "fable",
        invocation: .agent(model: "fable"),
        reason: "native weekly 20% < 85% ok; session 10% ok",
        source: .policy,
        oracle: .absent,
        degraded: false,
        candidatesTried: [
            BrokerCandidateTried(
                candidate: "native/claude-fable-5",
                available: true,
                why: "native weekly 20% < 85% ok; session 10% ok"
            )
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
