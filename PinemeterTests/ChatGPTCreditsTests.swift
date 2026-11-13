import Foundation
import XCTest
@testable import Pinemeter

final class ChatGPTCreditsTests: XCTestCase {
    private let now = BrokerFixture.now

    private func decode(_ json: String) throws -> ChatGPTWHAMUsageResponse {
        try JSONDecoder().decode(ChatGPTWHAMUsageResponse.self, from: Data(json.utf8))
    }

    private func usageJSON(credits: String?) -> String {
        let tail = credits.map { ",\"credits\":\($0)" } ?? ""
        return "{\"rate_limit\":{\"primary_window\":{\"used_percent\":100,\"limit_window_seconds\":604800}}\(tail)}"
    }

    // MARK: decoding

    func test_decodesCreditsWithStringAndNumberBalance() throws {
        let text = try decode(usageJSON(credits: #"{"has_credits":true,"unlimited":false,"balance":"42.5"}"#))
        XCTAssertEqual(text.credits, ChatGPTCredits(hasCredits: true, unlimited: false, balance: 42.5))
        let number = try decode(usageJSON(credits: #"{"has_credits":true,"unlimited":false,"balance":7}"#))
        XCTAssertEqual(number.credits?.balance, 7)
    }

    func test_absentOrMalformedCredits_decodeWithoutBreakingUsage() throws {
        let absent = try decode(usageJSON(credits: nil))
        XCTAssertNil(absent.credits)
        XCTAssertNil(try absent.toDomain(lastUpdated: now).credits)
        let null = try decode(usageJSON(credits: "null"))
        XCTAssertNil(null.credits)
        let odd = try decode(usageJSON(credits: "\"nope\""))
        XCTAssertNil(odd.credits)
        let empty = try decode(usageJSON(credits: "{}"))
        XCTAssertNil(empty.credits)
        XCTAssertEqual(try odd.toDomain(lastUpdated: now).rows.count, 1)
    }

    func test_cacheRoundTrip_andOldCacheWithoutCredits() throws {
        let data = ChatGPTUsageData(rows: [.init(label: "Codex weekly", usedPercent: 10, resetAt: nil)],
                                    lastUpdated: now, credits: .init(hasCredits: true, balance: 3))
        let encoded = try JSONEncoder().encode(data)
        XCTAssertEqual(try JSONDecoder().decode(ChatGPTUsageData.self, from: encoded), data)
        let plain = ChatGPTUsageData(rows: data.rows, lastUpdated: now)
        let plainJSON = try String(decoding: JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("credits"))
        XCTAssertNil(try JSONDecoder().decode(ChatGPTUsageData.self, from: Data(plainJSON.utf8)).credits)
    }

    // MARK: tracker

    private func tracker(_ points: [(TimeInterval, Double)]) -> ChatGPTCreditTracker {
        var tracker = ChatGPTCreditTracker()
        for (offset, balance) in points { tracker.record(balance: balance, at: now.addingTimeInterval(offset)) }
        return tracker
    }

    func test_burnAndProjection_fromSuccessiveObservations() throws {
        let t = tracker([(0, 100), (3600, 90), (7200, 80)])
        XCTAssertEqual(try XCTUnwrap(t.burnPerHour), 10, accuracy: 1e-9)
        let status = t.status(for: .init(hasCredits: true, balance: 80))
        XCTAssertEqual(status.exhaustsAt, now.addingTimeInterval(7200 + 8 * 3600))
    }

    func test_notEnoughObservations_isUnknown() {
        XCTAssertNil(tracker([]).burnPerHour)
        XCTAssertNil(tracker([(0, 100)]).burnPerHour)
        XCTAssertNil(tracker([(0, 100), (60, 99)]).burnPerHour)
        let status = tracker([(0, 100)]).status(for: .init(hasCredits: true, balance: 100))
        XCTAssertNil(status.burnPerHour)
        XCTAssertNil(status.exhaustsAt)
    }

    func test_topUpResetsSeries_burnNeverNegative() throws {
        let t = tracker([(0, 100), (3600, 90), (7200, 500)])
        XCTAssertNil(t.burnPerHour)
        let later = tracker([(0, 100), (3600, 90), (7200, 500), (10800, 490)])
        XCTAssertEqual(try XCTUnwrap(later.burnPerHour), 10, accuracy: 1e-9)
        for points in [[(0.0, 5.0), (3600.0, 5.0)], [(0.0, 5.0), (3600.0, 9.0)]] {
            XCTAssertGreaterThanOrEqual(tracker(points).burnPerHour ?? 0, 0)
        }
        let flat = tracker([(0, 5), (3600, 5)])
        XCTAssertEqual(flat.burnPerHour, 0)
        XCTAssertNil(flat.status(for: .init(hasCredits: true, balance: 5)).exhaustsAt)
    }

    func test_missingBalance_reportsNoBurnOrExhaustion_evenWithStaleSeries() {
        let t = tracker([(0, 100), (3600, 90)])
        let status = t.status(for: .init(hasCredits: true, balance: nil))
        XCTAssertNil(status.burnPerHour)
        XCTAssertNil(status.exhaustsAt)
        var folded = t
        folded.observe(.init(hasCredits: true, balance: nil), at: now.addingTimeInterval(7200))
        XCTAssertEqual(folded.observations.count, 2)
    }

    func test_unlimitedCredits_resetTheSeries() {
        var t = tracker([(0, 100), (3600, 90)])
        t.observe(.init(hasCredits: true, unlimited: true, balance: 90), at: now.addingTimeInterval(7200))
        XCTAssertTrue(t.observations.isEmpty)
        XCTAssertNil(t.burnPerHour)
        t.observe(.init(hasCredits: true, balance: 50), at: now.addingTimeInterval(10_800))
        XCTAssertNil(t.burnPerHour)
    }

    func test_unlimitedCredits_neverProjectExhaustion() {
        let t = tracker([(0, 100), (3600, 50)])
        let status = t.status(for: .init(hasCredits: true, unlimited: true, balance: 50))
        XCTAssertNil(status.exhaustsAt)
        XCTAssertNil(status.burnPerHour)
        XCTAssertTrue(status.unlimited)
    }

    // MARK: pricing

    private let weeklyReset = BrokerFixture.now.addingTimeInterval(48 * 3600)

    private func oracle(used: Double, credits: BrokerCreditsStatus?) -> OracleSnapshot {
        BrokerFixture.oracle(chatGPTRows: [.init(label: "Codex weekly", usedPercent: used, resetAt: weeklyReset,
            windowRole: .chatGPTWeekly, account: "Workspace A", credits: credits)], chatGPTConfigured: true)
    }

    private func pool(used: Double, credits: BrokerCreditsStatus?) throws -> BrokerPoolPrice {
        var policy = BrokerFixture.policy(roles: [:])
        policy.thresholds.preferExpiringQuota = true
        let rows = BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle(used: used, credits: credits),
                                                demand: nil, now: now)
        return try XCTUnwrap(rows.first)
    }

    private let funded = BrokerCreditsStatus(hasCredits: true, unlimited: false, balance: 40,
                                             burnPerHour: 2, exhaustsAt: BrokerFixture.now.addingTimeInterval(72_000))

    func test_exhaustedWindowWithCredits_isCreditFundedAndExposesCredits() throws {
        let row = try pool(used: 100, credits: funded)
        XCTAssertEqual(row.forecast.state, "credit_funded")
        XCTAssertEqual(row.priceLevel, 4)
        XCTAssertEqual(row.credits, funded)
        let json = try String(decoding: JSONEncoder().encode(row), as: UTF8.self)
        XCTAssertTrue(json.contains("\"burnPerHour\":2"))
    }

    func test_exhaustedWindowWithoutCredits_orWithEmptyCredits_isNotCreditFunded() throws {
        XCTAssertNotEqual(try pool(used: 100, credits: nil).forecast.state, "credit_funded")
        let empty = BrokerCreditsStatus(hasCredits: false, unlimited: false, balance: 0, burnPerHour: nil, exhaustsAt: nil)
        XCTAssertNotEqual(try pool(used: 100, credits: empty).forecast.state, "credit_funded")
    }

    func test_planFundedPool_isNeverDemotedByCredits() throws {
        let withCredits = try pool(used: 60, credits: funded)
        let without = try pool(used: 60, credits: nil)
        XCTAssertNotEqual(withCredits.forecast.state, "credit_funded")
        XCTAssertEqual(withCredits.price, without.price)
        XCTAssertEqual(withCredits.priceLevel, without.priceLevel)
        XCTAssertEqual(withCredits.forecast, without.forecast)
    }

    func test_absentCredits_encodeExactlyAsBefore() throws {
        let json = try String(decoding: JSONEncoder().encode(pool(used: 30, credits: nil)), as: UTF8.self)
        XCTAssertFalse(json.contains("credits"))
    }

    func test_creditFundedPool_losesToPlanFundedCandidate_evenWithPricingOff() throws {
        var policy = BrokerFixture.policy(
            roles: ["review": ["codex/gpt-6-astra", "native/claude-opus-5-5"]],
            models: ["gpt-6-astra": .init(quota: .chatGPT(labelContains: nil))])
        policy.equalQuality = ["review": [["claude-opus-5-5", "gpt-6-astra"]]]
        policy.agentModelAliases["claude-opus-5-5"] = "opus"
        let claude = BrokerFixture.account(label: "Account A", weekly: 20,
                                           weeklyResetAt: now.addingTimeInterval(60 * 3600))
        func rows(credits: BrokerCreditsStatus?) throws -> [BrokerScoringEngine.ScoredRow] {
            let oracle = BrokerFixture.oracle(accounts: [claude], chatGPTRows: [.init(
                label: "Codex weekly", usedPercent: 100, resetAt: weeklyReset, windowRole: .chatGPTWeekly,
                account: "Workspace A", credits: credits)], chatGPTConfigured: true)
            let ranked = BrokerFixture.candidates(["codex/gpt-6-astra", "native/claude-opus-5-5"])
            return BrokerScoringEngine.scoredRows(ranked, role: "review", policy: policy, oracle: oracle,
                                                  demand: nil, now: now)
        }
        let withCredits = try rows(credits: funded)
        let without = try rows(credits: nil)
        let codexWith = try XCTUnwrap(withCredits.first { $0.model == "gpt-6-astra" })
        let codexWithout = try XCTUnwrap(without.first { $0.model == "gpt-6-astra" })
        let claudeWith = try XCTUnwrap(withCredits.first { $0.model == "claude-opus-5-5" })
        let claudeWithout = try XCTUnwrap(without.first { $0.model == "claude-opus-5-5" })
        XCTAssertEqual(claudeWith.score, claudeWithout.score)
        XCTAssertLessThan(codexWith.score, codexWithout.score)
        XCTAssertLessThan(codexWith.score, claudeWith.score, "\(codexWith) \(claudeWith) \(codexWithout)")
    }
}
