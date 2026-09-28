import XCTest
@testable import Pinemeter

@MainActor
final class RemotePushCoordinatorTests: XCTestCase {
    func testAutomaticBurstCoalescesAndNoHostsReserveNothing() async throws {
        let harness = PushHarness()
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(harness: harness, sleeper: sleeper)

        await coordinator.scheduleAutomaticPush()
        await coordinator.scheduleAutomaticPush()
        await coordinator.scheduleAutomaticPush()
        try await eventually { await sleeper.pendingCount == 1 }
        await sleeper.releaseAll()
        try await eventually { await harness.sendCount == 1 }

        await harness.removeAllHosts()
        await coordinator.scheduleAutomaticPush()
        await sleeper.releaseAll()
        for _ in 0..<20 { await Task.yield() }

        let sends = await harness.sendCount
        let generations = await harness.generations
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(generations, [1])
    }

    func testRemovalCancelsDebounceWithoutReservingGeneration() async throws {
        let harness = PushHarness()
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(harness: harness, sleeper: sleeper)
        let hostID = await harness.hostID

        await coordinator.scheduleAutomaticPush()
        try await eventually { await sleeper.pendingCount == 1 }
        await coordinator.hostRemoved(hostID)
        await sleeper.releaseAll()
        for _ in 0..<20 { await Task.yield() }

        let sends = await harness.sendCount
        let generations = await harness.generations
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(generations, [])
    }

    func testManualBypassesDebounceAndAcceptedDeliveryRemainsUnknown() async throws {
        let harness = PushHarness()
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(harness: harness, sleeper: sleeper)
        let hostID = await harness.hostID

        await coordinator.manualPush(hostID: hostID)
        try await eventually { await harness.finishedUpdates.count == 1 }

        let updates = await harness.finishedUpdates
        let pendingSleeps = await sleeper.pendingCount
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].result, .succeeded)
        XCTAssertNil(updates[0].sanitizedError)
        XCTAssertEqual(pendingSleeps, 0)
    }

    func testMutationDuringSendQueuesOneFreshGenerationFollowUp() async throws {
        let harness = PushHarness(blockFirstSend: true)
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(harness: harness, sleeper: sleeper)
        let hostID = await harness.hostID

        await coordinator.manualPush(hostID: hostID)
        try await eventually { await harness.sendCount == 1 }
        await coordinator.scheduleAutomaticPush()
        await coordinator.scheduleAutomaticPush()
        await harness.releaseFirstSend()
        try await eventually { await harness.sendCount == 2 }

        let generations = await harness.generations
        XCTAssertEqual(generations, [1, 2])
    }

    func testLostAcknowledgementRetriesAtBoundedDelaysWithNewGenerations() async throws {
        let harness = PushHarness(sendFailuresBeforeSuccess: 4)
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(harness: harness, sleeper: sleeper)
        let hostID = await harness.hostID

        await coordinator.manualPush(hostID: hostID)
        try await eventually { await harness.sendCount == 1 }
        for expectedDelay in RemotePushCoordinator.retryDelays {
            try await eventually { await sleeper.pendingDurations.contains(expectedDelay) }
            await sleeper.releaseAll()
            try await eventually {
                await harness.sendCount == RemotePushCoordinator.retryDelays.firstIndex(of: expectedDelay)! + 2
            }
        }

        let exhaustedCount = await harness.sendCount
        XCTAssertEqual(exhaustedCount, 4)
        await coordinator.retryPending()
        try await eventually { await harness.sendCount == 5 }

        let generations = await harness.generations
        let updates = await harness.finishedUpdates
        let results = updates.map(\.result)
        XCTAssertEqual(generations, [1, 2, 3, 4, 5])
        XCTAssertEqual(results, [.failed, .failed, .failed, .failed, .succeeded])
    }

    func testBrokerCooldownMutationsEmitOnlyAfterSuccessfulWrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-push-broker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = MutationCounter()
        let service = BrokerService(
            cooldownStore: BrokerCooldownStore(
                storeDirectory: directory,
                cliCooldownsURL: directory.appendingPathComponent("cli.json")
            ),
            auditStore: BrokerAuditStore(storeDirectory: directory)
        )
        await service.setSuccessfulCooldownMutationHandler {
            Task { await counter.increment() }
        }

        try await service.down(target: "t3", minutes: 5)
        try await service.up(target: "t3")
        try await service.resetCooldowns()
        do {
            try await service.down(target: "not-a-target", minutes: 5)
            XCTFail("invalid target must fail")
        } catch {}
        try await eventually { await counter.value == 3 }

        let count = await counter.value
        XCTAssertEqual(count, 3)
    }

    func testStatusOnlySettingsSaveDoesNotScheduleAnotherPush() {
        var previous = AppSettings.default
        var statusOnly = previous
        statusOnly.broker.remoteHosts = [RemoteHost(
            host: "host.example.com",
            sshUser: "pinemeter",
            keyPath: "/tmp/id_ed25519",
            secretReference: "reference",
            pinnedHostKeyFingerprint: "SHA256:fixture",
            lastPushAt: Date(),
            lastPushResult: .succeeded
        )]
        XCTAssertFalse(AppModel.remotePushPayloadChanged(from: previous, to: statusOnly))

        previous.broker.policy.allowForcedDegraded["fixture"] = false
        XCTAssertTrue(AppModel.remotePushPayloadChanged(from: statusOnly, to: previous))
    }

    func testUnrelatedSettingsSaveCannotDiscardPendingPushTrigger() async throws {
        let repository = SettingsRepositoryFake()
        let harness = PushHarness()
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(harness: harness, sleeper: sleeper)
        let appModel = AppModel(
            settingsRepository: repository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(PushHarnessError.unavailable)),
            chatGPTSessionRepository: MissingChatGPTSessionRepository(),
            geminiAPIKeyRepository: MissingGeminiAPIKeyRepository(),
            notificationService: NotificationServiceSpy(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake(),
            remotePushCoordinator: coordinator
        )
        await appModel.bootstrap()

        appModel.settings.broker.policy.allowForcedDegraded["fixture"] = false
        appModel.settings.hasNotificationsEnabled.toggle()

        try await eventually { await sleeper.pendingCount == 1 }
    }

    func testAppModelPersistsSuccessfulAttemptWithoutSchedulingFeedback() async throws {
        let host = RemoteHost(
            host: "host.example.com",
            sshUser: "pinemeter",
            keyPath: "/tmp/id_ed25519",
            secretReference: "reference",
            pinnedHostKeyFingerprint: "SHA256:fixture"
        )
        let settingsRepository = SettingsRepositoryFake()
        var initialSettings = AppSettings.default
        initialSettings.broker.remoteHosts = [host]
        try await settingsRepository.save(initialSettings)

        let harness = PushHarness(hosts: [host])
        let sleeper = ManualPushSleeper()
        let modelReference = AppModelReference()
        let coordinator = makeCoordinator(
            harness: harness,
            sleeper: sleeper,
            recordUpdate: { update in await modelReference.record(update) }
        )
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(PushHarnessError.unavailable)),
            chatGPTSessionRepository: MissingChatGPTSessionRepository(),
            geminiAPIKeyRepository: MissingGeminiAPIKeyRepository(),
            notificationService: NotificationServiceSpy(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake(),
            remotePushCoordinator: coordinator
        )
        modelReference.value = appModel
        await appModel.bootstrap()

        appModel.settings.broker.policy.allowForcedDegraded["fixture"] = false
        try await eventually { await sleeper.pendingCount == 1 }
        await sleeper.releaseAll()
        try await eventually {
            let result = await appModel.settings.broker.remoteHosts[0].lastPushResult
            return result == .succeeded
        }

        let persisted = await settingsRepository.load()
        let sends = await harness.sendCount
        XCTAssertEqual(persisted.broker.remoteHosts[0].lastPushResult, .succeeded)
        XCTAssertEqual(persisted.broker.remoteHosts[0].credentialStatus, .unknown)
        XCTAssertEqual(sends, 1)

        await sleeper.releaseAll()
        for _ in 0..<20 { await Task.yield() }
        let finalSends = await harness.sendCount
        XCTAssertEqual(finalSends, 1)
    }

    private func makeCoordinator(
        harness: PushHarness,
        sleeper: ManualPushSleeper,
        recordUpdate: (@Sendable (RemotePushAttemptUpdate) async -> Void)? = nil
    ) -> RemotePushCoordinator {
        RemotePushCoordinator(
            loadSource: { await harness.source() },
            reserveGeneration: { try await harness.reserveGeneration() },
            buildBundle: { generation, _, source in
                await harness.recordBuild(generation: generation, source: source)
                return Data("{\"generation\":\(generation)}".utf8)
            },
            send: { bundle, host in try await harness.send(bundle: bundle, host: host) },
            recordUpdate: { update in
                await harness.record(update)
                await recordUpdate?(update)
            },
            sleep: { duration in try await sleeper.sleep(duration) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    private func eventually(
        _ condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Condition was not met", file: file, line: line)
    }
}

private actor PushHarness {
    struct FinishedUpdate: Equatable {
        let result: RemotePushResult
        let sanitizedError: String?
    }

    private var hosts: [RemoteHost]
    private var nextGeneration: UInt64 = 0
    private(set) var generations: [UInt64] = []
    private(set) var sendCount = 0
    private(set) var finishedUpdates: [FinishedUpdate] = []
    private var remainingFailures: Int
    private let blockFirstSend: Bool
    private var firstSendContinuation: CheckedContinuation<Void, Never>?
    private var releaseFirstSendRequested = false

    init(
        hosts: [RemoteHost] = [RemoteHost(
            host: "host.example.com",
            sshUser: "pinemeter",
            keyPath: "/tmp/id_ed25519",
            secretReference: "reference",
            pinnedHostKeyFingerprint: "SHA256:fixture"
        )],
        blockFirstSend: Bool = false,
        sendFailuresBeforeSuccess: Int = 0
    ) {
        self.hosts = hosts
        self.blockFirstSend = blockFirstSend
        remainingFailures = sendFailuresBeforeSuccess
    }

    var hostID: UUID { hosts[0].id }

    func source() -> RemotePushSourceSnapshot {
        RemotePushSourceSnapshot(
            hosts: hosts,
            inventory: RemotePushAccountInventory(claude: [], chatGPT: [], gemini: []),
            policy: .default,
            cooldowns: [:],
            oracleSnapshot: nil
        )
    }

    func removeAllHosts() {
        hosts = []
    }

    func reserveGeneration() throws -> UInt64 {
        nextGeneration += 1
        generations.append(nextGeneration)
        return nextGeneration
    }

    func recordBuild(generation: UInt64, source: RemotePushSourceSnapshot) {
        precondition(source.hosts.isEmpty == false)
        precondition(generations.contains(generation))
    }

    func send(bundle: Data, host: RemoteHost) async throws {
        precondition(hosts.contains(where: { $0.id == host.id }))
        precondition(bundle.isEmpty == false)
        sendCount += 1
        if blockFirstSend, sendCount == 1 {
            if releaseFirstSendRequested {
                releaseFirstSendRequested = false
            } else {
                await withCheckedContinuation { firstSendContinuation = $0 }
            }
        }
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw PushHarnessError.lostAcknowledgement
        }
    }

    func releaseFirstSend() {
        if let firstSendContinuation {
            firstSendContinuation.resume()
            self.firstSendContinuation = nil
        } else {
            releaseFirstSendRequested = true
        }
    }

    func record(_ update: RemotePushAttemptUpdate) {
        guard case .finished(_, _, let result, let error) = update else { return }
        finishedUpdates.append(FinishedUpdate(result: result, sanitizedError: error))
    }
}

private enum PushHarnessError: Error {
    case lostAcknowledgement
    case unavailable
}

private actor MissingChatGPTSessionRepository: ChatGPTSessionRepositoryProtocol {
    func save(_ session: ChatGPTSession, account: String) {}
    func load(account: String) throws -> ChatGPTSession { throw ChatGPTSessionRepositoryError.notFound }
    func validate(account: String) -> ChatGPTSessionAcquisitionStatus {
        .init(state: .missing, lastErrorCategory: .notFound)
    }
    func clear(account: String) {}
}

private actor MissingGeminiAPIKeyRepository: GeminiAPIKeyRepositoryProtocol {
    func save(_ apiKey: GeminiAPIKey, account: String) {}
    func load(account: String) throws -> GeminiAPIKey { throw GeminiAPIKeyRepositoryError.notFound }
    func validate(account: String) -> GeminiAPIKeyAcquisitionStatus {
        .init(state: .missing, lastErrorCategory: .notFound)
    }
    func clear(account: String) {}
}

@MainActor
private final class AppModelReference {
    weak var value: AppModel?

    func record(_ update: RemotePushAttemptUpdate) async {
        await value?.applyRemotePushUpdate(update)
    }
}

private actor MutationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor ManualPushSleeper {
    private struct Waiter {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [UUID: Waiter] = [:]
    private var cancelled = Set<UUID>()

    var pendingCount: Int { waiters.count }
    var pendingDurations: [Duration] { waiters.values.map(\.duration) }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        let operation: () async throws -> Void = {
            try await withCheckedThrowingContinuation { continuation in
                if self.cancelled.remove(id) != nil || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.waiters[id] = Waiter(duration: duration, continuation: continuation)
                }
            }
        }
        try await withTaskCancellationHandler(operation: operation) {
            Task { await self.cancel(id) }
        }
    }

    func releaseAll() {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
        }
    }
}
