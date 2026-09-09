import Foundation
import os

enum UsageTelemetryFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case error
    case unavailable
}

/// Failure kind recorded alongside an errored ChatGPT poll, so a run of
/// errors in the telemetry file can be attributed without reproducing it.
/// `unknown` covers a category added by a newer build than the reader.
enum UsageTelemetryChatGPTFailure: String, Codable, Equatable, Sendable {
    case missingSession
    case invalidSession
    case invalidResponse
    case httpError
    case transport
    case secureStorage
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = UsageTelemetryChatGPTFailure(rawValue: raw) ?? .unknown
    }
}

struct UsageTelemetryQuotaLimit: Codable, Equatable, Sendable {
    let utilization: Double?
    let resetAt: Date?
}

struct UsageTelemetryQuotaSnapshot: Codable, Equatable, Sendable {
    struct ClaudeAccount: Codable, Equatable, Sendable {
        let id: String
        let isPrimary: Bool
        let freshness: UsageTelemetryFreshness
        let lastUpdated: Date?
        let session: UsageTelemetryQuotaLimit
        let weekly: UsageTelemetryQuotaLimit
        let sonnet: UsageTelemetryQuotaLimit
        let fable: UsageTelemetryQuotaLimit
    }

    struct ChatGPTRow: Codable, Equatable, Sendable {
        let label: String
        let role: ChatGPTUsageData.MenuBarQuotaRole?
        let utilization: Double
        let resetAt: Date?
    }

    struct ChatGPT: Codable, Equatable, Sendable {
        let freshness: UsageTelemetryFreshness
        let lastUpdated: Date?
        let rows: [ChatGPTRow]
        /// Why the last poll failed, when `freshness` is `.error`. `nil` on a
        /// successful poll and on records written before this field existed.
        let failure: UsageTelemetryChatGPTFailure?
        /// HTTP status behind a `.httpError` failure; `nil` for every other
        /// failure kind.
        let httpStatusCode: Int?

        init(
            freshness: UsageTelemetryFreshness,
            lastUpdated: Date?,
            rows: [ChatGPTRow],
            failure: UsageTelemetryChatGPTFailure? = nil,
            httpStatusCode: Int? = nil
        ) {
            self.freshness = freshness
            self.lastUpdated = lastUpdated
            self.rows = rows
            self.failure = failure
            self.httpStatusCode = httpStatusCode
        }
    }

    let claudeAccounts: [ClaudeAccount]
    let chatGPT: ChatGPT

    static let empty = UsageTelemetryQuotaSnapshot(
        claudeAccounts: [],
        chatGPT: ChatGPT(freshness: .unavailable, lastUpdated: nil, rows: [])
    )
}

struct UsageTelemetryRecord: Codable, Equatable, Sendable {
    let attemptedAt: Date
    let t3Availability: T3UsageAvailability
    let claudeAccounts: [UsageTelemetryQuotaSnapshot.ClaudeAccount]
    let chatGPT: UsageTelemetryQuotaSnapshot.ChatGPT
    let t3Snapshot: T3UsageSnapshot?
    /// Build that wrote the record, so a failure run can be attributed to (or
    /// cleared of) a specific release.
    let appVersion: String?
    /// Launch that wrote the record. Identifies restarts without inferring
    /// them from gaps between `attemptedAt` values.
    let appLaunchedAt: Date?

    init(
        attemptedAt: Date,
        t3Availability: T3UsageAvailability,
        claudeAccounts: [UsageTelemetryQuotaSnapshot.ClaudeAccount],
        chatGPT: UsageTelemetryQuotaSnapshot.ChatGPT,
        t3Snapshot: T3UsageSnapshot?,
        appVersion: String? = nil,
        appLaunchedAt: Date? = nil
    ) {
        self.attemptedAt = attemptedAt
        self.t3Availability = t3Availability
        self.claudeAccounts = claudeAccounts
        self.chatGPT = chatGPT
        self.t3Snapshot = t3Snapshot
        self.appVersion = appVersion
        self.appLaunchedAt = appLaunchedAt
    }
}

actor UsageTelemetryStore {
    typealias Writer = @Sendable (Data, URL) throws -> Void
    typealias FailureLogger = @Sendable (String) -> Void

    static let capacity = 1_024
    static let fileName = "usage-telemetry.json"
    static let maxFileSizeBytes = 16 * 1_024 * 1_024
    static let flushInterval: Duration = .seconds(300)
    private static let logger = Logger(subsystem: "com.pinemeter", category: "UsageTelemetryStore")

    private struct StoredRecord: Codable, Equatable, Sendable {
        let order: UInt64
        let record: UsageTelemetryRecord
    }

    private struct Envelope: Codable, Sendable {
        let version: Int
        let records: [StoredRecord]
    }

    private let storeURL: URL
    private let writer: Writer
    private let scheduledFlushInterval: Duration
    private let logFailure: FailureLogger
    private var storedRecords: [StoredRecord]
    private var nextOrder: UInt64
    private var pendingFlushTask: Task<Void, Never>?
    private var isDirty = false

    init(
        fileManager: FileManager = .default,
        storeDirectory: URL? = nil,
        writer: @escaping Writer = { data, url in try data.write(to: url, options: .atomic) },
        scheduledFlushInterval: Duration = UsageTelemetryStore.flushInterval,
        logFailure: @escaping FailureLogger = { message in
            UsageTelemetryStore.logger.error("\(message, privacy: .public)")
        }
    ) {
        let directory = BrokerStorePaths.applicationSupportDirectory(
            fileManager: fileManager,
            requestedDirectory: storeDirectory
        )
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent(Self.fileName)
        self.writer = writer
        self.scheduledFlushInterval = scheduledFlushInterval
        self.logFailure = logFailure
        storedRecords = Self.load(from: storeURL)
        nextOrder = storedRecords.map(\.order).max().map { $0 + 1 } ?? 0
    }

    var resolvedStoreURL: URL { storeURL }

    func records() -> [UsageTelemetryRecord] {
        storedRecords.map(\.record)
    }

    func append(_ record: UsageTelemetryRecord) throws {
        let (followingOrder, overflow) = nextOrder.addingReportingOverflow(1)
        guard !overflow else { throw CocoaError(.fileWriteUnknown) }
        storedRecords.append(StoredRecord(order: nextOrder, record: record))
        if storedRecords.count > Self.capacity,
           let oldest = storedRecords.indices.min(by: { storedRecords[$0].order < storedRecords[$1].order }) {
            storedRecords.remove(at: oldest)
        }
        storedRecords.sort(by: Self.presentationOrder)
        nextOrder = followingOrder
        isDirty = true
        scheduleFlushIfNeeded()
    }

    func flush() throws {
        try persist()
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
    }

    private func scheduleFlushIfNeeded() {
        guard pendingFlushTask == nil else { return }
        pendingFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: scheduledFlushInterval)
            } catch {
                return
            }
            await self?.flushScheduled()
        }
    }

    private func flushScheduled() {
        pendingFlushTask = nil
        do {
            try persist()
        } catch {
            logFailure("Scheduled telemetry flush failed: \(error.localizedDescription)")
        }
    }

    private func persist() throws {
        guard isDirty else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Envelope(version: 1, records: storedRecords))
        guard data.count <= Self.maxFileSizeBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try writer(data, storeURL)
        isDirty = false
    }

    private static func load(from url: URL) -> [StoredRecord] {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0,
              size <= maxFileSizeBytes,
              let data = try? Data(contentsOf: url),
              data.count <= maxFileSizeBytes else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.version == 1,
              envelope.records.count <= capacity,
              Set(envelope.records.map(\.order)).count == envelope.records.count,
              envelope.records.map(\.order).max() != UInt64.max else {
            return []
        }
        return envelope.records.sorted(by: presentationOrder)
    }

    private static func presentationOrder(_ lhs: StoredRecord, _ rhs: StoredRecord) -> Bool {
        if lhs.record.attemptedAt != rhs.record.attemptedAt {
            return lhs.record.attemptedAt < rhs.record.attemptedAt
        }
        return lhs.order < rhs.order
    }
}
