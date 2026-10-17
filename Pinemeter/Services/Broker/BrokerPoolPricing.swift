import Foundation

/// Integer demand inputs supplied by the ledger summarizer, never fetched by a pick.
struct BrokerDemand: Codable, Equatable, Sendable {
    var historyDays: Int
    var historySufficient: Bool
    var roles: [String: Int]
    var pools: [String: PoolDemand]

    struct PoolDemand: Codable, Equatable, Sendable {
        var rateMilli: Int
        var windowDecisions: Int
        var ledgerDecisions: Int
        enum CodingKeys: String, CodingKey {
            case rateMilli = "rate_milli"
            case windowDecisions = "window_decisions"
            case ledgerDecisions = "ledger_decisions"
        }
    }

    enum CodingKeys: String, CodingKey {
        case historyDays = "history_days"
        case historySufficient = "history_sufficient"
        case roles, pools
    }
}

struct BrokerPoolPrice: Codable, Equatable, Sendable {
    struct Forecast: Codable, Equatable, Sendable {
        let state: String
        let rateMilli: Int
        let windowDecisions: Int
        let ledgerDecisions: Int
        let decisionsUntilReset: Int
        let demandBp: Int
    }
    let pool: String
    let label: String
    let usedBp: Int
    let capBp: Int
    let headroomBp: Int
    let resetAt: Date?
    let secondsToReset: Int?
    let forecast: Forecast
    let price: Int
    let priceLevel: Int
}

/// Pure, bounded integer pool prices; route ordering delegates to the scoring engine.
enum BrokerPoolPricing {
    static let earlyWindowSeconds = 43_200
    static let minLedgerDecisions = 5
    static let farResetSeconds = 259_200
    static let farResetFloor = 500
    static let safetyMarginBp = 500
    static let levelWidth = 250
    static let maxPrice = 1000
    static let rateMilliCap = 100_000_000
    static let windowSecondsCap = 2_678_400
    static let demandBpCap = 1_000_000

    static func chatGPTPoolKey(_ row: OracleSnapshot.ChatGPTRow) -> String {
        "chatgpt:\(row.account ?? ""):\(row.label)"
    }

    static func poolPrices(
        policy: BrokerPolicy, oracle: OracleSnapshot?, demand: BrokerDemand?, now: Date
    ) -> [BrokerPoolPrice] {
        guard let oracle else { return [] }
        var rows: [BrokerPoolPrice] = []
        var seen = Set<String>()
        func append(_ key: String, _ label: String, _ used: Double?, _ cap: Double,
                    _ reset: Date?, _ window: Int, _ fresh: Bool) {
            guard let used, used.isFinite, !seen.contains(key) else { return }
            seen.insert(key)
            rows.append(poolPrice(pool: key, label: label, used: used, cap: cap,
                                  resetAt: reset, windowSeconds: window, fresh: fresh,
                                  policy: policy, demand: demand, now: now))
        }
        let thresholds = policy.thresholds
        for row in oracle.accounts {
            let fresh = row.state == .fresh && row.lastUpdated.map {
                BrokerFreshness.isFresh($0, now: now, threshold: thresholds.stalenessSeconds)
            } == true
            append("claude:\(row.id):weekly", "\(row.label) weekly", row.weekly,
                   thresholds.weeklyPct, row.weeklyResetAt, 604800, fresh)
            append("claude:\(row.id):sonnet", "\(row.label) Sonnet weekly", row.sonnet,
                   thresholds.sonnetWeeklyPct, row.sonnetResetAt, 604800, fresh)
            append("claude:\(row.id):fable", "\(row.label) Fable weekly", row.fable,
                   thresholds.fableWeeklyPct, row.fableResetAt, 604800, fresh)
        }
        let fresh = oracle.chatGPTState == .fresh && oracle.chatGPTLastUpdated.map {
            BrokerFreshness.isFresh($0, now: now, threshold: thresholds.stalenessSeconds)
        } == true
        for row in oracle.chatGPTRows where BrokerEngine.isDurableWindow(row) {
            let window = windowSeconds(row)
            append(chatGPTPoolKey(row), row.label, row.usedPercent, thresholds.chatgptWeeklyPct,
                   row.resetAt, window, fresh)
        }
        return rows.sorted { Array($0.pool.utf8).lexicographicallyPrecedes(Array($1.pool.utf8)) }
    }

    static func windowSeconds(_ row: OracleSnapshot.ChatGPTRow) -> Int {
        if let seconds = row.windowSeconds, seconds.isFinite, seconds > 0 {
            return Int(min(Double(windowSecondsCap), max(1, seconds.rounded(.toNearestOrAwayFromZero))))
        }
        return row.windowRole == .chatGPTMonthly ? 2592000 : 604800
    }

    static func poolPrice(
        pool: String, label: String, used: Double, cap: Double, resetAt: Date?,
        windowSeconds: Int, fresh: Bool, policy: BrokerPolicy, demand: BrokerDemand?, now: Date
    ) -> BrokerPoolPrice {
        func basisPoints(_ percent: Double) -> Int {
            guard percent.isFinite else { return 0 }
            return Int((min(100, max(0, percent)) * 100).rounded(.toNearestOrAwayFromZero))
        }
        let usedBp = basisPoints(used)
        let capBp = basisPoints(cap)
        let headroom = capBp - usedBp
        let resetSeconds = resetAt.flatMap { Int(exactly: floor($0.timeIntervalSince1970)) }
        let nowSeconds = Int(exactly: floor(now.timeIntervalSince1970))
        let t: Int? = resetSeconds.flatMap { reset in
            guard let nowSeconds else { return nil }
            let (seconds, overflow) = reset.subtractingReportingOverflow(nowSeconds)
            return overflow ? nil : seconds
        }
        let window = min(windowSecondsCap, max(1, windowSeconds))
        let input = demand?.pools[pool]
        let rate = min(rateMilliCap, max(0, input?.rateMilli ?? 0))
        let count = max(0, input?.windowDecisions ?? 0)
        let ledger = max(0, input?.ledgerDecisions ?? 0)
        var demandBp = 0
        var decisions = 0
        if let t, t > 0, t < window {
            let elapsed = window - t
            let burn = usedBp * t / elapsed
            let nMilli = rate * t / 3600
            // A denominator larger than Int.max implies a quotient of zero.
            let fromLedger = count == 0 || count > Int.max / 1000
                ? 0 : usedBp * nMilli / (count * 1000)
            demandBp = min(demandBpCap, max(burn, fromLedger))
            decisions = nMilli / 1000
        }
        let state: String
        if !policy.thresholds.preferExpiringQuota { state = "pricing_off" }
        else if demand?.historySufficient != true { state = "short_history" }
        else if !fresh { state = "stale_oracle" }
        else if t == nil || t! <= 0 { state = "no_reset" }
        else if t! > window - earlyWindowSeconds { state = "early_window" }
        else if ledger < minLedgerDecisions { state = "new_pool" }
        else if count == 0 && rate > 0 { state = "uncalibrated" }
        else { state = "ok" }
        var price = maxPrice
        if state == "ok", headroom > 0 {
            price = min(maxPrice, (demandBp + demandBp / 2 + safetyMarginBp) * 1000 / headroom)
            if t! > farResetSeconds { price = max(price, farResetFloor) }
        }
        return BrokerPoolPrice(
            pool: pool, label: label, usedBp: usedBp, capBp: capBp, headroomBp: headroom,
            resetAt: resetSeconds.map { Date(timeIntervalSince1970: Double($0)) }, secondsToReset: t,
            forecast: .init(state: state, rateMilli: rate, windowDecisions: count,
                            ledgerDecisions: ledger, decisionsUntilReset: decisions, demandBp: demandBp),
            price: price, priceLevel: price / levelWidth
        )
    }

    static func candidatePoolKeys(
        _ candidate: BrokerCandidate, policy: BrokerPolicy, oracle: OracleSnapshot?
    ) -> [String] {
        guard let oracle else { return [] }
        let lane: BrokerUsageLane? = candidate.route == .native
            ? .claudeAccount(accountId: nil, labelContains: nil, isPrimary: true)
            : policy.usageLane(for: candidate)
        guard let lane else { return [] }
        switch lane {
        case .claudeAccount(let accountId, let labelContains, let isPrimary):
            let row = candidate.route == .native ? oracle.primaryAccount : BrokerEngine.claudeAccountRow(
                for: candidate, policy: policy, oracle: oracle, accountId: accountId,
                labelContains: labelContains, isPrimary: isPrimary)
            guard let row else { return [] }
            var keys = ["claude:\(row.id):weekly"]
            let sonnet = candidate.route == .native
                ? candidate.model.hasPrefix("claude-sonnet-5") : candidate.model.contains("sonnet")
            let fable = candidate.route == .native
                ? candidate.model.hasPrefix("claude-fable-5") : candidate.model.contains("fable")
            if sonnet { keys.append("claude:\(row.id):sonnet") }
            if fable { keys.append("claude:\(row.id):fable") }
            return keys
        case .chatGPT(let labelContains):
            let needle = (labelContains ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return oracle.chatGPTRows.filter {
                BrokerEngine.isDurableWindow($0) && (needle.isEmpty || $0.matchText.lowercased().contains(needle))
            }.map(chatGPTPoolKey)
        }
    }

    static func qualityTiers(_ ranked: [BrokerCandidate], groups: [[String]]) -> [Int] {
        var membership: [String: Int] = [:]
        for (index, group) in groups.enumerated() {
            for model in group where membership[model] == nil { membership[model] = index }
        }
        var tier = 0
        return ranked.indices.map { index in
            if index > 0 {
                let previous = ranked[index - 1].model
                let current = ranked[index].model
                if previous != current && (membership[previous] == nil || membership[previous] != membership[current]) {
                    tier += 1
                }
            }
            return tier
        }
    }

    static func pricedOrder(
        _ ranked: [BrokerCandidate], role: String, policy: BrokerPolicy, oracle: OracleSnapshot?,
        demand: BrokerDemand?, now: Date
    ) -> [BrokerCandidate] {
        BrokerScoringEngine.scoredOrder(ranked, role: role, policy: policy, oracle: oracle, demand: demand, now: now)
    }
}
