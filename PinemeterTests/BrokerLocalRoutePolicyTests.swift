import XCTest
@testable import Pinemeter

final class BrokerLocalRoutePolicyTests: XCTestCase {
    static let validInput = #"{"local_routes":[{"candidate":"t3:pi/lab/qwen-27b","host":"gpu-a","probe_url":"http://gpu-a.example:11434","preset":"qwen-27b","residency":"controlled","enabled":true,"roles":["explore","verification"],"base_effort":"high","quality":{"high":256}}],"residency_roles":{"execution":"controlled"}}"#

    static func declaredPolicy() throws -> BrokerPolicy {
        try GoldenFixture.decoder().decode(BrokerPolicy.self, from: Data(validInput.utf8))
    }

    func test_roundTrip() throws {
        let policy = try Self.declaredPolicy()
        XCTAssertEqual(policy.localRoutes.count, 1)
        XCTAssertEqual(policy.localRoutes[0].residency, .controlled)
        XCTAssertEqual(policy.residencyRoles, ["execution": .controlled])
        let encoded = try GoldenFixture.canonicalPolicyBytes(policy)
        XCTAssertEqual(try GoldenFixture.decoder().decode(BrokerPolicy.self, from: encoded), policy)
    }

    func test_ruleSetExcludesDeclarationsAndApplyPreservesThem() throws {
        var policy = try Self.declaredPolicy()
        let original = policy
        let rules = BrokerRuleSet(policy: policy)
        let encoded = try JSONEncoder().encode(rules)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(root["local_routes"])
        XCTAssertNil(root["residency_roles"])
        policy.apply(.default)
        XCTAssertEqual(policy.localRoutes, original.localRoutes)
        XCTAssertEqual(policy.residencyRoles, original.residencyRoles)
        policy.assignExactRules(rules)
        XCTAssertEqual(policy.localRoutes, original.localRoutes)
        XCTAssertEqual(policy.residencyRoles, original.residencyRoles)
    }

    func test_emptyKeysOmitted() throws {
        let policy = try GoldenFixture.decoder().decode(BrokerPolicy.self, from: Data("{}".utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: GoldenFixture.canonicalPolicyBytes(policy)) as? [String: Any])
        XCTAssertNil(root["local_routes"])
        XCTAssertNil(root["residency_roles"])
    }

    func test_modelSlugValidationKeepsInstanceRules() {
        for slug in ["lab/qwen-27b", "lab/qwen:27b", "a.b-c_d/e", String(repeating: "a", count: 128)] {
            XCTAssertTrue(T3InstanceConfig.isValidModelSlug(slug), slug)
        }
        for slug in ["", "/a", "a/", "a//b", String(repeating: "a", count: 129), "a b", "a\n", "a\u{200B}b", "a\u{034F}b"] {
            XCTAssertFalse(T3InstanceConfig.isValidModelSlug(slug), slug)
        }
        for id in ["a/b", "a:b"] { XCTAssertFalse(T3InstanceConfig.isValidId(id)) }
        XCTAssertEqual(BrokerLocalRoute.allowedRoles, ["explore", "verification", "execution"])
        XCTAssertEqual(BrokerLocalRoute.forbiddenRoles, ["review", "legal-review", "planning", "design", "research", "heavy"])
    }

    func test_routeStringBoundsAndProbeValidation() throws {
        let base = try XCTUnwrap(try Self.declaredPolicy().localRoutes.first)
        for host in ["", "gpu/a", "gpu:a", String(repeating: "h", count: 65)] {
            var route = base; route.host = host
            XCTAssertTrue(BrokerLocalRoute.normalized([route]).isEmpty)
        }
        for preset in ["", "lab/model", String(repeating: "p", count: 129)] {
            var route = base; route.preset = preset
            XCTAssertTrue(BrokerLocalRoute.normalized([route]).isEmpty)
        }
        for url in ["http://:11434", "http://gpu a.example:11434", "http://" + String(repeating: "a", count: 245) + ":11434"] {
            XCTAssertFalse(BrokerLocalRoute.isValidProbeURL(url))
        }
        for url in ["http://127.0.0.1:65535", "https://gpu-a.example:1/"] {
            XCTAssertTrue(BrokerLocalRoute.isValidProbeURL(url))
        }
    }

    private func pairPolicy() throws -> BrokerPolicy {
        var policy = try Self.declaredPolicy()
        var second = try XCTUnwrap(policy.localRoutes.first)
        second.candidate = "t3:pi/lab/model-b"
        second.host = "gpu-b"
        second.probeURL = "http://gpu-b.example:11434"
        policy.localRoutes.append(second)
        return policy
    }

    func test_allBuiltInProfilesAndImportPreserveDeclarations() throws {
        let original = try pairPolicy()
        var settings = BrokerSettings(isEnabled: true, port: 43117, policy: original)
        for profile in BrokerAgentProfile.builtIns {
            settings.applyProfile(id: profile.id)
            XCTAssertEqual(settings.policy.localRoutes, original.localRoutes, profile.name)
            XCTAssertEqual(settings.policy.residencyRoles, original.residencyRoles, profile.name)
        }
        let profile = try BrokerAgentProfile.decodeExported(from: Data(#"{"name":"Imported","rules":{"roles":{"execution":["native/test-model"]}}}"#.utf8))
        let id = settings.importProfile(profile)
        settings.applyProfile(id: id)
        XCTAssertEqual(settings.policy.localRoutes, original.localRoutes)
        XCTAssertEqual(settings.policy.residencyRoles, original.residencyRoles)

        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.exportableProfile(named: "Exported"))) as? [String: Any])
        let rules = try XCTUnwrap(exported["rules"] as? [String: Any])
        XCTAssertNil(exported["local_routes"])
        XCTAssertNil(exported["residency_roles"])
        XCTAssertNil(rules["local_routes"])
        XCTAssertNil(rules["residency_roles"])
    }

    func test_profileAndManifestCannotDeclareResidency() throws {
        let declarations = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.validInput.utf8)) as? [String: Any])
        let cleanRules: [String: Any] = ["default_instance": "pi"]
        var plantedRules = cleanRules
        plantedRules.merge(declarations) { _, new in new }
        let cleanProfile: [String: Any] = ["name": "Imported", "rules": cleanRules]
        let plantedProfile: [String: Any] = ["name": "Imported", "rules": plantedRules]
        let clean = try BrokerAgentProfile.decodeExported(from: JSONSerialization.data(withJSONObject: cleanProfile))
        let planted = try BrokerAgentProfile.decodeExported(from: JSONSerialization.data(withJSONObject: plantedProfile))
        XCTAssertEqual(planted.rules, clean.rules)

        let id = UUID().uuidString
        func manifest(_ rules: [String: Any]) throws -> BrokerPresetManifest {
            try BrokerPresetManifest.decode(from: JSONSerialization.data(withJSONObject: ["schema_version": 1,
                "presets": [["id": id, "name": "Synthetic", "detail": "Test preset.", "symbol_name": "leaf", "rules": rules]]]))
        }
        let cleanManifest = try manifest(cleanRules)
        let plantedManifest = try manifest(plantedRules)
        XCTAssertEqual(plantedManifest.presets.count, 1)
        XCTAssertEqual(plantedManifest.presets.first?.rules, cleanManifest.presets.first?.rules)
        for rules in [planted.rules, try XCTUnwrap(plantedManifest.presets.first).rules] {
            var policy = BrokerPolicy(roles: [:])
            policy.apply(rules)
            XCTAssertTrue(policy.localRoutes.isEmpty)
            XCTAssertTrue(policy.residencyRoles.isEmpty)
        }
    }

    func test_officialPresetJSONCannotDeclareResidency() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Pinemeter/Resources/broker-presets.json"))
        let clean = try BrokerPresetManifest.decode(from: data)
        var planted = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let declarations = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.validInput.utf8)) as? [String: Any])
        var entries = try XCTUnwrap(planted["presets"] as? [[String: Any]])
        for i in entries.indices {
            var rules = try XCTUnwrap(entries[i]["rules"] as? [String: Any])
            rules.merge(declarations) { _, new in new }
            entries[i]["rules"] = rules
        }
        planted["presets"] = entries
        planted.merge(declarations) { _, new in new }
        let decoded = try BrokerPresetManifest.decode(from: JSONSerialization.data(withJSONObject: planted))
        XCTAssertEqual(decoded.presets.map(\.rules), clean.presets.map(\.rules))
        XCTAssertFalse(decoded.presets.isEmpty)
        let original = try pairPolicy()
        for preset in decoded.presets {
            var policy = original
            policy.apply(preset.rules)
            XCTAssertEqual(policy.localRoutes, original.localRoutes)
            XCTAssertEqual(policy.residencyRoles, original.residencyRoles)
            var empty = BrokerPolicy(roles: [:])
            empty.apply(preset.rules)
            XCTAssertTrue(empty.localRoutes.isEmpty)
            XCTAssertTrue(empty.residencyRoles.isEmpty)
        }
    }

    func test_discoveryReconcilePreservesDeclarationsAndCannotCreateThem() throws {
        let original = try pairPolicy()
        let discovered = [DiscoveredT3Instance(instanceId: "pi", driver: "pi", displayName: "Synthetic",
            installed: true, checkedAt: Date(timeIntervalSince1970: 1_700_000_000), modelSlugs: ["lab/qwen-27b", "default"])]
        var policy = original
        _ = policy.reconcileDiscoveredT3Instances(discovered)
        XCTAssertEqual(policy.localRoutes, original.localRoutes)
        XCTAssertEqual(policy.residencyRoles, original.residencyRoles)
        var empty = BrokerPolicy(roles: [:])
        _ = empty.reconcileDiscoveredT3Instances(discovered)
        XCTAssertTrue(empty.localRoutes.isEmpty)
        XCTAssertTrue(empty.residencyRoles.isEmpty)
    }

    func test_prePhaseSettingsDecodeEmptyDeclarations() throws {
        let data = Data(#"{"refresh_interval":300,"broker":{"policy":{"thresholds":{"weekly_pct":63,"prefer_expiring_quota":false}}}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.refreshInterval, 300)
        XCTAssertEqual(settings.broker.policy.thresholds.weeklyPct, 63)
        XCTAssertTrue(settings.broker.policy.localRoutes.isEmpty)
        XCTAssertTrue(settings.broker.policy.residencyRoles.isEmpty)
    }

    func test_declarationsPersistThroughSettingsRepository() async throws {
        let suite = "BrokerLocalRoutePolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings.default
        settings.broker.policy = try pairPolicy()
        try await SettingsRepository(userDefaults: defaults).save(settings)
        let data = try XCTUnwrap(defaults.data(forKey: "app_settings"))
        let decoded = try GoldenFixture.decoder().decode(AppSettings.self, from: data)
        let loaded = await SettingsRepository(userDefaults: defaults).load()
        XCTAssertEqual(decoded.broker.policy.localRoutes, settings.broker.policy.localRoutes)
        XCTAssertEqual(decoded.broker.policy.residencyRoles, settings.broker.policy.residencyRoles)
        XCTAssertEqual(loaded.broker.policy.localRoutes, settings.broker.policy.localRoutes)
        XCTAssertEqual(loaded.broker.policy.residencyRoles, settings.broker.policy.residencyRoles)
    }
}
