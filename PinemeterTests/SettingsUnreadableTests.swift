import Foundation
import XCTest
@testable import Pinemeter

@MainActor
final class SettingsUnreadableTests: XCTestCase {
    private let warning = "Pinemeter could not read the saved settings. It did not change them, and it will not save changes until you replace them."

    func testBootstrapShowsUnreadableSettingsMessage() async throws {
        let fixture = try await fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let repository = UnreadableSettingsRepository(backing: fixture.repository)
        let app = try makeApp(repository: repository)
        let sidecar = fixture.defaults.data(forKey: "remote_push_state")

        await app.bootstrap()

        XCTAssertTrue(app.isReady)
        XCTAssertEqual(app.settingsUnreadableMessage, warning)
        XCTAssertEqual(app.settings.broker.remoteHosts, fixture.hosts)
        XCTAssertEqual(app.settings.broker.pushGeneration, 77)
        XCTAssertEqual(fixture.defaults.data(forKey: "app_settings"), fixture.corrupt)
        XCTAssertEqual(fixture.defaults.data(forKey: "remote_push_state"), sidecar)
        XCTAssertEqual(fixture.defaults.data(forKey: "app_settings_unreadable_backup"), fixture.corrupt)
        let replacements = await repository.replacementCalls
        XCTAssertEqual(replacements, 0, "Bootstrap must never replace unreadable settings")
    }

    func testReplacementClearsWarningAndRetainsBackup() async throws {
        let fixture = try await fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let repository = UnreadableSettingsRepository(backing: fixture.repository)
        let app = try makeApp(repository: repository)
        await app.bootstrap()
        XCTAssertEqual(app.settingsUnreadableMessage, warning)

        // Replacement reloads the repository's effective generation, not a stale UI snapshot.
        var sidecar = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(fixture.defaults.data(forKey: "remote_push_state"))
        ) as? [String: Any])
        sidecar["push_generation"] = 90
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: sidecar), forKey: "remote_push_state")
        await app.replaceUnreadableSettings()

        XCTAssertNil(app.settingsUnreadableMessage)
        XCTAssertEqual(app.settings.broker.remoteHosts, fixture.hosts)
        XCTAssertEqual(app.settings.broker.pushGeneration, 90)
        let replacements = await repository.replacementCalls
        XCTAssertEqual(replacements, 1)
        let persisted = await SettingsRepository(userDefaults: fixture.defaults).load()
        XCTAssertEqual(persisted.broker.remoteHosts, fixture.hosts)
        XCTAssertEqual(persisted.broker.pushGeneration, 90)
        XCTAssertEqual(fixture.defaults.data(forKey: "app_settings_unreadable_backup"), fixture.corrupt)
        let next = try await fixture.repository.reservePushGeneration()
        XCTAssertEqual(next, 91)
    }

    func testReplacementFailureKeepsWarning() async throws {
        let fixture = try await fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let repository = UnreadableSettingsRepository(backing: fixture.repository, failReplacement: true)
        let app = try makeApp(repository: repository)
        await app.bootstrap()
        let sidecar = fixture.defaults.data(forKey: "remote_push_state")

        await app.replaceUnreadableSettings()

        XCTAssertEqual(app.settingsUnreadableMessage, warning)
        XCTAssertEqual(app.settings.broker.remoteHosts, fixture.hosts)
        XCTAssertEqual(app.settings.broker.pushGeneration, 77)
        let replacements = await repository.replacementCalls
        XCTAssertEqual(replacements, 1)
        let unreadable = await fixture.repository.storedSettingsUnreadable()
        XCTAssertTrue(unreadable)
        XCTAssertEqual(fixture.defaults.data(forKey: "app_settings"), fixture.corrupt)
        XCTAssertEqual(fixture.defaults.data(forKey: "remote_push_state"), sidecar)
        XCTAssertEqual(fixture.defaults.data(forKey: "app_settings_unreadable_backup"), fixture.corrupt)
    }

    private func fixture() async throws -> (
        suite: String, defaults: UserDefaults, repository: SettingsRepository, hosts: [RemoteHost], corrupt: Data
    ) {
        let suite = "SettingsUnreadableTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let repository = SettingsRepository(userDefaults: defaults)
        let hosts = ["host.example.com", "other.example.com"].map { host in
            RemoteHost(host: host, sshUser: "pinemeter", keyPath: "/tmp/test-key",
                       secretReference: UUID().uuidString, pinnedHostKeyFingerprint: "SHA256:fixture")
        }
        var settings = AppSettings.default
        settings.broker.remoteHosts = hosts
        settings.broker.pushGeneration = 77
        try await repository.save(settings)
        let corrupt = Data(#"{"settings_revision":1,"broker":{"remote_hosts":[{"host":42}]}}"#.utf8)
        defaults.set(corrupt, forKey: "app_settings")
        return (suite, defaults, repository, hosts, corrupt)
    }

    private func makeApp(repository: any SettingsRepositoryProtocol) throws -> AppModel {
        let directory = try HealthTestSupport.directory()
        let session = HealthTestSupport.session(status: 500)
        addTeardownBlock {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
        }
        return HealthTestSupport.app(
            directory: directory, session: session, store: BrokerHealthStore(storeDirectory: directory),
            broker: HealthTestSupport.broker(directory: directory), keys: [:], settingsRepository: repository
        )
    }
}

private actor UnreadableSettingsRepository: SettingsRepositoryProtocol {
    private let backing: SettingsRepository
    private let failReplacement: Bool
    private(set) var replacementCalls = 0

    init(backing: SettingsRepository, failReplacement: Bool = false) {
        self.backing = backing
        self.failReplacement = failReplacement
    }

    func load() async -> AppSettings { await backing.load() }
    func save(_ settings: AppSettings) async throws { try await backing.save(settings) }
    func storedSettingsUnreadable() async -> Bool { await backing.storedSettingsUnreadable() }
    func replaceUnreadableSettings(with settings: AppSettings) async throws {
        replacementCalls += 1
        if failReplacement { throw URLError(.cannotWriteToFile) }
        try await backing.replaceUnreadableSettings(with: settings)
    }
    func loadNotificationState() async -> NotificationState { await backing.loadNotificationState() }
    func saveNotificationState(_ state: NotificationState) async throws {
        try await backing.saveNotificationState(state)
    }
}
