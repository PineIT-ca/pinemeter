import Foundation

enum T3UsageInstanceAvailability: String, Codable, Equatable, Sendable {
    case absent
    case unreachable
    case reachable
}

enum T3UsageUnavailableReason: String, Codable, Equatable, Sendable {
    case authenticationRequired = "authentication_required"
    case scanFailed = "scan_failed"
    case invalidWindow = "invalid_window"
    case adapterFailure = "adapter_failure"
    case persistenceFailure = "persistence_failure"
    case cancelled
}

enum T3UsageAvailability: Codable, Equatable, Sendable {
    case absent
    case unreachable
    case usageUnavailable(reason: T3UsageUnavailableReason)
    case incompatible(contractVersion: Int)
    case malformed
    case fresh(readAt: Date)
}

struct T3UsageRequest: Codable, Equatable, Sendable {
    let sinceDay: String
    let untilDay: String
    let timeZone: String

    static func trailingWeek(endingAt date: Date = Date(), timeZone: TimeZone = .current) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.date(byAdding: .day, value: -6, to: date) ?? date
        return Self(
            sinceDay: Self.dayString(start, calendar: calendar),
            untilDay: Self.dayString(date, calendar: calendar),
            timeZone: timeZone.identifier
        )
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

struct T3UsageSummaryV3: Codable, Equatable, Sendable {
    enum Provider: String, Codable, Equatable, Sendable {
        case claude
        case codex
    }

    enum CostSource: String, Codable, Equatable, Sendable {
        case providerReported
        case modelPriced
        case unpriced
    }

    enum SourceStatus: String, Codable, Equatable, Sendable {
        case ok
        case missing
        case partial
        case failed
    }

    enum PricingStatus: String, Codable, Equatable, Sendable {
        case fresh
        case cached
        case unavailable
    }

    struct TokenTotals: Codable, Equatable, Sendable {
        let uncachedInputTokens: Int
        let cachedInputTokens: Int
        let cacheCreationTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
    }

    struct Bucket: Codable, Equatable, Sendable {
        let day: String
        let provider: Provider
        let model: String
        let totals: TokenTotals
        let costUsd: Double
        let cacheSavingsUsd: Double
        let costSource: CostSource
        let records: Int
        let unpricedRecords: Int
        let sessions: Int
    }

    struct Source: Codable, Equatable, Sendable {
        struct Fingerprint: Codable, Equatable, Sendable {
            let hostId: String
            let provider: Provider
            let resolvedHomePath: String
            let volumeId: String
        }

        let fingerprint: Fingerprint
        let status: SourceStatus
        let scannedFiles: Int
        let skippedFiles: Int
        let malformedRecords: Int
        let distinctSessions: Int
        let message: String?
    }

    struct Pricing: Codable, Equatable, Sendable {
        let status: PricingStatus
        let source: String
        let fetchedAt: String?
        let knownModels: Int
    }

    let contractVersion: Int
    let readAt: String
    let timeZone: String
    let sinceDay: String
    let untilDay: String
    let buckets: [Bucket]
    let sources: [Source]
    let pricing: Pricing
    let scanDurationMs: Int

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case readAt
        case timeZone
        case sinceDay
        case untilDay
        case buckets
        case sources
        case pricing
        case scanDurationMs
    }
}

struct T3UsageSnapshot: Codable, Equatable, Sendable {
    struct TokenTotals: Codable, Equatable, Sendable {
        let uncachedInputTokens: Int
        let cachedInputTokens: Int
        let cacheCreationTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
    }

    struct Bucket: Codable, Equatable, Sendable {
        let day: String
        let provider: T3UsageSummaryV3.Provider
        let model: String
        let totals: TokenTotals
        let costUsd: Double
        let cacheSavingsUsd: Double
        let costSource: T3UsageSummaryV3.CostSource
        let records: Int
        let unpricedRecords: Int
        let sessions: Int

        var totalTokens: Int {
            totals.uncachedInputTokens
                + totals.cachedInputTokens
                + totals.cacheCreationTokens
                + totals.outputTokens
        }
    }

    struct SourceSummary: Codable, Equatable, Sendable {
        let provider: T3UsageSummaryV3.Provider
        let status: T3UsageSummaryV3.SourceStatus
        let scannedFiles: Int
        let skippedFiles: Int
        let malformedRecords: Int
        let distinctSessions: Int
    }

    struct PricingSummary: Codable, Equatable, Sendable {
        let status: T3UsageSummaryV3.PricingStatus
        let source: String
        let fetchedAt: Date?
        let knownModels: Int
    }

    let readAt: Date
    let timeZone: String
    let sinceDay: String
    let untilDay: String
    let buckets: [Bucket]
    let sources: [SourceSummary]
    let pricing: PricingSummary
    let scanDurationMs: Int
}

struct T3UsageRefreshResult: Equatable, Sendable {
    let availability: T3UsageAvailability
    let freshSnapshot: T3UsageSnapshot?
}

enum T3UsageAdapterError: Error, Equatable, Sendable {
    case usageUnavailable(T3UsageUnavailableReason)
    case readFailure(T3UsageUnavailableReason)
}

protocol T3UsageServiceProtocol: Sendable {
    func refresh(
        instanceAvailability: T3UsageInstanceAvailability,
        request: T3UsageRequest,
        quota: UsageTelemetryQuotaSnapshot
    ) async -> T3UsageRefreshResult
    func flushTelemetry() async throws
}

extension T3UsageServiceProtocol {
    func flushTelemetry() async throws {}
}

actor T3UsageService: T3UsageServiceProtocol {
    typealias Adapter = @Sendable (T3UsageRequest) async throws -> T3UsageSummaryV3

    private enum ValidationError: Error {
        case invalid
    }

    private static let maxInteger = 2_147_483_647
    private static let maxBuckets = 2_048
    private static let maxSources = 64
    private static let maxModelLength = 256
    private static let maxTextLength = 1_024

    private let store: UsageTelemetryStore
    private let now: @Sendable () -> Date
    private let adapter: Adapter
    private let appVersion: String?
    private let appLaunchedAt: Date?
    private var refreshGeneration: UInt64 = 0
    private(set) var lastFreshSnapshot: T3UsageSnapshot?

    init(
        store: UsageTelemetryStore = UsageTelemetryStore(),
        now: @escaping @Sendable () -> Date = { Date() },
        appVersion: String? = BuildInfo.diagnosticVersion(),
        appLaunchedAt: Date? = BuildInfo.launchedAt,
        adapter: @escaping Adapter = { _ in
            throw T3UsageAdapterError.usageUnavailable(.authenticationRequired)
        }
    ) {
        self.store = store
        self.now = now
        self.appVersion = appVersion
        self.appLaunchedAt = appLaunchedAt
        self.adapter = adapter
    }

    func refresh(
        instanceAvailability: T3UsageInstanceAvailability,
        request: T3UsageRequest
    ) async -> T3UsageRefreshResult {
        await refresh(instanceAvailability: instanceAvailability, request: request, quota: .empty)
    }

    func refresh(
        instanceAvailability: T3UsageInstanceAvailability,
        request: T3UsageRequest,
        quota: UsageTelemetryQuotaSnapshot
    ) async -> T3UsageRefreshResult {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let result = await resolve(instanceAvailability: instanceAvailability, request: request)
        let record = UsageTelemetryRecord(
            attemptedAt: now(),
            t3Availability: result.availability,
            claudeAccounts: quota.claudeAccounts,
            chatGPT: quota.chatGPT,
            t3Snapshot: result.freshSnapshot,
            appVersion: appVersion,
            appLaunchedAt: appLaunchedAt
        )
        do {
            try await store.append(record)
        } catch {
            return T3UsageRefreshResult(
                availability: .usageUnavailable(reason: .persistenceFailure),
                freshSnapshot: nil
            )
        }
        if generation == refreshGeneration, let snapshot = result.freshSnapshot {
            lastFreshSnapshot = snapshot
        }
        return result
    }

    func flushTelemetry() async throws {
        try await store.flush()
    }

    private func resolve(
        instanceAvailability: T3UsageInstanceAvailability,
        request: T3UsageRequest
    ) async -> T3UsageRefreshResult {
        switch instanceAvailability {
        case .absent:
            return T3UsageRefreshResult(availability: .absent, freshSnapshot: nil)
        case .unreachable:
            return T3UsageRefreshResult(availability: .unreachable, freshSnapshot: nil)
        case .reachable:
            break
        }

        do {
            try Self.validate(request)
            let summary = try await adapter(request)
            guard summary.contractVersion == 3 else {
                return T3UsageRefreshResult(
                    availability: .incompatible(contractVersion: summary.contractVersion),
                    freshSnapshot: nil
                )
            }
            let snapshot = try Self.normalize(summary, request: request)
            return T3UsageRefreshResult(
                availability: .fresh(readAt: snapshot.readAt),
                freshSnapshot: snapshot
            )
        } catch let error as T3UsageAdapterError {
            switch error {
            case .usageUnavailable(let reason), .readFailure(let reason):
                return T3UsageRefreshResult(availability: .usageUnavailable(reason: reason), freshSnapshot: nil)
            }
        } catch is CancellationError {
            return T3UsageRefreshResult(availability: .usageUnavailable(reason: .cancelled), freshSnapshot: nil)
        } catch is ValidationError {
            return T3UsageRefreshResult(availability: .malformed, freshSnapshot: nil)
        } catch {
            return T3UsageRefreshResult(availability: .usageUnavailable(reason: .adapterFailure), freshSnapshot: nil)
        }
    }

    private static func normalize(_ summary: T3UsageSummaryV3, request: T3UsageRequest) throws -> T3UsageSnapshot {
        let readAt = try date(summary.readAt)
        let timeZone = try boundedTrimmed(summary.timeZone, maximum: 128)
        let sinceDay = try day(summary.sinceDay)
        let untilDay = try day(summary.untilDay)
        guard timeZone == request.timeZone,
              sinceDay == request.sinceDay,
              untilDay == request.untilDay,
              sinceDay <= untilDay,
              summary.buckets.count <= maxBuckets,
              summary.sources.count <= maxSources else {
            throw ValidationError.invalid
        }
        try bounded(summary.scanDurationMs)

        let buckets = try summary.buckets.map { bucket in
            let bucketDay = try day(bucket.day)
            guard bucketDay >= sinceDay, bucketDay <= untilDay else { throw ValidationError.invalid }
            let model = try boundedTrimmed(bucket.model, maximum: maxModelLength)
            let values = [
                bucket.totals.uncachedInputTokens,
                bucket.totals.cachedInputTokens,
                bucket.totals.cacheCreationTokens,
                bucket.totals.outputTokens,
                bucket.totals.reasoningTokens,
                bucket.records,
                bucket.unpricedRecords,
                bucket.sessions
            ]
            try values.forEach(bounded)
            guard bucket.totals.reasoningTokens <= bucket.totals.outputTokens,
                  bucket.unpricedRecords <= bucket.records,
                  bucket.costUsd.isFinite,
                  bucket.costUsd >= 0,
                  bucket.cacheSavingsUsd.isFinite,
                  bucket.cacheSavingsUsd >= 0 else {
                throw ValidationError.invalid
            }
            return T3UsageSnapshot.Bucket(
                day: bucketDay,
                provider: bucket.provider,
                model: model,
                totals: .init(
                    uncachedInputTokens: bucket.totals.uncachedInputTokens,
                    cachedInputTokens: bucket.totals.cachedInputTokens,
                    cacheCreationTokens: bucket.totals.cacheCreationTokens,
                    outputTokens: bucket.totals.outputTokens,
                    reasoningTokens: bucket.totals.reasoningTokens
                ),
                costUsd: bucket.costUsd,
                cacheSavingsUsd: bucket.cacheSavingsUsd,
                costSource: bucket.costSource,
                records: bucket.records,
                unpricedRecords: bucket.unpricedRecords,
                sessions: bucket.sessions
            )
        }

        let sources = try summary.sources.map { source in
            try boundedTrimmed(source.fingerprint.hostId, maximum: maxTextLength)
            try boundedTrimmed(source.fingerprint.resolvedHomePath, maximum: maxTextLength)
            guard source.fingerprint.volumeId.count <= maxTextLength else { throw ValidationError.invalid }
            try [source.scannedFiles, source.skippedFiles, source.malformedRecords, source.distinctSessions]
                .forEach(bounded)
            return T3UsageSnapshot.SourceSummary(
                provider: source.fingerprint.provider,
                status: source.status,
                scannedFiles: source.scannedFiles,
                skippedFiles: source.skippedFiles,
                malformedRecords: source.malformedRecords,
                distinctSessions: source.distinctSessions
            )
        }
        let pricingSource = try boundedTrimmed(summary.pricing.source, maximum: 256)
        let fetchedAt = try summary.pricing.fetchedAt.map(date)
        try bounded(summary.pricing.knownModels)

        return T3UsageSnapshot(
            readAt: readAt,
            timeZone: timeZone,
            sinceDay: sinceDay,
            untilDay: untilDay,
            buckets: buckets,
            sources: sources,
            pricing: .init(
                status: summary.pricing.status,
                source: pricingSource,
                fetchedAt: fetchedAt,
                knownModels: summary.pricing.knownModels
            ),
            scanDurationMs: summary.scanDurationMs
        )
    }

    private static func validate(_ request: T3UsageRequest) throws {
        let since = try day(request.sinceDay)
        let until = try day(request.untilDay)
        let zone = try boundedTrimmed(request.timeZone, maximum: 128)
        guard since <= until, zone == request.timeZone, TimeZone(identifier: zone) != nil else {
            throw ValidationError.invalid
        }
    }

    private static func bounded(_ value: Int) throws {
        guard value >= 0, value <= maxInteger else { throw ValidationError.invalid }
    }

    @discardableResult
    private static func boundedTrimmed(_ value: String, maximum: Int) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= maximum else {
            throw ValidationError.invalid
        }
        return trimmed
    }

    private static func day(_ value: String) throws -> String {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            throw ValidationError.invalid
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day) else {
            throw ValidationError.invalid
        }
        return value
    }

    private static func date(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        guard let parsed = fractional.date(from: value) ?? whole.date(from: value) else {
            throw ValidationError.invalid
        }
        return parsed
    }
}
