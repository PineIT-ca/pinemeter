import Foundation
import Security
import XCTest
@testable import Pinemeter

@MainActor
final class RemoteHostStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAcceptedPushDoesNotBecomeFreshUntilCurrentStatusArrives() async throws {
        let harness = StatusCoordinatorHarness(
            inventory: inventory(claude: ["claude-a"]),
            statuses: [status(generation: 1, rows: [row(.claude, "claude-a", .unpolled, nil)])]
        )
        let coordinator = harness.coordinator(now: now)

        await coordinator.manualPush(hostID: harness.host.id)
        try await eventually {
            let counts = await harness.counts
            return counts.finished == 1 && counts.status == 1
        }

        let finishedResults = await harness.finishedResults
        let statusUpdates = await harness.statusUpdates
        XCTAssertEqual(finishedResults, [.succeeded])
        XCTAssertEqual(statusUpdates.last?.status, .unknown)
    }

    func testChallengedPrecedesExpiredAndExpiredPrecedesUnknown() {
        let inventory = inventory(claude: ["a", "b", "c"])
        let observed = now.addingTimeInterval(-30)
        let challenged = aggregate(
            status(generation: 4, rows: [
                row(.claude, "a", .sessionKeyInvalid, observed),
                row(.claude, "b", .challenged, observed),
                row(.claude, "c", .rateLimited, observed),
            ]),
            inventory: inventory,
            generation: 4
        )
        XCTAssertEqual(challenged.status, .challenged)

        let expired = aggregate(
            status(generation: 4, rows: [
                row(.claude, "a", .sessionKeyInvalid, observed),
                row(.claude, "b", .ok, observed),
                row(.claude, "c", .rateLimited, observed),
            ]),
            inventory: inventory,
            generation: 4
        )
        XCTAssertEqual(expired.status, .expired)
    }

    func testMissingRateLimitedAndEmptyInventoryAreUnknown() {
        let observed = now.addingTimeInterval(-20)
        let twoAccounts = inventory(claude: ["a", "b"])
        XCTAssertEqual(aggregate(
            status(generation: 2, rows: [row(.claude, "a", .ok, observed)]),
            inventory: twoAccounts,
            generation: 2
        ).status, .unknown)
        XCTAssertEqual(aggregate(
            status(generation: 2, rows: [
                row(.claude, "a", .ok, observed),
                row(.claude, "b", .rateLimited, observed),
            ]),
            inventory: twoAccounts,
            generation: 2
        ).status, .unknown)
        XCTAssertEqual(aggregate(
            status(generation: 2, rows: []),
            inventory: inventory(),
            generation: 2
        ).status, .unknown)
    }

    func testStaleFutureAndMissingTimestampsAreUnknownAndOldestRelevantTimeIsKept() {
        let old = now.addingTimeInterval(-1_201)
        let fresh = now.addingTimeInterval(-60)
        let future = now.addingTimeInterval(1)
        let configured = inventory(claude: ["a"], chatGPT: ["b"])

        let stale = aggregate(
            status(generation: 3, rows: [
                row(.claude, "a", .ok, old),
                row(.chatgpt, "b", .ok, fresh),
            ]),
            inventory: configured,
            generation: 3
        )
        XCTAssertEqual(stale.status, .unknown)
        XCTAssertEqual(stale.observedAt, old)

        for timestamp in [future, nil] as [Date?] {
            XCTAssertEqual(aggregate(
                status(generation: 3, rows: [
                    row(.claude, "a", .ok, timestamp),
                    row(.chatgpt, "b", .ok, fresh),
                ]),
                inventory: configured,
                generation: 3
            ).status, .unknown)
        }
    }

    func testGenerationMismatchIsHistoricalUnknown() {
        let observed = now.addingTimeInterval(-10)
        let result = aggregate(
            HostStatusDTO(
                schemaVersion: 1,
                acceptedGeneration: 8,
                observedGeneration: 7,
                observedAt: observed,
                accounts: [row(.claude, "a", .ok, observed)]
            ),
            inventory: inventory(claude: ["a"]),
            generation: 8
        )
        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.observedAt, observed)
        XCTAssertEqual(result.observedGeneration, 7)
    }

    func testActivePolicyFreshnessThresholdIsUsedAndUnknownWithoutKnownGeneration() {
        let observed = now.addingTimeInterval(-45)
        let dto = status(generation: 9, rows: [row(.claude, "a", .ok, observed)])
        let configured = inventory(claude: ["a"])

        XCTAssertEqual(RemotePushCoordinator.aggregateStatus(
            dto,
            inventory: configured,
            expectedGeneration: 9,
            now: now,
            freshnessThreshold: 30
        ).status, .unknown)
        XCTAssertEqual(RemotePushCoordinator.aggregateStatus(
            dto,
            inventory: configured,
            expectedGeneration: nil,
            now: now,
            freshnessThreshold: 60
        ).status, .unknown)
    }

    func testOutOfOrderStatusCannotOverwriteNewerGeneration() async throws {
        let harness = StatusCoordinatorHarness(
            inventory: inventory(claude: ["a"]),
            statuses: [
                status(generation: 1, rows: [row(.claude, "a", .sessionKeyInvalid, now)]),
                status(generation: 2, rows: [row(.claude, "a", .ok, now)]),
            ],
            blockFirstStatus: true
        )
        let coordinator = harness.coordinator(now: now)

        await coordinator.manualPush(hostID: harness.host.id)
        try await eventually { await harness.statusFetchCount == 1 }
        await coordinator.manualPush(hostID: harness.host.id)
        try await eventually { await harness.finishedCount == 2 }
        await harness.releaseFirstStatus()
        try await eventually {
            let counts = await harness.counts
            return counts.fetches == 2 && counts.status == 1
        }

        let statusUpdates = await harness.statusUpdates
        XCTAssertEqual(statusUpdates, [
            RemoteHostCredentialObservation(status: .fresh, observedAt: now, observedGeneration: 2),
        ])
    }

    func testWakeRefreshCannotTrustPersistedHostReportedGeneration() async throws {
        let host = makeHost(status: .expired, observedAt: now.addingTimeInterval(-120), generation: 6)
        let repository = SettingsRepositoryFake()
        var initial = AppSettings.default
        initial.broker.remoteHosts = [host]
        try await repository.save(initial)
        let harness = StatusCoordinatorHarness(
            host: host,
            inventory: inventory(claude: ["a"]),
            statuses: [
                status(generation: 6, rows: [row(.claude, "a", .ok, now)]),
                status(generation: 6, rows: [row(.claude, "a", .ok, now)]),
            ]
        )
        let reference = StatusAppModelReference()
        let coordinator = harness.coordinator(now: now) { update in await reference.record(update) }
        let appModel = AppModel(
            settingsRepository: repository,
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(StatusTestError.unavailable)),
            chatGPTSessionRepository: MissingStatusChatGPTRepository(),
            geminiAPIKeyRepository: MissingStatusGeminiRepository(),
            notificationService: NotificationServiceSpy(),
            t3InstanceDiscovery: T3InstanceDiscoveryFake(),
            remotePushCoordinator: coordinator
        )
        reference.value = appModel
        await appModel.bootstrap()

        await appModel.performWakeRefresh()
        try await eventually { await harness.statusUpdates.count >= 2 }

        let sendCount = await harness.sendCount
        let statusUpdates = await harness.statusUpdates
        let persisted = await repository.load()
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(statusUpdates.map(\.status), [.unknown, .unknown])
        XCTAssertEqual(persisted.broker.remoteHosts[0].credentialStatus, .unknown)
    }

    func testMaliciousStatusFieldsAreRejectedWithoutKeychainWrites() async throws {
        let fixture = try StatusResponseFixture(
            response: #"{"schemaVersion":1,"acceptedGeneration":1,"observedGeneration":1,"accounts":[],"credential":"must-not-cross"}"#
        )
        defer { fixture.cleanup() }
        let operations = StatusSecretOperations(identity: Data("fixture-identity".utf8), pin: validPinnedKey())
        let transport = RemoteSSHTransport(
            secretRepository: RemoteHostSecretRepository(operations: operations),
            testing: fixture.configuration
        )

        do {
            _ = try await transport.fetchStatus(host: makeHost())
            XCTFail("malicious response must fail")
        } catch {
            XCTAssertEqual(error as? RemoteSSHTransportError, .invalidResponse)
        }
        XCTAssertEqual(operations.writeCount, 0)
    }

    func testMalformedStatusTimestampIsRejected() async throws {
        let fixture = try StatusResponseFixture(
            response: #"{"schemaVersion":1,"acceptedGeneration":1,"observedGeneration":1,"observedAt":"not-a-date","accounts":[]}"#
        )
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.configuration)

        await assertTransportError(.invalidResponse) {
            _ = try await transport.fetchStatus(
                host: makeHost(),
                secret: RemoteHostSecret(identity: Data("fixture-identity".utf8), pinnedHostKey: validPinnedKey())
            )
        }
    }

    private func assertTransportError(
        _ expected: RemoteSSHTransportError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RemoteSSHTransportError, expected, file: file, line: line)
        }
    }

    private func aggregate(
        _ status: HostStatusDTO,
        inventory: RemotePushAccountInventory,
        generation: UInt64
    ) -> RemoteHostCredentialObservation {
        RemotePushCoordinator.aggregateStatus(
            status,
            inventory: inventory,
            expectedGeneration: generation,
            now: now
        )
    }

    private func status(generation: UInt64, rows: [HostAccountStatusDTO]) -> HostStatusDTO {
        HostStatusDTO(
            schemaVersion: 1,
            acceptedGeneration: generation,
            observedGeneration: rows.allSatisfy { $0.observedAt != nil } ? generation : 0,
            observedAt: rows.compactMap(\.observedAt).min(),
            accounts: rows
        )
    }

    private func row(
        _ provider: HostStatusProvider,
        _ id: String,
        _ verdict: HostStatusVerdict,
        _ observedAt: Date?
    ) -> HostAccountStatusDTO {
        HostAccountStatusDTO(provider: provider, id: id, verdict: verdict, observedAt: observedAt)
    }

    private func inventory(
        claude: [String] = [],
        chatGPT: [String] = [],
        gemini: [String] = []
    ) -> RemotePushAccountInventory {
        func accounts(_ ids: [String]) -> [RemotePushAccountInventory.Account] {
            ids.map { .init(id: $0, label: $0, isPrimary: false, keychainAccount: $0) }
        }
        return RemotePushAccountInventory(
            claude: accounts(claude),
            chatGPT: accounts(chatGPT),
            gemini: accounts(gemini)
        )
    }

    private func makeHost(
        status: RemoteCredentialStatus = .unknown,
        observedAt: Date? = nil,
        generation: UInt64? = nil
    ) -> RemoteHost {
        RemoteHost(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            host: "host.example.com",
            sshUser: "pinemeter",
            keyPath: "/display-only/key",
            secretReference: "fixture",
            pinnedHostKeyFingerprint: "SHA256:fixture",
            credentialStatus: status,
            observedAt: observedAt,
            observedGeneration: generation
        )
    }

    private func eventually(
        _ condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition was not met", file: file, line: line)
    }

    private func validPinnedKey() -> String {
        func sshString(_ data: Data) -> Data {
            var length = UInt32(data.count).bigEndian
            return withUnsafeBytes(of: &length) { Data($0) } + data
        }
        let blob = sshString(Data("ssh-ed25519".utf8)) + sshString(Data(repeating: 4, count: 32))
        return "ssh-ed25519 \(blob.base64EncodedString())"
    }
}

private actor StatusCoordinatorHarness {
    let host: RemoteHost
    let inventory: RemotePushAccountInventory
    private var statuses: [HostStatusDTO]
    private let blockFirstStatus: Bool
    private var statusContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private(set) var sendCount = 0
    private(set) var statusFetchCount = 0
    private(set) var finishedResults: [RemotePushResult] = []
    private(set) var statusUpdates: [RemoteHostCredentialObservation] = []
    var finishedCount: Int { finishedResults.count }
    var counts: (finished: Int, status: Int, fetches: Int) {
        (finishedResults.count, statusUpdates.count, statusFetchCount)
    }

    init(
        host: RemoteHost = RemoteHost(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            host: "host.example.com",
            sshUser: "pinemeter",
            keyPath: "/display-only/key",
            secretReference: "fixture",
            pinnedHostKeyFingerprint: "SHA256:fixture"
        ),
        inventory: RemotePushAccountInventory,
        statuses: [HostStatusDTO],
        blockFirstStatus: Bool = false
    ) {
        self.host = host
        self.inventory = inventory
        self.statuses = statuses
        self.blockFirstStatus = blockFirstStatus
    }

    nonisolated func coordinator(
        now: Date,
        record: (@Sendable (RemotePushAttemptUpdate) async -> Void)? = nil
    ) -> RemotePushCoordinator {
        RemotePushCoordinator(
            loadSource: { await self.source() },
            reserveGeneration: { try await self.reserveGeneration() },
            buildBundle: { generation, _, _ in Data("{\"generation\":\(generation)}".utf8) },
            send: { _, _ in await self.sent() },
            fetchStatus: { _ in try await self.fetch() },
            recordUpdate: { update in
                await self.record(update)
                await record?(update)
            },
            now: { now }
        )
    }

    private func source() -> RemotePushSourceSnapshot {
        RemotePushSourceSnapshot(
            hosts: [host],
            inventory: inventory,
            policy: .default,
            cooldowns: [:],
            oracleSnapshot: nil
        )
    }

    private func reserveGeneration() throws -> UInt64 { UInt64(sendCount + 1) }
    private func sent() { sendCount += 1 }

    private func fetch() async throws -> HostStatusDTO {
        let index = statusFetchCount
        statusFetchCount += 1
        if blockFirstStatus, index == 0 {
            if releaseRequested {
                releaseRequested = false
            } else {
                await withCheckedContinuation { statusContinuation = $0 }
            }
        }
        guard statuses.indices.contains(index) else { throw StatusTestError.unavailable }
        return statuses[index]
    }

    func releaseFirstStatus() {
        if let statusContinuation {
            statusContinuation.resume()
            self.statusContinuation = nil
        } else {
            releaseRequested = true
        }
    }

    private func record(_ update: RemotePushAttemptUpdate) {
        switch update {
        case .started: break
        case .finished(_, _, let result, _): finishedResults.append(result)
        case .status(_, let observation): statusUpdates.append(observation)
        }
    }
}

@MainActor
private final class StatusAppModelReference {
    weak var value: AppModel?
    func record(_ update: RemotePushAttemptUpdate) async { await value?.applyRemotePushUpdate(update) }
}

private actor MissingStatusChatGPTRepository: ChatGPTSessionRepositoryProtocol {
    func save(_ session: ChatGPTSession, account: String) {}
    func load(account: String) throws -> ChatGPTSession { throw ChatGPTSessionRepositoryError.notFound }
    func validate(account: String) -> ChatGPTSessionAcquisitionStatus {
        .init(state: .missing, lastErrorCategory: .notFound)
    }
    func clear(account: String) {}
}

private actor MissingStatusGeminiRepository: GeminiAPIKeyRepositoryProtocol {
    func save(_ apiKey: GeminiAPIKey, account: String) {}
    func load(account: String) throws -> GeminiAPIKey { throw GeminiAPIKeyRepositoryError.notFound }
    func validate(account: String) -> GeminiAPIKeyAcquisitionStatus {
        .init(state: .missing, lastErrorCategory: .notFound)
    }
    func clear(account: String) {}
}

private enum StatusTestError: Error { case unavailable }

private final class StatusSecretOperations: RemoteHostKeychainOperations, @unchecked Sendable {
    private let identity: Data
    private let pin: Data
    private(set) var writeCount = 0

    init(identity: Data, pin: String) {
        self.identity = identity
        self.pin = Data(pin.utf8)
    }

    func update(service: String, account: String, data: Data) -> OSStatus { writeCount += 1; return errSecSuccess }
    func add(service: String, account: String, data: Data) -> OSStatus { writeCount += 1; return errSecSuccess }
    func copy(service: String, account: String) -> (OSStatus, Data?) {
        (errSecSuccess, service.contains("identity") ? identity : pin)
    }
    func delete(service: String, account: String) -> OSStatus { writeCount += 1; return errSecSuccess }
}

private final class StatusResponseFixture {
    let root: URL
    let configuration: RemoteSSHTransportTestConfiguration

    init(response: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteHostStatusTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let executable = root.appendingPathComponent("ssh")
        let script = "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '\(response)'\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        configuration = RemoteSSHTransportTestConfiguration(executableURL: executable, operationRoot: root)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
