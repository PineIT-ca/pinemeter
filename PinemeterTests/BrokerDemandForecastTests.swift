import Foundation
import XCTest
@testable import Pinemeter

final class BrokerDemandForecastTests: XCTestCase {
    private let now = BrokerFixture.now
    private let claude = GoldenForecastFixtureTests.claude
    private let chatGPT = GoldenForecastFixtureTests.chatGPT
    private func day(_ age: Int, _ role: String = "standard", _ picks: Int = 72) -> BrokerLedgerDay {
        .init(day: String(ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(-age * 86400))).prefix(10)),
              role: role, picks: picks)
    }
    private func record(_ age: Int, _ role: String = "standard", _ candidate: String = "native/claude-opus-5") -> BrokerLedgerRecord {
        .init(timestamp: now.addingTimeInterval(Double(-age * 86400)), role: role, candidate: candidate)
    }
    private func summary(_ records: [BrokerLedgerRecord] = [], _ days: [BrokerLedgerDay] = []) throws -> BrokerDemand {
        var input = GoldenForecastFixtureTests.basic()
        input.records = records; input.days = days
        return try input.demand()
    }
    private func neutral(_ demand: BrokerDemand, file: StaticString = #filePath, line: UInt = #line) throws {
        for row in try GoldenForecastFixtureTests.basic().prices(demand) {
            XCTAssertEqual(row.price, 1000, row.pool, file: file, line: line)
        }
    }

    func test_demandLookback() throws {
        for (age, length, sufficient) in [(10, 7, true), (3, 3, true), (2, 2, false), (0, 0, false)] {
            let d = try summary([], [day(age, "standard", 24)])
            XCTAssertEqual(d.historyDays, length); XCTAssertEqual(d.historySufficient, sufficient)
            if !sufficient { try neutral(d) }
        }
        let ancient = BrokerLedgerDay(day: "0001-01-01", role: "standard", picks: 1)
        XCTAssertEqual(try summary([], [ancient, day(0)]).historyDays, 7)
    }
    func test_demandTodayExcluded() throws {
        let invalid = ["invalid", "2023-02-29", "2023-2-01", "2023-11-13extra"].map {
            BrokerLedgerDay(day: $0, role: "standard", picks: 999999)
        }
        let d = try summary([], [day(3, "standard", 24), day(1, "standard", 48), day(0, "standard", 999999), day(-1, "standard", 999999)] + invalid)
        XCTAssertEqual(d.historyDays, 3); XCTAssertEqual(d.roles["standard"], 1000)
    }
    func test_demandRollupLoadFailed() throws {
        var input = GoldenForecastFixtureTests.basic()
        input.days = [day(7, "standard", 168)]; input.rollupLoadFailed = true
        let d = try input.demand()
        XCTAssertFalse(d.historySufficient); XCTAssertEqual(d.historyDays, 7)
        XCTAssertEqual(d.roles["standard"], 1000); try neutral(d)
    }
    func test_demandRoleRates() throws {
        let d = try summary([], [day(3, "standard", 24), day(3, "standard", 24), day(1, "standard", 24),
                                 day(1, "review", 1), day(1, "zero", 0), day(1, "negative", -1),
                                 day(2, "capped", Int.max), day(1, "capped", Int.max)])
        XCTAssertEqual(d.roles, ["standard": 1000, "review": 13, "capped": 13888888888])
    }
    func test_demandPoolRatesUseFullActiveChains() throws {
        let records = [record(1), record(1, "standard", "codex/gpt-6-astra"), record(1, "review"),
                       record(1, "review", "codex/gpt-6-astra"), record(0), record(4)]
        let d = try summary(records, [day(3, "standard", 1), day(1, "review", 1), day(1, "planning", 7200)])
        XCTAssertEqual(d.pools[claude]?.rateMilli, 26); XCTAssertEqual(d.pools[chatGPT]?.rateMilli, 13)
        XCTAssertEqual(d.roles["planning"], 100000)
        let today = Date(timeIntervalSince1970: 1699920000)
        let edges: [BrokerLedgerRecord] = [
            .init(timestamp: today.addingTimeInterval(-3 * 86400), role: "standard", candidate: "native/claude-opus-5"),
            .init(timestamp: today.addingTimeInterval(-3 * 86400 - 1), role: "standard", candidate: "codex/gpt-6-astra"),
            .init(timestamp: today, role: "standard", candidate: "codex/gpt-6-astra"),
            .init(timestamp: today.addingTimeInterval(-1), role: "standard", candidate: "codex/gpt-6-astra")]
        let boundary = try summary(edges, [day(3)])
        XCTAssertEqual(boundary.pools[claude]?.rateMilli, 1000); XCTAssertEqual(boundary.pools[chatGPT]?.rateMilli, 1000)
    }
    func test_demandUnmappedRecords() throws {
        let d = try summary([record(1), record(1, "standard", "malformed"), record(1, "standard", "t3:unmapped/model-v1"),
                             record(1, "standard", "codex/unmapped")], [day(3)])
        XCTAssertEqual(d.pools[claude], .init(rateMilli: 1000, windowDecisions: 1, ledgerDecisions: 1))
        XCTAssertEqual(d.pools[chatGPT], .init(rateMilli: 1000, windowDecisions: 0, ledgerDecisions: 0))
    }
    func test_demandWindowEdges() throws {
        var input = GoldenForecastFixtureTests.basic()
        let reset = now.addingTimeInterval(3600.9)
        input.oracle = GoldenOracle(BrokerFixture.oracle(accounts: [BrokerFixture.account(weeklyResetAt: reset)]))
        let start = Date(timeIntervalSince1970: floor(reset.timeIntervalSince1970) - 604800)
        input.records = [start, start.addingTimeInterval(-1), start.addingTimeInterval(-0.001), now,
                         now.addingTimeInterval(1), now.addingTimeInterval(0.001)].map {
            .init(timestamp: $0, role: "standard", candidate: "native/claude-opus-5")
        }
        input.days = []
        XCTAssertEqual(try input.demand().pools[claude], .init(rateMilli: 0, windowDecisions: 2, ledgerDecisions: 6))
    }
    func test_demandLedgerCounts() throws {
        var input = GoldenForecastFixtureTests.basic()
        input.oracle = GoldenOracle(BrokerFixture.oracle(accounts: [BrokerFixture.account()]))
        input.records = [record(20), record(1), record(-1)]; input.days = [day(3)]
        XCTAssertEqual(try input.demand().pools[claude], .init(rateMilli: 1000, windowDecisions: 0, ledgerDecisions: 3))
    }
    func test_demandOrderIndependent() throws {
        var records = [record(1), record(1), record(1, "standard", "codex/gpt-6-astra"), record(2, "review", "codex/gpt-6-astra")]
        var days = [day(3), day(1, "review", 24), day(2, "review", 24)]
        let encoder = GoldenFixture.policyEncoder()
        let expected = try encoder.encode(summary(records, days))
        for _ in 0..<20 {
            records.shuffle(); days.shuffle()
            XCTAssertEqual(try encoder.encode(summary(records, days)), expected)
        }
        XCTAssertEqual(try summary(records, days).pools[claude]?.ledgerDecisions, 2)
    }
    func test_demandTruncatedRingNeverCheaper() throws {
        let records: [BrokerLedgerRecord] = (0..<20).map {
            .init(timestamp: now.addingTimeInterval(Double(-(20 - $0) * 3600)), role: "standard", candidate: "native/claude-opus-5")
        }
        var prior = 0
        for removed in 0...20 {
            let d = try summary(Array(records.dropFirst(removed)), [day(3)])
            XCTAssertEqual(d.pools[claude]?.windowDecisions, 20 - removed)
            let price = try XCTUnwrap(GoldenForecastFixtureTests.basic().prices(d).first { $0.pool == claude }).price
            XCTAssertGreaterThanOrEqual(price, prior); prior = price
        }
    }
    func test_demandEveryRoleUsesActiveChain() throws {
        for records in [[], [record(1)], [record(1, "standard", "codex/gpt-6-astra")],
                        [record(1, "standard", "malformed")], [record(1, "standard", "codex/unmapped")],
                        [record(0)], [record(4)]] {
            let d = try summary(records, [day(3)])
            XCTAssertEqual(d.pools[claude]?.rateMilli, 1000)
            XCTAssertEqual(d.pools[chatGPT]?.rateMilli, 1000)
        }
        var input = GoldenForecastFixtureTests.basic()
        input.policy.roles = ["planning": [BrokerCandidate(id: "auto/gpt-6-astra")!,
                                            BrokerCandidate(id: "auto/gpt-6-astra")!],
                              "review": [BrokerCandidate(id: "t3:*/claude-opus-5")!]]
        input.records = []
        input.days = [day(3, "architecture", 72), day(3, "review", 144), day(3, "removed-role", 720)]
        let d = try input.demand()
        XCTAssertEqual(d.pools[claude]?.rateMilli, 2000)
        XCTAssertEqual(d.pools[chatGPT]?.rateMilli, 1000)
    }

    // The original probe lost the standard role's only historical record (496 to 79).
    func test_demandTruncatedUnattributedRoleNeverCheaper() throws {
        var input = GoldenForecastFixtureTests.basic()
        input.days = [day(3, "standard", 720), day(3, "review", 72)]
        input.records = [record(1)] + Array(repeating: BrokerLedgerRecord(
            timestamp: now.addingTimeInterval(-3600), role: "review", candidate: "native/claude-opus-5"), count: 10)
        var prior = 0
        for removed in 0...1 {
            var truncated = input
            truncated.records = Array(input.records.dropFirst(removed))
            let d = try truncated.demand()
            XCTAssertEqual(d.pools[claude]?.rateMilli, 11000)
            let row = try XCTUnwrap(truncated.prices(d).first { $0.pool == claude })
            XCTAssertEqual(row.forecast.state, "ok")
            XCTAssertGreaterThanOrEqual(row.price, prior, "removed=\(removed)")
            prior = row.price
        }
    }

    func test_demandTruncatedMixedPoolsNeverCheaper() throws {
        var input = GoldenForecastFixtureTests.basic()
        input.days = [day(3, "standard", 720), day(3, "review", 72)]
        input.records = [record(2), record(1, "standard", "codex/gpt-6-astra")] + Array(repeating: BrokerLedgerRecord(
            timestamp: now.addingTimeInterval(-3600), role: "review", candidate: "native/claude-opus-5"), count: 10)
        var prior = 0
        for removed in 0...2 {
            var truncated = input
            truncated.records = Array(input.records.dropFirst(removed))
            let d = try truncated.demand()
            let row = try XCTUnwrap(truncated.prices(d).first { $0.pool == claude })
            XCTAssertEqual(row.forecast.state, "ok")
            XCTAssertGreaterThanOrEqual(row.price, prior, "removed=\(removed), rate=\(row.forecast.rateMilli)")
            prior = row.price
        }
    }

    func test_demandEmptyInputs() throws {
        let d = try summary()
        XCTAssertEqual(d.historyDays, 0); XCTAssertFalse(d.historySufficient); XCTAssertTrue(d.roles.isEmpty)
        XCTAssertEqual(d.pools.count, 2)
        for pool in d.pools.values { XCTAssertEqual(pool, .init(rateMilli: 0, windowDecisions: 0, ledgerDecisions: 0)) }
        try neutral(d)
        let noRing = try summary([], [day(3)])
        for pool in noRing.pools.values { XCTAssertEqual(pool, .init(rateMilli: 1000, windowDecisions: 0, ledgerDecisions: 0)) }
        try neutral(noRing)
        let noOracle = BrokerDemandForecast.summarize(policy: GoldenForecastFixtureTests.basic().policy, oracle: nil,
                                                      records: [], days: [], rollupLoadFailed: false, now: now)
        XCTAssertTrue(noOracle.pools.isEmpty)
    }

    func test_demandForecastVectorsNeverCheaperOnRingEviction() throws {
        let directory = GoldenFixture.goldenDirectory.appendingPathComponent("forecast")
        let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".input.json") }
        XCTAssertFalse(paths.isEmpty)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for path in paths {
            var input = try decoder.decode(GoldenForecastFixtureTests.Input.self, from: Data(contentsOf: path))
            input.records.sort { $0.timestamp < $1.timestamp }
            let original = try input.demand()
            var prior: [String: Int] = [:]
            for removed in 0...input.records.count {
                var truncated = input
                truncated.records = Array(input.records.dropFirst(removed))
                let demand = try truncated.demand()
                XCTAssertEqual(demand.roles, original.roles, path.lastPathComponent)
                for row in try truncated.prices(demand) {
                    XCTAssertEqual(demand.pools[row.pool]?.rateMilli, original.pools[row.pool]?.rateMilli)
                    XCTAssertGreaterThanOrEqual(row.price, prior[row.pool] ?? 0,
                                               "\(path.lastPathComponent), removed=\(removed), pool=\(row.pool)")
                    prior[row.pool] = row.price
                }
            }
        }
    }
    func test_demandChatGPTWindows() throws {
        let cases: [(ChatGPTUsageData.MenuBarQuotaRole, Double?, Int)] = [
            (.chatGPTWeekly, nil, 604800), (.chatGPTMonthly, nil, 2592000), (.chatGPTMonthly, 172800.5, 172801),
            (.chatGPTWeekly, -1, 604800), (.chatGPTWeekly, 999999999, 2678400)]
        for (role, seconds, window) in cases {
            var input = GoldenForecastFixtureTests.basic()
            let reset = now.addingTimeInterval(7200)
            input.oracle = GoldenOracle(BrokerFixture.oracle(chatGPTRows: [
                .init(label: "Weekly", usedPercent: 10, resetAt: reset, windowRole: role, windowSeconds: seconds, account: "Workspace A")]))
            let start = reset.addingTimeInterval(Double(-window))
            input.records = [start, start.addingTimeInterval(-1)].map {
                .init(timestamp: $0, role: "standard", candidate: "codex/gpt-6-astra")
            }
            input.days = []
            if let seconds, seconds < 86400 {
                XCTAssertNil(try input.demand().pools[chatGPT])
            } else {
                XCTAssertEqual(try input.demand().pools[chatGPT]?.windowDecisions, 1, "window \(window)")
            }
        }
    }
    func test_demandProjectionsContainOnlyPermittedFields() throws {
        let audit = BrokerOutcomeStoreTests.record(daysAgo: 1, role: "standard", model: "native/claude-opus-5",
                                                   outcome: .init(totalTokens: 999))
        let records = BrokerDemandForecast.ledgerRecords(from: [audit])
        XCTAssertEqual(records, [record(1)])
        var buckets: [BrokerOutcomeBucket] = []
        for (model, effort, basis) in [("model-a", "high", "quality"), ("model-b", "low", "quota"), ("model-c", "default", "human_override")] {
            var bucket = BrokerOutcomeBucket(day: day(3).day, role: "standard", model: model, effort: effort, pickBasis: basis)
            bucket.picks = 24; bucket.tokensTotal = 999; bucket.completed = 9
            buckets.append(bucket)
        }
        let days = BrokerDemandForecast.ledgerDays(from: .init(version: 1, buckets: buckets))
        XCTAssertEqual(days, Array(repeating: day(3, "standard", 24), count: 3))
        XCTAssertEqual(try summary(records, days).roles["standard"], 1000)
        let encoder = GoldenFixture.policyEncoder()
        let recordJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(records)) as? [[String: Any]])
        let dayJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(days)) as? [[String: Any]])
        XCTAssertEqual(Set(recordJSON[0].keys), ["timestamp", "role", "candidate"])
        XCTAssertEqual(Set(dayJSON[0].keys), ["day", "role", "picks"])
    }

    func test_demandAllDurablePools() throws {
        var input = GoldenForecastFixtureTests.basic()
        let reset = now.addingTimeInterval(7200)
        let durable = OracleSnapshot.ChatGPTRow(label: "Weekly", usedPercent: 10, resetAt: reset,
                                               windowRole: .chatGPTWeekly, account: "Workspace A")
        let short = OracleSnapshot.ChatGPTRow(label: "Weekly", usedPercent: 10, resetAt: reset,
                                             windowRole: .chatGPTWeekly, windowSeconds: 3600, account: "Workspace A")
        input.oracle = GoldenOracle(BrokerFixture.oracle(accounts: [BrokerFixture.account(
            label: "Account A", weekly: 20, sonnet: 10, fable: 12,
            weeklyResetAt: now.addingTimeInterval(3600), sonnetResetAt: now.addingTimeInterval(3600))],
            chatGPTRows: [short, durable, durable], chatGPTConfigured: true))
        let start = reset.addingTimeInterval(-604800)
        input.records = [
            .init(timestamp: start, role: "standard", candidate: "codex/gpt-6-astra"),
            .init(timestamp: start.addingTimeInterval(-1), role: "standard", candidate: "codex/gpt-6-astra"),
            record(1, "standard", "native/claude-sonnet-5")]
        input.days = [day(3)]
        let d = try input.demand()
        XCTAssertEqual(d.pools.count, 4)
        XCTAssertEqual(d.pools[chatGPT], .init(rateMilli: 1000, windowDecisions: 1, ledgerDecisions: 2))
        XCTAssertEqual(d.pools[claude], .init(rateMilli: 1000, windowDecisions: 1, ledgerDecisions: 1))
        XCTAssertEqual(d.pools["claude:acct-primary:sonnet"], .init(rateMilli: 0, windowDecisions: 1, ledgerDecisions: 1))
        XCTAssertEqual(d.pools["claude:acct-primary:fable"], .init(rateMilli: 0, windowDecisions: 0, ledgerDecisions: 0))
    }
}
