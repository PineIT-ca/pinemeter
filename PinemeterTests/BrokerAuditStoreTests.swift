//
//  BrokerAuditStoreTests.swift
//  PinemeterTests
//

import XCTest
@testable import Pinemeter

final class BrokerAuditStoreTests: XCTestCase {
    func testAuditRetentionRestartAndTransactionalWriteFailure() async throws {
        let directory = try makeTempDirectory()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let store = BrokerAuditStore(storeDirectory: directory)

        for index in 0..<BrokerAuditStore.capacity {
            try await store.append(
                decision: makeAuditDecision(decisionID: String(format: "decision-%03d", index)),
                timestamp: timestamp.addingTimeInterval(Double(index))
            )
        }
        try await store.append(
            decision: makeAuditDecision(decisionID: "decision-clock-rollback"),
            timestamp: timestamp.addingTimeInterval(-1)
        )

        let restarted = BrokerAuditStore(storeDirectory: directory)
        let retained = await restarted.recordsSnapshot
        XCTAssertEqual(retained.count, BrokerAuditStore.capacity)
        XCTAssertEqual(retained.first?.decisionID, "decision-499")
        XCTAssertEqual(retained.last?.decisionID, "decision-clock-rollback")
        XCTAssertFalse(retained.contains { $0.decisionID == "decision-000" })
        let lifecycleResult = try await restarted.reportLifecycle(
            BrokerLifecycleReport(decisionID: "decision-clock-rollback", status: .started)
        )
        XCTAssertEqual(lifecycleResult, .recorded)

        let writer = AuditWriterControl()
        let failingStore = BrokerAuditStore(
            storeDirectory: directory,
            writer: writer.write
        )
        let beforeFailure = await failingStore.recordsSnapshot
        writer.shouldFail = true

        await XCTAssertThrowsErrorAsync {
            try await failingStore.append(
                decision: makeAuditDecision(decisionID: "decision-write-failed"),
                timestamp: timestamp.addingTimeInterval(1)
            )
        }

        let afterFailure = await failingStore.recordsSnapshot
        let afterRestart = await BrokerAuditStore(storeDirectory: directory).recordsSnapshot
        XCTAssertEqual(afterFailure, beforeFailure)
        XCTAssertEqual(afterRestart, beforeFailure)
    }

    func testAuditStoreFailsEmptyForMissingEmptyCorruptOversizedAndUnknownVersionFiles() async throws {
        let fixtures: [Data?] = [
            nil,
            Data(),
            Data("not-json".utf8),
            Data(repeating: 0x61, count: BrokerAuditStore.maxFileBytes + 1),
            Data(#"{"version":3,"records":[]}"#.utf8),
        ]

        for fixture in fixtures {
            let directory = try makeTempDirectory()
            if let fixture {
                try fixture.write(to: directory.appendingPathComponent("broker-audit.json"))
            }
            let store = BrokerAuditStore(storeDirectory: directory)
            let records = await store.recordsSnapshot
            XCTAssertEqual(records, [])
        }
    }

    func testAuditStoreRejectsDuplicateAndMaximumPersistedOrders() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        for replacement in ["0", String(UInt64.max)] {
            let directory = try makeTempDirectory()
            let fileURL = directory.appendingPathComponent("broker-audit.json")
            let store = BrokerAuditStore(storeDirectory: directory)
            try await store.append(
                decision: makeAuditDecision(decisionID: "decision-0"),
                timestamp: timestamp
            )
            if replacement == "0" {
                try await store.append(
                    decision: makeAuditDecision(decisionID: "decision-1"),
                    timestamp: timestamp.addingTimeInterval(1)
                )
            }

            let valid = try String(contentsOf: fileURL, encoding: .utf8)
            let corrupted = valid.replacingOccurrences(
                of: replacement == "0" ? #""decision-1":1"# : #""decision-0":0"#,
                with: #""\#(replacement == "0" ? "decision-1" : "decision-0")":\#(replacement)"#
            )
            XCTAssertNotEqual(corrupted, valid)
            try Data(corrupted.utf8).write(to: fileURL)

            let restarted = BrokerAuditStore(storeDirectory: directory)
            let loaded = await restarted.recordsSnapshot
            XCTAssertTrue(loaded.isEmpty)
            try await restarted.append(
                decision: makeAuditDecision(decisionID: "decision-recovered"),
                timestamp: timestamp
            )
            let recovered = await restarted.recordsSnapshot
            XCTAssertEqual(recovered.count, 1)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testAuditStoreRejectsAnOversizedProspectiveEnvelopeTransactionally() async throws {
        let directory = try makeTempDirectory()
        let store = BrokerAuditStore(storeDirectory: directory)
        let largeText = String(repeating: "x", count: 2_048)
        let candidates = (0..<256).map { _ in
            BrokerCandidateTried(
                candidate: largeText,
                available: false,
                why: largeText
            )
        }
        var successfulWrites = 0

        while successfulWrites < 20 {
            do {
                try await store.append(
                    decision: makeAuditDecision(
                        decisionID: "large-\(successfulWrites)",
                        candidatesTried: candidates
                    ),
                    timestamp: Date(timeIntervalSince1970: TimeInterval(successfulWrites))
                )
                successfulWrites += 1
            } catch {
                break
            }
        }

        XCTAssertGreaterThan(successfulWrites, 0)
        XCTAssertLessThan(successfulWrites, 20)
        let inMemory = await store.recordsSnapshot
        let restarted = await BrokerAuditStore(storeDirectory: directory).recordsSnapshot
        XCTAssertEqual(inMemory.count, successfulWrites)
        XCTAssertEqual(restarted, inMemory)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("broker-audit.json"))
        XCTAssertLessThanOrEqual(bytes.count, BrokerAuditStore.maxFileBytes)
    }

    func testLifecycleWireBoundsOptionalityAndCorrelationRoundTrip() async throws {
        let directory = try makeTempDirectory()
        let store = BrokerAuditStore(storeDirectory: directory)
        let correlationID = String(repeating: "x", count: 128)
        try await store.append(
            decision: makeAuditDecision(decisionID: "decision-completed"),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let completed = BrokerLifecycleReport(
            decisionID: "  decision-completed  ",
            status: .completed,
            threadID: "  \(correlationID)  ",
            sessionID: correlationID,
            durationMS: 604_800_000,
            actualInputTokens: 2_147_483_647,
            actualCachedInputTokens: 2_147_483_647,
            actualCacheCreationInputTokens: 2_147_483_647,
            actualOutputTokens: 2_147_483_647,
            actualReasoningTokens: 2_147_483_647
        )
        let completedResult = try await store.reportLifecycle(completed)
        XCTAssertEqual(completedResult, .recorded)

        let restarted = BrokerAuditStore(storeDirectory: directory)
        let restartedRecords = await restarted.recordsSnapshot
        let persisted = try XCTUnwrap(restartedRecords.first?.terminal)
        let persistedCorrelationID = try XCTUnwrap(BrokerLifecycleText.persistedIdentifier(correlationID))
        XCTAssertEqual(persisted.decisionID, "decision-completed")
        XCTAssertEqual(persisted.threadID, persistedCorrelationID)
        XCTAssertEqual(persisted.sessionID, persistedCorrelationID)
        XCTAssertEqual(persisted.durationMS, 604_800_000)
        XCTAssertEqual(persisted.actualReasoningTokens, persisted.actualOutputTokens)

        try await store.append(
            decision: makeAuditDecision(decisionID: "decision-minimum"),
            timestamp: Date(timeIntervalSince1970: 1_700_000_002)
        )
        let minimum = try await store.reportLifecycle(
            BrokerLifecycleReport(
                decisionID: "decision-minimum",
                status: .completed,
                durationMS: 0,
                actualInputTokens: 0,
                actualCachedInputTokens: 0,
                actualCacheCreationInputTokens: 0,
                actualOutputTokens: 0,
                actualReasoningTokens: 0
            )
        )
        XCTAssertEqual(minimum, .recorded)

        let failedID = "decision-failed"
        try await store.append(
            decision: makeAuditDecision(decisionID: failedID),
            timestamp: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let reason = "\u{0000}\n  failure  " + String(repeating: "z", count: 300)
        let failedResult = try await store.reportLifecycle(
            BrokerLifecycleReport(decisionID: failedID, status: .failed, failureReason: reason)
        )
        XCTAssertEqual(failedResult, .recorded)
        let failedRecords = await store.recordsSnapshot
        let sanitized = try XCTUnwrap(
            failedRecords.first(where: { $0.decisionID == failedID })?.terminal?.failureReason
        )
        XCTAssertEqual(sanitized, BrokerLifecycleText.persistedFailureReason)

        let invalidReports = [
            BrokerLifecycleReport(decisionID: "", status: .completed),
            BrokerLifecycleReport(decisionID: String(repeating: "x", count: 129), status: .completed),
            BrokerLifecycleReport(
                decisionID: failedID,
                status: .completed,
                threadID: String(repeating: "x", count: 129)
            ),
            BrokerLifecycleReport(decisionID: failedID, status: .completed, sessionID: "  "),
            BrokerLifecycleReport(decisionID: failedID, status: .started, durationMS: 0),
            BrokerLifecycleReport(decisionID: failedID, status: .completed, failureReason: "no"),
            BrokerLifecycleReport(decisionID: failedID, status: .completed, durationMS: -1),
            BrokerLifecycleReport(decisionID: failedID, status: .completed, durationMS: 604_800_001),
            BrokerLifecycleReport(decisionID: failedID, status: .completed, actualInputTokens: -1),
            BrokerLifecycleReport(decisionID: failedID, status: .completed, actualInputTokens: 2_147_483_648),
            BrokerLifecycleReport(
                decisionID: failedID,
                status: .completed,
                actualOutputTokens: 1,
                actualReasoningTokens: 2
            ),
            BrokerLifecycleReport(decisionID: failedID, status: .failed, failureReason: "\n\u{0000}"),
        ]
        for report in invalidReports {
            await XCTAssertThrowsErrorAsync { _ = try await store.reportLifecycle(report) }
        }

        let wire = #"{"decision_id":"d","status":"completed","request":{"prompt":"secret"}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(BrokerLifecycleReport.self, from: Data(wire.utf8))
        )
        let bytes = try Data(contentsOf: directory.appendingPathComponent("broker-audit.json"))
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains(correlationID))
        XCTAssertTrue(text.contains(persistedCorrelationID))
        XCTAssertFalse(text.contains("prompt"))
        XCTAssertFalse(text.contains("usage-scan-cache"))
        XCTAssertFalse(text.contains("transcript-path"))
    }

    func testLegacySchemasMigrateFailureReasonsWithoutDecisionLoss() async throws {
        for legacyVersion in [1, 2] {
            let directory = try makeTempDirectory()
            let fileURL = directory.appendingPathComponent("broker-audit.json")
            let store = BrokerAuditStore(storeDirectory: directory)
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            let sentinel = "legacy-(legacyVersion)-opaque-Q7vK4pL9xR2m"

            try await store.append(
                decision: makeAuditDecision(decisionID: "decision-failed"),
                timestamp: timestamp
            )
            _ = try await store.reportLifecycle(
                BrokerLifecycleReport(
                    decisionID: "decision-failed",
                    status: .failed,
                    threadID: "thread 1",
                    sessionID: "session-🔬",
                    failureReason: "temporary"
                )
            )
            try await store.append(
                decision: makeAuditDecision(decisionID: "decision-unrelated"),
                timestamp: timestamp.addingTimeInterval(1)
            )

            var envelope = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
            )
            envelope["version"] = legacyVersion
            var records = try XCTUnwrap(envelope["records"] as? [[String: Any]])
            let recordIndex = try XCTUnwrap(
                records.firstIndex { $0["decision_id"] as? String == "decision-failed" }
            )
            var terminal = try XCTUnwrap(records[recordIndex]["terminal"] as? [String: Any])
            terminal["failure_reason"] = sentinel
            if legacyVersion == 1 {
                terminal["thread_id"] = "thread 1"
                terminal["session_id"] = "session-🔬"
            }
            records[recordIndex]["terminal"] = terminal
            envelope["records"] = records
            try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: fileURL)

            let firstRestart = BrokerAuditStore(storeDirectory: directory)
            let migrated = await firstRestart.recordsSnapshot
            XCTAssertEqual(migrated.count, 2, "schema (legacyVersion)")
            let lifecycle = try XCTUnwrap(
                migrated.first(where: { $0.decisionID == "decision-failed" })?.terminal
            )
            XCTAssertEqual(lifecycle.status, .failed)
            XCTAssertEqual(lifecycle.threadID, BrokerLifecycleText.persistedIdentifier("thread 1"))
            XCTAssertEqual(lifecycle.sessionID, BrokerLifecycleText.persistedIdentifier("session-🔬"))
            XCTAssertEqual(lifecycle.failureReason, BrokerLifecycleText.persistedFailureReason)
            XCTAssertNil(migrated.first { $0.decisionID == "decision-unrelated" }?.terminal)

            let rewritten = try Data(contentsOf: fileURL)
            XCTAssertTrue(String(decoding: rewritten, as: UTF8.self).contains(#""version":3"#))
            XCTAssertNil(rewritten.range(of: Data(sentinel.utf8)))
            let secondRestart = BrokerAuditStore(storeDirectory: directory)
            let stableRecords = await secondRestart.recordsSnapshot
            XCTAssertEqual(stableRecords, migrated)
            XCTAssertEqual(try Data(contentsOf: fileURL), rewritten)
        }
    }

    func testCurrentSchemaRejectsNoncanonicalFailureReason() async throws {
        let directory = try makeTempDirectory()
        let fileURL = directory.appendingPathComponent("broker-audit.json")
        let store = BrokerAuditStore(storeDirectory: directory)
        try await store.append(
            decision: makeAuditDecision(decisionID: "decision-current"),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        _ = try await store.reportLifecycle(
            BrokerLifecycleReport(
                decisionID: "decision-current",
                status: .failed,
                failureReason: "temporary"
            )
        )

        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        var records = try XCTUnwrap(envelope["records"] as? [[String: Any]])
        var terminal = try XCTUnwrap(records[0]["terminal"] as? [String: Any])
        terminal["failure_reason"] = "noncanonical-caller-text"
        records[0]["terminal"] = terminal
        envelope["records"] = records
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: fileURL)

        let loaded = await BrokerAuditStore(storeDirectory: directory).recordsSnapshot
        XCTAssertTrue(loaded.isEmpty)
    }

    func testLifecyclePersistenceDigestsIdentifiersAndRedactsSecretShapes() async throws {
        let directory = try makeTempDirectory()
        let store = BrokerAuditStore(storeDirectory: directory)
        let secrets = [
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturePart1234",
            "AKIAIOSFODNN7EXAMPLE",
            "sk-proj-abcdefghijklmnopqrstuvwxyz123456",
            "AIzaSyDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY",
        ]

        for (index, secret) in secrets.enumerated() {
            let decisionID = "decision-secret-\(index)"
            try await store.append(
                decision: makeAuditDecision(decisionID: decisionID),
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
            _ = try await store.reportLifecycle(
                BrokerLifecycleReport(
                    decisionID: decisionID,
                    status: .started,
                    threadID: secret,
                    sessionID: secret
                )
            )
            _ = try await store.reportLifecycle(
                BrokerLifecycleReport(
                    decisionID: decisionID,
                    status: .failed,
                    failureReason: "provider rejected \(secret) for account"
                )
            )
        }

        let bytes = try Data(contentsOf: directory.appendingPathComponent("broker-audit.json"))
        let text = String(decoding: bytes, as: UTF8.self)
        for secret in secrets {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertTrue(text.contains("sha256:"))
        XCTAssertTrue(text.contains(BrokerLifecycleText.persistedFailureReason))
        let restartedCount = await BrokerAuditStore(storeDirectory: directory).recordsSnapshot.count
        XCTAssertEqual(restartedCount, secrets.count)
    }

    func testLifecycleTransitionsAndWriteFailuresRemainAtomicAcrossRestart() async throws {
        let directory = try makeTempDirectory()
        let writer = AuditWriterControl()
        let store = BrokerAuditStore(storeDirectory: directory, writer: writer.write)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.append(decision: makeAuditDecision(decisionID: "decision-1"), timestamp: timestamp)

        let unknown = try await store.reportLifecycle(
            BrokerLifecycleReport(decisionID: "unknown", status: .started)
        )
        XCTAssertEqual(unknown, .unknownDecision)
        let started = try await store.reportLifecycle(
            BrokerLifecycleReport(decisionID: "decision-1", status: .started, threadID: "thread-1")
        )
        XCTAssertEqual(started, .recorded)
        let repeatedStarted = try await store.reportLifecycle(
            BrokerLifecycleReport(decisionID: "decision-1", status: .started, threadID: "other")
        )
        XCTAssertEqual(repeatedStarted, .duplicate)
        let completed = BrokerLifecycleReport(
            decisionID: "decision-1", status: .completed, durationMS: 1,
            actualOutputTokens: 1, actualReasoningTokens: 1
        )
        let terminal = try await store.reportLifecycle(completed)
        let repeatedTerminal = try await store.reportLifecycle(completed)
        let conflictingTerminal = try await store.reportLifecycle(
            BrokerLifecycleReport(decisionID: "decision-1", status: .failed)
        )
        XCTAssertEqual(terminal, .recorded)
        XCTAssertEqual(repeatedTerminal, .duplicate)
        XCTAssertEqual(conflictingTerminal, .alreadyFinalized)
        let repeatedStartedAfterTerminal = try await store.reportLifecycle(
            BrokerLifecycleReport(decisionID: "decision-1", status: .started)
        )
        XCTAssertEqual(repeatedStartedAfterTerminal, .duplicate)

        try await store.append(decision: makeAuditDecision(decisionID: "decision-exhausted"), timestamp: timestamp)
        let exhausted = try await store.reportLifecycle(
            BrokerLifecycleReport(
                decisionID: "decision-exhausted",
                status: .exhausted,
                failureReason: "quota exhausted"
            )
        )
        XCTAssertEqual(exhausted, .recorded)

        let restarted = BrokerAuditStore(storeDirectory: directory)
        let recordsAfterRestart = await restarted.recordsSnapshot
        let restartedRecord = try XCTUnwrap(recordsAfterRestart.first { $0.decisionID == "decision-1" })
        XCTAssertEqual(restartedRecord.started?.status, .started)
        XCTAssertEqual(restartedRecord.terminal?.status, .completed)
        XCTAssertEqual(
            recordsAfterRestart.first { $0.decisionID == "decision-exhausted" }?.terminal?.status,
            .exhausted
        )

        try await store.append(decision: makeAuditDecision(decisionID: "decision-write"), timestamp: timestamp)
        let beforeFailure = await store.recordsSnapshot
        writer.shouldFail = true
        await XCTAssertThrowsErrorAsync {
            _ = try await store.reportLifecycle(
                BrokerLifecycleReport(decisionID: "decision-write", status: .exhausted)
            )
        }
        let afterFailure = await store.recordsSnapshot
        let afterFailureRestart = await BrokerAuditStore(storeDirectory: directory).recordsSnapshot
        XCTAssertEqual(afterFailure, beforeFailure)
        XCTAssertEqual(afterFailureRestart, beforeFailure)
    }

    func testConcurrentAndCancelledLifecycleReportsKeepOneCompleteTransition() async throws {
        let directory = try makeTempDirectory()
        let store = BrokerAuditStore(storeDirectory: directory)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.append(decision: makeAuditDecision(decisionID: "decision-concurrent"), timestamp: timestamp)

        async let completed = store.reportLifecycle(
            BrokerLifecycleReport(decisionID: "decision-concurrent", status: .completed)
        )
        async let failed = store.reportLifecycle(
            BrokerLifecycleReport(decisionID: "decision-concurrent", status: .failed)
        )
        let results = try await [completed, failed]
        XCTAssertEqual(Set(results), Set([.recorded, .alreadyFinalized]))

        try await store.append(decision: makeAuditDecision(decisionID: "decision-cancelled"), timestamp: timestamp)
        let task = Task {
            try await store.reportLifecycle(
                BrokerLifecycleReport(decisionID: "decision-cancelled", status: .exhausted)
            )
        }
        task.cancel()
        _ = try? await task.value

        let restarted = await BrokerAuditStore(storeDirectory: directory).recordsSnapshot
        XCTAssertEqual(restarted.count, 2)
        let cancelled = try XCTUnwrap(restarted.first { $0.decisionID == "decision-cancelled" })
        XCTAssertTrue(cancelled.terminal == nil || cancelled.terminal?.status == .exhausted)

        try await store.append(decision: makeAuditDecision(decisionID: "decision-duplicate"), timestamp: timestamp)
        async let first = store.reportLifecycle(
            BrokerLifecycleReport(decisionID: "decision-duplicate", status: .completed)
        )
        async let second = store.reportLifecycle(
            BrokerLifecycleReport(decisionID: "decision-duplicate", status: .completed, durationMS: 1)
        )
        let duplicateResults = try await [first, second]
        XCTAssertEqual(Set(duplicateResults), Set([.recorded, .duplicate]))
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerAuditStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class AuditWriterControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _shouldFail = false

    var shouldFail: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _shouldFail
        }
        set {
            lock.lock()
            _shouldFail = newValue
            lock.unlock()
        }
    }

    func write(_ data: Data, _ url: URL) throws {
        if shouldFail { throw AuditTestError.writeFailed }
        try data.write(to: url, options: .atomic)
    }
}

private enum AuditTestError: Error {
    case writeFailed
}

private func makeAuditDecision(
    decisionID: String,
    candidatesTried: [BrokerCandidateTried]? = nil
) -> BrokerDecision {
    BrokerDecision(
        role: "planning",
        caller: "claude-code",
        model: "native/claude-fable-5",
        route: .native,
        agentModel: "fable",
        invocation: .agent(model: "fable"),
        reason: "native quota available",
        source: .policy,
        oracle: .absent,
        degraded: false,
        candidatesTried: candidatesTried ?? [
            BrokerCandidateTried(
                candidate: "native/claude-fable-5",
                available: true,
                why: "native quota available"
            )
        ],
        decisionID: decisionID
    )
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
