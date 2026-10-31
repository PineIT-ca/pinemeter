import Foundation

/// Chain-capped integer quality, minus the price of the route's scarce pools.
enum BrokerScoringEngine {
    static let executionFallback = "t3:pi/default"
    static func qualityKey(_ candidate: BrokerCandidate) -> String {
        candidate.id == executionFallback ? candidate.id : candidate.model
    }
    static let priceWeight = 5
    static let derivedTierStep = 21

    struct ScoredRow {
        let candidate: BrokerCandidate
        let model: String
        let baseKey: String?
        let quality: Int?
        let effective: Int
        let latency: Int?
        let eligible: Bool
        let reason: String?
        let level: Int
        let score: Int
        let offset: Int
    }

    static func baseKeys(role: String, policy: BrokerPolicy) -> [String: String] {
        var keys: [String: String] = [:]
        for c in policy.roles[policy.resolveRole(role)] ?? [] where keys[qualityKey(c)] == nil {
            keys[qualityKey(c)] = BrokerScoring.effortKey(c.effort)
        }
        return keys
    }

    static func derivedTable(_ ranked: [BrokerCandidate], role: String, policy: BrokerPolicy) -> BrokerRoleScoring {
        let tiers = BrokerPoolPricing.qualityTiers(ranked, groups: policy.equalQualityGroups(for: role))
        let count = (tiers.last ?? -1) + 1
        let keys = baseKeys(role: role, policy: policy)
        var quality: [String: [String: Int]] = [:]
        for (i, c) in ranked.enumerated() where quality[qualityKey(c)] == nil {
            if let key = keys[qualityKey(c)] { quality[qualityKey(c)] = [key: (count - tiers[i]) * derivedTierStep] }
        }
        return BrokerRoleScoring(floor: derivedTierStep, quality: quality)
    }

    static func effectiveTable(_ ranked: [BrokerCandidate], role: String, policy: BrokerPolicy) -> BrokerRoleScoring {
        policy.scoring.role(policy.resolveRole(role)) ?? derivedTable(ranked, role: role, policy: policy)
    }

    static func scoredRows(_ ranked: [BrokerCandidate], role: String, policy: BrokerPolicy,
                           oracle: OracleSnapshot?, demand: BrokerDemand?, now: Date, local: BrokerLocalLoad? = nil, liftFloor: Bool = false) -> [ScoredRow] {
        let table = effectiveTable(ranked, role: role, policy: policy)
        let keys = baseKeys(role: role, policy: policy)
        var effective: [String: Int] = [:]
        var previous = Int.max
        for c in ranked where effective[qualityKey(c)] == nil {
            if let key = keys[qualityKey(c)], let q = table.quality[qualityKey(c)]?[key] {
                // The opaque fallback must never cap measured models that follow it.
                if c.id == executionFallback {
                    effective[qualityKey(c)] = q
                    continue
                }
                let latency = BrokerLocalRouting.route(for: c, policy: policy) == nil ? (policy.scoring.latency[c.model]?[key] ?? 0) : 0
                previous = min(previous, q - (table.latencyWeight ?? 0) * latency)
            }
            effective[qualityKey(c)] = previous
        }
        var prices = Dictionary(uniqueKeysWithValues: BrokerPoolPricing.poolPrices(
            policy: policy, oracle: oracle, demand: demand, now: now).map { ($0.pool, $0.priceLevel) })
        let levels = ranked.map { c in
            if let route = BrokerLocalRouting.route(for: c, policy: policy) {
                prices["local:" + route.host] = BrokerLocalRouting.level(route: route, load: local, now: now)
                return prices["local:" + route.host]!
            }
            let pools = BrokerPoolPricing.candidatePoolKeys(c, policy: policy, oracle: oracle)
            return pools.map { prices[$0] ?? 4 }.max() ?? 4
        }
        let estimates = ranked.map { c in keys[qualityKey(c)].flatMap { table.quality[qualityKey(c)]?[$0] } }
        let latencies: [Int?] = ranked.map { c in
            BrokerLocalRouting.route(for: c, policy: policy) == nil
                ? keys[qualityKey(c)].flatMap { policy.scoring.latency[c.model]?[$0] } : nil
        }
        let reasons: [String?] = ranked.indices.map { i in
            if estimates[i] == nil { return "noEstimate" }
            if !liftFloor, let floor = table.floor, effective[qualityKey(ranked[i])]! < floor { return "belowFloor" }
            if let limit = table.latencyLimit, let latency = latencies[i], latency > limit { return "overLatencyLimit" }
            return nil
        }
        let maxLevel = ranked.indices.filter { reasons[$0] == nil }.map { levels[$0] }.max() ?? 4
        let pricing = demand != nil && policy.thresholds.preferExpiringQuota
        return ranked.enumerated().map { i, c in
            let e = effective[qualityKey(c)]!
            let eligible = reasons[i] == nil
            return ScoredRow(candidate: c, model: c.model, baseKey: keys[qualityKey(c)], quality: estimates[i],
                             effective: e, latency: latencies[i], eligible: eligible, reason: reasons[i], level: levels[i],
                             score: e - (pricing ? priceWeight * (eligible ? levels[i] : maxLevel)
                                : (policy.thresholds.preferExpiringQuota && BrokerLocalRouting.route(for: c, policy: policy) != nil
                                    ? priceWeight * (eligible ? levels[i] : 4) : 0)), offset: i)
        }
    }

    static func raiseTarget(for winner: BrokerCandidate, role: String, policy: BrokerPolicy,
                            oracle: OracleSnapshot?, demand: BrokerDemand?, now: Date) -> BrokerEffort? {
        guard let table = policy.scoring.role(policy.resolveRole(role)),
              demand != nil, policy.thresholds.preferExpiringQuota else { return nil }
        let chain = policy.roles[policy.resolveRole(role)] ?? []
        let ranked = BrokerEngine.rankingEquivalentCandidatesByHeadroom(
            BrokerEngine.expandingModelChoices(chain, policy: policy, oracle: oracle, now: now),
            policy: policy, oracle: oracle, now: now)
        guard let row = scoredRows(ranked, role: role, policy: policy, oracle: oracle, demand: demand, now: now)
            .first(where: { $0.candidate == winner }) else { return nil }
        return raiseTarget(for: row, table: table, policy: policy)
    }

    private static func raiseTarget(for row: ScoredRow, table: BrokerRoleScoring,
                                    policy: BrokerPolicy) -> BrokerEffort? {
        let key = BrokerScoring.effortKey(row.candidate.effort)
        guard row.eligible, row.level == 0, let base = table.quality[qualityKey(row.candidate)]?[key] else { return nil }
        let selectable = BrokerEffort.support(forModel: row.model, in: policy.models).selectableLevels
        var target: BrokerEffort?
        var quality = base
        for effort in selectable.sorted(by: { $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8) }) {
            guard let q = table.quality[qualityKey(row.candidate)]?[effort.rawValue], q > quality else { continue }
            if let limit = table.latencyLimit {
                guard let latency = policy.scoring.latency[row.model]?[effort.rawValue], latency <= limit else { continue }
            }
            target = effort
            quality = q
        }
        return target
    }

    static func scoredOrder(_ ranked: [BrokerCandidate], role: String, policy: BrokerPolicy,
                            oracle: OracleSnapshot?, demand: BrokerDemand?, now: Date, local: BrokerLocalLoad? = nil, liftFloor: Bool = false) -> [BrokerCandidate] {
        orderedRows(scoredRows(ranked, role: role, policy: policy, oracle: oracle, demand: demand, now: now, local: local, liftFloor: liftFloor))
            .map(\.candidate)
    }
    private static func orderedRows(_ rows: [ScoredRow]) -> [ScoredRow] {
        rows.sorted { $0.score == $1.score ? $0.offset < $1.offset : $0.score > $1.score }
    }

    static func scoredRole(role: String, policy: BrokerPolicy, oracle: OracleSnapshot?,
                           demand: BrokerDemand?, now: Date, local: BrokerLocalLoad? = nil) throws -> BrokerScoredRole {
        let resolved = policy.resolveRole(role)
        guard let chain = policy.roles[resolved] else {
            throw BrokerError.unknownRole(role: role, known: policy.roles.keys.sorted())
        }
        guard !chain.isEmpty else { throw BrokerError.configError("role '\(role)' has no candidates") }
        let expanded = BrokerEngine.expandingModelChoices(chain, policy: policy, oracle: oracle, now: now)
        let initial = BrokerEngine.rankingEquivalentCandidatesByHeadroom(expanded, policy: policy, oracle: oracle, now: now)
        let wasDerived = policy.scoring.role(resolved) == nil
        let injection = BrokerLocalRouting.inject(initial, role: resolved, policy: policy)
        let policy = injection.policy
        let ranked = injection.candidates
        let table = effectiveTable(ranked, role: resolved, policy: policy)
        let pricing = demand != nil && policy.thresholds.preferExpiringQuota
        let rows = orderedRows(scoredRows(ranked, role: resolved, policy: policy, oracle: oracle, demand: demand, now: now, local: local))
        return BrokerScoredRole(role: resolved, derived: wasDerived,
            floor: table.floor, latencyLimit: table.latencyLimit,
            pricing: pricing ? (demand!.historySufficient ? "active" : "unconfident")
                : (policy.thresholds.preferExpiringQuota && !injection.injectedIDs.isEmpty
                    ? (local == nil ? "unconfident" : "active") : "off"),
            rows: rows.enumerated().map { position, row in
                .init(candidate: row.candidate.id, model: row.model, effort: row.candidate.effort?.rawValue,
                      quality: row.quality, effective: row.quality == nil ? nil : row.effective,
                      latency: row.latency, level: pricing || (policy.thresholds.preferExpiringQuota && injection.injectedIDs.contains(row.candidate.id)) ? row.level : nil, eligible: row.eligible,
                      reason: row.reason, score: row.quality == nil ? nil : row.score,
                      position: position + 1, neutralPosition: row.offset + 1,
                      raise: pricing && !wasDerived
                        ? raiseTarget(for: row, table: table, policy: policy)?.rawValue : nil)
            })
    }
}

/// Portable rows from the same ranking used by pick; unknown estimates omit numeric scores.
struct BrokerScoredRole: Codable, Equatable, Sendable {
    var role: String
    var derived: Bool
    var floor: Int?
    var latencyLimit: Int?
    var pricing: String
    var rows: [Row]

    struct Row: Codable, Equatable, Sendable {
        var candidate: String
        var model: String
        var effort: String?
        var quality: Int?
        var effective: Int?
        var latency: Int?
        var level: Int?
        var eligible: Bool
        var reason: String?
        var score: Int?
        var position: Int
        var neutralPosition: Int
        var raise: String?
    }
}
