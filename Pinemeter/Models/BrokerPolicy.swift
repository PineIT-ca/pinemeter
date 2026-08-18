//
//  BrokerPolicy.swift
//  Pinemeter
//
//  Codable policy tree for the broker engine. Ported from the reference
//  broker CLI (a Node implementation with a JSON policy file) with the
//  reference's fourth, proxy-based route dropped entirely (phase 07 CONTEXT
//  decision 2).
//
//  Every type here follows the AppSettings decode-safety convention: an
//  explicit snake_case `CodingKeys`, a `static let default`, a custom
//  `init(from:)` that falls back per key, and a full `encode(to:)`. Synthesized
//  Codable is deliberately avoided — it breaks old saves the moment a field is
//  added.
//

import Foundation

/// A recommended reasoning effort for a candidate.
///
/// Omission (`nil`) is not a level: it means no recommendation, so the
/// provider's own default/adaptive behaviour applies. There is deliberately no
/// `none` case — consumers that must not send an effort simply see no field.
enum BrokerEffort: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case xhigh
}

/// Whether a model accepts an effort recommendation at all, and what the nil
/// (no-effort) selection means for that model in the editor picker (D-02).
enum BrokerEffortSupport: Equatable, Sendable {
    /// The model accepts an effort parameter. `nilLabel` names what the
    /// provider does when no effort is sent (adaptive behaviour, or its own
    /// default).
    case supported(nilLabel: String)
    /// The model has no effort parameter at all: there is nothing to select,
    /// and a stored effort on this model must never survive a write (D-03).
    case unsupported

    var supportsEffort: Bool {
        if case .supported = self { return true }
        return false
    }

    /// The label the nil selection shows, for both the supported and
    /// unsupported cases — the unsupported case's label is the literal the
    /// UI shows for a model with no effort parameter (D-02).
    var nilLabel: String {
        switch self {
        case .supported(let nilLabel): return nilLabel
        case .unsupported: return "Unsupported"
        }
    }

    /// The effort levels the editor may offer for this model: every level for
    /// a model that accepts the parameter, and none at all for a model that
    /// does not. Kept here rather than inline in the view so "an unsupported
    /// model offers no choices" is assertable without a snapshot (D-02).
    var selectableLevels: [BrokerEffort] {
        supportsEffort ? BrokerEffort.allCases : []
    }
}

extension BrokerEffort {
    /// Capability lookup for the editor's effort control (D-02). Matches on a
    /// lowercased id so a cased spelling resolves the same way, and by prefix
    /// so dated provider ids (e.g. `claude-haiku-4-5-20251001`) resolve to
    /// their family; branches are ordered most specific first.
    ///
    /// The Haiku branch also matches the bare `haiku` alias (the string this
    /// policy's `agentModelAliases` hands Claude Code) and a substring match
    /// for the family, so a namespaced id such as
    /// `us.anthropic.claude-haiku-4-5-20251001-v1:0` is recognised too. Only
    /// the Haiku branch gets the substring hardening: a miss there deletes a
    /// stored effort on the next edit, while a miss on any other branch just
    /// falls soft to the generic label. That is the whole of the matching
    /// hardening — deliberately no model registry and no further aliases
    /// (D-06).
    ///
    /// The final branch is a deliberate fail-soft for a custom or unrecognised
    /// model id: it must never guess a numeric provider default, only offer a
    /// generic "Provider default" label alongside the four levels (D-02, D-06).
    static func support(forModel model: String) -> BrokerEffortSupport {
        let id = model.lowercased()
        if id == "haiku" || id.contains("claude-haiku-4-5") {
            return .unsupported
        }
        if id.hasPrefix("claude-fable-5") {
            return .supported(nilLabel: "Adaptive (high)")
        }
        if id.hasPrefix("claude-opus-5") || id.hasPrefix("claude-sonnet-5") {
            return .supported(nilLabel: "Default (high)")
        }
        if id.hasPrefix("gpt-5.6-sol") {
            return .supported(nilLabel: "Default (medium)")
        }
        return .supported(nilLabel: "Provider default")
    }
}

/// A single ranked routing candidate: `<route>[:<instance>]/<model>`.
///
/// The identity rules are a wire contract shared with the reference
/// implementation: split at the **first** `/` (models may contain slashes),
/// then split the route part at its **first** `:` (optional T3 provider
/// instance qualifier). An empty qualifier (`t3:/model`) yields no instance.
///
/// The same model on two T3 instances is two distinct candidate ids with
/// independent cooldowns, ranks and usage-lane rows. `effort` is deliberately
/// NOT part of that identity: it is a recommendation carried alongside the
/// pick, never a second lane.
struct BrokerCandidate: Codable, Hashable, Sendable {
    let route: BrokerPolicy.Route
    let instance: String?
    let model: String
    /// Recommended reasoning effort, or `nil` for the provider default.
    /// Excluded from ``id``, so cooldown keys, deny matching and usage lanes
    /// all keep keying on the effort-free canonical id.
    let effort: BrokerEffort?

    init(
        route: BrokerPolicy.Route,
        instance: String? = nil,
        model: String,
        effort: BrokerEffort? = nil
    ) {
        self.route = route
        // `instance` is a T3-only qualifier — drop it defensively for any
        // other route so a malformed id (or a caller carrying a stale
        // instance across a route change) can never construct a candidate
        // in a corrupt shape, regardless of call site.
        self.instance = route == .t3 ? ((instance?.isEmpty ?? true) ? nil : instance) : nil
        self.model = model
        self.effort = effort
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

    private enum CodingKeys: String, CodingKey {
        case id
        case effort
    }

    // Two encoded forms: the canonical id string, and `{"id": …, "effort": …}`
    // when an effort is set. The legacy bare string is tried first so every
    // policy saved before efforts existed decodes unchanged.
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let raw = try? single.decode(String.self) {
            guard let parsed = BrokerCandidate(id: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Invalid broker candidate id '\(raw)'"
                )
            }
            self = parsed
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .id)
        guard let parsed = BrokerCandidate(id: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Invalid broker candidate id '\(raw)'"
            )
        }
        // An unknown effort fails loud, exactly like an unknown route: a
        // silently dropped level would route work at the wrong effort forever.
        let effort = try container.decodeIfPresent(BrokerEffort.self, forKey: .effort)
        self.init(route: parsed.route, instance: parsed.instance, model: parsed.model, effort: effort)
    }

    // Policy JSON stays human-editable: a candidate without an effort encodes
    // as its bare id, so an old policy round-trips byte-identical.
    func encode(to encoder: Encoder) throws {
        guard let effort else {
            var container = encoder.singleValueContainer()
            try container.encode(id)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(effort, forKey: .effort)
    }
}

extension BrokerCandidate {
    /// Enforces D-03: a candidate whose model has no effort parameter can
    /// never carry a stored effort. Returns `self` unchanged when the model
    /// supports effort or none is set — this is the one place every
    /// candidate mutation in the editor flows through before it is written.
    func clampingEffortToModelSupport() -> BrokerCandidate {
        guard effort != nil, !BrokerEffort.support(forModel: model).supportsEffort else {
            return self
        }
        return BrokerCandidate(route: route, instance: instance, model: model, effort: nil)
    }
}

extension BrokerCandidate {
    /// Instance qualifier meaning "whichever configured T3 instance can serve
    /// this model has the most headroom right now".
    ///
    /// `*` is not a legal instance id — ``T3InstanceConfig/isValidId`` rejects
    /// it — so the sentinel can never collide with a real row, and a policy
    /// written before it existed cannot contain one by accident.
    ///
    /// A `*` candidate is a rule, not a lane: the engine expands it into one
    /// concrete `t3:<instance>/<model>` candidate per eligible instance before
    /// anything is evaluated, so cooldown keys, usage lanes, deny lists and the
    /// dispatched decision all keep naming a real instance.
    static let anyInstance = "*"

    /// Whether this candidate defers its instance choice to live capacity.
    var isAnyInstance: Bool { route == .t3 && instance == BrokerCandidate.anyInstance }

    /// This candidate pinned to a concrete instance, effort carried across.
    func pinned(to instance: String) -> BrokerCandidate {
        BrokerCandidate(route: route, instance: instance, model: model, effort: effort)
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
    /// Model slug → instance id. Written only by the shipped seed and the
    /// user; discovery never writes routing (review CR-02/CR-03).
    var instanceByModel: [String: String]
    var defaultInstance: String
    /// Instance ids the user deleted from the T3 Instances list. Discovery
    /// never re-appends an ignored id, which is what makes deleting a
    /// detected row durable (review WR-01). Re-adding the instance from the
    /// add menu clears its entry.
    var ignoredInstances: [String]

    static let `default` = BrokerT3Config(
        instanceByModel: ["gpt-5.6-sol": "codex"],
        defaultInstance: "claudeAgent"
    )

    init(
        instanceByModel: [String: String],
        defaultInstance: String,
        ignoredInstances: [String] = []
    ) {
        self.instanceByModel = instanceByModel
        self.defaultInstance = defaultInstance
        self.ignoredInstances = ignoredInstances
    }

    private enum CodingKeys: String, CodingKey {
        case instanceByModel = "instance_by_model"
        case defaultInstance = "default_instance"
        case ignoredInstances = "ignored_instances"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrokerT3Config.default
        instanceByModel = try container.decodeIfPresent(
            [String: String].self, forKey: .instanceByModel
        ) ?? defaults.instanceByModel
        defaultInstance = try container.decodeIfPresent(String.self, forKey: .defaultInstance)
            ?? defaults.defaultInstance
        ignoredInstances = try container.decodeIfPresent(
            [String].self, forKey: .ignoredInstances
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(instanceByModel, forKey: .instanceByModel)
        try container.encode(defaultInstance, forKey: .defaultInstance)
        try container.encode(ignoredInstances, forKey: .ignoredInstances)
    }
}

/// One T3 provider instance the user has registered.
///
/// Instances live inside the one local T3 server and are selected per dispatch;
/// `baseURLOverride` is `nil` for the normal case, meaning "use the origin from
/// `~/.t3/userdata/server-runtime.json`".
struct T3InstanceConfig: Codable, Equatable, Sendable, Identifiable {
    /// How a row came to exist. Never downgraded once `.detected` — the
    /// three bundled seeds and every user-added row are promoted to
    /// `.detected` the moment a scan confirms the instance is real.
    enum Origin: String, Codable, Sendable {
        case detected
        case manual
    }

    /// Session-stable row identity for SwiftUI (review W-03): `id` is
    /// user-editable on manual rows, and index keying makes a retained
    /// binding edit a *different* row after a deletion, so lists key on this
    /// instead. Deliberately excluded from `CodingKeys` (regenerated each
    /// decode) and from `==` (two decodes of the same row must compare
    /// equal, or every launch would look like a policy change).
    let rowKey: UUID

    var id: String
    var name: String
    /// `nil` means the pointer-file origin.
    var baseURLOverride: String?
    /// Binds this lane to a `ClaudeAccount.id` so quota resolves without
    /// label string-matching. `nil` until the user assigns an account.
    /// Never written by discovery (D-02) — account identity is not
    /// derivable from any T3 signal.
    var boundAccountId: String?
    /// `.manual` until a scan confirms the instance is real, then `.detected`
    /// forever. System-owned; never set by the user directly.
    var origin: Origin
    /// The T3 driver (provider type) reported by the last successful scan
    /// that saw this instance, e.g. `"claudeAgent"`, `"codex"`. `nil` for a
    /// row discovery has never seen.
    var driver: String?
    /// Model slugs the last successful scan reported for this instance.
    var detectedModels: [String]
    /// When the last successful scan reported this instance. Drives
    /// ``status(now:stalenessSeconds:)``.
    var lastSeenAt: Date?

    static let `default` = T3InstanceConfig(id: "claudeAgent", name: "Claude Agent")

    init(
        id: String,
        name: String,
        baseURLOverride: String? = nil,
        boundAccountId: String? = nil,
        origin: Origin = .manual,
        driver: String? = nil,
        detectedModels: [String] = [],
        lastSeenAt: Date? = nil
    ) {
        self.rowKey = UUID()
        self.id = id
        self.name = name
        self.baseURLOverride = baseURLOverride
        self.boundAccountId = boundAccountId
        self.origin = origin
        self.driver = driver
        self.detectedModels = detectedModels
        self.lastSeenAt = lastSeenAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURLOverride = "base_url_override"
        case boundAccountId = "bound_account_id"
        case origin
        case driver
        case detectedModels = "detected_models"
        case lastSeenAt = "last_seen_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = T3InstanceConfig.default
        rowKey = UUID()
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? defaults.id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        baseURLOverride = try container.decodeIfPresent(String.self, forKey: .baseURLOverride)
        boundAccountId = try container.decodeIfPresent(String.self, forKey: .boundAccountId)
        // Decoded leniently — a future build's unknown origin value must not
        // fail the whole policy decode. This is a deliberate departure from
        // the fail-loud enums (BrokerEffort, Route) that govern routing:
        // `origin` only governs a UI badge. Defaulting an unknown-provenance
        // row to `.manual` is the fail-safe, since a manual row is never
        // auto-mutated or auto-removed by discovery.
        origin = ((try? container.decodeIfPresent(Origin.self, forKey: .origin)) ?? nil) ?? .manual
        driver = try container.decodeIfPresent(String.self, forKey: .driver)
        detectedModels = try container.decodeIfPresent([String].self, forKey: .detectedModels) ?? []
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(baseURLOverride, forKey: .baseURLOverride)
        try container.encodeIfPresent(boundAccountId, forKey: .boundAccountId)
        try container.encode(origin, forKey: .origin)
        try container.encodeIfPresent(driver, forKey: .driver)
        if !detectedModels.isEmpty {
            try container.encode(detectedModels, forKey: .detectedModels)
        }
        try container.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
    }

    /// `rowKey` is view identity, not row equality — see its doc comment.
    static func == (lhs: T3InstanceConfig, rhs: T3InstanceConfig) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.baseURLOverride == rhs.baseURLOverride
            && lhs.boundAccountId == rhs.boundAccountId
            && lhs.origin == rhs.origin
            && lhs.driver == rhs.driver
            && lhs.detectedModels == rhs.detectedModels
            && lhs.lastSeenAt == rhs.lastSeenAt
    }

    /// The T3 driver value that identifies a Claude subscription instance.
    /// This mirrors the T3 desktop app's driver vocabulary — if T3 renames
    /// the driver, the Claude-ambiguity warning in the settings UI silently
    /// stops firing, so keep this the single source for that comparison
    /// (review IN-11).
    static let claudeAgentDriver = "claudeAgent"

    /// Whether the Settings UI's Account control has anything to say about
    /// this row.
    ///
    /// `boundAccountId` binds a lane to a `ClaudeAccount`, and it is read in
    /// exactly one place — `BrokerEngine.claudeAccountRow`, reached only for a
    /// `claude_account` usage lane. A codex lane gates on its `chatgpt` usage
    /// lane instead, matched by label, and never reads this field; an opencode
    /// lane has no quota source at all. On those rows the picker could only
    /// ever read "None", which looks like an unfinished setup rather than an
    /// inapplicable control. An unknown (`nil`) driver keeps the control: a
    /// manual row discovery has not confirmed yet may still be a Claude lane.
    var supportsAccountBinding: Bool {
        driver == nil || driver == Self.claudeAgentDriver
    }

    /// The three states the Settings UI renders as a row badge. This is the
    /// single place staleness is computed; the UI only reads it. A
    /// `lastSeenAt` slightly in the future (small clock skew survives the
    /// discovery boundary's future-timestamp rejection) clamps to age zero
    /// rather than producing a negative age (review IN-04).
    func status(now: Date, stalenessSeconds: TimeInterval) -> T3InstanceStatus {
        guard origin == .detected else { return .manual }
        guard let lastSeenAt else { return .stale }
        return max(0, now.timeIntervalSince(lastSeenAt)) <= stalenessSeconds ? .detected : .stale
    }

    /// The charset/length rule shared by instance ids, drivers, and model
    /// slugs, exposed here as the single validator so the Settings UI's
    /// manual-id validator and the discovery service's validators cannot
    /// drift apart (R-07 / T-pz4-01 / review IN-01). `:` and `/` are
    /// excluded on purpose: `BrokerCandidate.init(id:)` splits a candidate
    /// id on the first `/` then the first `:`, so either character inside an
    /// instance id would corrupt candidate-id parsing, cooldown keys, and
    /// `deny_instances` matching.
    static func isValidIdentifier(_ value: String, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maxLength else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-"
        )
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// `isValidIdentifier` at the instance-id/driver length cap.
    static func isValidId(_ value: String) -> Bool {
        isValidIdentifier(value, maxLength: 64)
    }
}

/// The three states a T3 instance row can render as a badge.
enum T3InstanceStatus: Sendable {
    case detected
    case manual
    case stale
}

/// Maps a non-native candidate onto the first-party quota row that gates it.
///
/// No mapping, or no fresh data, yields no verdict — the lane then falls
/// through to whatever cooldowns allow. Lane matching is a pure tightening: it
/// never blocks a candidate that cooldowns would have allowed.
///
/// It is not, however, outcome-neutral. A mapped lane whose quota source is
/// known to be absent on this machine still ranks its candidate below one whose
/// headroom was verified (see `BrokerEngine.laneSourceUnconfigured`). The lane
/// map is therefore also a capability hint, not only a quota gate.
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

    /// Caller id length cap, shared by the validator and the error message.
    static let maxCallerLength = 64

    /// Whether a resolved caller id is well-formed.
    ///
    /// The broker's MCP/HTTP port is loopback but **unauthenticated**: any
    /// local process can send a `pick`, and the resolved caller is echoed into
    /// the decision, rendered in Settings and the popover, and persisted to the
    /// audit store. Validating at the boundary is what stops a planted caller
    /// from injecting control characters, bidi overrides, or megabytes of text
    /// into any of those sinks — the same reasoning as the discovery boundary's
    /// `displayName` treatment (review WR-05).
    ///
    /// Deliberately the same charset and cap as ``T3InstanceConfig/isValidId``:
    /// a caller id is an opaque machine identifier, and every id our own
    /// contract uses (`claude-code`, `codex`) already satisfies it.
    static func isValidCaller(_ caller: String) -> Bool {
        T3InstanceConfig.isValidIdentifier(caller, maxLength: maxCallerLength)
    }

    /// A malformed caller id, made safe to put in an error string that reaches
    /// the UI and the audit store: control characters and default-ignorable
    /// scalars (bidi overrides, zero-width joiners) become `?`, and the result
    /// is truncated. Never widen this to echo the raw value.
    ///
    /// Truncation counts SCALARS, not Characters. One Character can carry
    /// thousands of combining marks — none of them control, newline, or
    /// default-ignorable — so a grapheme-counted prefix would bound the visible
    /// length while leaving the string itself effectively unbounded.
    static func redactedCaller(_ caller: String) -> String {
        let scalars = caller.unicodeScalars.prefix(maxCallerLength).map { scalar -> Character in
            let unsafe = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || scalar.properties.isDefaultIgnorableCodePoint
            return unsafe ? "?" : Character(scalar)
        }
        return String(scalars)
    }

    /// Resolves the T3 provider instance a candidate would dispatch to.
    /// Precedence: inline qualifier → `instance_by_model` → `default_instance`.
    /// Judging denies on this resolved value (rather than the raw candidate id)
    /// is what stops a new model or override from silently reopening a deny.
    func resolvedInstance(for candidate: BrokerCandidate) -> String {
        candidate.instance ?? t3.instanceByModel[candidate.model] ?? t3.defaultInstance
    }

    /// The instances a `t3:*` candidate may expand to, in policy order.
    ///
    /// A row whose last scan reported models has to list this one. A row no
    /// scan has ever inspected keeps its chance: an empty `detected_models` is
    /// "unknown", not "serves nothing", and dropping it would make a
    /// hand-added instance invisible to every `*` candidate until a scan lands.
    func instances(serving model: String) -> [T3InstanceConfig] {
        t3Instances.filter { $0.detectedModels.isEmpty || $0.detectedModels.contains(model) }
    }

    /// The quota lane that gates a candidate: its explicit `usage_lanes` row,
    /// or — for a t3 candidate on an instance bound to a Claude account — that
    /// binding.
    ///
    /// The fallback is what lets `t3:*` see quota without a hand-written lane
    /// per instance: binding an account in the Instances pane already declares
    /// whose subscription that lane spends, and `usage_lanes` cannot name a
    /// candidate id that only exists after expansion.
    func usageLane(for candidate: BrokerCandidate) -> BrokerUsageLane? {
        if let explicit = usageLanes[candidate.id] { return explicit }
        guard candidate.route == .t3 else { return nil }
        let instance = resolvedInstance(for: candidate)
        guard let bound = t3Instances.first(where: { $0.id == instance })?.boundAccountId,
              !bound.isEmpty else { return nil }
        return .claudeAccount(accountId: bound, labelContains: nil, isPrimary: nil)
    }

    func t3InstanceReferences(id: String) -> [String] {
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
        return references
    }

    /// Removes an instance only when no active routing reference still resolves to it.
    ///
    /// Removes exactly one row (the first with a matching id), so a stray
    /// duplicate id in persisted state can never make one delete destroy two
    /// rows' user data (review WR-03). Every deletion records the id in
    /// `t3.ignoredInstances` so the next discovery scan does not resurrect
    /// it (review WR-01/W-02). Creating a row for an id clears its entry.
    mutating func removeT3Instance(id: String) -> String? {
        let references = t3InstanceReferences(id: id)

        guard references.isEmpty else {
            return "Cannot delete T3 instance \"\(id)\": \(references.joined(separator: "; ")). "
                + "Update these references before deleting."
        }

        guard let index = t3Instances.firstIndex(where: { $0.id == id }) else { return nil }
        t3Instances.remove(at: index)
        if !t3.ignoredInstances.contains(id) {
            t3.ignoredInstances.append(id)
        }
        return nil
    }

    /// Renames one manual row without breaking active routing references.
    mutating func renameT3Instance(rowKey: UUID, to proposed: String) -> String? {
        guard T3InstanceConfig.isValidId(proposed) else {
            return "Instance ID must be 1-64 characters: letters, numbers, underscore, period, or hyphen."
        }
        guard let index = t3Instances.firstIndex(where: { $0.rowKey == rowKey }) else { return nil }
        guard !t3Instances.contains(where: { $0.rowKey != rowKey && $0.id == proposed }) else {
            return "Another instance already uses this ID."
        }

        let oldId = t3Instances[index].id
        let references = t3InstanceReferences(id: oldId)
        guard oldId == proposed || references.isEmpty else {
            return "Cannot change T3 instance \"\(oldId)\": \(references.joined(separator: "; ")). "
                + "Update these references first."
        }

        unignoreT3Instance(id: proposed)
        t3Instances[index].id = proposed
        return nil
    }

    /// Clears any ignore entry for an id that just gained a row again, so
    /// discovery may append/refresh it once more. Called from every row
    /// creation path (add menu, manual add, id edit) — this is also what
    /// keeps `ignoredInstances` from growing without bound (review I-06).
    mutating func unignoreT3Instance(id: String) {
        t3.ignoredInstances.removeAll { $0 == id }
    }

    /// Adds a row for a discovered instance from the add menu. This is the
    /// mutation boundary, so it enforces what the menu's advisory filter
    /// cannot guarantee against a concurrently refreshed scan (review IN-10):
    /// a valid id and no existing row with the same id. Re-adding clears the
    /// id from `t3.ignoredInstances`, re-enabling reconciliation for it.
    @discardableResult
    mutating func addDetectedT3Instance(_ discovered: DiscoveredT3Instance) -> Bool {
        guard T3InstanceConfig.isValidId(discovered.instanceId),
              !t3Instances.contains(where: { $0.id == discovered.instanceId }) else {
            return false
        }
        unignoreT3Instance(id: discovered.instanceId)
        t3Instances.append(
            T3InstanceConfig(
                id: discovered.instanceId,
                name: discovered.displayName ?? discovered.instanceId,
                origin: .detected,
                driver: discovered.driver,
                detectedModels: discovered.modelSlugs,
                lastSeenAt: discovered.checkedAt
            )
        )
        return true
    }

    /// Reconciles a discovery scan into `t3Instances` without ever destroying
    /// user configuration (R-02) and without ever touching routing.
    ///
    /// Matches on `id`. On a match, overwrites only `driver`, `detectedModels`,
    /// and `lastSeenAt`, and promotes `origin` to `.detected` (never demotes a
    /// `.detected` row back to `.manual`). On no match, appends a new row only
    /// when the discovered instance is `installed` — three permanently-disabled
    /// placeholder rows on first launch would be noise (RESEARCH Q-2), but a
    /// row the user already configured is refreshed regardless of `installed`.
    /// An id in `t3.ignoredInstances` (a row the user deleted) is never
    /// re-appended (review WR-01).
    ///
    /// A row absent from the scan is retained unchanged; this method contains
    /// no removal path at all. Deletion stays exclusively behind
    /// ``removeT3Instance(id:)``'s reference guard (D-04). `name`,
    /// `baseURLOverride`, and `boundAccountId` are never touched here — this
    /// method does not attempt to infer account identity from any T3 signal,
    /// which stays an explicit manual binding (D-02). `roles`, `usageLanes`,
    /// and — deliberately — `t3.instanceByModel` are never touched either:
    /// writing `instance_by_model` changes what `resolvedInstance(for:)`
    /// returns, which feeds deny matching, cooldown keys, liveness lookup,
    /// and quota-lane resolution. Untrusted cache data must never make that
    /// routing decision (review CR-02/CR-03); mappings come only from the
    /// bundled seed and explicit user edits.
    ///
    /// Returns whether anything changed, so the caller can skip a redundant
    /// `updatePolicy` push.
    @discardableResult
    mutating func reconcileDiscoveredT3Instances(_ discovered: [DiscoveredT3Instance]) -> Bool {
        var changed = false

        for instance in discovered {
            // Discovery validates ids at its own boundary; re-checking here
            // keeps the invariant local to the mutation (defense in depth
            // for any future discovery source).
            guard T3InstanceConfig.isValidId(instance.instanceId) else { continue }
            if let index = t3Instances.firstIndex(where: { $0.id == instance.instanceId }) {
                let existing = t3Instances[index]
                if existing.driver != instance.driver
                    || existing.detectedModels != instance.modelSlugs
                    || existing.lastSeenAt != instance.checkedAt
                    || existing.origin != .detected {
                    t3Instances[index].driver = instance.driver
                    t3Instances[index].detectedModels = instance.modelSlugs
                    t3Instances[index].lastSeenAt = instance.checkedAt
                    t3Instances[index].origin = .detected
                    changed = true
                }
            } else if instance.installed, !t3.ignoredInstances.contains(instance.instanceId) {
                t3Instances.append(
                    T3InstanceConfig(
                        id: instance.instanceId,
                        name: instance.displayName ?? instance.instanceId,
                        origin: .detected,
                        driver: instance.driver,
                        detectedModels: instance.modelSlugs,
                        lastSeenAt: instance.checkedAt
                    )
                )
                changed = true
            }
        }

        return changed
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
    ///
    /// For the same reason no shipped chain names a T3 instance id. A second
    /// Claude subscription is worth ranking above the primary's fallbacks, but
    /// which row carries it is this Mac's business, so the seed asks for
    /// `t3:*` — any instance serving the model, most headroom first — and
    /// discovery plus the account binding fill in the rest.
    ///
    /// The per-candidate efforts come from the role/model/effort matrix in
    /// `.planning/quick/260814-eff-effort-aware-broker-routing/260814-eff-RESEARCH.md`;
    /// that document carries the sourcing and the recorded conflicts. An unset
    /// effort is a choice, not an omission: it means the provider default.
    static let bundledDefault: BrokerPolicy = {
        // Fable candidates stay effort-unset on purpose: Fable's thinking is
        // adaptive, and house policy is adaptive-first for the judgment tier.
        //
        // Rank 2 is `t3:*`: spend whichever T3 Claude lane has the most
        // headroom before falling back to a smaller native model.
        let fableChain: [BrokerCandidate] = [
            BrokerCandidate(route: .native, model: "claude-fable-5"),
            BrokerCandidate(route: .t3, instance: BrokerCandidate.anyInstance, model: "claude-fable-5"),
            BrokerCandidate(route: .t3, model: "claude-fable-5"),
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .xhigh),
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .xhigh),
        ]
        var roles: [String: [BrokerCandidate]] = [:]
        for role in ["planning", "architecture", "design", "review", "research"] {
            roles[role] = fableChain
        }
        roles["execution"] = [
            BrokerCandidate(route: .t3, model: "gpt-5.6-sol", effort: .high),
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol", effort: .high),
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .high),
            // Haiku 4.5 does not support the effort parameter at all, so every
            // Haiku candidate stays effort-unset.
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001"),
        ]
        roles["heavy"] = [
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .xhigh),
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .high),
        ]
        roles["standard"] = [
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .high),
            // Haiku 4.5 does not support the effort parameter at all.
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
                T3InstanceConfig(id: "codex", name: "Codex"),
            ],
            usageLanes: [
                "t3/claude-fable-5": .claudeAccount(
                    accountId: nil, labelContains: nil, isPrimary: true
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
