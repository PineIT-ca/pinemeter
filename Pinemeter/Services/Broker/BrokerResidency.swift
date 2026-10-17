import Foundation

/// Only machine-local declarations can attest controlled infrastructure.
enum BrokerResidencyFilter {
    static func isRequired(request: BrokerResidency?, role: String, policy: BrokerPolicy) -> Bool {
        request == .controlled || policy.residencyRoles[policy.resolveRole(role)] == .controlled
    }

    static func controlledIDs(role: String, policy: BrokerPolicy) -> Set<String> {
        let resolved = policy.resolveRole(role)
        guard BrokerLocalRoute.allowedRoles.contains(resolved),
              !BrokerLocalRoute.forbiddenRoles.contains(resolved) else { return [] }
        return Set(policy.localRoutes.filter {
            $0.enabled && $0.residency == .controlled && $0.roles.contains(resolved)
        }.map(\.candidate))
    }

    static func filter(_ candidates: [BrokerCandidate], role: String, policy: BrokerPolicy) -> [BrokerCandidate] {
        let ids = controlledIDs(role: role, policy: policy)
        return candidates.filter { ids.contains($0.id) }
    }

    static func routeClass(_ candidate: BrokerCandidate, policy: BrokerPolicy) -> String? {
        policy.localRoutes.contains { $0.enabled && $0.residency == .controlled && $0.candidate == candidate.id }
            ? "controlled" : nil
    }
}
