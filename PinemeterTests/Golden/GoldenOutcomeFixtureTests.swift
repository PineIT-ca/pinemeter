import CryptoKit
import Foundation
import XCTest
@testable import Pinemeter

final class GoldenOutcomeFixtureTests: XCTestCase {
    struct DetailCase: Encodable {
        let name: String
        let status: BrokerLifecycleStatus
        let backupCount: Int
        let input: BrokerOutcomeDetail
        let expected: BrokerOutcomeDetail?
        let refused: Bool
        let decisionID: String?
        let knownIDs: [String]?
        let resolved: BrokerOutcomeDetail?

        enum CodingKeys: String, CodingKey {
            case name, status, input, expected, refused
            case backupCount = "backup_count"
            case decisionID = "decision_id"
            case knownIDs = "known_ids"
            case resolved
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(status, forKey: .status)
            try c.encode(backupCount, forKey: .backupCount)
            try c.encode(input, forKey: .input)
            try c.encode(expected, forKey: .expected)
            try c.encode(refused, forKey: .refused)
            try c.encodeIfPresent(decisionID, forKey: .decisionID)
            if let knownIDs {
                try c.encode(knownIDs, forKey: .knownIDs)
                try c.encode(resolved, forKey: .resolved)
            }
        }
    }

    static var detailCases: [DetailCase] {
        var cases: [DetailCase] = []
        func add(_ name: String, _ input: BrokerOutcomeDetail, status: BrokerLifecycleStatus = .completed,
                 backups: Int = 2, refused: Bool = false, expected: BrokerOutcomeDetail? = nil,
                 decisionID: String? = nil, knownIDs: [String]? = nil, resolved: BrokerOutcomeDetail? = nil) {
            cases.append(.init(name: name, status: status, backupCount: backups, input: input,
                               expected: refused || input.isEmpty ? nil : (expected ?? input), refused: refused,
                               decisionID: decisionID, knownIDs: knownIDs, resolved: resolved))
        }
        let all = BrokerOutcomeDetail(backupIndex: 2, harnessVersion: "claude-code/2.1.280",
                                      servedModel: "claude-opus-5-5", totalTokens: 2_147_483_647)
        for status in [BrokerLifecycleStatus.completed, .failed, .exhausted] {
            add("all-\(status.rawValue)", all, status: status)
        }
        add("empty-completed", .init())
        add("empty-started", .init(), status: .started)
        for (name, input) in [
            ("harness", BrokerOutcomeDetail(harnessVersion: "codex-cli/0.160.0")),
            ("model", BrokerOutcomeDetail(servedModel: "model-v1")),
            ("backup", BrokerOutcomeDetail(backupIndex: 0)),
            ("total", BrokerOutcomeDetail(totalTokens: 0)),
        ] { add("started-\(name)", input, status: .started, refused: true) }
        let maxHarness = String(repeating: "a", count: 32) + "/" + String(repeating: "1", count: 31)
        add("harness-max", .init(harnessVersion: maxHarness))
        for (name, text) in [
            ("name-33", String(repeating: "a", count: 33) + "/1"),
            ("version-32", "cli/" + String(repeating: "1", count: 32)),
            ("uppercase", "CLI/1"), ("no-slash", "cli1"), ("inner-space", "cli/1 2"),
            ("empty", ""), ("no-version", "cli/"), ("unicode", "cli/é"),
            ("nbsp", "\u{00A0}cli/1\u{00A0}"), ("vertical-tab", "\u{000B}cli/1"),
        ] { add("harness-\(name)", .init(harnessVersion: text), refused: true) }
        add("harness-trim", .init(harnessVersion: " \t\r\ncli/1.2+beta-3 \r\n"),
            expected: .init(harnessVersion: "cli/1.2+beta-3"))
        add("model-max", .init(servedModel: String(repeating: "a", count: 96)))
        add("model-punctuation", .init(servedModel: "org/model:v1@host[preview]-2.0"))
        for (name, text) in [
            ("97", String(repeating: "a", count: 97)), ("leading-dash", "-model"),
            ("inner-space", "model v1"), ("unicode", "modél"), ("empty", ""),
            ("nbsp", "\u{00A0}model\u{00A0}"), ("vertical-tab", "model\u{000B}"),
        ] { add("model-\(name)", .init(servedModel: text), refused: true) }
        add("model-trim", .init(servedModel: " \tmodel-v1\n\r"), expected: .init(servedModel: "model-v1"))
        for marker in ["pm_", "AIza", "next-auth", "X-API-Key", "Set-Cookie"] {
            add("model-marker-\(marker)", .init(servedModel: "model-\(marker)FIXTURE"), refused: true)
            add("harness-marker-\(marker)", .init(harnessVersion: "cli/\(marker)1"), refused: true)
        }
        add("backup-zero", .init(backupIndex: 0), backups: 0)
        add("backup-equal-one", .init(backupIndex: 1), backups: 1)
        add("backup-equal-two", .init(backupIndex: 2))
        add("backup-over-zero", .init(backupIndex: 1), backups: 0, refused: true)
        add("backup-over-one", .init(backupIndex: 2), backups: 1, refused: true)
        add("backup-over-two", .init(backupIndex: 3), refused: true)
        add("backup-negative", .init(backupIndex: -1), refused: true)
        add("total-zero", .init(totalTokens: 0))
        add("total-max", .init(totalTokens: 2_147_483_647))
        add("total-over", .init(totalTokens: 2_147_483_648), refused: true)
        add("total-negative", .init(totalTokens: -1), refused: true)
        for verdict in BrokerReviewVerdict.allCases {
            let value = BrokerOutcomeDetail(reviewVerdict: verdict)
            add("verdict-\(verdict.rawValue)", value, decisionID: "reviewer", knownIDs: [], resolved: value)
        }
        for status in [BrokerLifecycleStatus.started, .failed, .exhausted] {
            add("verdict-\(status.rawValue)", .init(reviewVerdict: .fail), status: status, refused: true)
        }
        add("ids-no-verdict", .init(reviewedDecisionIDs: ["worker-a"]), refused: true)
        add("empty-ids-no-verdict", .init(reviewedDecisionIDs: []), refused: true)
        add("ids-nine", .init(reviewVerdict: .pass, reviewedDecisionIDs: Array(repeating: "worker-a", count: 9)), refused: true)
        add("id-over", .init(reviewVerdict: .pass, reviewedDecisionIDs: [String(repeating: "é", count: 129)]), refused: true)
        add("id-blank", .init(reviewVerdict: .pass, reviewedDecisionIDs: [" \t\n"]), refused: true)
        add("id-empty", .init(reviewVerdict: .pass, reviewedDecisionIDs: [""]), refused: true)
        let pass = BrokerOutcomeDetail(reviewVerdict: .pass)
        add("ids-empty", .init(reviewVerdict: .pass, reviewedDecisionIDs: []), expected: pass,
            decisionID: "reviewer", knownIDs: [], resolved: pass)
        add("ids-eight", .init(reviewVerdict: .pass, reviewedDecisionIDs: Array(repeating: "worker-a", count: 8)),
            decisionID: "reviewer", knownIDs: ["worker-a"],
            resolved: .init(reviewVerdict: .pass, reviewedDecisionIDs: ["worker-a"]))
        let order = ["worker-b", "worker-a", "worker-b", "reviewer", "remote-worker", "worker-c"]
        add("ids-order", .init(reviewVerdict: .pass, reviewedDecisionIDs: order),
            decisionID: "reviewer", knownIDs: ["worker-a", "worker-b", "worker-c", "reviewer"],
            resolved: .init(reviewVerdict: .pass, reviewedDecisionIDs: ["worker-b", "worker-a", "worker-c"]))
        add("ids-own-only", .init(reviewVerdict: .pass, reviewedDecisionIDs: ["reviewer"]),
            decisionID: "reviewer", knownIDs: ["reviewer"], resolved: pass)
        add("ids-unknown-only", .init(reviewVerdict: .pass, reviewedDecisionIDs: ["remote-worker"]),
            decisionID: "reviewer", knownIDs: [], resolved: pass)
        add("ids-trim", .init(reviewVerdict: .pass, reviewedDecisionIDs: [" \tworker-a\n", "worker-a"]),
            expected: .init(reviewVerdict: .pass, reviewedDecisionIDs: ["worker-a", "worker-a"]),
            decisionID: "reviewer", knownIDs: ["worker-a"],
            resolved: .init(reviewVerdict: .pass, reviewedDecisionIDs: ["worker-a"]))
        let maxID = String(repeating: "é", count: 128)
        add("id-max-scalars", .init(reviewVerdict: .pass, reviewedDecisionIDs: [maxID]),
            decisionID: "reviewer", knownIDs: [maxID],
            resolved: .init(reviewVerdict: .pass, reviewedDecisionIDs: [maxID]))
        add("failure-class-usage_limit-failed", .init(failureClass: .usageLimit), status: .failed, backups: 0)
        add("failure-class-provider_error-failed", .init(failureClass: .providerError), status: .failed, backups: 0)
        add("failure-class-transport_error-failed", .init(failureClass: .transportError), status: .failed, backups: 0)
        add("failure-class-permission_error-failed", .init(failureClass: .permissionError), status: .failed, backups: 0)
        add("failure-class-validation_error-failed", .init(failureClass: .validationError), status: .failed, backups: 0)
        add("failure-class-unknown-failed", .init(failureClass: .unknown), status: .failed, backups: 0)
        add("failure-class-credit_wall-failed", .init(failureClass: .creditWall), status: .failed, backups: 0)
        add("failure-class-task_error-failed", .init(failureClass: .taskError), status: .failed, backups: 0)
        add("failure-class-usage_limit-exhausted", .init(failureClass: .usageLimit), status: .exhausted, backups: 0)
        add("failure-class-provider_error-exhausted", .init(failureClass: .providerError), status: .exhausted, backups: 0)
        add("failure-class-transport_error-exhausted", .init(failureClass: .transportError), status: .exhausted, backups: 0)
        add("failure-class-permission_error-exhausted", .init(failureClass: .permissionError), status: .exhausted, backups: 0)
        add("failure-class-validation_error-exhausted", .init(failureClass: .validationError), status: .exhausted, backups: 0)
        add("failure-class-unknown-exhausted", .init(failureClass: .unknown), status: .exhausted, backups: 0)
        add("failure-class-credit_wall-exhausted", .init(failureClass: .creditWall), status: .exhausted, backups: 0)
        add("failure-class-task_error-exhausted", .init(failureClass: .taskError), status: .exhausted, backups: 0)
        add("failure-class-on-started-refused", .init(failureClass: .usageLimit), status: .started, backups: 0, refused: true)
        add("failure-class-on-completed-refused", .init(failureClass: .taskError), status: .completed, backups: 0, refused: true)
        return cases
    }

    nonisolated(unsafe) private static var wiped = false
    private func output() throws -> URL? {
        guard GoldenFixture.exportDirectory() != nil else { return nil }
        let directory = GoldenFixture.storesDirectory.appendingPathComponent("outcomes")
        if !Self.wiped {
            Self.wiped = true
            try GoldenFixture.wipe(directory)
        }
        return directory
    }

    func test_exportsOutcomeDetailCases() throws {
        for c in Self.detailCases {
            if c.refused {
                XCTAssertThrowsError(try c.input.normalized(status: c.status, backupCount: c.backupCount), c.name) {
                    XCTAssertEqual($0 as? BrokerAuditStoreError, .invalidLifecycleReport)
                }
            } else {
                let normalized = try c.input.normalized(status: c.status, backupCount: c.backupCount)
                XCTAssertEqual(normalized, c.expected, c.name)
                if let known = c.knownIDs {
                    XCTAssertEqual(normalized?.resolvingReviewedIDs(decisionID: c.decisionID!, isKnown: known.contains),
                                   c.resolved, c.name)
                }
            }
        }
        if let directory = try output() {
            try GoldenFixture.write(try GoldenFixture.policyEncoder().encode(Self.detailCases),
                                    to: directory, named: "detail-cases.json")
        }
    }

    func test_exportsCredentialMarkerDigest() throws {
        let digest = SHA256.hash(data: Data(BrokerOutcomeText.credentialMarkers.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined() + "\n"
        if let directory = try output() {
            try GoldenFixture.write(Data(digest.utf8), to: directory, named: "credential-markers.sha256")
        }
    }
    struct TrendRequest: Encodable {
        let now: Date
        let role: String?
        let includeAllReasons: Bool
        enum CodingKeys: String, CodingKey { case now, role; case includeAllReasons = "include_all_reasons" }
    }
    func test_exportsTrendFixtures() throws {
        let directory = try output()
        for c in BrokerOutcomeTrendTests.cases {
            BrokerOutcomeTrendTests.assertCase(c)
            if let directory {
                let encoder = BrokerOutcomeStore.encoder()
                let request = TrendRequest(now: c.now, role: c.role, includeAllReasons: c.all)
                try GoldenFixture.write(try encoder.encode(c.rollup), to: directory, named: c.name + ".rollup.json")
                try GoldenFixture.write(try encoder.encode(request), to: directory, named: c.name + ".request.json")
                try GoldenFixture.write(try encoder.encode(c.trend), to: directory, named: c.name + ".trend.json")
            }
        }
    }

    struct RollupOperation: Encodable {
        let kind: String
        let record: BrokerAuditRecord
        let reviewed: [BrokerAuditRecord]
        var now: Date? = nil
    }
    struct RollupOperations: Encodable {
        let clock: Date
        let operations: [RollupOperation]
    }
    func test_exportsRollupFixtures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GoldenRollup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = BrokerAuditStore(storeDirectory: directory)
        let store = BrokerOutcomeStore(storeDirectory: directory, now: { BrokerFixture.now })
        var operations: [RollupOperation] = []
        var nextID = 0
        func pick(role: String, effort: BrokerEffort, daysAgo: Int, quota: Bool = false) async throws -> String {
            nextID += 1
            let id = "rollup-\(nextID)"
            var policy = BrokerFixture.policy(roles: [role: ["native/claude-fable-5"]])
            policy.roles[role] = [BrokerCandidate(route: .native, model: "claude-fable-5", effort: effort),
                                  BrokerCandidate(route: .native, model: "claude-opus-5", effort: effort)]
            var oracle = BrokerFixture.oracle()
            var liveness: [String: T3Liveness] = [:]
            if quota {
                policy = BrokerFixture.policy(
                    roles: [role: ["t3:quota/claude-sonnet-5", "native/escape-hatch"]],
                    t3Instances: [T3InstanceConfig(id: "quota", name: "Quota", boundAccountId: "mapped", origin: .manual)],
                    usageLanes: ["t3:quota/claude-sonnet-5": .claudeAccount(accountId: nil, labelContains: nil, isPrimary: nil)])
                policy.roles[role]?[1] = BrokerCandidate(route: .native, model: "escape-hatch", effort: effort)
                oracle = BrokerFixture.oracle(accounts: [BrokerFixture.account(), BrokerFixture.account(
                    id: "mapped", label: "Mapped", isPrimary: false, session: 1, weekly: 1, sonnet: 31,
                    sonnetResetAt: BrokerFixture.now.addingTimeInterval(6.25 * 86400))])
                liveness = ["quota": T3Liveness(reachable: true, why: "http 200")]
            }
            let decision = try BrokerEngine.decide(role: role, caller: "claude-code", policy: policy,
                                                   oracle: oracle, cooldowns: [:], now: BrokerFixture.now, t3: liveness)
                .attachingDecisionID(id)
            XCTAssertEqual(decision.pickBasis, quota ? .quota : .quality)
            try await audit.append(decision: decision, timestamp: BrokerFixture.now.addingTimeInterval(Double(-daysAgo * 86400)))
            let stored = await audit.record(for: id)
            let record = try XCTUnwrap(stored)
            try await store.notePick(record)
            operations.append(.init(kind: "pick", record: record, reviewed: []))
            return id
        }
        func terminal(_ id: String, status: BrokerLifecycleStatus, outcome: BrokerOutcomeDetail? = nil) async throws {
            let report = BrokerLifecycleReport(decisionID: id, status: status, durationMS: 42,
                                               actualInputTokens: 3, actualCachedInputTokens: 4,
                                               actualCacheCreationInputTokens: 5, actualOutputTokens: 6, actualReasoningTokens: 2)
            let result = try await audit.reportLifecycle(report, outcome: outcome)
            if result == .recorded {
                let stored = await audit.record(for: id)
                let record = try XCTUnwrap(stored)
                var reviewed: [BrokerAuditRecord] = []
                for workerID in record.outcome?.reviewedDecisionIDs ?? [] {
                    if let worker = await audit.record(for: workerID) { reviewed.append(worker) }
                }
                try await store.noteTerminal(record, reviewed: reviewed)
                operations.append(.init(kind: "terminal", record: record, reviewed: reviewed))
            }
        }
        let first = try await pick(role: "execution", effort: .high, daysAgo: 2)
        try await terminal(first, status: .completed, outcome: .init(totalTokens: 25))
        try await terminal(first, status: .completed)
        let second = try await pick(role: "planning", effort: .medium, daysAgo: 1)
        try await terminal(second, status: .failed)
        let third = try await pick(role: "planning", effort: .high, daysAgo: 0, quota: true)
        try await terminal(third, status: .exhausted)
        let review = try await pick(role: "review", effort: .high, daysAgo: 0)
        try await terminal(review, status: .completed, outcome: .init(backupIndex: 1, harnessVersion: "cli/1",
                            servedModel: "model-1", reviewVerdict: .pass, reviewedDecisionIDs: [first, second]))
        for (i, status) in [BrokerLifecycleStatus.completed, .failed, .exhausted, .completed, .failed].enumerated() {
            let id = try await pick(role: "execution", effort: .high, daysAgo: 0)
            try await terminal(id, status: status, outcome: .init(harnessVersion: "cli/\(i + 1)", servedModel: "model-\(i + 1)"))
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.buckets.count, 5)
        XCTAssertEqual(snapshot.buckets.reduce(0) { $0 + ($1.verdictsReceived["pass"] ?? 0) }, 2)
        XCTAssertEqual(snapshot.buckets.map(\.servedModelsOther).max(), 1)
        if let out = try output() {
            try GoldenFixture.write(try Data(contentsOf: directory.appendingPathComponent(BrokerOutcomeStore.fileName)), to: out, named: "rollup-basic.json")
            try GoldenFixture.write(try GoldenFixture.policyEncoder().encode(RollupOperations(clock: BrokerFixture.now, operations: operations)), to: out, named: "rollup-basic.ops.json")
        }
    }

    func test_exportsRollupRetentionFixture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GoldenRetention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = RollupFixtureClock(BrokerFixture.now)
        let audit = BrokerAuditStore(storeDirectory: directory)
        let store = BrokerOutcomeStore(storeDirectory: directory, now: { clock.now })
        var operations: [RollupOperation] = []
        let policy = BrokerFixture.policy(roles: ["execution": ["native/claude-fable-5"]])
        for age in stride(from: 180, through: 0, by: -1) {
            clock.now = BrokerFixture.now.addingTimeInterval(Double(-age * 86400))
            let id = "retention-\(180 - age)"
            let decision = try BrokerEngine.decide(role: "execution", caller: "claude-code", policy: policy,
                                                   oracle: BrokerFixture.oracle(), cooldowns: [:], now: BrokerFixture.now, t3: [:])
                .attachingDecisionID(id)
            try await audit.append(decision: decision, timestamp: clock.now)
            let stored = await audit.record(for: id)
            let record = try XCTUnwrap(stored)
            try await store.notePick(record)
            operations.append(.init(kind: "pick", record: record, reviewed: [], now: clock.now))
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.buckets.count, 180)
        XCTAssertEqual(snapshot.buckets.first?.day, BrokerOutcomeStore.day(BrokerFixture.now.addingTimeInterval(-179 * 86400)))
        XCTAssertEqual(snapshot.buckets.last?.day, BrokerOutcomeStore.day(BrokerFixture.now))
        if let out = try output() {
            try GoldenFixture.write(try Data(contentsOf: directory.appendingPathComponent(BrokerOutcomeStore.fileName)), to: out, named: "rollup-retention.json")
            try GoldenFixture.write(try GoldenFixture.policyEncoder().encode(RollupOperations(clock: BrokerFixture.now, operations: operations)), to: out, named: "rollup-retention.ops.json")
        }
    }

}

private final class RollupFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}
