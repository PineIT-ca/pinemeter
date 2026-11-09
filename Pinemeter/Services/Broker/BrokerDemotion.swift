import Foundation

/// Reorders accepted health data without removing routes or changing their gates.
enum BrokerDemotion {
    static func apply(
        _ order: [BrokerCandidate], unpriced: [BrokerCandidate], health: BrokerHealthSnapshot?,
        role resolvedRole: String, policy: BrokerPolicy, oracle: OracleSnapshot?, now: Date
    ) -> (order: [BrokerCandidate], applied: Bool, skipped: Bool) {
        guard policy.thresholds.useModelHealth, let health, now < health.validUntil else {
            return (order, false, false)
        }
        let role = policy.resolveRole(resolvedRole)
        let demoted = Set(health.demotions.filter {
            now < $0.expiresAt && ($0.roles.isEmpty || $0.roles.contains(role))
        }.map(\.model))
        guard order.contains(where: { demoted.contains($0.model) }) else { return (order, false, false) }
        let rows = BrokerScoringEngine.scoredRows(unpriced, role: role, policy: policy,
            oracle: oracle, demand: nil, now: now)
        guard rows.contains(where: { $0.eligible && !demoted.contains($0.model) }) else {
            return (order, false, true)
        }
        let fallbackLast = order.last?.id == BrokerScoringEngine.executionFallback
        let established = fallbackLast ? Array(order.dropLast()) : order
        let partitioned = established.filter { !demoted.contains($0.model) }
            + established.filter { demoted.contains($0.model) }
            + (fallbackLast ? Array(order.suffix(1)) : [])
        return (partitioned, partitioned != order, false)
    }
}
