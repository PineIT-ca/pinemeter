//
//  GoldenPolicyFixtureTests.swift
//  PinemeterTests
//
//  Generates the ENGINE-03 half of the golden corpus: the `BrokerPolicy`
//  decode truth table (per-key fallbacks, both candidate encodings,
//  normalisation and rejection rules) and the one-time routing migrations.
//
//  Swift writes, Go replays. Every expectation in here is asserted against
//  the real decoder first and only then written to disk, so a fixture can
//  never record a behaviour that Swift does not actually have. Where the
//  observed behaviour differed from the phase research table, the case name
//  and a comment say so — the file records what the code does, not what the
//  table claimed.
//
//  Recording is opt-in (`GoldenFixture.exportDirectory()`); an ordinary
//  `xcodebuild test` runs every assertion and writes nothing.
//

import Foundation
import XCTest
@testable import Pinemeter

final class GoldenPolicyFixtureTests: XCTestCase {

    // MARK: - Export plumbing

    /// `golden/policy/decode`, or nil outside an export run.
    private var decodeOutput: URL? {
        guard GoldenFixture.exportDirectory() != nil else { return nil }
        return GoldenFixture.policyDirectory.appendingPathComponent("decode")
    }

    /// `golden/policy/migrations`, or nil outside an export run.
    private var migrationsOutput: URL? {
        guard GoldenFixture.exportDirectory() != nil else { return nil }
        return GoldenFixture.policyDirectory.appendingPathComponent("migrations")
    }

    /// Wiped once per process, lazily, so a deleted case disappears from the
    /// corpus instead of lingering as an orphan. Scoped to the one directory
    /// this class owns — see `golden/README.md` § Ownership.
    private static let decodeDirectoryWiped: Bool = {
        guard GoldenFixture.exportDirectory() != nil else { return false }
        let directory = GoldenFixture.policyDirectory.appendingPathComponent("decode")
        do { try GoldenFixture.wipe(directory) } catch {
            fatalError("could not wipe \(directory.path): \(error)")
        }
        return true
    }()

    private static let migrationsDirectoryWiped: Bool = {
        guard GoldenFixture.exportDirectory() != nil else { return false }
        let directory = GoldenFixture.policyDirectory.appendingPathComponent("migrations")
        do { try GoldenFixture.wipe(directory) } catch {
            fatalError("could not wipe \(directory.path): \(error)")
        }
        return true
    }()

    // MARK: - Decode cases

    struct DecodeCase {
        let name: String
        let input: String
        let expectsRejection: Bool

        init(_ name: String, _ input: String, expectsRejection: Bool = false) {
            self.name = name
            self.input = input
            self.expectsRejection = expectsRejection
        }
    }

    /// 70 scalars — past the 60-scalar cap `BrokerModelSpec` applies to a
    /// model quota label.
    private static let longLabel = String(repeating: "ab", count: 35)
    /// 45 scalars — past the 40-scalar cap `BrokerEffortCapability` applies.
    private static let longEffortLabel = "012345678901234567890123456789012345678901234"

    private static var decodeCases: [DecodeCase] {
        var cases: [DecodeCase] = []

        // --- Tracer: every top-level key absent resolves to the bundled seed.
        cases.append(DecodeCase("bundled-default", "{}"))

        // --- Every top-level key present, with rich content.
        cases.append(DecodeCase("full-roundtrip", """
        {
          "roles": {
            "planning": ["auto/claude-opus-5", {"id": "t3:codex/gpt-5.6-sol", "effort": "high"}],
            "review": [{"id": "auto/claude-fable-5-1", "effort": "xhigh"}, "t3:*/claude-sonnet-5"],
            "execution": ["native/claude-sonnet-5", "codex/gpt-5.6-sol", "t3/gpt-5.6-terra"]
          },
          "thresholds": {
            "session_pct": 75,
            "weekly_pct": 60,
            "sonnet_weekly_pct": 55,
            "fable_weekly_pct": 45,
            "chatgpt_weekly_pct": 70,
            "staleness_seconds": 900,
            "prefer_expiring_quota": false
          },
          "callers": {
            "claude-code": {
              "routes": ["native", "t3", "codex"],
              "deny_candidates": ["codex/gpt-5.6-sol"],
              "deny_instances": ["luna"]
            },
            "codex": {"routes": ["codex", "t3"]}
          },
          "t3": {
            "instance_by_model": {"gpt-5.6-sol": "codex", "claude-sonnet-5": "claudeAgent"},
            "default_instance": "claudeAgent",
            "ignored_instances": ["retired"]
          },
          "t3_instances": [
            {
              "id": "claudeAgent",
              "name": "Claude Agent",
              "origin": "detected",
              "driver": "claudeAgent",
              "detected_models": ["claude-sonnet-5", "claude-opus-5"],
              "last_seen_at": "2026-09-18T12:00:00Z"
            },
            {
              "id": "codex",
              "name": "Codex",
              "base_url_override": "http://127.0.0.1:4311/v1",
              "bound_account_id": "acct-7",
              "origin": "manual"
            }
          ],
          "usage_lanes": {
            "t3/claude-fable-5-1": {
              "provider": "claude_account",
              "account_id": "acct-7",
              "label_contains": "fable pool",
              "is_primary": true
            },
            "codex/gpt-5.6-sol": {"provider": "chatgpt", "label_contains": "codex weekly"}
          },
          "models": {
            "claude-opus-5": {
              "quota": {"provider": "claude_account", "label_contains": "primary", "is_primary": true},
              "effort": {"levels": ["low", "medium", "high", "xhigh"], "default_label": "Adaptive"}
            },
            "gpt-5.6-sol": {
              "quota": {"provider": "chatgpt", "label_contains": "codex weekly"},
              "effort": {"levels": ["medium", "high"], "default_label": "Provider default"}
            }
          },
          "agent_model_aliases": {"claude-opus-5": "opus", "claude-sonnet-5": "sonnet"},
          "allow_forced_degraded": {"planning": false, "execution": true}
        }
        """))

        // --- The two candidate encodings must collapse to the same bytes.
        cases.append(DecodeCase("candidates-bare", """
        {
          "roles": {
            "execution": ["native/claude-sonnet-5", "t3:codex/gpt-5.6-sol", "auto/claude-opus-5"]
          }
        }
        """))
        cases.append(DecodeCase("candidates-object", """
        {
          "roles": {
            "execution": [
              {"id": "native/claude-sonnet-5"},
              {"id": "t3:codex/gpt-5.6-sol"},
              {"id": "auto/claude-opus-5"}
            ]
          }
        }
        """))

        // --- Per-key fallbacks inside a present container.
        cases.append(DecodeCase("thresholds-partial", """
        {"thresholds": {"weekly_pct": 42}}
        """))
        cases.append(DecodeCase("callers-partial", """
        {"callers": {"claude-code": {"routes": ["native"]}}}
        """))
        cases.append(DecodeCase("t3-partial", """
        {"t3": {"default_instance": "codex"}}
        """))

        // --- The one lenient enum in the tree.
        cases.append(DecodeCase("instance-origin-unknown", """
        {"t3_instances": [{"id": "future", "name": "Future", "origin": "someday"}]}
        """))
        cases.append(DecodeCase("instance-empty-detected-models", """
        {"t3_instances": [{"id": "empty", "name": "Empty", "detected_models": []}]}
        """))

        // --- Normalisation on decode.
        cases.append(DecodeCase("models-effort-normalisation", """
        {
          "models": {
            "dupe-levels": {
              "effort": {
                "levels": ["low", "low", "high", "high", "medium"],
                "default_label": "\(longEffortLabel)"
              }
            },
            "empty-label": {"effort": {"levels": ["medium"], "default_label": ""}},
            "blank-label": {"effort": {"levels": ["xhigh"], "default_label": "     "}}
          }
        }
        """))
        // Records an asymmetry the research table did not: the 60-scalar cap
        // lives in `BrokerModelSpec`, so a `models[].quota` label is trimmed
        // while the same label in a top-level `usage_lanes` row is not.
        cases.append(DecodeCase("lane-label-sanitised", """
        {
          "usage_lanes": {
            "t3/labelled": {"provider": "chatgpt", "label_contains": "\(longLabel)"}
          },
          "models": {
            "labelled": {"quota": {"provider": "chatgpt", "label_contains": "\(longLabel)"}}
          }
        }
        """))
        cases.append(DecodeCase("allow-forced-degraded-false", """
        {"allow_forced_degraded": {"planning": false}}
        """))

        // --- Rejections. Each is asserted to throw before it is recorded.
        cases.append(DecodeCase("thresholds-type-mismatch", """
        {"thresholds": {"session_pct": "90"}}
        """, expectsRejection: true))
        cases.append(DecodeCase("unknown-lane-provider", """
        {"usage_lanes": {"t3/x": {"provider": "gemini_account"}}}
        """, expectsRejection: true))
        cases.append(DecodeCase("effort-none", """
        {"roles": {"execution": [{"id": "native/claude-sonnet-5", "effort": "none"}]}}
        """, expectsRejection: true))
        cases.append(DecodeCase("effort-bad-charset", """
        {"roles": {"execution": [{"id": "native/claude-sonnet-5", "effort": "Medium"}]}}
        """, expectsRejection: true))
        cases.append(DecodeCase("route-unknown", """
        {"roles": {"execution": ["zzz/gpt-5.6-sol"]}}
        """, expectsRejection: true))
        cases.append(DecodeCase("candidate-malformed-id", """
        {"roles": {"execution": ["native"]}}
        """, expectsRejection: true))
        cases.append(DecodeCase("claude-account-quota-with-account-id", """
        {
          "models": {
            "bound": {"quota": {"provider": "claude_account", "account_id": "acct-7"}}
          }
        }
        """, expectsRejection: true))

        // 65 model keys — one past `BrokerModelSpec.hasValidKeys`'s 64 cap.
        let tooMany = (0..<65)
            .map { String(format: "    \"model-%02d\": {}", $0) }
            .joined(separator: ",\n")
        cases.append(DecodeCase("models-too-many", """
        {
          "models": {
        \(tooMany)
          }
        }
        """, expectsRejection: true))

        // 129 scalars — one past the per-key 128-scalar cap.
        cases.append(DecodeCase("models-bad-key", """
        {"models": {"\(String(repeating: "a", count: 129))": {}}}
        """, expectsRejection: true))

        return cases
    }

    // MARK: - Decode fixtures

    func test_exportsPolicyDecodeFixtures() throws {
        let output = decodeOutput
        if output != nil { XCTAssertTrue(Self.decodeDirectoryWiped) }

        var canonicalByName: [String: Data] = [:]
        var rejected: [String] = []

        for testCase in Self.decodeCases {
            let inputData = Data(testCase.input.utf8)

            if testCase.expectsRejection {
                XCTAssertThrowsError(
                    try GoldenFixture.decoder().decode(BrokerPolicy.self, from: inputData),
                    "case '\(testCase.name)' is recorded as rejected but Swift accepted it; "
                        + "reclassify it as an accepted case and record what it actually decodes to"
                )
                rejected.append(testCase.name)
                if let output {
                    try GoldenFixture.write(
                        inputData, to: output, named: "\(testCase.name).input.json"
                    )
                    try GoldenFixture.write(
                        Data(), to: output, named: "\(testCase.name).rejected"
                    )
                }
                continue
            }

            let policy = try GoldenFixture.decoder().decode(BrokerPolicy.self, from: inputData)
            let canonical = try GoldenFixture.canonicalPolicyBytes(policy)

            // Canonical form must be a fixed point: the Go port re-encodes
            // what it decoded, and a form that drifts on the second pass is
            // not a contract.
            let reDecoded = try GoldenFixture.decoder().decode(BrokerPolicy.self, from: canonical)
            XCTAssertEqual(
                try GoldenFixture.canonicalPolicyBytes(reDecoded), canonical,
                "canonical form of '\(testCase.name)' is not idempotent"
            )

            canonicalByName[testCase.name] = canonical
            if let output {
                try GoldenFixture.write(
                    inputData, to: output, named: "\(testCase.name).input.json"
                )
                try GoldenFixture.write(
                    canonical, to: output, named: "\(testCase.name).policy.json"
                )
            }
        }

        // The ENGINE-03 anchor: `{}` IS the bundled seed, so the Go bundled
        // policy is checked against this one file rather than against a
        // hand-transcribed copy of `bundledDefault`.
        XCTAssertEqual(
            canonicalByName["bundled-default"],
            try GoldenFixture.canonicalPolicyBytes(BrokerPolicy.default),
            "decoding {} must produce exactly BrokerPolicy.default"
        )

        XCTAssertEqual(
            canonicalByName["candidates-bare"], canonicalByName["candidates-object"],
            "the bare-string and {id,effort} candidate encodings must collapse to one form"
        )

        XCTAssertGreaterThanOrEqual(Self.decodeCases.count, 18)
        XCTAssertGreaterThanOrEqual(rejected.count, 6)
    }

    /// Spot-checks the normalisation the fixtures record, so a behaviour
    /// change fails with a readable message rather than as a corpus diff.
    func test_decodeNormalisationRules() throws {
        let normalised = try GoldenFixture.decoder().decode(
            BrokerPolicy.self,
            from: Data(
                Self.decodeCases.first { $0.name == "models-effort-normalisation" }!.input.utf8
            )
        )
        XCTAssertEqual(
            normalised.models["dupe-levels"]?.effort?.levels.map(\.rawValue),
            ["low", "high", "medium"], "duplicate levels are dropped, order preserved"
        )
        XCTAssertEqual(
            normalised.models["dupe-levels"]?.effort?.nilLabel.unicodeScalars.count, 40
        )
        XCTAssertEqual(normalised.models["empty-label"]?.effort?.nilLabel, "Provider default")
        XCTAssertEqual(normalised.models["blank-label"]?.effort?.nilLabel, "Provider default")

        let labelled = try GoldenFixture.decoder().decode(
            BrokerPolicy.self,
            from: Data(Self.decodeCases.first { $0.name == "lane-label-sanitised" }!.input.utf8)
        )
        guard case .chatGPT(let modelLabel) = labelled.models["labelled"]?.quota else {
            return XCTFail("expected a chatgpt model quota")
        }
        XCTAssertEqual(modelLabel?.unicodeScalars.count, 60, "model quota labels are capped at 60")
        guard case .chatGPT(let laneLabel) = labelled.usageLanes["t3/labelled"] else {
            return XCTFail("expected a chatgpt usage lane")
        }
        XCTAssertEqual(
            laneLabel?.unicodeScalars.count, 70,
            "top-level usage_lanes labels are NOT sanitised — only models[].quota is"
        )

        let lenient = try GoldenFixture.decoder().decode(
            BrokerPolicy.self,
            from: Data(Self.decodeCases.first { $0.name == "instance-origin-unknown" }!.input.utf8)
        )
        XCTAssertEqual(lenient.t3Instances.first?.origin, .manual)
    }

    // MARK: - Routing migrations

    /// One pre-migration `BrokerSettings` document and what the decode makes
    /// of it. `policyBody` is the same JSON the document's `policy` key
    /// carries, decoded separately as a bare `BrokerPolicy` so "the migration
    /// changed the policy" is a byte comparison, not a judgement call.
    struct MigrationCase {
        let name: String
        let settings: String
        let policyBody: String?
        let expectsPolicyChange: Bool
    }

    private static let migrationIDs = BrokerSettings.knownRoutingMigrations.sorted()

    /// Every known migration id except one, as a JSON array literal. The one
    /// left out is the only migration that can still fire.
    private static func appliedExcept(_ excluded: String) -> String {
        let ids = migrationIDs.filter { $0 != excluded }.map { "\"\($0)\"" }
        return "[\(ids.joined(separator: ", "))]"
    }

    private static func settingsDocument(policy: String, applied: String?) -> String {
        let migrations = applied.map { ",\n  \"applied_routing_migrations\": \($0)" } ?? ""
        return """
        {
          "is_enabled": true,
          "policy": \(policy)\(migrations)
        }
        """
    }

    /// A caller block that already carries the codex self-route, so a case
    /// aimed at one migration is not disturbed by another.
    private static let migratedCodexCaller = """
    {"codex": {"routes": ["codex", "t3"]}}
    """

    private static var migrationCases: [MigrationCase] {
        var cases: [MigrationCase] = []

        func add(
            _ name: String,
            policy: String,
            applied: String?,
            changes: Bool
        ) {
            cases.append(
                MigrationCase(
                    name: name,
                    settings: settingsDocument(policy: policy, applied: applied),
                    policyBody: policy,
                    expectsPolicyChange: changes
                )
            )
        }

        let noOpusPolicy = """
        {"roles":{"review":[{"id":"auto/gpt-6-astra","effort":"medium"},"auto/claude-fable-5-1"]}}
        """
        add("legal-review-no-opus", policy: noOpusPolicy,
            applied: appliedExcept(BrokerSettings.legalReviewMigrationID), changes: true)
        let staleID = "11111111-2222-3333-4444-555555555555"
        cases.append(MigrationCase(
            name: "legal-review-stale-cache",
            settings: """
            {
              "policy": \(noOpusPolicy),
              "active_profile_id": "\(staleID)",
              "active_profile_rules": \(noOpusPolicy),
              "remote_presets": [{"id":"\(staleID)","name":"No Opus","detail":"","symbol_name":"leaf","rules":\(noOpusPolicy)}],
              "applied_routing_migrations": \(appliedExcept(BrokerSettings.legalReviewMigrationID))
            }
            """,
            policyBody: noOpusPolicy, expectsPolicyChange: true))

        // No record at all: the pre-migration shape a long-installed Mac has.
        // Every one of the six must fire and leave a visible mark.
        add("legacy-no-record", policy: """
        {
            "roles": {
              "review": ["native/claude-fable-5", "t3/claude-fable-5", "native/claude-sonnet-5"],
              "standard": ["native/claude-sonnet-5"],
              "heavy": ["native/claude-opus-5"],
              "execution": ["t3/gpt-5.6-sol"]
            },
            "callers": {
              "claude-code": {"routes": ["native", "t3"]},
              "codex": {"routes": ["t3"]}
            }
          }
        """, applied: nil, changes: true)

        // Same, but with no `callers` key: the bundled caller table already
        // carries the codex self-route, so migration 2 is a no-op while 3-6
        // still fire.
        add("legacy-no-callers-key", policy: """
        {
            "roles": {
              "standard": ["native/claude-sonnet-5"],
              "heavy": ["native/claude-opus-5"],
              "execution": ["t3/gpt-5.6-sol"]
            }
          }
        """, applied: nil, changes: true)

        add("missing-review-opus-5", policy: """
        {
            "roles": {
              "review": ["native/claude-fable-5", "t3/claude-fable-5"],
              "execution": ["auto/gpt-5.6-sol"]
            },
            "callers": \(migratedCodexCaller)
          }
        """, applied: appliedExcept(BrokerSettings.reviewOpusMigrationID), changes: true)

        add("missing-codex-self-route", policy: """
        {
            "roles": {"execution": ["auto/gpt-5.6-sol"]},
            "callers": {"codex": {"routes": ["t3"]}}
          }
        """, applied: appliedExcept(BrokerSettings.codexSelfRouteMigrationID), changes: true)

        add("missing-standard-codex-route", policy: """
        {
            "roles": {"standard": ["native/claude-sonnet-5"]},
            "callers": \(migratedCodexCaller)
          }
        """, applied: appliedExcept(BrokerSettings.standardCodexRouteMigrationID), changes: true)

        add("missing-new-roles", policy: """
        {
            "roles": {"execution": ["auto/gpt-5.6-sol"]},
            "callers": \(migratedCodexCaller)
          }
        """, applied: appliedExcept(BrokerSettings.newRolesMigrationID), changes: true)

        // Same as "missing-new-roles", but the saved `agent_model_aliases`
        // and `models` maps already carry every bundled entry EXCEPT the
        // model the new-roles migration is about to inject
        // (`claude-sonnet-5-5`, via the shipped explore/verification
        // chains) — the shape of a save written before that model shipped.
        // Exercises the alias/spec backfill (#134): decode must restore both
        // entries because the migrated policy's own chains now name the
        // model, exactly as `BrokerSettings.backfillDefinitions(for:)` does.
        var staleAliases = BrokerPolicy.bundledDefault.agentModelAliases
        staleAliases.removeValue(forKey: "claude-sonnet-5-5")
        var staleModels = BrokerPolicy.bundledDefault.models
        staleModels.removeValue(forKey: "claude-sonnet-5-5")
        let staleAliasesJSON = String(
            data: try! GoldenFixture.policyEncoder().encode(staleAliases), encoding: .utf8
        )!
        let staleModelsJSON = String(
            data: try! GoldenFixture.policyEncoder().encode(staleModels), encoding: .utf8
        )!
        add("missing-new-roles-stale-model-map", policy: """
        {
            "roles": {"execution": ["auto/gpt-5.6-sol"]},
            "callers": \(migratedCodexCaller),
            "agent_model_aliases": \(staleAliasesJSON),
            "models": \(staleModelsJSON)
          }
        """, applied: appliedExcept(BrokerSettings.newRolesMigrationID), changes: true)

        add("missing-automatic-model-routing", policy: """
        {
            "roles": {
              "execution": [
                "native/claude-sonnet-5",
                "t3/claude-sonnet-5",
                "codex/gpt-5.6-sol"
              ]
            },
            "callers": \(migratedCodexCaller)
          }
        """, applied: appliedExcept(BrokerSettings.automaticModelRoutingMigrationID), changes: true)

        add("missing-heavy-codex-route", policy: """
        {
            "roles": {"heavy": ["native/claude-opus-5"]},
            "callers": \(migratedCodexCaller)
          }
        """, applied: appliedExcept(BrokerSettings.heavyCodexRouteMigrationID), changes: true)

        // All six recorded: decode must be a pure no-op on the policy.
        add("fully-migrated-noop", policy: """
        {
            "roles": {
              "review": ["auto/claude-opus-5"],
              "standard": ["auto/claude-sonnet-5", "auto/gpt-5.6-sol"],
              "heavy": ["auto/claude-opus-5", "auto/gpt-5.6-sol"],
              "explore": ["auto/claude-haiku-4-5-20251001"],
              "verification": ["auto/claude-haiku-4-5-20251001"]
            },
            "callers": \(migratedCodexCaller)
          }
        """, applied: "[\(migrationIDs.map { "\"\($0)\"" }.joined(separator: ", "))]", changes: false)

        // A deleted role stays deleted: migration 1 rewrites, never creates.
        add("review-role-deleted", policy: """
        {
            "roles": {"execution": ["auto/gpt-5.6-sol"]},
            "callers": \(migratedCodexCaller)
          }
        """, applied: appliedExcept(BrokerSettings.reviewOpusMigrationID), changes: false)

        // No `policy` key at all. Recorded rather than assumed — Plan 07
        // mirrors whatever this turns out to be.
        cases.append(
            MigrationCase(
                name: "settings-policy-absent",
                settings: """
                {
                  "is_enabled": true
                }
                """,
                policyBody: nil,
                expectsPolicyChange: false
            )
        )

        return cases
    }

    func test_exportsRoutingMigrationFixtures() throws {
        let output = migrationsOutput
        if output != nil { XCTAssertTrue(Self.migrationsDirectoryWiped) }

        let appliedEncoder = JSONEncoder()
        appliedEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        for testCase in Self.migrationCases {
            let settingsData = Data(testCase.settings.utf8)
            let settings = try GoldenFixture.decoder()
                .decode(BrokerSettings.self, from: settingsData)

            // The union rule: whatever was recorded before, all six known ids
            // are recorded after. Go must write the same set back.
            XCTAssertEqual(
                settings.appliedRoutingMigrations, BrokerSettings.knownRoutingMigrations,
                "case '\(testCase.name)' must end with every known migration recorded"
            )

            if testCase.name == "legal-review-stale-cache" {
                XCTAssertFalse(settings.activeProfileHasUpdatedRules)
                var reapplied = settings
                reapplied.applyProfile(id: try XCTUnwrap(settings.activeProfileID))
                XCTAssertEqual(reapplied.policy.roles["legal-review"], settings.policy.roles["legal-review"])
            }

            let canonical = try GoldenFixture.canonicalPolicyBytes(settings.policy)

            if let body = testCase.policyBody {
                let inputPolicy = try GoldenFixture.decoder()
                    .decode(BrokerPolicy.self, from: Data(body.utf8))
                let inputCanonical = try GoldenFixture.canonicalPolicyBytes(inputPolicy)
                if testCase.expectsPolicyChange {
                    XCTAssertNotEqual(
                        canonical, inputCanonical,
                        "case '\(testCase.name)' names a migration that had no visible effect"
                    )
                } else {
                    XCTAssertEqual(
                        canonical, inputCanonical,
                        "case '\(testCase.name)' must decode to its input policy unchanged"
                    )
                }
            }

            if testCase.name == "review-role-deleted" {
                XCTAssertNil(
                    settings.policy.roles["review"],
                    "the review migration rewrites a chain, it never resurrects a deleted role"
                )
            }

            guard let output else { continue }
            try GoldenFixture.write(
                settingsData, to: output, named: "\(testCase.name).settings.json"
            )
            try GoldenFixture.write(canonical, to: output, named: "\(testCase.name).policy.json")
            try GoldenFixture.write(
                try appliedEncoder.encode(settings.appliedRoutingMigrations.sorted()),
                to: output,
                named: "\(testCase.name).applied.json"
            )
        }

        XCTAssertGreaterThanOrEqual(Self.migrationCases.count, 10)
    }

    /// The six migrations, each checked for the specific effect its fixture
    /// records, so a regression names the migration rather than the bytes.
    func test_routingMigrationEffects() throws {
        func decode(_ name: String) throws -> BrokerSettings {
            let testCase = Self.migrationCases.first { $0.name == name }!
            return try GoldenFixture.decoder()
                .decode(BrokerSettings.self, from: Data(testCase.settings.utf8))
        }

        let legacy = try decode("legacy-no-record")
        XCTAssertEqual(
            legacy.policy.roles["review"]?.map(\.id),
            BrokerPolicy.bundledDefault.roles["review"]?.map(\.id)
        )
        XCTAssertEqual(legacy.policy.callers["codex"]?.routes.first, .codex)
        XCTAssertEqual(
            legacy.policy.roles["standard"]?.map(\.id),
            ["auto/claude-sonnet-5", "auto/gpt-6.1-sol"]
        )
        XCTAssertEqual(
            legacy.policy.roles["heavy"]?.map(\.id),
            ["auto/claude-opus-5", "auto/gpt-6.1-sol"]
        )
        XCTAssertNotNil(legacy.policy.roles["explore"])
        XCTAssertNotNil(legacy.policy.roles["verification"])
        XCTAssertEqual(legacy.policy.roles["execution"]?.map(\.id), ["auto/gpt-5.6-sol"])

        XCTAssertEqual(
            try decode("missing-codex-self-route").policy.callers["codex"]?.routes,
            [.codex, .t3]
        )
        XCTAssertEqual(
            try decode("missing-automatic-model-routing").policy.roles["execution"]?.map(\.id),
            ["auto/claude-sonnet-5", "auto/gpt-5.6-sol"]
        )
        XCTAssertEqual(
            try decode("missing-heavy-codex-route").policy.roles["heavy"]?.last?.effort, .high
        )
        XCTAssertEqual(
            try decode("missing-standard-codex-route").policy.roles["standard"]?.last?.effort,
            .medium
        )

        // The stale-map case (#134): the migrated policy's own chains now
        // name the model, so backfill must restore both its shipped alias
        // and its shipped spec even though the saved maps omitted it.
        let staleMapPolicy = try decode("missing-new-roles-stale-model-map").policy
        // Guard the fixture's own premise first, so a shipped catalog that
        // stopped defining this model would fail loud here instead of making
        // both equality checks below a vacuous nil == nil.
        XCTAssertNotNil(BrokerPolicy.bundledDefault.agentModelAliases["claude-sonnet-5-5"])
        XCTAssertNotNil(BrokerPolicy.bundledDefault.models["claude-sonnet-5-5"])
        XCTAssertEqual(
            staleMapPolicy.agentModelAliases["claude-sonnet-5-5"],
            BrokerPolicy.bundledDefault.agentModelAliases["claude-sonnet-5-5"]
        )
        XCTAssertEqual(
            staleMapPolicy.models["claude-sonnet-5-5"],
            BrokerPolicy.bundledDefault.models["claude-sonnet-5-5"]
        )

        // Observed, not assumed: an absent `policy` key does not throw — it
        // falls back to `BrokerSettings.default.policy` (the bundled seed),
        // and running all six migrations over that seed changes nothing,
        // because the seed already ships their result. Plan 07 mirrors this.
        XCTAssertEqual(
            try GoldenFixture.canonicalPolicyBytes(try decode("settings-policy-absent").policy),
            try GoldenFixture.canonicalPolicyBytes(BrokerPolicy.default),
            "an absent `policy` key must resolve to the bundled seed, unchanged by migrations"
        )
    }
}
