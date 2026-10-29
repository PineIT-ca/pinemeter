import Foundation

struct BrokerLocalRouteRow: Equatable, Sendable {
    enum State: String, CaseIterable, Sendable {
        case off = "Off", brokerOff = "", unknown = "Unknown", unreachable = "Unreachable"
        case busyOther = "Busy with another model", failed = "Failed to load", loading = "Loading"
        case replacesIdle = "Replaces idle model", notLoaded = "Not loaded", idle = "Idle", busy = "Busy"

        var tooltip: String {
            switch self {
            case .off: "Turned off. The broker never picks this route."
            case .brokerOff: ""
            case .unknown: "No load reading in the last minute, so the broker does not use this route."
            case .unreachable: "The host did not answer. The broker skips this route until it does."
            case .busyOther: "Another model on this host is loading or running. A pick here would interrupt it, so the broker skips this route."
            case .failed: "The host reports this model failed to load. The broker skips this route."
            case .loading: "The model is loading. A pick here waits for it."
            case .replacesIdle: "Another model is loaded but idle. A pick here unloads it first, so this route costs the most."
            case .notLoaded: "The model loads on the first pick."
            case .idle: "Loaded and free. This route costs nothing right now."
            case .busy: "The model is running other work. More queued work raises the price level."
            }
        }
    }

    let rowKey: UUID
    let candidate: String
    let host: String
    let probeURL: String
    let preset: String
    let isEnabled: Bool
    let isControlled: Bool
    let roles: Set<String>
    let state: State
    let priceLevel: Int?
    let observedAt: Date?

    init(route: BrokerLocalRoute, load: BrokerLocalLoad?, now: Date, brokerEnabled: Bool) {
        rowKey = route.rowKey
        candidate = route.candidate; host = route.host; probeURL = route.probeURL; preset = route.preset
        isEnabled = route.enabled; isControlled = route.residency == .controlled; roles = Set(route.roles)
        let entry = load?.hosts.first { $0.host == route.host }
        let reason = BrokerLocalRouting.gate(route: route, load: load, now: now)
        let level = BrokerLocalRouting.level(route: route, load: load, now: now)
        observedAt = entry?.observedAt
        if !route.enabled { state = .off }
        else if !brokerEnabled { state = .brokerOff }
        else if entry == nil || entry!.observedAt > now || now.timeIntervalSince(entry!.observedAt) > 60 || entry!.state == "error" { state = .unknown }
        else if entry!.state == "unreachable" { state = .unreachable }
        else if reason == "local host '\(route.host)' busy with another model" { state = .busyOther }
        else if reason != nil { state = .failed }
        else {
            let target = entry!.presets[route.preset] ?? entry!.presets.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                .first { entry!.presets[$0]!.aliases.contains(route.preset) }.flatMap { entry!.presets[$0] }
            switch target?.status {
            case "loading": state = .loading
            case "unloaded", "sleeping": state = level == 4 ? .replacesIdle : .notLoaded
            default: state = level == 0 ? .idle : .busy
            }
        }
        priceLevel = [.loading, .replacesIdle, .notLoaded, .idle, .busy].contains(state) ? level : nil
    }
}
