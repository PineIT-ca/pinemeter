//
//  BrokerAgentProfile.swift
//  Pinemeter
//
//  Saveable/loadable agent rule profiles: a named snapshot of the *rules* a
//  BrokerPolicy applies, without any of the machine-local state that policy
//  also happens to carry.
//
//  The split is the whole point. `BrokerPolicy` mixes two kinds of data:
//  portable rules (which candidate serves which role, thresholds, caller
//  filters) and machine state (which T3 instances this Mac has, which
//  Pinemeter account each is bound to, which detected rows the user deleted).
//  Swapping a profile must never destroy the second kind — a profile you
//  exported on one Mac and imported on another has no business deleting the
//  instances it finds there.
//
//  Every type here follows the AppSettings decode-safety convention: explicit
//  snake_case `CodingKeys`, a `static let default`, a custom `init(from:)`
//  that falls back per key, and a full `encode(to:)`.
//

import Foundation

// MARK: - Rule set

/// The portable subset of a ``BrokerPolicy``: everything a profile carries.
///
/// Deliberately excluded, and why:
/// - `t3Instances` — this Mac's detected/registered provider instances.
/// - `t3.ignoredInstances` — this Mac's "don't resurrect that row" list.
/// - `usageLanes` — carries `ClaudeAccount.id` values, which are per-install.
struct BrokerRuleSet: Codable, Equatable, Sendable {
    /// Ordered candidate chain per role. Order is rank order.
    var roles: [String: [BrokerCandidate]]
    /// Utilization ceilings for the quota gates.
    var thresholds: BrokerThresholds
    /// Structural per-caller filters.
    var callers: [String: BrokerCallerPolicy]
    /// Per-role forced-degraded toggle. An unlisted role allows it.
    var allowForcedDegraded: [String: Bool]
    /// Native model name → agent alias used in `/agent` invocations.
    var agentModelAliases: [String: String]
    /// Model slug → T3 instance id.
    var instanceByModel: [String: String]
    /// T3 instance id used when neither the request nor `instanceByModel` names one.
    var defaultInstance: String

    static let `default` = BrokerRuleSet(policy: .bundledDefault)

    init(
        roles: [String: [BrokerCandidate]],
        thresholds: BrokerThresholds = .default,
        callers: [String: BrokerCallerPolicy] = [:],
        allowForcedDegraded: [String: Bool] = [:],
        agentModelAliases: [String: String] = [:],
        instanceByModel: [String: String] = [:],
        defaultInstance: String = BrokerT3Config.default.defaultInstance
    ) {
        self.roles = roles
        self.thresholds = thresholds
        self.callers = callers
        self.allowForcedDegraded = allowForcedDegraded
        self.agentModelAliases = agentModelAliases
        self.instanceByModel = instanceByModel
        self.defaultInstance = defaultInstance
    }

    /// Extracts the portable rules out of a live policy.
    init(policy: BrokerPolicy) {
        self.init(
            roles: policy.roles,
            thresholds: policy.thresholds,
            callers: policy.callers,
            allowForcedDegraded: policy.allowForcedDegraded,
            agentModelAliases: policy.agentModelAliases,
            instanceByModel: policy.t3.instanceByModel,
            defaultInstance: policy.t3.defaultInstance
        )
    }

    /// Every T3 instance an explicit T3 candidate resolves to. Automatic model
    /// choices do not use legacy model/default instance mappings.
    var referencedInstanceIDs: [String] {
        var ids = Set<String>()
        for chain in roles.values {
            for candidate in chain where candidate.route == .t3 {
                if let instance = candidate.instance {
                    ids.insert(instance)
                } else {
                    ids.insert(instanceByModel[candidate.model] ?? defaultInstance)
                }
            }
        }
        // `t3:*` names no instance — it asks for whichever one has headroom —
        // so it can never be an instance this Mac is missing.
        ids.remove(BrokerCandidate.anyInstance)
        return ids.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case roles
        case thresholds
        case callers
        case allowForcedDegraded = "allow_forced_degraded"
        case agentModelAliases = "agent_model_aliases"
        case instanceByModel = "instance_by_model"
        case defaultInstance = "default_instance"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrokerRuleSet.default
        roles = try container.decodeIfPresent([String: [BrokerCandidate]].self, forKey: .roles)
            ?? defaults.roles
        thresholds = try container.decodeIfPresent(BrokerThresholds.self, forKey: .thresholds)
            ?? defaults.thresholds
        callers = try container.decodeIfPresent([String: BrokerCallerPolicy].self, forKey: .callers)
            ?? defaults.callers
        allowForcedDegraded = try container.decodeIfPresent(
            [String: Bool].self, forKey: .allowForcedDegraded
        ) ?? defaults.allowForcedDegraded
        agentModelAliases = try container.decodeIfPresent(
            [String: String].self, forKey: .agentModelAliases
        ) ?? defaults.agentModelAliases
        instanceByModel = try container.decodeIfPresent(
            [String: String].self, forKey: .instanceByModel
        ) ?? defaults.instanceByModel
        defaultInstance = try container.decodeIfPresent(String.self, forKey: .defaultInstance)
            ?? defaults.defaultInstance
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roles, forKey: .roles)
        try container.encode(thresholds, forKey: .thresholds)
        try container.encode(callers, forKey: .callers)
        try container.encode(allowForcedDegraded, forKey: .allowForcedDegraded)
        try container.encode(agentModelAliases, forKey: .agentModelAliases)
        try container.encode(instanceByModel, forKey: .instanceByModel)
        try container.encode(defaultInstance, forKey: .defaultInstance)
    }
}

extension BrokerPolicy {
    /// This policy's portable rules.
    var ruleSet: BrokerRuleSet { BrokerRuleSet(policy: self) }

    /// Overwrites the rule half of this policy, leaving every machine-local
    /// field (`t3Instances`, `t3.ignoredInstances`, `usageLanes`) untouched.
    mutating func apply(_ rules: BrokerRuleSet) {
        roles = rules.modelRouted.roles
        thresholds = rules.thresholds
        callers = rules.callers
        allowForcedDegraded = rules.allowForcedDegraded
        agentModelAliases = rules.agentModelAliases
        t3.instanceByModel = rules.instanceByModel
        t3.defaultInstance = rules.defaultInstance
    }
}

// MARK: - Profile

/// A named, saveable set of agent routing rules.
struct BrokerAgentProfile: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    /// One line describing what the profile optimizes for. Shown under the
    /// name in the profile menu.
    var detail: String
    /// SF Symbol shown beside the name.
    var symbolName: String
    /// Built-in profiles ship with the app: they can be applied and duplicated
    /// but never edited in place, renamed, or deleted.
    var isBuiltIn: Bool
    var rules: BrokerRuleSet

    init(
        id: UUID = UUID(),
        name: String,
        detail: String = "",
        symbolName: String = "slider.horizontal.3",
        isBuiltIn: Bool = false,
        rules: BrokerRuleSet
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbolName = symbolName
        self.isBuiltIn = isBuiltIn
        self.rules = rules.modelRouted
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case detail
        case symbolName = "symbol_name"
        case isBuiltIn = "is_built_in"
        case rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Profile"
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)
            ?? "slider.horizontal.3"
        // An imported file claiming built-in status must not become
        // uneditable-but-user-owned: built-in identity comes from the shipped
        // list, never from decoded data.
        isBuiltIn = false
        rules = (try container.decodeIfPresent(BrokerRuleSet.self, forKey: .rules) ?? .default).modelRouted
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(detail, forKey: .detail)
        try container.encode(symbolName, forKey: .symbolName)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encode(rules, forKey: .rules)
    }
}

/// Why an imported file was refused.
enum BrokerProfileImportError: LocalizedError {
    case notAProfile

    var errorDescription: String? {
        switch self {
        case .notAProfile:
            return "That file is not a Pinemeter rule profile."
        }
    }
}

extension BrokerAgentProfile {
    /// The rule-set keys an exported profile is guaranteed to carry at least
    /// one of. Used only to recognise the file, never to decode it.
    ///
    /// Internal rather than private: `BrokerPresetManifest` reuses it at the
    /// remote-manifest trust boundary, and the two recognition rules must
    /// never drift apart.
    static let ruleSetKeys: Set<String> = [
        "roles", "thresholds", "callers", "allow_forced_degraded",
        "agent_model_aliases", "instance_by_model", "default_instance",
    ]

    /// Whether an untyped JSON object recognisably carries a `BrokerRuleSet`
    /// under its `rules` key — the shared recognition check both import
    /// boundaries (single-profile import, remote manifest presets) run
    /// before trusting an entry enough to decode it.
    static func hasRecognizedRules(_ object: [String: Any]) -> Bool {
        guard let rules = object["rules"] as? [String: Any] else { return false }
        return !ruleSetKeys.isDisjoint(with: rules.keys)
    }

    /// Strict parse for the import boundary.
    ///
    /// `init(from:)` falls back per key, which is correct for settings read
    /// off disk — a partially-unreadable save must still load. At an import
    /// panel that same leniency is a trap: any JSON object at all decodes to
    /// a valid-looking profile carrying the BUNDLED DEFAULT rules, so picking
    /// the wrong file reports success and later replaces the user's routing
    /// with defaults they never chose. Recognise the file first, then decode.
    static func decodeExported(from data: Data) throws -> BrokerAgentProfile {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              hasRecognizedRules(object)
        else {
            throw BrokerProfileImportError.notAProfile
        }
        return try JSONDecoder().decode(BrokerAgentProfile.self, from: data)
    }
}

// MARK: - Built-in profiles

extension BrokerAgentProfile {
    /// Fixed ids so `activeProfileID` survives a relaunch and an app update.
    static let balancedID = UUID(uuidString: "B0A5E000-0000-4000-A000-000000000001")!
    static let conserveID = UUID(uuidString: "B0A5E000-0000-4000-A000-000000000002")!
    static let maxQualityID = UUID(uuidString: "B0A5E000-0000-4000-A000-000000000003")!
    static let offloadID = UUID(uuidString: "B0A5E000-0000-4000-A000-000000000004")!

    /// Role names the shipped policy defines for judgment work — the roles the
    /// broker contract routes to the reasoning tier.
    static let judgmentRoles = ["architecture", "design", "planning", "research", "review"]

    /// The profiles that ship with the app, in menu order.
    static let builtIns: [BrokerAgentProfile] = [balanced, conserveQuota, maxQuality, offloadExecution]

    static func builtIn(id: UUID) -> BrokerAgentProfile? {
        builtIns.first { $0.id == id }
    }

    static let balanced = BrokerAgentProfile(
        id: balancedID,
        name: "Balanced",
        detail: "Reasoning tier for judgment, Codex for execution.",
        symbolName: "scalemass",
        isBuiltIn: true,
        rules: .default
    )

    static let conserveQuota: BrokerAgentProfile = {
        var rules = BrokerRuleSet.default
        // T3 and cheaper lanes first, so the primary subscription is the last
        // thing spent rather than the first. `t3:*` picks whichever T3 lane
        // has the most headroom, which is the whole point of this profile.
        rules.setChain(for: judgmentRoles, [
            BrokerCandidate(route: .t3, instance: BrokerCandidate.anyInstance, model: "claude-fable-5-1"),
            BrokerCandidate(route: .t3, model: "claude-fable-5-1"),
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .high),
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001"),
        ])
        rules.setChain(for: ["execution"], [
            BrokerCandidate(route: .t3, model: "gpt-5.6-sol", effort: .medium),
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol", effort: .medium),
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001"),
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .medium),
        ])
        rules.setChain(for: ["heavy"], [
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .high),
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .high),
            BrokerCandidate(route: .t3, model: "gpt-5.6-sol", effort: .high),
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol", effort: .high),
        ])
        rules.setChain(for: ["standard"], [
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001"),
            BrokerCandidate(route: .t3, model: "gpt-5.6-sol", effort: .medium),
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol", effort: .medium),
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .medium),
        ])
        rules.thresholds = BrokerThresholds(
            sessionPct: 75,
            weeklyPct: 70,
            sonnetWeeklyPct: 80,
            fableWeeklyPct: 75,
            chatgptWeeklyPct: 85,
            stalenessSeconds: 1200
        )
        // Degraded fallback stays allowed everywhere: finishing the work on a
        // small model beats refusing to route when every lane is capped.
        rules.allowForcedDegraded = [:]
        return BrokerAgentProfile(
            id: conserveID,
            name: "Conserve Quota",
            detail: "Cheapest lane that can do the job; ceilings gate early.",
            symbolName: "leaf",
            isBuiltIn: true,
            rules: rules
        )
    }()

    static let maxQuality: BrokerAgentProfile = {
        var rules = BrokerRuleSet.default
        rules.setChain(for: judgmentRoles, [
            BrokerCandidate(route: .native, model: "claude-fable-5-1"),
            BrokerCandidate(route: .t3, instance: BrokerCandidate.anyInstance, model: "claude-fable-5-1"),
            BrokerCandidate(route: .t3, model: "claude-fable-5-1"),
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .xhigh),
        ])
        rules.setChain(for: ["execution"], [
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .xhigh),
            BrokerCandidate(route: .t3, model: "gpt-5.6-sol", effort: .high),
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol", effort: .high),
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .high),
        ])
        rules.setChain(for: ["heavy"], [
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .xhigh),
            BrokerCandidate(route: .native, model: "claude-fable-5-1"),
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .xhigh),
            BrokerCandidate(route: .t3, model: "gpt-5.6-sol", effort: .high),
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol", effort: .high),
        ])
        rules.setChain(for: ["standard"], [
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .high),
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .high),
            BrokerCandidate(route: .t3, model: "gpt-5.6-sol", effort: .high),
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol", effort: .high),
        ])
        rules.thresholds = BrokerThresholds(
            sessionPct: 97,
            weeklyPct: 95,
            sonnetWeeklyPct: 97,
            fableWeeklyPct: 97,
            chatgptWeeklyPct: 97,
            stalenessSeconds: 900
        )
        // Judgment work must never be silently downgraded: if every reasoning
        // lane is exhausted the caller is told so rather than handed a small
        // model that will quietly produce a worse plan.
        rules.allowForcedDegraded = Dictionary(uniqueKeysWithValues: judgmentRoles.map { ($0, false) })
        return BrokerAgentProfile(
            id: maxQualityID,
            name: "Max Quality",
            detail: "Best available model per role; no silent downgrades.",
            symbolName: "sparkles",
            isBuiltIn: true,
            rules: rules
        )
    }()

    static let offloadExecution: BrokerAgentProfile = {
        var rules = BrokerRuleSet.default
        rules.setChain(for: ["execution"], [
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol", effort: .high),
            BrokerCandidate(route: .t3, model: "gpt-5.6-sol", effort: .high),
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .high),
        ])
        rules.setChain(for: ["standard"], [
            BrokerCandidate(route: .codex, model: "gpt-5.6-sol", effort: .medium),
            BrokerCandidate(route: .t3, model: "gpt-5.6-sol", effort: .medium),
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001"),
            BrokerCandidate(route: .native, model: "claude-sonnet-5", effort: .medium),
        ])
        return BrokerAgentProfile(
            id: offloadID,
            name: "Offload Execution",
            detail: "Keep Claude quota for judgment; write code on GPT.",
            symbolName: "arrow.left.arrow.right",
            isBuiltIn: true,
            rules: rules
        )
    }()
}

extension BrokerRuleSet {
    var modelRouted: BrokerRuleSet {
        var copy = self
        copy.roles = copy.roles.mapValues(BrokerPolicy.automaticModelChoices)
        return copy
    }

    /// Assigns one chain to several roles, clamping every candidate to its
    /// model's effort capability (D-03) so a shipped profile can never seed
    /// the invalid (effort-free model, stored effort) pair.
    mutating func setChain(for roleNames: [String], _ chain: [BrokerCandidate]) {
        let clamped = BrokerPolicy.automaticModelChoices(in: chain)
            .map { $0.clampingEffortToModelSupport() }
        for role in roleNames { roles[role] = clamped }
    }
}

// MARK: - Profile management

extension BrokerSettings {
    /// Built-ins, then remote presets in manifest order, then the user's own
    /// profiles by name.
    var allProfiles: [BrokerAgentProfile] {
        BrokerAgentProfile.builtIns
            + remotePresets
            + profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The profile the live rules were last loaded from, if it still exists.
    var activeProfile: BrokerAgentProfile? {
        guard let activeProfileID else { return nil }
        return BrokerAgentProfile.builtIn(id: activeProfileID)
            ?? remotePresets.first { $0.id == activeProfileID }
            ?? profiles.first { $0.id == activeProfileID }
    }

    /// Whether `id` names a profile that came from the remote preset
    /// manifest. The profile bar reads this the same way it reads
    /// `isBuiltIn` — applicable and duplicable, never renamed, saved into, or
    /// deleted — because a manifest refresh can replace `remotePresets`
    /// wholesale at any time and none of those edits would survive it.
    func isRemotePreset(id: UUID) -> Bool {
        remotePresets.contains { $0.id == id }
    }

    /// The rules as of the last apply or save — the baseline every "has this
    /// changed" question is asked against.
    ///
    /// `nil` whenever no profile is active, which is what makes "these rules
    /// are stored nowhere" answerable. A stored pin is deliberately ignored in
    /// that case: `activeProfileID` naming a profile that no longer exists
    /// (a hand-edited or half-synced settings file) would otherwise leave a
    /// stale pin answering for a bar that reads "Custom", suppressing the
    /// confirmation that stops one click from destroying those rules.
    ///
    /// The fallback to the profile's current rules is defence in depth only.
    /// `BrokerSettings.init(from:)` attaches a pin at decode for saves written
    /// before pinning existed, so in practice an active profile always has one.
    var pinnedProfileRules: BrokerRuleSet? {
        guard let activeProfile else { return nil }
        return activeProfileRules ?? activeProfile.rules
    }

    /// True when the live policy's rules have drifted from the pinned
    /// baseline — the "Edited" state in the profile bar.
    ///
    /// Compared against the pin, never against the profile's current rules:
    /// otherwise shipping a better built-in in an app update would light this
    /// up for every user on that profile, blaming them for an edit they did
    /// not make.
    ///
    /// Deliberately `false` when no profile is active: with nothing to be
    /// edited *relative to*, an "Edited" badge would be meaningless. Use
    /// ``hasUnsavedRuleChanges`` to decide whether replacing the rules
    /// destroys something.
    var hasUnsavedProfileEdits: Bool {
        guard let pinnedProfileRules else { return false }
        return pinnedProfileRules != policy.ruleSet
    }

    /// True when the rules on screen are stored nowhere else, so loading a
    /// profile over them loses them for good.
    ///
    /// The no-active-profile case is the dangerous one and is exactly the
    /// case ``hasUnsavedProfileEdits`` reports `false` for: after deleting
    /// the active profile, or after decoding a hand-edited pre-profiles save,
    /// the rules belong to nothing and there is no revert path. Gating the
    /// confirmation on the badge alone let one click destroy them.
    var hasUnsavedRuleChanges: Bool {
        guard let pinnedProfileRules else { return true }
        return pinnedProfileRules != policy.ruleSet
    }

    /// True when the active profile's stored rules have moved on from what
    /// was loaded — an app update improving a built-in, or the same profile
    /// saved in another window. Surfaced as its own state rather than folded
    /// into "Edited", because the two call for opposite actions: this one is
    /// adopted by re-picking the profile, not by saving or reverting.
    var activeProfileHasUpdatedRules: Bool {
        guard let activeProfile, let activeProfileRules else { return false }
        return activeProfile.rules != activeProfileRules
    }

    /// Loads a profile's rules into the live policy. Machine-local policy
    /// state (instances, ignore list, usage lanes) is preserved. Resolves a
    /// remote preset id exactly like a built-in or user profile id — pin
    /// mechanics (`activeProfileRules`) work the same regardless of where the
    /// profile came from, which is what makes an upstream manifest change to
    /// the active preset surface through ``activeProfileHasUpdatedRules``.
    mutating func applyProfile(id: UUID) {
        guard let profile = BrokerAgentProfile.builtIn(id: id)
            ?? remotePresets.first(where: { $0.id == id })
            ?? profiles.first(where: { $0.id == id })
        else { return }
        policy.apply(profile.rules)
        activeProfileID = profile.id
        activeProfileRules = policy.ruleSet
    }

    /// Replaces the remote presets from a manifest refresh, dropping any
    /// entry whose id collides with a saved user profile (see the filter
    /// below).
    ///
    /// Deliberately touches nothing else — not `policy`, not
    /// `activeProfileID`, not `activeProfileRules` — the same posture as
    /// discovery reconciliation (review CR-02/CR-03): untrusted data fetched
    /// in the background must never make a routing decision by itself. If
    /// the active profile happens to be a remote preset that just changed,
    /// `activeProfileHasUpdatedRules` reflects that through the existing pin
    /// comparison, and adopting it is the same explicit re-pick an updated
    /// built-in already asks for.
    mutating func updateRemotePresets(_ presets: [BrokerAgentProfile]) {
        // Drop any incoming preset whose id collides with a user profile.
        // `activeProfile`/`applyProfile(id:)`/`isRemotePreset(id:)` all
        // resolve remote presets before `profiles`, so an id collision would
        // let a manifest silently shadow — and, through `applyProfile`,
        // silently swap the rules behind — a profile the user saved
        // themselves. `BrokerPresetManifest.decode` already refuses a
        // collision with a built-in id; this is the same defence for the
        // other identity space a manifest doesn't get to see when it's
        // authored.
        let userProfileIDs = Set(profiles.map(\.id))
        remotePresets = presets.filter { !userProfileIDs.contains($0.id) }
    }

    /// Discards local edits by restoring the pinned baseline.
    ///
    /// Restores what was LOADED, not what the profile currently stores. If
    /// the profile has since been updated, reverting must not quietly hand
    /// the user different routing than they had — adopting an update is a
    /// separate, explicit re-pick (``activeProfileHasUpdatedRules``).
    mutating func revertToActiveProfile() {
        guard let pinnedProfileRules else { return }
        policy.apply(pinnedProfileRules)
    }

    /// Writes the live rules back into the active profile. Built-ins refuse:
    /// the caller offers "Duplicate" instead.
    @discardableResult
    mutating func saveActiveProfile() -> Bool {
        guard let activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == activeProfileID })
        else { return false }
        profiles[index].rules = policy.ruleSet
        activeProfileRules = policy.ruleSet
        return true
    }

    /// Creates a user profile from the live rules and makes it active.
    @discardableResult
    mutating func createProfile(named name: String, detail: String = "") -> UUID {
        let profile = BrokerAgentProfile(
            name: uniqueProfileName(name),
            detail: detail.isEmpty ? "Your own saved rules." : detail,
            symbolName: "bookmark",
            rules: policy.ruleSet
        )
        profiles.append(profile)
        activeProfileID = profile.id
        activeProfileRules = profile.rules
        return profile.id
    }

    mutating func renameProfile(id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profiles[index].name else { return }
        profiles[index].name = uniqueProfileName(trimmed, excluding: id)
    }

    /// Deletes a user profile. Deleting the active one leaves the live rules
    /// exactly as they are and clears the association, so the bar reads
    /// "Custom" — deletion must never silently re-route anything.
    mutating func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = nil
            activeProfileRules = nil
        }
    }

    /// Stores an imported profile as a user profile without applying it.
    /// Returns the stored id, which differs from the file's id when that id
    /// already exists here.
    @discardableResult
    mutating func importProfile(_ imported: BrokerAgentProfile) -> UUID {
        let existingIDs = Set(profiles.map(\.id))
            .union(remotePresets.map(\.id))
            .union(BrokerAgentProfile.builtIns.map(\.id))
        let stored = BrokerAgentProfile(
            id: existingIDs.contains(imported.id) ? UUID() : imported.id,
            name: uniqueProfileName(imported.name),
            detail: imported.detail,
            symbolName: imported.symbolName,
            isBuiltIn: false,
            rules: imported.rules
        )
        profiles.append(stored)
        return stored.id
    }

    /// A copy of the live rules under the given name, ready to write to disk.
    func exportableProfile(named name: String) -> BrokerAgentProfile {
        BrokerAgentProfile(
            name: name,
            detail: activeProfile?.detail ?? "",
            symbolName: activeProfile?.symbolName ?? "slider.horizontal.3",
            isBuiltIn: false,
            rules: policy.ruleSet
        )
    }

    /// T3 instance ids the given rules route to that this Mac has no row for.
    /// A non-empty result is a warning, never a block: the broker still
    /// resolves those candidates, they just cannot dispatch.
    func unknownInstanceReferences(in rules: BrokerRuleSet) -> [String] {
        let configured = Set(policy.t3Instances.map(\.id))
        return rules.referencedInstanceIDs.filter { !configured.contains($0) }
    }

    /// Appends " 2", " 3", … until the name is free. Compared
    /// case-insensitively so "conserve" and "Conserve" can't both exist.
    ///
    /// `excluding` drops one profile from the taken set, which a rename must
    /// pass: without it a profile collides with its own current name, and
    /// changing "conserve" to "Conserve" yields "Conserve 2".
    func uniqueProfileName(_ base: String, excluding excludedID: UUID? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "Untitled Profile" : trimmed
        let taken = Set(
            (profiles.filter { $0.id != excludedID }.map(\.name)
                + BrokerAgentProfile.builtIns.map(\.name)
                + remotePresets.map(\.name)).map { $0.lowercased() }
        )
        guard taken.contains(candidate.lowercased()) else { return candidate }
        var suffix = 2
        while taken.contains("\(candidate) \(suffix)".lowercased()) { suffix += 1 }
        return "\(candidate) \(suffix)"
    }
}
