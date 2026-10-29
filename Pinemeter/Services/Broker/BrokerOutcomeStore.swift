import Foundation
import Darwin

struct BrokerOutcomeBucket: Codable, Equatable, Sendable {
    var day: String
    var role: String
    var model: String
    var effort: String
    var pickBasis: String
    var backupRuns: Int = 0
    var completed: Int = 0
    var durationMSTotal: Int = 0
    var durationSamples: Int = 0
    var exhausted: Int = 0
    var failed: Int = 0
    var harnessVersionsOther: Int = 0
    var outputSamples: Int = 0
    var outputTokens: Int = 0
    var picks: Int = 0
    var reasoningSamples: Int = 0
    var reasoningTokens: Int = 0
    var servedModelsOther: Int = 0
    var tokenSamples: Int = 0
    var tokensTotal: Int = 0
    var verdictsIssued: [String: Int] = Dictionary(uniqueKeysWithValues: BrokerReviewVerdict.allCases.map { ($0.rawValue, 0) })
    var verdictsReceived: [String: Int] = Dictionary(uniqueKeysWithValues: BrokerReviewVerdict.allCases.map { ($0.rawValue, 0) })
    var servedModels: [String: Int] = [:]
    var harnessVersions: [String: Int] = [:]
    private enum CodingKeys: String, CodingKey {
        case day = "day"
        case role = "role"
        case model = "model"
        case effort = "effort"
        case pickBasis = "pick_basis"
        case backupRuns = "backup_runs"
        case completed = "completed"
        case durationMSTotal = "duration_ms_total"
        case durationSamples = "duration_samples"
        case exhausted = "exhausted"
        case failed = "failed"
        case harnessVersionsOther = "harness_versions_other"
        case outputSamples = "output_samples"
        case outputTokens = "output_tokens"
        case picks = "picks"
        case reasoningSamples = "reasoning_samples"
        case reasoningTokens = "reasoning_tokens"
        case servedModelsOther = "served_models_other"
        case tokenSamples = "token_samples"
        case tokensTotal = "tokens_total"
        case verdictsIssued = "verdicts_issued"
        case verdictsReceived = "verdicts_received"
        case servedModels = "served_models"
        case harnessVersions = "harness_versions"
    }
    var key: [String] { [day, role, model, effort, pickBasis] }
    var counters: [Int] { [backupRuns, completed, durationMSTotal, durationSamples, exhausted, failed, harnessVersionsOther, outputSamples, outputTokens, picks, reasoningSamples, reasoningTokens, servedModelsOther, tokenSamples, tokensTotal] }
}

struct BrokerOutcomeRollup: Codable, Equatable, Sendable {
    var version: Int = 1
    var buckets: [BrokerOutcomeBucket] = []
}

enum BrokerOutcomeStoreError: Error, Equatable { case fullStore, invalidRollup }

actor BrokerOutcomeStore {
    static let fileName = "broker-outcomes.json"
    struct Limits: Sendable {
        var retentionDays = 180
        var maxBuckets = 8192
        var maxFileBytes = 4 * 1024 * 1024
        var maxCounter = 9_007_199_254_740_991
        var maxMapEntries = 4
        static let production = Limits()
    }
    private let storeURL: URL
    private let writer: BrokerAuditStore.Writer
    private let now: @Sendable () -> Date
    private let limits: Limits
    private var rollup = BrokerOutcomeRollup()
    private(set) var loadFailed = false

    init(fileManager: FileManager = .default, storeDirectory: URL? = nil,
         writer: @escaping BrokerAuditStore.Writer = { try $0.write(to: $1, options: .atomic) },
         now: @escaping @Sendable () -> Date = { Date() }, limits: Limits = .production) {
        let directory = BrokerStorePaths.applicationSupportDirectory(fileManager: fileManager, requestedDirectory: storeDirectory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent(Self.fileName)
        self.writer = writer
        self.now = now
        self.limits = limits
        let loaded = Self.readState(from: storeURL, limits: limits, fileManager: fileManager)
        rollup = loaded.rollup
        loadFailed = loaded.failed
    }

    func snapshot() -> BrokerOutcomeRollup { rollup }

    static func bucket(for record: BrokerAuditRecord) -> BrokerOutcomeBucket? {
        guard let basis = record.pickBasis, validLabel(record.role),
              record.timestamp.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let model = record.candidate.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? record.candidate
        return BrokerOutcomeBucket(day: day(record.timestamp), role: record.role, model: model,
                                   effort: record.effort?.rawValue ?? "default", pickBasis: basis.rawValue)
    }

    static func day(_ date: Date) -> String {
        dayFormatter().string(from: date)
    }
    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
    private static func sameKey(_ a: [String], _ b: [String]) -> Bool {
        zip(a, b).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
    static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= 128 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func ordered(_ a: BrokerOutcomeBucket, _ b: BrokerOutcomeBucket) -> Bool {
        for (left, right) in zip(a.key, b.key) where left.utf8.elementsEqual(right.utf8) == false {
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
        return false
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    private func update(_ buckets: inout [BrokerOutcomeBucket], record: BrokerAuditRecord,
                        change: (inout BrokerOutcomeBucket) -> Void) {
        guard let bucket = Self.bucket(for: record) else { return }
        let index: Int
        if let found = buckets.firstIndex(where: { Self.sameKey($0.key, bucket.key) }) { index = found }
        else { buckets.append(bucket); index = buckets.count - 1 }
        change(&buckets[index])
    }
    func notePick(_ record: BrokerAuditRecord) throws {
        guard Self.bucket(for: record) != nil else { return }
        var buckets = rollup.buckets
        update(&buckets, record: record) { $0.picks = adding($0.picks) }
        try persist(buckets, target: record)
    }
    func noteTerminal(_ record: BrokerAuditRecord, reviewed: [BrokerAuditRecord]) throws {
        guard let terminal = record.terminal, terminal.status.isTerminal,
              Self.bucket(for: record) != nil else { return }
        var buckets = rollup.buckets
        update(&buckets, record: record) { bucket in
            if let outcome = record.outcome {
                if (outcome.backupIndex ?? 0) > 0 { bucket.backupRuns = adding(bucket.backupRuns, 1) }
                countLabel(outcome.servedModel, map: &bucket.servedModels, other: &bucket.servedModelsOther)
                countLabel(outcome.harnessVersion, map: &bucket.harnessVersions, other: &bucket.harnessVersionsOther)
            }
            switch terminal.status {
            case .completed:
                bucket.completed = adding(bucket.completed, 1)
                let tokens = [terminal.actualInputTokens, terminal.actualCachedInputTokens, terminal.actualCacheCreationInputTokens, terminal.actualOutputTokens].compactMap { $0 }
                if let total = record.outcome?.totalTokens ?? (tokens.isEmpty ? nil : tokens.reduce(0, +)) {
                    bucket.tokenSamples = adding(bucket.tokenSamples, 1); bucket.tokensTotal = adding(bucket.tokensTotal, total)
                }
                if let output = terminal.actualOutputTokens { bucket.outputSamples = adding(bucket.outputSamples, 1); bucket.outputTokens = adding(bucket.outputTokens, output) }
                if let reasoning = terminal.actualReasoningTokens { bucket.reasoningSamples = adding(bucket.reasoningSamples, 1); bucket.reasoningTokens = adding(bucket.reasoningTokens, reasoning) }
                if let duration = terminal.durationMS { bucket.durationSamples = adding(bucket.durationSamples, 1); bucket.durationMSTotal = adding(bucket.durationMSTotal, duration) }
            case .failed: bucket.failed = adding(bucket.failed, 1)
            case .exhausted: bucket.exhausted = adding(bucket.exhausted, 1)
            case .started: break
            }
        }
        if terminal.status == .completed, let verdict = record.outcome?.reviewVerdict {
            update(&buckets, record: record) { $0.verdictsIssued[verdict.rawValue] = adding($0.verdictsIssued[verdict.rawValue, default: 0]) }
            for worker in reviewed {
                update(&buckets, record: worker) { $0.verdictsReceived[verdict.rawValue] = adding($0.verdictsReceived[verdict.rawValue, default: 0]) }
            }
        }
        try persist(buckets, target: record)
    }
    private func countLabel(_ value: String?, map: inout [String: Int], other: inout Int) {
        guard let value else { return }
        if map[value] != nil || map.count < limits.maxMapEntries { map[value] = adding(map[value, default: 0]) }
        else { other = adding(other) }
    }
    private func adding(_ value: Int, _ increment: Int = 1) -> Int {
        if increment > limits.maxCounter - value { return limits.maxCounter }
        return value + increment
    }
    private func persist(_ buckets: [BrokerOutcomeBucket], target: BrokerAuditRecord) throws {
        let cutoff = Self.day(now().addingTimeInterval(Double(-(limits.retentionDays - 1)) * 86400))
        var prospective = BrokerOutcomeRollup(buckets: buckets.filter { $0.day >= cutoff }.sorted(by: Self.ordered))
        func dropOldestDay() -> Bool {
            guard let first = prospective.buckets.first, let last = prospective.buckets.last, first.day != last.day else { return false }
            prospective.buckets.removeAll { $0.day == first.day }
            return true
        }
        func retained() -> Bool {
            guard let bucket = Self.bucket(for: target) else { return false }
            return prospective.buckets.contains { Self.sameKey($0.key, bucket.key) }
        }
        while prospective.buckets.count > limits.maxBuckets, dropOldestDay() {}
        guard prospective.buckets.count <= limits.maxBuckets, retained() else { throw BrokerOutcomeStoreError.fullStore }
        guard Self.valid(prospective, limits: limits) else { throw BrokerOutcomeStoreError.invalidRollup }
        var data = try Self.encoder().encode(prospective)
        while data.count > limits.maxFileBytes, dropOldestDay() { data = try Self.encoder().encode(prospective) }
        guard data.count <= limits.maxFileBytes, retained() else { throw BrokerOutcomeStoreError.fullStore }
        try writer(data, storeURL)
        rollup = prospective
    }
    private static func valid(_ rollup: BrokerOutcomeRollup, limits: Limits) -> Bool {
        guard rollup.version == 1, rollup.buckets.count <= limits.maxBuckets else { return false }
        let formatter = dayFormatter()
        let verdictKeys = Set(BrokerReviewVerdict.allCases.map(\.rawValue))
        var seen: Set<[Data]> = []
        func counterOK(_ value: Int) -> Bool { value >= 0 && value <= limits.maxCounter }
        func verdictsOK(_ values: [String: Int]) -> Bool {
            Set(values.keys) == verdictKeys && values.values.allSatisfy(counterOK)
        }
        func labelsOK(_ values: [String: Int], normalize: (String) -> String?) -> Bool {
            values.count <= limits.maxMapEntries && values.allSatisfy { normalize($0.key) == $0.key && counterOK($0.value) }
        }
        for bucket in rollup.buckets {
            guard bucket.day.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) != nil,
                  !bucket.day.hasPrefix("0000"),
                  let date = formatter.date(from: bucket.day), formatter.string(from: date) == bucket.day,
                  [bucket.role, bucket.model, bucket.effort, bucket.pickBasis].allSatisfy(validLabel),
                  seen.insert(bucket.key.map { Data($0.utf8) }).inserted,
                  bucket.counters.allSatisfy(counterOK),
                  verdictsOK(bucket.verdictsIssued), verdictsOK(bucket.verdictsReceived),
                  labelsOK(bucket.servedModels, normalize: BrokerOutcomeText.normalizedServedModel),
                  labelsOK(bucket.harnessVersions, normalize: BrokerOutcomeText.normalizedHarnessVersion) else { return false }
        }
        return true
    }
    private static func readState(from url: URL, limits: Limits, fileManager: FileManager) -> (rollup: BrokerOutcomeRollup, failed: Bool) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        if descriptor < 0, errno == ENOENT { return (BrokerOutcomeRollup(), false) }
        func rejected() -> (BrokerOutcomeRollup, Bool) {
            let backup = url.appendingPathExtension("bak")
            if !fileManager.fileExists(atPath: backup.path),
               let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               attributes[.type] as? FileAttributeType == .typeRegular {
                try? fileManager.copyItem(at: url, to: backup)
            }
            return (BrokerOutcomeRollup(), true)
        }
        guard descriptor >= 0 else { return rejected() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink <= 1, status.st_size > 0, status.st_size <= Int64(limits.maxFileBytes),
              let data = try? handle.read(upToCount: limits.maxFileBytes + 1), data.count <= limits.maxFileBytes,
              let loaded = try? JSONDecoder().decode(BrokerOutcomeRollup.self, from: data),
              valid(loaded, limits: limits) else { return rejected() }
        return (loaded, false)
    }
}
