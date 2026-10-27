import Foundation

/// Output-only history. Every group compares one model and effort with itself.
struct BrokerOutcomeTrend: Codable, Equatable, Sendable {
    struct Role: Codable, Equatable, Sendable {
        let role: String
        let recentPicks: Int
        enum CodingKeys: String, CodingKey { case role; case recentPicks = "recent_picks" }
    }
    struct Group: Codable, Equatable, Sendable {
        let model: String
        let effort: String
        let recentTasks: Int
        let rows: [Row]
        enum CodingKeys: String, CodingKey { case model, effort, rows; case recentTasks = "recent_tasks" }
    }
    struct Row: Codable, Equatable, Sendable {
        let label: String
        let recent: String
        let baseline: String
        let change: String
        let modelChanged: Bool
        let recentSamples: Int
        let baselineSamples: Int
        enum CodingKeys: String, CodingKey {
            case label, recent, baseline, change
            case modelChanged = "model_changed"
            case recentSamples = "recent_samples"
            case baselineSamples = "baseline_samples"
        }
    }
    let today: String
    let includeAllReasons: Bool
    let role: String?
    let roles: [Role]
    let state: String
    let groups: [Group]
    enum CodingKeys: String, CodingKey {
        case today, role, roles, state, groups
        case includeAllReasons = "include_all_reasons"
    }

    static let maxCounter = 9_007_199_254_740_991
    private static func add(_ a: Int, _ b: Int) -> Int { a + min(b, maxCounter - a) }
    private static func sum(_ values: some Sequence<Int>) -> Int { values.reduce(0, add) }
    static func rounded(_ numerator: Int, over denominator: Int) -> Int {
        guard denominator > 0 else { return 0 }
        return numerator / denominator + (numerator % denominator >= denominator / 2 + denominator % 2 ? 1 : 0)
    }
    static func tenths(_ value: Int) -> String { "\(value / 10).\(value % 10)" }
    static func compact(_ value: Int) -> String {
        let divisor: Int
        let suffix: String
        let decimal: Bool
        switch value {
        case ..<1000: return String(value)
        case ..<9950: (divisor, suffix, decimal) = (1000, "K", true)
        case ..<999500: (divisor, suffix, decimal) = (1000, "K", false)
        case ..<9950000: (divisor, suffix, decimal) = (1000000, "M", true)
        default: (divisor, suffix, decimal) = (1000000, "M", false)
        }
        let units = rounded(value * (decimal ? 10 : 1), over: divisor)
        return (decimal ? (units % 10 == 0 ? String(units / 10) : tenths(units)) : String(units)) + suffix
    }
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" + (seconds % 60 == 0 ? "" : " \(seconds % 60)s") }
        return "\(seconds / 3600)h" + (seconds % 3600 / 60 == 0 ? "" : " \(seconds % 3600 / 60)m")
    }
    static func signed(_ value: Int, format: (Int) -> String) -> String {
        (value > 0 ? "+" : value < 0 ? "−" : "") + format(abs(value))
    }

    private struct Window {
        var picks = 0, completed = 0, failed = 0, exhausted = 0, backupRuns = 0
        var tokenSamples = 0, tokensTotal = 0, outputSamples = 0, outputTokens = 0
        var durationSamples = 0, durationMSTotal = 0, servedModelsOther = 0
        var verdictsReceived: [String: Int] = [:]
        var servedModels: [String: Int] = [:]
        mutating func append(_ b: BrokerOutcomeBucket) {
            picks = add(picks, b.picks); completed = add(completed, b.completed)
            failed = add(failed, b.failed); exhausted = add(exhausted, b.exhausted)
            backupRuns = add(backupRuns, b.backupRuns)
            tokenSamples = add(tokenSamples, b.tokenSamples); tokensTotal = add(tokensTotal, b.tokensTotal)
            outputSamples = add(outputSamples, b.outputSamples); outputTokens = add(outputTokens, b.outputTokens)
            durationSamples = add(durationSamples, b.durationSamples); durationMSTotal = add(durationMSTotal, b.durationMSTotal)
            servedModelsOther = add(servedModelsOther, b.servedModelsOther)
            for (key, count) in b.verdictsReceived { verdictsReceived[key] = add(verdictsReceived[key, default: 0], count) }
            for (key, count) in b.servedModels { servedModels[key] = add(servedModels[key, default: 0], count) }
        }
        var terminal: Int { sum([completed, failed, exhausted]) }
        var failures: Int { add(failed, exhausted) }
        var reviews: Int { sum(verdictsReceived.values) }
        var passes: Int { add(verdictsReceived["pass", default: 0], verdictsReceived["pass-with-nits", default: 0]) }
        var providerReports: Int { add(sum(servedModels.values), servedModelsOther) }
        var topModel: String? {
            servedModels.keys.filter { servedModels[$0, default: 0] > 0 }.sorted {
                let a = servedModels[$0, default: 0], b = servedModels[$1, default: 0]
                return a == b ? bytesBefore($0, $1) : a > b
            }.first
        }
    }
    private static func rows(_ recent: Window, _ baseline: Window, recentDays: Int, baselineDays: Int) -> [Row] {
        func numeric(_ label: String, _ a: Int?, _ b: Int?, samples: (Int, Int),
                     format: (Int) -> String, change: (Int) -> String) -> Row {
            let a = samples.0 >= 5 ? a : nil, b = samples.1 >= 5 ? b : nil
            return Row(label: label, recent: a.map(format) ?? "—", baseline: b.map(format) ?? "—",
                       change: a.flatMap { a in b.map { signed(a - $0, format: change) } } ?? "—",
                       modelChanged: false, recentSamples: samples.0, baselineSamples: samples.1)
        }
        func percent(_ label: String, _ a: Int, _ b: Int, denominators: (Int, Int), samples: (Int, Int)) -> Row {
            numeric(label, denominators.0 > 0 ? rounded(a * 100, over: denominators.0) : nil,
                    denominators.1 > 0 ? rounded(b * 100, over: denominators.1) : nil,
                    samples: samples, format: { "\($0)%" }, change: { "\($0) pts" })
        }
        var result = [
            numeric("Tasks per day", recentDays > 0 ? rounded(recent.picks * 10, over: recentDays) : nil,
                    baselineDays > 0 ? rounded(baseline.picks * 10, over: baselineDays) : nil,
                    samples: (recent.picks, baseline.picks), format: tenths, change: tenths),
            percent("Reported", recent.terminal, baseline.terminal, denominators: (recent.picks, baseline.picks), samples: (recent.picks, baseline.picks)),
            percent("Failed", recent.failures, baseline.failures, denominators: (recent.terminal, baseline.terminal), samples: (recent.terminal, baseline.terminal)),
            percent("Review passed", recent.passes, baseline.passes, denominators: (recent.reviews, baseline.reviews), samples: (recent.reviews, baseline.reviews)),
            numeric("Tokens per task", rounded(recent.tokensTotal, over: recent.tokenSamples), rounded(baseline.tokensTotal, over: baseline.tokenSamples),
                    samples: (recent.tokenSamples, baseline.tokenSamples), format: compact, change: compact),
            numeric("Output tokens per task", rounded(recent.outputTokens, over: recent.outputSamples), rounded(baseline.outputTokens, over: baseline.outputSamples),
                    samples: (recent.outputSamples, baseline.outputSamples), format: compact, change: compact),
            numeric("Duration", rounded(rounded(recent.durationMSTotal, over: recent.durationSamples), over: 1000),
                    rounded(rounded(baseline.durationMSTotal, over: baseline.durationSamples), over: 1000),
                    samples: (recent.durationSamples, baseline.durationSamples), format: duration, change: duration),
            percent("Ran on a backup", recent.backupRuns, baseline.backupRuns, denominators: (recent.terminal, baseline.terminal), samples: (recent.terminal, baseline.terminal))
        ]
        func served(_ window: Window) -> String? {
            guard window.providerReports >= 5, let top = window.topModel else { return nil }
            return top + " \(rounded(window.servedModels[top, default: 0] * 100, over: window.providerReports))%"
        }
        let a = served(recent), b = served(baseline)
        let changed = a != nil && b != nil && recent.topModel != baseline.topModel
        result.append(Row(label: "Served model", recent: a ?? "—", baseline: b ?? "—",
                          change: a == nil || b == nil ? "—" : changed ? "Model changed" : "Same",
                          modelChanged: changed, recentSamples: recent.providerReports, baselineSamples: baseline.providerReports))
        return result
    }

    private static func bytesBefore(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
    // Numeric runs compare without parsing, so arbitrarily long version numbers cannot overflow.
    static func modelBefore(_ a: String, _ b: String) -> Bool {
        func runs(_ text: String) -> [(digits: Bool, bytes: [UInt8])] {
            var result: [(Bool, [UInt8])] = []
            for byte in text.utf8 {
                let digit = (48...57).contains(byte)
                if result.last?.0 == digit { result[result.count - 1].1.append(byte) }
                else { result.append((digit, [byte])) }
            }
            return result
        }
        let left = runs(a), right = runs(b)
        for (l, r) in zip(left, right) {
            var x = l.bytes, y = r.bytes
            if l.digits && r.digits {
                x = Array(x.drop(while: { $0 == 48 })); y = Array(y.drop(while: { $0 == 48 }))
                if x.count != y.count { return x.count < y.count }
            } else {
                // Scalar lowercase avoids locale and contextual case conversion.
                x = Array(String(decoding: x, as: UTF8.self).unicodeScalars.map { String($0).lowercased() }.joined().utf8)
                y = Array(String(decoding: y, as: UTF8.self).unicodeScalars.map { String($0).lowercased() }.joined().utf8)
            }
            if x != y { return x.lexicographicallyPrecedes(y) }
        }
        if left.count != right.count { return left.count < right.count }
        return bytesBefore(a, b)
    }
    private static func effortBefore(_ a: String, _ b: String) -> Bool {
        func rank(_ value: String) -> Int { ["low", "medium", "high", "xhigh"].firstIndex(of: value) ?? (value == "default" ? 5 : 4) }
        return rank(a) == rank(b) ? bytesBefore(a, b) : rank(a) < rank(b)
    }
    static func make(rollup: BrokerOutcomeRollup, now: Date, role requestedRole: String?, includeAllReasons: Bool) -> BrokerOutcomeTrend {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = (0..<35).map { BrokerOutcomeStore.day(calendar.date(byAdding: .day, value: -$0, to: now)!) }
        let ages = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element, $0.offset) })
        let earliest = rollup.buckets.map(\.day).min()
        // Count retained calendar days independently of role and reason filters.
        let historyRecent = days.prefix(7).filter { day in earliest.map { day >= $0 } ?? false }.count
        let historyBaseline = days.dropFirst(7).filter { day in earliest.map { day >= $0 } ?? false }.count
        let buckets = rollup.buckets.filter { ages[$0.day] != nil }
        var rolePicks: [Data: Role] = [:]
        for b in buckets where b.picks > 0 {
            let key = Data(b.role.utf8)
            let previous = rolePicks[key]?.recentPicks ?? 0
            rolePicks[key] = Role(role: b.role, recentPicks: add(previous, ages[b.day]! < 7 ? b.picks : 0))
        }
        let roles = rolePicks.values.sorted { bytesBefore($0.role, $1.role) }
        let selected = requestedRole.flatMap { rolePicks[Data($0.utf8)]?.role } ?? roles.sorted {
            $0.recentPicks == $1.recentPicks ? bytesBefore($0.role, $1.role) : $0.recentPicks > $1.recentPicks
        }.first?.role
        var groups: [Group] = []
        if let selected {
            let filtered = buckets.filter { $0.role.utf8.elementsEqual(selected.utf8) && (includeAllReasons || $0.pickBasis == "quality") }
            let pairs = Dictionary(grouping: filtered, by: { [Data($0.model.utf8), Data($0.effort.utf8)] })
            for group in pairs.values where group.contains(where: { $0.picks > 0 }) {
                var recent = Window(), baseline = Window()
                for b in group { if ages[b.day]! < 7 { recent.append(b) } else { baseline.append(b) } }
                groups.append(Group(model: group[0].model, effort: group[0].effort, recentTasks: recent.picks,
                                    rows: rows(recent, baseline, recentDays: historyRecent, baselineDays: historyBaseline)))
            }
            groups.sort { a, b in
                a.model.utf8.elementsEqual(b.model.utf8) ? effortBefore(a.effort, b.effort) : modelBefore(a.model, b.model)
            }
        }
        return BrokerOutcomeTrend(today: days[0], includeAllReasons: includeAllReasons, role: selected, roles: roles,
                                  state: selected == nil ? "no-data" : groups.isEmpty ? "filtered-empty" : "populated", groups: groups)
    }
}
