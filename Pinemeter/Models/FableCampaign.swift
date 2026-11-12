import Foundation

/// Machine-local, opt-in overlay. Base policy remains the only remote push policy.
struct FableCampaign: Codable, Equatable, Sendable {
    static let model = "claude-fable-5-2"
    var expiresAt: Date
    var accountDeadlines: [String: Date]

    func applying(to base: BrokerPolicy, now: Date) -> BrokerPolicy {
        guard expiresAt.timeIntervalSince1970.isFinite, now < expiresAt else { return base }
        var result = base
        let head = BrokerCandidate(route: .auto, model: Self.model)
        for role in ["planning", "review", "research", "design", "heavy", "legal-review"] {
            guard let chain = base.roles[role] else { continue }
            result.roles[role] = [head] + chain.filter { !$0.model.hasPrefix("claude-fable-") }
        }
        if let chain = base.roles["execution"] {
            let others = chain.filter { !$0.model.hasPrefix("claude-fable-") }
            if let first = others.first {
                result.roles["execution"] = [first, head] + others.dropFirst()
            } else if !chain.isEmpty {
                result.roles["execution"] = [head]
            }
        }
        Self.addModelMetadata(to: &result)
        result.thresholds.fableWeeklyPct = 95
        result.localFablePacingDeadlines = accountDeadlines.filter { !$0.key.isEmpty && $0.value > now }
        return result
    }
    /// Diagnostics for an earlier decision still need its quota lane after expiry.
    static func addModelMetadata(to policy: inout BrokerPolicy) {
        if policy.models[Self.model] == nil {
            policy.models[Self.model] = BrokerModelSpec(
                effort: BrokerEffortCapability(levels: BrokerEffort.builtInLevels, nilLabel: "Default (Code medium; API high)")
            )
        }
        if policy.agentModelAliases[Self.model] == nil {
            policy.agentModelAliases[Self.model] = "claude-fable-5-2"
        }
        // Preserve explicit lane matchers, including the unbound default T3 route.
        for (key, lane) in policy.usageLanes where key.contains("claude-fable-5-1") {
            let promotedKey = key.replacingOccurrences(of: "claude-fable-5-1", with: Self.model)
            if policy.usageLanes[promotedKey] == nil { policy.usageLanes[promotedKey] = lane }
        }
    }

}

extension BrokerSettings {
    func effectivePolicy(now: Date) -> BrokerPolicy {
        fableCampaign?.applying(to: policy, now: now) ?? policy
    }
}

extension BrokerPolicy {
    func waivesFablePacing(accountID: String?, model: String, now: Date) -> Bool {
        guard model == FableCampaign.model, let accountID,
              let deadline = localFablePacingDeadlines[accountID] else { return false }
        return now < deadline
    }
}
