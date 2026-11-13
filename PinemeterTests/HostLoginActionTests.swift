import XCTest
import Security
@testable import Pinemeter

@MainActor
final class HostLoginActionTests: XCTestCase {
    private let hostID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let claudeID = "00000000-0000-4000-8000-000000000003"

    func testStartHostLoginBuildsRequestFromSettingsAndSources() async throws {
        let launcher = RecordingHostLoginLauncher()
        let model = try await makeModel(launcher: launcher)
        await report(model, rows: [row(.claude, claudeID), row(.chatgpt, "user-fixture")])
        let codex = await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-fixture")
        let claude = await model.startHostLogin(hostID: hostID, provider: .claude, accountID: claudeID)
        XCTAssertTrue(codex)
        XCTAssertTrue(claude)
        let requests = await launcher.requests
        XCTAssertEqual(requests, [request(.chatgpt, "user-fixture"), request(.claude, claudeID)])
        XCTAssertNil(model.remoteHostLoginErrors[hostID])
    }

    func testStartHostLoginReadsOnlyThePinnedHostKey() async throws {
        let secrets = LoginActionSecretOperations()
        let model = try await makeModel(secrets: secrets)
        await report(model, rows: [row(.chatgpt, "user-fixture")])
        let started = await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-fixture")
        XCTAssertTrue(started)
        XCTAssertEqual(secrets.copiedServices, ["ca.pineit.pinemeter.remote-host.pin"])
    }

    func testStartHostLoginRefusesUnknownHostLegacyAndUnlistedAccounts() async throws {
        let launcher = RecordingHostLoginLauncher()
        let model = try await makeModel(launcher: launcher)
        await report(model, rows: [row(.chatgpt, "legacy-chatgpt"), row(.claude, "user-fixture")])
        let unknown = UUID()
        let missing = await model.startHostLogin(hostID: unknown, provider: .chatgpt, accountID: "user-fixture")
        XCTAssertFalse(missing)
        XCTAssertEqual(model.remoteHostLoginErrors[unknown], "This host is no longer configured.")
        for (provider, account) in [(HostLoginProvider.chatgpt, "legacy-chatgpt"), (.chatgpt, "user-absent"), (.claude, "user-fixture")] {
            let started = await model.startHostLogin(hostID: hostID, provider: provider, accountID: account)
            XCTAssertFalse(started)
            XCTAssertEqual(model.remoteHostLoginErrors[hostID], "This account cannot be logged in from this Mac.")
        }
        let refusedRequests = await launcher.requests
        XCTAssertTrue(refusedRequests.isEmpty)
        var delivered = RemoteHostLoginAlertState()
        delivered.deliveredKeys = ["chatgpt|user-fixture|expired"]
        let relaunched = try await makeModel(launcher: launcher, delivered: delivered)
        let started = await relaunched.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-fixture")
        XCTAssertTrue(started)
    }

    func testReportedRowsRemainEligibleWhenSourcesBecomeUnavailable() async throws {
        var delivered = RemoteHostLoginAlertState()
        delivered.deliveredKeys = ["chatgpt|user-old|expired"]
        let launcher = RecordingHostLoginLauncher()
        let model = try await makeModel(launcher: launcher, delivered: delivered)
        await report(model, rows: [row(.chatgpt, "user-fixture")])
        let old = await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-old")
        XCTAssertFalse(old)
        await model.applyRemotePushUpdate(.loginSources(hostID: hostID, observation: .unavailable))
        let stale = await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-fixture")
        XCTAssertTrue(stale)
        let requests = await launcher.requests
        XCTAssertEqual(requests, [request(.chatgpt, "user-fixture")])
    }

    func testDeliveredAlertAllowsLoginAfterUnavailableFirstSourcesFetch() async throws {
        var delivered = RemoteHostLoginAlertState()
        delivered.deliveredKeys = ["chatgpt|user-fixture|expired"]
        let launcher = RecordingHostLoginLauncher()
        let model = try await makeModel(launcher: launcher, delivered: delivered)
        await model.applyRemotePushUpdate(.loginSources(hostID: hostID, observation: .unavailable))
        let display = try XCTUnwrap(model.remoteHostLogins[hostID])
        XCTAssertFalse(display.isCurrent)
        XCTAssertTrue(display.rows.isEmpty)

        let started = await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-fixture")
        XCTAssertTrue(started)
        let unlisted = await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-absent")
        XCTAssertFalse(unlisted)
        let requests = await launcher.requests
        XCTAssertEqual(requests, [request(.chatgpt, "user-fixture")])
    }

    func testCurrentEmptySourcesDoNotUseDeliveredAlertFallback() async throws {
        var delivered = RemoteHostLoginAlertState()
        delivered.deliveredKeys = ["chatgpt|user-fixture|expired"]
        let launcher = RecordingHostLoginLauncher()
        let model = try await makeModel(launcher: launcher, delivered: delivered)
        // A current inventory supersedes saved alert keys, even before they are pruned.
        await report(model, rows: [])
        model.settings.broker.remoteHosts[0].loginAlerts = delivered
        let started = await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-fixture")
        XCTAssertFalse(started)
        let requests = await launcher.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testMissingAndInvalidPinsNeverLaunch() async throws {
        for (status, pin) in [(errSecItemNotFound, Data()), (errSecSuccess, Data("FAKE-invalid-pin".utf8)), (errSecSuccess, Data([0xff]))] {
            let secrets = LoginActionSecretOperations()
            secrets.status = status
            secrets.pin = pin
            let launcher = RecordingHostLoginLauncher()
            let model = try await makeModel(launcher: launcher, secrets: secrets)
            await report(model, rows: [row(.chatgpt, "user-fixture")])
            let started = await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-fixture")
            XCTAssertFalse(started)
            XCTAssertEqual(model.remoteHostLoginErrors[hostID], "The pinned host key for this host is missing. Remove and add the host again.")
            let requests = await launcher.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testLaunchFailureIsReportedAndClearedOnSuccess() async throws {
        let launcher = RecordingHostLoginLauncher()
        await launcher.setError(.keyUnreadable(path: "/fixture/id_ed25519"))
        let model = try await makeModel(launcher: launcher)
        await report(model, rows: [row(.chatgpt, "user-fixture")])
        let failed = await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-fixture")
        XCTAssertFalse(failed)
        XCTAssertEqual(model.remoteHostLoginErrors[hostID], HostLoginLaunchError.keyUnreadable(path: "/fixture/id_ed25519").errorDescription)
        await launcher.setError(nil)
        let started = await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-fixture")
        XCTAssertTrue(started)
        XCTAssertNil(model.remoteHostLoginErrors[hostID])
    }

    func testConcurrentDuplicateLaunchIsRefused() async throws {
        let launcher = RecordingHostLoginLauncher()
        await launcher.setPaused(true)
        let model = try await makeModel(launcher: launcher)
        await report(model, rows: [row(.chatgpt, "user-fixture")])
        let first = Task { await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-fixture") }
        try await eventually { await launcher.requests.count == 1 }
        let duplicate = await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-fixture")
        XCTAssertFalse(duplicate)
        XCTAssertEqual(model.remoteHostLoginErrors[hostID], "A login session is already opening for this account.")
        let requests = await launcher.requests
        XCTAssertEqual(requests.count, 1)
        await launcher.resume()
        let started = await first.value
        XCTAssertTrue(started)
        XCTAssertNil(model.remoteHostLoginErrors[hostID])
    }

    func testDefaultLauncherIsInertUnderXCTest() {
        XCTAssertTrue(AppModel.defaultHostLoginLauncher() is NullHostLoginLauncher)
    }

    func testBootstrapSweepsStaleLoginDirectories() async throws {
        let root = FileManager.default.temporaryDirectory
        let old = root.appendingPathComponent("pinemeter-login-\(UUID())")
        let fresh = root.appendingPathComponent("pinemeter-login-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: fresh)
        }
        for directory in [old, fresh] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
        _ = try await makeModel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testRemovingHostClearsLoginStateAndBanners() async throws {
        let notifications = NotificationServiceSpy()
        let model = try await makeModel(notifications: notifications)
        await report(model, rows: [row(.chatgpt, "user-fixture", state: .expired)])
        XCTAssertEqual(notifications.sentHostLoginAlerts.count, 1)
        _ = await model.startHostLogin(hostID: hostID, provider: .chatgpt, accountID: "user-absent")
        try await model.removeRemoteHost(id: hostID)
        XCTAssertNil(model.remoteHostLogins[hostID])
        XCTAssertNil(model.remoteHostLoginErrors[hostID])
        XCTAssertEqual(notifications.removedHostLoginIdentifiers, [[HostLoginAlert.notificationIdentifier(hostID: hostID, key: "chatgpt|user-fixture|expired")]])
    }

    func testRemovingHostDuringAlertDeliveryRemovesLateBanner() async throws {
        let notifications = NotificationServiceSpy()
        var resumeDelivery: CheckedContinuation<Void, Never>?
        notifications.beforeHostLoginAlertDelivery = {
            await withCheckedContinuation { resumeDelivery = $0 }
        }
        let model = try await makeModel(notifications: notifications)
        let delivery = Task { await report(model, rows: [row(.chatgpt, "user-fixture", state: .expired)]) }
        try await eventually { resumeDelivery != nil }
        try await model.removeRemoteHost(id: hostID)
        resumeDelivery?.resume()
        await delivery.value

        XCTAssertEqual(notifications.sentHostLoginAlerts.count, 1)
        XCTAssertEqual(notifications.removedHostLoginIdentifiers, [[
            "host-login.00000000-0000-4000-8000-000000000002.chatgpt|user-fixture|expired",
        ]])
        XCTAssertFalse(model.settings.broker.remoteHosts.contains { $0.id == hostID })
        XCTAssertNil(model.remoteHostLogins[hostID])
    }

    func testStartHostLoginNotificationRunsLauncher() async throws {
        let launcher = RecordingHostLoginLauncher()
        let model = try await makeModel(launcher: launcher)
        await report(model, rows: [row(.chatgpt, "user-fixture")])
        NotificationCenter.default.post(name: .startHostLogin,
                                        object: HostLoginRequest(hostID: hostID, provider: .chatgpt, accountID: "user-fixture"))
        try await eventually { await launcher.requests.count == 1 }
        let requests = await launcher.requests
        XCTAssertEqual(requests, [request(.chatgpt, "user-fixture")])
        XCTAssertNil(model.remoteHostLoginErrors[hostID])
    }

    func testFailedNotificationLoginOpensRemoteHostsPane() async throws {
        let defaults = TestSafeDefaults.standardOrIsolated
        let previous = defaults.object(forKey: BrokerWindowView.paneDefaultsKey)
        defer { defaults.set(previous, forKey: BrokerWindowView.paneDefaultsKey) }
        let launcher = RecordingHostLoginLauncher()
        await launcher.setError(.openFailed)
        let model = try await makeModel(launcher: launcher)
        await report(model, rows: [row(.chatgpt, "user-fixture")])
        var pane: String?
        var opened = false
        let show = NotificationCenter.default.addObserver(forName: .showBrokerPane, object: nil, queue: nil) {
            pane = $0.userInfo?["pane"] as? String
        }
        let open = NotificationCenter.default.addObserver(forName: .openBrokerSettings, object: nil, queue: nil) { _ in opened = true }
        defer {
            NotificationCenter.default.removeObserver(show)
            NotificationCenter.default.removeObserver(open)
        }
        NotificationCenter.default.post(name: .startHostLogin,
                                        object: HostLoginRequest(hostID: hostID, provider: .chatgpt, accountID: "user-fixture"))
        try await eventually {
            pane == "remoteHosts" && model.remoteHostLoginErrors[self.hostID] == HostLoginLaunchError.openFailed.errorDescription
        }
        XCTAssertTrue(opened)
        XCTAssertEqual(model.remoteHostLoginErrors[hostID], HostLoginLaunchError.openFailed.errorDescription)
        XCTAssertEqual(defaults.string(forKey: BrokerWindowView.paneDefaultsKey), "remoteHosts")
    }

    private func request(_ provider: HostLoginProvider, _ account: String) -> HostLoginLaunchRequest {
        HostLoginLaunchRequest(hostID: hostID, host: "host.example.com", sshUser: "pinemeter", keyPath: "/fixture/id_ed25519",
                               pinnedHostKeyRecord: LoginActionSecretOperations.pinRecord, loginWord: provider == .claude ? "claude" : "codex", accountID: account)
    }

    private func row(_ provider: HostLoginProvider, _ account: String, state: HostLoginState = .fresh) -> HostSourcesAccountDTO {
        HostSourcesAccountDTO(provider: provider, id: account, verdict: .unpolled, observedAt: nil, source: .hostLogin,
                              hostLogin: true, login: HostLoginHealthDTO(state: state, reason: "", refreshExpiresAt: nil, lastRefreshAt: nil))
    }

    private func report(_ model: AppModel, rows: [HostSourcesAccountDTO]) async {
        await model.applyRemotePushUpdate(.loginSources(hostID: hostID, observation: .rows(rows, fetchedAt: Date())))
    }

    private func makeModel(launcher: RecordingHostLoginLauncher = RecordingHostLoginLauncher(),
                           secrets: LoginActionSecretOperations = LoginActionSecretOperations(),
                           notifications: NotificationServiceSpy? = nil,
                           delivered: RemoteHostLoginAlertState? = nil) async throws -> AppModel {
        let repository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.hasNotificationsEnabled = true
        settings.broker.remoteHosts = [RemoteHost(id: hostID, host: "host.example.com", sshUser: "pinemeter",
                                                 keyPath: "/fixture/id_ed25519", secretReference: "FAKE-reference",
                                                 pinnedHostKeyFingerprint: "SHA256:fixture", loginAlerts: delivered)]
        try await repository.save(settings)
        let coordinator = RemotePushCoordinator(loadSource: { .empty }, reserveGeneration: { 1 },
                                                buildBundle: { _, _, _ in Data() }, send: { _, _ in }, recordUpdate: { _ in })
        let model = AppModel(settingsRepository: repository, keychainRepository: KeychainRepositoryFake(),
                             usageService: UsageServiceStub(fetchUsageResult: .failure(LoginActionTestError.unavailable)),
                             chatGPTSessionRepository: LoginActionMissingChatGPTRepository(), geminiAPIKeyRepository: LoginActionMissingGeminiRepository(),
                             notificationService: notifications ?? NotificationServiceSpy(),
                             sessionKeyImportService: SessionKeyImportServiceStub(result: .failure(LoginActionTestError.unavailable)),
                             runningBrowserSources: { [] }, codexWorkspaceResolver: { nil }, browserLoginPrompt: { _ in },
                             t3InstanceDiscovery: T3InstanceDiscoveryFake(), remoteHostSecretRepository: RemoteHostSecretRepository(operations: secrets),
                             remotePushCoordinator: coordinator, hostLoginLauncher: launcher)
        await model.bootstrap()
        return model
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for host login action")
        throw LoginActionTestError.unavailable
    }
}

private actor RecordingHostLoginLauncher: HostLoginLaunching {
    private(set) var requests: [HostLoginLaunchRequest] = []
    private var error: HostLoginLaunchError?
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    func setError(_ error: HostLoginLaunchError?) { self.error = error }
    func setPaused(_ paused: Bool) { self.paused = paused }
    func resume() { paused = false; continuation?.resume(); continuation = nil }
    func launch(_ request: HostLoginLaunchRequest) async throws {
        requests.append(request)
        if paused { await withCheckedContinuation { continuation = $0 } }
        if let error { throw error }
    }
}

private final class LoginActionSecretOperations: RemoteHostKeychainOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var services: [String] = []
    var copiedServices: [String] { lock.withLock { services } }
    var status: OSStatus = errSecSuccess
    var pin = Data(pinRecord.utf8)
    static var pinRecord: String {
        func sshString(_ data: Data) -> Data {
            var length = UInt32(data.count).bigEndian
            return withUnsafeBytes(of: &length) { Data($0) } + data
        }
        let blob = sshString(Data("ssh-ed25519".utf8)) + sshString(Data(repeating: 4, count: 32))
        return "ssh-ed25519 \(blob.base64EncodedString())"
    }
    func update(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
    func add(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
    func delete(service: String, account: String) -> OSStatus { errSecSuccess }
    func copy(service: String, account: String) -> (OSStatus, Data?) {
        lock.withLock { services.append(service) }
        return (status, pin)
    }
}

private enum LoginActionTestError: Error { case unavailable }
private actor LoginActionMissingChatGPTRepository: ChatGPTSessionRepositoryProtocol {
    func save(_ session: ChatGPTSession, account: String) {}
    func load(account: String) throws -> ChatGPTSession { throw ChatGPTSessionRepositoryError.notFound }
    func validate(account: String) -> ChatGPTSessionAcquisitionStatus { .init(state: .missing, lastErrorCategory: .notFound) }
    func clear(account: String) {}
}
private actor LoginActionMissingGeminiRepository: GeminiAPIKeyRepositoryProtocol {
    func save(_ apiKey: GeminiAPIKey, account: String) {}
    func load(account: String) throws -> GeminiAPIKey { throw GeminiAPIKeyRepositoryError.notFound }
    func validate(account: String) -> GeminiAPIKeyAcquisitionStatus { .init(state: .missing, lastErrorCategory: .notFound) }
    func clear(account: String) {}
}
