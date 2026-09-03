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
//  A manifest that lags the compiled built-ins would therefore publish stale
//  routing to every fetching install, which is exactly how a model rename
//  went unnoticed once already. The guard below makes that a test failure,
//  and the generator beside it makes fixing it a one-command job.
//

import XCTest
@testable import Pinemeter

final class BrokerPresetManifestSyncTests: XCTestCase {
    /// Every built-in must be published, with the rules this build ships.
    ///
    /// Compared against the compiled rules rather than against a golden file:
    /// the point is not that the JSON is unchanged, it is that a user who
    /// fetches the manifest gets the same routing a fresh install would.
    func test_bundledManifest_publishesEveryBuiltInWithItsShippedRules() throws {
        let manifest = try loadBundledManifest()

        for builtIn in BrokerAgentProfile.builtIns {
            let published = manifest.presets.first { $0.id == builtIn.id }
            let entry = try XCTUnwrap(
                published,
                "\(builtIn.name) is not published: an install on it cannot be re-routed "
                    + "without an app update. Regenerate broker-presets.json."
            )
            XCTAssertEqual(
                entry.rules, builtIn.rules,
                "\(builtIn.name) publishes rules this build no longer ships. "
                    + "Regenerate broker-presets.json."
            )
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

    /// Rewrites `broker-presets.json` from the compiled built-ins, preserving
    /// every manifest-only preset in the file.
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
        let existingPresets = ((existing as? [String: Any])?["presets"] as? [[String: Any]]) ?? []
        let builtInIDs = Set(BrokerAgentProfile.builtIns.map { $0.id.uuidString.lowercased() })
        let manifestOnly = existingPresets.filter { entry in
            guard let id = entry["id"] as? String else { return false }
            return !builtInIDs.contains(id.lowercased())
        }

        let regenerated: [String: Any] = [
            "schema_version": 1,
            "presets": try BrokerAgentProfile.builtIns.map(entryDictionary) + manifestOnly,
        ]
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
