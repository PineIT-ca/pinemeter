//
//  InstructionCheckStore.swift
//  Pinemeter
//
//  The last instruction check this machine ran, so the Instructions tab can
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
    let sources: [InstructionCheckSource]

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
        let check: InstructionCheck
    }

    private let storeURL: URL
    private let writer: Writer
    private var latestCheck: InstructionCheck?

    init(
        fileManager: FileManager = .default,
        storeDirectory: URL? = nil,
        writer: @escaping Writer = { data, url in try data.write(to: url, options: .atomic) }
    ) {
        let directory = storeDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Pinemeter", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent(Self.fileName)
        self.writer = writer
        latestCheck = Self.load(from: storeURL)
    }

    func latest() -> InstructionCheck? { latestCheck }

    /// Folds one graded `audit` call into the stored check.
    ///
    /// A write failure is not propagated to the tool: grading succeeded, the
    /// caller's result is valid, and losing the "last checked" line is not a
    /// reason to fail their call. The in-memory record is only advanced when
    /// the write lands, so the file and the UI cannot disagree after a restart.
    func record(report: InstructionAuditReport, runID: String?, caller: String?, at date: Date) {
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

        let check = InstructionCheck(
            runID: runID,
            caller: Self.normalizedIdentifier(caller),
            checkedAt: date,
            sources: Array(merged.prefix(Self.maxSources))
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Envelope(version: 1, check: check)),
              data.count <= Self.maxFileSizeBytes,
              (try? writer(data, storeURL)) != nil else {
            return
        }
        latestCheck = check
    }

    private static func load(from url: URL) -> InstructionCheck? {
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
              envelope.check.sources.count <= maxSources else {
            return nil
        }
        return envelope.check
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
