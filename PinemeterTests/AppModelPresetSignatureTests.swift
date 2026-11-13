import Foundation
import XCTest
@testable import Pinemeter

private actor SignedManifestStub: PresetManifestServiceProtocol {
    enum Script {
        case outcome(PresetManifestSignedFetchOutcome)
        case failure(Error)
    }
    struct Call: Sendable { let url: String; let etag: String? }
    private var calls: [Call] = []
    private var script: Script
    private var unsignedOutcome: PresetManifestFetchOutcome?
    init(line: Data) { script = .outcome(.updated(line: line, etag: "next-signed-etag")) }
    func setUnsignedOutcome(_ outcome: PresetManifestFetchOutcome) { unsignedOutcome = outcome }
    func setLine(_ line: Data) { script = .outcome(.updated(line: line, etag: "next-signed-etag")) }
    func setScript(_ script: Script) { self.script = script }
    func fetch(from url: URL, etag: String?) async throws -> PresetManifestFetchOutcome {
        calls.append(Call(url: url.absoluteString, etag: etag))
        guard let unsignedOutcome else { throw URLError(.unsupportedURL) }
        return unsignedOutcome
    }
    func fetchSigned(etag: String?) async throws -> PresetManifestSignedFetchOutcome {
        calls.append(Call(url: BrokerPresetDistribution.officialURL, etag: etag))
        switch script {
        case .outcome(let outcome): return outcome
        case .failure(let error): throw error
        }
    }
    func recordedCalls() -> [Call] { calls }
}

@MainActor
final class AppModelPresetSignatureTests: XCTestCase {
    private struct World {
        let directory: URL
        let model: AppModel
        let service: SignedManifestStub
        let store: BrokerOfficialPresetStore
        let history: BrokerManifestHistoryStore
        let source: BrokerPresetManifestSource
        let state: BrokerOfficialPresetState
        let revisions: BrokerManifestHistoryLoadResult
    }

    private func makeWorld(
        decodeManifest: @escaping @Sendable (Data) throws -> BrokerPresetManifest = BrokerPresetManifest.decode(from:)
    ) async throws -> World {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = BrokerOfficialPresetStore(storeDirectory: directory, decodeManifest: decodeManifest)
        let history = BrokerManifestHistoryStore(storeDirectory: directory)
        let service = SignedManifestStub(line: try PresetSigningFixture.line(seq: 2))
        let model = try makeModel(service: service, store: store, history: history)
        await model.refreshPresetManifest(force: true)
        let source = try XCTUnwrap(model.settings.broker.presetManifest.sources.first)
        XCTAssertEqual(source.cachedPresets, try PresetSigningFixture.manifest().presets)
        let state = await store.snapshot()
        let revisions = await history.load(sourceID: source.id, urlString: source.urlString)
        guard case .loaded(let snapshots) = revisions else { throw TestError(message: "history must load") }
        XCTAssertEqual(snapshots.count, 1)
        model.settings.broker.presetManifest.sources[0].lastError = "previous failure"
        model.settings.broker.presetManifest.sources[0].lastCheckedAt = .distantPast
        return World(directory: directory, model: model, service: service, store: store,
                     history: history, source: source, state: state, revisions: revisions)
    }

    private func makeModel(service: SignedManifestStub, store: BrokerOfficialPresetStore,
                           history: BrokerManifestHistoryStore) throws -> AppModel {
        AppModel(
            settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "unused"))),
            notificationService: NotificationServiceSpy(), presetManifestService: service,
            presetManifestHistoryStore: history,
            officialPresetStore: store, officialPresetKeys: try PresetSigningFixture.keys,
            officialPresetNow: { PresetSigningFixture.now }
        )
    }

    private func assertRetained(_ world: World, error: String?,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let source = try XCTUnwrap(world.model.settings.broker.presetManifest.sources.first, file: file, line: line)
        XCTAssertEqual(source.cachedPresets, world.source.cachedPresets, file: file, line: line)
        XCTAssertEqual(source.cachedAgentSetup, world.source.cachedAgentSetup, file: file, line: line)
        XCTAssertEqual(source.etag, world.source.etag, file: file, line: line)
        XCTAssertEqual(source.lastError, error, file: file, line: line)
        XCTAssertGreaterThan(try XCTUnwrap(source.lastCheckedAt, file: file, line: line), .distantPast, file: file, line: line)
        let revisions = await world.history.load(sourceID: source.id, urlString: source.urlString)
        XCTAssertEqual(revisions, world.revisions, file: file, line: line)
        let state = await world.store.snapshot()
        XCTAssertEqual(state.line, world.state.line, file: file, line: line)
        XCTAssertEqual(state.manifest, world.state.manifest, file: file, line: line)
        XCTAssertEqual(state.payload, world.state.payload, file: file, line: line)
        XCTAssertEqual(state.lastCheck?.at, PresetSigningFixture.now, file: file, line: line)
        let persisted = await BrokerOfficialPresetStore(storeDirectory: world.directory)
            .load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        XCTAssertEqual(persisted, state, file: file, line: line)
    }

    private func signedLine(changing changes: [String: Any]) throws -> Data {
        let payload = try BrokerPresetSignature.verify(line: PresetSigningFixture.line(seq: 3),
                                                      keys: PresetSigningFixture.keys)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        fields.merge(changes) { _, new in new }
        return try PresetSigningFixture.sign(JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
    }

    func test_frozenVerifiedManifestWarnsOnlyForOfficialSourceAtLoadAndRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrokerOfficialPresetStore(storeDirectory: directory)
        _ = await store.load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        _ = try await store.accept(line: PresetSigningFixture.line(), etag: "old", checkedAt: PresetSigningFixture.now)
        let now = PresetSigningFixture.now.addingTimeInterval(15 * 24 * 3600)
        let service = SignedManifestStub(line: try signedLine(changing: [
            "issued_at": BrokerHealthDocument.formatTime(now)
        ]))
        let model = AppModel(
            settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "unused"))),
            notificationService: NotificationServiceSpy(), presetManifestService: service,
            presetManifestHistoryStore: BrokerManifestHistoryStore(storeDirectory: directory),
            officialPresetStore: store, officialPresetKeys: try PresetSigningFixture.keys,
            officialPresetNow: { now }
        )
        let official = try XCTUnwrap(model.settings.broker.presetManifest.sources.first)
        XCTAssertNil(model.officialBrokerPresetFreshnessWarning(for: official))
        await model.loadOfficialPresetsIfNeeded()
        XCTAssertEqual(model.officialPresetIssuedAt, PresetSigningFixture.now)
        XCTAssertEqual(model.officialBrokerPresetFreshnessWarning(for: official),
            "Official presets were last published 15 days ago. Updates may be blocked; current presets stay in use.")
        var userSource = official
        userSource.urlString = "https://example.com/presets.json"
        XCTAssertNil(model.officialBrokerPresetFreshnessWarning(for: userSource))
        userSource.urlString = BrokerPresetDistribution.officialURL
        XCTAssertNil(model.officialBrokerPresetFreshnessWarning(for: userSource))
        await model.refreshPresetManifest(force: true)
        XCTAssertEqual(model.officialPresetIssuedAt, now)
        XCTAssertNil(model.officialBrokerPresetFreshnessWarning(for: official))
    }

    private struct RoutingWorld {
        let model: AppModel
        let service: SignedManifestStub
        let store: BrokerOfficialPresetStore
        let broker: FakeBrokerService
        let directory: URL
        let manifest: BrokerPresetManifest
    }

    private func makeRoutingWorld(emptyKeys: Bool = false) throws -> RoutingWorld {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = BrokerOfficialPresetStore(storeDirectory: directory)
        var profile = BrokerAgentProfile.balanced
        profile.isBuiltIn = false
        profile.rules.roles["planning"] = [BrokerCandidate(route: .auto, model: "published")]
        let manifest = BrokerPresetManifest(schemaVersion: 2, presets: [profile])
        let service = SignedManifestStub(line: try PresetSigningFixture.line(manifest: manifest))
        let broker = FakeBrokerService()
        let model = AppModel(
            settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "unused"))),
            notificationService: NotificationServiceSpy(), presetManifestService: service,
            presetManifestHistoryStore: BrokerManifestHistoryStore(storeDirectory: directory),
            officialPresetStore: store, officialPresetKeys: emptyKeys ? [:] : try PresetSigningFixture.keys,
            officialPresetNow: { PresetSigningFixture.now }, brokerService: broker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
        )
        model.settings.broker.isEnabled = true
        model.settings.broker.autoApplyPublishedRoutingUpdates = true
        model.settings.broker.applyProfile(id: BrokerAgentProfile.balancedID)
        return RoutingWorld(model: model, service: service, store: store, broker: broker,
                            directory: directory, manifest: manifest)
    }

    private func assertNoAutomaticApply(_ world: RoutingWorld, policy: BrokerPolicy,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        await world.model.routingUpdateApplyTask?.value
        XCTAssertEqual(world.model.settings.broker.policy, policy, file: file, line: line)
        XCTAssertNil(world.model.routingUpdateApplyTask, file: file, line: line)
        XCTAssertFalse(world.model.settings.broker.canUndoRoutingUpdate, file: file, line: line)
        let pushed = await world.broker.updatedPolicies
        XCTAssertTrue(pushed.isEmpty, file: file, line: line)
    }

    func test_emptyInjectedKeysKeepCacheAndPresetsInUse() async throws {
        let world = try makeRoutingWorld(emptyKeys: true)
        world.model.settings.broker.presetManifest.sources[0].cachedPresets = world.manifest.presets
        let policy = world.model.settings.broker.policy
        await world.model.refreshPresetManifest(force: true)
        let source = try XCTUnwrap(world.model.settings.broker.presetManifest.sources.first)
        XCTAssertEqual(source.cachedPresets, world.manifest.presets)
        XCTAssertEqual(source.lastError, "This build cannot verify official preset updates. Current presets stay in use.")
        XCTAssertNil(world.model.officialPresetIssuedAt)
        XCTAssertNil(world.model.officialBrokerPresetFreshnessWarning(for: source))
        try await assertStoreResult(world, result: "unknown_key")
        await assertNoAutomaticApply(world, policy: policy)
    }

    private func assertStoreResult(_ world: RoutingWorld, result: String) async throws {
        let state = await world.store.snapshot()
        XCTAssertEqual(state.lastCheck?.result, result)
    }

    func test_autoApplyRejectsCachedPresetsThatNeverPassedVerification() async throws {
        let world = try makeRoutingWorld()
        world.model.settings.broker.presetManifest.sources[0].cachedPresets = world.manifest.presets
        await world.service.setScript(.outcome(.notModified))
        let policy = world.model.settings.broker.policy
        await world.model.refreshPresetManifest(force: true)
        XCTAssertTrue(world.model.settings.broker.activeProfileHasUpdatedRules)
        await assertNoAutomaticApply(world, policy: policy)
    }

    func test_autoApplyDoesNotRunAfterRejectedRefreshEvenWithVerifiedCache() async throws {
        let world = try makeRoutingWorld()
        world.model.settings.broker.autoApplyPublishedRoutingUpdates = false
        await world.model.refreshPresetManifest(force: true)
        let verified = await world.store.snapshot()
        XCTAssertEqual(verified.manifest?.presets, world.manifest.presets)
        world.model.settings.broker.autoApplyPublishedRoutingUpdates = true
        await world.service.setLine(Data("invalid".utf8))
        let policy = world.model.settings.broker.policy
        await world.model.refreshPresetManifest(force: true)
        try await assertStoreResult(world, result: "malformed")
        XCTAssertEqual(world.model.settings.broker.presetManifest.sources[0].cachedPresets, world.manifest.presets)
        await assertNoAutomaticApply(world, policy: policy)
    }

    func test_autoApplyUsesVerifiedManifestAfterRepairingMismatchedCache() async throws {
        let world = try makeRoutingWorld()
        world.model.settings.broker.autoApplyPublishedRoutingUpdates = false
        await world.model.refreshPresetManifest(force: true)
        var forged = world.manifest.presets[0]
        forged.rules.roles["planning"] = [BrokerCandidate(route: .auto, model: "unverified")]
        world.model.settings.broker.presetManifest.sources[0].cachedPresets = [forged]
        world.model.settings.broker.autoApplyPublishedRoutingUpdates = true
        await world.service.setScript(.outcome(.notModified))
        await world.model.refreshPresetManifest(force: true)
        await world.model.routingUpdateApplyTask?.value
        XCTAssertEqual(world.model.settings.broker.presetManifest.sources[0].cachedPresets, world.manifest.presets)
        XCTAssertEqual(world.model.settings.broker.policy.roles["planning"]?.first?.model, "published")
        XCTAssertTrue(world.model.settings.broker.canUndoRoutingUpdate)
    }

    func test_autoApplyRunsAfterVerifiedAcceptance() async throws {
        let world = try makeRoutingWorld()
        await world.model.refreshPresetManifest(force: true)
        await world.model.routingUpdateApplyTask?.value
        let accepted = await world.store.snapshot()
        XCTAssertEqual(accepted.manifest?.presets, world.model.settings.broker.presetManifest.sources[0].cachedPresets)
        XCTAssertEqual(world.model.settings.broker.policy.roles["planning"]?.first?.model, "published")
        XCTAssertFalse(world.model.settings.broker.activeProfileHasUpdatedRules)
        XCTAssertTrue(world.model.settings.broker.canUndoRoutingUpdate)
        let pushed = await world.broker.updatedPolicies.last
        XCTAssertEqual(pushed?.roles["planning"]?.first?.model, "published")
    }

    func test_userAddedSourceUsesUnsignedFetchWithoutReadingOrWritingOfficialStore() async throws {
        let world = try makeRoutingWorld(emptyKeys: true)
        // A load would erase the in-memory sentinel after its disk file disappears.
        _ = await world.store.load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        _ = try await world.store.accept(line: PresetSigningFixture.line(), etag: "sentinel", checkedAt: PresetSigningFixture.now)
        let sentinel = await world.store.snapshot()
        let file = world.directory.appendingPathComponent("broker-official-presets.json")
        try FileManager.default.removeItem(at: file)
        let url = "https://example.com/user-presets.json"
        world.model.settings.broker.presetManifest.sources = [BrokerPresetManifestSource(urlString: url, etag: "user-etag")]
        await world.service.setUnsignedOutcome(.updated(manifest: world.manifest, etag: "user-next"))
        let policy = world.model.settings.broker.policy
        await world.model.loadOfficialPresetsIfNeeded()
        await world.model.refreshPresetManifest(force: true)
        let source = try XCTUnwrap(world.model.settings.broker.presetManifest.sources.first)
        XCTAssertEqual(source.cachedPresets, world.manifest.presets)
        XCTAssertEqual(source.etag, "user-next")
        XCTAssertNil(source.lastError)
        let calls = await world.service.recordedCalls()
        XCTAssertEqual(calls.map(\.url), [url])
        XCTAssertEqual(calls.map(\.etag), ["user-etag"])
        let after = await world.store.snapshot()
        XCTAssertEqual(after, sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(world.model.officialPresetIssuedAt)
        await assertNoAutomaticApply(world, policy: policy)
    }

    private func assertQuietRefreshRestoresCache(result: String, _ outcome: (World) throws -> PresetManifestSignedFetchOutcome) async throws {
        // Cover both a cleared source and a setup-only mismatch.
        for clearPresets in [true, false] {
            let world = try await makeWorld()
            if clearPresets { world.model.settings.broker.presetManifest.sources[0].cachedPresets = [] }
            world.model.settings.broker.presetManifest.sources[0].cachedAgentSetup = nil
            world.model.settings.broker.presetManifest.sources[0].etag = nil
            await world.service.setScript(.outcome(try outcome(world)))
            await world.model.refreshPresetManifest(force: true)
            let source = try XCTUnwrap(world.model.settings.broker.presetManifest.sources.first)
            XCTAssertEqual(source.cachedPresets, world.state.manifest?.presets)
            XCTAssertEqual(source.cachedAgentSetup, world.state.manifest?.agentSetup)
            XCTAssertNil(source.etag)
            XCTAssertNil(source.lastError)
            XCTAssertEqual(world.model.settings.broker.remotePresets, world.state.manifest?.presets)
            let persisted = await BrokerOfficialPresetStore(storeDirectory: world.directory)
                .load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
            XCTAssertEqual(persisted.manifest, world.state.manifest)
            XCTAssertEqual(persisted.line, world.state.line)
            XCTAssertEqual(persisted.lastCheck?.result, result)
            XCTAssertEqual(persisted.payload?.seq, 2)
            guard case .loaded(let snapshots) = await world.history.load(sourceID: source.id, urlString: source.urlString) else {
                return XCTFail("restored verified history must load")
            }
            XCTAssertEqual(snapshots.last?.presets, persisted.manifest?.presets)
            XCTAssertEqual(snapshots.last?.agentSetup, persisted.manifest?.agentSetup)
        }
    }

    func test_http304RestoresClearedCacheFromVerifiedStore() async throws {
        try await assertQuietRefreshRestoresCache(result: "unchanged") { _ in .notModified }
    }

    func test_unchangedRestoresClearedCacheFromVerifiedStore() async throws {
        try await assertQuietRefreshRestoresCache(result: "unchanged") { world in .updated(line: try XCTUnwrap(world.state.line), etag: "same") }
    }

    func test_staleCopyRestoresClearedCacheFromVerifiedStore() async throws {
        try await assertQuietRefreshRestoresCache(result: "stale_copy") { _ in .updated(line: try PresetSigningFixture.line(seq: 1, name: "Stale"), etag: "stale") }
    }

    func test_unchangedClearsErrorAndRecordsCheckWithoutChangingCache() async throws {
        let world = try await makeWorld()
        await world.service.setScript(.outcome(.updated(line: try XCTUnwrap(world.state.line), etag: "unchanged-etag")))
        await world.model.refreshPresetManifest(force: true)
        try await assertRetained(world, error: nil)
        let state = await world.store.snapshot()
        XCTAssertEqual(state.lastCheck?.result, "unchanged")
        XCTAssertEqual(state.etag, "unchanged-etag")
    }

    func test_staleCopyClearsErrorAndRetainsNewestLineAndETag() async throws {
        let world = try await makeWorld()
        await world.service.setScript(.outcome(.updated(line: try PresetSigningFixture.line(seq: 1, name: "Old preset"), etag: "old-etag")))
        await world.model.refreshPresetManifest(force: true)
        try await assertRetained(world, error: nil)
        let state = await world.store.snapshot()
        XCTAssertEqual(state.lastCheck?.result, "stale_copy")
        XCTAssertEqual(state.etag, world.state.etag)
    }

    func test_http304ClearsErrorAndRecordsCheckWithoutChangingCache() async throws {
        let world = try await makeWorld()
        await world.service.setScript(.outcome(.notModified))
        await world.model.refreshPresetManifest(force: true)
        try await assertRetained(world, error: nil)
        let state = await world.store.snapshot()
        XCTAssertEqual(state.lastCheck?.result, "unchanged")
        XCTAssertEqual(state.etag, world.state.etag)
    }

    func test_eachRejectionKeepsCacheAndRecordsMatchingCaption() async throws {
        let valid = try PresetSigningFixture.line(seq: 3)
        let signature = Data(repeating: 0, count: 64).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let invalidSignature = Data((String(decoding: valid.split(separator: UInt8(ascii: "."))[0], as: UTF8.self) + "." + signature).utf8)
        let cases: [(BrokerPresetSignature.Rejection, Data)] = [
            (.tooLarge, Data(repeating: 32, count: BrokerPresetSignature.maxBytes + 1)),
            (.malformed, Data("invalid".utf8)),
            (.unknownKey, try signedLine(changing: ["kid": "presets-1999-02"])),
            (.signature, invalidSignature),
            (.wrongType, try signedLine(changing: ["typ": "other-document"])),
            (.unsupportedVersion, try signedLine(changing: ["v": 2])),
            (.futureIssued, try signedLine(changing: ["issued_at": BrokerHealthDocument.formatTime(PresetSigningFixture.now.addingTimeInterval(86401))])),
            (.seqConflict, try PresetSigningFixture.line(seq: 2, name: "Conflicting preset"))
        ]
        for (rejection, line) in cases {
            let world = try await makeWorld()
            await world.service.setScript(.outcome(.updated(line: line, etag: "rejected-etag")))
            await world.model.refreshPresetManifest(force: true)
            try await assertRetained(world, error: rejection.errorDescription)
            let state = await world.store.snapshot()
            XCTAssertEqual(state.lastCheck?.result, rejection.rawValue)
            XCTAssertEqual(state.etag, world.state.etag)
        }
    }

    func test_undecodableManifestKeepsSequenceAvailableForLaterBuild() async throws {
        let world = try await makeWorld { data in
            let manifest = try BrokerPresetManifest.decode(from: data)
            guard manifest.schemaVersion == 1 else { throw BrokerPresetManifestError.malformed }
            return manifest
        }
        let line = try signedLine(changing: ["manifest": ["schema_version": 2,
            "presets": [["id": "10000000-0000-0000-0000-000000000002", "name": "Future preset",
                         "rules": ["default_instance": "claudeAgent"]]]]])
        let acceptance = BrokerPresetSignature.accept(line: line, stored: world.state.line,
            keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        XCTAssertEqual(acceptance.outcome, .accepted)
        await world.service.setScript(.outcome(.updated(line: line, etag: "future-etag")))
        await world.model.refreshPresetManifest(force: true)
        try await assertRetained(world, error: "This version cannot read the official preset update. Update Pinemeter to receive it. Current presets stay in use.")
        let rejected = await world.store.snapshot()
        XCTAssertEqual(rejected.lastCheck?.result, "undecodable")
        XCTAssertEqual(rejected.etag, world.state.etag)

        // Simulate a later build whose decoder understands the same signed bytes.
        let upgradedStore = BrokerOfficialPresetStore(storeDirectory: world.directory)
        let upgradedModel = try makeModel(service: world.service, store: upgradedStore, history: world.history)
        upgradedModel.settings = world.model.settings
        await upgradedModel.refreshPresetManifest(force: true)
        let upgraded = await upgradedStore.snapshot()
        XCTAssertEqual(upgraded.lastCheck?.result, "accepted")
        XCTAssertEqual(upgraded.payload?.seq, 3)
        XCTAssertEqual(upgraded.line, line)
        XCTAssertEqual(upgraded.etag, "future-etag")
        let source = try XCTUnwrap(upgradedModel.settings.broker.presetManifest.sources.first)
        XCTAssertEqual(source.cachedPresets.map(\.name), ["Future preset"])
        XCTAssertNil(source.lastError)
        guard case .loaded(let snapshots) = await world.history.load(sourceID: source.id, urlString: source.urlString) else {
            return XCTFail("upgraded history must load")
        }
        XCTAssertEqual(snapshots.count, 2)
    }

    func test_fetchErrorsKeepExistingTextAndPresets() async throws {
        let cases: [(Error, String)] = [
            (PresetManifestService.FetchError.badStatus(503), "The manifest server returned status 503."),
            (PresetManifestService.FetchError.tooLarge, "The manifest is larger than Pinemeter will accept."),
            (PresetManifestService.FetchError.insecureScheme, "The manifest URL must use https."),
            (TestError(message: "offline\nretry"), "offline?retry")
        ]
        for (error, caption) in cases {
            let world = try await makeWorld()
            await world.service.setScript(.failure(error))
            await world.model.refreshPresetManifest(force: true)
            try await assertRetained(world, error: caption)
            let state = await world.store.snapshot()
            XCTAssertEqual(state.lastCheck?.result, "fetch_failed")
            XCTAssertEqual(state.etag, world.state.etag)
        }
    }

    func test_weeklyResignKeepsCacheSetupAndHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrokerOfficialPresetStore(storeDirectory: directory)
        let history = BrokerManifestHistoryStore(storeDirectory: directory)
        let service = SignedManifestStub(line: try PresetSigningFixture.line())
        let checkedAt = PresetSigningFixture.now.addingTimeInterval(7 * 24 * 3600)
        let model = AppModel(
            settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "unused"))),
            notificationService: NotificationServiceSpy(), presetManifestService: service,
            presetManifestHistoryStore: history,
            officialPresetStore: store, officialPresetKeys: try PresetSigningFixture.keys,
            officialPresetNow: { checkedAt }
        )
        await model.refreshPresetManifest(force: true)
        let initial = try XCTUnwrap(model.settings.broker.presetManifest.sources.first)
        let initialHistory = await history.load(sourceID: initial.id, urlString: initial.urlString)
        guard case .loaded(let revisions) = initialHistory else { return XCTFail("history must load") }
        XCTAssertEqual(revisions.count, 1)

        let payload = try BrokerPresetSignature.verify(line: PresetSigningFixture.line(seq: 2),
                                                      keys: PresetSigningFixture.keys)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        fields["issued_at"] = BrokerHealthDocument.formatTime(checkedAt)
        let resigned = try PresetSigningFixture.sign(JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
        await service.setLine(resigned)
        model.settings.broker.presetManifest.sources[0].lastError = "previous failure"
        model.settings.broker.presetManifest.sources[0].lastCheckedAt = .distantPast
        let beforeRefresh = Date()
        await model.refreshPresetManifest(force: true)

        let source = try XCTUnwrap(model.settings.broker.presetManifest.sources.first)
        XCTAssertEqual(source.cachedPresets, initial.cachedPresets)
        XCTAssertEqual(source.cachedAgentSetup, initial.cachedAgentSetup)
        XCTAssertNil(source.lastError)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(source.lastCheckedAt), beforeRefresh)
        let finalHistory = await history.load(sourceID: source.id, urlString: source.urlString)
        XCTAssertEqual(finalHistory, initialHistory)
        let state = await store.snapshot()
        XCTAssertEqual(state.payload?.seq, 2)
        XCTAssertEqual(state.payload?.issuedAt, checkedAt)
        XCTAssertEqual(state.line, resigned)
        XCTAssertEqual(state.lastCheck?.result, "accepted")
        XCTAssertEqual(state.lastCheck?.at, checkedAt)
    }

    func test_signedOfficialManifestReplacesCacheFromDistributionOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrokerOfficialPresetStore(storeDirectory: directory)
        _ = await store.load(keys: try PresetSigningFixture.keys, now: PresetSigningFixture.now)
        _ = try await store.accept(line: try PresetSigningFixture.line(seq: 1, name: "Earlier preset"),
                                   etag: "signed-etag", checkedAt: PresetSigningFixture.now)
        let nextService = SignedManifestStub(line: try PresetSigningFixture.line(seq: 2))
        let history = BrokerManifestHistoryStore(storeDirectory: directory)
        let model = AppModel(
            settingsRepository: SettingsRepositoryFake(), keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "unused"))),
            notificationService: NotificationServiceSpy(), presetManifestService: nextService,
            presetManifestHistoryStore: history,
            officialPresetStore: store, officialPresetKeys: try PresetSigningFixture.keys,
            officialPresetNow: { PresetSigningFixture.now }
        )
        model.settings.broker.presetManifest.sources[0].etag = "mirror-etag"
        model.settings.broker.presetManifest.sources[0].urlString = " \n" + BrokerPresetManifestConfig.defaultURLString + "\t"
        model.settings.broker.presetManifest.sources[0].lastError = "previous failure"
        await model.refreshPresetManifest(force: true)
        let source = try XCTUnwrap(model.settings.broker.presetManifest.sources.first)
        XCTAssertEqual(source.cachedPresets, try PresetSigningFixture.manifest().presets)
        XCTAssertEqual(source.cachedAgentSetup, try PresetSigningFixture.manifest().agentSetup)
        XCTAssertNil(source.lastError)
        XCTAssertEqual(source.etag, "mirror-etag")
        let state = await store.snapshot()
        XCTAssertEqual(state.payload?.seq, 2)
        XCTAssertEqual(state.etag, "next-signed-etag")
        guard case .loaded(let revisions) = await history.load(sourceID: source.id, urlString: source.urlString) else {
            return XCTFail("signed manifest must reach history")
        }
        XCTAssertEqual(revisions.last?.presets, source.cachedPresets)
        let calls = await nextService.recordedCalls()
        XCTAssertEqual(calls.map(\.url), [BrokerPresetDistribution.officialURL])
        XCTAssertEqual(calls.map(\.etag), ["signed-etag"])
    }
}
