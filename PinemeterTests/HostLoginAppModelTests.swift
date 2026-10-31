import Foundation
import Security
import XCTest
@testable import Pinemeter

@MainActor
final class HostLoginAppModelTests: XCTestCase {
    private let hostID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let accountID = "00000000-0000-4000-8000-000000000001"

    func testExpiredHostLoginAlertsOnceEndToEnd() async throws {
        let fixture = try HostLoginSSHFixture(accountID: accountID)
        defer { fixture.cleanup() }
        let repository = SettingsRepositoryFake()
        let notifications = NotificationServiceSpy()
        let model = try await makeModel(fixture: fixture, repository: repository, notifications: notifications)
        await model.bootstrap()
        try await eventually { fixture.commands.contains("pinemeterd status") }
        try await eventually { notifications.sentHostLoginAlerts.count == 1 }
        try await eventually {
            await repository.load().broker.remoteHosts.first?.loginAlerts?.deliveredKeys == ["claude|\(self.accountID)|expired"]
        }
        let delivered = try XCTUnwrap(notifications.sentHostLoginAlerts.first)
        XCTAssertEqual(delivered.hostID, hostID)
        XCTAssertEqual(delivered.hostName, "host.example.com")
        XCTAssertEqual(delivered.alert.provider, .claude)
        XCTAssertEqual(delivered.alert.accountID, accountID)
        XCTAssertEqual(delivered.alert.accountLabel, "Fixture Claude")
        XCTAssertEqual(delivered.alert.cause, .expired)
        let display = try XCTUnwrap(model.remoteHostLogins[hostID])
        XCTAssertTrue(display.isCurrent)
        XCTAssertEqual(display.rows.count, 1)
        XCTAssertEqual(display.rows.first?.login?.state, .expired)
        XCTAssertNotNil(display.rows.first?.login?.lastRefreshAt)
        XCTAssertEqual(Array(fixture.commands.prefix(2)), ["pinemeterd status", "pinemeterd status --sources"])
        let persisted = await repository.load()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(persisted.broker.remoteHosts[0])) as? [String: Any])
        XCTAssertEqual((json["login_alerts"] as? [String: Any])?["delivered_keys"] as? [String], ["claude|\(accountID)|expired"])

        await model.performWakeRefresh()
        try await eventually { fixture.commands.filter { $0 == "pinemeterd status --sources" }.count >= 2 }
        try await eventually { model.remoteHostLogins[self.hostID]?.fetchedAt != display.fetchedAt }
        XCTAssertEqual(notifications.sentHostLoginAlerts.count, 1)
    }

    func testUnavailableSourcesRetainRowsAndAlertState() async throws {
        let fixture = try HostLoginSSHFixture(accountID: accountID)
        defer { fixture.cleanup() }
        let repository = SettingsRepositoryFake()
        let notifications = NotificationServiceSpy()
        let model = try await makeModel(fixture: fixture, repository: repository, notifications: notifications)
        await model.bootstrap()
        try await eventually {
            await repository.load().broker.remoteHosts.first?.loginAlerts?.deliveredKeys == ["claude|\(self.accountID)|expired"]
        }
        let display = try XCTUnwrap(model.remoteHostLogins[hostID])
        let previous = await repository.load().broker.remoteHosts[0].loginAlerts

        await model.applyRemotePushUpdate(.loginSources(hostID: hostID, observation: .unavailable))

        XCTAssertEqual(model.remoteHostLogins[hostID]?.rows, display.rows)
        XCTAssertEqual(model.remoteHostLogins[hostID]?.fetchedAt, display.fetchedAt)
        XCTAssertEqual(model.remoteHostLogins[hostID]?.isCurrent, false)
        XCTAssertEqual(notifications.sentHostLoginAlerts.count, 1)
        let persisted = await repository.load()
        XCTAssertEqual(persisted.broker.remoteHosts[0].loginAlerts, previous)
    }

    func testUndeliveredAlertIsNotRecorded() async throws {
        let fixture = try HostLoginSSHFixture(accountID: accountID)
        defer { fixture.cleanup() }
        let repository = SettingsRepositoryFake()
        let notifications = NotificationServiceSpy()
        notifications.hasPermission = false
        let model = try await makeModel(fixture: fixture, repository: repository, notifications: notifications)
        await model.bootstrap()
        try await eventually { model.remoteHostLogins[self.hostID]?.isCurrent == true }
        let display = try XCTUnwrap(model.remoteHostLogins[hostID])
        let update = RemotePushAttemptUpdate.loginSources(hostID: hostID, observation: .rows(display.rows, fetchedAt: Date()))
        await model.applyRemotePushUpdate(update)
        XCTAssertTrue(notifications.sentHostLoginAlerts.isEmpty)
        var persisted = await repository.load()
        XCTAssertTrue(persisted.broker.remoteHosts[0].loginAlerts?.deliveredKeys.isEmpty ?? true)

        notifications.hasPermission = true
        notifications.hostLoginAlertResult = false
        await model.applyRemotePushUpdate(update)
        XCTAssertTrue(notifications.sentHostLoginAlerts.isEmpty)
        persisted = await repository.load()
        XCTAssertTrue(persisted.broker.remoteHosts[0].loginAlerts?.deliveredKeys.isEmpty ?? true)

        notifications.hostLoginAlertResult = true
        notifications.hostLoginAlertError = HostLoginTestError.unavailable
        await model.applyRemotePushUpdate(update)
        XCTAssertTrue(notifications.sentHostLoginAlerts.isEmpty)
        persisted = await repository.load()
        XCTAssertTrue(persisted.broker.remoteHosts[0].loginAlerts?.deliveredKeys.isEmpty ?? true)

        notifications.hostLoginAlertError = nil
        await model.applyRemotePushUpdate(update)
        XCTAssertEqual(notifications.sentHostLoginAlerts.count, 1)
        persisted = await repository.load()
        XCTAssertEqual(persisted.broker.remoteHosts[0].loginAlerts?.deliveredKeys, ["claude|\(accountID)|expired"])
    }

    func testDisabledNotificationsAreRetriedWhenEnabled() async throws {
        let fixture = try HostLoginSSHFixture(accountID: accountID)
        defer { fixture.cleanup() }
        let repository = SettingsRepositoryFake()
        let notifications = NotificationServiceSpy()
        let model = try await makeModel(fixture: fixture, repository: repository, notifications: notifications,
                                       notificationsEnabled: false)
        await model.bootstrap()
        try await eventually { model.remoteHostLogins[self.hostID]?.isCurrent == true }
        let display = try XCTUnwrap(model.remoteHostLogins[hostID])
        XCTAssertTrue(notifications.sentHostLoginAlerts.isEmpty)
        let disabled = await repository.load()
        XCTAssertTrue(disabled.broker.remoteHosts[0].loginAlerts?.deliveredKeys.isEmpty ?? true)

        model.settings.hasNotificationsEnabled = true
        await model.applyRemotePushUpdate(.loginSources(hostID: hostID, observation: .rows(display.rows, fetchedAt: Date())))
        XCTAssertEqual(notifications.sentHostLoginAlerts.count, 1)
        let persisted = await repository.load()
        XCTAssertEqual(persisted.broker.remoteHosts[0].loginAlerts?.deliveredKeys, ["claude|\(accountID)|expired"])
    }

    func testRecoveredLoginRemovesDeliveredNotification() async throws {
        let fixture = try HostLoginSSHFixture(accountID: accountID)
        defer { fixture.cleanup() }
        let repository = SettingsRepositoryFake()
        let notifications = NotificationServiceSpy()
        let model = try await makeModel(fixture: fixture, repository: repository, notifications: notifications)
        await model.bootstrap()
        try await eventually {
            await repository.load().broker.remoteHosts.first?.loginAlerts?.deliveredKeys == ["claude|\(self.accountID)|expired"]
        }
        let fresh = HostSourcesAccountDTO(
            provider: .claude, id: accountID, verdict: .unpolled, observedAt: nil, source: .hostLogin, hostLogin: true,
            login: HostLoginHealthDTO(state: .fresh, reason: "", refreshExpiresAt: nil, lastRefreshAt: nil)
        )
        await model.applyRemotePushUpdate(.loginSources(hostID: hostID, observation: .rows([fresh], fetchedAt: Date())))
        XCTAssertEqual(notifications.removedHostLoginIdentifiers,
                       [["host-login.00000000-0000-4000-8000-000000000002.claude|\(accountID)|expired"]])
        XCTAssertEqual(notifications.sentHostLoginAlerts.count, 1)
        let persisted = await repository.load()
        XCTAssertEqual(persisted.broker.remoteHosts[0].loginAlerts?.deliveredKeys, [])
    }

    func testRelaunchDoesNotRealert() async throws {
        let suite = "PinemeterTests.HostLogin.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstNotifications = NotificationServiceSpy()
        let first = try await makePersistedModel(defaults: defaults, notifications: firstNotifications)
        let now = Date(timeIntervalSince1970: 1_790_985_600)
        let update = RemotePushAttemptUpdate.loginSources(hostID: hostID, observation: .rows([loginRow(.expired)], fetchedAt: now))
        await first.applyRemotePushUpdate(update)
        XCTAssertEqual(firstNotifications.sentHostLoginAlerts.count, 1)

        let secondNotifications = NotificationServiceSpy()
        let second = try await makePersistedModel(defaults: defaults, notifications: secondNotifications)
        await second.applyRemotePushUpdate(update)
        XCTAssertTrue(secondNotifications.sentHostLoginAlerts.isEmpty)
        XCTAssertEqual(second.settings.broker.remoteHosts[0].loginAlerts?.deliveredKeys, ["claude|\(accountID)|expired"])
    }

    func testRefreshFailedTimerSurvivesRelaunch() async throws {
        let suite = "PinemeterTests.HostLogin.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstNotifications = NotificationServiceSpy()
        let first = try await makePersistedModel(defaults: defaults, notifications: firstNotifications)
        let now = Date(timeIntervalSince1970: 1_790_985_600)
        await first.applyRemotePushUpdate(.loginSources(hostID: hostID, observation: .rows([loginRow(.refreshFailed)], fetchedAt: now)))
        XCTAssertTrue(firstNotifications.sentHostLoginAlerts.isEmpty)
        let timer = first.settings.broker.remoteHosts[0].loginAlerts
        XCTAssertEqual(timer?.refreshFailedSince["claude|\(accountID)"], now)

        let secondNotifications = NotificationServiceSpy()
        let second = try await makePersistedModel(defaults: defaults, notifications: secondNotifications)
        for _ in 0..<3 {
            await second.applyRemotePushUpdate(.loginSources(hostID: hostID, observation: .unavailable))
            XCTAssertEqual(second.settings.broker.remoteHosts[0].loginAlerts, timer)
        }
        XCTAssertTrue(secondNotifications.sentHostLoginAlerts.isEmpty)
        await second.applyRemotePushUpdate(.loginSources(hostID: hostID, observation: .rows([loginRow(.refreshFailed)], fetchedAt: now.addingTimeInterval(86_399))))
        XCTAssertTrue(secondNotifications.sentHostLoginAlerts.isEmpty)
        await second.applyRemotePushUpdate(.loginSources(hostID: hostID, observation: .rows([loginRow(.refreshFailed)], fetchedAt: now.addingTimeInterval(86_400))))
        XCTAssertEqual(secondNotifications.sentHostLoginAlerts.map(\.alert.cause), [.refreshFailed])
    }

    func testExpiryWarningNotRepeatedAfterRelaunch() async throws {
        let suite = "PinemeterTests.HostLogin.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstNotifications = NotificationServiceSpy()
        let first = try await makePersistedModel(defaults: defaults, notifications: firstNotifications)
        let now = Date(timeIntervalSince1970: 1_790_985_600)
        let expiry = now.addingTimeInterval(259_200)
        let update = RemotePushAttemptUpdate.loginSources(hostID: hostID, observation: .rows([loginRow(.fresh, expiresAt: expiry)], fetchedAt: now))
        await first.applyRemotePushUpdate(update)
        XCTAssertEqual(firstNotifications.sentHostLoginAlerts.map(\.alert.cause), [.expiryWarning(expiresAt: expiry)])

        let secondNotifications = NotificationServiceSpy()
        let second = try await makePersistedModel(defaults: defaults, notifications: secondNotifications)
        await second.applyRemotePushUpdate(update)
        XCTAssertTrue(secondNotifications.sentHostLoginAlerts.isEmpty)
        XCTAssertEqual(second.settings.broker.remoteHosts[0].loginAlerts, first.settings.broker.remoteHosts[0].loginAlerts)
    }

    func testRecoveryThenNewCauseRealertsThroughAppModel() async throws {
        let suite = "PinemeterTests.HostLogin.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifications = NotificationServiceSpy()
        let model = try await makePersistedModel(defaults: defaults, notifications: notifications)
        let now = Date(timeIntervalSince1970: 1_790_985_600)
        for state in [HostLoginState.expired, .fresh, .challenged] {
            await model.applyRemotePushUpdate(.loginSources(hostID: hostID, observation: .rows([loginRow(state)], fetchedAt: now)))
            if state == .fresh {
                XCTAssertEqual(notifications.removedHostLoginIdentifiers, [[HostLoginAlert.notificationIdentifier(hostID: hostID, key: "claude|\(accountID)|expired")]])
                let persisted = await SettingsRepository(userDefaults: defaults).load()
                XCTAssertEqual(persisted.broker.remoteHosts[0].loginAlerts?.deliveredKeys, [])
            }
        }
        XCTAssertEqual(notifications.sentHostLoginAlerts.map(\.alert.cause), [.expired, .challenged])
        let persisted = await SettingsRepository(userDefaults: defaults).load()
        XCTAssertEqual(persisted.broker.remoteHosts[0].loginAlerts?.deliveredKeys, ["claude|\(accountID)|challenged"])
    }

    private func loginRow(_ state: HostLoginState, expiresAt: Date? = nil) -> HostSourcesAccountDTO {
        HostSourcesAccountDTO(
            provider: .claude, id: accountID, verdict: .unpolled, observedAt: nil, source: .hostLogin, hostLogin: true,
            login: HostLoginHealthDTO(state: state, reason: "", refreshExpiresAt: expiresAt, lastRefreshAt: nil)
        )
    }

    private func makePersistedModel(defaults: UserDefaults, notifications: NotificationServiceSpy) async throws -> AppModel {
        let repository = SettingsRepository(userDefaults: defaults)
        if defaults.data(forKey: "app_settings") == nil {
            var settings = AppSettings.default
            settings.hasNotificationsEnabled = true
            settings.broker.remoteHosts = [RemoteHost(
                id: hostID, host: "host.example.com", sshUser: "pinemeter",
                keyPath: "/display-only/key", secretReference: "fixture", pinnedHostKeyFingerprint: "SHA256:fixture"
            )]
            try await repository.save(settings)
        }
        let coordinator = RemotePushCoordinator(
            loadSource: { .empty }, reserveGeneration: { 1 }, buildBundle: { _, _, _ in Data() },
            send: { _, _ in }, recordUpdate: { _ in }
        )
        let model = AppModel(
            settingsRepository: repository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(HostLoginTestError.unavailable)),
            chatGPTSessionRepository: MissingLoginChatGPTRepository(),
            geminiAPIKeyRepository: MissingLoginGeminiRepository(),
            notificationService: notifications,
            sessionKeyImportService: SessionKeyImportServiceStub(result: .failure(HostLoginTestError.unavailable)),
            runningBrowserSources: { [] }, codexWorkspaceResolver: { nil }, browserLoginPrompt: { _ in },
            t3InstanceDiscovery: T3InstanceDiscoveryFake(),
            remoteHostSecretRepository: RemoteHostSecretRepository(operations: HostLoginSecretOperations()),
            remotePushCoordinator: coordinator
        )
        await model.bootstrap()
        return model
    }

    private func makeModel(
        fixture: HostLoginSSHFixture,
        repository: SettingsRepositoryFake,
        notifications: NotificationServiceSpy,
        notificationsEnabled: Bool = true
    ) async throws -> AppModel {
        var settings = AppSettings.default
        settings.hasNotificationsEnabled = notificationsEnabled
        settings.broker.remoteHosts = [RemoteHost(
            id: hostID, host: "host.example.com", sshUser: "pinemeter",
            keyPath: "/display-only/key", secretReference: "fixture",
            pinnedHostKeyFingerprint: "SHA256:fixture"
        )]
        settings.claudeAccounts = [ClaudeAccount(
            id: accountID, label: "Fixture Claude", organizationId: UUID(uuidString: accountID)!,
            keychainAccount: accountID
        )]
        try await repository.save(settings)
        let secrets = RemoteHostSecretRepository(operations: HostLoginSecretOperations())
        return AppModel(
            settingsRepository: repository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(HostLoginTestError.unavailable)),
            chatGPTSessionRepository: MissingLoginChatGPTRepository(),
            geminiAPIKeyRepository: MissingLoginGeminiRepository(),
            notificationService: notifications,
            sessionKeyImportService: SessionKeyImportServiceStub(result: .failure(HostLoginTestError.unavailable)),
            runningBrowserSources: { [] },
            codexWorkspaceResolver: { nil },
            browserLoginPrompt: { _ in },
            t3InstanceDiscovery: T3InstanceDiscoveryFake(),
            remoteHostSecretRepository: secrets,
            remoteSSHTransport: RemoteSSHTransport(secretRepository: secrets, testing: fixture.configuration)
        )
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        // A refresh performs bare status and sources SSH calls, each with a 30-second fixture budget.
        let deadline = Date().addingTimeInterval(65)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for host login update")
        throw HostLoginTestError.unavailable
    }
}

private enum HostLoginTestError: Error { case unavailable }

private actor MissingLoginChatGPTRepository: ChatGPTSessionRepositoryProtocol {
    func save(_ session: ChatGPTSession, account: String) {}
    func load(account: String) throws -> ChatGPTSession { throw ChatGPTSessionRepositoryError.notFound }
    func validate(account: String) -> ChatGPTSessionAcquisitionStatus {
        .init(state: .missing, lastErrorCategory: .notFound)
    }
    func clear(account: String) {}
}

private actor MissingLoginGeminiRepository: GeminiAPIKeyRepositoryProtocol {
    func save(_ apiKey: GeminiAPIKey, account: String) {}
    func load(account: String) throws -> GeminiAPIKey { throw GeminiAPIKeyRepositoryError.notFound }
    func validate(account: String) -> GeminiAPIKeyAcquisitionStatus {
        .init(state: .missing, lastErrorCategory: .notFound)
    }
    func clear(account: String) {}
}

private final class HostLoginSecretOperations: RemoteHostKeychainOperations, @unchecked Sendable {
    func update(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
    func add(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
    func delete(service: String, account: String) -> OSStatus { errSecSuccess }
    func copy(service: String, account: String) -> (OSStatus, Data?) {
        if service.contains("identity") { return (errSecSuccess, Data("FAKE-identity".utf8)) }
        func sshString(_ data: Data) -> Data {
            var length = UInt32(data.count).bigEndian
            return withUnsafeBytes(of: &length) { Data($0) } + data
        }
        let blob = sshString(Data("ssh-ed25519".utf8)) + sshString(Data(repeating: 4, count: 32))
        return (errSecSuccess, Data("ssh-ed25519 \(blob.base64EncodedString())".utf8))
    }
}

private final class HostLoginSSHFixture {
    let root: URL
    let configuration: RemoteSSHTransportTestConfiguration
    private let callLog: URL

    var commands: [String] {
        ((try? String(contentsOf: callLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    init(accountID: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HostLoginTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        callLog = root.appendingPathComponent("calls")
        let executable = root.appendingPathComponent("ssh")
        let script = """
        #!/bin/sh
        cat >/dev/null
        for argument do command="$argument"; done
        printf '%s\\n' "$command" >> '\(callLog.path)'
        case "$command" in
          'pinemeterd status')
            printf '%s\\n' '{"schemaVersion":1,"acceptedGeneration":0,"observedGeneration":0,"observedAt":null,"accounts":[]}' ;;
          'pinemeterd status --sources')
            printf '%s\\n' '{"schemaVersion":2,"acceptedGeneration":0,"accounts":[{"provider":"claude","id":"\(accountID)","verdict":"unpolled","observedAt":null,"source":"host_login","hostLogin":true,"login":{"state":"expired","reason":"invalid_grant","refreshExpiresAt":null,"lastRefreshAt":"2026-10-01T12:00:00.123456789Z"}}]}' ;;
          *) exit 126 ;;
        esac
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        configuration = RemoteSSHTransportTestConfiguration(
            executableURL: executable, operationRoot: root, timeoutNanoseconds: 30_000_000_000
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
