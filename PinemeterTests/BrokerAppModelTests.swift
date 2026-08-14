//
//  BrokerAppModelTests.swift
//  PinemeterTests
//
//  AppModel's broker wiring (07-04): DI'd fakes for BrokerLifecycleProtocol,
//  BrokerLoopbackServerProtocol and T3LivenessCheckerProtocol so these tests
//  never bind a real socket.
//

import XCTest
@testable import Pinemeter

@MainActor
final class BrokerAppModelTests: XCTestCase {
    // MARK: - Test 1: bootstrap pushes policy and starts/does-not-start the server

    func test_bootstrap_withBrokerEnabled_pushesPersistedPolicyAndStartsServer() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.port = 43117
        try await settingsRepository.save(settings)

        let fakeBroker = FakeBrokerService()
        let fakeServer = FakeBrokerLoopbackServer(startResult: .success(43117))

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker()
        )

        await appModel.bootstrap()

        let policies = await fakeBroker.updatedPolicies
        XCTAssertEqual(policies.last, settings.broker.policy)
        let startCount = await fakeServer.startCallCount
        XCTAssertEqual(startCount, 1)
        let serverStates = await fakeBroker.serverStates
        XCTAssertEqual(serverStates.last, .running(port: 43117))
    }

    func test_bootstrap_withBrokerDisabled_neverStartsServer() async throws {
        // Default settings: broker.isEnabled == false.
        let settingsRepository = SettingsRepositoryFake()
        let fakeBroker = FakeBrokerService()
        let fakeServer = FakeBrokerLoopbackServer()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker()
        )

        await appModel.bootstrap()

        let startCount = await fakeServer.startCallCount
        XCTAssertEqual(startCount, 0)
        // The policy is still pushed on every bootstrap, independent of the
        // enable toggle, so a later enable-without-restart never serves a
        // stale policy.
        let policies = await fakeBroker.updatedPolicies
        XCTAssertEqual(policies.last, BrokerPolicy.bundledDefault)
    }

    func test_bootstrap_withPortAlreadyInUse_surfacesFailedServerState() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.port = 43117
        try await settingsRepository.save(settings)

        let fakeBroker = FakeBrokerService()
        let fakeServer = FakeBrokerLoopbackServer(
            startResult: .failure(LoopbackHTTPServerError.addressInUse(port: 43117))
        )

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker()
        )

        await appModel.bootstrap()

        let serverStates = await fakeBroker.serverStates
        guard case .failed(let message) = serverStates.last else {
            XCTFail("expected a failed server state, got \(String(describing: serverStates.last))")
            return
        }
        XCTAssertTrue(message.contains("43117"))
    }

    func test_bootstrap_afterObservedSettingsStart_doesNotRestartBrokerServer() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.port = 43117
        try await settingsRepository.save(settings)

        let fakeBroker = FakeBrokerService()
        let fakeServer = FakeBrokerLoopbackServer(startResult: .success(43117))
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker()
        )

        appModel.settings.broker = settings.broker
        await appModel.applyBrokerSettingsChange()
        await appModel.bootstrap()

        let startCount = await fakeServer.startCallCount
        XCTAssertEqual(startCount, 1)
        let stopCount = await fakeServer.stopCallCount
        XCTAssertEqual(stopCount, 0)
        let serverStates = await fakeBroker.serverStates
        XCTAssertEqual(serverStates.last, .running(port: 43117))
    }

    // MARK: - Test 2: every export-triggering refresh path also pushes an OracleSnapshot

    func test_refreshUsage_pushesOracleSnapshotMatchingTheExportAssembly() async throws {
        let expectedUsage = makeBrokerTestUsageData(sessionPercentage: 42, weeklyPercentage: 17)
        let usageService = UsageServiceStub(fetchUsageResult: .success(expectedUsage))
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let fakeBroker = FakeBrokerService()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            brokerService: fakeBroker,
            brokerServerFactory: { _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker()
        )

        try? await keychainRepository.save(sessionKey: TestConstants.sessionKeyValue, account: "default")

        await appModel.bootstrap()

        let pushed = await fakeBroker.pushedOracleSnapshots
        guard let snapshot = pushed.last.flatMap({ $0 }) else {
            XCTFail("expected a pushed OracleSnapshot")
            return
        }

        XCTAssertEqual(snapshot.accounts.count, 1)
        let row = try XCTUnwrap(snapshot.accounts.first)
        XCTAssertTrue(row.isPrimary)
        XCTAssertEqual(row.state, .fresh)
        XCTAssertEqual(row.session, expectedUsage.sessionUsage.percentage)
        XCTAssertEqual(row.weekly, expectedUsage.weeklyUsage.percentage)
    }

    func test_refreshChatGPTUsage_pushesOracleSnapshotWithChatGPTRows() async throws {
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let chatGPTSessionRepository = BrokerTestChatGPTSessionRepositoryFake()
        try await chatGPTSessionRepository.save(
            ChatGPTSession(sessionCookie: "chatgpt-session-redacted"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let chatGPTUsage = ChatGPTUsageData(
            rows: [
                ChatGPTUsageData.LimitRow(label: "Codex weekly", usedPercent: 64, resetAt: nil)
            ],
            lastUpdated: Date()
        )
        let chatGPTUsageService = BrokerTestChatGPTUsageServiceStub(fetchUsageResult: .success(chatGPTUsage))
        let fakeBroker = FakeBrokerService()

        var settings = AppSettings.default
        settings.isChatGPTUsageShown = true
        try await settingsRepository.save(settings)

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            chatGPTUsageService: chatGPTUsageService,
            chatGPTSessionRepository: chatGPTSessionRepository,
            brokerService: fakeBroker,
            brokerServerFactory: { _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker()
        )

        await appModel.bootstrap()

        let pushed = await fakeBroker.pushedOracleSnapshots
        guard let snapshot = pushed.last.flatMap({ $0 }) else {
            XCTFail("expected a pushed OracleSnapshot")
            return
        }
        XCTAssertEqual(snapshot.chatGPTRows.map(\.label), ["Codex weekly"])
        XCTAssertEqual(snapshot.chatGPTRows.map(\.usedPercent), [64])
        XCTAssertEqual(snapshot.chatGPTState, .fresh)
    }

    // MARK: - Test 3: the wired refresh handler forces a real provider re-poll

    func test_refreshHandler_invokesRefreshConfiguredUsageProvidersForced() async throws {
        let usageService = UsageServiceStub(fetchUsageResult: .success(makeBrokerTestUsageData(sessionPercentage: 10, weeklyPercentage: 5)))
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let fakeBroker = FakeBrokerService()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: usageService,
            brokerService: fakeBroker,
            brokerServerFactory: { _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker()
        )
        try? await keychainRepository.save(sessionKey: TestConstants.sessionKeyValue, account: "default")

        await appModel.bootstrap()

        let refreshHandlerSetCount = await fakeBroker.refreshHandlerSetCount
        XCTAssertEqual(refreshHandlerSetCount, 1)

        let callsBefore = await usageService.fetchUsageCallCount
        try await fakeBroker.invokeRefreshHandler()
        let callsAfter = await usageService.fetchUsageCallCount

        XCTAssertGreaterThan(callsAfter, callsBefore)
        let forceValues = await usageService.forceRefreshValues
        XCTAssertEqual(forceValues.last, true)
    }

    func test_bootstrap_installsRefreshHandlerBeforeStartingServer() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        try await settingsRepository.save(settings)

        let fakeBroker = FakeBrokerService()
        let fakeServer = FakeBrokerLoopbackServer(
            onStart: { try await fakeBroker.invokeRefreshHandler() }
        )
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker()
        )

        await appModel.bootstrap()

        let refreshHandlerInvokeCount = await fakeBroker.refreshHandlerInvokeCount
        let serverStates = await fakeBroker.serverStates
        XCTAssertEqual(refreshHandlerInvokeCount, 1)
        XCTAssertEqual(serverStates.last, .running(port: 43117))
    }

    // MARK: - Test 4: applyBrokerSettingsChange stop/restart/push matrix

    func test_overlappingBrokerStarts_leaveLatestEnabledServerRunning() async throws {
        let fakeBroker = FakeBrokerService()
        let firstServer = SuspendingFakeBrokerLoopbackServer()
        let secondServer = CollisionAwareFakeBrokerLoopbackServer(previous: firstServer)
        let serverFactory = FakeBrokerLoopbackServerFactory(servers: [firstServer, secondServer])
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _ in serverFactory.next() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker()
        )
        appModel.settings.broker.isEnabled = true

        let firstApply = Task { await appModel.applyBrokerSettingsChange() }
        await firstServer.waitUntilStartCalled()
        let secondApply = Task { await appModel.applyBrokerSettingsChange() }

        await secondApply.value
        await firstApply.value

        let firstStopCount = await firstServer.stopCallCount
        let secondStartCount = await secondServer.startCallCount
        let secondStopCount = await secondServer.stopCallCount
        let serverStates = await fakeBroker.serverStates
        XCTAssertEqual(firstStopCount, 2)
        XCTAssertEqual(secondStartCount, 1)
        XCTAssertEqual(secondStopCount, 0)
        XCTAssertEqual(serverStates.last, .running(port: 43117))
    }

    func test_disableDuringBrokerStart_endsStopped() async throws {
        let fakeBroker = FakeBrokerService()
        let fakeServer = SuspendingFakeBrokerLoopbackServer()
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker()
        )
        appModel.settings.broker.isEnabled = true

        let startApply = Task { await appModel.applyBrokerSettingsChange() }
        await fakeServer.waitUntilStartCalled()
        appModel.settings.broker.isEnabled = false
        let disableApply = Task { await appModel.applyBrokerSettingsChange() }

        await disableApply.value
        await fakeServer.finishStart()
        await startApply.value

        let stopCallCount = await fakeServer.stopCallCount
        let serverStates = await fakeBroker.serverStates
        XCTAssertGreaterThanOrEqual(stopCallCount, 1)
        XCTAssertEqual(serverStates.last, .stopped)
    }

    func test_applyBrokerSettingsChange_stopsRestartsAndPushesPolicyAppropriately() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.port = 43117
        try await settingsRepository.save(settings)

        let fakeBroker = FakeBrokerService()
        let firstServer = FakeBrokerLoopbackServer(startResult: .success(43117))
        let secondServer = FakeBrokerLoopbackServer(startResult: .success(50000))

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            brokerService: fakeBroker,
            brokerServerFactory: { _, port in port == 43117 ? firstServer : secondServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker()
        )

        await appModel.bootstrap()
        let firstStartAfterBootstrap = await firstServer.startCallCount
        XCTAssertEqual(firstStartAfterBootstrap, 1)

        // Policy-only change: the new policy is pushed, no restart happens.
        appModel.settings.broker.policy.roles["planning"] = [
            BrokerCandidate(route: .native, model: "claude-opus-5")
        ]
        await appModel.applyBrokerSettingsChange()
        let firstStopAfterPolicyChange = await firstServer.stopCallCount
        XCTAssertEqual(firstStopAfterPolicyChange, 0, "a policy-only change must not restart the server")
        let policyCountAfterPolicyChange = await fakeBroker.updatedPolicies.count
        XCTAssertGreaterThanOrEqual(policyCountAfterPolicyChange, 2)

        // Port change: stop the old server, start on the new port.
        appModel.settings.broker.port = 50000
        await appModel.applyBrokerSettingsChange()
        let firstStopAfterPortChange = await firstServer.stopCallCount
        XCTAssertEqual(firstStopAfterPortChange, 1)
        let secondStart = await secondServer.startCallCount
        XCTAssertEqual(secondStart, 1)

        // Disabling stops the running server.
        appModel.settings.broker.isEnabled = false
        await appModel.applyBrokerSettingsChange()
        let secondStop = await secondServer.stopCallCount
        XCTAssertEqual(secondStop, 1)
        let serverStates = await fakeBroker.serverStates
        XCTAssertEqual(serverStates.last, .stopped)
    }

    // MARK: - Test 5: the refresh-loop tick probes T3 liveness and pushes it

    func test_scheduledRefreshTick_probesT3LivenessForConfiguredInstancesAndPushesResults() async throws {
        let settingsRepository = SettingsRepositoryFake()
        let fakeBroker = FakeBrokerService()
        let fakeLivenessChecker = BrokerAppModelFakeT3LivenessChecker()
        let expectedLiveness: [String: T3Liveness] = [
            "claudeAgent": T3Liveness(reachable: true, why: "200")
        ]
        await fakeLivenessChecker.setResult(expectedLiveness)

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: fakeLivenessChecker
        )

        await appModel.bootstrap()
        await appModel.performScheduledRefreshTick()

        let callCount = await fakeLivenessChecker.callCount
        XCTAssertEqual(callCount, 1)
        let lastInstances = await fakeLivenessChecker.lastInstances
        XCTAssertEqual(lastInstances, BrokerPolicy.bundledDefault.t3Instances)

        let pushedLiveness = await fakeBroker.pushedLiveness
        XCTAssertEqual(pushedLiveness.last, expectedLiveness)
    }
}

// MARK: - Test doubles

/// Records every call AppModel makes across the broker's tool surface
/// (`BrokerServiceProtocol`) and lifecycle seams (`BrokerLifecycleProtocol`),
/// without touching a real socket, cooldown file or T3 pointer file.
private actor FakeBrokerService: BrokerLifecycleProtocol {
    private(set) var updatedPolicies: [BrokerPolicy] = []
    private(set) var pushedOracleSnapshots: [OracleSnapshot?] = []
    private(set) var pushedLiveness: [[String: T3Liveness]] = []
    private(set) var serverStates: [BrokerUIState.ServerState] = []
    private(set) var refreshHandlerSetCount = 0
    private(set) var refreshHandlerInvokeCount = 0
    private var refreshHandler: (@Sendable () async throws -> Void)?

    private(set) var pickCalls: [(role: String, caller: String?)] = []
    private(set) var downCalls: [(target: String, minutes: Int?)] = []
    private(set) var upCalls: [String] = []
    private(set) var refreshCallCount = 0

    private var uiState = BrokerUIState.initial
    private var continuations: [UUID: AsyncStream<BrokerUIState>.Continuation] = [:]

    // MARK: BrokerServiceProtocol

    func pick(role: String, caller: String?) async throws -> BrokerDecision {
        pickCalls.append((role, caller))
        throw BrokerError.configError("FakeBrokerService.pick is unconfigured")
    }

    func status() async -> BrokerStatus {
        BrokerStatus(
            running: false,
            port: nil,
            oracle: BrokerStatus.OracleFreshness(present: false, stale: false, ageSeconds: nil, accounts: []),
            cooldowns: [],
            t3: [],
            roles: [],
            recentPicksCount: 0
        )
    }

    func down(target: String, minutes: Int?) async {
        downCalls.append((target, minutes))
    }

    func up(target: String) async {
        upCalls.append(target)
    }

    func refresh() async throws {
        refreshCallCount += 1
    }

    // MARK: BrokerLifecycleProtocol

    func updatePolicy(_ policy: BrokerPolicy) async {
        updatedPolicies.append(policy)
    }

    func updateOracleSnapshot(_ oracle: OracleSnapshot?) async {
        pushedOracleSnapshots.append(oracle)
    }

    func updateT3Liveness(_ liveness: [String: T3Liveness]) async {
        pushedLiveness.append(liveness)
    }

    func updateServerState(_ state: BrokerUIState.ServerState) async {
        serverStates.append(state)
        uiState.serverState = state
        publish()
    }

    func setRefreshHandler(_ handler: @escaping @Sendable () async throws -> Void) {
        refreshHandler = handler
        refreshHandlerSetCount += 1
    }

    func uiStateUpdates() async -> AsyncStream<BrokerUIState> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(uiState)
        }
    }

    /// Test helper: invokes the handler AppModel wired via `setRefreshHandler`.
    func invokeRefreshHandler() async throws {
        guard let refreshHandler else {
            throw TestError(message: "refresh handler is not installed")
        }
        refreshHandlerInvokeCount += 1
        try await refreshHandler()
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(uiState)
        }
    }
}

/// Records `start`/`stop` calls without binding a real `NWListener`.
private actor FakeBrokerLoopbackServer: BrokerLoopbackServerProtocol {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private let startResult: Result<UInt16, Error>
    private let onStart: (@Sendable () async throws -> Void)?

    init(
        startResult: Result<UInt16, Error> = .success(43117),
        onStart: (@Sendable () async throws -> Void)? = nil
    ) {
        self.startResult = startResult
        self.onStart = onStart
    }

    func start() async throws -> UInt16 {
        startCallCount += 1
        try await onStart?()
        return try startResult.get()
    }

    func stop() async {
        stopCallCount += 1
    }
}

private actor SuspendingFakeBrokerLoopbackServer: BrokerLoopbackServerProtocol {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var startContinuation: CheckedContinuation<UInt16, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func start() async throws -> UInt16 {
        startCallCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { startContinuation = $0 }
    }

    func stop() {
        stopCallCount += 1
        finishStart()
    }

    func waitUntilStartCalled() async {
        guard startCallCount == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishStart() {
        startContinuation?.resume(returning: 43117)
        startContinuation = nil
    }
}

private actor CollisionAwareFakeBrokerLoopbackServer: BrokerLoopbackServerProtocol {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private let previous: SuspendingFakeBrokerLoopbackServer

    init(previous: SuspendingFakeBrokerLoopbackServer) {
        self.previous = previous
    }

    func start() async throws -> UInt16 {
        startCallCount += 1
        guard await previous.stopCallCount > 0 else {
            throw LoopbackHTTPServerError.addressInUse(port: 43117)
        }
        return 43117
    }

    func stop() {
        stopCallCount += 1
    }
}

private final class FakeBrokerLoopbackServerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [any BrokerLoopbackServerProtocol]

    init(servers: [any BrokerLoopbackServerProtocol]) {
        self.servers = servers
    }

    func next() -> any BrokerLoopbackServerProtocol {
        lock.withLock { servers.removeFirst() }
    }
}

/// Records every `checkLiveness` call, returning a configurable canned result.
private actor BrokerAppModelFakeT3LivenessChecker: T3LivenessCheckerProtocol {
    private(set) var callCount = 0
    private(set) var lastInstances: [T3InstanceConfig] = []
    private var result: [String: T3Liveness] = [:]

    func setResult(_ result: [String: T3Liveness]) {
        self.result = result
    }

    func checkLiveness(instances: [T3InstanceConfig]) async -> [String: T3Liveness] {
        callCount += 1
        lastInstances = instances
        return result
    }
}

/// Minimal ChatGPT session repository double, local to this file (the
/// project has no shared TestDoubles entry for it yet).
private actor BrokerTestChatGPTSessionRepositoryFake: ChatGPTSessionRepositoryProtocol {
    private var sessions: [String: ChatGPTSession] = [:]
    private var status = ChatGPTSessionAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)

    func save(_ session: ChatGPTSession, account: String) async throws {
        sessions[account] = session
        status = ChatGPTSessionAcquisitionStatus(state: .available, lastErrorCategory: nil)
    }

    func load(account: String) async throws -> ChatGPTSession {
        guard let session = sessions[account] else {
            throw ChatGPTSessionRepositoryError.notFound
        }
        return session
    }

    func validate(account: String) async -> ChatGPTSessionAcquisitionStatus {
        status
    }

    func clear(account: String) async throws {
        sessions[account] = nil
        status = ChatGPTSessionAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
    }
}

private actor BrokerTestChatGPTUsageServiceStub: ChatGPTUsageServiceProtocol {
    let fetchUsageResult: Result<ChatGPTUsageData, Error>

    init(fetchUsageResult: Result<ChatGPTUsageData, Error>) {
        self.fetchUsageResult = fetchUsageResult
    }

    func fetchUsage() async throws -> ChatGPTUsageData {
        try fetchUsageResult.get()
    }

    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData {
        try fetchUsageResult.get()
    }

    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool {
        true
    }
}

private func makeBrokerTestUsageData(sessionPercentage: Double, weeklyPercentage: Double) -> UsageData {
    let resetDate = Date().addingTimeInterval(TestConstants.oneHourInterval)
    return UsageData(
        sessionUsage: UsageLimit(utilization: sessionPercentage, resetAt: resetDate),
        weeklyUsage: UsageLimit(utilization: weeklyPercentage, resetAt: resetDate),
        sonnetUsage: nil,
        lastUpdated: Date()
    )
}
