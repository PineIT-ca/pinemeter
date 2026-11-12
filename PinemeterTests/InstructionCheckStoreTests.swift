//
//  InstructionCheckStoreTests.swift
//  PinemeterTests
//
//  The record behind the Instructions pane's "last checked" line. It is the
//  only instruction state Pinemeter keeps, so what it must never keep matters
//  as much as what it does.
//

import XCTest
@testable import Pinemeter

final class InstructionCheckStoreTests: XCTestCase {
    private var directory: URL!
    private let checkedAt = Date(timeIntervalSince1970: 1_760_000_000)
    /// The grading build, for the cases that are not about which build graded.
    private let version = "1.1.0"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstructionCheckStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    private func makeStore() -> InstructionCheckStore {
        InstructionCheckStore(storeDirectory: directory)
    }

    private func report(_ sources: [(String, InstructionAuditStatus, [String])]) -> InstructionAuditReport {
        InstructionAuditReport(sources: sources.map { path, status, findings in
            InstructionAuditSourceReport(
                path: path,
                status: status,
                findings: findings.map { InstructionAuditFinding(kind: .missingDirective, message: $0) }
            )
        })
    }

    func test_dispatchedCompletionSurvivesUnrelatedAuditAndRestart() async throws {
        let store = makeStore()
        let provenance = InstructionDispatchProvenance(version: version, setupRevision: 3)
        await store.recordDispatch(InstructionDispatchRun(
            runID: "run-A", provenance: provenance, dispatchedAt: checkedAt, completedAt: nil
        ))
        let completedAt = checkedAt.addingTimeInterval(60)
        await store.record(
            report: report([("a.md", .pass, [])]), runID: "run-A", caller: "codex",
            gradedBy: version, setupRevision: 3, at: completedAt
        )
        await store.record(
            report: report([("b.md", .warning, [])]), runID: "unrelated-B", caller: "codex",
            gradedBy: version, setupRevision: 3, at: checkedAt.addingTimeInterval(120)
        )
        let reloaded = makeStore()
        let run = await reloaded.dispatchRun()
        let latest = await reloaded.latest()
        XCTAssertEqual(latest?.runID, "unrelated-B")
        XCTAssertEqual(run?.runID, "run-A")
        XCTAssertEqual(run?.provenance, provenance)
        XCTAssertEqual(run?.completedAt, completedAt)
        // B is stale, but the automatic attempt's cooldown still holds.
        let settings = BrokerInstructionDispatchSettings(
            lastDispatchedAt: checkedAt, lastDispatchThreadID: "run-A",
            lastAutomaticDispatchAt: checkedAt.addingTimeInterval(240),
            lastDispatchProvenance: provenance, lastAutomaticDispatchProvenance: provenance
        )
        XCTAssertFalse(InstructionRecheck.shouldDispatchAutomatically(
            check: latest, settings: settings, provenance: provenance,
            run: run, now: checkedAt.addingTimeInterval(InstructionRecheck.interval + 121)
        ))
        XCTAssertTrue(InstructionRecheck.shouldDispatchAutomatically(
            check: latest, settings: settings, provenance: provenance,
            run: run, now: checkedAt.addingTimeInterval(InstructionRecheck.interval + 240)
        ))
    }

    func test_onlyMatchingDispatchAuditCompletesTheRun() async throws {
        let store = makeStore()
        let provenance = InstructionDispatchProvenance(version: version, setupRevision: 3)
        await store.recordDispatch(InstructionDispatchRun(
            runID: "run-A", provenance: provenance, dispatchedAt: checkedAt, completedAt: nil
        ))
        for (runID, gradedBy, revision, date) in [
            ("unrelated", version, 3, checkedAt),
            ("run-A", "other-version", 3, checkedAt),
            ("run-A", version, 2, checkedAt),
            ("run-A", version, 3, checkedAt.addingTimeInterval(-1))
        ] {
            await store.record(
                report: report([("a.md", .pass, [])]), runID: runID, caller: "codex",
                gradedBy: gradedBy, setupRevision: revision, at: date
            )
            let run = await store.dispatchRun()
            XCTAssertNil(run?.completedAt)
        }
        // Even an unavailable audit ends the worker's unfinished hold.
        await store.record(
            report: report([("a.md", .unavailable, [])]), runID: "run-A", caller: "codex",
            gradedBy: version, setupRevision: 3, at: checkedAt.addingTimeInterval(1)
        )
        let completed = await store.dispatchRun()
        XCTAssertEqual(completed?.completedAt, checkedAt.addingTimeInterval(1))
    }

    func test_dispatchDatesRetainSubsecondPrecisionAcrossRestart() async throws {
        let store = makeStore()
        let run = InstructionDispatchRun(
            runID: "run-A", provenance: .init(version: version, setupRevision: 0),
            dispatchedAt: Date(timeIntervalSinceReferenceDate: 800_000_000.0000001),
            completedAt: Date(timeIntervalSinceReferenceDate: 800_000_000.0000004)
        )
        await store.recordDispatch(run)
        let reloaded = await makeStore().dispatchRun()
        XCTAssertEqual(reloaded, run)
    }

    func test_dispatchRegistrationBeforeAnyAuditSurvivesRestart() async throws {
        let run = InstructionDispatchRun(
            runID: "run-A", provenance: .init(version: version, setupRevision: 0),
            dispatchedAt: checkedAt, completedAt: nil
        )
        await makeStore().recordDispatch(run)
        let reloaded = makeStore()
        let loaded = await reloaded.dispatchRun()
        let check = await reloaded.latest()
        XCTAssertEqual(loaded, run)
        XCTAssertNil(check)
    }

    func test_recordSurvivesARestart() async throws {
        let store = makeStore()
        await store.record(
            report: report([("~/.claude/CLAUDE.md", .warning, ["Missing directive: fail-closed behavior."])]),
            runID: "run-1",
            caller: "claude-code",
            gradedBy: version,
            setupRevision: 3,
            at: checkedAt
        )

        let reloaded = await makeStore().latest()

        XCTAssertEqual(reloaded?.runID, "run-1")
        XCTAssertEqual(reloaded?.caller, "claude-code")
        XCTAssertEqual(reloaded?.checkedAt, checkedAt)
        XCTAssertEqual(reloaded?.sources.first?.findings, ["Missing directive: fail-closed behavior."])
        XCTAssertEqual(reloaded?.status, .warning)
        XCTAssertEqual(reloaded?.gradedBy, version)
        XCTAssertEqual(reloaded?.setupRevision, 3)
        let stored = try JSONSerialization.jsonObject(with: Data(
            contentsOf: directory.appendingPathComponent(InstructionCheckStore.fileName)
        )) as? [String: Any]
        let storedCheck = stored?["check"] as? [String: Any]
        XCTAssertEqual(storedCheck?["setup_revision"] as? Int, 3)
    }

    /// A record written before the grading version existed decodes rather than
    /// being discarded, which would throw away the only evidence the machine
    /// has just as the app learns to question it.
    func test_aStoreFileWithoutAGradingVersionDecodesToNil() async throws {
        let json = """
        {
            "version": 1,
            "check": {
                "runID": "run-1",
                "caller": "claude-code",
                "checkedAt": "2025-10-09T07:33:20Z",
                "sources": [{ "path": "a.md", "status": "pass", "findings": [] }]
            }
        }
        """
        try Data(json.utf8).write(
            to: directory.appendingPathComponent(InstructionCheckStore.fileName)
        )

        let loaded = await makeStore().latest()

        XCTAssertEqual(loaded?.runID, "run-1")
        XCTAssertNil(loaded?.gradedBy)
        XCTAssertNil(loaded?.setupRevision)
        let run = await makeStore().dispatchRun()
        XCTAssertNil(run)
    }

    /// An app update mid-run: the record describes one stack, and the build
    /// that graded its last batch is the one the whole record answers to.
    func test_aMergedRunKeepsTheGradingVersionOfTheLatestBatch() async throws {
        let store = makeStore()
        await store.record(
            report: report([("a.md", .pass, [])]),
            runID: "run-1", caller: nil, gradedBy: "1.1.0", at: checkedAt
        )
        await store.record(
            report: report([("b.md", .pass, [])]),
            runID: "run-1", caller: nil, gradedBy: "1.2.0", at: checkedAt.addingTimeInterval(30)
        )

        let latest = await store.latest()
        let check = try XCTUnwrap(latest)
        XCTAssertEqual(check.sources.map(\.path), ["a.md", "b.md"])
        XCTAssertEqual(check.gradedBy, "1.2.0")
    }

    func test_batchesSharingARunIDMergeByPathAndLastWins() async throws {
        let store = makeStore()
        await store.record(
            report: report([("a.md", .warning, ["gap"]), ("b.md", .pass, [])]),
            runID: "run-1", caller: nil, gradedBy: version, at: checkedAt
        )
        await store.record(
            report: report([("c.md", .conflict, ["clash"]), ("a.md", .pass, [])]),
            runID: "run-1", caller: nil, gradedBy: version, at: checkedAt.addingTimeInterval(30)
        )

        let latest = await store.latest()
        let check = try XCTUnwrap(latest)
        XCTAssertEqual(check.sources.map(\.path), ["a.md", "b.md", "c.md"])
        XCTAssertEqual(check.sources.first { $0.path == "a.md" }?.status, .pass,
                       "a re-sent path takes the newer verdict")
        XCTAssertEqual(check.checkedAt, checkedAt.addingTimeInterval(30))
        XCTAssertEqual(check.status, .conflict)
    }

    func test_aDifferentOrAbsentRunIDReplacesRatherThanAccumulates() async throws {
        let store = makeStore()
        await store.record(report: report([("a.md", .pass, [])]), runID: "run-1", caller: nil, gradedBy: version, at: checkedAt)
        await store.record(report: report([("b.md", .pass, [])]), runID: "run-2", caller: nil, gradedBy: version, at: checkedAt)
        let afterRun2 = await store.latest()
        XCTAssertEqual(afterRun2?.sources.map(\.path), ["b.md"])

        // Without a run id every call stands alone, so an agent that never
        // sends one cannot silently accumulate a stale union of past checks.
        await store.record(report: report([("c.md", .pass, [])]), runID: nil, caller: nil, gradedBy: version, at: checkedAt)
        await store.record(report: report([("d.md", .pass, [])]), runID: nil, caller: nil, gradedBy: version, at: checkedAt)
        let afterNoRun = await store.latest()
        XCTAssertEqual(afterNoRun?.sources.map(\.path), ["d.md"])
    }

    /// A caller that reuses a stable id — a session id, a harness name —
    /// must not fold a fresh batch into a record from another day. The stale
    /// paths would ride along under today's timestamp, which is the
    /// stale-subset problem this design exists to remove, inverted.
    func test_aStaleRunIDStartsAFreshCheckRatherThanMerging() async throws {
        let store = makeStore()
        await store.record(report: report([("old.md", .warning, ["gap"])]), runID: "stable",
                           caller: nil, gradedBy: version, at: checkedAt)

        let justInside = checkedAt.addingTimeInterval(InstructionCheckStore.mergeWindow - 1)
        await store.record(report: report([("new.md", .pass, [])]), runID: "stable",
                           caller: nil, gradedBy: version, at: justInside)
        let merged = await store.latest()
        XCTAssertEqual(merged?.sources.map(\.path), ["new.md", "old.md"], "batches inside the window merge")

        let wellOutside = justInside.addingTimeInterval(InstructionCheckStore.mergeWindow + 1)
        await store.record(report: report([("newer.md", .pass, [])]), runID: "stable",
                           caller: nil, gradedBy: version, at: wellOutside)
        let fresh = await store.latest()
        XCTAssertEqual(fresh?.sources.map(\.path), ["newer.md"], "a stale run id starts over")
        XCTAssertEqual(fresh?.checkedAt, wellOutside)
    }

    /// A record written under a clock that has since moved backwards (a manual
    /// change, an NTP correction) must not merge either: the window would read
    /// as negative and pass a naive "less than" check.
    func test_aRecordFromTheFutureIsNotMergedInto() async throws {
        let store = makeStore()
        await store.record(report: report([("future.md", .pass, [])]), runID: "stable",
                           caller: nil, gradedBy: version, at: checkedAt)

        await store.record(report: report([("now.md", .pass, [])]), runID: "stable",
                           caller: nil, gradedBy: version, at: checkedAt.addingTimeInterval(-60))
        let latest = await store.latest()
        XCTAssertEqual(latest?.sources.map(\.path), ["now.md"])
    }

    func test_identifiersAreRejectedWhenBlankOversizedOrControlBearing() async throws {
        let store = makeStore()
        await store.record(
            report: report([("a.md", .pass, [])]),
            runID: "   ",
            caller: String(repeating: "c", count: InstructionCheckStore.maxIdentifierLength + 1),
            gradedBy: version,
            at: checkedAt
        )
        var latest = await store.latest()
        var check = try XCTUnwrap(latest)
        XCTAssertNil(check.runID)
        XCTAssertNil(check.caller)

        await store.record(
            report: report([("a.md", .pass, [])]),
            runID: "run\u{0}1",
            caller: "claude\ncode",
            gradedBy: version,
            at: checkedAt
        )
        latest = await store.latest()
        check = try XCTUnwrap(latest)
        XCTAssertNil(check.runID)
        XCTAssertNil(check.caller)
    }

    func test_findingsAreCappedPerSourceAndPerMessage() async throws {
        let store = makeStore()
        await store.record(
            report: report([(
                "a.md",
                .warning,
                (0..<(InstructionCheckStore.maxFindingsPerSource + 5)).map { _ in
                    String(repeating: "x", count: InstructionCheckStore.maxFindingLength + 50)
                }
            )]),
            runID: nil, caller: nil, gradedBy: version, at: checkedAt
        )

        let latest = await store.latest()
        let source = try XCTUnwrap(latest?.sources.first)
        XCTAssertEqual(source.findings.count, InstructionCheckStore.maxFindingsPerSource)
        XCTAssertEqual(source.findings.first?.count, InstructionCheckStore.maxFindingLength)
    }

    func test_aWriteFailureLeavesTheStoreOnItsLastGoodRecord() async throws {
        let store = InstructionCheckStore(
            storeDirectory: directory,
            writer: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        await store.record(report: report([("a.md", .pass, [])]), runID: nil, caller: nil, gradedBy: version, at: checkedAt)

        let inMemory = await store.latest()
        XCTAssertNil(inMemory, "an unwritten check must not linger in memory")
        let reloaded = await makeStore().latest()
        XCTAssertNil(reloaded)
    }

    func test_anEmptyCheckIsUnavailableRatherThanPassing() {
        let check = InstructionCheck(runID: nil, caller: nil, checkedAt: checkedAt, sources: [])
        XCTAssertEqual(check.status, .unavailable, "nothing checked is not the same as everything passing")
    }

    /// A check stored before reference crediting existed never wrote a
    /// "credited" status. It must still decode today, unaffected by adding
    /// the new `InstructionAuditStatus` case.
    func test_aCheckStoredBeforeReferenceCreditingStillDecodes() async throws {
        let json = """
        {
            "version": 1,
            "check": {
                "runID": "run-1",
                "caller": "claude-code",
                "checkedAt": "2025-10-09T07:33:20Z",
                "gradedBy": "1.0.0",
                "sources": [
                    { "path": "~/.claude/CLAUDE.md", "status": "pass", "findings": [] },
                    {
                        "path": "~/.claude/skills/broker-dispatch/SKILL.md",
                        "status": "warning",
                        "findings": ["Missing directive: nested-subtask broker selection."]
                    }
                ]
            }
        }
        """
        try Data(json.utf8).write(
            to: directory.appendingPathComponent(InstructionCheckStore.fileName)
        )

        let loaded = await makeStore().latest()

        XCTAssertEqual(loaded?.runID, "run-1")
        XCTAssertEqual(loaded?.gradedBy, "1.0.0")
        XCTAssertEqual(loaded?.sources.map(\.path), [
            "~/.claude/CLAUDE.md", "~/.claude/skills/broker-dispatch/SKILL.md",
        ])
        XCTAssertEqual(loaded?.status, .warning)
    }
}
