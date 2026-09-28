//
//  GoldenFixture.swift
//  PinemeterTests
//
//  Codable wrappers for the golden decision corpus (ENGINE-01).
//
//  The engine's world inputs (`OracleSnapshot`, `OracleSnapshot.AccountRow`,
//  `T3Liveness`) are deliberately not `Codable` in the app target — they are
//  in-memory value types, not a wire contract. The corpus needs them on disk,
//  so this file defines test-target-only mirrors with explicit `CodingKeys`
//  and explicit `encode(_:)` for every optional, so an absent value is written
//  as JSON `null` rather than an omitted key. The Go replay reads these same
//  files, and a key that is sometimes absent and sometimes null is a decoder
//  trap on both sides.
//
//  Nothing here may change an app-target type.
//

import Foundation
import XCTest
@testable import Pinemeter

// MARK: - Liveness

/// Mirror of `T3Liveness`. A missing map entry means "no signal at all",
/// which is a different input from `{reachable: false}` — the corpus records
/// both, so the map is never defaulted on either side.
struct GoldenLiveness: Codable, Equatable {
    let reachable: Bool
    let why: String

    init(reachable: Bool, why: String) {
        self.reachable = reachable
        self.why = why
    }

    init(_ liveness: T3Liveness) {
        self.init(reachable: liveness.reachable, why: liveness.why)
    }

    func liveness() -> T3Liveness {
        T3Liveness(reachable: reachable, why: why)
    }
}

// MARK: - Oracle

/// Mirror of `OracleSnapshot.AccountRow` — all 13 fields, `null` for nil.
struct GoldenAccountRow: Codable, Equatable {
    let id: String
    let label: String
    let isPrimary: Bool
    let lastUpdated: Date?
    let state: String
    let session: Double?
    let weekly: Double?
    let sonnet: Double?
    let fable: Double?
    let sessionResetAt: Date?
    let weeklyResetAt: Date?
    let sonnetResetAt: Date?
    let fableResetAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, label, isPrimary, lastUpdated, state
        case session, weekly, sonnet, fable
        case sessionResetAt, weeklyResetAt, sonnetResetAt, fableResetAt
    }

    init(_ row: OracleSnapshot.AccountRow) {
        id = row.id
        label = row.label
        isPrimary = row.isPrimary
        lastUpdated = row.lastUpdated
        state = row.state.rawValue
        session = row.session
        weekly = row.weekly
        sonnet = row.sonnet
        fable = row.fable
        sessionResetAt = row.sessionResetAt
        weeklyResetAt = row.weeklyResetAt
        sonnetResetAt = row.sonnetResetAt
        fableResetAt = row.fableResetAt
    }

    func row() throws -> OracleSnapshot.AccountRow {
        guard let quotaState = BrokerQuotaState(rawValue: state) else {
            throw GoldenFixture.Failure("unknown account state '\(state)'")
        }
        return OracleSnapshot.AccountRow(
            id: id,
            label: label,
            isPrimary: isPrimary,
            lastUpdated: lastUpdated,
            state: quotaState,
            session: session,
            weekly: weekly,
            sonnet: sonnet,
            fable: fable,
            sessionResetAt: sessionResetAt,
            weeklyResetAt: weeklyResetAt,
            sonnetResetAt: sonnetResetAt,
            fableResetAt: fableResetAt
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(isPrimary, forKey: .isPrimary)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(state, forKey: .state)
        try container.encode(session, forKey: .session)
        try container.encode(weekly, forKey: .weekly)
        try container.encode(sonnet, forKey: .sonnet)
        try container.encode(fable, forKey: .fable)
        try container.encode(sessionResetAt, forKey: .sessionResetAt)
        try container.encode(weeklyResetAt, forKey: .weeklyResetAt)
        try container.encode(sonnetResetAt, forKey: .sonnetResetAt)
        try container.encode(fableResetAt, forKey: .fableResetAt)
    }
}

/// Mirror of `OracleSnapshot`.
///
/// `chatGPTRows` reuses `OracleSnapshot.ChatGPTRow`'s own synthesized
/// `Codable`, which OMITS nil optionals. That asymmetry is deliberate: the
/// same synthesized encoding is what the live decision's `oracle.chatGPTRows`
/// emits, so the fixture input and the decision output agree on row shape.
struct GoldenOracle: Codable, Equatable {
    let generatedAt: Date
    let accounts: [GoldenAccountRow]
    let chatGPTState: String
    let chatGPTRows: [OracleSnapshot.ChatGPTRow]
    let chatGPTLastUpdated: Date?
    let chatGPTConfigured: Bool

    enum CodingKeys: String, CodingKey {
        case generatedAt, accounts, chatGPTState, chatGPTRows
        case chatGPTLastUpdated, chatGPTConfigured
    }

    init(_ snapshot: OracleSnapshot) {
        generatedAt = snapshot.generatedAt
        accounts = snapshot.accounts.map(GoldenAccountRow.init)
        chatGPTState = snapshot.chatGPTState.rawValue
        chatGPTRows = snapshot.chatGPTRows
        chatGPTLastUpdated = snapshot.chatGPTLastUpdated
        chatGPTConfigured = snapshot.chatGPTConfigured
    }

    func snapshot() throws -> OracleSnapshot {
        guard let state = BrokerQuotaState(rawValue: chatGPTState) else {
            throw GoldenFixture.Failure("unknown chatGPTState '\(chatGPTState)'")
        }
        return OracleSnapshot(
            generatedAt: generatedAt,
            accounts: try accounts.map { try $0.row() },
            chatGPTState: state,
            chatGPTRows: chatGPTRows,
            chatGPTLastUpdated: chatGPTLastUpdated,
            chatGPTConfigured: chatGPTConfigured
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(chatGPTState, forKey: .chatGPTState)
        try container.encode(chatGPTRows, forKey: .chatGPTRows)
        try container.encode(chatGPTLastUpdated, forKey: .chatGPTLastUpdated)
        try container.encode(chatGPTConfigured, forKey: .chatGPTConfigured)
    }
}

// MARK: - Input

/// One corpus input: the complete world a single `decide` /
/// `decideOverride` call saw. `schema` is bumped when the shape changes so a
/// Go reader can refuse a file it does not understand instead of guessing.
struct GoldenInput: Codable {
    static let currentSchema = 1

    let schema: Int
    let role: String
    /// `null` here is Swift `nil` (resolves to the default caller); `""` is a
    /// distinct recorded case that takes a different path to the same answer.
    let caller: String?
    /// Non-null means the case was recorded through `decideOverride`.
    let overrideCandidate: String?
    let now: Date
    let policy: BrokerPolicy
    let oracle: GoldenOracle?
    let cooldowns: [String: Date]
    let t3: [String: GoldenLiveness]

    enum CodingKeys: String, CodingKey {
        case schema, role, caller
        case overrideCandidate = "override_candidate"
        case now, policy, oracle, cooldowns, t3
    }

    init(
        role: String,
        caller: String?,
        overrideCandidate: String?,
        now: Date,
        policy: BrokerPolicy,
        oracle: OracleSnapshot?,
        cooldowns: [String: Date],
        t3: [String: T3Liveness]
    ) {
        self.schema = Self.currentSchema
        self.role = role
        self.caller = caller
        self.overrideCandidate = overrideCandidate
        self.now = now
        self.policy = policy
        self.oracle = oracle.map(GoldenOracle.init)
        self.cooldowns = cooldowns
        self.t3 = t3.mapValues(GoldenLiveness.init)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(role, forKey: .role)
        // `encode`, not `encodeIfPresent`: a nil caller must be a visible
        // `null`, because an absent key would be indistinguishable from "".
        try container.encode(caller, forKey: .caller)
        try container.encode(overrideCandidate, forKey: .overrideCandidate)
        try container.encode(now, forKey: .now)
        try container.encode(policy, forKey: .policy)
        try container.encode(oracle, forKey: .oracle)
        try container.encode(cooldowns, forKey: .cooldowns)
        try container.encode(t3, forKey: .t3)
    }

    func liveness() -> [String: T3Liveness] {
        t3.mapValues { $0.liveness() }
    }
}

// MARK: - Error fixtures

/// The `noHeadroom` trace, the only error that carries engine state.
struct GoldenErrorTrace: Codable, Equatable {
    let candidatesTried: [BrokerCandidateTried]
    let oracle: BrokerOracleBlock
}

/// A recorded `BrokerError`. `case` is the enum case name (a stable
/// identifier the Go port matches on); `message` is the exact
/// `errorDescription` text, which is what every caller actually reads.
struct GoldenErrorFixture: Codable, Equatable {
    let caseName: String
    let message: String
    let trace: GoldenErrorTrace?

    enum CodingKeys: String, CodingKey {
        case caseName = "case"
        case message, trace
    }

    init(caseName: String, message: String, trace: GoldenErrorTrace?) {
        self.caseName = caseName
        self.message = message
        self.trace = trace
    }

    /// Nil for anything that is not a `BrokerError` — a non-engine failure is
    /// a test bug, not a corpus entry, and must not be silently recorded.
    init?(_ error: Error) {
        guard let brokerError = error as? BrokerError else { return nil }
        let name: String
        var trace: GoldenErrorTrace?
        switch brokerError {
        case .unknownRole:
            name = "unknownRole"
        case .unknownCaller:
            name = "unknownCaller"
        case .malformedCaller:
            name = "malformedCaller"
        case .overrideUnavailable:
            name = "overrideUnavailable"
        case .noHeadroom(_, let candidatesTried, let oracle):
            name = "noHeadroom"
            trace = GoldenErrorTrace(candidatesTried: candidatesTried, oracle: oracle)
        case .configError:
            name = "configError"
        }
        self.init(
            caseName: name,
            // `errorDescription` is what `localizedDescription` surfaces for a
            // `LocalizedError`, and it is the text the existing tests assert on.
            message: brokerError.errorDescription ?? brokerError.localizedDescription,
            trace: trace
        )
    }
}

// MARK: - Namespace

enum GoldenFixture {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Environment variable the exporter sets. `xcodebuild` forwards
    /// `TEST_RUNNER_`-prefixed variables to the test process with the prefix
    /// stripped.
    static let exportDirectoryEnvironmentKey = "PINEMETER_GOLDEN_EXPORT_DIR"

    /// Fallback marker for runners where the `TEST_RUNNER_` passthrough does
    /// not reach this process. Written and removed by `scripts/golden-export.sh`.
    static let exportDirectoryMarkerName = ".export-dir"

    /// Pretty + sorted: inputs are read by humans in review diffs, and their
    /// formatting is free because they are decoded, never byte-compared.
    static func inputEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    /// The one canonical encoding. Deliberately the production encoder, not a
    /// copy: if the wire form changes, the corpus must fail, not follow along.
    static func canonicalEncoder() -> JSONEncoder {
        BrokerDecision.makeEncoder()
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Repo root, found by walking up from this source file until a directory
    /// containing `Pinemeter.xcodeproj` appears. Avoids touching
    /// `project.pbxproj` to add the corpus as a bundle resource, and keeps the
    /// hundreds of JSON files out of the test bundle.
    static let repoRoot: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var tried: [String] = []
        while directory.path != "/" {
            tried.append(directory.path)
            let project = directory.appendingPathComponent("Pinemeter.xcodeproj")
            if FileManager.default.fileExists(atPath: project.path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        fatalError(
            "could not find a directory containing Pinemeter.xcodeproj above "
                + "\(#filePath); tried: \(tried.joined(separator: ", "))"
        )
    }()

    static var goldenDirectory: URL {
        repoRoot.appendingPathComponent("golden")
    }

    static var decisionsDirectory: URL {
        goldenDirectory.appendingPathComponent("decisions")
    }

    /// Policy decode + routing-migration fixtures (ENGINE-03).
    static var policyDirectory: URL {
        goldenDirectory.appendingPathComponent("policy")
    }

    /// Store-format fixtures (ENGINE-04). Only the three Swift-owned
    /// subdirectories live here; `stores/go-written/` is written by the Go
    /// side (Plan 11-10) and must never be touched by a Swift exporter.
    static var storesDirectory: URL {
        goldenDirectory.appendingPathComponent("stores")
    }

    /// Canonical encoding for a `BrokerPolicy` document.
    ///
    /// Same rules as the decision wire form (compact, sorted keys, ISO-8601,
    /// unescaped slashes) but a separate encoder: the policy is not a
    /// `BrokerDecision`, and pinning it to `BrokerDecision.makeEncoder()`
    /// would make an intentional decision-wire change look like a policy
    /// change. The byte rules are identical on purpose — the Go port has one
    /// canonical writer, not two.
    static func policyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func canonicalPolicyBytes(_ policy: BrokerPolicy) throws -> Data {
        try policyEncoder().encode(policy)
    }

    /// Writes `data` to `directory/name`, creating the directory. No trailing
    /// newline is ever added: the raw bytes ARE the contract.
    static func write(_ data: Data, to directory: URL, named name: String) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// Removes and recreates one fixture directory so a deleted case
    /// disappears from the corpus. Scoped deliberately: callers name the
    /// single directory they own (see `golden/README.md` § Ownership).
    static func wipe(_ directory: URL) throws {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    /// Where to write fixtures, or nil when this is an ordinary test run.
    /// Recording is opt-in so `xcodebuild test` never mutates the working tree.
    static func exportDirectory() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment[exportDirectoryEnvironmentKey] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return URL(fileURLWithPath: trimmed) }
        }
        let marker = goldenDirectory.appendingPathComponent(exportDirectoryMarkerName)
        guard let contents = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
    }

    /// `-[BrokerEngineTests test_x]` -> `BrokerEngineTests.test_x.1`.
    /// The counter disambiguates tests that decide more than once, so no test
    /// needs a hand-written fixture name and a renamed test renames its
    /// fixtures (making the corpus diff show what actually moved).
    static func caseName(for test: XCTestCase, counter: Int) -> String {
        var raw = test.name
        if raw.hasPrefix("-[") { raw.removeFirst(2) }
        if raw.hasSuffix("]") { raw.removeLast() }
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        // Swift test classes can report as `Module.Class`; keep only the class.
        let className = (parts.first ?? "UnknownTests").split(separator: ".").last.map(String.init)
            ?? "UnknownTests"
        let methodName = parts.count > 1 ? parts[1] : "unknownTest"
        return "\(sanitize(className)).\(sanitize(methodName)).\(counter)"
    }

    /// Fixture names become filenames; anything outside this set would make
    /// the corpus path-dependent or unopenable.
    private static func sanitize(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let mapped = value.map { allowed.contains($0) ? $0 : "_" }
        return mapped.isEmpty ? "_" : String(mapped)
    }
}
