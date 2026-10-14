//
//  GoldenStoreFixtureTests.swift
//  PinemeterTests
//
//  Generates the ENGINE-04 half of the golden corpus: the on-disk formats of
//  the three broker file stores, written by the real Mac stores from
//  deterministic inputs and copied into `golden/stores/` byte for byte.
//
//  The fixture files here are NEVER re-encoded on the way out. Whatever
//  `BrokerCooldownStore`, `BrokerAuditStore` and `UsageTelemetryStore` put on
//  disk is what Go must read, so a "tidied" copy would document the tidying
//  rather than the store. Hand-written inputs (the reference CLI's cooldown
//  file, the malformed and oversize files) are the exception and are marked
//  as such in each case's `.ops.json`.
//
//  Ownership (see golden/README.md § Ownership): this class owns
//  `golden/stores/{cooldowns,audit,telemetry}` and wipes only those three.
//  `golden/stores/go-written/` belongs to the Go side (Plan 11-10) and must
//  never be touched from here.
//

import Foundation
import XCTest
@testable import Pinemeter

final class GoldenStoreFixtureTests: XCTestCase {

    /// The single instant every store fixture is built at. Shared with the
    /// decision corpus so a Go test can reuse one clock for both.
    private static let clock = BrokerFixture.now

    // MARK: - Export plumbing

    private func output(_ store: String) -> URL? {
        guard GoldenFixture.exportDirectory() != nil else { return nil }
        return GoldenFixture.storesDirectory.appendingPathComponent(store)
    }

    /// Wiped lazily, once per process, and only for the directory named.
    /// Deliberately three separate wipes rather than one over
    /// `golden/stores`: that tree also holds `go-written/`, which this
    /// exporter does not own and must not delete.
    private static func wipeOnce(_ store: String, _ flag: inout Bool) {
        guard !flag else { return }
        flag = true
        guard GoldenFixture.exportDirectory() != nil else { return }
        let directory = GoldenFixture.storesDirectory.appendingPathComponent(store)
        do { try GoldenFixture.wipe(directory) } catch {
            fatalError("could not wipe \(directory.path): \(error)")
        }
    }

    nonisolated(unsafe) private static var cooldownsWiped = false
    nonisolated(unsafe) private static var auditWiped = false
    nonisolated(unsafe) private static var telemetryWiped = false

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoldenStoreFixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Byte copy. No decode, no re-encode, no trailing newline.
    private func copyVerbatim(_ source: URL, to directory: URL?, named name: String) throws {
        guard let directory else { return }
        try GoldenFixture.write(try Data(contentsOf: source), to: directory, named: name)
    }

    /// `.ops.json` files are inputs, not expectations: pretty-printed with
    /// sorted keys exactly like `golden/decisions/*.input.json`, and never
    /// byte-compared by either side.
    private func writeOps<T: Encodable>(_ ops: T, to directory: URL?, named name: String) throws {
        guard let directory else { return }
        try GoldenFixture.write(
            try GoldenFixture.inputEncoder().encode(ops), to: directory, named: name
        )
    }

    private func writeCanonical<T: Encodable>(
        _ value: T, to directory: URL?, named name: String
    ) throws {
        guard let directory else { return }
        try GoldenFixture.write(
            try GoldenFixture.policyEncoder().encode(value), to: directory, named: name
        )
    }

    // MARK: - Ops documents

    private struct CooldownOps: Encodable {
        struct Operation: Encodable {
            let op: String
            let target: String?
            let minutes: Int?
        }
        let clock: Date
        let storeFile: String
        let cliFile: String?
        let handWritten: Bool
        let operations: [Operation]
        let notes: [String]
    }

    private struct AuditOps: Encodable {
        struct Appended: Encodable {
            let decisionID: String
            let timestamp: Date
            let decision: BrokerDecision
        }
        struct Reported: Encodable {
            let report: BrokerLifecycleReport
            let result: String
        }
        let clock: Date
        let storeFile: String
        let appended: [Appended]
        let reported: [Reported]
        let notes: [String]
    }

    private struct TelemetryOps: Encodable {
        let clock: Date
        let storeFile: String
        let appended: [UsageTelemetryRecord]
        let notes: [String]
    }

    private struct SimpleOps: Encodable {
        let clock: Date
        let storeFile: String
        let handWritten: Bool
        let notes: [String]
    }

    // MARK: - Cooldowns

    func test_exportsCooldownStoreFixtures() async throws {
        Self.wipeOnce("cooldowns", &Self.cooldownsWiped)
        let out = output("cooldowns")
        let clock = Self.clock

        // --- in-app-basic: two `down` calls at the fixed clock.
        let basicDirectory = try makeTempDirectory()
        let basicStore = BrokerCooldownStore(
            storeDirectory: basicDirectory,
            cliCooldownsURL: basicDirectory.appendingPathComponent("cli-cooldowns.json"),
            now: { clock }
        )
        try await basicStore.down(target: "t3:codex/gpt-5.6-sol", minutes: 60)
        try await basicStore.down(target: "native", minutes: 5)
        let basicURL = await basicStore.resolvedStoreURL
        let basicMerged = await basicStore.mergedSnapshot()
        XCTAssertEqual(
            basicMerged.keys.sorted(), ["native", "t3:codex/gpt-5.6-sol"]
        )
        XCTAssertEqual(basicMerged["native"], clock.addingTimeInterval(300))
        try copyVerbatim(basicURL, to: out, named: "in-app-basic.json")
        try writeCanonical(basicMerged, to: out, named: "in-app-basic.merged.json")
        try writeOps(
            CooldownOps(
                clock: clock,
                storeFile: "broker-cooldowns.json",
                cliFile: nil,
                handWritten: false,
                operations: [
                    .init(op: "down", target: "t3:codex/gpt-5.6-sol", minutes: 60),
                    .init(op: "down", target: "native", minutes: 5),
                ],
                notes: [
                    "Written by BrokerCooldownStore with an injected clock; no CLI file present.",
                    "The in-app file is encoded WITHOUT .sortedKeys, so top-level key order is "
                        + "one valid order, not a contract. Compare parsed content, never bytes.",
                ]
            ),
            to: out, named: "in-app-basic.ops.json"
        )

        // --- cli-file + merged-with-cli: both files present.
        let mergeDirectory = try makeTempDirectory()
        let cliURL = mergeDirectory.appendingPathComponent("cli-cooldowns.json")
        let mergeStore = BrokerCooldownStore(
            storeDirectory: mergeDirectory, cliCooldownsURL: cliURL, now: { clock }
        )
        try await mergeStore.down(target: "t3:codex/gpt-5.6-sol", minutes: 60)
        try await mergeStore.down(target: "native", minutes: 5)
        // Hand-written in the reference CLI's shape: JS `Date.toISOString()`
        // always emits fractional seconds, but a hand-edited file may not.
        let cliFile = """
        {
          "t3:codex/gpt-5.6-sol": "2023-11-14T23:43:20.250Z",
          "codex/gpt-5.6-terra": "2023-11-14T23:13:20Z",
          "native/claude-opus-5": "2023-11-14T21:13:20Z"
        }
        """
        try Data(cliFile.utf8).write(to: cliURL, options: .atomic)
        let merged = await mergeStore.mergedSnapshot()
        // Later `availableAt` wins on a shared key; a past entry is dropped.
        XCTAssertEqual(
            merged.keys.sorted(),
            ["codex/gpt-5.6-terra", "native", "t3:codex/gpt-5.6-sol"]
        )
        XCTAssertEqual(
            merged["t3:codex/gpt-5.6-sol"],
            Date(timeIntervalSince1970: 1_700_005_400.25),
            "the CLI's later expiry must win over the in-app entry"
        )
        XCTAssertNil(merged["native/claude-opus-5"], "an already-past CLI entry is dropped")
        try copyVerbatim(cliURL, to: out, named: "cli-file.json")
        try copyVerbatim(
            await mergeStore.resolvedStoreURL, to: out, named: "in-app-with-cli.json"
        )
        try writeCanonical(merged, to: out, named: "merged-with-cli.json")
        try writeOps(
            CooldownOps(
                clock: clock,
                storeFile: "broker-cooldowns.json",
                cliFile: "cli-cooldowns.json",
                handWritten: false,
                operations: [
                    .init(op: "down", target: "t3:codex/gpt-5.6-sol", minutes: 60),
                    .init(op: "down", target: "native", minutes: 5),
                    .init(op: "write-cli-file", target: "cli-file.json", minutes: nil),
                    .init(op: "mergedSnapshot", target: nil, minutes: nil),
                ],
                notes: [
                    "cli-file.json is hand-written in the reference CLI's shape and carries a "
                        + "fractional-seconds timestamp, a whole-seconds timestamp, an already-past "
                        + "entry, and a key shared with the in-app file at a LATER expiry.",
                    "merged-with-cli.json is the mergedSnapshot() result: later expiry wins on a "
                        + "shared key, past entries are dropped, and the merged values re-encode "
                        + "with whole-second ISO-8601 (fractional seconds truncated).",
                ]
            ),
            to: out, named: "merged-with-cli.ops.json"
        )

        // --- reset() with a CLI file present writes the ms-map marker.
        let resetDirectory = try makeTempDirectory()
        let resetCLIURL = resetDirectory.appendingPathComponent("cli-cooldowns.json")
        try Data(cliFile.utf8).write(to: resetCLIURL, options: .atomic)
        let resetStore = BrokerCooldownStore(
            storeDirectory: resetDirectory, cliCooldownsURL: resetCLIURL, now: { clock }
        )
        try await resetStore.reset()
        let resetURL = await resetStore.resolvedStoreURL
        let resetText = try String(contentsOf: resetURL, encoding: .utf8)
        XCTAssertTrue(resetText.contains("__pinemeter_cli_reset__"))
        XCTAssertTrue(
            resetText.contains("1700005400250"),
            "a future CLI expiry is snapshotted in whole milliseconds, half away from zero"
        )
        XCTAssertFalse(
            resetText.contains("1699996400000"),
            "an already-past CLI expiry is not suppressed"
        )
        try copyVerbatim(resetURL, to: out, named: "in-app-reset-marker-ms.json")
        try writeCanonical(
            await resetStore.mergedSnapshot(),
            to: out, named: "in-app-reset-marker-ms.merged.json"
        )
        try writeOps(
            CooldownOps(
                clock: clock,
                storeFile: "broker-cooldowns.json",
                cliFile: "cli-file.json",
                handWritten: false,
                operations: [.init(op: "reset", target: nil, minutes: nil)],
                notes: [
                    "reset() snapshots every FUTURE CLI expiry into the reset marker as whole "
                        + "milliseconds (Int64 of timeIntervalSince1970 * 1000, rounded half away "
                        + "from zero), so a later CLI extension within the same second is still "
                        + "distinguishable from the entry that was reset.",
                    "The merged view after a reset suppresses exactly the snapshotted entries.",
                ]
            ),
            to: out, named: "in-app-reset-marker-ms.ops.json"
        )

        // --- hand-written in-app files: legacy marker, oversize, bad values.
        try await exportHandWrittenCooldownFile(
            name: "in-app-legacy-marker-date",
            contents: """
            {
              "native/claude-opus-5": "2023-11-14T23:13:20Z",
              "__pinemeter_cli_reset__": "2023-11-15T00:13:20Z"
            }
            """,
            cliFile: cliFile,
            out: out,
            notes: [
                "The legacy reset-marker shape: a bare ISO-8601 date rather than the ms map. "
                    + "While it is live, every CLI entry at or before it is suppressed.",
            ]
        ) { merged in
            XCTAssertNil(
                merged["codex/gpt-5.6-terra"],
                "a CLI entry at or before a live legacy marker is suppressed"
            )
            XCTAssertEqual(merged["native/claude-opus-5"], Date(timeIntervalSince1970: 1_700_003_600))
        }

        let oversizeEntries = (0..<65)
            .map { String(format: "  \"oversize/%02d\": \"2023-11-14T23:13:20Z\"", $0) }
            .joined(separator: ",\n")
        try await exportHandWrittenCooldownFile(
            name: "in-app-oversize",
            contents: "{\n\(oversizeEntries)\n}",
            cliFile: nil,
            out: out,
            notes: [
                "65 entries and no reset marker: one past the 64-entry cap, so the WHOLE file "
                    + "decodes as empty. The cap is all-or-nothing here, unlike the per-entry "
                    + "drops in in-app-bad-values.",
            ]
        ) { merged in
            XCTAssertTrue(merged.isEmpty, "an oversize file decodes as empty, not truncated")
        }

        let overlongKey = String(repeating: "k", count: 257)
        try await exportHandWrittenCooldownFile(
            name: "in-app-bad-values",
            contents: """
            {
              "good/one": "2023-11-14T23:13:20Z",
              "bad/value": 123,
              "\(overlongKey)": "2023-11-14T23:13:20Z",
              "": "2023-11-14T23:13:20Z"
            }
            """,
            cliFile: nil,
            out: out,
            notes: [
                "A non-date value, a 257-scalar key (cap is 256) and an empty key are each "
                    + "dropped on their own; the valid entry survives. Losing the whole file "
                    + "here would silently re-enable an exhausted candidate.",
            ]
        ) { merged in
            XCTAssertEqual(merged.keys.sorted(), ["good/one"])
        }
    }

    private func exportHandWrittenCooldownFile(
        name: String,
        contents: String,
        cliFile: String?,
        out: URL?,
        notes: [String],
        verify: ([String: Date]) -> Void
    ) async throws {
        let clock = Self.clock
        let directory = try makeTempDirectory()
        let cliURL = directory.appendingPathComponent("cli-cooldowns.json")
        if let cliFile { try Data(cliFile.utf8).write(to: cliURL, options: .atomic) }
        try Data(contents.utf8).write(
            to: directory.appendingPathComponent("broker-cooldowns.json"), options: .atomic
        )
        let store = BrokerCooldownStore(
            storeDirectory: directory, cliCooldownsURL: cliURL, now: { clock }
        )
        let merged = await store.mergedSnapshot()
        verify(merged)
        try copyVerbatim(
            await store.resolvedStoreURL, to: out, named: "\(name).json"
        )
        try writeCanonical(merged, to: out, named: "\(name).merged.json")
        try writeOps(
            CooldownOps(
                clock: clock,
                storeFile: "broker-cooldowns.json",
                cliFile: cliFile == nil ? nil : "cli-file.json",
                handWritten: true,
                operations: [.init(op: "mergedSnapshot", target: nil, minutes: nil)],
                notes: notes
            ),
            to: out, named: "\(name).ops.json"
        )
    }

    // MARK: - Audit

    func test_exportsAuditStoreFixtures() async throws {
        Self.wipeOnce("audit", &Self.auditWiped)
        let out = output("audit")
        let clock = Self.clock

        let directory = try makeTempDirectory()
        let store = BrokerAuditStore(storeDirectory: directory)
        let storeURL = await store.resolvedStoreURL

        var appended: [AuditOps.Appended] = []
        for (index, decision) in try Self.auditDecisions().enumerated() {
            let timestamp = clock.addingTimeInterval(Double(index))
            try await store.append(decision: decision, timestamp: timestamp)
            appended.append(
                .init(
                    decisionID: decision.decisionID!, timestamp: timestamp, decision: decision
                )
            )
        }

        let reports: [BrokerLifecycleReport] = [
            BrokerLifecycleReport(
                decisionID: "decision-001", status: .started,
                threadID: "thread-alpha", sessionID: "session-alpha"
            ),
            BrokerLifecycleReport(
                decisionID: "decision-001", status: .completed,
                threadID: "thread-alpha", sessionID: "session-alpha",
                durationMS: 42_000,
                actualInputTokens: 12_000,
                actualCachedInputTokens: 8_000,
                actualCacheCreationInputTokens: 1_500,
                actualOutputTokens: 3_200,
                actualReasoningTokens: 1_100
            ),
            BrokerLifecycleReport(
                decisionID: "decision-002", status: .failed,
                durationMS: 900, failureReason: "provider returned 503 twice"
            ),
            // Duplicate terminal with the same status.
            BrokerLifecycleReport(
                decisionID: "decision-001", status: .completed, durationMS: 42_000
            ),
            BrokerLifecycleReport(decisionID: "decision-unknown", status: .started),
        ]
        var reported: [AuditOps.Reported] = []
        for report in reports {
            let result = try await store.reportLifecycle(report)
            reported.append(.init(report: report, result: result.rawValue))
        }
        XCTAssertEqual(reported.map(\.result), [
            "recorded", "recorded", "recorded", "duplicate", "unknown_decision",
        ])

        // The persisted failure reason is always the literal sentinel, and
        // thread/session ids are sha256-normalised before they hit disk.
        let persisted = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("\"failure_reason\":\"reported_failure\""))
        XCTAssertFalse(persisted.contains("503"), "raw failure text must never be persisted")
        XCTAssertFalse(persisted.contains("thread-alpha"), "identifiers are hashed before write")
        XCTAssertTrue(persisted.contains("\"version\":4"))

        try copyVerbatim(storeURL, to: out, named: "records-basic.json")
        try writeOps(
            AuditOps(
                clock: clock,
                storeFile: "broker-audit.json",
                appended: appended,
                reported: reported,
                notes: [
                    "Decisions come from BrokerEngine.decide on BrokerFixture policies and are "
                        + "given deterministic ids through BrokerDecision.attachingDecisionID, the "
                        + "same seam BrokerService uses for its generated ids.",
                    "broker-audit.json is encoded WITH .sortedKeys, so unlike the other two stores "
                        + "it IS byte-comparable: Go must reproduce these exact bytes.",
                    "thread_id/session_id are persisted as sha256:<64 hex>; failure_reason is "
                        + "persisted as the literal 'reported_failure', never the reported text.",
                ]
            ),
            to: out, named: "records-basic.ops.json"
        )

        try await exportLegacyAuditFixtures(out: out)
        try await exportRejectedAuditFixture(out: out)
    }

    /// v1/v2 are produced exactly the way
    /// `BrokerAuditStoreTests.testLegacySchemasMigrateFailureReasonsWithoutDecisionLoss`
    /// produces them: write a real v4 file, then rewrite the version and put a
    /// raw failure reason (and, for v1, raw identifiers) back into it.
    ///
    /// v3 is produced the way
    /// `BrokerAuditStoreTests.testSchemaThreeLoadsWithoutRewritingOrLosingRecords`
    /// produces it — a `"version":4` -> `"version":3` substitution on a
    /// store-written file. There is no hand-written v3 envelope literal
    /// anywhere in the Swift tests; this fixture is that same substitution,
    /// not an invented shape.
    private func exportLegacyAuditFixtures(out: URL?) async throws {
        let clock = Self.clock

        for legacyVersion in [1, 2, 3] {
            let directory = try makeTempDirectory()
            let fileURL = directory.appendingPathComponent("broker-audit.json")
            let store = BrokerAuditStore(storeDirectory: directory)
            try await store.append(
                decision: Self.auditDecision(
                    id: "decision-failed", role: "planning", model: "claude-fable-5"
                ),
                timestamp: clock
            )
            _ = try await store.reportLifecycle(
                BrokerLifecycleReport(
                    decisionID: "decision-failed", status: .failed,
                    threadID: "thread 1", sessionID: "session-research",
                    failureReason: "temporary"
                )
            )
            try await store.append(
                decision: Self.auditDecision(
                    id: "decision-unrelated", role: "planning", model: "claude-fable-5"
                ),
                timestamp: clock.addingTimeInterval(1)
            )

            let legacyData: Data
            if legacyVersion == 3 {
                let current = try String(contentsOf: fileURL, encoding: .utf8)
                let downgraded = current.replacingOccurrences(
                    of: #""version":4"#, with: #""version":3"#
                )
                XCTAssertNotEqual(downgraded, current)
                legacyData = Data(downgraded.utf8)
            } else {
                var envelope = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: try Data(contentsOf: fileURL))
                        as? [String: Any]
                )
                envelope["version"] = legacyVersion
                var records = try XCTUnwrap(envelope["records"] as? [[String: Any]])
                let index = try XCTUnwrap(
                    records.firstIndex { $0["decision_id"] as? String == "decision-failed" }
                )
                var terminal = try XCTUnwrap(records[index]["terminal"] as? [String: Any])
                terminal["failure_reason"] = "legacy-v\(legacyVersion)-opaque-Q7vK4pL9xR2m"
                if legacyVersion == 1 {
                    terminal["thread_id"] = "thread 1"
                    terminal["session_id"] = "session-research"
                }
                records[index]["terminal"] = terminal
                envelope["records"] = records
                legacyData = try JSONSerialization.data(
                    withJSONObject: envelope, options: [.sortedKeys]
                )
            }
            try legacyData.write(to: fileURL, options: .atomic)

            // Loading is what migrates (v1/v2) or does not (v3).
            let reloaded = BrokerAuditStore(storeDirectory: directory)
            let records = await reloaded.recordsSnapshot
            XCTAssertEqual(records.count, 2, "schema \(legacyVersion) must lose no decision")
            let after = try Data(contentsOf: fileURL)

            if legacyVersion == 3 {
                XCTAssertEqual(
                    after, legacyData, "v3 loads without a rewrite; the file must be untouched"
                )
            } else {
                XCTAssertNotEqual(after, legacyData, "v1/v2 must be rewritten as v4")
                XCTAssertTrue(
                    String(decoding: after, as: UTF8.self).contains(#""version":4"#)
                )
                XCTAssertNil(
                    after.range(of: Data("Q7vK4pL9xR2m".utf8)),
                    "the raw legacy failure reason must not survive the migration"
                )
            }

            let name = "legacy-v\(legacyVersion)"
            if let out {
                try GoldenFixture.write(legacyData, to: out, named: "\(name).json")
                try GoldenFixture.write(after, to: out, named: "\(name).migrated.json")
                try writeOps(
                    SimpleOps(
                        clock: clock,
                        storeFile: "broker-audit.json",
                        handWritten: false,
                        notes: legacyVersion == 3
                            ? [
                                "Derived by substituting \"version\":4 -> \"version\":3 in a "
                                    + "store-written v4 file, the same derivation "
                                    + "BrokerAuditStoreTests uses. No v3 envelope literal exists "
                                    + "in the Swift tests to copy.",
                                "v3 is accepted AS IS: the store loads it and does not rewrite, "
                                    + "so legacy-v3.migrated.json is byte-identical to "
                                    + "legacy-v3.json.",
                            ]
                            : [
                                "Derived the way BrokerAuditStoreTests derives it: a "
                                    + "store-written v4 file with the version rewritten to "
                                    + "\(legacyVersion) and a raw failure reason"
                                    + (legacyVersion == 1
                                        ? " plus un-hashed thread/session identifiers"
                                        : "")
                                    + " put back into the terminal report.",
                                "Loading migrates in place: failure reasons collapse to the "
                                    + "'reported_failure' literal, identifiers are hashed, and "
                                    + "the file is rewritten as version 4. Neither decision is "
                                    + "lost.",
                            ]
                    ),
                    to: out, named: "\(name).ops.json"
                )
            }
        }
    }

    private func exportRejectedAuditFixture(out: URL?) async throws {
        let directory = try makeTempDirectory()
        let fileURL = directory.appendingPathComponent("broker-audit.json")
        let backupURL = fileURL.appendingPathExtension("bak")
        let malformed = Data(#"{"version":99,"records":[]}"#.utf8)
        try malformed.write(to: fileURL, options: .atomic)

        let store = BrokerAuditStore(storeDirectory: directory)
        let snapshot = await store.recordsSnapshot
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try Data(contentsOf: backupURL), malformed)

        if let out {
            try GoldenFixture.write(malformed, to: out, named: "rejected-envelope.json")
            try writeOps(
                SimpleOps(
                    clock: Self.clock,
                    storeFile: "broker-audit.json",
                    handWritten: true,
                    notes: [
                        "An unknown schema version. The store starts EMPTY and copies the "
                            + "unreadable file to broker-audit.json.bak exactly once, so the "
                            + "original is recoverable and a second launch does not overwrite it.",
                        "Accepted versions are 1, 2, 3 and 4; everything else lands here.",
                    ]
                ),
                to: out, named: "rejected-envelope.ops.json"
            )
        }
    }

    private static func auditDecision(
        id: String, role: String, model: String
    ) -> BrokerDecision {
        BrokerDecision(
            role: role,
            caller: "claude-code",
            model: "native/\(model)",
            route: .native,
            agentModel: "fable",
            invocation: .agent(model: "fable"),
            reason: "native quota available",
            source: .policy,
            oracle: .absent,
            degraded: false,
            candidatesTried: [
                BrokerCandidateTried(
                    candidate: "native/\(model)", available: true, why: "native quota available"
                )
            ],
            decisionID: id
        )
    }

    /// Three real engine decisions, one per executable route, with the ids
    /// attached the way `BrokerService` attaches its generated ones.
    private static func auditDecisions() throws -> [BrokerDecision] {
        let oracle = BrokerFixture.oracle()
        let native = try BrokerEngine.decide(
            role: "planning",
            caller: "claude-code",
            policy: BrokerFixture.policy(roles: ["planning": ["native/claude-fable-5"]]),
            oracle: oracle,
            cooldowns: [:],
            now: clock,
            t3: [:]
        ).attachingDecisionID("decision-001")

        let t3 = try BrokerEngine.decide(
            role: "execution",
            caller: "claude-code",
            policy: BrokerFixture.policy(roles: ["execution": ["t3/gpt-5.6-sol"]]),
            oracle: oracle,
            cooldowns: [:],
            now: clock,
            t3: ["claudeAgent": T3Liveness(reachable: true, why: "scan ok")]
        ).attachingDecisionID("decision-002")

        let codex = try BrokerEngine.decide(
            role: "review",
            caller: "codex",
            policy: BrokerFixture.policy(roles: ["review": ["codex/gpt-5.6-sol"]]),
            oracle: oracle,
            cooldowns: [:],
            now: clock,
            t3: [:]
        ).attachingDecisionID("decision-003")

        return [native, t3, codex]
    }

    // MARK: - Telemetry

    func test_exportsTelemetryStoreFixtures() async throws {
        Self.wipeOnce("telemetry", &Self.telemetryWiped)
        let out = output("telemetry")
        let clock = Self.clock

        let directory = try makeTempDirectory()
        let store = UsageTelemetryStore(storeDirectory: directory)
        let storeURL = await store.resolvedStoreURL

        let availabilities: [T3UsageAvailability] = [
            .absent,
            .unreachable,
            .usageUnavailable(reason: .scanFailed),
            .incompatible(contractVersion: 3),
            .malformed,
            .fresh(readAt: clock.addingTimeInterval(-30)),
        ]
        var appended: [UsageTelemetryRecord] = []
        for (index, availability) in availabilities.enumerated() {
            let record = UsageTelemetryRecord(
                attemptedAt: clock.addingTimeInterval(Double(index)),
                t3Availability: availability,
                claudeAccounts: Self.telemetryClaudeAccounts(clock: clock),
                chatGPT: Self.telemetryChatGPT(index: index, clock: clock),
                // Only the `fresh` record carries a snapshot — that is the
                // only case the Mac ever has one for.
                t3Snapshot: index == availabilities.count - 1
                    ? Self.telemetrySnapshot(clock: clock) : nil,
                appVersion: "1.2.0",
                appLaunchedAt: clock.addingTimeInterval(-3_600)
            )
            try await store.append(record)
            appended.append(record)
        }
        try await store.flush()

        let data = try Data(contentsOf: storeURL)
        try assertAvailabilityEncoding(in: data)

        try copyVerbatim(storeURL, to: out, named: "records-all-availability.json")
        try writeOps(
            TelemetryOps(
                clock: clock,
                storeFile: "usage-telemetry.json",
                appended: appended,
                notes: [
                    "Appended in this order at attemptedAt = clock + index seconds, then flush().",
                    "T3UsageAvailability uses Swift's SYNTHESIZED enum-with-payload Codable: each "
                        + "value encodes as a single-key object whose key is the case name and "
                        + "whose value is an object of the associated values by label. Payload-free "
                        + "cases encode as an EMPTY object, not as a bare string: "
                        + "{\"absent\":{}}, {\"unreachable\":{}}, {\"malformed\":{}}, "
                        + "{\"usageUnavailable\":{\"reason\":\"scan_failed\"}}, "
                        + "{\"incompatible\":{\"contractVersion\":3}}, "
                        + "{\"fresh\":{\"readAt\":\"2023-11-14T22:12:50Z\"}}. "
                        + "This settles research assumption A1.",
                    "usage-telemetry.json is encoded WITHOUT .sortedKeys; compare parsed content, "
                        + "never bytes.",
                ]
            ),
            to: out, named: "records-all-availability.ops.json"
        )
    }

    /// Reads the file back as untyped JSON and pins the observed shape, so
    /// assumption A1 is an assertion rather than a claim in a document.
    private func assertAvailabilityEncoding(in data: Data) throws {
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(envelope["version"] as? Int, 1)
        let stored = try XCTUnwrap(envelope["records"] as? [[String: Any]])
        XCTAssertEqual(stored.count, 6)

        let payloads: [[String: Any]] = try stored.map { entry in
            let record = try XCTUnwrap(entry["record"] as? [String: Any])
            return try XCTUnwrap(record["t3Availability"] as? [String: Any])
        }
        XCTAssertEqual(
            payloads.map { $0.keys.sorted().joined(separator: ",") },
            ["absent", "unreachable", "usageUnavailable", "incompatible", "malformed", "fresh"],
            "each availability encodes as exactly one case-named key"
        )
        XCTAssertEqual((payloads[0]["absent"] as? [String: Any])?.count, 0)
        XCTAssertEqual((payloads[1]["unreachable"] as? [String: Any])?.count, 0)
        XCTAssertEqual((payloads[4]["malformed"] as? [String: Any])?.count, 0)
        XCTAssertEqual(
            (payloads[2]["usageUnavailable"] as? [String: Any])?["reason"] as? String,
            "scan_failed"
        )
        XCTAssertEqual(
            (payloads[3]["incompatible"] as? [String: Any])?["contractVersion"] as? Int, 3
        )
        XCTAssertEqual(
            (payloads[5]["fresh"] as? [String: Any])?["readAt"] as? String,
            "2023-11-14T22:12:50Z"
        )
    }

    private static func telemetryClaudeAccounts(
        clock: Date
    ) -> [UsageTelemetryQuotaSnapshot.ClaudeAccount] {
        [
            .init(
                id: "acct-primary",
                isPrimary: true,
                freshness: .fresh,
                lastUpdated: clock.addingTimeInterval(-60),
                session: .init(utilization: 12.5, resetAt: clock.addingTimeInterval(3_600)),
                weekly: .init(utilization: 48, resetAt: clock.addingTimeInterval(86_400)),
                sonnet: .init(utilization: 3.25, resetAt: nil),
                fable: .init(utilization: 91.75, resetAt: clock.addingTimeInterval(172_800))
            ),
            .init(
                id: "acct-secondary",
                isPrimary: false,
                freshness: .stale,
                lastUpdated: nil,
                session: .init(utilization: nil, resetAt: nil),
                weekly: .init(utilization: nil, resetAt: nil),
                sonnet: .init(utilization: nil, resetAt: nil),
                fable: .init(utilization: nil, resetAt: nil)
            ),
        ]
    }

    private static func telemetryChatGPT(
        index: Int, clock: Date
    ) -> UsageTelemetryQuotaSnapshot.ChatGPT {
        // One errored poll among the six, so the failure and status-code
        // fields appear on disk at least once.
        if index == 1 {
            return .init(
                freshness: .error,
                lastUpdated: clock.addingTimeInterval(-900),
                rows: [],
                failure: .httpError,
                httpStatusCode: 503
            )
        }
        return .init(
            freshness: .fresh,
            lastUpdated: clock.addingTimeInterval(-45),
            rows: [
                .init(
                    label: "Codex 5h",
                    role: .chatGPT5h,
                    utilization: 21.5,
                    resetAt: clock.addingTimeInterval(1_800)
                ),
                .init(label: "Codex weekly", role: .chatGPTWeekly, utilization: 64, resetAt: nil),
                .init(label: "Unlabelled row", role: nil, utilization: 0, resetAt: nil),
            ]
        )
    }

    private static func telemetrySnapshot(clock: Date) -> T3UsageSnapshot {
        T3UsageSnapshot(
            readAt: clock.addingTimeInterval(-30),
            timeZone: "America/Vancouver",
            sinceDay: "2023-11-08",
            untilDay: "2023-11-14",
            buckets: [
                .init(
                    day: "2023-11-14",
                    provider: .claude,
                    model: "claude-fable-5",
                    totals: .init(
                        uncachedInputTokens: 1_200,
                        cachedInputTokens: 9_800,
                        cacheCreationTokens: 400,
                        outputTokens: 2_300,
                        reasoningTokens: 700
                    ),
                    costUsd: 0.42,
                    cacheSavingsUsd: 0.13,
                    costSource: .modelPriced,
                    records: 7,
                    unpricedRecords: 0,
                    sessions: 2
                ),
                .init(
                    day: "2023-11-13",
                    provider: .codex,
                    model: "gpt-5.6-sol",
                    totals: .init(
                        uncachedInputTokens: 800,
                        cachedInputTokens: 0,
                        cacheCreationTokens: 0,
                        outputTokens: 1_100,
                        reasoningTokens: 0
                    ),
                    costUsd: 0,
                    cacheSavingsUsd: 0,
                    costSource: .unpriced,
                    records: 3,
                    unpricedRecords: 3,
                    sessions: 1
                ),
            ],
            sources: [
                .init(
                    provider: .claude,
                    status: .ok,
                    scannedFiles: 12,
                    skippedFiles: 1,
                    malformedRecords: 0,
                    distinctSessions: 2
                ),
                .init(
                    provider: .codex,
                    status: .partial,
                    scannedFiles: 4,
                    skippedFiles: 0,
                    malformedRecords: 2,
                    distinctSessions: 1
                ),
            ],
            pricing: .init(
                status: .cached,
                source: "bundled",
                fetchedAt: clock.addingTimeInterval(-7_200),
                knownModels: 37
            ),
            scanDurationMs: 118
        )
    }
}
