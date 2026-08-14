//
//  BrokerPolicy.swift
//  Pinemeter
//
//  Codable policy tree for the broker engine. Ported from the trixie-box
//  reference implementation (scripts/my-v2/model-broker.mjs,
//  policy/model-broker.json) with the reference's fourth, proxy-based route
//  dropped entirely (phase 07 CONTEXT decision 2).
//
//  Every type here follows the AppSettings decode-safety convention: an
//  explicit snake_case `CodingKeys`, a `static let default`, a custom
//  `init(from:)` that falls back per key, and a full `encode(to:)`. Synthesized
//  Codable is deliberately avoided — it breaks old saves the moment a field is
//  added.
//

import Foundation

/// A single ranked routing candidate: `<route>[:<instance>]/<model>`.
///
/// The identity rules are a wire contract shared with the reference
/// implementation: split at the **first** `/` (models may contain slashes),
/// then split the route part at its **first** `:` (optional T3 provider
/// instance qualifier). An empty qualifier (`t3:/model`) yields no instance.
///
/// The same model on two T3 instances is two distinct candidate ids with
/// independent cooldowns, ranks and usage-lane rows.
struct BrokerCandidate: Codable, Hashable, Sendable {
    let route: BrokerPolicy.Route
    let instance: String?
    let model: String

    init(route: BrokerPolicy.Route, instance: String? = nil, model: String) {
        self.route = route
        // `instance` is a T3-only qualifier — drop it defensively for any
        // other route so a malformed id (or a caller carrying a stale
        // instance across a route change) can never construct a candidate
        // in a corrupt shape, regardless of call site.
        self.instance = route == .t3 ? ((instance?.isEmpty ?? true) ? nil : instance) : nil
        self.model = model
    }

    /// Canonical candidate id, the form used as cooldown keys and in decision JSON.
    var id: String {
        if let instance, !instance.isEmpty {
            return "\(route.rawValue):\(instance)/\(model)"
        }
        return "\(route.rawValue)/\(model)"
    }

    /// Parses a canonical candidate id. Returns `nil` when the id is malformed
    /// or names a route this build does not know.
    init?(id: String) {
        guard let slash = id.firstIndex(of: "/") else { return nil }
        let routePart = String(id[id.startIndex..<slash])
        let model = String(id[id.index(after: slash)...])
        guard !model.isEmpty, !routePart.isEmpty else { return nil }

        let routeName: String
        let qualifier: String?
        if let colon = routePart.firstIndex(of: ":") {
            routeName = String(routePart[routePart.startIndex..<colon])
            let raw = String(routePart[routePart.index(after: colon)...])
            qualifier = raw.isEmpty ? nil : raw
        } else {
            routeName = routePart
            qualifier = nil
        }

        guard !routeName.isEmpty, let route = BrokerPolicy.Route(rawValue: routeName) else {
            return nil
        }
        self.init(route: route, instance: qualifier, model: model)
    }

    // Encoded as its canonical id string so policy JSON stays human-editable.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = BrokerCandidate(id: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid broker candidate id '\(raw)'"
            )
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

/// Utilization ceilings, in percent, above which a lane is considered capped.
///
/// Every threshold is NON-OPTIONAL on purpose. The reference implementation
/// fails loud on a missing threshold key because `x >= undefined` is always
/// false — a missing key silently disables its gate, which is exactly the
/// blowout the broker exists to prevent. Non-optional properties with seeded
/// defaults give the same guarantee in Swift.
struct BrokerThresholds: Codable, Equatable, Sendable {
    var sessionPct: Double
    var weeklyPct: Double
    var sonnetWeeklyPct: Double
    var fableWeeklyPct: Double
    var chatgptWeeklyPct: Double
    var stalenessSeconds: TimeInterval

    static let `default` = BrokerThresholds(
        sessionPct: 90,
        weeklyPct: 85,
        sonnetWeeklyPct: 90,
        fableWeeklyPct: 90,
        chatgptWeeklyPct: 90,
        stalenessSeconds: 1200
    )

    private enum CodingKeys: String, CodingKey {
        case sessionPct = "session_pct"
        case weeklyPct = "weekly_pct"
        case sonnetWeeklyPct = "sonnet_weekly_pct"
        case fableWeeklyPct = "fable_weekly_pct"
        case chatgptWeeklyPct = "chatgpt_weekly_pct"
        case stalenessSeconds = "staleness_seconds"
    }

    init(
        sessionPct: Double,
        weeklyPct: Double,
        sonnetWeeklyPct: Double,
        fableWeeklyPct: Double,
        chatgptWeeklyPct: Double,
        stalenessSeconds: TimeInterval
    ) {
        self.sessionPct = sessionPct
        self.weeklyPct = weeklyPct
        self.sonnetWeeklyPct = sonnetWeeklyPct
        self.fableWeeklyPct = fableWeeklyPct
        self.chatgptWeeklyPct = chatgptWeeklyPct
        self.stalenessSeconds = stalenessSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrokerThresholds.default
        sessionPct = try container.decodeIfPresent(Double.self, forKey: .sessionPct)
            ?? defaults.sessionPct
        weeklyPct = try container.decodeIfPresent(Double.self, forKey: .weeklyPct)
            ?? defaults.weeklyPct
        sonnetWeeklyPct = try container.decodeIfPresent(Double.self, forKey: .sonnetWeeklyPct)
            ?? defaults.sonnetWeeklyPct
        fableWeeklyPct = try container.decodeIfPresent(Double.self, forKey: .fableWeeklyPct)
            ?? defaults.fableWeeklyPct
        chatgptWeeklyPct = try container.decodeIfPresent(Double.self, forKey: .chatgptWeeklyPct)
            ?? defaults.chatgptWeeklyPct
        stalenessSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .stalenessSeconds)
            ?? defaults.stalenessSeconds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionPct, forKey: .sessionPct)
        try container.encode(weeklyPct, forKey: .weeklyPct)
        try container.encode(sonnetWeeklyPct, forKey: .sonnetWeeklyPct)
        try container.encode(fableWeeklyPct, forKey: .fableWeeklyPct)
        try container.encode(chatgptWeeklyPct, forKey: .chatgptWeeklyPct)
        try container.encode(stalenessSeconds, forKey: .stalenessSeconds)
    }
}

/// What one calling harness is structurally allowed to be handed.
///
/// These are structural filters, never quota events: a Codex session cannot
/// invoke the Agent tool, so handing it a native pick is a defect. Filtered
/// candidates are excluded even from the forced-degraded fallback.
struct BrokerCallerPolicy: Codable, Equatable, Sendable {
    var routes: [BrokerPolicy.Route]
    /// Candidate-level denies, finer than a whole route.
    var denyCandidates: [BrokerCandidate]
    /// T3 instance denies, judged on the RESOLVED instance so a new model or
    /// override cannot silently reopen the hole.
    var denyInstances: [String]

    static let `default` = BrokerCallerPolicy(routes: [])

    init(
        routes: [BrokerPolicy.Route],
        denyCandidates: [BrokerCandidate] = [],
        denyInstances: [String] = []
    ) {
        self.routes = routes
        self.denyCandidates = denyCandidates
        self.denyInstances = denyInstances
    }

    private enum CodingKeys: String, CodingKey {
        case routes
        case denyCandidates = "deny_candidates"
        case denyInstances = "deny_instances"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        routes = try container.decodeIfPresent([BrokerPolicy.Route].self, forKey: .routes) ?? []
        denyCandidates = try container.decodeIfPresent(
            [BrokerCandidate].self, forKey: .denyCandidates
        ) ?? []
        denyInstances = try container.decodeIfPresent([String].self, forKey: .denyInstances) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(routes, forKey: .routes)
        try container.encode(denyCandidates, forKey: .denyCandidates)
        try container.encode(denyInstances, forKey: .denyInstances)
    }
}

/// How a `t3` candidate resolves to a provider instance inside the local T3 server.
struct BrokerT3Config: Codable, Equatable, Sendable {
    var instanceByModel: [String: String]
    var defaultInstance: String

    static let `default` = BrokerT3Config(
        instanceByModel: ["gpt-5.6-sol": "codex"],
        defaultInstance: "claudeAgent"
    )

    init(instanceByModel: [String: String], defaultInstance: String) {
        self.instanceByModel = instanceByModel
        self.defaultInstance = defaultInstance
    }

    private enum CodingKeys: String, CodingKey {
        case instanceByModel = "instance_by_model"
        case defaultInstance = "default_instance"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrokerT3Config.default
        instanceByModel = try container.decodeIfPresent(
            [String: String].self, forKey: .instanceByModel
        ) ?? defaults.instanceByModel
        defaultInstance = try container.decodeIfPresent(String.self, forKey: .defaultInstance)
            ?? defaults.defaultInstance
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(instanceByModel, forKey: .instanceByModel)
        try container.encode(defaultInstance, forKey: .defaultInstance)
    }
}

/// One T3 provider instance the user has registered.
///
/// Instances live inside the one local T3 server and are selected per dispatch;
/// `baseURLOverride` is `nil` for the normal case, meaning "use the origin from
/// `~/.t3/userdata/server-runtime.json`".
struct T3InstanceConfig: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    /// `nil` means the pointer-file origin.
    var baseURLOverride: String?
    /// Binds this lane to a `ClaudeAccount.id` so quota resolves without
    /// label string-matching. `nil` until the user assigns an account.
    var boundAccountId: String?

    static let `default` = T3InstanceConfig(id: "claudeAgent", name: "Claude Agent")

    init(id: String, name: String, baseURLOverride: String? = nil, boundAccountId: String? = nil) {
        self.id = id
        self.name = name
        self.baseURLOverride = baseURLOverride
        self.boundAccountId = boundAccountId
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURLOverride = "base_url_override"
        case boundAccountId = "bound_account_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = T3InstanceConfig.default
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? defaults.id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        baseURLOverride = try container.decodeIfPresent(String.self, forKey: .baseURLOverride)
        boundAccountId = try container.decodeIfPresent(String.self, forKey: .boundAccountId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(baseURLOverride, forKey: .baseURLOverride)
        try container.encodeIfPresent(boundAccountId, forKey: .boundAccountId)
    }
}

/// Maps a non-native candidate onto the first-party quota row that gates it.
///
/// No mapping, or no fresh data, yields no verdict — the lane then falls
/// through to whatever cooldowns allow. Lane matching is a pure tightening.
enum BrokerUsageLane: Codable, Equatable, Sendable {
    /// A Claude subscription row. Resolution order: bound account id, then
    /// case-insensitive label match, then the primary-account flag.
    case claudeAccount(accountId: String?, labelContains: String?, isPrimary: Bool?)
    /// ChatGPT rows whose label contains `labelContains` (case-insensitive);
    /// the worst matching row gates the lane.
    case chatGPT(labelContains: String?)

    private enum CodingKeys: String, CodingKey {
        case provider
        case accountId = "account_id"
        case labelContains = "label_contains"
        case isPrimary = "is_primary"
    }

    private enum Provider: String, Codable {
        case claudeAccount = "claude_account"
        case chatGPT = "chatgpt"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .claudeAccount(let accountId, let labelContains, let isPrimary):
            try container.encode(Provider.claudeAccount, forKey: .provider)
            try container.encodeIfPresent(accountId, forKey: .accountId)
            try container.encodeIfPresent(labelContains, forKey: .labelContains)
            try container.encodeIfPresent(isPrimary, forKey: .isPrimary)
        case .chatGPT(let labelContains):
            try container.encode(Provider.chatGPT, forKey: .provider)
            try container.encodeIfPresent(labelContains, forKey: .labelContains)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(Provider.self, forKey: .provider)
        let labelContains = try container.decodeIfPresent(String.self, forKey: .labelContains)
        switch provider {
        case .claudeAccount:
            self = .claudeAccount(
                accountId: try container.decodeIfPresent(String.self, forKey: .accountId),
                labelContains: labelContains,
                isPrimary: try container.decodeIfPresent(Bool.self, forKey: .isPrimary)
            )
        case .chatGPT:
            self = .chatGPT(labelContains: labelContains)
        }
    }
}

/// The broker's routing policy: which candidates serve which role, and the
/// gates that decide whether a candidate is currently usable.
struct BrokerPolicy: Codable, Equatable, Sendable {
    /// The routes this build can invoke. The reference's proxy route is
    /// deliberately absent — its only purpose (second-account Fable capacity)
    /// is served by a T3 lane, so it is unrepresentable here rather than
    /// merely unused.
    enum Route: String, Codable, Sendable, CaseIterable {
        case native
        case t3
        case codex
    }

    /// Caller assumed when a client omits the `caller` argument.
    static let defaultCaller = "claude-code"

    /// Ordered candidate chain per role. Order is rank order.
    var roles: [String: [BrokerCandidate]]
    /// Utilization ceilings for the quota gates.
    var thresholds: BrokerThresholds
    /// Structural per-caller filters. An unknown caller fails loud.
    var callers: [String: BrokerCallerPolicy]
    /// T3 instance resolution.
    var t3: BrokerT3Config
    /// The registered T3 provider instances.
    var t3Instances: [T3InstanceConfig]
    /// Candidate id → quota lane matcher.
    var usageLanes: [String: BrokerUsageLane]
    /// Native model name → agent alias used in `/agent` invocations.
    var agentModelAliases: [String: String]
    /// Per-role forced-degraded toggle. An unlisted role allows it.
    var allowForcedDegraded: [String: Bool]

    init(
        roles: [String: [BrokerCandidate]],
        thresholds: BrokerThresholds = .default,
        callers: [String: BrokerCallerPolicy] = [:],
        t3: BrokerT3Config = .default,
        t3Instances: [T3InstanceConfig] = [],
        usageLanes: [String: BrokerUsageLane] = [:],
        agentModelAliases: [String: String] = [:],
        allowForcedDegraded: [String: Bool] = [:]
    ) {
        self.roles = roles
        self.thresholds = thresholds
        self.callers = callers
        self.t3 = t3
        self.t3Instances = t3Instances
        self.usageLanes = usageLanes
        self.agentModelAliases = agentModelAliases
        self.allowForcedDegraded = allowForcedDegraded
    }

    /// Resolves the caller a decision is filtered for. The resolved value is
    /// echoed back verbatim in the decision (stale-build handshake).
    static func resolveCaller(_ caller: String?) -> String {
        guard let caller else { return defaultCaller }
        let trimmed = caller.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultCaller : trimmed
    }

    /// Resolves the T3 provider instance a candidate would dispatch to.
    /// Precedence: inline qualifier → `instance_by_model` → `default_instance`.
    /// Judging denies on this resolved value (rather than the raw candidate id)
    /// is what stops a new model or override from silently reopening a deny.
    func resolvedInstance(for candidate: BrokerCandidate) -> String {
        candidate.instance ?? t3.instanceByModel[candidate.model] ?? t3.defaultInstance
    }

    /// Removes an instance only when no active routing reference still resolves to it.
    mutating func removeT3Instance(id: String) -> String? {
        let affectedRoles = roles.compactMap { role, candidates in
            candidates.contains {
                $0.route == .t3 && resolvedInstance(for: $0) == id
            } ? role : nil
        }.sorted()
        let mappedModels = t3.instanceByModel.compactMap {
            $0.value == id ? $0.key : nil
        }.sorted()

        var references: [String] = []
        if !affectedRoles.isEmpty { references.append("roles: \(affectedRoles.joined(separator: ", "))") }
        if !mappedModels.isEmpty { references.append("instance_by_model: \(mappedModels.joined(separator: ", "))") }
        if t3.defaultInstance == id { references.append("default_instance") }

        guard references.isEmpty else {
            return "Cannot delete T3 instance \"\(id)\": \(references.joined(separator: "; ")). "
                + "Update these references before deleting."
        }

        t3Instances.removeAll { $0.id == id }
        return nil
    }

    /// Whether a role may fall back to a forced-degraded pick when nothing has headroom.
    func allowsForcedDegraded(role: String) -> Bool {
        allowForcedDegraded[role] ?? true
    }

    // MARK: - Decode safety

    private enum CodingKeys: String, CodingKey {
        case roles
        case thresholds
        case callers
        case t3
        case t3Instances = "t3_instances"
        case usageLanes = "usage_lanes"
        case agentModelAliases = "agent_model_aliases"
        case allowForcedDegraded = "allow_forced_degraded"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrokerPolicy.default
        roles = try container.decodeIfPresent([String: [BrokerCandidate]].self, forKey: .roles)
            ?? defaults.roles
        thresholds = try container.decodeIfPresent(BrokerThresholds.self, forKey: .thresholds)
            ?? defaults.thresholds
        callers = try container.decodeIfPresent([String: BrokerCallerPolicy].self, forKey: .callers)
            ?? defaults.callers
        t3 = try container.decodeIfPresent(BrokerT3Config.self, forKey: .t3) ?? defaults.t3
        t3Instances = try container.decodeIfPresent([T3InstanceConfig].self, forKey: .t3Instances)
            ?? defaults.t3Instances
        usageLanes = try container.decodeIfPresent(
            [String: BrokerUsageLane].self, forKey: .usageLanes
        ) ?? defaults.usageLanes
        agentModelAliases = try container.decodeIfPresent(
            [String: String].self, forKey: .agentModelAliases
        ) ?? defaults.agentModelAliases
        allowForcedDegraded = try container.decodeIfPresent(
            [String: Bool].self, forKey: .allowForcedDegraded
        ) ?? defaults.allowForcedDegraded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roles, forKey: .roles)
        try container.encode(thresholds, forKey: .thresholds)
        try container.encode(callers, forKey: .callers)
        try container.encode(t3, forKey: .t3)
        try container.encode(t3Instances, forKey: .t3Instances)
        try container.encode(usageLanes, forKey: .usageLanes)
        try container.encode(agentModelAliases, forKey: .agentModelAliases)
        try container.encode(allowForcedDegraded, forKey: .allowForcedDegraded)
    }
}

extension BrokerPolicy {
    /// The policy a fresh install starts from, and the fallback every decode
    /// falls back to per key. Alias of ``bundledDefault`` so there is exactly
    /// one seed in the app.
    static var `default`: BrokerPolicy { bundledDefault }

    /// Seed policy distilled from `policy/model-routing.yaml`, surviving routes
    /// only. Account ids are deliberately unbound: the shipped seed must not
    /// assume any particular machine's Pinemeter account identifiers.
    static let bundledDefault: BrokerPolicy = {
        let fableChain: [BrokerCandidate] = [
            BrokerCandidate(route: .native, model: "claude-fable-5"),
            BrokerCandidate(route: .t3, instance: "claude_autimo", model: "claude-fable-5"),
            BrokerCandidate(route: .t3, model: "claude-fable-5"),
            BrokerCandidate(route: .native, model: "claude-opus-5"),
            BrokerCandidate(route: .native, model: "claude-sonnet-5"),
        ]
        var roles: [String: [BrokerCandidate]] = [:]
        for role in ["planning", "architecture", "design", "review", "research"] {
            roles[role] = fableChain
        }
        roles["execution"] = [
            BrokerCandidate(route: .t3, model: "gpt-5.6-sol"),
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol"),
            BrokerCandidate(route: .native, model: "claude-sonnet-5"),
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001"),
        ]
        roles["heavy"] = [
            BrokerCandidate(route: .native, model: "claude-opus-5"),
            BrokerCandidate(route: .native, model: "claude-sonnet-5"),
        ]
        roles["standard"] = [
            BrokerCandidate(route: .native, model: "claude-sonnet-5"),
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001"),
        ]

        return BrokerPolicy(
            roles: roles,
            thresholds: .default,
            callers: [
                // The codex route is claude-orchestrator-only: handing it back
                // to a codex caller is pointless, the work is already there.
                BrokerPolicy.defaultCaller: BrokerCallerPolicy(routes: [.native, .codex, .t3]),
                "codex": BrokerCallerPolicy(routes: [.t3]),
            ],
            t3: .default,
            t3Instances: [
                T3InstanceConfig(id: "claudeAgent", name: "Claude Agent"),
                T3InstanceConfig(id: "claude_autimo", name: "Claude (autimo)"),
                T3InstanceConfig(id: "codex", name: "Codex"),
            ],
            usageLanes: [
                "t3/claude-fable-5": .claudeAccount(
                    accountId: nil, labelContains: nil, isPrimary: true
                ),
                // Resolved through the claude_autimo instance's bound account,
                // which ships unbound: the user assigns it in the editor.
                "t3:claude_autimo/claude-fable-5": .claudeAccount(
                    accountId: nil, labelContains: nil, isPrimary: nil
                ),
                "t3/gpt-5.6-sol": .chatGPT(labelContains: "codex weekly"),
                "codex/gpt-5.6-sol": .chatGPT(labelContains: "codex weekly"),
            ],
            agentModelAliases: [
                "claude-fable-5": "fable",
                "claude-opus-5": "opus",
                "claude-sonnet-5": "sonnet",
                "claude-haiku-4-5-20251001": "haiku",
            ],
            allowForcedDegraded: [:]
        )
    }()
}
