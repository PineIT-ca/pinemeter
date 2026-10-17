import Foundation
import XCTest
@testable import Pinemeter

final class BrokerOutcomeTrendTests: XCTestCase {
    static let now = ISO8601DateFormatter().date(from: "2023-11-14T22:13:20Z")!

    static func bucket(age: Int, model: String = "model-1", effort: String = "high",
                       role: String = "review", basis: String = "quality", picks: Int = 14) -> BrokerOutcomeBucket {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return BrokerOutcomeBucket(day: BrokerOutcomeStore.day(calendar.date(byAdding: .day, value: -age, to: now)!),
                                   role: role, model: model, effort: effort, pickBasis: basis, picks: picks)
    }

    static var basic: BrokerOutcomeRollup {
        var recent = bucket(age: 0)
        recent.completed = 10; recent.failed = 2; recent.exhausted = 2
        recent.tokenSamples = 10; recent.tokensTotal = 512_340
        recent.outputSamples = 10; recent.outputTokens = 12_340
        recent.durationSamples = 10; recent.durationMSTotal = 1_340_000
        recent.backupRuns = 2; recent.verdictsReceived["pass"] = 5
        recent.verdictsReceived["pass-with-nits"] = 1; recent.verdictsReceived["fail"] = 1
        recent.servedModels = ["provider-1": 6]; recent.servedModelsOther = 1
        var baseline = recent
        baseline.day = bucket(age: 34).day; baseline.picks = 56
        baseline.completed = 48; baseline.failed = 4; baseline.exhausted = 4
        baseline.tokensTotal = 478_340; baseline.durationMSTotal = 1_220_000
        return BrokerOutcomeRollup(buckets: [baseline, recent, bucket(age: 0, model: "model-2", picks: 4)])
    }

    static func assertBasic(_ trend: BrokerOutcomeTrend, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(trend.state, "populated", file: file, line: line)
        XCTAssertEqual(trend.role, "review", file: file, line: line)
        XCTAssertEqual(trend.groups.map(\.model), ["model-1", "model-2"], file: file, line: line)
        let rows = trend.groups[0].rows
        XCTAssertEqual(rows.map(\.label), ["Tasks per day", "Reported", "Failed", "Review passed", "Tokens per task",
                                          "Output tokens per task", "Duration", "Ran on a backup", "Served model"], file: file, line: line)
        XCTAssertEqual(rows.map(\.recent), ["2.0", "100%", "29%", "86%", "51K", "1.2K", "2m 14s", "14%", "provider-1 86%"], file: file, line: line)
        XCTAssertEqual(rows.map(\.baseline), ["2.0", "100%", "14%", "86%", "48K", "1.2K", "2m 2s", "4%", "provider-1 86%"], file: file, line: line)
        XCTAssertEqual(rows.map(\.change), ["0.0", "0 pts", "+15 pts", "0 pts", "+3.4K", "0", "+12s", "+10 pts", "Same"], file: file, line: line)
        XCTAssertTrue(trend.groups[1].rows.allSatisfy { $0.recent == "—" && $0.baseline == "—" && $0.change == "—" }, file: file, line: line)
    }

    func test_basic() {
        Self.assertBasic(BrokerOutcomeTrend.make(rollup: Self.basic, now: Self.now, role: nil, includeAllReasons: false))
    }

    struct Case {
        let name: String
        let rollup: BrokerOutcomeRollup
        var role: String? = nil
        var all = false
        var now: Date = BrokerOutcomeTrendTests.now
        var trend: BrokerOutcomeTrend { BrokerOutcomeTrend.make(rollup: rollup, now: now, role: role, includeAllReasons: all) }
    }
    static func sampled(age: Int, model: String = "model-1", count: Int) -> BrokerOutcomeBucket {
        var b = bucket(age: age, model: model, picks: count)
        b.completed = count; b.tokenSamples = count; b.tokensTotal = count * 1234
        b.outputSamples = count; b.outputTokens = count * 999
        b.durationSamples = count; b.durationMSTotal = count * 48_000
        b.verdictsReceived["pass"] = count; b.servedModels = ["provider-1": count]
        return b
    }
    static var cases: [Case] {
        var cases = [Case(name: "trend-basic", rollup: basic)]
        cases.append(Case(name: "trend-window-edges", rollup: .init(buckets:
            [0, 6, 7, 34, 35, -1].map { bucket(age: $0, picks: $0 == 35 || $0 == -1 ? 999 : 14) })))
        var minimums: [BrokerOutcomeBucket] = []
        for count in [4, 5] {
            minimums += [sampled(age: 0, model: "samples-\(count)", count: count), sampled(age: 34, model: "samples-\(count)", count: 5)]
        }
        // Each source independently falls below the minimum, then rises in the baseline.
        for i in 0..<7 {
            let model = "source-\(i)"
            var recent = sampled(age: 0, model: model, count: 5)
            switch i {
            case 0: recent.picks = 4
            case 1: recent.completed = 4
            case 2: recent.verdictsReceived["pass"] = 4
            case 3: recent.tokenSamples = 4
            case 4: recent.outputSamples = 4
            case 5: recent.durationSamples = 4
            default: recent.servedModels = ["provider-1": 4]
            }
            minimums += [recent, sampled(age: 34, model: model, count: 5)]
            var thinBaseline = recent
            thinBaseline.model = "baseline-\(i)"; thinBaseline.day = bucket(age: 34).day
            minimums += [sampled(age: 0, model: thinBaseline.model, count: 5), thinBaseline]
        }
        cases.append(Case(name: "trend-min-samples", rollup: .init(buckets: minimums)))
        cases.append(Case(name: "trend-short-history", rollup: .init(buckets: [bucket(age: 2)])))
        let order = ["default", "unknown-z", "xhigh", "high", "medium", "low", "unknown-a"].map {
            bucket(age: 0, model: "claude-opus-5-5", effort: $0)
        } + [bucket(age: 0, model: "claude-opus-5-10")]
        cases.append(Case(name: "trend-order", rollup: .init(buckets: order.reversed())))
        let reasons = [bucket(age: 34), bucket(age: 0), bucket(age: 0, basis: "quota", picks: 7),
                       bucket(age: 0, model: "quota-model", basis: "quota"),
                       bucket(age: 0, model: "override-model", basis: "human-override"),
                       bucket(age: 0, model: "drift-model", basis: "drift")]
        cases.append(Case(name: "trend-all-reasons", rollup: .init(buckets: reasons), all: true))
        cases.append(Case(name: "trend-quality-only", rollup: .init(buckets: reasons)))
        let roles = [bucket(age: 0, role: "z-role", picks: 5), bucket(age: 0, role: "a-role", basis: "quota", picks: 5),
                     bucket(age: 7, role: "baseline-role", picks: 100), bucket(age: 0, role: "b-role", picks: 6)]
        cases.append(Case(name: "trend-default-role", rollup: .init(buckets: roles), role: "missing"))
        cases.append(Case(name: "trend-role-tie", rollup: .init(buckets: Array(roles.prefix(3)))))
        cases.append(Case(name: "trend-requested-role", rollup: .init(buckets: roles), role: "z-role"))
        cases.append(Case(name: "trend-no-data", rollup: .init(buckets: [bucket(age: 35), bucket(age: -1), bucket(age: 0, picks: 0)])))
        cases.append(Case(name: "trend-filtered-empty", rollup: .init(buckets: [bucket(age: 0, basis: "quota")])))
        var recent = sampled(age: 0, count: 5), baseline = sampled(age: 34, count: 5)
        recent.servedModels = ["provider-a": 3, "provider-z": 3]; recent.servedModelsOther = 1
        baseline.servedModels = ["provider-z": 5]
        cases.append(Case(name: "trend-model-changed", rollup: .init(buckets: [baseline, recent])))
        let max = BrokerOutcomeTrend.maxCounter
        let saturated = [0, 1, 7, 34].map { age in
            var b = bucket(age: age, picks: max)
            b.completed = max; b.failed = max; b.exhausted = max; b.backupRuns = max
            b.tokenSamples = 5; b.tokensTotal = max; b.outputSamples = 5; b.outputTokens = max
            b.durationSamples = 5; b.durationMSTotal = max
            b.verdictsReceived = ["pass": max, "pass-with-nits": max, "fail": max, "inconclusive": max]
            b.servedModels = ["provider-a": max, "provider-z": max]; b.servedModelsOther = max
            return b
        }
        cases.append(Case(name: "trend-saturated", rollup: .init(buckets: saturated)))
        var roundedRecent = sampled(age: 0, count: 8), roundedBaseline = sampled(age: 34, count: 8)
        roundedRecent.completed = 5; roundedBaseline.completed = 6
        roundedRecent.tokensTotal = 803; roundedBaseline.tokensTotal = 804
        roundedRecent.durationMSTotal = 3996; roundedBaseline.durationMSTotal = 3995
        cases.append(Case(name: "trend-rounded-changes", rollup: .init(buckets: [roundedRecent, roundedBaseline])))
        cases.append(Case(name: "trend-unicode-order", rollup: .init(buckets:
            ["İ-2", "i\u{0307}-2", "É-2", "é-2", "Σ-2", "σ-2", "model-0002", "model-2",
             "model-999999999999999999999999999999", "model-1000000000000000000000000000000"].map { bucket(age: 0, model: $0) })))
        // Offset crosses the local day, but today and windows remain UTC.
        cases.append(Case(name: "trend-utc-day", rollup: .init(buckets: [bucket(age: 0)]),
                          now: ISO8601DateFormatter().date(from: "2023-11-15T00:30:00+02:00")!))
        return cases
    }

    static func assertCase(_ c: Case, file: StaticString = #filePath, line: UInt = #line) {
        let t = c.trend
        XCTAssertEqual(t.today, "2023-11-14", c.name, file: file, line: line)
        switch c.name {
        case "trend-basic": assertBasic(t, file: file, line: line)
        case "trend-window-edges":
            XCTAssertEqual(t.groups[0].recentTasks, 28, file: file, line: line)
            XCTAssertEqual(t.groups[0].rows[0].baselineSamples, 28, file: file, line: line)
            XCTAssertEqual(t.groups[0].rows[0].recent, "4.0", file: file, line: line)
            XCTAssertEqual(t.groups[0].rows[0].baseline, "1.0", file: file, line: line)
        case "trend-min-samples":
            for g in t.groups {
                for row in g.rows {
                    XCTAssertEqual(row.recent == "—", row.recentSamples < 5, g.model + row.label, file: file, line: line)
                    XCTAssertEqual(row.baseline == "—", row.baselineSamples < 5, g.model + row.label, file: file, line: line)
                    XCTAssertEqual(row.change == "—", row.recentSamples < 5 || row.baselineSamples < 5, file: file, line: line)
                }
            }
        case "trend-short-history":
            XCTAssertEqual(t.groups[0].rows[0].recent, "4.7", file: file, line: line)
            XCTAssertEqual(t.groups[0].rows[0].baseline, "—", file: file, line: line)
        case "trend-order":
            XCTAssertEqual(t.groups.map(\.effort), ["low", "medium", "high", "xhigh", "unknown-a", "unknown-z", "default", "high"], file: file, line: line)
            XCTAssertEqual(t.groups.last?.model, "claude-opus-5-10", file: file, line: line)
        case "trend-all-reasons":
            XCTAssertEqual(t.groups.map(\.model), ["drift-model", "model-1", "override-model", "quota-model"], file: file, line: line)
            XCTAssertEqual(t.groups[1].recentTasks, 21, file: file, line: line)
        case "trend-quality-only":
            XCTAssertEqual(t.groups.map(\.model), ["model-1"], file: file, line: line)
            XCTAssertEqual(t.groups[0].recentTasks, 14, file: file, line: line)
            XCTAssertEqual(t.roles[0].recentPicks, 63, file: file, line: line)
        case "trend-default-role":
            XCTAssertEqual(t.role, "b-role", file: file, line: line)
            XCTAssertEqual(t.roles.map(\.role), ["a-role", "b-role", "baseline-role", "z-role"], file: file, line: line)
        case "trend-role-tie":
            XCTAssertEqual(t.role, "a-role", file: file, line: line)
            XCTAssertEqual(t.state, "filtered-empty", file: file, line: line)
        case "trend-requested-role": XCTAssertEqual(t.role, "z-role", file: file, line: line)
        case "trend-no-data":
            XCTAssertEqual(t.state, "no-data", file: file, line: line)
            XCTAssertNil(t.role, file: file, line: line)
            XCTAssertTrue(t.groups.isEmpty && t.roles.isEmpty, file: file, line: line)
        case "trend-filtered-empty":
            XCTAssertEqual(t.state, "filtered-empty", file: file, line: line)
            XCTAssertEqual(t.role, "review", file: file, line: line)
            XCTAssertTrue(t.groups.isEmpty, file: file, line: line)
        case "trend-model-changed":
            let row = t.groups[0].rows[8]
            XCTAssertEqual(row.recent, "provider-a 43%", file: file, line: line)
            XCTAssertEqual(row.change, "Model changed", file: file, line: line)
            XCTAssertTrue(row.modelChanged, file: file, line: line)
        case "trend-saturated":
            XCTAssertEqual(t.roles[0].recentPicks, BrokerOutcomeTrend.maxCounter, file: file, line: line)
            XCTAssertEqual(t.groups[0].recentTasks, BrokerOutcomeTrend.maxCounter, file: file, line: line)
            XCTAssertEqual(t.groups[0].rows[1].recent, "100%", file: file, line: line)
            XCTAssertEqual(t.groups[0].rows[2].recent, "100%", file: file, line: line)
            XCTAssertEqual(t.groups[0].rows[4].recent, "900719925M", file: file, line: line)
            XCTAssertEqual(t.groups[0].rows[4].change, "0", file: file, line: line)
            XCTAssertEqual(t.groups[0].rows[8].recentSamples, BrokerOutcomeTrend.maxCounter, file: file, line: line)
        case "trend-rounded-changes":
            let rows = t.groups[0].rows
            XCTAssertEqual(rows[1].recent, "63%", file: file, line: line)
            XCTAssertEqual(rows[1].change, "−12 pts", file: file, line: line)
            XCTAssertEqual(rows[4].recent, "100", file: file, line: line)
            XCTAssertEqual(rows[4].baseline, "101", file: file, line: line)
            XCTAssertEqual(rows[4].change, "−1", file: file, line: line)
            XCTAssertEqual(rows[6].recent, "1s", file: file, line: line)
            XCTAssertEqual(rows[6].baseline, "0s", file: file, line: line)
            XCTAssertEqual(rows[6].change, "+1s", file: file, line: line)
        case "trend-unicode-order":
            XCTAssertEqual(t.groups.map(\.model), ["i\u{0307}-2", "İ-2", "model-0002", "model-2",
                "model-999999999999999999999999999999", "model-1000000000000000000000000000000", "É-2", "é-2", "Σ-2", "σ-2"], file: file, line: line)
        case "trend-utc-day": XCTAssertEqual(t.groups[0].recentTasks, 14, file: file, line: line)
        default: XCTFail("Unasserted trend case: " + c.name, file: file, line: line)
        }
    }
    func test_cases() { for c in Self.cases { Self.assertCase(c) } }

    func test_formatting() {
        for (value, expected) in [(999, "999"), (1000, "1K"), (1234, "1.2K"), (9949, "9.9K"), (9950, "10K"),
                                  (51234, "51K"), (999499, "999K"), (999500, "1M"), (1234567, "1.2M"), (9950000, "10M"),
                                  (1250, "1.3K"), (15000, "15K"), (1250000, "1.3M")] {
            XCTAssertEqual(BrokerOutcomeTrend.compact(value), expected, String(value))
        }
        for (value, expected) in [(0, "0s"), (48, "48s"), (120, "2m"), (134, "2m 14s"), (3600, "1h"), (3780, "1h 3m"), (3785, "1h 3m")] {
            XCTAssertEqual(BrokerOutcomeTrend.duration(value), expected, String(value))
        }
        for (n, d, expected) in [(1, 2, 1), (1, 3, 0), (2, 3, 1), (500, 8, 63), (50, 4, 13), (803, 8, 100), (804, 8, 101),
                                  (3996, 8, 500), (3995, 8, 499), (0, 7, 0), (9_007_199_254_740_991, 1, 9_007_199_254_740_991)] {
            XCTAssertEqual(BrokerOutcomeTrend.rounded(n, over: d), expected)
        }
        let formats: [(Int, (Int) -> String, String)] = [
            (12, BrokerOutcomeTrend.duration, "+12s"), (-65, BrokerOutcomeTrend.duration, "−1m 5s"),
            (0, BrokerOutcomeTrend.duration, "0s"), (0, BrokerOutcomeTrend.tenths, "0.0"),
            (0, { "\($0) pts" }, "0 pts"), (0, BrokerOutcomeTrend.compact, "0"),
            (-4, { "\($0) pts" }, "−4 pts"), (6, BrokerOutcomeTrend.tenths, "+0.6")
        ]
        for (value, format, expected) in formats { XCTAssertEqual(BrokerOutcomeTrend.signed(value, format: format), expected) }
    }

    func test_modelValuesNeverCombineWithOtherModels() {
        let original = Self.cases[0].trend.groups[0]
        var rollup = Self.basic
        rollup.buckets.removeAll { $0.model == "model-2" }
        XCTAssertEqual(BrokerOutcomeTrend.make(rollup: rollup, now: Self.now, role: nil, includeAllReasons: false).groups[0], original)
        for age in [0, 34] { rollup.buckets.append(Self.sampled(age: age, model: "another-model", count: 10000)) }
        let withOther = BrokerOutcomeTrend.make(rollup: rollup, now: Self.now, role: nil, includeAllReasons: false)
        XCTAssertEqual(withOther.groups.first { $0.model == "model-1" }, original)
        XCTAssertEqual(withOther.groups.map(\.model), ["another-model", "model-1"])
    }

    func test_historyStartUsesWholeRollupAndBaselineOnlyGroupsRemain() {
        var history = Self.bucket(age: 34, role: "another-role", basis: "quota", picks: 0)
        history.completed = 1
        let trend = BrokerOutcomeTrend.make(rollup: .init(buckets: [Self.bucket(age: 2), history]), now: Self.now, role: "review", includeAllReasons: false)
        XCTAssertEqual(trend.groups[0].rows[0].recent, "2.0")
        let baseline = BrokerOutcomeTrend.make(rollup: .init(buckets: [Self.sampled(age: 34, count: 5)]), now: Self.now, role: nil, includeAllReasons: false)
        XCTAssertEqual(baseline.groups[0].recentTasks, 0)
        XCTAssertTrue(baseline.groups[0].rows.allSatisfy { $0.recent == "—" && $0.change == "—" })
        XCTAssertTrue(baseline.groups[0].rows.allSatisfy { $0.baseline != "—" })
    }

    func test_servedModelOtherOnlyAndZeroNamedCounts() {
        var b = Self.bucket(age: 0)
        b.servedModelsOther = 5; b.servedModels = ["provider-1": 0]
        let trend = BrokerOutcomeTrend.make(rollup: .init(buckets: [b]), now: Self.now, role: nil, includeAllReasons: false)
        XCTAssertEqual(trend.groups[0].rows[8].recentSamples, 5)
        XCTAssertEqual(trend.groups[0].rows[8].recent, "—")
        XCTAssertFalse(trend.groups[0].rows[8].modelChanged)
    }
}
