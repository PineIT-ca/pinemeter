import XCTest
@testable import Pinemeter

@MainActor
final class T3UsageTelemetryTests: XCTestCase {
    func testVersion3SummaryRefreshPersistsThroughAppModel() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_786_700_000)
        let store = UsageTelemetryStore(storeDirectory: directory)
        let service = T3UsageService(store: store, now: { now }) { request in
            Self.version3Summary(
                readAt: now,
                sinceDay: request.sinceDay,
                untilDay: request.untilDay,
                timeZone: request.timeZone,
                bucketDay: request.untilDay
            )
        }
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.isChatGPTUsageShown = true
        try await settingsRepository.save(settings)

        let keychain = KeychainRepositoryFake()
        try await keychain.save(sessionKey: TestConstants.sessionKeyValue, account: "default")
        let sessionRepository = TelemetryChatGPTSessionRepository()
        try await sessionRepository.save(
            ChatGPTSession(sessionCookie: "synthetic-cookie"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let usage = UsageData(
            sessionUsage: UsageLimit(utilization: 42, resetAt: now.addingTimeInterval(3_600)),
            weeklyUsage: UsageLimit(utilization: 18, resetAt: now.addingTimeInterval(86_400)),
            sonnetUsage: UsageLimit(utilization: 7, resetAt: now.addingTimeInterval(86_400)),
            fableUsage: UsageLimit(utilization: 11, resetAt: now.addingTimeInterval(86_400)),
            lastUpdated: now
        )
        let chatGPT = ChatGPTUsageData(
            rows: [
                .init(
                    label: "Codex weekly",
                    usedPercent: 33,
                    resetAt: now.addingTimeInterval(86_400),
                    menuBarRole: .chatGPTWeekly
                )
            ],
            lastUpdated: now
        )
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychain,
            usageService: UsageServiceStub(fetchUsageResult: .success(usage)),
            chatGPTUsageService: TelemetryChatGPTUsageService(result: chatGPT),
            chatGPTSessionRepository: sessionRepository,
            notificationService: NotificationServiceSpy(),
            brokerService: TelemetryBrokerService(),
            brokerServerFactory: { _, _, _ in TelemetryBrokerServer() },
            t3InstanceDiscovery: T3InstanceDiscoveryFake(),
            t3UsageService: service
        )

        await appModel.bootstrap()

        let records = await store.records()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.attemptedAt, now)
        XCTAssertEqual(record.t3Availability, .fresh(readAt: now))
        XCTAssertEqual(record.t3Snapshot?.buckets.first?.totals.outputTokens, 40)
        XCTAssertEqual(record.t3Snapshot?.buckets.first?.totals.reasoningTokens, 9)
        XCTAssertEqual(record.t3Snapshot?.buckets.first?.totalTokens, 100)
        XCTAssertEqual(record.claudeAccounts.first?.session.utilization, 42)
        XCTAssertEqual(record.chatGPT.rows.first?.utilization, 33)
        XCTAssertEqual(record.t3Snapshot?.sources.first?.status, .partial)
        XCTAssertEqual(record.t3Snapshot?.pricing.status, .cached)

        let restarted = UsageTelemetryStore(storeDirectory: directory)
        let restartedRecords = await restarted.records()
        XCTAssertEqual(restartedRecords, records)
    }

    /// A failed ChatGPT poll must record *why* it failed, plus the build and
    /// launch that saw it. Without those fields a run of `.error` records is
    /// unattributable after the fact: an expired session, an upstream 5xx and
    /// a transport fault are indistinguishable.
    func testChatGPTFailureRecordsCategoryBuildAndLaunch() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_786_700_000)
        let store = UsageTelemetryStore(storeDirectory: directory)
        let service = T3UsageService(store: store, now: { now }) { _ in
            throw T3UsageAdapterError.usageUnavailable(.authenticationRequired)
        }
        let settingsRepository = SettingsRepositoryFake()
        var settings = AppSettings.default
        settings.broker.isEnabled = true
        settings.isChatGPTUsageShown = true
        try await settingsRepository.save(settings)

        let keychain = KeychainRepositoryFake()
        try await keychain.save(sessionKey: TestConstants.sessionKeyValue, account: "default")
        let sessionRepository = TelemetryChatGPTSessionRepository()
        try await sessionRepository.save(
            ChatGPTSession(sessionCookie: "synthetic-cookie"),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        let appModel = AppModel(
            settingsRepository: settingsRepository,
            keychainRepository: keychain,
            usageService: UsageServiceStub(fetchUsageResult: .success(Self.claudeUsage(now: now))),
            chatGPTUsageService: TelemetryChatGPTUsageService(failure: .httpError(statusCode: 503)),
            chatGPTSessionRepository: sessionRepository,
            notificationService: NotificationServiceSpy(),
            brokerService: TelemetryBrokerService(),
            brokerServerFactory: { _, _, _ in TelemetryBrokerServer() },
            t3InstanceDiscovery: T3InstanceDiscoveryFake(),
            t3UsageService: service
        )

        await appModel.bootstrap()

        let records = await store.records()
        let record = try XCTUnwrap(records.last)
        XCTAssertEqual(record.chatGPT.freshness, .error)
        XCTAssertEqual(record.chatGPT.failure, .httpError)
        XCTAssertEqual(record.chatGPT.httpStatusCode, 503)
        XCTAssertEqual(record.appLaunchedAt, BuildInfo.launchedAt)
        XCTAssertNotNil(record.appVersion)
    }

    /// Every `ChatGPTUsageError` maps to a distinct telemetry category, so no
    /// failure kind is silently folded into another when it is read back.
    func testChatGPTTelemetryFailureMapsEveryErrorCase() {
        XCTAssertEqual(
            AppModel.chatGPTTelemetryFailure(for: ChatGPTUsageError.missingSessionCookie).0,
            .missingSession
        )
        XCTAssertEqual(
            AppModel.chatGPTTelemetryFailure(for: ChatGPTUsageError.invalidSessionCookie).0,
            .invalidSession
        )
        XCTAssertEqual(
            AppModel.chatGPTTelemetryFailure(for: ChatGPTUsageError.invalidResponse).0,
            .invalidResponse
        )
        XCTAssertEqual(
            AppModel.chatGPTTelemetryFailure(for: ChatGPTUsageError.networkUnavailable).0,
            .transport
        )
        XCTAssertEqual(
            AppModel.chatGPTTelemetryFailure(for: ChatGPTUsageError.secureStorageUnavailable).0,
            .secureStorage
        )
        let httpFailure = AppModel.chatGPTTelemetryFailure(
            for: ChatGPTUsageError.httpError(statusCode: 429)
        )
        XCTAssertEqual(httpFailure.0, .httpError)
        XCTAssertEqual(httpFailure.1, 429)
        XCTAssertEqual(AppModel.chatGPTTelemetryFailure(for: AppError.noSessionKey).0, .unknown)
    }

    /// `UsageTelemetryStore.load` returns `[]` on any decode failure, so a
    /// schema change that breaks old files destroys the whole history without
    /// a symptom. This pins both directions: a record written before the
    /// failure/build fields existed still loads, and a category written by a
    /// newer build decodes as `.unknown` instead of discarding the file.
    func testLegacyAndNewerSchemaRecordsStillLoad() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(UsageTelemetryStore.fileName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(
            Self.record(at: Date(timeIntervalSince1970: 1_786_700_000), contractVersion: 3)
        )
        var legacyRecord = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for field in ["appVersion", "appLaunchedAt"] {
            legacyRecord.removeValue(forKey: field)
        }
        var chatGPT = try XCTUnwrap(legacyRecord["chatGPT"] as? [String: Any])
        for field in ["failure", "httpStatusCode"] {
            chatGPT.removeValue(forKey: field)
        }
        legacyRecord["chatGPT"] = chatGPT

        func write(_ record: [String: Any]) throws {
            let envelope: [String: Any] = ["version": 1, "records": [["order": 0, "record": record]]]
            try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL)
        }

        try write(legacyRecord)
        let legacyRecords = await UsageTelemetryStore(storeDirectory: directory).records()
        let loadedLegacy = try XCTUnwrap(legacyRecords.first)
        XCTAssertEqual(legacyRecords.count, 1)
        XCTAssertNil(loadedLegacy.appVersion)
        XCTAssertNil(loadedLegacy.appLaunchedAt)
        XCTAssertNil(loadedLegacy.chatGPT.failure)
        XCTAssertNil(loadedLegacy.chatGPT.httpStatusCode)

        var newerRecord = legacyRecord
        chatGPT["failure"] = "categoryFromANewerBuild"
        newerRecord["chatGPT"] = chatGPT
        try write(newerRecord)
        let newerRecords = await UsageTelemetryStore(storeDirectory: directory).records()
        XCTAssertEqual(newerRecords.count, 1, "an unknown category must not discard the whole file")
        XCTAssertEqual(newerRecords.first?.chatGPT.failure, .unknown)
    }

    func testProductionAdapterIsAuthenticationRequiredAndPerformsNoExternalWork() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_786_700_000)
        let store = UsageTelemetryStore(storeDirectory: directory)
        let service = T3UsageService(store: store, now: { now })

        let result = await service.refresh(
            instanceAvailability: .reachable,
            request: .init(sinceDay: "2026-08-09", untilDay: "2026-08-15", timeZone: "America/Vancouver")
        )

        XCTAssertEqual(result.availability, .usageUnavailable(reason: .authenticationRequired))
        let lastFreshSnapshot = await service.lastFreshSnapshot
        let storedAvailability = await store.records().map(\.t3Availability)
        XCTAssertNil(lastFreshSnapshot)
        XCTAssertEqual(storedAvailability, [result.availability])
    }

    func testRefreshReportsTelemetryPersistenceFailure() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_786_700_000)
        let store = UsageTelemetryStore(storeDirectory: directory) { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let service = T3UsageService(store: store, now: { now }) { _ in
            Self.version3Summary(readAt: now)
        }

        let result = await service.refresh(
            instanceAvailability: .reachable,
            request: .init(sinceDay: "2026-08-09", untilDay: "2026-08-15", timeZone: "America/Vancouver")
        )
        let lastFreshSnapshot = await service.lastFreshSnapshot
        let records = await store.records()

        XCTAssertEqual(result.availability, .usageUnavailable(reason: .persistenceFailure))
        XCTAssertNil(result.freshSnapshot)
        XCTAssertNil(lastFreshSnapshot)
        XCTAssertTrue(records.isEmpty)
    }

    func testUnavailableStatesAppendAvailabilityAndRetainLastFreshSnapshot() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_786_700_000)
        let queue = T3UsageAdapterQueue([
            .summary(Self.version3Summary(readAt: now)),
            .unavailable(.authenticationRequired),
            .readFailure(.scanFailed),
            .summary(Self.version3Summary(readAt: now, contractVersion: 2)),
            .summary(Self.version3Summary(readAt: now, untilDay: "2026-08-14")),
            .failure,
            .cancelled
        ])
        let store = UsageTelemetryStore(storeDirectory: directory)
        let service = T3UsageService(store: store, now: { now }) { request in
            try await queue.next(request)
        }
        let request = T3UsageRequest(
            sinceDay: "2026-08-09",
            untilDay: "2026-08-15",
            timeZone: "America/Vancouver"
        )

        let fresh = await service.refresh(instanceAvailability: .reachable, request: request)
        let absent = await service.refresh(instanceAvailability: .absent, request: request)
        let unreachable = await service.refresh(instanceAvailability: .unreachable, request: request)
        let authentication = await service.refresh(instanceAvailability: .reachable, request: request)
        let readFailure = await service.refresh(instanceAvailability: .reachable, request: request)
        let incompatible = await service.refresh(instanceAvailability: .reachable, request: request)
        let malformed = await service.refresh(instanceAvailability: .reachable, request: request)
        let thrown = await service.refresh(instanceAvailability: .reachable, request: request)
        let cancelled = await service.refresh(instanceAvailability: .reachable, request: request)

        XCTAssertEqual(fresh.availability, .fresh(readAt: now))
        XCTAssertEqual(absent.availability, .absent)
        XCTAssertEqual(unreachable.availability, .unreachable)
        XCTAssertEqual(authentication.availability, .usageUnavailable(reason: .authenticationRequired))
        XCTAssertEqual(readFailure.availability, .usageUnavailable(reason: .scanFailed))
        XCTAssertEqual(incompatible.availability, .incompatible(contractVersion: 2))
        XCTAssertEqual(malformed.availability, .malformed)
        XCTAssertEqual(thrown.availability, .usageUnavailable(reason: .adapterFailure))
        XCTAssertEqual(cancelled.availability, .usageUnavailable(reason: .cancelled))
        let adapterCallCount = await queue.callCount
        XCTAssertEqual(adapterCallCount, 7, "absent and unreachable instances must bypass the adapter")
        let lastFreshSnapshot = await service.lastFreshSnapshot
        XCTAssertEqual(lastFreshSnapshot, fresh.freshSnapshot)
        let records = await store.records()
        XCTAssertEqual(records.map(\.t3Availability), [
            fresh.availability,
            absent.availability,
            unreachable.availability,
            authentication.availability,
            readFailure.availability,
            incompatible.availability,
            malformed.availability,
            thrown.availability,
            cancelled.availability
        ])
    }

    func testConcurrentRefreshKeepsNewestStartedFreshSnapshot() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let adapter = SuspendedT3UsageAdapter()
        let store = UsageTelemetryStore(storeDirectory: directory)
        let service = T3UsageService(store: store) { request in
            await adapter.next(request)
        }
        let request = T3UsageRequest(
            sinceDay: "2026-08-09",
            untilDay: "2026-08-15",
            timeZone: "America/Vancouver"
        )
        let olderReadAt = Date(timeIntervalSince1970: 1_786_700_000)
        let newerReadAt = olderReadAt.addingTimeInterval(60)

        let olderTask = Task {
            await service.refresh(instanceAvailability: .reachable, request: request)
        }
        await adapter.waitForCallCount(1)
        let newerTask = Task {
            await service.refresh(instanceAvailability: .reachable, request: request)
        }
        await adapter.waitForCallCount(2)

        await adapter.complete(call: 1, with: Self.version3Summary(readAt: newerReadAt))
        let newerResult = await newerTask.value
        await adapter.complete(call: 0, with: Self.version3Summary(readAt: olderReadAt))
        _ = await olderTask.value

        let lastFreshSnapshot = await service.lastFreshSnapshot
        let records = await store.records()
        XCTAssertEqual(lastFreshSnapshot, newerResult.freshSnapshot)
        XCTAssertEqual(records.count, 2, "superseded refresh attempts must still persist telemetry")
    }

    func testTelemetryStoreRetentionRestartAndSecretExclusion() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(UsageTelemetryStore.fileName)

        var store = UsageTelemetryStore(storeDirectory: directory)
        var loadedRecords = await store.records()
        XCTAssertTrue(loadedRecords.isEmpty)

        try Data().write(to: fileURL)
        store = UsageTelemetryStore(storeDirectory: directory)
        loadedRecords = await store.records()
        XCTAssertTrue(loadedRecords.isEmpty)
        try Data("not-json".utf8).write(to: fileURL)
        store = UsageTelemetryStore(storeDirectory: directory)
        loadedRecords = await store.records()
        XCTAssertTrue(loadedRecords.isEmpty)
        try Data("{\"version\":2,\"records\":[]}".utf8).write(to: fileURL)
        store = UsageTelemetryStore(storeDirectory: directory)
        loadedRecords = await store.records()
        XCTAssertTrue(loadedRecords.isEmpty)
        try Data(count: UsageTelemetryStore.maxFileSizeBytes + 1).write(to: fileURL)
        store = UsageTelemetryStore(storeDirectory: directory)
        loadedRecords = await store.records()
        XCTAssertTrue(loadedRecords.isEmpty)
        try FileManager.default.removeItem(at: fileURL)

        let timestamp = Date(timeIntervalSince1970: 1_786_700_000)
        for index in 0 ..< UsageTelemetryStore.capacity {
            try await store.append(
                Self.record(at: timestamp.addingTimeInterval(Double(index)), contractVersion: index)
            )
        }
        try await store.append(
            Self.record(at: timestamp.addingTimeInterval(-1), contractVersion: UsageTelemetryStore.capacity)
        )
        let retained = await store.records()
        XCTAssertEqual(retained.count, UsageTelemetryStore.capacity)
        XCTAssertEqual(retained.first?.t3Availability, .incompatible(contractVersion: UsageTelemetryStore.capacity))
        XCTAssertFalse(retained.contains { $0.t3Availability == .incompatible(contractVersion: 0) })
        let restarted = UsageTelemetryStore(storeDirectory: directory)
        let restartedRecords = await restarted.records()
        XCTAssertEqual(restartedRecords, retained)
        XCTAssertEqual(
            restartedRecords.first?.t3Availability,
            .incompatible(contractVersion: UsageTelemetryStore.capacity)
        )

        let concurrentDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: concurrentDirectory) }
        let concurrentStore = UsageTelemetryStore(storeDirectory: concurrentDirectory)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 32 {
                group.addTask {
                    try await concurrentStore.append(
                        Self.record(at: timestamp.addingTimeInterval(Double(index)), contractVersion: index)
                    )
                }
            }
            try await group.waitForAll()
        }
        let concurrentRecords = await concurrentStore.records()
        XCTAssertEqual(concurrentRecords.count, 32)
        let concurrentRestarted = UsageTelemetryStore(storeDirectory: concurrentDirectory)
        let concurrentRestartedRecords = await concurrentRestarted.records()
        XCTAssertEqual(concurrentRestartedRecords, concurrentRecords)

        let cancelledAppend = Task {
            try await concurrentStore.append(Self.record(at: timestamp.addingTimeInterval(100), contractVersion: 100))
        }
        cancelledAppend.cancel()
        try await cancelledAppend.value
        let cancellationSafeRecords = await concurrentStore.records()
        let cancellationRestarted = UsageTelemetryStore(storeDirectory: concurrentDirectory)
        let cancellationRestartedRecords = await cancellationRestarted.records()
        XCTAssertEqual(cancellationRestartedRecords, cancellationSafeRecords)

        let secretDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: secretDirectory) }
        let secretStore = UsageTelemetryStore(storeDirectory: secretDirectory)
        let secretService = T3UsageService(store: secretStore, now: { timestamp }) { _ in
            Self.version3Summary(readAt: timestamp)
        }
        _ = await secretService.refresh(
            instanceAvailability: .reachable,
            request: .init(sinceDay: "2026-08-09", untilDay: "2026-08-15", timeZone: "America/Vancouver")
        )
        let persisted = try String(
            decoding: Data(contentsOf: secretDirectory.appendingPathComponent(UsageTelemetryStore.fileName)),
            as: UTF8.self
        )
        for secret in [
            "synthetic-cookie",
            "host-fingerprint-secret",
            "/synthetic/private/transcript-path",
            "volume-secret",
            "raw-source-message-secret"
        ] {
            XCTAssertFalse(persisted.contains(secret), "telemetry persisted forbidden source material: \(secret)")
        }
    }

    func testTelemetryStoreRejectsDuplicateAndMaximumPersistedOrders() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_786_700_000)

        for replacement in ["0", String(UInt64.max)] {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent(UsageTelemetryStore.fileName)
            let store = UsageTelemetryStore(storeDirectory: directory)
            try await store.append(Self.record(at: timestamp, contractVersion: 0))
            if replacement == "0" {
                try await store.append(Self.record(at: timestamp.addingTimeInterval(1), contractVersion: 1))
            }

            let valid = try String(contentsOf: fileURL, encoding: .utf8)
            let corrupted = valid.replacingOccurrences(
                of: replacement == "0" ? #""order":1"# : #""order":0"#,
                with: #""order":\#(replacement)"#
            )
            XCTAssertNotEqual(corrupted, valid)
            try Data(corrupted.utf8).write(to: fileURL)

            let restarted = UsageTelemetryStore(storeDirectory: directory)
            let loaded = await restarted.records()
            XCTAssertTrue(loaded.isEmpty)
            try await restarted.append(Self.record(at: timestamp, contractVersion: 2))
            let recovered = await restarted.records()
            XCTAssertEqual(recovered.count, 1)
        }
    }

    nonisolated private static func version3Summary(
        readAt: Date,
        contractVersion: Int = 3,
        sinceDay: String = "2026-08-09",
        untilDay: String = "2026-08-15",
        timeZone: String = "America/Vancouver",
        bucketDay: String = "2026-08-15"
    ) -> T3UsageSummaryV3 {
        T3UsageSummaryV3(
            contractVersion: contractVersion,
            readAt: ISO8601DateFormatter().string(from: readAt),
            timeZone: timeZone,
            sinceDay: sinceDay,
            untilDay: untilDay,
            buckets: [
                .init(
                    day: bucketDay,
                    provider: .codex,
                    model: "gpt-5.6-sol",
                    totals: .init(
                        uncachedInputTokens: 10,
                        cachedInputTokens: 20,
                        cacheCreationTokens: 30,
                        outputTokens: 40,
                        reasoningTokens: 9
                    ),
                    costUsd: 1.25,
                    cacheSavingsUsd: 0.75,
                    costSource: .modelPriced,
                    records: 4,
                    unpricedRecords: 0,
                    sessions: 2
                )
            ],
            sources: [
                .init(
                    fingerprint: .init(
                        hostId: "host-fingerprint-secret",
                        provider: .codex,
                        resolvedHomePath: "/synthetic/private/transcript-path",
                        volumeId: "volume-secret"
                    ),
                    status: .partial,
                    scannedFiles: 8,
                    skippedFiles: 1,
                    malformedRecords: 2,
                    distinctSessions: 3,
                    message: "raw-source-message-secret"
                )
            ],
            pricing: .init(
                status: .cached,
                source: "litellm",
                fetchedAt: ISO8601DateFormatter().string(from: readAt.addingTimeInterval(-60)),
                knownModels: 500
            ),
            scanDurationMs: 25
        )
    }

    /// Claude usage has to succeed in the ChatGPT-failure test: a failing
    /// Claude credential makes `bootstrap()` run browser-session recovery,
    /// which scans real browsers and prompts, neither of which belongs in a
    /// unit test.
    nonisolated private static func claudeUsage(now: Date) -> UsageData {
        UsageData(
            sessionUsage: UsageLimit(utilization: 42, resetAt: now.addingTimeInterval(3_600)),
            weeklyUsage: UsageLimit(utilization: 18, resetAt: now.addingTimeInterval(86_400)),
            sonnetUsage: UsageLimit(utilization: 7, resetAt: now.addingTimeInterval(86_400)),
            fableUsage: UsageLimit(utilization: 11, resetAt: now.addingTimeInterval(86_400)),
            lastUpdated: now
        )
    }

    nonisolated private static func record(at date: Date, contractVersion: Int) -> UsageTelemetryRecord {
        UsageTelemetryRecord(
            attemptedAt: date,
            t3Availability: .incompatible(contractVersion: contractVersion),
            claudeAccounts: [],
            chatGPT: .init(freshness: .unavailable, lastUpdated: nil, rows: []),
            t3Snapshot: nil
        )
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("T3UsageTelemetryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private enum T3UsageAdapterFixture: Sendable {
    case summary(T3UsageSummaryV3)
    case unavailable(T3UsageUnavailableReason)
    case readFailure(T3UsageUnavailableReason)
    case failure
    case cancelled
}

private struct T3UsageAdapterFixtureError: Error, Sendable {}

private actor T3UsageAdapterQueue {
    private var fixtures: [T3UsageAdapterFixture]
    private(set) var callCount = 0

    init(_ fixtures: [T3UsageAdapterFixture]) {
        self.fixtures = fixtures
    }

    func next(_ request: T3UsageRequest) throws -> T3UsageSummaryV3 {
        callCount += 1
        guard !fixtures.isEmpty else { throw T3UsageAdapterFixtureError() }
        switch fixtures.removeFirst() {
        case .summary(let summary):
            return summary
        case .unavailable(let reason):
            throw T3UsageAdapterError.usageUnavailable(reason)
        case .readFailure(let reason):
            throw T3UsageAdapterError.readFailure(reason)
        case .failure:
            throw T3UsageAdapterFixtureError()
        case .cancelled:
            throw CancellationError()
        }
    }
}

private actor SuspendedT3UsageAdapter {
    private var calls: [CheckedContinuation<T3UsageSummaryV3, Never>?] = []

    func next(_ request: T3UsageRequest) async -> T3UsageSummaryV3 {
        await withCheckedContinuation { continuation in
            calls.append(continuation)
        }
    }

    func waitForCallCount(_ count: Int) async {
        while calls.count < count { await Task.yield() }
    }

    func complete(call index: Int, with summary: T3UsageSummaryV3) {
        let continuation = calls[index]
        calls[index] = nil
        continuation?.resume(returning: summary)
    }
}

private actor TelemetryChatGPTSessionRepository: ChatGPTSessionRepositoryProtocol {
    private var session: ChatGPTSession?

    func save(_ session: ChatGPTSession, account: String) { self.session = session }
    func load(account: String) throws -> ChatGPTSession {
        guard let session else { throw ChatGPTSessionRepositoryError.notFound }
        return session
    }
    func validate(account: String) -> ChatGPTSessionAcquisitionStatus {
        .init(state: session == nil ? .missing : .available, lastErrorCategory: session == nil ? .notFound : nil)
    }
    func clear(account: String) { session = nil }
}

private actor TelemetryChatGPTUsageService: ChatGPTUsageServiceProtocol {
    let result: Result<ChatGPTUsageData, ChatGPTUsageError>

    init(result: ChatGPTUsageData) {
        self.result = .success(result)
    }

    init(failure: ChatGPTUsageError) {
        self.result = .failure(failure)
    }

    func fetchUsage() throws -> ChatGPTUsageData { try result.get() }
    func fetchUsage(sessionCookie: String) throws -> ChatGPTUsageData { try result.get() }
    func validateSessionCookie(_ sessionCookie: String) -> Bool { true }
}

private actor TelemetryBrokerService: BrokerLifecycleProtocol {
    private var liveness = ["claudeAgent": T3Liveness(reachable: true, why: "http 200")]

    func pick(role: String, caller: String?) async throws -> BrokerDecision {
        throw BrokerError.configError("unused")
    }
    func status() -> BrokerStatus {
        BrokerStatus(
            running: false,
            port: nil,
            oracle: .init(present: false, stale: false, ageSeconds: nil, accounts: []),
            cooldowns: [],
            t3: [],
            roles: [],
            recentPicksCount: 0
        )
    }
    func down(target: String, minutes: Int?) async throws {}
    func up(target: String) async throws {}
    func refresh() async throws {}
    func updatePolicy(_ policy: BrokerPolicy) {}
    func updateOracleSnapshot(_ oracle: OracleSnapshot?) {}
    func updateT3Liveness(_ liveness: [String: T3Liveness]) { self.liveness = liveness }
    func refreshT3Liveness() async -> [String: T3Liveness] {
        liveness = ["claudeAgent": T3Liveness(reachable: true, why: "http 200")]
        return liveness
    }
    func t3LivenessSnapshot() async -> [String: T3Liveness] { liveness }
    func updateServerState(_ state: BrokerUIState.ServerState) {}
    func setRefreshHandler(_ handler: @escaping @Sendable () async throws -> Void) {}
    func uiStateUpdates() -> AsyncStream<BrokerUIState> { AsyncStream { $0.finish() } }
}

private actor TelemetryBrokerServer: BrokerLoopbackServerProtocol {
    func start() -> UInt16 { 43_117 }
    func stop() {}
}
