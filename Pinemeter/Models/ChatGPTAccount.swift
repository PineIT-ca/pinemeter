//
//  ChatGPTAccount.swift
//  Pinemeter
//

import Foundation

/// Metadata for one connected ChatGPT account.
///
/// Mirrors `ClaudeAccount`: the session cookie itself lives in Keychain under
/// `keychainAccount`, and this value type carries only the non-secret metadata
/// needed to poll and label the account. Persisted in `AppSettings` so every
/// connected account is restored across launches without re-importing.
struct ChatGPTAccount: Codable, Equatable, Sendable, Identifiable {
    /// Stable identifier. Uses the ChatGPT user id (`user_id` from the WHAM
    /// usage response) so the same login keeps its identity when its cookie is
    /// refreshed or re-imported from a different browser profile.
    let id: String

    /// Human-readable label. The account email when the provider reports one.
    var label: String

    /// Plan reported by the provider ("pro", "plus", "free"), for display.
    var planType: String?

    /// Keychain account under which this account's session cookie is stored.
    /// The primary account keeps the legacy `"chatgpt.com"` identifier for
    /// backward compatibility; additional accounts use their ChatGPT user id.
    let keychainAccount: String

    /// Browser profile this account was imported from, for display/diagnostics.
    var profileLabel: String?

    /// User-chosen label overriding `label`. Preserved across re-imports;
    /// nil (or blank) means the provider-reported label is shown.
    var customLabel: String?

    init(
        id: String,
        label: String,
        planType: String? = nil,
        keychainAccount: String,
        profileLabel: String? = nil,
        customLabel: String? = nil
    ) {
        self.id = id
        self.label = label
        self.planType = planType
        self.keychainAccount = keychainAccount
        self.profileLabel = profileLabel
        self.customLabel = customLabel
    }

    /// Label shown in the popover and menu bar: the user's custom label when
    /// set, otherwise the provider-reported one, falling back to "ChatGPT".
    var displayLabel: String {
        let custom = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let reported = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return reported.isEmpty ? "ChatGPT" : reported
    }

    /// Key used on broker surfaces instead of `displayLabel`.
    ///
    /// `label` is the provider-reported account email. Broker quota rows are
    /// served over the loopback MCP port and persisted in the audit log, so
    /// only a label the user chose themselves, or the opaque account id,
    /// crosses that boundary.
    var brokerLabel: String {
        let custom = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? id : custom
    }

    /// The primary account reuses the legacy single-account Keychain slot.
    static let primaryKeychainAccount = ChatGPTUsageService.defaultSessionAccount

    var isPrimary: Bool { keychainAccount == Self.primaryKeychainAccount }

    /// Identifier used for a connected account whose id the provider did not
    /// report. Keeps legacy installs (connected before identities were read)
    /// addressable until the next successful poll fills the real id in.
    static let unidentifiedId = "chatgpt.legacy"

    /// The account a legacy single-account install is migrated to.
    static func legacyPrimary(customLabel: String?) -> Self {
        Self(
            id: unidentifiedId,
            label: "ChatGPT",
            keychainAccount: primaryKeychainAccount,
            customLabel: customLabel
        )
    }

    // Per-key fallback decode: this type crosses the settings-persistence
    // boundary, so a field added or removed in a later build must never make
    // an otherwise-valid saved account undecodable.
    enum CodingKeys: String, CodingKey {
        case id
        case label
        case planType = "plan_type"
        case keychainAccount = "keychain_account"
        case profileLabel = "profile_label"
        case customLabel = "custom_label"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self.id = id
        self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? "ChatGPT"
        self.planType = try container.decodeIfPresent(String.self, forKey: .planType)
        self.keychainAccount = try container.decodeIfPresent(String.self, forKey: .keychainAccount) ?? id
        self.profileLabel = try container.decodeIfPresent(String.self, forKey: .profileLabel)
        self.customLabel = try container.decodeIfPresent(String.self, forKey: .customLabel)
    }
}

/// Identity the provider reports for a ChatGPT session cookie.
struct ChatGPTAccountIdentity: Equatable, Sendable {
    let userId: String?
    let accountId: String?
    let email: String?
    let planType: String?

    /// Stable account key: the ChatGPT user id, falling back to the workspace
    /// account id. Nil when the provider reported neither.
    var stableId: String? {
        for candidate in [userId, accountId] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return nil
    }

    var displayLabel: String {
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? "ChatGPT" : email
    }

    /// An identity the provider did not report. Connecting rejects these
    /// (two accounts could not be told apart), while a poll of an already
    /// connected account simply leaves its stored metadata untouched.
    static let unidentified = Self(userId: nil, accountId: nil, email: nil, planType: nil)
}
