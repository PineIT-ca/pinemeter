//
//  BrokerPresetManifestMultipleSourcesTests.swift
//  PinemeterTests
//

import XCTest
@testable import Pinemeter

private actor MultipleSourceManifestService: PresetManifestServiceProtocol {
    enum Script {
        case outcome(PresetManifestFetchOutcome)
        case failure(Error)
    }

    struct Call: Sendable {
        let url: URL
        let etag: String?
    }

    private let scripts: [String: Script]
    private var calls: [Call] = []

    init(scripts: [String: Script]) {
        self.scripts = scripts
    }

    func fetch(from url: URL, etag: String?) async throws -> PresetManifestFetchOutcome {
        calls.append(Call(url: url, etag: etag))
        switch scripts[url.absoluteString] {
        case .outcome(let outcome): return outcome
        case .failure(let error): throw error
        case nil: throw TestError(message: "no script for \(url.absoluteString)")
        }
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

@MainActor
final class BrokerPresetManifestMultipleSourcesTests: XCTestCase {
    private func makeAppModel(service: any PresetManifestServiceProtocol) -> AppModel {
        AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "not used"))),
            notificationService: NotificationServiceSpy(),
            presetManifestService: service,
            brokerService: nil
        )
    }

    private func profile(id: UUID = UUID(), name: String) -> BrokerAgentProfile {
        BrokerAgentProfile(id: id, name: name, detail: "", symbolName: "leaf", rules: .default)
    }

    private func outcome(_ profiles: [BrokerAgentProfile], etag: String? = nil) -> PresetManifestFetchOutcome {
        .updated(
            manifest: BrokerPresetManifest(schemaVersion: 1, presets: profiles),
            etag: etag
        )
    }

    /// The key a real pre-multi-source save carries is `url` — that is what
    /// the shipped encoder wrote. `url_string` is only accepted as a
    /// belt-and-braces alias, so testing it alone would leave the migration
    /// every existing install actually needs uncovered.
    func test_oldSingleURLConfigDecodesIntoExactlyOneSource() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_760_000_000)
        for legacyKey in ["url", "url_string"] {
            var root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Self.settingsEncoder.encode(BrokerSettings.default))
                    as? [String: Any]
            )
            root["preset_manifest"] = [
                "is_enabled": true,
                legacyKey: "https://example.com/legacy.json",
                "etag": "\"legacy\"",
                "last_checked_at": ISO8601DateFormatter().string(from: checkedAt),
                "last_error": "offline",
            ]

            let data = try JSONSerialization.data(withJSONObject: root)
            let settings = try Self.settingsDecoder.decode(BrokerSettings.self, from: data)

            XCTAssertEqual(settings.presetManifest.sources.count, 1, legacyKey)
            let source = try XCTUnwrap(settings.presetManifest.sources.first)
            XCTAssertEqual(source.urlString, "https://example.com/legacy.json", legacyKey)
            XCTAssertEqual(source.etag, "\"legacy\"", legacyKey)
            XCTAssertEqual(source.lastCheckedAt, checkedAt, legacyKey)
            XCTAssertEqual(source.lastError, "offline", legacyKey)
        }
    }

    func test_duplicateSourceIdsInASaveAreDroppedOnDecode() throws {
        let sharedID = UUID()
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Self.settingsEncoder.encode(BrokerSettings.default))
                as? [String: Any]
        )
        root["preset_manifest"] = [
            "is_enabled": true,
            "sources": [
                ["id": sharedID.uuidString, "url_string": "https://example.com/first.json"],
                ["id": sharedID.uuidString, "url_string": "https://example.com/second.json"],
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: root)
        let settings = try Self.settingsDecoder.decode(BrokerSettings.self, from: data)

        XCTAssertEqual(
            settings.presetManifest.sources.map(\.urlString),
            ["https://example.com/first.json"],
            "every lookup is firstIndex(by id), so a second row under the same id could "
                + "never be fetched and would break the list it renders in"
        )
    }

    func test_effectiveAgentSetupUsesHighestSourceRevision() {
        var settings = BrokerSettings.default
        settings.presetManifest.sources = [
            BrokerPresetManifestSource(
                urlString: "https://example.com/first.json",
                cachedAgentSetup: BrokerAgentSetupNotice(
                    revision: 1, changedAt: nil, summary: "Old"
                )
            ),
            BrokerPresetManifestSource(
                urlString: "https://example.com/second.json",
                cachedAgentSetup: BrokerAgentSetupNotice(
                    revision: 4, changedAt: nil, summary: "Current"
                )
            ),
        ]

        XCTAssertEqual(settings.effectiveAgentSetup?.revision, 4)
        XCTAssertEqual(settings.effectiveAgentSetup?.summary, "Current")
    }

    /// The coders the app actually persists with (`SettingsRepository`).
    /// A bare `JSONDecoder` reads dates as raw numbers, which would let a
    /// migration test pass against a document the app could never load.
    private static var settingsEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var settingsDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func test_refreshPresetManifest_sendsEachSourcesOwnETag() async {
        let firstURL = "https://example.com/first.json"
        let secondURL = "https://example.com/second.json"
        let service = MultipleSourceManifestService(scripts: [
            firstURL: .outcome(.notModified),
            secondURL: .outcome(.notModified),
        ])
        let appModel = makeAppModel(service: service)
        appModel.settings.broker.presetManifest.sources = [
            BrokerPresetManifestSource(urlString: firstURL, etag: "\"first\""),
            BrokerPresetManifestSource(urlString: secondURL, etag: "\"second\""),
        ]

        await appModel.refreshPresetManifest(force: true)

        let calls = await service.recordedCalls()
        XCTAssertEqual(calls.map(\.url.absoluteString), [firstURL, secondURL])
        XCTAssertEqual(calls.map(\.etag), ["\"first\"", "\"second\""])
    }

    func test_refreshPresetManifest_oneFailureKeepsItsCacheWhileAnotherSucceeds() async {
        let failedURL = "https://example.com/failed.json"
        let goodURL = "https://example.com/good.json"
        let stale = profile(name: "Stale but usable")
        let fresh = profile(name: "Fresh")
        let service = MultipleSourceManifestService(scripts: [
            failedURL: .failure(TestError(message: "offline")),
            goodURL: .outcome(outcome([fresh])),
        ])
        let appModel = makeAppModel(service: service)
        appModel.settings.broker.presetManifest.sources = [
            BrokerPresetManifestSource(urlString: failedURL, cachedPresets: [stale]),
            BrokerPresetManifestSource(urlString: goodURL),
        ]

        await appModel.refreshPresetManifest(force: true)

        XCTAssertEqual(appModel.settings.broker.remotePresets.map(\.name), ["Stale but usable", "Fresh"])
        XCTAssertEqual(appModel.settings.broker.presetManifest.sources[0].lastError, "offline")
        XCTAssertNil(appModel.settings.broker.presetManifest.sources[1].lastError)
    }

    func test_refreshPresetManifest_firstSourceWinsIDCollision() async {
        let firstURL = "https://example.com/first.json"
        let secondURL = "https://example.com/second.json"
        let sharedID = UUID()
        let service = MultipleSourceManifestService(scripts: [
            firstURL: .outcome(outcome([profile(id: sharedID, name: "First")])),
            secondURL: .outcome(outcome([profile(id: sharedID, name: "Second")])),
        ])
        let appModel = makeAppModel(service: service)
        appModel.settings.broker.presetManifest.sources = [
            BrokerPresetManifestSource(urlString: firstURL),
            BrokerPresetManifestSource(urlString: secondURL),
        ]

        await appModel.refreshPresetManifest(force: true)

        XCTAssertEqual(appModel.settings.broker.remotePresets.map(\.name), ["First"])
    }

    func test_refreshPresetManifest_capsMergedSourcesAtManifestMaximum() async {
        let firstURL = "https://example.com/first.json"
        let secondURL = "https://example.com/second.json"
        let first = (0..<20).map { profile(name: "First \($0)") }
        let second = (0..<20).map { profile(name: "Second \($0)") }
        let service = MultipleSourceManifestService(scripts: [
            firstURL: .outcome(outcome(first)),
            secondURL: .outcome(outcome(second)),
        ])
        let appModel = makeAppModel(service: service)
        appModel.settings.broker.presetManifest.sources = [
            BrokerPresetManifestSource(urlString: firstURL),
            BrokerPresetManifestSource(urlString: secondURL),
        ]

        await appModel.refreshPresetManifest(force: true)

        XCTAssertEqual(appModel.settings.broker.remotePresets.count, BrokerPresetManifest.maxPresets)
        XCTAssertEqual(appModel.settings.broker.remotePresets.prefix(20).map(\.name), first.map(\.name))
        XCTAssertEqual(appModel.settings.broker.remotePresets.last?.name, "Second 11")
    }
}
