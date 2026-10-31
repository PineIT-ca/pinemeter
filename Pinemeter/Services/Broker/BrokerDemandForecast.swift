import Foundation

struct BrokerLedgerRecord: Codable, Equatable, Sendable {
    let timestamp: Date
    let role: String
    let candidate: String
}

struct BrokerLedgerDay: Codable, Equatable, Sendable {
    let day: String
    let role: String
    let picks: Int
}

/// Pure projections and complete-UTC-day rates from retained local history.
enum BrokerDemandForecast {
    static let minHistoryDays = 3
    static let lookbackDays = 7
    static let picksCap = 1_000_000_000

    static func ledgerRecords(from records: [BrokerAuditRecord]) -> [BrokerLedgerRecord] {
        records.map { .init(timestamp: $0.timestamp, role: $0.role, candidate: $0.candidate) }
    }

    static func ledgerDays(from rollup: BrokerOutcomeRollup) -> [BrokerLedgerDay] {
        rollup.buckets.map { .init(day: $0.day, role: $0.role, picks: $0.picks) }
    }

    static func summarize(
        policy: BrokerPolicy, oracle: OracleSnapshot?, records: [BrokerLedgerRecord],
        days: [BrokerLedgerDay], rollupLoadFailed: Bool, now: Date
    ) -> BrokerDemand {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        func parseDay(_ text: String) -> Date? {
            let bytes = Array(text.utf8)
            guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
                  bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) })
            else { return nil }
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, parts[0] > 0,
                  let date = calendar.date(from: .init(year: parts[0], month: parts[1], day: parts[2]))
            else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard components.year == parts[0], components.month == parts[1], components.day == parts[2]
            else { return nil }
            return date
        }
        let validDays = days.compactMap { row in parseDay(row.day).map { ($0, row) } }
        let covered = validDays.map { $0.0 }.min().map { max(0, Int(today.timeIntervalSince($0) / 86400)) } ?? 0
        let length = min(lookbackDays, covered)
        let start = today.addingTimeInterval(Double(-length * 86400))
        var picks: [String: Int] = [:]
        if length > 0 {
            for (date, row) in validDays where date >= start && date < today && row.picks > 0 {
                picks[row.role] = min(picksCap, (picks[row.role] ?? 0) + min(picksCap, row.picks))
            }
        }
        let rows = BrokerPoolPricing.poolPrices(policy: policy, oracle: oracle, demand: nil, now: now)
        var pools = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.pool, BrokerDemand.PoolDemand(rateMilli: 0, windowDecisions: 0, ledgerDecisions: 0))
        })
        var starts: [String: Date] = [:]
        for row in rows {
            if let reset = row.resetAt {
                let window = oracle?.chatGPTRows.first {
                    BrokerPoolPricing.chatGPTPoolKey($0) == row.pool && BrokerEngine.isDurableWindow($0)
                        && $0.usedPercent?.isFinite == true
                }
                    .map(BrokerPoolPricing.windowSeconds) ?? 604800
                starts[row.pool] = reset.addingTimeInterval(Double(-window))
            }
        }
        for record in records {
            guard let candidate = BrokerCandidate(id: record.candidate) else { continue }
            let keys = Set(BrokerPoolPricing.candidatePoolKeys(candidate, policy: policy, oracle: oracle))
            for key in keys where pools[key] != nil {
                pools[key]!.ledgerDecisions += 1
                if let start = starts[key], record.timestamp >= start && record.timestamp <= now {
                    pools[key]!.windowDecisions += 1
                }
            }
        }
        var roles: [String: Int] = [:]
        if length > 0 {
            for (role, count) in picks {
                roles[role] = count * 1000 / (length * 24)
                // Full active-chain rates keep demand independent of audit ring eviction.
                let chain = policy.roles[policy.resolveRole(role)] ?? []
                let candidates = BrokerEngine.expandingModelChoices(chain, policy: policy, oracle: oracle, now: now)
                let keys = Set(candidates.flatMap {
                    BrokerPoolPricing.candidatePoolKeys($0, policy: policy, oracle: oracle)
                })
                for key in keys where pools[key] != nil { pools[key]!.rateMilli += roles[role]! }
            }
        }
        return .init(historyDays: length, historySufficient: length >= minHistoryDays && !rollupLoadFailed,
                     roles: roles, pools: pools)
    }
}
