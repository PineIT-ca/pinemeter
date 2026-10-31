//
//  InstructionCheckStore.swift
//  Pinemeter
//
//  The last instruction check this machine ran, so the Instructions pane can
//  show a verdict without an agent in the room.
//
//  The record is not the agent's claim about its own work: it is what
//  Pinemeter itself graded on the `audit` calls that agent made. The app can
//  therefore show a real verdict over a complete stack, which is the one thing
//  its old fixed-path scan could never do.
//
//  Only paths, verdicts and finding text are kept. Submitted file content is
//  graded and dropped, which is the promise the tool result makes.
//

import Foundation

struct InstructionCheckSource: Codable, Equatable, Sendable {
    let path: String
    let status: InstructionAuditStatus
    let findings: [String]
}

/// One check, possibly assembled from several `audit` calls.
///
/// An agent with more sources than fit in a single call sends them in batches
/// under one `runID`; batches sharing a run merge by path, so the record
/// describes the whole stack rather than whichever batch happened to land
/// last. A call without a `runID` is its own run.
///
/// Merging is also bounded in time. The batches of one check land seconds
/// apart, so anything older is a caller reusing a stable id (a session id, a
/// harness name) across separate checks. Folding those together would carry a
/// path that no longer exists into a record stamped with today's date, which
/// is the stale-subset problem this whole design exists to remove, inverted.
struct InstructionCheck: Codable, Equatable, Sendable {
    let runID: String?
    let caller: String?
    let checkedAt: Date
    /// The Pinemeter version whose grader produced this record. `nil` on a
    /// record written before the version was kept, which is indistinguishable
    /// from a record graded by an unknown build and treated the same way.
    let gradedBy: String?
    /// Agent-setup contract revision graded by this check. Old records have
    /// no value and compare as revision zero.
    let setupRevision: Int?
    let sources: [InstructionCheckSource]

    private enum CodingKeys: String, CodingKey {
        case runID
        case caller
        case checkedAt
        case gradedBy
        case setupRevision = "setup_revision"
        case sources
    }

    /// Spelled out rather than memberwise so `gradedBy` can default: every
    /// other field is part of what the agent sent, and a call site that has
    /// no version to state should not have to say so.
    init(
        runID: String?,
        caller: String?,
        checkedAt: Date,
        gradedBy: String? = nil,
        setupRevision: Int? = nil,
        sources: [InstructionCheckSource]
    ) {
        self.runID = runID
        self.caller = caller
        self.checkedAt = checkedAt
        self.gradedBy = gradedBy
        self.setupRevision = setupRevision
        self.sources = sources
    }

    var status: InstructionAuditStatus {
        if sources.contains(where: { $0.status == .conflict }) { return .conflict }
        if sources.contains(where: { $0.status == .warning }) { return .warning }
        if sources.isEmpty || sources.allSatisfy({ $0.status == .unavailable }) { return .unavailable }
        if sources.contains(where: { $0.status == .unavailable }) { return .warning }
        return .pass
    }

    func count(of status: InstructionAuditStatus) -> Int {
        sources.filter { $0.status == status }.count
    }

    /// The rows worth showing: anything that is not a clean pass.
    var issues: [InstructionCheckSource] {
        sources.filter { $0.status != .pass }
    }
}

/// Completion evidence for the most recently dispatched run. Later unrelated
/// audits replace the visible check, but cannot replace this run's evidence.
struct InstructionDispatchRun: Codable, Equatable, Sendable {
    let runID: String
    let provenance: InstructionDispatchProvenance
    let dispatchedAt: Date
    var completedAt: Date?

    func matches(_ check: InstructionCheck) -> Bool {
        check.runID == runID && check.checkedAt >= dispatchedAt
            && check.gradedBy == provenance.version
            && (check.setupRevision ?? 0) == provenance.setupRevision
    }
}

extension InstructionDispatchRun {
    private enum CodingKeys: String, CodingKey {
        case runID, provenance, dispatchedAt, completedAt
    }

    // Preserve Date's native precision, matching SettingsRepository dispatch stamps.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(String.self, forKey: .runID)
        provenance = try container.decode(InstructionDispatchProvenance.self, forKey: .provenance)
        dispatchedAt = Date(timeIntervalSinceReferenceDate: try container.decode(Double.self, forKey: .dispatchedAt))
        completedAt = try container.decodeIfPresent(Double.self, forKey: .completedAt).map(Date.init(timeIntervalSinceReferenceDate:))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(dispatchedAt.timeIntervalSinceReferenceDate, forKey: .dispatchedAt)
        try container.encodeIfPresent(completedAt?.timeIntervalSinceReferenceDate, forKey: .completedAt)
    }
}

actor InstructionCheckStore {
    typealias Writer = @Sendable (Data, URL) throws -> Void

    static let fileName = "instruction-check.json"
    static let maxFileSizeBytes = 1_024 * 1_024
    /// A merged run's ceiling. Well past any real instruction stack, and low
    /// enough that a misbehaving caller cannot grow the file without bound.
    static let maxSources = 512
    static let maxFindingsPerSource = 16
    static let maxFindingLength = 240
    static let maxIdentifierLength = 128
    /// How long a `runID` stays mergeable. Batches of one check arrive
    /// seconds apart; a reused id turning up later starts a fresh check.
    static let mergeWindow: TimeInterval = 600

    private struct Envelope: Codable, Sendable {
        let version: Int
        let check: InstructionCheck?
        let dispatchRun: InstructionDispatchRun?
    }

    private let storeURL: URL
    private let writer: Writer
    private var latestCheck: InstructionCheck?
    private var latestDispatchRun: InstructionDispatchRun?

    init(
        fileManager: FileManager = .default,
        storeDirectory: URL? = nil,
        writer: @escaping Writer = { data, url in try data.write(to: url, options: .atomic) }
    ) {
        let directory = BrokerStorePaths.applicationSupportDirectory(
            fileManager: fileManager,
            requestedDirectory: storeDirectory
        )
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent(Self.fileName)
        self.writer = writer
        let stored = Self.load(from: storeURL)
        latestCheck = stored?.check
        latestDispatchRun = stored?.dispatchRun
    }

    var resolvedStoreURL: URL { storeURL }

    func latest() -> InstructionCheck? { latestCheck }

    func dispatchRun() -> InstructionDispatchRun? { latestDispatchRun }

    /// Register before sending the worker message so a fast audit cannot race it.
    func recordDispatch(_ run: InstructionDispatchRun) {
        var run = run
        if let check = latestCheck, run.completedAt == nil, run.matches(check) {
            run.completedAt = check.checkedAt
        }
        persist(check: latestCheck, dispatchRun: run)
    }

    /// Folds one graded `audit` call into the stored check.
    ///
    /// A write failure is not propagated to the tool: grading succeeded, the
    /// caller's result is valid, and losing the "last checked" line is not a
    /// reason to fail their call. The in-memory record is only advanced when
    /// the write lands, so the file and the UI cannot disagree after a restart.
    func record(
        report: InstructionAuditReport,
        runID: String?,
        caller: String?,
        gradedBy: String?,
        setupRevision: Int? = nil,
        at date: Date
    ) {
        let incoming = report.sources.map { source in
            InstructionCheckSource(
                path: source.path,
                status: source.status,
                findings: source.findings.prefix(Self.maxFindingsPerSource).map {
                    String($0.message.prefix(Self.maxFindingLength))
                }
            )
        }

        let runID = Self.normalizedIdentifier(runID)
        let merged: [InstructionCheckSource]
        if let runID,
           let previous = latestCheck,
           previous.runID == runID,
           date.timeIntervalSince(previous.checkedAt) < Self.mergeWindow,
           date >= previous.checkedAt {
            let existing = previous.sources
            var byPath = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { _, latest in latest })
            for source in incoming { byPath[source.path] = source }
            merged = byPath.values.sorted { $0.path < $1.path }
        } else {
            merged = incoming
        }

        // A merged run takes the grading version of the call that closed it:
        // the record describes one stack, and the build that graded its last
        // batch is the build the whole record has to be re-checked against.
        let check = InstructionCheck(
            runID: runID,
            caller: Self.normalizedIdentifier(caller),
            checkedAt: date,
            gradedBy: Self.normalizedIdentifier(gradedBy),
            setupRevision: setupRevision,
            sources: Array(merged.prefix(Self.maxSources))
        )

        var run = latestDispatchRun
        if run?.completedAt == nil, run?.matches(check) == true {
            run?.completedAt = check.checkedAt
        }
        persist(check: check, dispatchRun: run)
    }

    private func persist(check: InstructionCheck?, dispatchRun: InstructionDispatchRun?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Envelope(version: 1, check: check, dispatchRun: dispatchRun)),
              data.count <= Self.maxFileSizeBytes,
              (try? writer(data, storeURL)) != nil else {
            return
        }
        latestCheck = check
        latestDispatchRun = dispatchRun
    }

    private static func load(from url: URL) -> Envelope? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0,
              size <= maxFileSizeBytes,
              let data = try? Data(contentsOf: url),
              data.count <= maxFileSizeBytes else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.version == 1,
              (envelope.check?.sources.count ?? 0) <= maxSources else {
            return nil
        }
        return envelope
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= maxIdentifierLength,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }
}
