import Security
import XCTest
@testable import Pinemeter

@MainActor
final class RemoteHostsViewTests: XCTestCase {
    func testRemoteHostsPaneFollowsNetworkAndRestoresSelection() {
        let panes = BrokerWindowView.Pane.allCases
        XCTAssertEqual(panes.firstIndex(of: .remoteHosts), panes.firstIndex(of: .network).map { $0 + 1 })

        let defaults = TestSafeDefaults.standardOrIsolated
        let previous = defaults.string(forKey: BrokerWindowView.paneDefaultsKey)
        defer { defaults.set(previous, forKey: BrokerWindowView.paneDefaultsKey) }
        defaults.set(BrokerWindowView.Pane.remoteHosts.rawValue, forKey: BrokerWindowView.paneDefaultsKey)
        XCTAssertEqual(BrokerWindowView.restoredPane(), .remoteHosts)
    }

    func testDraftValidationRequiresConfirmationAndRelevantChangesResetIt() throws {
        let keyURL = try writePrivateKey()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }
        let pinnedKey = validPinnedKey()
        var draft = RemoteHostDraft()
        draft.host = "host.example.com"
        draft.sshUser = "pinemeter"
        draft.keyPath = keyURL.path
        draft.pinnedHostKey = pinnedKey
        XCTAssertNotNil(draft.fingerprint)
        XCTAssertFalse(draft.isValid(existing: []))

        draft.isFingerprintConfirmed = true
        XCTAssertTrue(draft.isValid(existing: []))
        draft.host = "other.example.com"
        XCTAssertFalse(draft.isFingerprintConfirmed)

        draft.isFingerprintConfirmed = true
        draft.keyPath = keyURL.path + ".other"
        XCTAssertFalse(draft.isFingerprintConfirmed)

        draft.keyPath = keyURL.path
        draft.isFingerprintConfirmed = true
        draft.pinnedHostKey = pinnedKey + " "
        XCTAssertFalse(draft.isFingerprintConfirmed)
    }

    func testDuplicateAndUnreadableKeyErrorsUseLockedCopy() throws {
        let host = RemoteHost(
            host: "host.example.com",
            sshUser: "pinemeter",
            keyPath: "/tmp/id",
            secretReference: "reference",
            pinnedHostKeyFingerprint: "SHA256:fixture"
        )
        var draft = RemoteHostDraft()
        draft.host = host.host.uppercased()
        draft.sshUser = host.sshUser
        draft.keyPath = "/missing/key"
        draft.pinnedHostKey = validPinnedKey()
        XCTAssertEqual(
            draft.validationError(existing: []),
            "Cannot read the SSH key. Check the path and permissions."
        )

        let keyURL = try writePrivateKey()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }
        draft.keyPath = keyURL.path
        XCTAssertEqual(
            draft.validationError(existing: [host]),
            "This SSH user and host are already configured."
        )
    }

    func testAddFailureCleansSecretsAndLeavesSettingsUnchanged() async throws {
        let keyURL = try writePrivateKey()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }
        let operations = RemoteHostsKeychainOperations()
        let settingsRepository = RemoteHostsSettingsRepository(failSaves: true)
        let appModel = makeAppModel(
            settingsRepository: settingsRepository,
            secretRepository: RemoteHostSecretRepository(operations: operations)
        )

        do {
            try await appModel.addRemoteHost(
                host: "host.example.com",
                sshUser: "pinemeter",
                keyPath: keyURL.path,
                pinnedHostKey: validPinnedKey()
            )
            XCTFail("save failure must reject the host")
        } catch {}

        let persisted = await settingsRepository.load()
        XCTAssertTrue(persisted.broker.remoteHosts.isEmpty)
        XCTAssertTrue(operations.items.isEmpty)
    }

    func testRemoveSaveFailureRetainsRowSecretsAndOriginalKey() async throws {
        let keyURL = try writePrivateKey()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }
        let operations = RemoteHostsKeychainOperations()
        let settingsRepository = RemoteHostsSettingsRepository()
        let secretRepository = RemoteHostSecretRepository(operations: operations)
        let appModel = makeAppModel(
            settingsRepository: settingsRepository,
            secretRepository: secretRepository
        )
        let host = try await appModel.addRemoteHost(
            host: "host.example.com",
            sshUser: "pinemeter",
            keyPath: keyURL.path,
            pinnedHostKey: validPinnedKey()
        )
        await settingsRepository.setFailSaves(true)

        do {
            try await appModel.removeRemoteHost(id: host.id)
            XCTFail("save failure must retain the host")
        } catch {}

        XCTAssertEqual(appModel.settings.broker.remoteHosts, [host])
        let storedSecret = try await secretRepository.load(reference: host.secretReference)
        XCTAssertFalse(storedSecret.identity.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
    }

    func testManualAndAutomaticPushShareBusyAndHistoricalState() async throws {
        let host = RemoteHost(
            host: "host.example.com",
            sshUser: "pinemeter",
            keyPath: "/tmp/id",
            secretReference: "reference",
            pinnedHostKeyFingerprint: "SHA256:fixture",
            lastPushAt: Date(timeIntervalSince1970: 10),
            lastPushResult: .failed,
            sanitizedError: "Previous failure",
            credentialStatus: .challenged
        )
        let settingsRepository = RemoteHostsSettingsRepository()
        var initial = AppSettings.default
        initial.broker.remoteHosts = [host]
        try await settingsRepository.save(initial)
        let harness = RemoteHostsPushHarness(host: host)
        let sleeper = RemoteHostsSleeper()
        let modelReference = RemoteHostsAppModelReference()
        let coordinator = RemotePushCoordinator(
            loadSource: { await harness.source() },
            reserveGeneration: { try await settingsRepository.reservePushGeneration() },
            buildBundle: { _, _, _ in Data("bundle".utf8) },
            send: { _, _ in try await harness.send() },
            recordUpdate: { update in await modelReference.record(update) },
            sleep: { duration in try await sleeper.sleep(duration) }
        )
        let appModel = makeAppModel(
            settingsRepository: settingsRepository,
            secretRepository: RemoteHostSecretRepository(operations: RemoteHostsKeychainOperations()),
            coordinator: coordinator
        )
        appModel.settings = initial
        modelReference.value = appModel

        await appModel.pushRemoteHostNow(id: host.id)
        try await eventually { appModel.remoteHostPushInProgress.contains(host.id) }
        XCTAssertEqual(appModel.settings.broker.remoteHosts[0].lastPushResult, .failed)
        XCTAssertEqual(appModel.settings.broker.remoteHosts[0].sanitizedError, "Previous failure")
        await harness.releaseSend()
        try await eventually { !appModel.remoteHostPushInProgress.contains(host.id) }
        XCTAssertEqual(appModel.settings.broker.remoteHosts[0].lastPushResult, .succeeded)
        XCTAssertEqual(appModel.settings.broker.remoteHosts[0].credentialStatus, .unknown)

        for _ in 0..<20 { await Task.yield() }
        await harness.blockNextSend()
        appModel.scheduleRemotePush()
        try await eventually { await sleeper.pendingCount == 1 }
        await sleeper.releaseAll()
        try await eventually { appModel.remoteHostPushInProgress.contains(host.id) }
        await harness.releaseSend()
        try await eventually { !appModel.remoteHostPushInProgress.contains(host.id) }
        let sendCount = await harness.sendCount
        XCTAssertEqual(sendCount, 2)
    }

    private func makeAppModel(
        settingsRepository: any SettingsRepositoryProtocol,
        secretRepository: RemoteHostSecretRepository,
        coordinator: RemotePushCoordinator? = nil
    ) -> AppModel {
        AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(RemoteHostsTestError.unavailable)),
            notificationService: NotificationServiceSpy(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake(),
            remoteHostSecretRepository: secretRepository,
            remotePushCoordinator: coordinator
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Condition was not met", file: file, line: line)
    }

    private func validPinnedKey() -> String {
        let blob = sshString("ssh-ed25519") + sshString(Data(repeating: 9, count: 32))
        return "ssh-ed25519 \(blob.base64EncodedString())"
    }

    private func writePrivateKey() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("identity")
        let value = "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----\n"
        try Data(value.utf8).write(to: url, options: .atomic)
        return url
    }

    private func sshString(_ value: String) -> Data { sshString(Data(value.utf8)) }

    private func sshString(_ value: Data) -> Data {
        var length = UInt32(value.count).bigEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(value)
        return data
    }
}

private enum RemoteHostsTestError: Error {
    case unavailable
    case saveFailed
}

private actor RemoteHostsSettingsRepository: SettingsRepositoryProtocol {
    private var settings = AppSettings.default
    private var failSaves: Bool

    init(failSaves: Bool = false) {
        self.failSaves = failSaves
    }

    func setFailSaves(_ value: Bool) { failSaves = value }
    func load() -> AppSettings { settings }

    func save(_ settings: AppSettings) throws {
        guard !failSaves else { throw RemoteHostsTestError.saveFailed }
        var settings = settings
        settings.broker.pushGeneration = max(
            settings.broker.pushGeneration,
            self.settings.broker.pushGeneration
        )
        self.settings = settings
    }

    func reservePushGeneration() throws -> UInt64 {
        settings.broker.pushGeneration += 1
        return settings.broker.pushGeneration
    }

    func loadNotificationState() -> NotificationState { NotificationState() }
    func saveNotificationState(_ state: NotificationState) {}
}

private final class RemoteHostsKeychainOperations: RemoteHostKeychainOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    var items: [String: Data] { lock.withLock { storage } }

    func update(service: String, account: String, data: Data) -> OSStatus {
        lock.withLock {
            let key = "\(service)|\(account)"
            guard storage[key] != nil else { return errSecItemNotFound }
            storage[key] = data
            return errSecSuccess
        }
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        lock.withLock {
            let key = "\(service)|\(account)"
            guard storage[key] == nil else { return errSecDuplicateItem }
            storage[key] = data
            return errSecSuccess
        }
    }

    func copy(service: String, account: String) -> (OSStatus, Data?) {
        lock.withLock {
            let data = storage["\(service)|\(account)"]
            return data.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
    }

    func delete(service: String, account: String) -> OSStatus {
        lock.withLock {
            storage.removeValue(forKey: "\(service)|\(account)") == nil
                ? errSecItemNotFound : errSecSuccess
        }
    }
}

private actor RemoteHostsPushHarness {
    private let host: RemoteHost
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var sendCount = 0
    private var shouldBlock = true
    private var releaseRequested = false

    init(host: RemoteHost) { self.host = host }

    func source() -> RemotePushSourceSnapshot {
        RemotePushSourceSnapshot(
            hosts: [host],
            inventory: RemotePushAccountInventory(claude: [], chatGPT: [], gemini: []),
            policy: .default,
            cooldowns: [:],
            oracleSnapshot: nil
        )
    }

    func send() async throws {
        sendCount += 1
        if shouldBlock {
            if releaseRequested {
                releaseRequested = false
            } else {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        shouldBlock = false
    }

    func blockNextSend() { shouldBlock = true }

    func releaseSend() {
        if let continuation {
            continuation.resume()
            self.continuation = nil
        } else {
            releaseRequested = true
        }
    }
}

private actor RemoteHostsSleeper {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    var pendingCount: Int { continuations.count }

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class RemoteHostsAppModelReference {
    weak var value: AppModel?

    func record(_ update: RemotePushAttemptUpdate) async {
        await value?.applyRemotePushUpdate(update)
    }
}
