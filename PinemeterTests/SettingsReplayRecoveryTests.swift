import Foundation
import XCTest
@testable import Pinemeter

@MainActor
final class SettingsReplayRecoveryTests: XCTestCase {
    func testOldWriterRollbackThenReplayRecoverySurvivesReopen() async throws {
        let suite = "SettingsReplayRecoveryTests.rollback.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = fixtureHost()
        var settings = AppSettings.default
        settings.broker.remoteHosts = [host]
        settings.broker.pushGeneration = 2
        try await SettingsRepository(userDefaults: defaults).save(settings)
        let sidecarBefore = try XCTUnwrap(defaults.data(forKey: "remote_push_state"))

        // Betas 44-46 rewrote main settings without remote push metadata.
        let oldWriterData = Data(#"{"refresh_interval":300,"broker":{"is_enabled":true,"port":43117}}"#.utf8)
        defaults.set(oldWriterData, forKey: "app_settings")
        let repository = SettingsRepository(userDefaults: defaults)
        let restored = await repository.load()
        XCTAssertEqual(restored.broker.remoteHosts, [host])
        XCTAssertEqual(restored.broker.pushGeneration, 2)
        XCTAssertEqual(restored.refreshInterval, 300)
        XCTAssertEqual(defaults.data(forKey: "app_settings"), oldWriterData)
        XCTAssertEqual(defaults.data(forKey: "remote_push_state"), sidecarBefore)

        let recorder = ReplayRecoveryRecorder()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = makeCoordinator(repository: repository, recorder: recorder, now: now)
        await coordinator.manualPush(hostID: host.id)
        try await eventually { await recorder.statusSendCounts.count == 2 }
        // Drain the normal post-success status task before removing its host.
        try await eventually { await recorder.statusUpdateCount == 1 }
        await coordinator.hostRemoved(host.id)

        let builtBundles = await recorder.builtBundles
        let buildCount = await recorder.buildCount
        let builtGenerations = try builtBundles.map { try JSONDecoder().decode(ReplayBundleGeneration.self, from: $0).generation }
        let sentGenerations = await recorder.sentGenerations
        let builtHosts = await recorder.builtHosts
        let sentHosts = await recorder.sentHosts
        let statusSendCounts = await recorder.statusSendCounts
        let finished = await recorder.finished
        XCTAssertEqual(builtGenerations, [3, 5])
        XCTAssertEqual(buildCount, 2)
        XCTAssertEqual(sentGenerations, [3, 5])
        XCTAssertEqual(builtHosts, [[host], [host]])
        XCTAssertEqual(sentHosts, [host, host])
        XCTAssertEqual(statusSendCounts, [1, 2], "Recovery reads status before resend; normal status follows success")
        XCTAssertEqual(finished, [.finished(hostID: host.id, completedAt: now, result: .succeeded, sanitizedError: nil)])

        let reopened = await SettingsRepository(userDefaults: defaults).load()
        XCTAssertEqual(reopened.broker.remoteHosts, [host])
        XCTAssertEqual(reopened.broker.pushGeneration, 5)
        XCTAssertEqual(reopened.refreshInterval, 300)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let main = try decoder.decode(AppSettings.self, from: XCTUnwrap(defaults.data(forKey: "app_settings")))
        let sidecar = try decoder.decode(ReplayPersistedState.self, from: XCTUnwrap(defaults.data(forKey: "remote_push_state")))
        XCTAssertEqual(main.broker.remoteHosts, [host])
        XCTAssertEqual(main.broker.pushGeneration, 5)
        XCTAssertEqual(sidecar.version, 1)
        XCTAssertEqual(sidecar.remote_hosts, [host])
        XCTAssertEqual(sidecar.push_generation, 5)
        XCTAssertNil(defaults.data(forKey: "app_settings_unreadable_backup"))
    }

    func testUnreadableSettingsPreventPushReservation() async throws {
        let suite = "SettingsReplayRecoveryTests.unreadable.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = fixtureHost()
        var settings = AppSettings.default
        settings.broker.remoteHosts = [host]
        settings.broker.pushGeneration = 2
        try await SettingsRepository(userDefaults: defaults).save(settings)
        let sidecarBefore = try XCTUnwrap(defaults.data(forKey: "remote_push_state"))
        let corrupt = Data(#"{"broker":{"push_generation":"unreadable"}}"#.utf8)
        defaults.set(corrupt, forKey: "app_settings")
        let repository = SettingsRepository(userDefaults: defaults)
        let fallback = await repository.load()
        XCTAssertEqual(fallback.broker.remoteHosts, [host])
        XCTAssertEqual(fallback.broker.pushGeneration, 2)
        let backupBefore = try XCTUnwrap(defaults.data(forKey: "app_settings_unreadable_backup"))
        XCTAssertEqual(backupBefore, corrupt)

        let recorder = ReplayRecoveryRecorder()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = makeCoordinator(repository: repository, recorder: recorder, now: now)
        await coordinator.manualPush(hostID: host.id)
        try await eventually { await recorder.finished.count == 1 }
        await coordinator.hostRemoved(host.id)

        let builtBundles = await recorder.builtBundles
        let buildCount = await recorder.buildCount
        let sentGenerations = await recorder.sentGenerations
        let statusSendCounts = await recorder.statusSendCounts
        let finished = await recorder.finished
        XCTAssertTrue(builtBundles.isEmpty, "Unreadable settings must fail before bundle construction")
        XCTAssertEqual(buildCount, 0)
        XCTAssertTrue(sentGenerations.isEmpty, "Unreadable settings must fail before send")
        XCTAssertTrue(statusSendCounts.isEmpty)
        XCTAssertEqual(finished, [.finished(hostID: host.id, completedAt: now, result: .failed, sanitizedError:
            "Push failed: saved settings could not be read, so Pinemeter did not save a new push generation."
        )])
        XCTAssertEqual(defaults.data(forKey: "app_settings"), corrupt)
        XCTAssertEqual(defaults.data(forKey: "remote_push_state"), sidecarBefore)
        XCTAssertEqual(defaults.data(forKey: "app_settings_unreadable_backup"), backupBefore)
        let reopenedRepository = SettingsRepository(userDefaults: defaults)
        let reopened = await reopenedRepository.load()
        let unreadable = await reopenedRepository.storedSettingsUnreadable()
        XCTAssertTrue(unreadable)
        XCTAssertEqual(reopened.broker.remoteHosts, [host])
        XCTAssertEqual(reopened.broker.pushGeneration, 2)
        XCTAssertEqual(defaults.data(forKey: "app_settings"), corrupt)
        XCTAssertEqual(defaults.data(forKey: "app_settings_unreadable_backup"), backupBefore)
        XCTAssertEqual(defaults.data(forKey: "remote_push_state"), sidecarBefore)
    }

    private func makeCoordinator(
        repository: SettingsRepository,
        recorder: ReplayRecoveryRecorder,
        now: Date
    ) -> RemotePushCoordinator {
        RemotePushCoordinator(
            loadSource: {
                let settings = await repository.load()
                return RemotePushSourceSnapshot(
                    hosts: settings.broker.remoteHosts,
                    inventory: RemotePushAccountInventory(claude: [], chatGPT: [], gemini: []),
                    policy: settings.broker.policy,
                    cooldowns: [:],
                    oracleSnapshot: nil
                )
            },
            reserveGeneration: { try await repository.reservePushGeneration() },
            reserveGenerationAfter: { try await repository.reservePushGeneration(after: $0) },
            buildBundle: { try await recorder.build(generation: $0, pushedAt: $1, source: $2) },
            send: { try await recorder.send(bundle: $0, host: $1) },
            fetchStatus: { _ in await recorder.status(now: now) },
            recordUpdate: { await recorder.record($0) },
            // Stop outer retry scheduling without real delays or background reservations.
            sleep: { _ in throw CancellationError() },
            now: { now }
        )
    }

    private func fixtureHost() -> RemoteHost {
        RemoteHost(
            host: "replay.example.invalid", sshUser: "pinemeter",
            keyPath: "/tmp/fixture-key", secretReference: "fixture-reference",
            pinnedHostKeyFingerprint: "SHA256:fixture",
            lastPushAt: Date(timeIntervalSince1970: 1_799_999_000), lastPushResult: .succeeded
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
        throw ReplayRecoveryTestError.timedOut
    }
}

private struct ReplayBundleGeneration: Decodable {
    let generation: UInt64
}

private struct ReplayPersistedState: Decodable {
    let version: Int
    let remote_hosts: [RemoteHost]
    let push_generation: UInt64
}

private enum ReplayRecoveryTestError: Error {
    case timedOut
}

private actor ReplayRecoveryRecorder {
    private let builder = RemotePushBundleBuilder(
        keychainRepository: KeychainRepositoryFake(),
        chatGPTRepository: ReplayMissingChatGPTRepository(),
        geminiRepository: ReplayMissingGeminiRepository(),
        timeZoneIdentifier: { "UTC" }
    )
    private(set) var builtBundles: [Data] = []
    private(set) var buildCount = 0
    private(set) var builtHosts: [[RemoteHost]] = []
    private(set) var sentGenerations: [UInt64] = []
    private(set) var sentHosts: [RemoteHost] = []
    private(set) var statusSendCounts: [Int] = []
    private(set) var statusUpdateCount = 0
    private(set) var finished: [RemotePushAttemptUpdate] = []

    func build(generation: UInt64, pushedAt: Date, source: RemotePushSourceSnapshot) async throws -> Data {
        buildCount += 1
        let bundle = try await builder.build(
            generation: generation, pushedAt: pushedAt, inventory: source.inventory,
            policy: source.policy, cooldowns: source.cooldowns, oracleSnapshot: source.oracleSnapshot,
            codexWorkspaceAccountIds: source.codexWorkspaceAccountIds
        )
        builtBundles.append(bundle)
        builtHosts.append(source.hosts)
        return bundle
    }

    func send(bundle: Data, host: RemoteHost) throws {
        sentGenerations.append(try JSONDecoder().decode(ReplayBundleGeneration.self, from: bundle).generation)
        sentHosts.append(host)
        if sentGenerations.count == 1 { throw RemoteSSHTransportError.generationReplay }
    }

    func status(now: Date) -> HostStatusDTO {
        statusSendCounts.append(sentGenerations.count)
        let generation: UInt64 = sentGenerations.count == 1 ? 4 : 5
        return HostStatusDTO(
            schemaVersion: 1, acceptedGeneration: generation, observedGeneration: generation,
            observedAt: now, accounts: []
        )
    }

    func record(_ update: RemotePushAttemptUpdate) {
        if case .finished = update { finished.append(update) }
        if case .status = update { statusUpdateCount += 1 }
    }
}

private actor ReplayMissingChatGPTRepository: ChatGPTSessionRepositoryProtocol {
    func save(_ session: ChatGPTSession, account: String) {}
    func load(account: String) throws -> ChatGPTSession { throw ChatGPTSessionRepositoryError.notFound }
    func validate(account: String) -> ChatGPTSessionAcquisitionStatus {
        .init(state: .missing, lastErrorCategory: .notFound)
    }
    func clear(account: String) {}
}

private actor ReplayMissingGeminiRepository: GeminiAPIKeyRepositoryProtocol {
    func save(_ apiKey: GeminiAPIKey, account: String) {}
    func load(account: String) throws -> GeminiAPIKey { throw GeminiAPIKeyRepositoryError.notFound }
    func validate(account: String) -> GeminiAPIKeyAcquisitionStatus {
        .init(state: .missing, lastErrorCategory: .notFound)
    }
    func clear(account: String) {}
}
