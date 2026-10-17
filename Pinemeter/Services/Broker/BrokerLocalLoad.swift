import Foundation

/// Immutable probe input. Routing never reads a host or the wall clock.
struct BrokerLocalLoad: Codable, Equatable, Sendable {
    var hosts: [Host]

    struct Host: Codable, Equatable, Sendable {
        var host: String
        var state: String
        var observedAt: Date
        var presets: [String: Preset]
        var pending: Int
        enum CodingKeys: String, CodingKey {
            case host, state, presets, pending
            case observedAt = "observed_at"
        }
    }
    struct Preset: Codable, Equatable, Sendable {
        var status: String
        var aliases: [String]
        var slotsTotal: Int
        var slotsBusy: Int
        enum CodingKeys: String, CodingKey {
            case status, aliases
            case slotsTotal = "slots_total"
            case slotsBusy = "slots_busy"
        }
    }
}

enum BrokerLocalRouting {
    static func inject(_ ranked: [BrokerCandidate], role: String, policy: BrokerPolicy)
        -> (candidates: [BrokerCandidate], policy: BrokerPolicy, injectedIDs: Set<String>) {
        let resolved = policy.resolveRole(role)
        var copy = policy
        copy.localRoutes = []
        var candidates = ranked
        var ids = Set(ranked.map(\.id))
        var injected = Set<String>()
        guard BrokerLocalRoute.allowedRoles.contains(resolved),
              !BrokerLocalRoute.forbiddenRoles.contains(resolved) else { return (ranked, copy, injected) }
        var table = BrokerScoringEngine.effectiveTable(ranked, role: resolved, policy: policy)
        for route in policy.localRoutes where route.enabled && route.roles.contains(resolved) {
            guard let parsed = BrokerCandidate(id: route.candidate), ids.insert(parsed.id).inserted else { continue }
            let candidate = BrokerCandidate(route: parsed.route, instance: parsed.instance,
                model: parsed.model, effort: route.baseEffort)
            candidates.insert(candidate, at: candidates.last?.id == BrokerScoringEngine.executionFallback
                ? candidates.endIndex - 1 : candidates.endIndex)
            let chain = copy.roles[resolved] ?? []
            copy.roles[resolved, default: []].insert(candidate,
                at: chain.last?.id == BrokerScoringEngine.executionFallback ? chain.endIndex - 1 : chain.endIndex)
            copy.localRoutes.append(route)
            injected.insert(candidate.id)
            let quality = route.quality[route.baseEffort.rawValue]
                ?? BrokerBuiltInScoring.localModelQuality[route.preset]?[route.baseEffort.rawValue]
            table.quality[candidate.model] = quality.map { [route.baseEffort.rawValue: $0] } ?? [:]
            if copy.models[candidate.model] == nil {
                copy.models[candidate.model] = BrokerModelSpec(effort: .init(
                    levels: [.low, .medium, .high], nilLabel: "Default (high)"))
            }
        }
        if !injected.isEmpty { copy.scoring.roles[resolved] = table }
        return (candidates, copy, injected)
    }

    static func route(for candidate: BrokerCandidate, policy: BrokerPolicy) -> BrokerLocalRoute? {
        policy.localRoutes.first { $0.enabled && $0.candidate == candidate.id }
    }

    private static func target(_ route: BrokerLocalRoute, host: BrokerLocalLoad.Host) -> String? {
        if host.presets[route.preset] != nil { return route.preset }
        return host.presets.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .first { host.presets[$0]!.aliases.contains(route.preset) }
    }

    static func gate(route: BrokerLocalRoute, load: BrokerLocalLoad?, now: Date) -> String? {
        guard let host = load?.hosts.first(where: { $0.host == route.host }), host.state == "ok",
              host.observedAt <= now, now.timeIntervalSince(host.observedAt) <= 60 else {
            return "local host '\(route.host)' load unknown"
        }
        let id = target(route, host: host)
        if host.presets.contains(where: { key, preset in
            key != id && (preset.status == "loading" || (preset.status == "loaded" && clamp(preset.slotsBusy) > 0))
        }) { return "local host '\(route.host)' busy with another model" }
        guard let id, let preset = host.presets[id],
              ["loaded", "loading", "unloaded", "sleeping"].contains(preset.status) else {
            return "local host '\(route.host)' model failed to load"
        }
        return nil
    }

    static func level(route: BrokerLocalRoute, load: BrokerLocalLoad?, now: Date) -> Int {
        guard gate(route: route, load: load, now: now) == nil,
              let host = load?.hosts.first(where: { $0.host == route.host }),
              let id = target(route, host: host), let preset = host.presets[id] else { return 4 }
        if preset.status != "loaded", host.presets.contains(where: { $0.key != id && $0.value.status == "loaded" }) { return 4 }
        if preset.status == "loading" { return 2 }
        if preset.status != "loaded" { return 1 }
        let busy = clamp(preset.slotsBusy)
        let ahead = max(0, busy + (busy > 0 ? 1 : 0) + clamp(host.pending) - clamp(preset.slotsTotal) + 1)
        return ahead == 0 ? 0 : min(4, ahead + 1)
    }
    private static func clamp(_ value: Int) -> Int { min(64, max(0, value)) }
}
