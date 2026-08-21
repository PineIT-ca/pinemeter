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
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
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
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
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

    func testBrokerOnlyConfigurationStartsScheduledRefreshWhenT3Unavailable() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        try await settingsRepository.save(settings)
        let t3Usage = BrokerAppModelT3UsageServiceFake(
            result: .init(availability: .usageUnavailable(reason: .authenticationRequired), freshSnapshot: nil)
        )

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: FakeBrokerService(),
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake(),
            t3UsageService: t3Usage
        )

        await appModel.bootstrap()

        XCTAssertTrue(appModel.isRefreshLoopRunning)
        let t3UsageCallCount = await t3Usage.callCount
        XCTAssertEqual(t3UsageCallCount, 1)
    }

    func testAllRefreshTriggersConvergeAndRuntimeBrokerTogglesLoop() async throws {
        let fakeBroker = FakeBrokerService()
        let fakeServer = FakeBrokerLoopbackServer()
        let t3Usage = BrokerAppModelT3UsageServiceFake(
            result: .init(availability: .usageUnavailable(reason: .authenticationRequired), freshSnapshot: nil)
        )
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            chatGPTSessionRepository: BrokerTestChatGPTSessionRepositoryFake(),
            geminiAPIKeyRepository: BrokerTestGeminiAPIKeyRepositoryFake(),
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake(),
            t3UsageService: t3Usage
        )

        await appModel.bootstrap()
        try await fakeBroker.invokeRefreshHandler()
        await appModel.performScheduledRefreshTick()
        await appModel.performWakeRefresh()

        let triggerCallCount = await t3Usage.callCount
        XCTAssertEqual(triggerCallCount, 4)
        XCTAssertFalse(appModel.isRefreshLoopRunning)

        appModel.settings.broker.isEnabled = true
        await appModel.applyBrokerSettingsChange()
        XCTAssertTrue(appModel.isRefreshLoopRunning)

        appModel.settings.broker.isEnabled = false
        await appModel.applyBrokerSettingsChange()
        XCTAssertFalse(appModel.isRefreshLoopRunning)
        let startCallCount = await fakeServer.startCallCount
        let stopCallCount = await fakeServer.stopCallCount
        XCTAssertEqual(startCallCount, 1)
        XCTAssertEqual(stopCallCount, 1)
    }

    func testBrokerRefreshUsesTheProbedLivenessForTelemetry() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        try await settingsRepository.save(settings)
        let fakeBroker = FakeBrokerService()
        await fakeBroker.setLivenessResult([
            "claudeAgent": T3Liveness(reachable: true, why: "reachable")
        ])
        let t3Usage = BrokerAppModelT3UsageServiceFake(
            result: .init(availability: .usageUnavailable(reason: .authenticationRequired), freshSnapshot: nil)
        )
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3InstanceDiscovery: T3InstanceDiscoveryFake(),
            t3UsageService: t3Usage
        )

        await appModel.bootstrap()
        var availability = await t3Usage.availabilities.last
        XCTAssertEqual(availability, .reachable)

        await fakeBroker.setLivenessResult([
            "claudeAgent": T3Liveness(reachable: false, why: "unreachable")
        ])
        try await fakeBroker.refresh()

        availability = await t3Usage.availabilities.last
        let liveness = await fakeBroker.t3LivenessSnapshot()
        XCTAssertEqual(availability, .unreachable)
        XCTAssertEqual(liveness["claudeAgent"]?.why, "unreachable")
    }

    func testPolicyRemovalStopsStaleReachableInstanceFromEnablingTelemetry() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.policy.t3Instances = [
            T3InstanceConfig(id: "removed", name: "Removed"),
            T3InstanceConfig(id: "current", name: "Current"),
        ]
        try await settingsRepository.save(settings)
        let fakeBroker = FakeBrokerService()
        await fakeBroker.setLivenessResult([
            "removed": T3Liveness(reachable: true, why: "reachable")
        ])
        let t3Usage = BrokerAppModelT3UsageServiceFake(
            result: .init(availability: .usageUnavailable(reason: .authenticationRequired), freshSnapshot: nil)
        )
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3InstanceDiscovery: T3InstanceDiscoveryFake(),
            t3UsageService: t3Usage
        )

        await appModel.bootstrap()
        var availability = await t3Usage.availabilities.last
        XCTAssertEqual(availability, .reachable)

        appModel.settings.broker.policy.t3Instances = [
            T3InstanceConfig(id: "current", name: "Current")
        ]
        await appModel.applyBrokerSettingsChange()
        await appModel.refreshConfiguredUsageProviders()

        availability = await t3Usage.availabilities.last
        XCTAssertEqual(availability, .unreachable)
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
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
        )

        await appModel.bootstrap()

        let serverStates = await fakeBroker.serverStates
        guard case .failed(let message) = serverStates.last else {
            XCTFail("expected a failed server state, got \(String(describing: serverStates.last))")
            return
        }
        XCTAssertTrue(message.contains("43117"))

        appModel.settings.broker.isEnabled = false
        await appModel.applyBrokerSettingsChange()
        let disabledServerState = await fakeBroker.serverStates.last
        XCTAssertEqual(disabledServerState, .stopped)
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
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
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
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
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
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
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

    func testOracleProjectionCarriesAllClaudeAndChatGPTRowResets() async throws {
        let settingsRepository = SettingsRepositoryFake()
        let keychainRepository = KeychainRepositoryFake()
        let chatGPTSessionRepository = BrokerTestChatGPTSessionRepositoryFake()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var claudeUsage = UsageData(
            sessionUsage: UsageLimit(utilization: 10, resetAt: base.addingTimeInterval(1)),
            weeklyUsage: UsageLimit(utilization: 20, resetAt: base.addingTimeInterval(2)),
            sonnetUsage: UsageLimit(utilization: 30, resetAt: base.addingTimeInterval(3)),
            lastUpdated: Date()
        )
        claudeUsage.fableUsage = UsageLimit(utilization: 40, resetAt: base.addingTimeInterval(4))
        let chatGPTRows = [
            ChatGPTUsageData.LimitRow(
                label: "Codex 5h",
                usedPercent: 50,
                resetAt: base.addingTimeInterval(5),
                menuBarRole: .chatGPT5h
            ),
            ChatGPTUsageData.LimitRow(
                label: "Unknown",
                usedPercent: 60,
                resetAt: base.addingTimeInterval(6)
            ),
        ]
        try await keychainRepository.save(sessionKey: TestConstants.sessionKeyValue, account: "default")
        try await chatGPTSessionRepository.save(
            ChatGPTSession(sessionCookie: "chatgpt-session-redacted"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        var settings = AppSettings.default
        settings.isChatGPTUsageShown = true
        try await settingsRepository.save(settings)
        let fakeBroker = FakeBrokerService()
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychainRepository,
            usageService: UsageServiceStub(fetchUsageResult: .success(claudeUsage)),
            chatGPTUsageService: BrokerTestChatGPTUsageServiceStub(
                fetchUsageResult: .success(ChatGPTUsageData(rows: chatGPTRows, lastUpdated: Date()))
            ),
            chatGPTSessionRepository: chatGPTSessionRepository,
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
        )

        await appModel.bootstrap()

        let pushed = await fakeBroker.pushedOracleSnapshots
        let snapshot = try XCTUnwrap(pushed.last.flatMap { $0 })
        let account = try XCTUnwrap(snapshot.accounts.first)
        XCTAssertEqual(account.sessionResetAt, base.addingTimeInterval(1))
        XCTAssertEqual(account.weeklyResetAt, base.addingTimeInterval(2))
        XCTAssertEqual(account.sonnetResetAt, base.addingTimeInterval(3))
        XCTAssertEqual(account.fableResetAt, base.addingTimeInterval(4))
        XCTAssertEqual(snapshot.chatGPTRows.map(\.resetAt), chatGPTRows.map(\.resetAt))
        XCTAssertEqual(snapshot.chatGPTRows.map(\.windowRole), [.chatGPT5h, nil])
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
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
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
        let expectedLiveness = ["claudeAgent": T3Liveness(reachable: true, why: "ready")]
        await fakeBroker.setLivenessResult(expectedLiveness)
        let fakeServer = FakeBrokerLoopbackServer(
            onStart: {
                let liveness = await fakeBroker.t3LivenessSnapshot()
                XCTAssertEqual(liveness, expectedLiveness)
                try await fakeBroker.invokeRefreshHandler()
            }
        )
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
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
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in serverFactory.next() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
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
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in fakeServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
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
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, port, _ in port == 43117 ? firstServer : secondServer },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
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
        let expectedLiveness: [String: T3Liveness] = [
            "claudeAgent": T3Liveness(reachable: true, why: "200")
        ]
        await fakeBroker.setLivenessResult(expectedLiveness)

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
        )

        await appModel.bootstrap()
        await appModel.performScheduledRefreshTick()

        let callCount = await fakeBroker.livenessRefreshCallCount
        XCTAssertEqual(callCount, 1)
        let lastInstances = await fakeBroker.lastLivenessInstances
        XCTAssertEqual(lastInstances, BrokerPolicy.bundledDefault.t3Instances)

        let pushedLiveness = await fakeBroker.pushedLiveness
        XCTAssertEqual(pushedLiveness.last, expectedLiveness)
    }

    // MARK: - Test 6: T3 discovery reconciliation (260814-pz4)

    func test_bootstrap_withDiscoveredInstanceNotInSeeds_pushesReconciledPolicyContainingIt() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true // discovery only runs while enabled (WR-06)
        try await settingsRepository.save(settings)
        let fakeBroker = FakeBrokerService()
        let discoveryFake = T3InstanceDiscoveryFake()
        await discoveryFake.setResult([
            DiscoveredT3Instance(
                instanceId: "cursor",
                driver: "cursor",
                displayName: "Cursor",
                installed: true,
                checkedAt: Date(),
                modelSlugs: ["cursor-model"]
            )
        ])

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: discoveryFake
        )

        await appModel.bootstrap()

        let policies = await fakeBroker.updatedPolicies
        let pushedIds = policies.last?.t3Instances.map(\.id) ?? []
        XCTAssertTrue(pushedIds.contains("cursor"), "a discovered instance not in the seeds must reach the pushed policy")
    }

    func test_scheduledRefreshTick_runsDiscoveryBeforeLiveness_soLivenessSeesTheNewInstance() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true // discovery only runs while enabled (WR-06)
        try await settingsRepository.save(settings)
        let fakeBroker = FakeBrokerService()
        let discoveryFake = T3InstanceDiscoveryFake()

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3InstanceDiscovery: discoveryFake
        )

        // No instance discovered at bootstrap.
        await appModel.bootstrap()

        // A new instance appears in the next scan, before the tick runs.
        await discoveryFake.setResult([
            DiscoveredT3Instance(
                instanceId: "grok",
                driver: "grok",
                displayName: "Grok",
                installed: true,
                checkedAt: Date(),
                modelSlugs: []
            )
        ])

        await appModel.performScheduledRefreshTick()

        let lastInstances = await fakeBroker.lastLivenessInstances
        XCTAssertTrue(
            lastInstances.contains { $0.id == "grok" },
            "discovery must run before liveness within the same tick so a newly discovered instance is probed immediately"
        )

        let policies = await fakeBroker.updatedPolicies
        XCTAssertTrue(
            policies.last?.t3Instances.contains { $0.id == "grok" } ?? false,
            "a changed reconciliation result must reach updatePolicy so the MCP tools never resolve against the pre-discovery instance set"
        )
    }

    func test_scheduledRefreshTick_failedDiscoveryScan_leavesPolicyUnchangedAndPushesNoNewPolicy() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true // discovery only runs while enabled (WR-06)
        try await settingsRepository.save(settings)
        let fakeBroker = FakeBrokerService()
        let fakeLivenessChecker = BrokerAppModelFakeT3LivenessChecker()
        let discoveryFake = T3InstanceDiscoveryFake() // nil result: scan failure

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: fakeLivenessChecker,
            t3InstanceDiscovery: discoveryFake
        )

        await appModel.bootstrap()
        let policyBeforeTick = appModel.settings.broker.policy
        let policyCountBeforeTick = await fakeBroker.updatedPolicies.count

        await appModel.performScheduledRefreshTick()

        XCTAssertEqual(appModel.settings.broker.policy, policyBeforeTick, "a failed scan (nil) must leave the saved policy untouched (R-05)")
        let policyCountAfterTick = await fakeBroker.updatedPolicies.count
        XCTAssertEqual(policyCountAfterTick, policyCountBeforeTick, "a failed scan must push no new policy")
    }

    func test_brokerDisabled_discoveryNeverScansOrRewritesSettings() async throws {
        // Review WR-06: a user who has the broker turned off must get no
        // `~/.t3` file access and no settings mutation from discovery.
        let settingsRepository = SettingsRepositoryFake()
        let fakeBroker = FakeBrokerService()
        let discoveryFake = T3InstanceDiscoveryFake(result: [
            DiscoveredT3Instance(instanceId: "cursor", driver: "cursor", installed: true)
        ])

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: fakeBroker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: discoveryFake
        )

        await appModel.bootstrap()
        await appModel.performScheduledRefreshTick()

        let scanCallCount = await discoveryFake.scanCallCount
        XCTAssertEqual(scanCallCount, 0, "discovery must not scan while the broker is disabled")
        XCTAssertFalse(
            appModel.settings.broker.policy.t3Instances.contains { $0.id == "cursor" },
            "a disabled broker must never gain rows from discovery"
        )
    }

    // MARK: - Instruction re-check reminder

    private func makeRecheckAppModel(
        settings: AppSettings,
        broker: FakeBrokerService,
        notificationService: NotificationServiceSpy
    ) -> AppModel {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: notificationService,
            brokerService: broker,
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
        )
        appModel.settings = settings
        return appModel
    }

    private func recheckSettings() -> AppSettings {
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.hasNotificationsEnabled = true
        return settings
    }

    /// Graded by the running build, so only its age can make it due.
    private func recordedCheck(at date: Date) -> InstructionCheck {
        InstructionCheck(
            runID: "run-1",
            caller: "claude-code",
            checkedAt: date,
            gradedBy: BrokerMCPServer.appVersion,
            sources: [InstructionCheckSource(path: "a.md", status: .pass, findings: [])]
        )
    }

    func test_recheckReminder_notifiesOnceWhenDueThenWaitsOutTheInterval() async throws {
        let checkedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let broker = FakeBrokerService()
        await broker.setInstructionCheck(recordedCheck(at: checkedAt))
        let notifications = NotificationServiceSpy()
        let appModel = makeRecheckAppModel(
            settings: recheckSettings(), broker: broker, notificationService: notifications
        )

        let due = checkedAt.addingTimeInterval(InstructionRecheck.interval + 1)
        await appModel.sendInstructionRecheckReminderIfNeeded(now: due)
        XCTAssertEqual(notifications.sentRecheckReasons, [.stale])
        XCTAssertEqual(appModel.settings.lastInstructionRecheckNotifiedAt, due)

        // Still due, still the same record: nudging again the next day is
        // nagging, not information.
        await appModel.sendInstructionRecheckReminderIfNeeded(now: due.addingTimeInterval(86_400))
        XCTAssertEqual(notifications.sentRecheckReasons, [.stale])

        let nextNudge = due.addingTimeInterval(InstructionRecheck.interval)
        await appModel.sendInstructionRecheckReminderIfNeeded(now: nextNudge)
        XCTAssertEqual(notifications.sentRecheckReasons, [.stale, .stale])
        XCTAssertEqual(appModel.settings.lastInstructionRecheckNotifiedAt, nextNudge)
    }

    /// A check recorded since the last reminder re-arms it: the user acted,
    /// and the reminder now speaks about what they ran rather than repeating
    /// itself about a record that is gone.
    func test_recheckReminder_isReArmedByANewerCheck() async throws {
        let checkedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let broker = FakeBrokerService()
        await broker.setInstructionCheck(recordedCheck(at: checkedAt))
        let notifications = NotificationServiceSpy()
        let appModel = makeRecheckAppModel(
            settings: recheckSettings(), broker: broker, notificationService: notifications
        )

        let due = checkedAt.addingTimeInterval(InstructionRecheck.interval + 1)
        await appModel.sendInstructionRecheckReminderIfNeeded(now: due)
        XCTAssertEqual(notifications.sentRecheckReasons, [.stale])

        // Re-run on a build that is not this one: fresh, and still due.
        let reRunAt = due.addingTimeInterval(60)
        await broker.setInstructionCheck(
            InstructionCheck(
                runID: "run-2",
                caller: "claude-code",
                checkedAt: reRunAt,
                gradedBy: "0.0.1-ancient",
                sources: [InstructionCheckSource(path: "a.md", status: .pass, findings: [])]
            )
        )

        await appModel.sendInstructionRecheckReminderIfNeeded(now: reRunAt.addingTimeInterval(60))
        XCTAssertEqual(notifications.sentRecheckReasons, [.stale, .contractMayHaveChanged])
    }

    func test_recheckReminder_saysNothingAboutAMachineThatHasNeverBeenChecked() async throws {
        let notifications = NotificationServiceSpy()
        let appModel = makeRecheckAppModel(
            settings: recheckSettings(),
            broker: FakeBrokerService(),
            notificationService: notifications
        )

        await appModel.sendInstructionRecheckReminderIfNeeded(now: Date(timeIntervalSince1970: 1_760_000_000))

        XCTAssertTrue(notifications.sentRecheckReasons.isEmpty)
        XCTAssertNil(appModel.settings.lastInstructionRecheckNotifiedAt)
    }

    func test_recheckReminder_respectsItsToggleTheBrokerToggleAndNotificationState() async throws {
        let checkedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let due = checkedAt.addingTimeInterval(InstructionRecheck.interval + 1)

        func sentReasons(
            configure: (inout AppSettings) -> Void,
            hasPermission: Bool = true
        ) async -> [InstructionRecheck.Reason] {
            let broker = FakeBrokerService()
            await broker.setInstructionCheck(recordedCheck(at: checkedAt))
            let notifications = NotificationServiceSpy()
            notifications.hasPermission = hasPermission
            var settings = recheckSettings()
            configure(&settings)
            let appModel = makeRecheckAppModel(
                settings: settings, broker: broker, notificationService: notifications
            )
            await appModel.sendInstructionRecheckReminderIfNeeded(now: due)
            return notifications.sentRecheckReasons
        }

        let reminderOff = await sentReasons { $0.broker.recheckReminderEnabled = false }
        XCTAssertTrue(reminderOff.isEmpty)

        let brokerOff = await sentReasons { $0.broker.isEnabled = false }
        XCTAssertTrue(brokerOff.isEmpty)

        let notificationsOff = await sentReasons { $0.hasNotificationsEnabled = false }
        XCTAssertTrue(notificationsOff.isEmpty)

        let permissionDenied = await sentReasons(configure: { _ in }, hasPermission: false)
        XCTAssertTrue(permissionDenied.isEmpty)

        let allowed = await sentReasons { _ in }
        XCTAssertEqual(allowed, [.stale])
    }

    // MARK: - Network access and API key provisioning

    func test_changingNetworkAccessWhileRunning_restartsTheServerWithTheNewPolicy() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.apiKeyMode = .none
        try await settingsRepository.save(settings)

        let factory = RecordingBrokerLoopbackServerFactory()
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: FakeBrokerService(),
            brokerServerFactory: { _, port, policy in factory.make(port: port, policy: policy) },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
        )

        await appModel.bootstrap()
        XCTAssertEqual(factory.policies.map(\.networkAccess), [.loopback])

        appModel.settings.broker.networkAccess = .network
        await appModel.applyBrokerSettingsChange()

        XCTAssertEqual(factory.policies.map(\.networkAccess), [.loopback, .network])
        let firstStops = await factory.servers[0].stopCallCount
        XCTAssertEqual(firstStops, 1, "the loopback-bound listener must be torn down before rebinding")
        let secondStarts = await factory.servers[1].startCallCount
        XCTAssertEqual(secondStarts, 1)
    }

    func test_reapplyingIdenticalNetworkSettings_doesNotRestartTheServer() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        try await settingsRepository.save(settings)

        let factory = RecordingBrokerLoopbackServerFactory()
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: FakeBrokerService(),
            brokerServerFactory: { _, port, policy in factory.make(port: port, policy: policy) },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
        )

        await appModel.bootstrap()
        await appModel.applyBrokerSettingsChange()

        XCTAssertEqual(factory.policies.count, 1, "an unchanged access policy must not rebind the socket")
    }

    func test_enablingAnAPIKeyMode_generatesStoresAndServesTheKey() async throws {
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.apiKeyMode = .none
        try await settingsRepository.save(settings)

        let keychain = KeychainRepositoryFake()
        let factory = RecordingBrokerLoopbackServerFactory()
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychain,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: FakeBrokerService(),
            brokerServerFactory: { _, port, policy in factory.make(port: port, policy: policy) },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
        )

        await appModel.bootstrap()
        XCTAssertNil(appModel.brokerAPIKey, "no key is provisioned while none is required")

        appModel.settings.broker.apiKeyMode = .all
        await appModel.ensureBrokerAPIKey()

        let stored = try await keychain.retrieve(account: BrokerAccessPolicy.keychainAccount)
        let published = try XCTUnwrap(appModel.brokerAPIKey)
        XCTAssertEqual(stored, published)
        XCTAssertTrue(published.hasPrefix("pm_"))

        // The running server must be rebuilt around the new key, not left
        // comparing against nothing.
        let lastPolicy = try XCTUnwrap(factory.policies.last)
        XCTAssertEqual(lastPolicy.apiKeyMode, .all)
        XCTAssertEqual(lastPolicy.apiKey, published)
    }

    func test_ensureBrokerAPIKey_withNoKeyRequired_provisionsNothing() async throws {
        let keychain = KeychainRepositoryFake()
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: keychain,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: FakeBrokerService(),
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
        )

        await appModel.bootstrap()
        appModel.settings.broker.apiKeyMode = .none
        await appModel.ensureBrokerAPIKey()

        let exists = await keychain.exists(account: BrokerAccessPolicy.keychainAccount)
        XCTAssertFalse(exists)
        XCTAssertNil(appModel.brokerAPIKey)
    }

    func test_ensureBrokerAPIKey_keepsAnAlreadyStoredKey() async throws {
        let keychain = KeychainRepositoryFake()
        try await keychain.save(sessionKey: "pm_existing", account: BrokerAccessPolicy.keychainAccount)

        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.apiKeyMode = .all
        try await settingsRepository.save(settings)

        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychain,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: FakeBrokerService(),
            brokerServerFactory: { _, _, _ in FakeBrokerLoopbackServer() },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
        )

        await appModel.bootstrap()
        XCTAssertEqual(appModel.brokerAPIKey, "pm_existing", "bootstrap must publish the stored key")

        await appModel.ensureBrokerAPIKey()

        let stored = try await keychain.retrieve(account: BrokerAccessPolicy.keychainAccount)
        XCTAssertEqual(stored, "pm_existing", "an existing key must never be silently rotated")
    }

    func test_regenerateBrokerAPIKey_replacesTheKeyAndRestartsTheServer() async throws {
        let keychain = KeychainRepositoryFake()
        try await keychain.save(sessionKey: "pm_old", account: BrokerAccessPolicy.keychainAccount)

        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.broker.apiKeyMode = .all
        try await settingsRepository.save(settings)

        let factory = RecordingBrokerLoopbackServerFactory()
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychain,
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "no key"))),
            notificationService: NotificationServiceSpy(),
            brokerService: FakeBrokerService(),
            brokerServerFactory: { _, port, policy in factory.make(port: port, policy: policy) },
            t3LivenessChecker: BrokerAppModelFakeT3LivenessChecker(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake()
        )

        await appModel.bootstrap()
        XCTAssertEqual(factory.policies.last?.apiKey, "pm_old")

        await appModel.regenerateBrokerAPIKey()

        let published = try XCTUnwrap(appModel.brokerAPIKey)
        XCTAssertNotEqual(published, "pm_old")
        let stored = try await keychain.retrieve(account: BrokerAccessPolicy.keychainAccount)
        XCTAssertEqual(stored, published)

        XCTAssertEqual(factory.policies.count, 2, "the running server must be rebuilt around the new key")
        XCTAssertEqual(factory.policies.last?.apiKey, published)
        let firstStops = await factory.servers[0].stopCallCount
        XCTAssertEqual(firstStops, 1)
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
    private(set) var livenessRefreshCallCount = 0
    private(set) var lastLivenessInstances: [T3InstanceConfig] = []
    private var liveness: [String: T3Liveness] = [:]
    private var nextLiveness: [String: T3Liveness] = [:]

    private(set) var pickCalls: [(role: String, caller: String?)] = []
    private(set) var downCalls: [(target: String, minutes: Int?)] = []
    private(set) var upCalls: [String] = []
    private(set) var refreshCallCount = 0

    private var uiState = BrokerUIState.initial
    private var continuations: [UUID: AsyncStream<BrokerUIState>.Continuation] = [:]

    /// The stored check AppModel's re-check reminder reads. Set directly
    /// rather than recorded, so a test can date a record without driving the
    /// store's merge rules.
    private var instructionCheck: InstructionCheck?

    func setInstructionCheck(_ check: InstructionCheck?) {
        instructionCheck = check
    }

    func latestInstructionCheck() async -> InstructionCheck? { instructionCheck }

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

    func down(target: String, minutes: Int?) async throws {
        downCalls.append((target, minutes))
    }

    func up(target: String) async throws {
        upCalls.append(target)
    }

    func refresh() async throws {
        refreshCallCount += 1
        _ = await refreshT3Liveness()
        try await invokeRefreshHandler()
    }

    // MARK: BrokerLifecycleProtocol

    func updatePolicy(_ policy: BrokerPolicy) async {
        updatedPolicies.append(policy)
    }

    func updateOracleSnapshot(_ oracle: OracleSnapshot?) async {
        pushedOracleSnapshots.append(oracle)
    }

    func updateT3Liveness(_ liveness: [String: T3Liveness]) async {
        self.liveness = liveness
        pushedLiveness.append(liveness)
    }

    func setLivenessResult(_ liveness: [String: T3Liveness]) {
        nextLiveness = liveness
    }

    func refreshT3Liveness() async -> [String: T3Liveness] {
        livenessRefreshCallCount += 1
        lastLivenessInstances = updatedPolicies.last?.t3Instances ?? []
        liveness = nextLiveness
        pushedLiveness.append(liveness)
        return liveness
    }

    func t3LivenessSnapshot() async -> [String: T3Liveness] { liveness }

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

/// Hands out a fresh `FakeBrokerLoopbackServer` per start and records the port
/// and access policy each one was built with, so a test can assert *what* the
/// server was rebound with rather than only that it restarted.
private final class RecordingBrokerLoopbackServerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPorts: [UInt16] = []
    private var recordedPolicies: [BrokerAccessPolicy] = []
    private var madeServers: [FakeBrokerLoopbackServer] = []

    var ports: [UInt16] { lock.withLock { recordedPorts } }
    var policies: [BrokerAccessPolicy] { lock.withLock { recordedPolicies } }
    var servers: [FakeBrokerLoopbackServer] { lock.withLock { madeServers } }

    func make(port: UInt16, policy: BrokerAccessPolicy) -> any BrokerLoopbackServerProtocol {
        let server = FakeBrokerLoopbackServer(startResult: .success(port == 0 ? 43117 : port))
        lock.withLock {
            recordedPorts.append(port)
            recordedPolicies.append(policy)
            madeServers.append(server)
        }
        return server
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

private actor BrokerAppModelT3UsageServiceFake: T3UsageServiceProtocol {
    private let result: T3UsageRefreshResult
    private(set) var callCount = 0
    private(set) var availabilities: [T3UsageInstanceAvailability] = []

    init(result: T3UsageRefreshResult) {
        self.result = result
    }

    func refresh(
        instanceAvailability: T3UsageInstanceAvailability,
        request: T3UsageRequest,
        quota: UsageTelemetryQuotaSnapshot
    ) -> T3UsageRefreshResult {
        callCount += 1
        availabilities.append(instanceAvailability)
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

private actor BrokerTestGeminiAPIKeyRepositoryFake: GeminiAPIKeyRepositoryProtocol {
    func save(_ apiKey: GeminiAPIKey, account: String) {}
    func load(account: String) throws -> GeminiAPIKey { throw GeminiAPIKeyRepositoryError.notFound }
    func validate(account: String) -> GeminiAPIKeyAcquisitionStatus {
        .init(state: .missing, lastErrorCategory: .notFound)
    }
    func clear(account: String) {}
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
