import Foundation
import XCTest
@testable import Pinemeter

final class GoldenForecastFixtureTests: XCTestCase {
    struct Input: Codable {
        var schema = 1
        var now: Date
        var policy: BrokerPolicy
        var oracle: GoldenOracle
        var records: [BrokerLedgerRecord]
        var days: [BrokerLedgerDay]
        var rollupLoadFailed = false
        enum CodingKeys: String, CodingKey {
            case schema, now, policy, oracle, records, days
            case rollupLoadFailed = "rollup_load_failed"
        }
        func demand() throws -> BrokerDemand {
            BrokerDemandForecast.summarize(policy: policy, oracle: try oracle.snapshot(), records: records,
                                           days: days, rollupLoadFailed: rollupLoadFailed, now: now)
        }
        func prices(_ demand: BrokerDemand) throws -> [BrokerPoolPrice] {
            BrokerPoolPricing.poolPrices(policy: policy, oracle: try oracle.snapshot(), demand: demand, now: now)
        }
    }

    static let claude = "claude:acct-primary:weekly"
    static let chatGPT = "chatgpt:Workspace A:Weekly"

    static func basic() -> Input {
        let now = BrokerFixture.now
        var policy = BrokerFixture.policy(
            roles: ["standard": ["native/claude-opus-5", "codex/gpt-6-astra"], "review": ["t3:alpha/claude-opus-5"]],
            t3: .init(instanceByModel: [:], defaultInstance: "alpha"),
            t3Instances: [.init(id: "alpha", name: "Alpha", boundAccountId: "acct-primary", origin: .manual)],
            usageLanes: ["t3:alpha/claude-opus-5": .claudeAccount(accountId: "acct-primary", labelContains: nil, isPrimary: nil)],
            models: ["gpt-6-astra": .init(quota: .chatGPT(labelContains: nil))])
        policy.thresholds.preferExpiringQuota = true
        let oracle = BrokerFixture.oracle(
            accounts: [BrokerFixture.account(label: "Account A", weekly: 20, weeklyResetAt: now.addingTimeInterval(3600))],
            chatGPTRows: [.init(label: "Weekly", usedPercent: 10, resetAt: now.addingTimeInterval(7200),
                               windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true)
        let days: [BrokerLedgerDay] = (1...8).flatMap { age -> [BrokerLedgerDay] in
            let day = String(ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(-age * 86400))).prefix(10))
            return [.init(day: day, role: "standard", picks: 24), .init(day: day, role: "review", picks: 12)]
        }
        let records: [BrokerLedgerRecord] = (0..<40).map { i -> BrokerLedgerRecord in
            let timestamp = now.addingTimeInterval(Double(-86400 - i * 3600))
            let role = i < 30 ? "standard" : "review"
            let candidate = i < 15 ? "native/claude-opus-5" : (i < 30 ? "codex/gpt-6-astra" : "t3:alpha/claude-opus-5")
            return .init(timestamp: timestamp, role: role, candidate: candidate)
        }
        return .init(now: now, policy: policy, oracle: GoldenOracle(oracle), records: records, days: days)
    }

    nonisolated(unsafe) private static var wiped = false
    private func write(_ name: String, input: Input, demand: BrokerDemand, prices: [BrokerPoolPrice]) throws {
        guard GoldenFixture.exportDirectory() != nil else { return }
        let directory = GoldenFixture.goldenDirectory.appendingPathComponent("forecast")
        if !Self.wiped { Self.wiped = true; try GoldenFixture.wipe(directory) }
        let encoder = GoldenFixture.policyEncoder()
        try GoldenFixture.write(try encoder.encode(input), to: directory, named: name + ".input.json")
        try GoldenFixture.write(try encoder.encode(demand), to: directory, named: name + ".demand.json")
        try GoldenFixture.write(try encoder.encode(prices), to: directory, named: name + ".pools.json")
    }

    func test_forecastBasic() throws {
        let input = Self.basic()
        let demand = try input.demand()
        XCTAssertEqual(demand.historyDays, 7)
        XCTAssertTrue(demand.historySufficient)
        XCTAssertEqual(demand.roles["standard"], 1000)
        XCTAssertEqual(demand.pools[Self.claude]?.rateMilli, 1500)
        XCTAssertEqual(demand.pools[Self.claude]?.windowDecisions, 25)
        try write("forecast-basic", input: input, demand: demand, prices: input.prices(demand))
    }

    func test_forecastUnattributedRole() throws {
        var input = Self.basic()
        let day = String(ISO8601DateFormatter().string(from: input.now.addingTimeInterval(-3 * 86400)).prefix(10))
        input.days = [.init(day: day, role: "standard", picks: 720), .init(day: day, role: "review", picks: 72)]
        input.records = [.init(timestamp: input.now.addingTimeInterval(-86400), role: "standard", candidate: "native/claude-opus-5")]
            + Array(repeating: .init(timestamp: input.now.addingTimeInterval(-3600), role: "review", candidate: "native/claude-opus-5"), count: 10)
        let before = try input.demand()
        XCTAssertEqual(try input.prices(before).first { $0.pool == Self.claude }?.price, 538)
        input.records.removeFirst()
        let demand = try input.demand()
        XCTAssertEqual(demand.historyDays, 3)
        XCTAssertTrue(demand.historySufficient)
        XCTAssertEqual(demand.roles, ["standard": 10000, "review": 1000])
        XCTAssertEqual(demand.pools[Self.claude], .init(rateMilli: 11000, windowDecisions: 10, ledgerDecisions: 10))
        XCTAssertEqual(demand.pools[Self.chatGPT], .init(rateMilli: 10000, windowDecisions: 0, ledgerDecisions: 0))
        let prices = try input.prices(demand)
        let claude = try XCTUnwrap(prices.first { $0.pool == Self.claude })
        XCTAssertEqual(claude.forecast.state, "ok")
        XCTAssertEqual(claude.price, 584)
        let chatGPT = try XCTUnwrap(prices.first { $0.pool == Self.chatGPT })
        XCTAssertEqual(chatGPT.forecast.state, "new_pool")
        XCTAssertEqual(chatGPT.price, 1000)
        try write("forecast-unattributed-role", input: input, demand: demand, prices: prices)
    }

    func test_forecastMixedPoolEviction() throws {
        var input = Self.basic()
        let day = String(ISO8601DateFormatter().string(from: input.now.addingTimeInterval(-3 * 86400)).prefix(10))
        input.days = [.init(day: day, role: "standard", picks: 720), .init(day: day, role: "review", picks: 72)]
        input.records = [
            .init(timestamp: input.now.addingTimeInterval(-2 * 86400), role: "standard", candidate: "native/claude-opus-5"),
            .init(timestamp: input.now.addingTimeInterval(-86400), role: "standard", candidate: "codex/gpt-6-astra")
        ] + Array(repeating: .init(timestamp: input.now.addingTimeInterval(-3600), role: "review", candidate: "native/claude-opus-5"), count: 10)
        let demand = try input.demand()
        XCTAssertEqual(demand.pools[Self.claude], .init(rateMilli: 11000, windowDecisions: 11, ledgerDecisions: 11))
        XCTAssertEqual(demand.pools[Self.chatGPT], .init(rateMilli: 10000, windowDecisions: 1, ledgerDecisions: 1))
        let prices = try input.prices(demand)
        XCTAssertEqual(prices.first { $0.pool == Self.claude }?.price, 538)
        try write("forecast-mixed-pool-eviction", input: input, demand: demand, prices: prices)
    }

    private func stateOracle(resetSeconds: Int? = 3600, state: BrokerQuotaState = .fresh) -> GoldenOracle {
        let now = BrokerFixture.now
        let reset = resetSeconds.map { now.addingTimeInterval(Double($0)) }
        return GoldenOracle(BrokerFixture.oracle(
            accounts: [BrokerFixture.account(label: "Account A", state: state, weekly: 20, weeklyResetAt: reset)],
            chatGPTState: state,
            chatGPTRows: [.init(label: "Weekly", usedPercent: 10, resetAt: reset,
                               windowRole: .chatGPTWeekly, account: "Workspace A")], chatGPTConfigured: true))
    }

    func test_forecastStatesAndHistoryEdges() throws {
        var cases: [(String, Input, String, Int, Int)] = []
        var input = Self.basic()
        cases.append(("forecast-state-ok", input, "ok", 104, 87))
        input.policy.thresholds.preferExpiringQuota = false
        cases.append(("forecast-state-pricing-off", input, "pricing_off", 1000, 1000))
        input = Self.basic()
        let cutoff = String(ISO8601DateFormatter().string(from: input.now.addingTimeInterval(-2 * 86400)).prefix(10))
        input.days = input.days.filter { $0.day >= cutoff }
        cases.append(("forecast-state-short-history", input, "short_history", 1000, 1000))
        input = Self.basic(); input.oracle = stateOracle(state: .stale)
        cases.append(("forecast-state-stale-oracle", input, "stale_oracle", 1000, 1000))
        input = Self.basic(); input.oracle = stateOracle(resetSeconds: nil)
        cases.append(("forecast-state-no-reset", input, "no_reset", 1000, 1000))
        input = Self.basic(); input.oracle = stateOracle(resetSeconds: 561601)
        cases.append(("forecast-state-early-window", input, "early_window", 1000, 1000))
        input = Self.basic(); input.records = Array(input.records.prefix(4))
        cases.append(("forecast-state-new-pool", input, "new_pool", 1000, 1000))
        input = Self.basic(); input.oracle = stateOracle(resetSeconds: 86400)
        input.records = input.records.map {
            .init(timestamp: input.now.addingTimeInterval(-6.5 * 86400), role: $0.role, candidate: $0.candidate)
        }
        cases.append(("forecast-state-uncalibrated", input, "uncalibrated", 1000, 1000))
        input = Self.basic(); input.records = []; input.days = []
        cases.append(("forecast-empty", input, "short_history", 1000, 1000))
        input = Self.basic(); input.records = Array(input.records.dropFirst(10))
        cases.append(("forecast-truncated-ring", input, "ok", 123, 87))
        input = Self.basic()
        let first = String(ISO8601DateFormatter().string(from: input.now.addingTimeInterval(-7 * 86400)).prefix(10))
        let last = String(ISO8601DateFormatter().string(from: input.now.addingTimeInterval(-86400)).prefix(10))
        input.days = input.days.filter { $0.day == first || $0.day == last }
        cases.append(("forecast-gap-days", input, "ok", 84, 69))
        input = Self.basic(); input.rollupLoadFailed = true
        cases.append(("forecast-load-failed", input, "short_history", 1000, 1000))
        for (name, input, state, claudePrice, chatGPTPrice) in cases {
            let demand = try input.demand()
            let prices = try input.prices(demand)
            XCTAssertEqual(prices.count, 2, name)
            for row in prices {
                XCTAssertEqual(row.forecast.state, state, name)
                XCTAssertEqual(row.price, row.pool == Self.claude ? claudePrice : chatGPTPrice, name)
            }
            if name == "forecast-state-short-history" { XCTAssertEqual(demand.historyDays, 2, name) }
            if name == "forecast-empty" { XCTAssertTrue(demand.roles.isEmpty, name); XCTAssertEqual(demand.historyDays, 0, name) }
            if name == "forecast-gap-days" {
                XCTAssertEqual(demand.historyDays, 7, name); XCTAssertEqual(demand.roles["standard"], 285, name)
                XCTAssertEqual(demand.pools[Self.claude]?.rateMilli, 427, name)
            }
            if name == "forecast-state-uncalibrated" {
                XCTAssertEqual(demand.pools[Self.claude]?.windowDecisions, 0, name)
                XCTAssertGreaterThan(demand.pools[Self.claude]?.rateMilli ?? 0, 0, name)
            }
            try write(name, input: input, demand: demand, prices: prices)
        }
    }
}
