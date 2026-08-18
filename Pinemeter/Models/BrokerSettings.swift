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

/// Broker configuration: whether the loopback MCP server runs, which port it
/// binds to, and the routing policy it serves picks from.
struct BrokerSettings: Codable, Equatable, Sendable {
    /// The server is opt-in — `false` until the user turns it on (D-07).
    var isEnabled: Bool

    /// Loopback port the MCP server binds to.
    var port: Int

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

    static let `default` = BrokerSettings(
        isEnabled: false,
        port: 43117,
        policy: .bundledDefault,
        profiles: [],
        // The bundled policy IS the Balanced profile's rule set, so a fresh
        // install starts on a named profile rather than on "Custom".
        activeProfileID: BrokerAgentProfile.balancedID,
        activeProfileRules: BrokerAgentProfile.balanced.rules
    )

    init(
        isEnabled: Bool,
        port: Int,
        policy: BrokerPolicy,
        profiles: [BrokerAgentProfile] = [],
        activeProfileID: UUID? = BrokerAgentProfile.balancedID,
        activeProfileRules: BrokerRuleSet? = nil
    ) {
        self.isEnabled = isEnabled
        self.port = BrokerSettings.clampedPort(port)
        self.policy = policy
        self.profiles = profiles
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
        case policy
        case profiles
        case activeProfileID = "active_profile_id"
        case activeProfileRules = "active_profile_rules"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrokerSettings.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        let decodedPort = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        port = BrokerSettings.clampedPort(decodedPort)
        policy = try container.decodeIfPresent(BrokerPolicy.self, forKey: .policy) ?? defaults.policy
        profiles = try container.decodeIfPresent([BrokerAgentProfile].self, forKey: .profiles) ?? []
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(port, forKey: .port)
        try container.encode(policy, forKey: .policy)
        try container.encode(profiles, forKey: .profiles)
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
