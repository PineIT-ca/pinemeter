//
//  BrokerAuditStore.swift
//  Pinemeter
//
//  Bounded, restart-durable broker decision and lifecycle history.
//

import CryptoKit
import Foundation

enum BrokerStorePaths {
    static var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    static func applicationSupportDirectory(
        fileManager: FileManager,
        requestedDirectory: URL?
    ) -> URL {
        let defaultDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Pinemeter", isDirectory: true)
        let directory = requestedDirectory ?? defaultDirectory
        guard isRunningTests,
              directory.standardizedFileURL == defaultDirectory.standardizedFileURL else {
            return directory
        }
        return fileManager.temporaryDirectory
            .appendingPathComponent("PinemeterTests-\(UUID().uuidString)", isDirectory: true)
    }
}

enum BrokerLifecycleText {
    static let persistedFailureReason = "reported_failure"

    static func normalizedIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.count <= 128 else { return nil }
        return trimmed
    }

    static func sanitizedFailureReason(_ value: String) -> String? {
        var cleaned = ""
        for scalar in value.unicodeScalars.prefix(1_024)
        where !CharacterSet.controlCharacters.contains(scalar) {
            cleaned.unicodeScalars.append(scalar)
        }
        let normalized = cleaned.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return persistedFailureReason
    }

    static func persistedIdentifier(_ value: String) -> String? {
        guard let normalized = normalizedIdentifier(value) else { return nil }
        if normalized.hasPrefix("sha256:"),
           normalized.count == 71,
           normalized.dropFirst(7).allSatisfy(\.isHexDigit) {
            return normalized
        }
        return "sha256:" + SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct BrokerAuditRecord: Codable, Equatable, Sendable {
    let decisionID: String
    let timestamp: Date
    let role: String
    let caller: String
    let candidate: String
    let route: BrokerPolicy.Route
    let agentModel: String?
    let invocation: BrokerInvocation
    let effort: BrokerEffort?
    let reason: String
    let source: BrokerDecisionSource
    let degraded: Bool
    let oracle: BrokerOracleBlock
    let candidatesTried: [BrokerCandidateTried]
    /// Ranked fallbacks captured at pick time. Additive — see `init(from:)`.
    let backups: [BrokerBackupOption]
    var started: BrokerLifecycleReport?
    var terminal: BrokerLifecycleReport?

    init(
        decisionID: String,
        timestamp: Date,
        role: String,
        caller: String,
        candidate: String,
        route: BrokerPolicy.Route,
        agentModel: String?,
        invocation: BrokerInvocation,
        effort: BrokerEffort?,
        reason: String,
        source: BrokerDecisionSource,
        degraded: Bool,
        oracle: BrokerOracleBlock,
        candidatesTried: [BrokerCandidateTried],
        backups: [BrokerBackupOption] = [],
        started: BrokerLifecycleReport? = nil,
        terminal: BrokerLifecycleReport? = nil
    ) {
        self.decisionID = decisionID
        self.timestamp = timestamp
        self.role = role
        self.caller = caller
        self.candidate = candidate
        self.route = route
        self.agentModel = agentModel
        self.invocation = invocation
        self.effort = effort
        self.reason = reason
        self.source = source
        self.degraded = degraded
        self.oracle = oracle
        self.candidatesTried = candidatesTried
        self.backups = Array(backups.prefix(BrokerDecision.maxBackups))
        self.started = started
        self.terminal = terminal
    }

    private enum CodingKeys: String, CodingKey {
        case decisionID = "decision_id"
        case timestamp, role, caller, candidate, route
        case agentModel = "agent_model"
        case invocation, effort, reason, source, degraded, oracle
        case candidatesTried = "candidates_tried"
        case backups, started, terminal
    }

    // `backups` is additive: a record persisted by an older build has no such
    // key on disk, and must decode to an empty list rather than fail the
    // whole audit file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decisionID = try container.decode(String.self, forKey: .decisionID)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        role = try container.decode(String.self, forKey: .role)
        caller = try container.decode(String.self, forKey: .caller)
        candidate = try container.decode(String.self, forKey: .candidate)
        route = try container.decode(BrokerPolicy.Route.self, forKey: .route)
        agentModel = try container.decodeIfPresent(String.self, forKey: .agentModel)
        invocation = try container.decode(BrokerInvocation.self, forKey: .invocation)
        effort = try container.decodeIfPresent(BrokerEffort.self, forKey: .effort)
        reason = try container.decode(String.self, forKey: .reason)
        source = try container.decode(BrokerDecisionSource.self, forKey: .source)
        degraded = try container.decode(Bool.self, forKey: .degraded)
        oracle = try container.decode(BrokerOracleBlock.self, forKey: .oracle)
        candidatesTried = try container.decode([BrokerCandidateTried].self, forKey: .candidatesTried)
        backups = Array(
            (try container.decodeIfPresent([BrokerBackupOption].self, forKey: .backups) ?? [])
                .prefix(BrokerDecision.maxBackups)
        )
        started = try container.decodeIfPresent(BrokerLifecycleReport.self, forKey: .started)
        terminal = try container.decodeIfPresent(BrokerLifecycleReport.self, forKey: .terminal)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decisionID, forKey: .decisionID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(role, forKey: .role)
        try container.encode(caller, forKey: .caller)
        try container.encode(candidate, forKey: .candidate)
        try container.encode(route, forKey: .route)
        try container.encodeIfPresent(agentModel, forKey: .agentModel)
        try container.encode(invocation, forKey: .invocation)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encode(reason, forKey: .reason)
        try container.encode(source, forKey: .source)
        try container.encode(degraded, forKey: .degraded)
        try container.encode(oracle, forKey: .oracle)
        try container.encode(candidatesTried, forKey: .candidatesTried)
        try container.encode(backups, forKey: .backups)
        try container.encodeIfPresent(started, forKey: .started)
        try container.encodeIfPresent(terminal, forKey: .terminal)
    }
}

/// One pick that never produced a decision: every candidate was rejected and
/// the role forbade forcing one anyway, so the caller got an error instead.
///
/// Kept in its own `blocks` array rather than folded into `records`, because
/// every reader of a record expects a winning candidate, a route and an
/// invocation, and a block has none of those. Widening the record would mean
/// making all three optional for every existing consumer of the file.
///
/// Carries labels, candidate ids, rejection reasons and the quota block only —
/// the same fields a decision record carries, and never a prompt, a credential
/// or assistant text.
struct BrokerAuditBlock: Codable, Equatable, Sendable {
    let timestamp: Date
    let role: String
    let caller: String
    /// The message the caller was handed, verbatim.
    let message: String
    /// Every candidate the walk rejected, with the reason it was rejected —
    /// the part of the trace that says whether this was quota, a cooldown, an
    /// unreachable lane or a caller filter.
    let candidatesTried: [BrokerCandidateTried]
    /// The oracle snapshot those rejections were computed from.
    let oracle: BrokerOracleBlock

    init(
        timestamp: Date,
        role: String,
        caller: String,
        message: String,
        candidatesTried: [BrokerCandidateTried],
        oracle: BrokerOracleBlock
    ) {
        self.timestamp = timestamp
        self.role = role
        self.caller = caller
        self.message = message
        self.candidatesTried = candidatesTried
        self.oracle = oracle
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, role, caller, message
        case candidatesTried = "candidates_tried"
        case oracle
    }

    // Per-key fallback on the two structured fields, matching
    // `BrokerAuditRecord`: a block whose trace is unreadable is still worth
    // more than a dropped block, and an entry written by a build that shaped
    // either field differently must not fail the whole audit file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        role = try container.decode(String.self, forKey: .role)
        caller = try container.decode(String.self, forKey: .caller)
        message = try container.decode(String.self, forKey: .message)
        candidatesTried = (try? container.decode([BrokerCandidateTried].self, forKey: .candidatesTried)) ?? []
        oracle = (try? container.decode(BrokerOracleBlock.self, forKey: .oracle)) ?? .absent
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(role, forKey: .role)
        try container.encode(caller, forKey: .caller)
        try container.encode(message, forKey: .message)
        try container.encode(candidatesTried, forKey: .candidatesTried)
        try container.encode(oracle, forKey: .oracle)
    }
}

enum BrokerLifecycleStatus: String, Codable, CaseIterable, Sendable {
    case started
    case completed
    case failed
    case exhausted

    var isTerminal: Bool { self != .started }
}

enum BrokerReviewTrigger: String, Codable, CaseIterable, Sendable {
    case size
    case dependency
    case security
    case testAssertion = "test-assertion"
    case uncertain
}

struct BrokerLifecycleReport: Codable, Equatable, Sendable {
    let decisionID: String
    let status: BrokerLifecycleStatus
    let threadID: String?
    let sessionID: String?
    let durationMS: Int?
    let actualInputTokens: Int?
    let actualCachedInputTokens: Int?
    let actualCacheCreationInputTokens: Int?
    let actualOutputTokens: Int?
    let actualReasoningTokens: Int?
    let sourceFiles: Int?
    let sourceLines: Int?
    let generatedLines: Int?
    let docsLines: Int?
    let trigger: BrokerReviewTrigger?
    let failureReason: String?

    init(
        decisionID: String,
        status: BrokerLifecycleStatus,
        threadID: String? = nil,
        sessionID: String? = nil,
        durationMS: Int? = nil,
        actualInputTokens: Int? = nil,
        actualCachedInputTokens: Int? = nil,
        actualCacheCreationInputTokens: Int? = nil,
        actualOutputTokens: Int? = nil,
        actualReasoningTokens: Int? = nil,
        sourceFiles: Int? = nil,
        sourceLines: Int? = nil,
        generatedLines: Int? = nil,
        docsLines: Int? = nil,
        trigger: BrokerReviewTrigger? = nil,
        failureReason: String? = nil
    ) {
        self.decisionID = decisionID
        self.status = status
        self.threadID = threadID
        self.sessionID = sessionID
        self.durationMS = durationMS
        self.actualInputTokens = actualInputTokens
        self.actualCachedInputTokens = actualCachedInputTokens
        self.actualCacheCreationInputTokens = actualCacheCreationInputTokens
        self.actualOutputTokens = actualOutputTokens
        self.actualReasoningTokens = actualReasoningTokens
        self.sourceFiles = sourceFiles
        self.sourceLines = sourceLines
        self.generatedLines = generatedLines
        self.docsLines = docsLines
        self.trigger = trigger
        self.failureReason = failureReason
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case decisionID = "decision_id"
        case status
        case threadID = "thread_id"
        case sessionID = "session_id"
        case durationMS = "duration_ms"
        case actualInputTokens = "actual_input_tokens"
        case actualCachedInputTokens = "actual_cached_input_tokens"
        case actualCacheCreationInputTokens = "actual_cache_creation_input_tokens"
        case actualOutputTokens = "actual_output_tokens"
        case actualReasoningTokens = "actual_reasoning_tokens"
        case sourceFiles = "source_files"
        case sourceLines = "source_lines"
        case generatedLines = "generated_lines"
        case docsLines = "docs_lines"
        case trigger
        case failureReason = "failure_reason"
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let untyped = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard untyped.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown lifecycle field")
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decisionID = try container.decode(String.self, forKey: .decisionID)
        status = try container.decode(BrokerLifecycleStatus.self, forKey: .status)
        threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        durationMS = try container.decodeIfPresent(Int.self, forKey: .durationMS)
        actualInputTokens = try container.decodeIfPresent(Int.self, forKey: .actualInputTokens)
        actualCachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .actualCachedInputTokens)
        actualCacheCreationInputTokens = try container.decodeIfPresent(
            Int.self, forKey: .actualCacheCreationInputTokens
        )
        actualOutputTokens = try container.decodeIfPresent(Int.self, forKey: .actualOutputTokens)
        actualReasoningTokens = try container.decodeIfPresent(Int.self, forKey: .actualReasoningTokens)
        sourceFiles = try container.decodeIfPresent(Int.self, forKey: .sourceFiles)
        sourceLines = try container.decodeIfPresent(Int.self, forKey: .sourceLines)
        generatedLines = try container.decodeIfPresent(Int.self, forKey: .generatedLines)
        docsLines = try container.decodeIfPresent(Int.self, forKey: .docsLines)
        trigger = try container.decodeIfPresent(BrokerReviewTrigger.self, forKey: .trigger)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decisionID, forKey: .decisionID)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(threadID, forKey: .threadID)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(durationMS, forKey: .durationMS)
        try container.encodeIfPresent(actualInputTokens, forKey: .actualInputTokens)
        try container.encodeIfPresent(actualCachedInputTokens, forKey: .actualCachedInputTokens)
        try container.encodeIfPresent(actualCacheCreationInputTokens, forKey: .actualCacheCreationInputTokens)
        try container.encodeIfPresent(actualOutputTokens, forKey: .actualOutputTokens)
        try container.encodeIfPresent(actualReasoningTokens, forKey: .actualReasoningTokens)
        try container.encodeIfPresent(sourceFiles, forKey: .sourceFiles)
        try container.encodeIfPresent(sourceLines, forKey: .sourceLines)
        try container.encodeIfPresent(generatedLines, forKey: .generatedLines)
        try container.encodeIfPresent(docsLines, forKey: .docsLines)
        try container.encodeIfPresent(trigger, forKey: .trigger)
        try container.encodeIfPresent(failureReason, forKey: .failureReason)
    }
}

enum BrokerLifecycleResult: String, Codable, Hashable, Sendable {
    case recorded
    case duplicate
    case unknownDecision = "unknown_decision"
    case alreadyFinalized = "already_finalized"
}

enum BrokerAuditStoreError: Error, Equatable {
    case invalidDecisionID
    case duplicateDecisionID
    case invalidRecord
    case invalidLifecycleReport
}

actor BrokerAuditStore {
    static let capacity = 500
    /// Blocks are far rarer than decisions and only ever read while diagnosing
    /// one, so they get their own, much smaller cap rather than competing with
    /// decision history for `capacity`.
    static let blockCapacity = 100
    static let maxFileBytes = 8 * 1024 * 1024

    typealias Writer = @Sendable (_ data: Data, _ url: URL) throws -> Void

    /// One decoded block, or nothing. Decoding an array of these is what keeps
    /// a single malformed entry from failing the envelope: `Array` propagates
    /// any element's error, so without a per-element `try?` a block missing one
    /// required key would reject the file and send the decision history the
    /// store exists for to `.bak`.
    /// `Decodable` only. `Envelope.blocks` stays `[BrokerAuditBlock]` on the
    /// way out, so this wrapper exists purely to make the read lenient and has
    /// no encoded form to get wrong.
    private struct FailableBlock: Decodable {
        let value: BrokerAuditBlock?

        init(from decoder: Decoder) throws {
            value = try? BrokerAuditBlock(from: decoder)
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let records: [BrokerAuditRecord]
        let orders: [String: UInt64]?
        /// Additive and optional: absent in every file written before blocks
        /// existed, and left absent again while nothing has blocked, so a
        /// build that predates this array reads back exactly what it wrote.
        let blocks: [BrokerAuditBlock]?

        private enum CodingKeys: String, CodingKey {
            case version, records, orders, blocks
        }

        init(
            version: Int,
            records: [BrokerAuditRecord],
            orders: [String: UInt64]?,
            blocks: [BrokerAuditBlock]?
        ) {
            self.version = version
            self.records = records
            self.orders = orders
            self.blocks = blocks
        }

        // `version` and `records` stay strict: they are what the file is for,
        // and a store that cannot read them back is a rejected store, not a
        // degraded one. Only `blocks` is salvaged element by element.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            records = try container.decode([BrokerAuditRecord].self, forKey: .records)
            orders = try container.decodeIfPresent([String: UInt64].self, forKey: .orders)
            // `try?` flattens the `decodeIfPresent` optional, so an absent key
            // and a `blocks` value that is not an array of objects at all both
            // land on nil — which is what the store wants either way.
            let decodedBlocks = try? container.decodeIfPresent(
                [FailableBlock].self, forKey: .blocks
            )
            blocks = decodedBlocks?.compactMap(\.value)
        }
    }

    private struct LoadedState {
        let records: [BrokerAuditRecord]
        let orders: [String: UInt64]
        let blocks: [BrokerAuditBlock]
        let needsRewrite: Bool
    }

    private static let schemaVersion = 4
    private static let maxTextScalars = 2_048

    private let storeURL: URL
    private let writer: Writer
    private var records: [BrokerAuditRecord]
    private var recordOrders: [String: UInt64]
    private var nextOrder: UInt64
    /// Newest-first, capped at `blockCapacity`.
    private var blocks: [BrokerAuditBlock]

    init(
        fileManager: FileManager = .default,
        storeDirectory: URL? = nil,
        writer: @escaping Writer = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        let directory = BrokerStorePaths.applicationSupportDirectory(
            fileManager: fileManager,
            requestedDirectory: storeDirectory
        )
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("broker-audit.json")
        let loaded = Self.readState(from: storeURL)
        self.storeURL = storeURL
        self.writer = writer
        self.records = loaded.records
        self.recordOrders = loaded.orders
        self.nextOrder = loaded.orders.values.max().map { $0 + 1 } ?? 0
        self.blocks = loaded.blocks
        if loaded.needsRewrite,
           let data = try? Self.encoder().encode(
               Self.envelope(records: loaded.records, orders: loaded.orders, blocks: loaded.blocks)
           ),
           data.count <= Self.maxFileBytes {
            try? writer(data, storeURL)
        }
    }

    var recordsSnapshot: [BrokerAuditRecord] { records }
    var blocksSnapshot: [BrokerAuditBlock] { blocks }
    var resolvedStoreURL: URL { storeURL }

    func append(decision: BrokerDecision, timestamp: Date) throws {
        guard let decisionID = decision.decisionID,
              Self.isValidIdentifier(decisionID),
              timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw BrokerAuditStoreError.invalidDecisionID
        }
        guard !records.contains(where: { $0.decisionID == decisionID }) else {
            throw BrokerAuditStoreError.duplicateDecisionID
        }
        let (followingOrder, overflow) = nextOrder.addingReportingOverflow(1)
        guard !overflow else { throw BrokerAuditStoreError.invalidRecord }

        let record = BrokerAuditRecord(
            decisionID: decisionID,
            timestamp: timestamp,
            role: decision.role,
            caller: decision.caller,
            candidate: decision.model,
            route: decision.route,
            agentModel: decision.agentModel,
            invocation: decision.invocation,
            effort: decision.effort,
            reason: decision.reason,
            source: decision.source,
            degraded: decision.degraded,
            oracle: decision.oracle,
            candidatesTried: decision.candidatesTried,
            backups: decision.backups,
            started: nil,
            terminal: nil
        )
        guard Self.isValid(record) else { throw BrokerAuditStoreError.invalidRecord }

        var prospective = records
        prospective.append(record)
        var prospectiveOrders = recordOrders
        prospectiveOrders[decisionID] = nextOrder
        prospective.sort {
            prospectiveOrders[$0.decisionID, default: 0] > prospectiveOrders[$1.decisionID, default: 0]
        }
        prospective = Array(prospective.prefix(Self.capacity))
        prospectiveOrders = prospective.reduce(into: [:]) { orders, record in
            orders[record.decisionID] = prospectiveOrders[record.decisionID]
        }
        guard prospective.contains(where: { $0.decisionID == decisionID }) else {
            throw BrokerAuditStoreError.invalidRecord
        }
        prospective.sort(by: Self.recordOrder)
        let data = try Self.encoder().encode(
            Self.envelope(records: prospective, orders: prospectiveOrders, blocks: blocks)
        )
        guard data.count <= Self.maxFileBytes else { throw BrokerAuditStoreError.invalidRecord }
        try writer(data, storeURL)
        records = prospective
        recordOrders = prospectiveOrders
        nextOrder = followingOrder
    }

    /// Persists a pick that threw, so the caller's dead end leaves a trace.
    ///
    /// Same transactional shape as `append(decision:timestamp:)`: the whole
    /// envelope is encoded and written before any in-memory state moves, so a
    /// failed write leaves the store exactly as it was.
    func append(block: BrokerAuditBlock) throws {
        guard block.timestamp.timeIntervalSinceReferenceDate.isFinite,
              Self.isValid(block) else {
            throw BrokerAuditStoreError.invalidRecord
        }
        var prospective = blocks
        prospective.insert(block, at: 0)
        prospective = Array(prospective.prefix(Self.blockCapacity))
        let data = try Self.encoder().encode(
            Self.envelope(records: records, orders: recordOrders, blocks: prospective)
        )
        guard data.count <= Self.maxFileBytes else { throw BrokerAuditStoreError.invalidRecord }
        try writer(data, storeURL)
        blocks = prospective
    }

    func reportLifecycle(_ unvalidatedReport: BrokerLifecycleReport) throws -> BrokerLifecycleResult {
        let report = try Self.validate(unvalidatedReport)
        guard let index = records.firstIndex(where: { $0.decisionID == report.decisionID }) else {
            return .unknownDecision
        }

        let current = records[index]
        if report.status == .started, current.started != nil {
            return .duplicate
        }
        if let terminal = current.terminal {
            return terminal.status == report.status ? .duplicate : .alreadyFinalized
        }

        var updated = current
        if report.status == .started {
            updated.started = report
        } else {
            updated.terminal = report
        }
        var prospective = records
        prospective[index] = updated
        let data = try Self.encoder().encode(
            Self.envelope(records: prospective, orders: recordOrders, blocks: blocks)
        )
        guard data.count <= Self.maxFileBytes else { throw BrokerAuditStoreError.invalidRecord }
        try writer(data, storeURL)
        records = prospective
        return .recorded
    }

    private static func validate(_ report: BrokerLifecycleReport) throws -> BrokerLifecycleReport {
        guard let decisionID = BrokerLifecycleText.normalizedIdentifier(report.decisionID) else {
            throw BrokerAuditStoreError.invalidLifecycleReport
        }
        let threadID = try normalizedOptionalIdentifier(report.threadID)
        let sessionID = try normalizedOptionalIdentifier(report.sessionID)

        let numericValues = [
            report.actualInputTokens,
            report.actualCachedInputTokens,
            report.actualCacheCreationInputTokens,
            report.actualOutputTokens,
            report.actualReasoningTokens,
            report.sourceFiles,
            report.sourceLines,
            report.generatedLines,
            report.docsLines,
        ].compactMap { $0 }
        guard report.durationMS.map({ 0...604_800_000 ~= $0 }) ?? true,
              numericValues.allSatisfy({ 0...2_147_483_647 ~= $0 }) else {
            throw BrokerAuditStoreError.invalidLifecycleReport
        }
        if let reasoning = report.actualReasoningTokens {
            guard let output = report.actualOutputTokens, reasoning <= output else {
                throw BrokerAuditStoreError.invalidLifecycleReport
            }
        }

        let hasOutcomeMetrics = report.durationMS != nil || !numericValues.isEmpty || report.trigger != nil
        switch report.status {
        case .started:
            guard !hasOutcomeMetrics, report.failureReason == nil else {
                throw BrokerAuditStoreError.invalidLifecycleReport
            }
        case .completed:
            guard report.failureReason == nil else {
                throw BrokerAuditStoreError.invalidLifecycleReport
            }
        case .failed, .exhausted:
            break
        }

        let failureReason: String?
        if let rawReason = report.failureReason {
            guard report.status == .failed || report.status == .exhausted,
                  let sanitized = sanitizedFailureReason(rawReason) else {
                throw BrokerAuditStoreError.invalidLifecycleReport
            }
            failureReason = sanitized
        } else {
            failureReason = nil
        }

        return BrokerLifecycleReport(
            decisionID: decisionID,
            status: report.status,
            threadID: threadID,
            sessionID: sessionID,
            durationMS: report.durationMS,
            actualInputTokens: report.actualInputTokens,
            actualCachedInputTokens: report.actualCachedInputTokens,
            actualCacheCreationInputTokens: report.actualCacheCreationInputTokens,
            actualOutputTokens: report.actualOutputTokens,
            actualReasoningTokens: report.actualReasoningTokens,
            sourceFiles: report.sourceFiles,
            sourceLines: report.sourceLines,
            generatedLines: report.generatedLines,
            docsLines: report.docsLines,
            trigger: report.trigger,
            failureReason: failureReason
        )
    }

    private static func normalizedOptionalIdentifier(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard let normalized = BrokerLifecycleText.persistedIdentifier(value) else {
            throw BrokerAuditStoreError.invalidLifecycleReport
        }
        return normalized
    }

    private static func sanitizedFailureReason(_ value: String) -> String? {
        BrokerLifecycleText.sanitizedFailureReason(value)
    }

    private static func isValid(_ record: BrokerAuditRecord) -> Bool {
        let text = [record.role, record.caller, record.candidate, record.reason]
            + record.candidatesTried.flatMap { [$0.candidate, $0.why] }
            + record.backups.flatMap { [$0.candidate, $0.model, $0.why] }
        guard record.candidatesTried.count <= 256,
              record.backups.count <= BrokerDecision.maxBackups,
              text.allSatisfy({
            !$0.isEmpty && $0.unicodeScalars.count <= maxTextScalars
              }) else { return false }
        if let started = record.started {
            guard started.status == .started,
                  started.decisionID == record.decisionID,
                  isCanonicalFailureReason(started.failureReason),
                  (try? validate(started)) == started else { return false }
        }
        if let terminal = record.terminal {
            guard terminal.status.isTerminal,
                  terminal.decisionID == record.decisionID,
                  isCanonicalFailureReason(terminal.failureReason),
                  (try? validate(terminal)) == terminal else { return false }
        }
        return true
    }

    private static func isValid(_ block: BrokerAuditBlock) -> Bool {
        let text = [block.role, block.caller, block.message]
            + block.candidatesTried.flatMap { [$0.candidate, $0.why] }
        return block.candidatesTried.count <= 256
            && text.allSatisfy { !$0.isEmpty && $0.unicodeScalars.count <= maxTextScalars }
    }

    /// The one place the on-disk shape is assembled. `blocks` is omitted while
    /// empty so a store that has never blocked keeps writing the same bytes a
    /// build without this array would.
    private static func envelope(
        records: [BrokerAuditRecord],
        orders: [String: UInt64],
        blocks: [BrokerAuditBlock]
    ) -> Envelope {
        Envelope(
            version: schemaVersion,
            records: records,
            orders: orders,
            blocks: blocks.isEmpty ? nil : blocks
        )
    }

    private static func isCanonicalFailureReason(_ value: String?) -> Bool {
        value == nil || value == BrokerLifecycleText.persistedFailureReason
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        BrokerLifecycleText.normalizedIdentifier(value) == value
    }

    private static func recordOrder(_ lhs: BrokerAuditRecord, _ rhs: BrokerAuditRecord) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
        return lhs.decisionID > rhs.decisionID
    }

    private static func readState(from url: URL) -> LoadedState {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue > 0,
              byteCount.intValue <= maxFileBytes,
              let data = try? Data(contentsOf: url),
              let envelope = try? decoder().decode(Envelope.self, from: data),
              envelope.version == schemaVersion || envelope.version == 3
                || envelope.version == 1 || envelope.version == 2,
              envelope.records.count <= capacity,
              Set(envelope.records.map(\.decisionID)).count == envelope.records.count,
              envelope.records.allSatisfy({ isValidIdentifier($0.decisionID) }) else {
            return rejectedState(from: url)
        }
        let migrated = envelope.version == 1 || envelope.version == 2
        let loadedRecords: [BrokerAuditRecord]
        if migrated {
            loadedRecords = envelope.records.compactMap(migratingLegacyRecord)
        } else {
            guard envelope.records.allSatisfy(isValid) else {
                return rejectedState(from: url)
            }
            loadedRecords = envelope.records
        }
        let records = loadedRecords.sorted(by: recordOrder)
        let decisionIDs = Set(records.map(\.decisionID))
        let orders: [String: UInt64]
        if let persistedOrders = envelope.orders {
            let retainedOrders = persistedOrders.filter { decisionIDs.contains($0.key) }
            guard Set(retainedOrders.keys) == decisionIDs,
                  Set(retainedOrders.values).count == retainedOrders.count,
                  retainedOrders.values.max() != UInt64.max else {
                return rejectedState(from: url)
            }
            orders = retainedOrders
        } else {
            orders = Dictionary(uniqueKeysWithValues: records.reversed().enumerated().map {
                ($0.element.decisionID, UInt64($0.offset))
            })
        }
        // A block is a diagnostic, never a routing input, so an unreadable one
        // is dropped on its own rather than costing the decision history the
        // file exists for.
        let blocks = Array((envelope.blocks ?? []).filter(isValid).prefix(blockCapacity))
        return LoadedState(records: records, orders: orders, blocks: blocks, needsRewrite: migrated)
    }

    private static func rejectedState(from url: URL) -> LoadedState {
        let backupURL = url.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.fileExists(atPath: backupURL.path) {
            try? FileManager.default.copyItem(at: url, to: backupURL)
        }
        return LoadedState(records: [], orders: [:], blocks: [], needsRewrite: false)
    }

    private static func migratingLegacyRecord(_ record: BrokerAuditRecord) -> BrokerAuditRecord? {
        var migrated = record
        migrated.started = record.started.flatMap(migratingLegacyReport)
        migrated.terminal = record.terminal.flatMap(migratingLegacyReport)
        return isValid(migrated) ? migrated : nil
    }

    private static func migratingLegacyReport(_ report: BrokerLifecycleReport) -> BrokerLifecycleReport? {
        try? validate(BrokerLifecycleReport(
            decisionID: report.decisionID,
            status: report.status,
            threadID: report.threadID,
            sessionID: report.sessionID,
            durationMS: report.durationMS,
            actualInputTokens: report.actualInputTokens,
            actualCachedInputTokens: report.actualCachedInputTokens,
            actualCacheCreationInputTokens: report.actualCacheCreationInputTokens,
            actualOutputTokens: report.actualOutputTokens,
            actualReasoningTokens: report.actualReasoningTokens,
            failureReason: report.failureReason.map { _ in BrokerLifecycleText.persistedFailureReason }
        ))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
