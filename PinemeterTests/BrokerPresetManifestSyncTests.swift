//
//  BrokerPresetManifestSyncTests.swift
//  PinemeterTests
//
//  The bundled manifest is also the published one: the default manifest URL
//  points at this very file on `main`, so whatever ships here is what an
//  existing install fetches. That makes it the delivery path for a routing
//  change — an install already sitting on a built-in profile learns about new
//  rules from the manifest, not from an app update it may not have taken.
//
//  Published rules and compiled fallbacks are one contract. Keeping them equal
//  prevents a network failure from silently changing a built-in profile.
//

import XCTest
@testable import Pinemeter

final class BrokerPresetManifestSyncTests: XCTestCase {
    func test_bundledManifestCarriesAgentSetupRevision() throws {
        let notice = try XCTUnwrap(loadBundledManifest().agentSetup)

        XCTAssertEqual(notice.revision, 1)
        XCTAssertEqual(notice.changedAt, "2026-09-03")
        XCTAssertFalse(try XCTUnwrap(notice.summary).isEmpty)
    }

    func test_bundledManifest_publishesEveryBuiltInWithStableIdentityAndRules() throws {
        let manifest = try loadBundledManifest()
        for builtIn in BrokerAgentProfile.builtIns {
            let entry = try XCTUnwrap(
                manifest.presets.first { $0.id == builtIn.id },
                "\(builtIn.name) is missing: existing installations cannot update it."
            )
            XCTAssertEqual(entry.name, builtIn.name)
            XCTAssertEqual(entry.rules, builtIn.rules, builtIn.name)
        }
    }

    func test_everyMixedPresetSuppliesClaudeAndCodexForAllNineRoles() throws {
        let expectedRoles = Set(BrokerPolicy.bundledDefault.roles.keys)

        for preset in try loadBundledManifest().presets {
            let roles = preset.rules.roles
            XCTAssertEqual(Set(roles.keys), expectedRoles, preset.name)

            for role in expectedRoles.sorted() {
                let chain = try XCTUnwrap(roles[role], "\(preset.name)/\(role)")
                XCTAssertFalse(chain.isEmpty, "\(preset.name)/\(role)")
                guard preset.name != "Claude Only" else { continue }
                XCTAssertTrue(
                    chain.contains { $0.model.hasPrefix("claude-") },
                    "\(preset.name)/\(role) has no Claude fallback"
                )
                XCTAssertTrue(
                    chain.contains { $0.model.hasPrefix("gpt-") },
                    "\(preset.name)/\(role) has no Codex fallback"
                )
            }
        }
    }

    func test_balancedUsesTheApprovedDesignAndResearchChains() throws {
        let balanced = try XCTUnwrap(
            loadBundledManifest().presets.first { $0.id == BrokerAgentProfile.balancedID }
        )

        XCTAssertEqual(balanced.rules.roles["design"], [
            choice("claude-fable-5-1"),
            choice("gpt-6-astra", .low),
            choice("claude-opus-5-5", .xhigh),
            choice("claude-sonnet-5", .xhigh),
        ])
        XCTAssertEqual(balanced.rules.roles["research"], [
            choice("claude-fable-5-1"),
            choice("claude-opus-5-5", .high),
            choice("gpt-5.6-sol", .high),
            choice("claude-sonnet-5", .high),
        ])
    }

    func test_conserveJudgmentUsesSolWithoutExpandingAstra() throws {
        let conserve = try XCTUnwrap(
            loadBundledManifest().presets.first { $0.id == BrokerAgentProfile.conserveID }
        )

        for role in BrokerAgentProfile.judgmentRoles {
            XCTAssertTrue(
                conserve.rules.roles[role, default: []].contains { $0.model == "gpt-5.6-sol" },
                role
            )
        }
        XCTAssertFalse(conserve.rules.roles.values.joined().contains { $0.model == "gpt-6-astra" })
        XCTAssertNil(conserve.rules.models["gpt-6-astra"])
    }

    /// The published rules must survive the same decode the app applies to
    /// them, so a chain that only exists in the file is caught here rather
    /// than by a user whose routing quietly lost a candidate.
    func test_bundledManifest_publishedBuiltInsCarryAModelForEveryShippedRole() throws {
        let manifest = try loadBundledManifest()

        for builtIn in BrokerAgentProfile.builtIns {
            let entry = try XCTUnwrap(manifest.presets.first { $0.id == builtIn.id })
            for role in builtIn.rules.roles.keys {
                XCTAssertFalse(
                    entry.rules.roles[role]?.isEmpty ?? true,
                    "\(builtIn.name)/\(role) publishes no candidate"
                )
            }
        }
    }

    /// The manifest is how an install already sitting on Max Quality learns
    /// that `review` may now return a confirmable degraded pick instead of
    /// erroring, so the published rule is asserted directly rather than only
    /// through the compiled-vs-published comparison above.
    func test_bundledManifest_maxQualityAllowsForcedDegradedForReviewOnly() throws {
        let manifest = try loadBundledManifest()
        let maxQuality = try XCTUnwrap(
            manifest.presets.first { $0.id == BrokerAgentProfile.maxQualityID }
        )

        XCTAssertEqual(maxQuality.rules.allowForcedDegraded["review"], true)
        for role in ["design", "planning", "research"] {
            XCTAssertEqual(
                maxQuality.rules.allowForcedDegraded[role], false,
                "\(role) still hard-stops rather than downgrading"
            )
        }
    }

    /// Rewrites compiled built-in rules while preserving manifest display
    /// metadata and every manifest-only preset.
    ///
    /// Skipped unless asked for, because a test that writes to the checkout by
    /// default is a test that can hide the very drift the guard above exists
    /// to report. Run it with:
    ///
    /// ```sh
    /// TEST_RUNNER_PINEMETER_WRITE_PRESET_MANIFEST=1 \
    ///   TEST_RUNNER_PINEMETER_PRESET_MANIFEST_PATH=$PWD/Pinemeter/Resources/broker-presets.json \
    ///   xcodebuild test -project Pinemeter.xcodeproj -scheme Pinemeter \
    ///   -only-testing:PinemeterTests/BrokerPresetManifestSyncTests/test_regenerateBundledManifest
    /// ```
    ///
    /// The `TEST_RUNNER_` prefix is what carries a variable from the shell
    /// into the test process; `xcodebuild` drops anything else.
    func test_regenerateBundledManifest() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PINEMETER_WRITE_PRESET_MANIFEST"] == "1" else {
            throw XCTSkip("set PINEMETER_WRITE_PRESET_MANIFEST=1 to rewrite the manifest")
        }
        let path = try XCTUnwrap(
            environment["PINEMETER_PRESET_MANIFEST_PATH"],
            "PINEMETER_PRESET_MANIFEST_PATH must name the file to rewrite"
        )
        let url = URL(fileURLWithPath: path)

        let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let existingObject = (existing as? [String: Any]) ?? [:]
        let existingPresets = (existingObject["presets"] as? [[String: Any]]) ?? []
        let builtInIDs = Set(BrokerAgentProfile.builtIns.map { $0.id.uuidString.lowercased() })
        let compiledBuiltIns = try BrokerAgentProfile.builtIns.map { builtIn in
            let compiled = try entryDictionary(for: builtIn)
            var entry = existingPresets.first {
                ($0["id"] as? String)?.lowercased() == builtIn.id.uuidString.lowercased()
            } ?? compiled
            entry["rules"] = compiled["rules"]
            return entry
        }
        let manifestOnly = existingPresets.filter {
            guard let id = ($0["id"] as? String)?.lowercased() else { return true }
            return !builtInIDs.contains(id)
        }
        var regenerated = existingObject
        regenerated["schema_version"] = 1
        regenerated["presets"] = compiledBuiltIns + manifestOnly
        let data = try JSONSerialization.data(
            withJSONObject: regenerated,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url)
    }

    private func entryDictionary(for profile: BrokerAgentProfile) throws -> [String: Any] {
        let rulesData = try JSONEncoder().encode(profile.rules)
        let rules = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rulesData) as? [String: Any]
        )
        return [
            "id": profile.id.uuidString,
            "name": profile.name,
            "detail": profile.detail,
            "symbol_name": profile.symbolName,
            "rules": rules,
        ]
    }

    private func choice(_ model: String, _ effort: BrokerEffort? = nil) -> BrokerCandidate {
        BrokerCandidate(route: .auto, model: model, effort: effort)
    }

    private func loadBundledManifest() throws -> BrokerPresetManifest {
        let url = try XCTUnwrap(
            BrokerPresetManifestTests.bundledManifestURL(),
            "broker-presets.json must ship in the app bundle"
        )
        return try BrokerPresetManifest.decode(from: Data(contentsOf: url))
    }
}
