import Foundation
import XCTest
@testable import Pinemeter

final class BrokerOutcomeStoreTests: XCTestCase {
    static func record(id: String = "worker", daysAgo: Int = 0, role: String = "execution",
                       model: String = "native/model-v1", effort: BrokerEffort? = .high,
                       basis: BrokerPickBasis? = .quality, status: BrokerLifecycleStatus? = nil,
                       outcome: BrokerOutcomeDetail? = nil) -> BrokerAuditRecord {
        BrokerAuditRecord(decisionID: id, timestamp: BrokerFixture.now.addingTimeInterval(Double(-daysAgo * 86400)),
                          role: role, caller: "claude-code", candidate: model, route: .native,
                          agentModel: "fable", invocation: .agent(model: "fable"), effort: effort,
                          reason: "available", source: .policy, degraded: false, oracle: .absent,
                          candidatesTried: [], pickBasis: basis,
                          terminal: status.map { BrokerLifecycleReport(decisionID: id, status: $0) }, outcome: outcome)
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OutcomeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func test_pickAndCompletedSamplesPersistAndReload() async throws {
        let dir = try directory()
        let store = BrokerOutcomeStore(storeDirectory: dir, now: { BrokerFixture.now })
        var record = Self.record()
        try await store.notePick(record)
        record.terminal = BrokerLifecycleReport(decisionID: record.decisionID, status: .completed, durationMS: 12,
                                               actualInputTokens: 3, actualCachedInputTokens: 4,
                                               actualCacheCreationInputTokens: 5, actualOutputTokens: 6, actualReasoningTokens: 2)
        try await store.noteTerminal(record, reviewed: [])
        let snapshot = await store.snapshot()
        let b = try XCTUnwrap(snapshot.buckets.first)
        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(b.picks, 1); XCTAssertEqual(b.completed, 1)
        XCTAssertEqual(b.tokensTotal, 18); XCTAssertEqual(b.tokenSamples, 1)
        XCTAssertEqual(b.outputTokens, 6); XCTAssertEqual(b.outputSamples, 1)
        XCTAssertEqual(b.reasoningTokens, 2); XCTAssertEqual(b.reasoningSamples, 1)
        XCTAssertEqual(b.durationMSTotal, 12); XCTAssertEqual(b.durationSamples, 1)
        let reloaded = await BrokerOutcomeStore(storeDirectory: dir, now: { BrokerFixture.now }).snapshot()
        XCTAssertEqual(reloaded, snapshot)
    }
    func test_totalTokensWinsAndMissingSamplesStayAbsent() async throws {
        let store = BrokerOutcomeStore(storeDirectory: try directory(), now: { BrokerFixture.now })
        var r = Self.record(status: .completed, outcome: .init(totalTokens: 0))
        r.terminal = BrokerLifecycleReport(decisionID: r.decisionID, status: .completed, actualInputTokens: 15)
        try await store.noteTerminal(r, reviewed: [])
        try await store.noteTerminal(Self.record(status: .completed), reviewed: [])
        try await store.noteTerminal(Self.record(status: .failed), reviewed: [])
        try await store.noteTerminal(Self.record(status: .exhausted), reviewed: [])
        let snapshot = await store.snapshot()
        let b = try XCTUnwrap(snapshot.buckets.first)
        XCTAssertEqual(b.completed, 2); XCTAssertEqual(b.failed, 1); XCTAssertEqual(b.exhausted, 1)
        XCTAssertEqual(b.tokenSamples, 1); XCTAssertEqual(b.tokensTotal, 0)
        XCTAssertEqual(b.durationSamples, 0)
    }
    func test_keysMergeButEffortAndBasisSeparateAndLegacySkips() async throws {
        let store = BrokerOutcomeStore(storeDirectory: try directory(), now: { BrokerFixture.now })
        for r in [Self.record(), Self.record(), Self.record(effort: nil), Self.record(basis: .quota),
                  Self.record(basis: nil), Self.record(role: ""), Self.record(role: "bad\nrole"),
                  Self.record(role: String(repeating: "é", count: 129))] { try await store.notePick(r) }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.buckets.count, 3)
        XCTAssertEqual(snapshot.buckets.reduce(0) { $0 + $1.picks }, 4)
        XCTAssertEqual(snapshot.buckets.map(\.effort), ["default", "high", "high"])
    }
    func test_verdictCreditBackupRunsAndBoundedMaps() async throws {
        let store = BrokerOutcomeStore(storeDirectory: try directory(), now: { BrokerFixture.now })
        let a = Self.record(daysAgo: 2)
        let b = Self.record(id: "worker-b", daysAgo: 1)
        let legacy = Self.record(id: "legacy", daysAgo: 1, basis: nil)
        for r in [a, b, legacy] { try await store.notePick(r) }
        var review = Self.record(id: "reviewer", role: "review", status: .completed,
                                 outcome: .init(reviewVerdict: .pass, reviewedDecisionIDs: [a.decisionID, b.decisionID, legacy.decisionID]))
        try await store.noteTerminal(review, reviewed: [a, b, legacy])
        var buckets = await store.snapshot().buckets
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets[0].verdictsReceived["pass"], 1)
        XCTAssertEqual(buckets[1].verdictsReceived["pass"], 1)
        XCTAssertEqual(buckets[2].verdictsIssued["pass"], 1)
        review.outcome?.reviewedDecisionIDs = nil
        try await store.noteTerminal(review, reviewed: [])
        buckets = await store.snapshot().buckets
        XCTAssertEqual(buckets[2].verdictsIssued["pass"], 2)
        for (i, status) in [BrokerLifecycleStatus.completed, .failed, .exhausted, .failed, .exhausted, .completed].enumerated() {
            let value = i % 5 + 1
            let r = Self.record(status: status, outcome: .init(backupIndex: i == 1 ? 1 : 0,
                                harnessVersion: "cli/\(value)", servedModel: "model-\(value)"))
            try await store.noteTerminal(r, reviewed: [])
        }
        buckets = await store.snapshot().buckets
        let run = try XCTUnwrap(buckets.first { $0.day == BrokerOutcomeStore.day(BrokerFixture.now) && $0.role == "execution" })
        XCTAssertEqual(run.backupRuns, 1)
        XCTAssertEqual(run.servedModels.count, 4); XCTAssertEqual(run.servedModels["model-1"], 2)
        XCTAssertEqual(run.servedModelsOther, 1)
        XCTAssertEqual(run.harnessVersions.count, 4); XCTAssertEqual(run.harnessVersions["cli/1"], 2)
        XCTAssertEqual(run.harnessVersionsOther, 1)
    }

    func test_retentionAndWholeDayBucketCapsAreTransactional() async throws {
        let clock = OutcomeTestClock(BrokerFixture.now.addingTimeInterval(-180 * 86400))
        let store = BrokerOutcomeStore(storeDirectory: try directory(), now: { clock.now })
        for age in [180, 179] { try await store.notePick(Self.record(daysAgo: age)) }
        clock.now = BrokerFixture.now
        try await store.notePick(Self.record())
        let retained = await store.snapshot().buckets
        XCTAssertEqual(retained.count, 2)
        XCTAssertEqual(retained.first?.day, BrokerOutcomeStore.day(BrokerFixture.now.addingTimeInterval(-179 * 86400)))
        var limits = BrokerOutcomeStore.Limits.production
        limits.maxBuckets = 2
        let dir = try directory()
        let capped = BrokerOutcomeStore(storeDirectory: dir, now: { BrokerFixture.now }, limits: limits)
        for (age, model) in [(2, "a"), (2, "b"), (1, "c"), (0, "d"), (0, "e")] {
            try await capped.notePick(Self.record(daysAgo: age, model: "native/\(model)"))
        }
        let before = await capped.snapshot()
        XCTAssertEqual(before.buckets.map(\.model), ["d", "e"])
        let url = dir.appendingPathComponent(BrokerOutcomeStore.fileName)
        let disk = try Data(contentsOf: url)
        for r in [Self.record(model: "native/f"), Self.record(daysAgo: 3)] {
            do { try await capped.notePick(r); XCTFail("Full store accepted increment") } catch {}
            let after = await capped.snapshot()
            XCTAssertEqual(after, before)
            XCTAssertEqual(try Data(contentsOf: url), disk)
        }
    }
    func test_byteCapAndWriterFailuresKeepPreviousState() async throws {
        let seed = BrokerOutcomeStore(storeDirectory: try directory(), now: { BrokerFixture.now })
        try await seed.notePick(Self.record())
        let snapshot = await seed.snapshot()
        var limits = BrokerOutcomeStore.Limits.production
        limits.maxFileBytes = try BrokerOutcomeStore.encoder().encode(snapshot).count + 20
        let store = BrokerOutcomeStore(storeDirectory: try directory(), now: { BrokerFixture.now }, limits: limits)
        try await store.notePick(Self.record(daysAgo: 1))
        try await store.notePick(Self.record())
        let before = await store.snapshot()
        XCTAssertEqual(before.buckets.count, 1)
        XCTAssertEqual(before.buckets.first?.day, BrokerOutcomeStore.day(BrokerFixture.now))
        do { try await store.notePick(Self.record(model: "native/another")); XCTFail("Oversized day accepted") } catch {}
        let after = await store.snapshot()
        XCTAssertEqual(after, before)
        let failing = BrokerOutcomeStore(storeDirectory: try directory(), writer: { _, _ in throw BrokerOutcomeStoreError.invalidRollup }, now: { BrokerFixture.now })
        for terminal in [false, true] {
            do {
                if terminal { try await failing.noteTerminal(Self.record(status: .completed), reviewed: []) }
                else { try await failing.notePick(Self.record()) }
                XCTFail("Write failure ignored by store")
            } catch {}
            let failed = await failing.snapshot()
            XCTAssertEqual(failed.buckets, [])
        }
    }
    func test_everyCounterSaturatesAtExactIntegerCeiling() async throws {
        let max = BrokerOutcomeStore.Limits.production.maxCounter
        let b = try XCTUnwrap(BrokerOutcomeStore.bucket(for: Self.record()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: BrokerOutcomeStore.encoder().encode(b)) as? [String: Any])
        for (key, value) in object where value is NSNumber { object[key] = max }
        for key in ["verdicts_issued", "verdicts_received"] {
            object[key] = Dictionary(uniqueKeysWithValues: BrokerReviewVerdict.allCases.map { ($0.rawValue, max) })
        }
        object["served_models"] = ["model-1": max, "model-2": max, "model-3": max, "model-4": max]
        object["harness_versions"] = ["cli/1": max, "cli/2": max, "cli/3": max, "cli/4": max]
        let dir = try directory()
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "buckets": [object]])
        try data.write(to: dir.appendingPathComponent(BrokerOutcomeStore.fileName))
        let store = BrokerOutcomeStore(storeDirectory: dir, now: { BrokerFixture.now })
        let before = await store.snapshot()
        var r = Self.record(status: .completed, outcome: .init(backupIndex: 1, harnessVersion: "cli/1", servedModel: "model-1", reviewVerdict: .pass))
        r.terminal = .init(decisionID: r.decisionID, status: .completed, durationMS: 25, actualOutputTokens: 20, actualReasoningTokens: 10)
        try await store.notePick(r)
        try await store.noteTerminal(r, reviewed: [Self.record()])
        for status in [BrokerLifecycleStatus.failed, .exhausted] {
            try await store.noteTerminal(Self.record(status: status, outcome: .init(harnessVersion: "cli/5", servedModel: "model-5")), reviewed: [])
        }
        let after = await store.snapshot()
        XCTAssertEqual(after, before)
    }
    func test_rejectedFilesStartEmptyAndBackupNeverOverwrites() async throws {
        let b = try XCTUnwrap(BrokerOutcomeStore.bucket(for: Self.record()))
        let encoded = try BrokerOutcomeStore.encoder().encode(BrokerOutcomeRollup(buckets: [b]))
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var cases: [String: Data] = ["invalid": Data("{".utf8), "oversized": Data(repeating: 32, count: 4 * 1024 * 1024 + 1)]
        for name in ["version", "negative", "over-counter", "day", "role", "model", "effort", "basis", "verdict-missing", "verdict-extra", "map-full", "map-model", "map-version", "missing-counter", "null-counter", "duplicate", "null-buckets", "bucket-cap", "fractional"] {
            var root = base
            var bucket = try XCTUnwrap((root["buckets"] as? [[String: Any]])?.first)
            switch name {
            case "version": root["version"] = 2
            case "negative": bucket["picks"] = -1
            case "over-counter": bucket["picks"] = BrokerOutcomeStore.Limits.production.maxCounter + 1
            case "day": bucket["day"] = "2023-02-30"
            case "role": bucket["role"] = "bad\nrole"
            case "model": bucket["model"] = ""
            case "effort": bucket["effort"] = String(repeating: "é", count: 129)
            case "basis": bucket["pick_basis"] = ""
            case "verdict-missing": bucket["verdicts_issued"] = ["fail": 0, "inconclusive": 0, "pass-with-nits": 0]
            case "verdict-extra": bucket["verdicts_received"] = ["fail": 0, "inconclusive": 0, "pass": 0, "pass-with-nits": 0, "unknown": 0]
            case "map-full": bucket["served_models"] = ["a": 1, "b": 1, "c": 1, "d": 1, "e": 1]
            case "map-model": bucket["served_models"] = ["model-AIzaFIXTURE": 1]
            case "map-version": bucket["harness_versions"] = ["invalid": 1]
            case "missing-counter": bucket.removeValue(forKey: "picks")
            case "null-counter": bucket["picks"] = NSNull()
            case "fractional": bucket["picks"] = 1.5
            default: break
            }
            root["buckets"] = [bucket]
            if name == "duplicate" { root["buckets"] = [bucket, bucket] }
            if name == "null-buckets" { root["buckets"] = NSNull() }
            if name == "bucket-cap" { root["buckets"] = (0..<8193).map { index in var row = bucket; row["model"] = String(index); return row } }
            cases[name] = try JSONSerialization.data(withJSONObject: root)
        }
        for (name, data) in cases {
            let dir = try directory()
            let url = dir.appendingPathComponent(BrokerOutcomeStore.fileName)
            let backup = url.appendingPathExtension("bak")
            try data.write(to: url)
            let store = BrokerOutcomeStore(storeDirectory: dir, now: { BrokerFixture.now })
            let failed = await store.loadFailed
            let snapshot = await store.snapshot()
            XCTAssertTrue(failed, name); XCTAssertEqual(snapshot.buckets, [], name)
            XCTAssertEqual(try Data(contentsOf: backup), data, name)
            try Data("different invalid file".utf8).write(to: url)
            let second = BrokerOutcomeStore(storeDirectory: dir)
            _ = await second.snapshot()
            XCTAssertEqual(try Data(contentsOf: backup), data, name)
        }
        let dir = try directory()
        let url = dir.appendingPathComponent(BrokerOutcomeStore.fileName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let unreadable = await BrokerOutcomeStore(storeDirectory: dir).loadFailed
        XCTAssertTrue(unreadable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }
    func test_byteKeysKeepCanonicalUnicodeSpellingsSeparateAndRejectControls() async throws {
        let store = BrokerOutcomeStore(storeDirectory: try directory(), now: { BrokerFixture.now })
        for role in ["é", "e\u{0301}", "z", "a\u{2028}b", "bad\u{200b}role", "bad\u{007f}role"] {
            try await store.notePick(Self.record(role: role))
        }
        let buckets = await store.snapshot().buckets
        XCTAssertEqual(buckets.count, 4)
        XCTAssertEqual(buckets.map { Array($0.role.utf8) }, ["a\u{2028}b", "e\u{0301}", "z", "é"].map { Array($0.utf8) })
    }

}

private final class OutcomeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}
