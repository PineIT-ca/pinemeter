import Foundation
import Security
import XCTest
@testable import Pinemeter

final class RemoteHostSettingsTests: XCTestCase {
    func testOldSettingsDecodeWithEmptyHostsAndZeroGeneration() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))

        XCTAssertEqual(settings.broker.remoteHosts, [])
        XCTAssertEqual(settings.broker.pushGeneration, 0)
    }

    func testRemoteHostMetadataRoundTripsWithoutSecrets() throws {
        var settings = AppSettings.default
        settings.broker.pushGeneration = 42
        settings.broker.remoteHosts = [
            RemoteHost(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                host: "host.example.com",
                sshUser: "pinemeter",
                keyPath: "~/.ssh/pinemeter",
                secretReference: "secret-reference",
                pinnedHostKeyFingerprint: "SHA256:display-only",
                lastPushAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastPushResult: .failed,
                sanitizedError: "Push failed.",
                observedAt: Date(timeIntervalSince1970: 1_700_000_100),
                observedGeneration: 41
            )
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("private-key-sentinel"))
        XCTAssertFalse(text.contains("host-key-blob-sentinel"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(AppSettings.self, from: data), settings)
        XCTAssertEqual(settings.broker.remoteHosts[0].credentialStatus, .unknown)
    }

    func testValidationRejectsHostUserAndMalformedHostKeys() throws {
        XCTAssertThrowsError(try RemoteHostValidator.normalizedHost("https://host.example.com"))
        XCTAssertThrowsError(try RemoteHostValidator.normalizedHost("host.example.com:22"))
        XCTAssertThrowsError(try RemoteHostValidator.normalizedHost("-oProxyCommand=bad"))
        XCTAssertThrowsError(try RemoteHostValidator.normalizedHost("host example.com"))
        XCTAssertThrowsError(try RemoteHostValidator.normalizedSSHUser("-root"))
        XCTAssertThrowsError(try RemoteHostValidator.normalizedSSHUser("root user"))
        XCTAssertThrowsError(try RemoteHostValidator.parsePinnedHostKey("from=bad ssh-ed25519 AAAA"))
        XCTAssertThrowsError(try RemoteHostValidator.parsePinnedHostKey("ssh-ed25519 AAAA\nssh-rsa AAAA"))
        XCTAssertThrowsError(try RemoteHostValidator.parsePinnedHostKey("ssh-ed25519 AAAA"))

        let rsaBlob = sshString("ssh-rsa") + sshString(Data([1, 0, 1])) + sshString(Data(repeating: 7, count: 32))
        let mismatched = "ssh-ed25519 \(rsaBlob.base64EncodedString())"
        XCTAssertThrowsError(try RemoteHostValidator.parsePinnedHostKey(mismatched))
    }

    func testPinnedKeyParsesEmbeddedTypeAndFingerprint() throws {
        let pin = try RemoteHostValidator.parsePinnedHostKey(validPinnedKey())

        XCTAssertTrue(pin.record.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(pin.fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(pin.fingerprint.hasSuffix("="))
    }

    func testConfigureHostRejectsNormalizedDuplicateWithoutChangingSecrets() async throws {
        let privateKey = "-----BEGIN PRIVATE KEY-----\ncHJpdmF0ZS1rZXktc2VudGluZWw=\n-----END PRIVATE KEY-----\n"
        let keyURL = try writePrivateKey(privateKey)
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }
        let operations = FakeRemoteHostKeychainOperations()
        let secrets = RemoteHostSecretRepository(operations: operations)
        let settings = SettingsRepositoryFake()

        let row = try await secrets.configureHost(
            host: "HOST.EXAMPLE.COM", sshUser: "Pinemeter", keyPath: keyURL.path,
            pinnedHostKey: validPinnedKey(), settingsRepository: settings
        )
        let stored = try await secrets.load(reference: row.secretReference)
        XCTAssertEqual(stored.identity, Data(privateKey.utf8))
        XCTAssertEqual(stored.pinnedHostKey, validPinnedKey())
        let encodedSettings = try JSONEncoder().encode(await settings.load())
        let persistedText = try XCTUnwrap(String(data: encodedSettings, encoding: .utf8))
        XCTAssertFalse(persistedText.contains("private-key-sentinel"))
        XCTAssertFalse(persistedText.contains(validPinnedKey()))
        let writes = operations.writeCount

        do {
            _ = try await secrets.configureHost(
                host: "host.example.com", sshUser: "pinemeter", keyPath: keyURL.path,
                pinnedHostKey: validPinnedKey(), settingsRepository: settings
            )
            XCTFail("Expected duplicate rejection")
        } catch {
            XCTAssertEqual(error as? RemoteHostValidationError, .duplicateHost)
        }
        XCTAssertEqual(operations.writeCount, writes)
        let remoteHostsCount = await settings.load().broker.remoteHosts.count
        XCTAssertEqual(remoteHostsCount, 1)
    }

    func testEncryptedPrivateKeysAreRejectedBeforeKeychainWrite() async throws {
        let keyURL = try writePrivateKey("-----BEGIN ENCRYPTED PRIVATE KEY-----\nYWJjZA==\n-----END ENCRYPTED PRIVATE KEY-----\n")
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }
        let operations = FakeRemoteHostKeychainOperations()
        let secrets = RemoteHostSecretRepository(operations: operations)

        do {
            _ = try await secrets.configureHost(
                host: "host.example.com", sshUser: "pinemeter", keyPath: keyURL.path,
                pinnedHostKey: validPinnedKey(), settingsRepository: SettingsRepositoryFake()
            )
            XCTFail("Expected encrypted key rejection")
        } catch {
            XCTAssertEqual(error as? RemoteHostValidationError, .encryptedPrivateKey)
        }
        XCTAssertEqual(operations.writeCount, 0)
        XCTAssertTrue(operations.items.isEmpty)

        var openssh = Data("openssh-key-v1\0".utf8)
        openssh.append(sshString("aes256-ctr"))
        let opensshURL = try writePrivateKey(
            "-----BEGIN OPENSSH PRIVATE KEY-----\n\(openssh.base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----\n"
        )
        defer { try? FileManager.default.removeItem(at: opensshURL.deletingLastPathComponent()) }
        XCTAssertThrowsError(try RemoteHostValidator.readPrivateKey(at: opensshURL.path)) { error in
            XCTAssertEqual(error as? RemoteHostValidationError, .encryptedPrivateKey)
        }
    }

    func testPrivateKeyPathMustBeAbsoluteReadableRegularFile() throws {
        XCTAssertThrowsError(try RemoteHostValidator.readPrivateKey(at: "relative/key"))
        XCTAssertThrowsError(try RemoteHostValidator.readPrivateKey(at: "/path/that/does/not/exist"))
        XCTAssertThrowsError(try RemoteHostValidator.readPrivateKey(at: FileManager.default.temporaryDirectory.path))
    }

    func testSettingsSaveFailureCleansImportedSecrets() async throws {
        let keyURL = try writePrivateKey("-----BEGIN PRIVATE KEY-----\nYWJjZA==\n-----END PRIVATE KEY-----\n")
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }
        let operations = FakeRemoteHostKeychainOperations()
        let secrets = RemoteHostSecretRepository(operations: operations)
        let settings = FailingSettingsRepository()

        await XCTAssertThrowsErrorAsync {
            _ = try await secrets.configureHost(
                host: "host.example.com", sshUser: "pinemeter", keyPath: keyURL.path,
                pinnedHostKey: self.validPinnedKey(), settingsRepository: settings
            )
        }
        XCTAssertTrue(operations.items.isEmpty)
        XCTAssertEqual(operations.updateCalls, 2, "update-before-add must be used for both items")
        XCTAssertEqual(operations.addCalls, 2)
        XCTAssertEqual(operations.deleteCalls, 2)
    }

    func testStaleSaveCannotLowerReservedGeneration() async throws {
        let suite = "RemoteHostSettingsTests.stale.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        let stale = await repository.load()

        let firstReservation = try await repository.reservePushGeneration()
        XCTAssertEqual(firstReservation, 1)
        try await repository.save(stale)

        let generationAfterStaleSave = await repository.load().broker.pushGeneration
        XCTAssertEqual(generationAfterStaleSave, 1)
    }

    func testReserveAfterFloor() async throws {
        let suite = "RemoteHostSettingsTests.floor.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        var settings = AppSettings.default
        settings.broker.pushGeneration = 2
        try await repository.save(settings)

        let aboveFloor = try await repository.reservePushGeneration(after: 4)
        let aboveLocal = try await repository.reservePushGeneration(after: 1)
        XCTAssertEqual(aboveFloor, 5)
        XCTAssertEqual(aboveLocal, 6)
        let loaded = await SettingsRepository(userDefaults: defaults).load()
        XCTAssertEqual(loaded.broker.pushGeneration, 6)
        let mainBefore = defaults.data(forKey: "app_settings")
        let sidecarBefore = defaults.data(forKey: "remote_push_state")
        do {
            _ = try await repository.reservePushGeneration(after: .max)
            XCTFail("Expected exhaustion")
        } catch {
            XCTAssertEqual(error as? SettingsRepositoryError, .pushGenerationExhausted)
        }
        XCTAssertEqual(defaults.data(forKey: "app_settings"), mainBefore)
        XCTAssertEqual(defaults.data(forKey: "remote_push_state"), sidecarBefore)
    }

    func testGenerationUsesMaximumAcrossMainSidecarAndMemory() async throws {
        let suite = "RemoteHostSettingsTests.maximum.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        for (main, sidecar, expected) in [(2, 7, 7), (9, 3, 9), (1, 2, 9)] {
            defaults.set(Data("{\"broker\":{\"push_generation\":\(main)}}".utf8), forKey: "app_settings")
            defaults.set(Data("{\"version\":1,\"remote_hosts\":[],\"push_generation\":\(sidecar)}".utf8), forKey: "remote_push_state")
            let loaded = await repository.load()
            XCTAssertEqual(loaded.broker.pushGeneration, UInt64(expected))
        }
        let reserved = try await repository.reservePushGeneration()
        XCTAssertEqual(reserved, 10)
        defaults.removeObject(forKey: "app_settings")
        defaults.removeObject(forKey: "remote_push_state")
        let memoryOnly = await repository.load()
        XCTAssertEqual(memoryOnly.broker.pushGeneration, 10)
        try await repository.save(.default)
        let persisted = await SettingsRepository(userDefaults: defaults).load()
        XCTAssertEqual(persisted.broker.pushGeneration, 10)
    }

    func testFloorReservationProtocolFallback() async throws {
        let repository: any SettingsRepositoryProtocol = SettingsRepositoryFake()
        let first = try await repository.reservePushGeneration(after: 4)
        let second = try await repository.reservePushGeneration(after: 0)
        XCTAssertEqual(first, 5)
        XCTAssertEqual(second, 6)
    }

    func testPreferenceRollbackUsesRunningSessionHighWaterMark() async throws {
        let suite = "RemoteHostSettingsTests.rollback.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        let firstReservation = try await repository.reservePushGeneration()
        XCTAssertEqual(firstReservation, 1)
        defaults.removeObject(forKey: "app_settings")

        let secondReservation = try await repository.reservePushGeneration()
        XCTAssertEqual(secondReservation, 2)
        let generationAfterRollback = await repository.load().broker.pushGeneration
        XCTAssertEqual(generationAfterRollback, 2)
    }

    func testConcurrentReservationsAreUniqueAndMonotonic() async throws {
        let suite = "RemoteHostSettingsTests.concurrent.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)

        let values = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for _ in 0..<32 { group.addTask { try await repository.reservePushGeneration() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(values.sorted(), Array(1...32).map(UInt64.init))
        let finalGeneration = await repository.load().broker.pushGeneration
        XCTAssertEqual(finalGeneration, 32)
    }

    func testGenerationExhaustionFailsClosed() async throws {
        let suite = "RemoteHostSettingsTests.exhaustion.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        var settings = AppSettings.default
        settings.broker.pushGeneration = .max
        try await repository.save(settings)

        do {
            _ = try await repository.reservePushGeneration()
            XCTFail("Expected exhaustion")
        } catch {
            XCTAssertEqual(error as? SettingsRepositoryError, .pushGenerationExhausted)
        }
        let generationAfterExhaustion = await repository.load().broker.pushGeneration
        XCTAssertEqual(generationAfterExhaustion, .max)
    }

    func testOldRemoteHostWithoutLoginAlertsDecodes() throws {
        let data = Data("""
        {"broker":{"remote_hosts":[{"id":"11111111-1111-1111-1111-111111111111","host":"host.example.com","ssh_user":"pinemeter","key_path":"/display-only/key","secret_reference":"fixture","pinned_host_key_fingerprint":"SHA256:fixture"}]}}
        """.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.broker.remoteHosts.count, 1)
        XCTAssertEqual(settings.broker.remoteHosts.first?.host, "host.example.com")
        XCTAssertNil(settings.broker.remoteHosts.first?.loginAlerts)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).broker.remoteHosts.isEmpty)
    }

    func testMalformedLoginAlertsKeepHostAndAllSettings() async throws {
        let suite = "PinemeterTests.HostLogin.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings.default
        settings.hasNotificationsEnabled = false
        settings.broker.pushGeneration = 42
        settings.broker.remoteHosts = [loginAlertHost()]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(settings)) as? [String: Any])
        let malformed: [Any] = [42, "x", ["delivered_keys": "x", "refresh_failed_since": [1]], ["delivered_keys": [1, 2]], ["refresh_failed_since": ["claude|user-fixture": "not-a-date"]]]
        for value in malformed {
            var object = original
            var broker = try XCTUnwrap(object["broker"] as? [String: Any])
            var hosts = try XCTUnwrap(broker["remote_hosts"] as? [[String: Any]])
            hosts[0]["login_alerts"] = value
            broker["remote_hosts"] = hosts
            object["broker"] = broker
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "app_settings")
            let loaded = await SettingsRepository(userDefaults: defaults).load()
            XCTAssertEqual(loaded.broker.remoteHosts.count, 1)
            let host = try XCTUnwrap(loaded.broker.remoteHosts.first)
            XCTAssertEqual(host.id, settings.broker.remoteHosts[0].id)
            XCTAssertEqual(host.host, "host.example.com")
            XCTAssertTrue(host.loginAlerts?.deliveredKeys.isEmpty ?? true)
            XCTAssertTrue(host.loginAlerts?.refreshFailedSince.isEmpty ?? true)
            XCTAssertEqual(loaded.broker.pushGeneration, 42)
            XCTAssertFalse(loaded.hasNotificationsEnabled)
            var withoutAlerts = loaded
            withoutAlerts.broker.remoteHosts[0].loginAlerts = nil
            XCTAssertEqual(withoutAlerts, settings, "Malformed alert state must preserve every other setting")
        }
    }

    func testLoginAlertsRoundTrip() async throws {
        let suite = "PinemeterTests.HostLogin.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        var settings = AppSettings.default
        var host = loginAlertHost()
        host.loginAlerts = loginAlertState()
        settings.broker.remoteHosts = [host]
        try await repository.save(settings)
        let loaded = await SettingsRepository(userDefaults: defaults).load()
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.broker.remoteHosts.first?.loginAlerts, host.loginAlerts)
    }

    func testLoginAlertsPayloadCarriesNoCredentialFragments() throws {
        let data = try JSONEncoder().encode(loginAlertState())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for fragment in ["Cookie", "Bearer", "sk-ant-", "session_key", "session_cookie", "access_token", "token", "credential_state", "checked_at", "@"] {
            XCTAssertFalse(text.contains(fragment), "Alert state must not encode \(fragment)")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["delivered_keys", "refresh_failed_since"])
    }

    private func loginAlertHost() -> RemoteHost {
        RemoteHost(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            host: "host.example.com", sshUser: "pinemeter", keyPath: "/display-only/key",
            secretReference: "fixture", pinnedHostKeyFingerprint: "SHA256:fixture"
        )
    }

    private func loginAlertState() -> RemoteHostLoginAlertState {
        var state = RemoteHostLoginAlertState()
        state.deliveredKeys = ["claude|user-fixture|expired", "claude|user-fixture|challenged", "claude|user-fixture|refresh_failed", "claude|user-fixture|expiry|2026-10-30"]
        state.refreshFailedSince = ["claude|user-fixture": Date(timeIntervalSince1970: 1_790_985_600)]
        return state
    }

    private func validPinnedKey() -> String {
        let blob = sshString("ssh-ed25519") + sshString(Data(repeating: 9, count: 32))
        return "ssh-ed25519 \(blob.base64EncodedString())"
    }

    private func writePrivateKey(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("identity")
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

}

private enum TestSettingsError: Error { case saveFailed }

private actor FailingSettingsRepository: SettingsRepositoryProtocol {
    func load() async -> AppSettings { .default }
    func save(_ settings: AppSettings) async throws { throw TestSettingsError.saveFailed }
    func loadNotificationState() async -> NotificationState { NotificationState() }
    func saveNotificationState(_ state: NotificationState) async throws {}
}

private final class FakeRemoteHostKeychainOperations: RemoteHostKeychainOperations, @unchecked Sendable {
    var items: [String: Data] = [:]
    var updateCalls = 0
    var addCalls = 0
    var deleteCalls = 0
    var writeCount: Int { updateCalls + addCalls }

    func update(service: String, account: String, data: Data) -> OSStatus {
        updateCalls += 1
        let key = "\(service)|\(account)"
        guard items[key] != nil else { return errSecItemNotFound }
        items[key] = data
        return errSecSuccess
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        addCalls += 1
        let key = "\(service)|\(account)"
        guard items[key] == nil else { return errSecDuplicateItem }
        items[key] = data
        return errSecSuccess
    }

    func copy(service: String, account: String) -> (OSStatus, Data?) {
        let data = items["\(service)|\(account)"]
        return data.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
    }

    func delete(service: String, account: String) -> OSStatus {
        deleteCalls += 1
        return items.removeValue(forKey: "\(service)|\(account)") == nil ? errSecItemNotFound : errSecSuccess
    }
}

private func sshString(_ value: String) -> Data { sshString(Data(value.utf8)) }

private func sshString(_ value: Data) -> Data {
    var length = UInt32(value.count).bigEndian
    var data = withUnsafeBytes(of: &length) { Data($0) }
    data.append(value)
    return data
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
