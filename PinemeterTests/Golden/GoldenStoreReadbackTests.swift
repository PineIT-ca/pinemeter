//
//  GoldenStoreReadbackTests.swift
//  PinemeterTests
//
//  The write direction of the store contract (ENGINE-04, decision D-07).
//
//  `GoldenStoreFixtureTests` exports what the Mac's stores wrote so the Go
//  port can prove it READS the Mac's formats. This class is the mirror: it
//  loads the files the Go stores wrote (`golden/stores/go-written/`, produced
//  by `scripts/golden-store-readback.sh`) through the real
//  `BrokerCooldownStore`, `BrokerAuditStore` and `UsageTelemetryStore`, and
//  asserts the contents `expected.json` says must come back.
//
//  This is the only assertion in the corpus that a Go-internal round-trip
//  cannot make. Every other parity test compares Go output against bytes
//  Swift produced earlier; none of them has the Swift decoder open a
//  Go-written file. Phases 13/14 put a Go daemon on the other end of these
//  three files, so "the Mac can read them" has to be a test, not a claim.
//
//  Read-only: the corpus is never opened in place. Each case stages its file
//  into a fresh temporary directory, because two of the three stores write
//  back on load and a mutated fixture would destroy the contract it checks.
//

import Foundation
import XCTest
@testable import Pinemeter

final class GoldenStoreReadbackTests: XCTestCase {

    // MARK: - The expectation document

    /// Mirrors `golden/stores/go-written/expected.json`, written by
    /// `TestExportGoWrittenStoreFiles`. Decoded rather than transcribed so a
    /// change in Go's output surfaces here as a failure in the same commit,
    /// not as a Swift test that silently kept asserting the old shape.
    private struct Expectation: Decodable {
        struct Cooldowns: Decodable {
            let storeFile: String
            let cliFixture: String
            let cliFileName: String
            let mergedSnapshot: [String: String]
            let suppressedCLIKeys: [String]
        }

        struct AuditRecord: Decodable, Equatable {
            let decisionID: String
            let role: String
            let candidate: String
            let timestamp: String
            let hasStarted: Bool
            let hasTerminal: Bool
            let terminalStatus: String
        }

        struct AuditReport: Decodable {
            let decisionID: String
            let status: String
            let durationMS: Int
            let expectedResult: String
            let writes: Bool
        }

        struct Audit: Decodable {
            let storeFile: String
            let recordCount: Int
            let records: [AuditRecord]
            let rewrittenOnLoad: Bool
            let backupCreatedOnLoad: Bool
            let reportAfterLoad: AuditReport
        }

        struct Telemetry: Decodable {
            let storeFile: String
            let recordCount: Int
            let firstAttemptedAt: String
            let lastAttemptedAt: String
            let availabilityCases: [String]
        }

        let clock: String
        let cooldowns: Cooldowns
        let audit: Audit
        let telemetry: Telemetry
    }

    // MARK: - Fixture plumbing

    private static var goWrittenDirectory: URL {
        GoldenFixture.repoRoot
            .appendingPathComponent("golden", isDirectory: true)
            .appendingPathComponent("stores", isDirectory: true)
            .appendingPathComponent("go-written", isDirectory: true)
    }

    /// Whole-second UTC, the one date form both engines write.
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private func loadExpectation() throws -> Expectation {
        let url = Self.goWrittenDirectory.appendingPathComponent("expected.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Expectation.self, from: data)
    }

    private func clock(_ expectation: Expectation) throws -> Date {
        try XCTUnwrap(
            Self.iso.date(from: expectation.clock),
            "expected.json carries an unparseable clock: \(expectation.clock)"
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoldenStoreReadback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Copies a Go-written file into `directory`. Byte copy, no re-encode: the
    /// point of the test is what the Go store actually put on disk.
    @discardableResult
    private func stageGoWritten(
        _ name: String, into directory: URL, named destination: String? = nil
    ) throws -> URL {
        let source = Self.goWrittenDirectory.appendingPathComponent(name)
        let data = try Data(contentsOf: source)
        XCTAssertFalse(
            data.isEmpty, "\(name) is empty; regenerate with scripts/golden-store-readback.sh"
        )
        let target = directory.appendingPathComponent(destination ?? name)
        try data.write(to: target, options: .atomic)
        return target
    }

    /// A path under the repository root, used for the Swift-owned CLI fixture
    /// the cooldown merge needs on the other side.
    private func stageRepoFile(
        _ relativePath: String, into directory: URL, named destination: String
    ) throws -> URL {
        let source = GoldenFixture.repoRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: source)
        let target = directory.appendingPathComponent(destination)
        try data.write(to: target, options: .atomic)
        return target
    }

    /// The store directory must hold exactly the files the case put there:
    /// no `.bak`, no leftover atomic-write temp file, no second store file.
    private func assertDirectoryContents(
        _ directory: URL, equals expected: [String], file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let contents = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .sorted()
        XCTAssertEqual(contents, expected.sorted(), file: file, line: line)
    }

    private func isoStrings(_ dates: [String: Date]) -> [String: String] {
        dates.mapValues { Self.iso.string(from: $0) }
    }

    // MARK: - Cooldowns

    /// The Go store wrote a file carrying both shapes at once: the millisecond
    /// CLI reset marker and two live cooldown entries. The merged view the Mac
    /// computes from it, against the same CLI file, must be exactly the one Go
    /// computed — which is only true if Swift parsed the marker Go wrote.
    func test_macCooldownStoreReadsAGoWrittenFile() async throws {
        let expectation = try loadExpectation()
        let clock = try clock(expectation)
        let directory = try makeTempDirectory()

        let storeURL = try stageGoWritten(
            expectation.cooldowns.storeFile, into: directory, named: "broker-cooldowns.json"
        )
        let cliURL = try stageRepoFile(
            expectation.cooldowns.cliFixture,
            into: directory,
            named: expectation.cooldowns.cliFileName
        )

        let store = BrokerCooldownStore(
            storeDirectory: directory, cliCooldownsURL: cliURL, now: { clock }
        )
        let resolvedURL = await store.resolvedStoreURL
        XCTAssertEqual(resolvedURL, storeURL)

        let merged = await store.mergedSnapshot()
        XCTAssertFalse(merged.isEmpty, "a Go-written cooldown file decoded to nothing")
        XCTAssertEqual(
            isoStrings(merged), expectation.cooldowns.mergedSnapshot,
            "the Mac's merged view of a Go-written file differs from Go's"
        )

        // The suppression half, stated independently of the map comparison:
        // every key the marker names is still present in the CLI file, and
        // none of them may reach the merged view at its CLI expiry. Without
        // this, a Swift decoder that silently ignored the marker could still
        // match on `native` alone.
        let cliEntries = try JSONDecoder().decode(
            [String: String].self, from: try Data(contentsOf: cliURL)
        )
        XCTAssertFalse(expectation.cooldowns.suppressedCLIKeys.isEmpty)
        for key in expectation.cooldowns.suppressedCLIKeys {
            let rawCLIDate = try XCTUnwrap(
                cliEntries[key], "\(key) is named as suppressed but is not in the CLI file"
            )
            let cliDate = try XCTUnwrap(Self.iso.date(from: rawCLIDate) ?? fractionalDate(rawCLIDate))
            XCTAssertNotEqual(
                merged[key], cliDate,
                "\(key) reached the merged view at its CLI expiry: the reset marker Go wrote was ignored"
            )
        }

        try assertDirectoryContents(
            directory, equals: ["broker-cooldowns.json", expectation.cooldowns.cliFileName]
        )
    }

    /// The reference CLI writes `Date.toISOString()`, which carries
    /// milliseconds. `.withInternetDateTime` alone does not parse those.
    private func fractionalDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: raw)
    }

    // MARK: - Audit

    /// `broker-audit.json` is the one byte-comparable store file, so this case
    /// asserts more than decode: loading a Go-written v4 envelope must leave
    /// the bytes untouched and must not produce a `.bak`. A rewrite would mean
    /// the Mac judged Go's envelope in need of migration; a `.bak` would mean
    /// it rejected it outright and started empty.
    func test_macAuditStoreReadsAGoWrittenFileWithoutRewritingIt() async throws {
        let expectation = try loadExpectation()
        let directory = try makeTempDirectory()
        let storeURL = try stageGoWritten(
            expectation.audit.storeFile, into: directory, named: "broker-audit.json"
        )
        let originalBytes = try Data(contentsOf: storeURL)

        let store = BrokerAuditStore(storeDirectory: directory)
        let resolvedURL = await store.resolvedStoreURL
        XCTAssertEqual(resolvedURL, storeURL)

        if !expectation.audit.rewrittenOnLoad {
            XCTAssertEqual(
                try Data(contentsOf: storeURL), originalBytes,
                "loading a Go-written v4 envelope rewrote it"
            )
        }
        if !expectation.audit.backupCreatedOnLoad {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("broker-audit.json.bak").path
                ),
                "the store backed the file up, which means it refused it and started empty"
            )
        }

        let records = await store.recordsSnapshot
        XCTAssertEqual(records.count, expectation.audit.recordCount)
        let observed = records.map { record in
            Expectation.AuditRecord(
                decisionID: record.decisionID,
                role: record.role,
                candidate: record.candidate,
                timestamp: Self.iso.string(from: record.timestamp),
                hasStarted: record.started != nil,
                hasTerminal: record.terminal != nil,
                terminalStatus: record.terminal?.status.rawValue ?? ""
            )
        }
        XCTAssertEqual(observed, expectation.audit.records)

        // A further report on a loaded decision: the lifecycle state Go wrote
        // has to be understood, not merely decoded. A duplicate is the useful
        // probe because it must NOT write, so the bytes can be re-asserted.
        let report = expectation.audit.reportAfterLoad
        let status = try XCTUnwrap(
            BrokerLifecycleStatus(rawValue: report.status),
            "expected.json names an unknown lifecycle status: \(report.status)"
        )
        let result = try await store.reportLifecycle(
            BrokerLifecycleReport(
                decisionID: report.decisionID, status: status, durationMS: report.durationMS
            )
        )
        XCTAssertEqual(result.rawValue, report.expectedResult)
        if !report.writes {
            XCTAssertEqual(
                try Data(contentsOf: storeURL), originalBytes,
                "a \(report.expectedResult) report wrote the file"
            )
        }

        try assertDirectoryContents(directory, equals: ["broker-audit.json"])
    }

    // MARK: - Telemetry

    /// Every `T3UsageAvailability` case must survive the trip. The Swift
    /// decoder throws on an unknown case and a throw starts the whole history
    /// empty, so a single unrecognised Go-written payload shows up here as
    /// zero records rather than as a history with a hole in it.
    func test_macTelemetryStoreReadsAGoWrittenFile() async throws {
        let expectation = try loadExpectation()
        let directory = try makeTempDirectory()
        let storeURL = try stageGoWritten(
            expectation.telemetry.storeFile, into: directory, named: "usage-telemetry.json"
        )

        let store = UsageTelemetryStore(storeDirectory: directory)
        let resolvedURL = await store.resolvedStoreURL
        XCTAssertEqual(resolvedURL, storeURL)

        let records = await store.records()
        XCTAssertEqual(
            records.count, expectation.telemetry.recordCount,
            "a count of 0 means the file was refused whole, not that one record was dropped"
        )
        let first = try XCTUnwrap(records.first)
        let last = try XCTUnwrap(records.last)
        XCTAssertEqual(
            Self.iso.string(from: first.attemptedAt), expectation.telemetry.firstAttemptedAt
        )
        XCTAssertEqual(
            Self.iso.string(from: last.attemptedAt), expectation.telemetry.lastAttemptedAt
        )
        XCTAssertEqual(
            records.map { Self.caseName(of: $0.t3Availability) },
            expectation.telemetry.availabilityCases
        )

        // The payloads, not just the case names: an availability that decoded
        // to the right case with a lost associated value would otherwise pass.
        for record in records {
            switch record.t3Availability {
            case .usageUnavailable(let reason):
                XCTAssertEqual(reason, .scanFailed)
            case .incompatible(let contractVersion):
                XCTAssertEqual(contractVersion, 3)
            case .fresh(let readAt):
                XCTAssertEqual(readAt, first.attemptedAt.addingTimeInterval(-30))
            case .absent, .unreachable, .malformed:
                break
            }
        }

        try assertDirectoryContents(directory, equals: ["usage-telemetry.json"])
    }

    private static func caseName(of availability: T3UsageAvailability) -> String {
        switch availability {
        case .absent: return "absent"
        case .unreachable: return "unreachable"
        case .usageUnavailable: return "usageUnavailable"
        case .incompatible: return "incompatible"
        case .malformed: return "malformed"
        case .fresh: return "fresh"
        }
    }

    // MARK: - Corpus integrity

    /// The four files must be present and non-empty. Without this, deleting
    /// `golden/stores/go-written/` would turn the three cases above into
    /// errors that are easy to misread as an environment problem rather than
    /// as a missing corpus.
    func test_goWrittenCorpusIsPresent() throws {
        for name in [
            "broker-cooldowns.json", "broker-audit.json", "usage-telemetry.json", "expected.json",
        ] {
            let url = Self.goWrittenDirectory.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = try XCTUnwrap(attributes[.size] as? Int)
            XCTAssertGreaterThan(size, 0, "\(name) is empty")
        }
    }
}
