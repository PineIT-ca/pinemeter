import XCTest
@testable import Pinemeter

@MainActor
final class RemotePushCoordinatorTests: XCTestCase {
    func testReplayRecoveryFailureMatrix() async throws {
        let cases = [
            "status", "missing status", "missing floor", "floor", "exhaustion",
            "build", "resend replay", "resend timeout", "lag zero", "lag stale", "large floor", "max jump"
        ]
        for scenario in cases {
            let succeeds = ["lag zero", "lag stale", "max jump"].contains(scenario)
            let maxJumpFloor = 3 + RemotePushCoordinator.maxReplayFloorJump
            let floor: UInt64 = scenario == "exhaustion" ? .max
                : scenario == "large floor" ? maxJumpFloor + 1
                : scenario == "max jump" ? maxJumpFloor
                : scenario == "lag zero" ? 0 : scenario == "lag stale" ? 1 : 4
            let retryGeneration: UInt64 = scenario == "max jump" ? maxJumpFloor + 1 : succeeds ? 4 : 5
            let sendResults: [RemoteSSHTransportError?] = [
                .generationReplay,
                scenario == "resend replay" ? .generationReplay : scenario == "resend timeout" ? .timedOut : nil
            ]
            let harness = PushHarness(initialGeneration: 2, sendResults: sendResults)
            let sleeper = ManualPushSleeper()
            let statusFetcher: RemotePushCoordinator.StatusFetcher = { _ in
                if scenario == "status" { throw PushHarnessError.unavailable }
                return await harness.status(acceptedGeneration: floor)
            }
            let floorReserver: RemotePushCoordinator.GenerationFloorReserver = { floor in
                if scenario == "floor" { throw SettingsRepositoryError.storedSettingsUnreadable }
                return try await harness.reserveGeneration(after: floor)
            }
            let fetchStatus = scenario == "missing status" ? nil : statusFetcher
            let reserve = scenario == "missing floor" ? nil : floorReserver
            let coordinator = makeCoordinator(
                harness: harness, sleeper: sleeper, fetchStatus: fetchStatus,
                reserveGenerationAfter: reserve,
                beforeBuild: { generation in
                    if scenario == "build", generation != 3 { throw PushHarnessError.unavailable }
                }
            )
            await coordinator.manualPush(hostID: harness.hostID)
            try await eventually { await harness.finishedUpdates.count == 1 }
            if !succeeds { try await eventually { await sleeper.pendingCount == 1 } }
            let sends = await harness.sentGenerations
            let builds = await harness.builtGenerations
            let updates = await harness.finishedUpdates
            let expectedSends = succeeds ? [3, retryGeneration]
                : scenario.hasPrefix("resend") ? [3, 5] : [3]
            XCTAssertEqual(sends, expectedSends, scenario)
            XCTAssertLessThanOrEqual(sends.count, 2, scenario)
            XCTAssertEqual(updates, [.init(
                result: succeeds ? .succeeded : .failed,
                sanitizedError: succeeds ? nil : RemoteSSHTransportError.generationReplay.errorDescription
            )], scenario)
            if scenario == "exhaustion" || scenario == "large floor" {
                let floors = await harness.reservationFloors
                XCTAssertEqual(builds, [3], "An implausible floor must not wrap or rebuild")
                XCTAssertEqual(floors, [], "An implausible floor must not move the shared counter")
            }
            if succeeds {
                let floors = await harness.reservationFloors
                XCTAssertEqual(floors, [floor], scenario)
                XCTAssertEqual(builds, [3, retryGeneration], scenario)
            }
            await coordinator.hostRemoved(harness.hostID)
        }
    }

    func testReplayRecoveryCancellation() async throws {
        for stage in ["status", "floor", "build", "resend"] {
            for cancellation in ["removal", "CancellationError", "transport cancelled"] {
                let harness = PushHarness(initialGeneration: 2, sendResults: [.generationReplay, nil])
                let sleeper = ManualPushSleeper()
                let gate = ReplayRecoveryGate()
                let checkpoint: @Sendable (String) async throws -> Void = { currentStage in
                    guard currentStage == stage else { return }
                    await gate.markEntered()
                    if cancellation == "CancellationError" { throw CancellationError() }
                    if cancellation == "transport cancelled" { throw RemoteSSHTransportError.cancelled }
                    await gate.wait()
                    if currentStage == "resend" { try Task.checkCancellation() }
                }
                let coordinator = makeCoordinator(
                    harness: harness, sleeper: sleeper,
                    fetchStatus: { _ in
                        try await checkpoint("status")
                        return await harness.status(acceptedGeneration: 4)
                    },
                    reserveGenerationAfter: { floor in
                        try await checkpoint("floor")
                        return try await harness.reserveGeneration(after: floor)
                    },
                    beforeBuild: { generation in
                        if generation != 3 { try await checkpoint("build") }
                    },
                    beforeSend: { generation in
                        if generation != 3 { try await checkpoint("resend") }
                    }
                )
                let hostID = await harness.hostID
                await coordinator.manualPush(hostID: hostID)
                if cancellation == "removal" {
                    try await eventually { await gate.entered }
                    await harness.removeAllHosts()
                    await coordinator.hostRemoved(hostID)
                    await gate.release()
                }
                if cancellation != "removal" {
                    try await eventually { await gate.entered }
                }
                for _ in 0..<50 { await Task.yield() }
                let sends = await harness.sentGenerations
                let builds = await harness.builtGenerations
                let updates = await harness.finishedUpdates
                let statuses = await harness.statusUpdates
                let delays = await sleeper.pendingDurations
                XCTAssertEqual(sends, [3], "\(stage): \(cancellation)")
                let rebuilt = stage == "resend" || (stage == "build" && cancellation == "removal")
                XCTAssertEqual(builds, rebuilt ? [3, 5] : [3], "\(stage): \(cancellation)")
                XCTAssertTrue(updates.isEmpty, "\(stage): \(cancellation)")
                XCTAssertTrue(statuses.isEmpty)
                XCTAssertTrue(delays.isEmpty)
                await coordinator.hostRemoved(hostID)
            }
        }
    }

    func testReplayRecoveryKeepsOuterRetrySchedule() async throws {
        let harness = PushHarness(initialGeneration: 2, sendResults: Array(repeating: .generationReplay, count: 8))
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(
            harness: harness, sleeper: sleeper,
            fetchStatus: { _ in await harness.status(acceptedGeneration: 4) },
            reserveGenerationAfter: { try await harness.reserveGeneration(after: $0) }
        )
        await coordinator.manualPush(hostID: harness.hostID)
        let delays: [Duration] = [.seconds(1), .seconds(5), .seconds(30)]
        XCTAssertEqual(RemotePushCoordinator.retryDelays, delays)
        for (index, delay) in delays.enumerated() {
            try await eventually { await sleeper.pendingDurations == [delay] }
            let sends = await harness.sendCount
            XCTAssertEqual(sends, (index + 1) * 2)
            await sleeper.releaseAll()
        }
        try await eventually { await harness.finishedUpdates.count == 4 }
        let sends = await harness.sentGenerations
        let updates = await harness.finishedUpdates
        let pending = await sleeper.pendingCount
        XCTAssertEqual(sends, [3, 5, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(updates, Array(repeating: .init(
            result: .failed, sanitizedError: RemoteSSHTransportError.generationReplay.errorDescription
        ), count: 4))
        XCTAssertEqual(pending, 0)
        try await eventually {
            await coordinator.retryPending()
            return await harness.finishedUpdates.count == 5
        }
        let retried = await harness.finishedUpdates
        XCTAssertEqual(retried.last, .init(result: .succeeded, sanitizedError: nil))
        await coordinator.hostRemoved(harness.hostID)
    }

    func testUnreadableSettingsReservationUsesFixedMessage() async throws {
        let harness = PushHarness()
        let sleeper = ManualPushSleeper()
        let coordinator = RemotePushCoordinator(
            loadSource: { await harness.source() },
            reserveGeneration: { throw SettingsRepositoryError.storedSettingsUnreadable },
            buildBundle: { _, _, _ in XCTFail("Unreadable settings must not build"); return Data() },
            send: { _, _ in XCTFail("Unreadable settings must not send") },
            recordUpdate: { await harness.record($0) },
            sleep: { try await sleeper.sleep($0) }
        )
        await coordinator.manualPush(hostID: harness.hostID)
        try await eventually { await harness.finishedUpdates.count == 1 }
        let updates = await harness.finishedUpdates
        XCTAssertEqual(updates, [.init(result: .failed, sanitizedError:
            "Push failed: saved settings could not be read, so Pinemeter did not save a new push generation."
        )])
        await coordinator.hostRemoved(harness.hostID)
    }

    func testReplayRecoversOnceAboveHostGeneration() async throws {
        let suite = "RemotePushCoordinatorTests.replay.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        var settings = AppSettings.default
        settings.broker.pushGeneration = 2
        try await repository.save(settings)
        let harness = PushHarness(initialGeneration: 2, sendResults: [.generationReplay, nil])
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(
            harness: harness,
            sleeper: sleeper,
            fetchStatus: { _ in
                let sends = await harness.sendCount
                return await harness.status(acceptedGeneration: sends == 1 ? 4 : 5)
            },
            reserveGenerationAfter: { floor in
                let generation = try await repository.reservePushGeneration(after: floor)
                await harness.recordReservation(generation, floor: floor)
                return generation
            }
        )

        await coordinator.manualPush(hostID: harness.hostID)
        try await eventually { await harness.statusUpdates.count == 1 }
        let sends = await harness.sentGenerations
        let builds = await harness.builtGenerations
        let floors = await harness.reservationFloors
        let updates = await harness.finishedUpdates
        let statusCalls = await harness.statusSendCounts
        let observations = await harness.statusUpdates
        let persisted = await SettingsRepository(userDefaults: defaults).load()
        XCTAssertEqual(sends, [3, 5])
        XCTAssertEqual(builds, [3, 5])
        XCTAssertEqual(floors, [4])
        XCTAssertEqual(statusCalls, [1, 2], "Recovery status precedes resend; normal refresh follows it")
        XCTAssertEqual(updates, [.init(result: .succeeded, sanitizedError: nil)])
        XCTAssertEqual(observations.last?.status, .fresh, "Post-success status must use retry generation 5")
        XCTAssertEqual(persisted.broker.pushGeneration, 5)

        await coordinator.refreshStatus()
        try await eventually { await harness.statusUpdates.count == 2 }
        let refreshed = await harness.statusUpdates
        XCTAssertEqual(refreshed.last?.status, .fresh, "Cached accepted generation must also be 5")
        await coordinator.hostRemoved(harness.hostID)
    }

    func testResidencyGuardRefusesUnsupportedBeforeBuildingOrSending() async throws {
        let harness = PushHarness(residencyRoles: ["execution": .controlled])
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(harness: harness, sleeper: sleeper, fetchCapabilities: { _ in .unsupported })
        await coordinator.manualPush(hostID: harness.hostID)
        try await eventually { await harness.finishedUpdates.count == 1 }
        let updates = await harness.finishedUpdates
        XCTAssertEqual(updates, [.init(result: .failed, sanitizedError:
            "Not pushed: the broker on gpu-a.example does not support Controlled infrastructure only, and it would send execution to vendor models. Update the broker on gpu-a.example, or turn off Controlled infrastructure only for those roles, then push again."
        )])
        let sends = await harness.sendCount
        let builds = await harness.buildCount
        let generations = await harness.generations
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(builds, 0)
        XCTAssertEqual(generations, [])
        await coordinator.hostRemoved(harness.hostID)
    }

    func testResidencyGuardUnreadableResponseKeepsExistingFailureAndNeverSends() async throws {
        let harness = PushHarness(residencyRoles: ["execution": .controlled])
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(harness: harness, sleeper: sleeper, fetchCapabilities: { _ in
            await harness.recordCapability()
            throw RemoteSSHTransportError.invalidResponse
        })
        await coordinator.manualPush(hostID: harness.hostID)
        try await eventually { await harness.finishedUpdates.count == 1 }
        let updates = await harness.finishedUpdates
        XCTAssertEqual(updates, [.init(result: .failed, sanitizedError: "Push failed: the remote response was invalid.")])
        let counts = await harness.operationCounts
        XCTAssertEqual(counts, [1, 0, 0])
        await coordinator.hostRemoved(harness.hostID)
    }

    func testResidencyGuardMissingFetcherFailsClosed() async throws {
        let harness = PushHarness(residencyRoles: ["execution": .controlled])
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(harness: harness, sleeper: sleeper)
        await coordinator.manualPush(hostID: harness.hostID)
        try await eventually { await harness.finishedUpdates.count == 1 }
        let updates = await harness.finishedUpdates
        XCTAssertEqual(updates, [.init(result: .failed, sanitizedError: "Push failed: the remote response was invalid.")])
        let counts = await harness.operationCounts
        XCTAssertEqual(counts, [0, 0, 0])
        await coordinator.hostRemoved(harness.hostID)
    }

    func testResidencyGuardSupportedManualAutomaticAndRetryPushesCheckEveryAttempt() async throws {
        let harness = PushHarness(sendFailuresBeforeSuccess: 1, residencyRoles: ["execution": .controlled])
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(harness: harness, sleeper: sleeper, fetchCapabilities: { _ in
            await harness.recordCapability()
            return .supported
        })
        await coordinator.manualPush(hostID: harness.hostID)
        try await eventually { await harness.finishedUpdates.count == 1 }
        try await eventually { await sleeper.pendingCount == 1 }
        await sleeper.releaseAll()
        try await eventually { await harness.finishedUpdates.count == 2 }
        await coordinator.scheduleAutomaticPush()
        try await eventually { await sleeper.pendingCount == 1 }
        await sleeper.releaseAll()
        try await eventually { await harness.finishedUpdates.count == 3 }
        let counts = await harness.operationCounts
        let updates = await harness.finishedUpdates
        XCTAssertEqual(counts, [3, 3, 3])
        XCTAssertEqual(updates.map(\.result), [.failed, .succeeded, .succeeded])
        await coordinator.hostRemoved(harness.hostID)
    }

    func testResidencyGuardEmptyRolesSkipCapabilitiesOnManualAutomaticAndAllRetries() async throws {
        let harness = PushHarness(sendFailuresBeforeSuccess: 4)
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(harness: harness, sleeper: sleeper, fetchCapabilities: { _ in
            await harness.recordCapability()
            throw RemoteSSHTransportError.invalidResponse
        })
        await coordinator.manualPush(hostID: harness.hostID)
        try await eventually { await harness.finishedUpdates.count == 1 }
        for count in 2...4 {
            try await eventually { await sleeper.pendingCount == 1 }
            await sleeper.releaseAll()
            try await eventually { await harness.finishedUpdates.count == count }
        }
        await coordinator.retryPending()
        try await eventually { await harness.finishedUpdates.count == 5 }
        await coordinator.scheduleAutomaticPush()
        try await eventually { await sleeper.pendingCount == 1 }
        await sleeper.releaseAll()
        try await eventually { await harness.finishedUpdates.count == 6 }
        let counts = await harness.operationCounts
        let updates = await harness.finishedUpdates
        XCTAssertEqual(counts, [0, 6, 6])
        XCTAssertEqual(updates.map(\.result), [.failed, .failed, .failed, .failed, .succeeded, .succeeded])
        await coordinator.hostRemoved(harness.hostID)
    }

    func testResidencyGuardSortsRestrictedRolesAndRechecksAfterRefusalOnRetries() async throws {
        let harness = PushHarness(residencyRoles: ["verification": .controlled, "execution": .controlled])
        let sleeper = ManualPushSleeper()
        let coordinator = makeCoordinator(harness: harness, sleeper: sleeper, fetchCapabilities: { _ in
            await harness.recordCapability()
            return .unsupported
        })
        await coordinator.manualPush(hostID: harness.hostID)
        try await eventually { await harness.finishedUpdates.count == 1 }
        for count in 2...4 {
            try await eventually { await sleeper.pendingCount == 1 }
            await sleeper.releaseAll()
            try await eventually { await harness.finishedUpdates.count == count }
        }
        await coordinator.retryPending()
        try await eventually { await harness.finishedUpdates.count == 5 }
        let updates = await harness.finishedUpdates
        for update in updates {
            XCTAssertEqual(update, .init(result: .failed, sanitizedError:
                "Not pushed: the broker on gpu-a.example does not support Controlled infrastructure only, and it would send execution, verification to vendor models. Update the broker on gpu-a.example, or turn off Controlled infrastructure only for those roles, then push again."
            ))
        }
        let counts = await harness.operationCounts
        XCTAssertEqual(counts, [5, 0, 0])
        await coordinator.hostRemoved(harness.hostID)
    }

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
        recordUpdate: (@Sendable (RemotePushAttemptUpdate) async -> Void)? = nil,
        fetchCapabilities: RemotePushCoordinator.CapabilityFetcher? = nil,
        fetchStatus: RemotePushCoordinator.StatusFetcher? = nil,
        reserveGenerationAfter: RemotePushCoordinator.GenerationFloorReserver? = nil,
        beforeBuild: (@Sendable (UInt64) async throws -> Void)? = nil,
        beforeSend: (@Sendable (UInt64) async throws -> Void)? = nil
    ) -> RemotePushCoordinator {
        RemotePushCoordinator(
            loadSource: { await harness.source() },
            reserveGeneration: { try await harness.reserveGeneration() },
            reserveGenerationAfter: reserveGenerationAfter,
            buildBundle: { generation, _, source in
                try await beforeBuild?(generation)
                await harness.recordBuild(generation: generation, source: source)
                return Data("{\"generation\":\(generation)}".utf8)
            },
            send: { bundle, host in
                let object = try JSONSerialization.jsonObject(with: bundle) as! [String: NSNumber]
                try await beforeSend?(object["generation"]!.uint64Value)
                try await harness.send(bundle: bundle, host: host)
            },
            fetchStatus: fetchStatus,
            fetchCapabilities: fetchCapabilities,
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
    private let residencyRoles: [String: BrokerResidency]
    private(set) var buildCount = 0
    private(set) var capabilityCount = 0

    var operationCounts: [Int] { [capabilityCount, buildCount, sendCount] }

    func recordCapability() { capabilityCount += 1 }
    private var nextGeneration: UInt64 = 0
    private(set) var generations: [UInt64] = []
    private(set) var builtGenerations: [UInt64] = []
    private(set) var sentGenerations: [UInt64] = []
    private(set) var reservationFloors: [UInt64] = []
    private(set) var statusSendCounts: [Int] = []
    private(set) var statusUpdates: [RemoteHostCredentialObservation] = []
    private var sendResults: [RemoteSSHTransportError?]
    private(set) var sendCount = 0
    private(set) var finishedUpdates: [FinishedUpdate] = []
    private var remainingFailures: Int
    private let blockFirstSend: Bool
    private var firstSendContinuation: CheckedContinuation<Void, Never>?
    private var releaseFirstSendRequested = false

    init(
        hosts: [RemoteHost] = [RemoteHost(
            host: "gpu-a.example",
            sshUser: "pinemeter",
            keyPath: "/tmp/id_ed25519",
            secretReference: "reference",
            pinnedHostKeyFingerprint: "SHA256:fixture"
        )],
        blockFirstSend: Bool = false,
        sendFailuresBeforeSuccess: Int = 0,
        residencyRoles: [String: BrokerResidency] = [:],
        initialGeneration: UInt64 = 0,
        sendResults: [RemoteSSHTransportError?] = []
    ) {
        self.hosts = hosts
        self.residencyRoles = residencyRoles
        self.blockFirstSend = blockFirstSend
        remainingFailures = sendFailuresBeforeSuccess
        nextGeneration = initialGeneration
        self.sendResults = sendResults
    }

    var hostID: UUID { hosts[0].id }

    func source() -> RemotePushSourceSnapshot {
        RemotePushSourceSnapshot(
            hosts: hosts,
            inventory: RemotePushAccountInventory(
                claude: [.init(id: "fixture", label: "Fixture", isPrimary: false, keychainAccount: "fixture")],
                chatGPT: [], gemini: []
            ),
            policy: BrokerPolicy(roles: BrokerPolicy.default.roles, residencyRoles: residencyRoles),
            cooldowns: [:],
            oracleSnapshot: nil
        )
    }

    func removeAllHosts() {
        hosts = []
    }

    func reserveGeneration() throws -> UInt64 {
        guard nextGeneration < UInt64.max else { throw SettingsRepositoryError.pushGenerationExhausted }
        nextGeneration += 1
        generations.append(nextGeneration)
        return nextGeneration
    }

    func reserveGeneration(after floor: UInt64) throws -> UInt64 {
        let current = max(nextGeneration, floor)
        guard current < UInt64.max else { throw SettingsRepositoryError.pushGenerationExhausted }
        recordReservation(current + 1, floor: floor)
        return current + 1
    }

    func recordBuild(generation: UInt64, source: RemotePushSourceSnapshot) {
        buildCount += 1
        builtGenerations.append(generation)
        precondition(source.hosts.isEmpty == false)
        precondition(generations.contains(generation))
    }

    func send(bundle: Data, host: RemoteHost) async throws {
        precondition(hosts.contains(where: { $0.id == host.id }))
        precondition(bundle.isEmpty == false)
        sendCount += 1
        let object = try JSONSerialization.jsonObject(with: bundle) as! [String: NSNumber]
        sentGenerations.append(object["generation"]!.uint64Value)
        if !sendResults.isEmpty, let error = sendResults.removeFirst() {
            throw error
        }
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
        if case .status(_, let observation) = update { statusUpdates.append(observation) }
        guard case .finished(_, _, let result, let error) = update else { return }
        finishedUpdates.append(FinishedUpdate(result: result, sanitizedError: error))
    }

    func recordReservation(_ generation: UInt64, floor: UInt64) {
        nextGeneration = generation
        generations.append(generation)
        reservationFloors.append(floor)
    }

    func status(acceptedGeneration: UInt64) -> HostStatusDTO {
        statusSendCounts.append(sendCount)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return HostStatusDTO(
            schemaVersion: 1, acceptedGeneration: acceptedGeneration,
            observedGeneration: acceptedGeneration, observedAt: now,
            accounts: [.init(provider: .claude, id: "fixture", verdict: .ok, observedAt: now)]
        )
    }
}

private enum PushHarnessError: Error {
    case lostAcknowledgement
    case unavailable
}

private actor ReplayRecoveryGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func markEntered() { entered = true }

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
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
