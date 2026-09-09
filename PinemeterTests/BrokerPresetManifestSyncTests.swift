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
//  Published rules may lead compiled defaults between app releases. Tests
//  require every built-in to remain addressable and validate published rules,
//  rather than forcing remote policy back to the compiled fallback.
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

    /// Stable IDs let existing installations adopt newer published rules.
    /// Rule equality is deliberately not required: remote routing can change
    /// without rebuilding the app's compiled fallback presets.
    func test_bundledManifest_publishesEveryBuiltInWithStableIdentity() throws {
        let manifest = try loadBundledManifest()
        for builtIn in BrokerAgentProfile.builtIns {
            let entry = try XCTUnwrap(
                manifest.presets.first { $0.id == builtIn.id },
                "\(builtIn.name) is missing: existing installations cannot update it."
            )
            XCTAssertEqual(entry.name, builtIn.name)
        }
    }

    func test_astraTrialHasBoundedRolesAndEfforts() throws {
        for preset in try loadBundledManifest().presets {
            let roles = preset.rules.roles
            let astraRoles = Set(roles.filter { $0.value.contains { $0.model == "gpt-6-astra" } }.keys)
            if ["Conserve Quota", "Claude Only"].contains(preset.name) {
                XCTAssertTrue(astraRoles.isEmpty, preset.name)
                XCTAssertNil(preset.rules.models["gpt-6-astra"])
                continue
            }
            XCTAssertEqual(astraRoles, ["heavy", "planning", "review"], preset.name)
            XCTAssertEqual(roles["heavy"]?.first?.model, "gpt-6-astra", preset.name)
            XCTAssertEqual(roles["heavy"]?.first?.effort, .medium)
            for role in ["planning", "review"] {
                let index = preset.name == "Max Quality" && role == "review" ? 0 : 1
                let chain = try XCTUnwrap(roles[role])
                XCTAssertGreaterThan(chain.count, index)
                guard chain.count > index else { continue }
                XCTAssertEqual(chain[index].model, "gpt-6-astra", preset.name + "/" + role)
                XCTAssertEqual(chain[index].effort, .low)
            }
        }
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

    /// Adds missing compiled built-ins to `broker-presets.json`, preserving
    /// all existing published rules, including overrides of built-in presets.
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
        let existingIDs = Set(existingPresets.compactMap { ($0["id"] as? String)?.lowercased() })
        let missingBuiltIns = BrokerAgentProfile.builtIns.filter {
            !existingIDs.contains($0.id.uuidString.lowercased())
        }

        var regenerated: [String: Any] = [
            "schema_version": 1,
            "presets": existingPresets + (try missingBuiltIns.map(entryDictionary)),
        ]
        if let agentSetup = existingObject["agent_setup"] as? [String: Any] {
            regenerated["agent_setup"] = agentSetup
        }
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

    private func loadBundledManifest() throws -> BrokerPresetManifest {
        let url = try XCTUnwrap(
            BrokerPresetManifestTests.bundledManifestURL(),
            "broker-presets.json must ship in the app bundle"
        )
        return try BrokerPresetManifest.decode(from: Data(contentsOf: url))
    }
}
