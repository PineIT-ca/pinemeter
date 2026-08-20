//
//  BrokerPresetManifestTests.swift
//  PinemeterTests
//
//  The remote preset manifest is a trust boundary: its JSON is attacker-
//  reachable (whoever answers for the configured URL controls it), rendered
//  straight into the profile menu, and — on explicit user action — applied
//  to live routing. These tests cover the three layers that boundary is
//  built from: per-entry validation in `BrokerPresetManifest.decode`, the
//  settings-side integration that keeps a manifest refresh from re-routing
//  anything by itself, and the HTTP client's own limits (https-only, size
//  cap, etag handling).
//

import XCTest
@testable import Pinemeter

final class BrokerPresetManifestTests: XCTestCase {
    // MARK: - Fixtures

    /// The smallest JSON object `BrokerAgentProfile.hasRecognizedRules`
    /// accepts: one recognised rule-set key.
    private static let minimalRules: [String: Any] = ["default_instance": "claudeAgent"]

    private func makeEntry(
        id: String = UUID().uuidString,
        name: String = "Extra Preset",
        detail: String = "A preset from the manifest.",
        symbolName: String = "leaf",
        rules: [String: Any]? = minimalRules
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "id": id,
            "name": name,
            "detail": detail,
            "symbol_name": symbolName,
        ]
        if let rules {
            entry["rules"] = rules
        }
        return entry
    }

    private func makeManifestData(
        schemaVersion: Int = 1, presets: [[String: Any]]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema_version": schemaVersion,
            "presets": presets,
        ])
    }

    // MARK: - Decode: acceptance

    func test_decode_validManifestDecodesPresets() throws {
        let id = UUID().uuidString
        let data = try makeManifestData(presets: [
            makeEntry(id: id, name: "Balanced-ish", detail: "A test preset.", symbolName: "leaf"),
        ])

        let manifest = try BrokerPresetManifest.decode(from: data)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.presets.count, 1)
        let preset = try XCTUnwrap(manifest.presets.first)
        XCTAssertEqual(preset.id.uuidString, id)
        XCTAssertEqual(preset.name, "Balanced-ish")
        XCTAssertEqual(preset.detail, "A test preset.")
        XCTAssertEqual(preset.symbolName, "leaf")
        XCTAssertFalse(preset.isBuiltIn, "manifest identity is tracked by BrokerSettings, not this flag")
    }

    // MARK: - Decode: per-entry rejection

    func test_decode_entryWithoutRulesKeySkipped() throws {
        var entry = makeEntry(rules: nil)
        entry["rules"] = ["extends": "eslint:recommended"] // has a `rules`-shaped sibling, but no recognised key
        let data = try makeManifestData(presets: [entry])

        let manifest = try BrokerPresetManifest.decode(from: data)

        XCTAssertTrue(manifest.presets.isEmpty)
    }

    func test_decode_entryWithoutIdSkipped() throws {
        var entry = makeEntry()
        entry.removeValue(forKey: "id")
        let data = try makeManifestData(presets: [entry])

        let manifest = try BrokerPresetManifest.decode(from: data)

        XCTAssertTrue(manifest.presets.isEmpty)
    }

    func test_decode_duplicateIdSkipped() throws {
        let id = UUID().uuidString
        let data = try makeManifestData(presets: [
            makeEntry(id: id, name: "First"),
            makeEntry(id: id, name: "Second"),
        ])

        let manifest = try BrokerPresetManifest.decode(from: data)

        XCTAssertEqual(manifest.presets.count, 1)
        XCTAssertEqual(manifest.presets.first?.name, "First", "the first occurrence wins")
    }

    func test_decode_idCollidingWithBuiltInSkipped() throws {
        let data = try makeManifestData(presets: [
            makeEntry(id: BrokerAgentProfile.balancedID.uuidString, name: "Impostor Balanced"),
        ])

        let manifest = try BrokerPresetManifest.decode(from: data)

        XCTAssertTrue(
            manifest.presets.isEmpty,
            "a manifest must never be able to shadow a compiled built-in"
        )
    }

    func test_decode_moreThan32PresetsTruncated() throws {
        let entries = (0..<40).map { _ in makeEntry() }
        let data = try makeManifestData(presets: entries)

        let manifest = try BrokerPresetManifest.decode(from: data)

        XCTAssertEqual(manifest.presets.count, BrokerPresetManifest.maxPresets)
    }

    // MARK: - Decode: sanitisation

    func test_decode_controlCharsStrippedFromNameAndDetail() throws {
        let data = try makeManifestData(presets: [
            makeEntry(name: "Bad\u{0007}Name\nHere", detail: "Bad\u{0000}Detail\r\nHere"),
        ])

        let manifest = try BrokerPresetManifest.decode(from: data)

        let preset = try XCTUnwrap(manifest.presets.first)
        XCTAssertEqual(preset.name, "BadNameHere")
        XCTAssertEqual(preset.detail, "BadDetailHere")
    }

    func test_decode_overlongNameCapped() throws {
        let longName = String(repeating: "x", count: 500)
        let longDetail = String(repeating: "y", count: 500)
        let data = try makeManifestData(presets: [makeEntry(name: longName, detail: longDetail)])

        let manifest = try BrokerPresetManifest.decode(from: data)

        let preset = try XCTUnwrap(manifest.presets.first)
        XCTAssertEqual(preset.name.unicodeScalars.count, BrokerPresetManifest.maxNameScalars)
        XCTAssertEqual(preset.detail.unicodeScalars.count, BrokerPresetManifest.maxDetailScalars)
    }

    func test_decode_emptyNameAfterSanitizingSkipsEntry() throws {
        // Entirely control characters: nothing survives sanitising.
        let data = try makeManifestData(presets: [makeEntry(name: "\u{0001}\u{0002}\n")])

        let manifest = try BrokerPresetManifest.decode(from: data)

        XCTAssertTrue(manifest.presets.isEmpty)
    }

    func test_decode_invalidSymbolFallsBack() throws {
        let data = try makeManifestData(presets: [
            makeEntry(symbolName: "not a valid sf symbol name!!"),
        ])

        let manifest = try BrokerPresetManifest.decode(from: data)

        XCTAssertEqual(manifest.presets.first?.symbolName, BrokerPresetManifest.fallbackSymbolName)
    }

    // MARK: - Decode: forward compatibility

    func test_decode_schemaVersion2StillYieldsValidEntries() throws {
        let data = try makeManifestData(schemaVersion: 2, presets: [makeEntry(name: "Future Preset")])

        let manifest = try BrokerPresetManifest.decode(from: data)

        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.presets.first?.name, "Future Preset")
    }

    func test_decode_malformedTopLevelThrows() {
        let data = Data("not json at all".utf8)
        XCTAssertThrowsError(try BrokerPresetManifest.decode(from: data)) { error in
            XCTAssertEqual(error as? BrokerPresetManifestError, .malformed)
        }
    }

    // MARK: - BrokerSettings integration

    private func makeSettings(remotePresets: [BrokerAgentProfile] = []) -> BrokerSettings {
        var settings = BrokerSettings(isEnabled: true, port: 43117, policy: .bundledDefault)
        settings.remotePresets = remotePresets
        return settings
    }

    private func makeRemotePreset(
        id: UUID = UUID(), name: String = "Remote Preset", rules: BrokerRuleSet = .default
    ) -> BrokerAgentProfile {
        BrokerAgentProfile(id: id, name: name, detail: "From the manifest.", symbolName: "leaf", rules: rules)
    }

    func test_decode_oldSaveWithoutNewKeysDecodesToDefaults() throws {
        var json = try encodedSettingsDictionary(BrokerSettings.default)
        json.removeValue(forKey: "remote_presets")
        json.removeValue(forKey: "preset_manifest")

        let decoded = try decodeSettings(json)

        XCTAssertEqual(decoded.remotePresets, [])
        XCTAssertTrue(decoded.presetManifest.isEnabled)
        XCTAssertEqual(decoded.presetManifest.urlString, BrokerPresetManifestConfig.defaultURLString)
        XCTAssertNil(decoded.presetManifest.lastCheckedAt)
    }

    func test_roundTrip_withRemotePresets() throws {
        var settings = makeSettings(remotePresets: [makeRemotePreset(name: "Zeta Preset")])
        settings.presetManifest.etag = "abc123"
        settings.presetManifest.lastCheckedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BrokerSettings.self, from: data)

        XCTAssertEqual(decoded.remotePresets.map(\.name), ["Zeta Preset"])
        XCTAssertEqual(decoded.presetManifest.etag, "abc123")
        XCTAssertEqual(decoded.presetManifest.lastCheckedAt, settings.presetManifest.lastCheckedAt)
    }

    func test_allProfiles_ordering() {
        let remote = makeRemotePreset(name: "Middle Preset")
        var settings = makeSettings(remotePresets: [remote])
        settings.createProfile(named: "Zzz User Profile")

        let names = settings.allProfiles.map(\.name)
        let builtInNames = BrokerAgentProfile.builtIns.map(\.name)

        XCTAssertEqual(Array(names.prefix(builtInNames.count)), builtInNames)
        XCTAssertEqual(names[builtInNames.count], "Middle Preset")
        XCTAssertEqual(names.last, "Zzz User Profile")
    }

    func test_activeProfile_resolvesRemotePreset() {
        let remote = makeRemotePreset(name: "Applied Remote")
        var settings = makeSettings(remotePresets: [remote])

        settings.applyProfile(id: remote.id)

        XCTAssertEqual(settings.activeProfileID, remote.id)
        XCTAssertEqual(settings.activeProfile?.name, "Applied Remote")
    }

    func test_applyProfile_onRemotePreset_preservesMachineState() {
        var policy = BrokerPolicy.bundledDefault
        policy.t3Instances = [
            T3InstanceConfig(
                id: "claudeAgent", name: "Renamed By User", boundAccountId: "account-1",
                origin: .detected, driver: "claudeAgent"
            )
        ]
        var remoteRules = BrokerRuleSet.default
        remoteRules.thresholds.sessionPct = 61
        let remote = makeRemotePreset(name: "Remote With Rules", rules: remoteRules)
        var settings = BrokerSettings(isEnabled: true, port: 43117, policy: policy)
        settings.remotePresets = [remote]

        settings.applyProfile(id: remote.id)

        XCTAssertEqual(settings.policy.thresholds.sessionPct, 61)
        XCTAssertEqual(settings.policy.t3Instances.first?.name, "Renamed By User")
        XCTAssertEqual(settings.policy.t3Instances.first?.boundAccountId, "account-1")
    }

    func test_updateRemotePresets_neverTouchesPolicyOrPin() {
        var settings = makeSettings()
        settings.applyProfile(id: BrokerAgentProfile.balancedID)
        let policyBefore = settings.policy
        let activeIDBefore = settings.activeProfileID
        let activeRulesBefore = settings.activeProfileRules

        settings.updateRemotePresets([makeRemotePreset(name: "New Arrival")])

        XCTAssertEqual(settings.remotePresets.map(\.name), ["New Arrival"])
        XCTAssertEqual(settings.policy, policyBefore)
        XCTAssertEqual(settings.activeProfileID, activeIDBefore)
        XCTAssertEqual(settings.activeProfileRules, activeRulesBefore)
    }

    /// F3: a manifest preset whose id collides with a saved user profile must
    /// never be allowed in -- `activeProfile`/`applyProfile(id:)`/
    /// `isRemotePreset(id:)` all resolve `remotePresets` before `profiles`,
    /// so letting the collision through would shadow (and, through
    /// `applyProfile`, silently swap the rules behind) a profile the user
    /// saved themselves.
    func test_updateRemotePresets_dropsPresetCollidingWithUserProfileID() {
        var settings = makeSettings()
        let userProfileID = settings.createProfile(named: "My Own Profile")
        let colliding = makeRemotePreset(id: userProfileID, name: "Impostor")
        let harmless = makeRemotePreset(name: "Harmless")

        settings.updateRemotePresets([colliding, harmless])

        XCTAssertEqual(settings.remotePresets.map(\.name), ["Harmless"])
        XCTAssertFalse(settings.isRemotePreset(id: userProfileID))
    }

    /// F3: even with a manifest attempting the collision, the user's own
    /// profile must keep resolving through every profile-identity API.
    func test_updateRemotePresets_collidingID_userProfileStillResolvesEverywhere() {
        var settings = makeSettings()
        let userProfileID = settings.createProfile(named: "My Own Profile")
        let userProfileRules = settings.profiles.first { $0.id == userProfileID }!.rules
        let colliding = makeRemotePreset(id: userProfileID, name: "Impostor", rules: {
            var rules = BrokerRuleSet.default
            rules.thresholds.sessionPct = 12
            return rules
        }())

        settings.updateRemotePresets([colliding])

        XCTAssertEqual(settings.activeProfile?.id, userProfileID)
        XCTAssertEqual(settings.activeProfile?.rules, userProfileRules)
        settings.applyProfile(id: userProfileID)
        XCTAssertEqual(settings.policy.ruleSet, userProfileRules)
        XCTAssertNotEqual(settings.policy.thresholds.sessionPct, 12, "the impostor's rules must never apply")
    }

    func test_uniqueProfileName_collidesWithRemotePresetName() {
        let remote = makeRemotePreset(name: "Shared Name")
        let settings = makeSettings(remotePresets: [remote])

        XCTAssertEqual(settings.uniqueProfileName("Shared Name"), "Shared Name 2")
        XCTAssertEqual(settings.uniqueProfileName("shared name"), "shared name 2")
    }

    func test_isRemotePreset_trueOnlyForManifestEntries() {
        let remote = makeRemotePreset()
        let settings = makeSettings(remotePresets: [remote])

        XCTAssertTrue(settings.isRemotePreset(id: remote.id))
        XCTAssertFalse(settings.isRemotePreset(id: BrokerAgentProfile.balancedID))
        XCTAssertFalse(settings.isRemotePreset(id: UUID()))
    }

    // MARK: - Service: HTTP client

    /// Minimal `URLProtocol` stub: the test installs a handler closure per
    /// request, and this forwards the (data, response) it returns (or the
    /// error it throws) straight into the `URLSession` pipeline. No shared
    /// mutable state beyond the handler itself, since each test builds its
    /// own session/configuration.
    private final class StubURLProtocol: URLProtocol {
        static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = StubURLProtocol.handler else {
                client?.urlProtocol(self, didFailWithError: TestError(message: "no handler installed"))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func test_fetch_200WithETag_returnsUpdatedManifestAndETag() async throws {
        let manifestData = try makeManifestData(presets: [makeEntry(name: "Fetched Preset")])
        StubURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Etag": "\"v2\""]
            )!
            return (response, manifestData)
        }
        let service = PresetManifestService(session: makeStubbedSession())

        let outcome = try await service.fetch(from: URL(string: "https://example.com/presets.json")!, etag: nil)

        guard case .updated(let manifest, let etag) = outcome else {
            return XCTFail("expected .updated")
        }
        XCTAssertEqual(manifest.presets.first?.name, "Fetched Preset")
        XCTAssertEqual(etag, "\"v2\"")
    }

    func test_fetch_304_returnsNotModified() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }
        let service = PresetManifestService(session: makeStubbedSession())

        let outcome = try await service.fetch(
            from: URL(string: "https://example.com/presets.json")!, etag: "\"v1\""
        )

        XCTAssertEqual(outcome, .notModified)
    }

    func test_fetch_nonHTTPSRejected() async throws {
        let service = PresetManifestService(session: makeStubbedSession())

        do {
            _ = try await service.fetch(from: URL(string: "http://example.com/presets.json")!, etag: nil)
            XCTFail("expected insecureScheme to be thrown")
        } catch let error as PresetManifestService.FetchError {
            XCTAssertEqual(error, .insecureScheme)
        }
    }

    func test_fetch_oversizedBodyRejected() async throws {
        let oversized = Data(repeating: 0x20, count: BrokerPresetManifest.maxPayloadBytes + 1)
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, oversized)
        }
        let service = PresetManifestService(session: makeStubbedSession())

        do {
            _ = try await service.fetch(from: URL(string: "https://example.com/presets.json")!, etag: nil)
            XCTFail("expected tooLarge to be thrown")
        } catch let error as PresetManifestService.FetchError {
            XCTAssertEqual(error, .tooLarge)
        }
    }

    /// F2: a server that admits up front (via `Content-Length`) that the body
    /// is too big must be rejected before any of that body is read, not just
    /// after it has all been buffered.
    func test_fetch_oversizedContentLengthRejectedBeforeReadingBody() async throws {
        let oversizedLength = BrokerPresetManifest.maxPayloadBytes + 1
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": "\(oversizedLength)"]
            )!
            // No body at all: if the service ever tried to read one before
            // checking `expectedContentLength`, this would still succeed
            // (empty body decodes to a malformed-but-not-oversized manifest),
            // so the only way this test can pass is the early check firing.
            return (response, Data())
        }
        let service = PresetManifestService(session: makeStubbedSession())

        do {
            _ = try await service.fetch(from: URL(string: "https://example.com/presets.json")!, etag: nil)
            XCTFail("expected tooLarge to be thrown")
        } catch let error as PresetManifestService.FetchError {
            XCTAssertEqual(error, .tooLarge)
        }
    }

    // MARK: - Bundled resource

    func test_bundledManifest_loadsAndContainsBalancedNoOpus() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "broker-presets", withExtension: "json")
                ?? Bundle.main.url(forResource: "broker-presets", withExtension: "json"),
            "broker-presets.json must ship in the app bundle"
        )
        let data = try Data(contentsOf: url)

        let manifest = try BrokerPresetManifest.decode(from: data)

        let preset = try XCTUnwrap(manifest.presets.first { $0.name == "Balanced (No Opus)" })
        XCTAssertEqual(preset.symbolName, "scalemass")
    }

    func test_bundledManifest_noOpusOrHaikuCandidateAnywhere() throws {
        let manifest = try loadBundledManifest()
        let preset = try XCTUnwrap(manifest.presets.first { $0.name == "Balanced (No Opus)" })

        for (role, chain) in preset.rules.roles {
            for candidate in chain {
                XCTAssertFalse(
                    candidate.model.lowercased().contains("opus"),
                    "\(role): \(candidate.id) must not name an Opus model"
                )
                XCTAssertFalse(
                    candidate.model.lowercased().contains("haiku"),
                    "\(role): \(candidate.id) must not name a Haiku model"
                )
            }
        }
    }

    func test_bundledManifest_thresholdsEqualDefault() throws {
        let manifest = try loadBundledManifest()
        let preset = try XCTUnwrap(manifest.presets.first { $0.name == "Balanced (No Opus)" })

        XCTAssertEqual(preset.rules.thresholds, BrokerThresholds.default)
    }

    private func loadBundledManifest() throws -> BrokerPresetManifest {
        // The app bundle isn't the test bundle, so this reaches into the main
        // app's Resources by path from `Bundle.main` (the app under test's
        // executable path is what xctest hosts under, so on CI/local runs the
        // Pinemeter.app bundle itself is discoverable via
        // `Bundle(identifier:)`). Falling back to a direct source-tree read
        // keeps this test resilient to how the test bundle is hosted.
        if let url = Bundle.main.url(forResource: "broker-presets", withExtension: "json") {
            return try BrokerPresetManifest.decode(from: try Data(contentsOf: url))
        }
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pinemeter/Resources/broker-presets.json")
        let data = try Data(contentsOf: sourceURL)
        return try BrokerPresetManifest.decode(from: data)
    }

    // MARK: - Helpers

    private func encodedSettingsDictionary(_ settings: BrokerSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodeSettings(_ dictionary: [String: Any]) throws -> BrokerSettings {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try JSONDecoder().decode(BrokerSettings.self, from: data)
    }
}

// MARK: - AppModel wiring

/// A scripted `PresetManifestServiceProtocol`: returns one canned outcome (or
/// throws) per `fetch`, and records every call so a test can assert the
/// throttle actually skipped the network rather than merely produced the
/// same result by coincidence.
private actor FakePresetManifestService: PresetManifestServiceProtocol {
    enum Script {
        case succeed(PresetManifestFetchOutcome)
        case fail(Error)
    }

    var script: Script
    private(set) var callCount = 0

    init(script: Script) {
        self.script = script
    }

    func fetch(from url: URL, etag: String?) async throws -> PresetManifestFetchOutcome {
        callCount += 1
        switch script {
        case .succeed(let outcome): return outcome
        case .fail(let error): throw error
        }
    }
}

@MainActor
final class BrokerPresetManifestAppModelTests: XCTestCase {
    private func makeAppModel(presetManifestService: (any PresetManifestServiceProtocol)?) -> AppModel {
        AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "not used"))),
            notificationService: NotificationServiceSpy(),
            presetManifestService: presetManifestService,
            brokerService: nil
        )
    }

    private func makeUpdatedOutcome(name: String = "Fetched") -> PresetManifestFetchOutcome {
        let profile = BrokerAgentProfile(name: name, detail: "", symbolName: "leaf", rules: .default)
        return .updated(
            manifest: BrokerPresetManifest(schemaVersion: 1, presets: [profile]),
            etag: "\"etag-1\""
        )
    }

    func test_refreshPresetManifest_disabled_noOp() async {
        let fake = FakePresetManifestService(script: .succeed(makeUpdatedOutcome()))
        let appModel = makeAppModel(presetManifestService: fake)
        appModel.settings.broker.presetManifest.isEnabled = false

        await appModel.refreshPresetManifest(force: true)

        let calls = await fake.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(appModel.settings.broker.remotePresets.isEmpty)
    }

    func test_refreshPresetManifest_invalidURL_noOp() async {
        let fake = FakePresetManifestService(script: .succeed(makeUpdatedOutcome()))
        let appModel = makeAppModel(presetManifestService: fake)
        appModel.settings.broker.presetManifest.urlString = "not a url"

        await appModel.refreshPresetManifest(force: true)

        let calls = await fake.callCount
        XCTAssertEqual(calls, 0)
    }

    func test_refreshPresetManifest_success_storesPresetsAndETagAndClearsError() async {
        let fake = FakePresetManifestService(script: .succeed(makeUpdatedOutcome(name: "Fresh Preset")))
        let appModel = makeAppModel(presetManifestService: fake)
        appModel.settings.broker.presetManifest.lastError = "stale error"
        let policyBefore = appModel.settings.broker.policy
        let activeProfileIDBefore = appModel.settings.broker.activeProfileID

        await appModel.refreshPresetManifest(force: true)

        XCTAssertEqual(appModel.settings.broker.remotePresets.map(\.name), ["Fresh Preset"])
        XCTAssertEqual(appModel.settings.broker.presetManifest.etag, "\"etag-1\"")
        XCTAssertNil(appModel.settings.broker.presetManifest.lastError)
        XCTAssertNotNil(appModel.settings.broker.presetManifest.lastCheckedAt)
        // A refresh must never touch routing by itself.
        XCTAssertEqual(appModel.settings.broker.policy, policyBefore)
        XCTAssertEqual(appModel.settings.broker.activeProfileID, activeProfileIDBefore)
    }

    func test_refreshPresetManifest_failure_keepsPreviousPresetsAndSetsSanitizedError() async {
        let existing = BrokerAgentProfile(name: "Still Here", detail: "", symbolName: "leaf", rules: .default)
        let fake = FakePresetManifestService(script: .fail(TestError(message: "boom\ncontrol\u{0007}chars")))
        let appModel = makeAppModel(presetManifestService: fake)
        appModel.settings.broker.remotePresets = [existing]

        await appModel.refreshPresetManifest(force: true)

        XCTAssertEqual(appModel.settings.broker.remotePresets, [existing], "stale-but-usable beats empty")
        let error = try? XCTUnwrap(appModel.settings.broker.presetManifest.lastError)
        XCTAssertNotNil(error)
        XCTAssertFalse(error?.contains("\n") ?? true, "the stored error must not carry a raw newline")
    }

    func test_refreshPresetManifest_notModified_updatesLastCheckedOnlyAndClearsError() async {
        let existing = BrokerAgentProfile(name: "Unchanged", detail: "", symbolName: "leaf", rules: .default)
        let fake = FakePresetManifestService(script: .succeed(.notModified))
        let appModel = makeAppModel(presetManifestService: fake)
        appModel.settings.broker.remotePresets = [existing]
        appModel.settings.broker.presetManifest.lastError = "stale error"

        await appModel.refreshPresetManifest(force: true)

        XCTAssertEqual(appModel.settings.broker.remotePresets, [existing])
        XCTAssertNil(appModel.settings.broker.presetManifest.lastError)
        XCTAssertNotNil(appModel.settings.broker.presetManifest.lastCheckedAt)
    }

    func test_refreshPresetManifest_withinFreshnessWindow_skipsWithoutForce() async {
        let fake = FakePresetManifestService(script: .succeed(makeUpdatedOutcome()))
        let appModel = makeAppModel(presetManifestService: fake)
        appModel.settings.broker.presetManifest.lastCheckedAt = Date()

        await appModel.refreshPresetManifest(force: false)

        let calls = await fake.callCount
        XCTAssertEqual(calls, 0)
    }

    func test_refreshPresetManifest_pastFreshnessWindow_fetchesWithoutForce() async {
        let fake = FakePresetManifestService(script: .succeed(makeUpdatedOutcome()))
        let appModel = makeAppModel(presetManifestService: fake)
        appModel.settings.broker.presetManifest.lastCheckedAt = Date(timeIntervalSinceNow: -7 * 60 * 60)

        await appModel.refreshPresetManifest(force: false)

        let calls = await fake.callCount
        XCTAssertEqual(calls, 1)
    }
}
