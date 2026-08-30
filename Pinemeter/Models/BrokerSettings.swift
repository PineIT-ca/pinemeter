//
//  BrokerSettings.swift
//  Pinemeter
//
//  Persisted broker configuration (D-04, D-07). Follows the AppSettings
//  decode-safety convention exactly: an explicit snake_case `CodingKeys`, a
//  `static let default`, a custom `init(from:)` that falls back per key, and
//  a full `encode(to:)`. Synthesized Codable is deliberately avoided.
//

import Foundation

/// Which interface the broker's MCP server binds to.
///
/// `loopback` is the default and the historical behaviour: the listener is
/// pinned to `127.0.0.1`, so only agents on this Mac can reach it. `network`
/// is an explicit opt-in that binds every interface so other machines (T3
/// servers and clients) can call the same endpoint.
enum BrokerNetworkAccess: String, Codable, Sendable, CaseIterable {
    case loopback
    case network
}

/// When a caller must present the broker's API key.
///
/// `nonLoopback` is the default because it is the safe pairing with
/// ``BrokerNetworkAccess``: local agents keep working with no configuration,
/// and the moment network access is turned on, remote callers need a key.
enum BrokerAPIKeyMode: String, Codable, Sendable, CaseIterable {
    case none
    case nonLoopback = "non_loopback"
    case all
}

/// Settings for the remote broker preset manifest: a small GitHub-hosted JSON
/// file (``BrokerPresetManifest``) offering extra named rule profiles the
/// user may explicitly apply. Refreshed frequently, but fetching only
/// downloads presets into ``BrokerSettings/remotePresets`` — it never applies
/// one (see ``BrokerSettings/updateRemotePresets(_:)``).
///
/// Follows the same decode-safety convention as everything else here.
struct BrokerPresetManifestConfig: Codable, Equatable, Sendable {
    /// Whether Pinemeter fetches the manifest at all. On by default: the
    /// feature is opt-out, not opt-in, but applying a fetched preset always
    /// stays an explicit user action.
    var isEnabled: Bool
    /// Where to fetch it from. Must be `https` to be used — see
    /// ``PresetManifestService``.
    var urlString: String
    /// When the last fetch attempt (successful or not) completed.
    var lastCheckedAt: Date?
    /// The `ETag` from the last 200 response, sent back as `If-None-Match` so
    /// an unchanged manifest costs a 304 instead of a full re-decode.
    var etag: String?
    /// A short, sanitised description of the last fetch failure, for the
    /// settings UI. `nil` after a successful check.
    var lastError: String?

    static let defaultURLString =
        "https://raw.githubusercontent.com/PineIT-ca/pinemeter/main/Pinemeter/Resources/broker-presets.json"

    static let `default` = BrokerPresetManifestConfig(
        isEnabled: true,
        urlString: defaultURLString
    )

    init(
        isEnabled: Bool = true,
        urlString: String = defaultURLString,
        lastCheckedAt: Date? = nil,
        etag: String? = nil,
        lastError: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.urlString = urlString
        self.lastCheckedAt = lastCheckedAt
        self.etag = etag
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case urlString = "url"
        case lastCheckedAt = "last_checked_at"
        case etag
        case lastError = "last_error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrokerPresetManifestConfig.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        let decodedURLString = try container.decodeIfPresent(String.self, forKey: .urlString)
        urlString = (decodedURLString?.isEmpty == false) ? decodedURLString! : defaults.urlString
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(urlString, forKey: .urlString)
        try container.encodeIfPresent(lastCheckedAt, forKey: .lastCheckedAt)
        try container.encodeIfPresent(etag, forKey: .etag)
        try container.encodeIfPresent(lastError, forKey: .lastError)
    }
}

/// Broker configuration: whether the MCP server runs, which port and
/// interface it binds to, how callers authenticate, and the routing policy it
/// serves picks from.
struct BrokerSettings: Codable, Equatable, Sendable {
    /// The server is opt-in — `false` until the user turns it on (D-07).
    var isEnabled: Bool

    /// Port the MCP server binds to.
    var port: Int

    /// Which interface the server binds to. Loopback-only unless the user
    /// opts in to network exposure.
    var networkAccess: BrokerNetworkAccess

    /// When callers must present the API key. The key itself is never stored
    /// here — it lives in the Keychain only (``BrokerAccessPolicy/keychainAccount``).
    var apiKeyMode: BrokerAPIKeyMode

    /// Valid loopback port range (review WR-02), mirroring the Broker
    /// settings tab's `portFormatter` bounds (`BrokerSettingsTab.swift`).
    /// Ports below 1024 are typically privileged and ports above 65535
    /// don't exist.
    static let portRange: ClosedRange<Int> = 1024...65535

    private static func clampedPort(_ port: Int) -> Int {
        min(max(port, portRange.lowerBound), portRange.upperBound)
    }

    /// Routing policy. Defaults to the bundled seed (D-04): any pre-phase
    /// save or fresh install decodes with no `policy` key, which falls back
    /// to `BrokerPolicy.bundledDefault` below — the effective first-launch
    /// policy without any dedicated seeding step.
    var policy: BrokerPolicy

    /// The user's saved agent rule profiles. Built-in profiles are NOT stored
    /// here — they ship with the app (``BrokerAgentProfile/builtIns``) so an
    /// app update can improve them, and so a saved settings file never pins a
    /// stale copy of one.
    var profiles: [BrokerAgentProfile]

    /// Which profile ``policy``'s rules were last loaded from, or `nil` for
    /// rules that belong to no profile (the profile bar reads "Custom").
    /// Never a source of routing truth: the engine always reads ``policy``.
    var activeProfileID: UUID?

    /// The rules exactly as they were the moment ``activeProfileID`` was
    /// applied or saved.
    ///
    /// This exists because built-in profiles ship with the app and an update
    /// can change them. Comparing the live policy against a built-in's
    /// CURRENT rules would make an app update look like the user's own edit:
    /// they would see an "Edited" badge on rules they never touched, and
    /// "Revert" — which promises to discard *their* edits — would instead
    /// swap their routing to the newly shipped rules. Pinned, "Edited" means
    /// only what the user changed, and adopting an updated profile is an
    /// explicit re-pick.
    var activeProfileRules: BrokerRuleSet?

    /// Extra named rule profiles fetched from the remote preset manifest, in
    /// manifest order. A third profile category alongside built-ins and the
    /// user's own ``profiles``: applicable and duplicable like a built-in,
    /// but never renamed, saved into, or deleted, and wholesale-replaced by
    /// every successful refresh (``updateRemotePresets(_:)``) rather than
    /// edited in place.
    var remotePresets: [BrokerAgentProfile]

    /// Settings for fetching ``remotePresets``: whether to, from where, and
    /// the last-fetch bookkeeping the settings UI shows.
    var presetManifest: BrokerPresetManifestConfig

    /// Whether Pinemeter may notify when the recorded instruction check is due
    /// to be re-run. On by default: a stale check is silent by nature, and the
    /// Instructions pane only says so to someone already looking at it.
    var recheckReminderEnabled: Bool

    /// Identifiers of the one-time routing migrations already applied to
    /// ``policy``.
    ///
    /// A routing migration rewrites live routing in place, which is the one
    /// thing the rest of this type is built to never do (see
    /// ``activeProfileRules``). Recording which ones have run is what keeps
    /// "one-time" true: without this the rewrite would re-fire on every
    /// decode and discard any later edit the user made to the same role,
    /// turning a single migration into a permanent override.
    var appliedRoutingMigrations: Set<String>

    /// Moves the `review` role onto the Opus-led chain for installs that
    /// already have a saved policy, not just fresh ones.
    ///
    /// This is a deliberate exception to the no-silent-change rule on
    /// ``activeProfileRules``, taken because the reviewer completion gate is
    /// the highest-volume judgment role and its old Fable-led chain spent the
    /// reasoning tier faster than every other caller combined. It is scoped
    /// to the one role it names and leaves saved profiles in ``profiles``
    /// untouched — those are user-authored objects, not shipped routing.
    static let reviewOpusMigrationID = "review-opus-5"
    static let codexSelfRouteMigrationID = "codex-self-route"
    static let standardCodexRouteMigrationID = "standard-codex-route"

    /// Every routing migration this build knows about. A fresh install starts
    /// with all of them recorded: ``BrokerPolicy/bundledDefault`` already ships
    /// their result, so replaying one would be pure churn.
    static let knownRoutingMigrations: Set<String> = [
        reviewOpusMigrationID,
        codexSelfRouteMigrationID,
        standardCodexRouteMigrationID,
    ]

    static let `default` = BrokerSettings(
        isEnabled: false,
        port: 43117,
        networkAccess: .loopback,
        apiKeyMode: .nonLoopback,
        policy: .bundledDefault,
        profiles: [],
        // The bundled policy IS the Balanced profile's rule set, so a fresh
        // install starts on a named profile rather than on "Custom".
        activeProfileID: BrokerAgentProfile.balancedID,
        activeProfileRules: BrokerAgentProfile.balanced.rules,
        recheckReminderEnabled: true,
        appliedRoutingMigrations: BrokerSettings.knownRoutingMigrations
    )

    init(
        isEnabled: Bool,
        port: Int,
        networkAccess: BrokerNetworkAccess = .loopback,
        apiKeyMode: BrokerAPIKeyMode = .nonLoopback,
        policy: BrokerPolicy,
        profiles: [BrokerAgentProfile] = [],
        activeProfileID: UUID? = BrokerAgentProfile.balancedID,
        activeProfileRules: BrokerRuleSet? = nil,
        recheckReminderEnabled: Bool = true,
        remotePresets: [BrokerAgentProfile] = [],
        presetManifest: BrokerPresetManifestConfig = .default,
        appliedRoutingMigrations: Set<String> = BrokerSettings.knownRoutingMigrations
    ) {
        self.isEnabled = isEnabled
        self.recheckReminderEnabled = recheckReminderEnabled
        self.appliedRoutingMigrations = appliedRoutingMigrations
        self.port = BrokerSettings.clampedPort(port)
        self.networkAccess = networkAccess
        self.apiKeyMode = apiKeyMode
        self.policy = policy
        self.profiles = profiles
        self.remotePresets = remotePresets
        self.presetManifest = presetManifest
        self.activeProfileID = activeProfileID
        // Derived rather than defaulted to nil: `activeProfileID` defaults to
        // Balanced, so a caller building settings from parts would otherwise
        // claim a profile is active while leaving its baseline unpinned, which
        // reads as an edit the caller never made. Claiming a profile is active
        // and pinning that profile's rules is the only self-consistent pair.
        self.activeProfileRules = activeProfileRules
            ?? activeProfileID.flatMap { id in
                BrokerAgentProfile.builtIn(id: id) ?? profiles.first { $0.id == id }
            }?.rules
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case port
        case networkAccess = "network_access"
        case apiKeyMode = "api_key_mode"
        case policy
        case profiles
        case activeProfileID = "active_profile_id"
        case activeProfileRules = "active_profile_rules"
        case recheckReminderEnabled = "recheck_reminder_enabled"
        case remotePresets = "remote_presets"
        case presetManifest = "preset_manifest"
        case appliedRoutingMigrations = "applied_routing_migrations"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrokerSettings.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        let decodedPort = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        port = BrokerSettings.clampedPort(decodedPort)
        // Decoded as a raw `String` rather than as the enum, so a value this
        // build doesn't know (a settings file written by a newer Pinemeter,
        // or one edited by hand) falls back to the default instead of
        // throwing and discarding every other broker setting with it.
        networkAccess = (try container.decodeIfPresent(String.self, forKey: .networkAccess))
            .flatMap(BrokerNetworkAccess.init(rawValue:)) ?? defaults.networkAccess
        apiKeyMode = (try container.decodeIfPresent(String.self, forKey: .apiKeyMode))
            .flatMap(BrokerAPIKeyMode.init(rawValue:)) ?? defaults.apiKeyMode
        policy = try container.decodeIfPresent(BrokerPolicy.self, forKey: .policy) ?? defaults.policy
        profiles = try container.decodeIfPresent([BrokerAgentProfile].self, forKey: .profiles) ?? []
        remotePresets = try container.decodeIfPresent(
            [BrokerAgentProfile].self, forKey: .remotePresets
        ) ?? []
        presetManifest = try container.decodeIfPresent(
            BrokerPresetManifestConfig.self, forKey: .presetManifest
        ) ?? .default
        recheckReminderEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .recheckReminderEnabled
        ) ?? true
        // Absent means a save written before routing migrations existed, so
        // nothing has run yet. Empty is the correct answer there, not
        // `knownRoutingMigrations` — that default belongs to a fresh install,
        // whose policy already ships every migration's result.
        appliedRoutingMigrations = try container.decodeIfPresent(
            Set<String>.self, forKey: .appliedRoutingMigrations
        ) ?? []
        if container.contains(.activeProfileID) {
            activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        } else {
            // A save written before profiles existed carries rules the user may
            // have edited by hand. Associate it with a shipped profile only
            // when the rules match one exactly — otherwise the bar would show
            // an Edited badge on rules that were never loaded from a profile,
            // and Revert would silently overwrite them.
            let storedRules = policy.ruleSet
            activeProfileID = BrokerAgentProfile.builtIns.first { $0.rules == storedRules }?.id
        }
        activeProfileRules = try container.decodeIfPresent(
            BrokerRuleSet.self, forKey: .activeProfileRules
        )
        // Attach a pin now for any save written before pinning existed.
        //
        // Without this the fallback in `pinnedProfileRules` is not a
        // one-decode bridge but a permanent state: `encodeIfPresent` re-omits
        // the key on every save, so a user who never touches the profile bar
        // stays unpinned forever. The first app update that changes a
        // built-in's rules would then show them an "Edited" badge for an edit
        // they never made, with no "Updated" chip (that needs a pin) and a
        // Revert that swaps their routing to the newly shipped rules — the
        // exact failure the pin exists to prevent, re-armed for precisely the
        // migrated users who never opted into any of this.
        if activeProfileRules == nil {
            activeProfileRules = activeProfile?.rules
        }
        // Last, so a migration sees the fully-resolved policy and pin rather
        // than a half-decoded one.
        applyPendingRoutingMigrations()
    }

    /// Applies any routing migration this build knows about that has not run
    /// on these settings yet, then records it so it never runs again.
    private mutating func applyPendingRoutingMigrations() {
        defer { appliedRoutingMigrations.formUnion(BrokerSettings.knownRoutingMigrations) }

        // Rewrites the `review` chain, but never creates one. The policy
        // editor can delete a role outright, so an absent `review` is a choice
        // someone made; re-adding it here would resurrect routing they removed,
        // which is a different change than the one this migration is for.
        if !appliedRoutingMigrations.contains(BrokerSettings.reviewOpusMigrationID),
           policy.roles["review"] != nil,
           let shippedReviewChain = BrokerPolicy.bundledDefault.roles["review"] {
            policy.roles["review"] = shippedReviewChain
            // Move the pin with the policy. The pin records what the active
            // profile looked like when it was applied, so leaving it behind
            // would make the profile bar show an "Edited" badge — and offer a
            // Revert — for a change the user never made.
            activeProfileRules?.roles["review"] = shippedReviewChain
        }

        if !appliedRoutingMigrations.contains(BrokerSettings.codexSelfRouteMigrationID),
           var codexCaller = policy.callers["codex"],
           !codexCaller.routes.contains(.codex) {
            codexCaller.routes.insert(.codex, at: 0)
            policy.callers["codex"] = codexCaller
            if var pinnedCaller = activeProfileRules?.callers["codex"],
               !pinnedCaller.routes.contains(.codex) {
                pinnedCaller.routes.insert(.codex, at: 0)
                activeProfileRules?.callers["codex"] = pinnedCaller
            }
        }

        if !appliedRoutingMigrations.contains(BrokerSettings.standardCodexRouteMigrationID),
           let codexRoutes = policy.callers["codex"]?.routes,
           var standardChain = policy.roles["standard"],
           !standardChain.contains(where: { codexRoutes.contains($0.route) }) {
            let codexCandidates = [
                BrokerCandidate(route: .t3, model: "gpt-5.6-sol", effort: .medium),
                BrokerCandidate(route: .codex, model: "gpt-5.6-sol", effort: .medium),
            ]
            standardChain.append(contentsOf: codexCandidates)
            policy.roles["standard"] = standardChain
            if var pinnedChain = activeProfileRules?.roles["standard"],
               !pinnedChain.contains(where: { codexRoutes.contains($0.route) }) {
                pinnedChain.append(contentsOf: codexCandidates)
                activeProfileRules?.roles["standard"] = pinnedChain
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(port, forKey: .port)
        try container.encode(networkAccess, forKey: .networkAccess)
        try container.encode(apiKeyMode, forKey: .apiKeyMode)
        try container.encode(policy, forKey: .policy)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(remotePresets, forKey: .remotePresets)
        try container.encode(presetManifest, forKey: .presetManifest)
        try container.encode(recheckReminderEnabled, forKey: .recheckReminderEnabled)
        try container.encode(appliedRoutingMigrations, forKey: .appliedRoutingMigrations)
        // Written even when nil, as an explicit null. The decoder
        // distinguishes "key absent" (a pre-profiles save, which may deserve
        // migration) from "key present and null" (the user severed the
        // association on purpose); `encodeIfPresent` collapses both and the
        // migration would silently restore a profile they had just left.
        if let activeProfileID {
            try container.encode(activeProfileID, forKey: .activeProfileID)
        } else {
            try container.encodeNil(forKey: .activeProfileID)
        }
        // Absent means "saved before pinning existed", which
        // `BrokerSettings.pinnedProfileRules` handles by falling back to the
        // profile's current rules. There is no third state to preserve here,
        // so this one stays `encodeIfPresent`.
        try container.encodeIfPresent(activeProfileRules, forKey: .activeProfileRules)
    }
}
