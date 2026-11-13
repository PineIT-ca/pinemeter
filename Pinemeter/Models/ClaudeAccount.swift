//
//  ClaudeAccount.swift
//  Pinemeter
//

import Foundation

/// Metadata for one connected Claude subscription.
///
/// The session key itself lives in Keychain under `keychainAccount`; this
/// value type only carries the non-secret metadata needed to fetch and
/// display usage for the account (its organization and a human label). It is
/// persisted in `AppSettings` so the app can restore every connected account
/// across launches without re-importing.
struct ClaudeAccount: Codable, Equatable, Sendable, Identifiable {
    /// Stable identifier. Uses the Claude organization UUID string so the same
    /// subscription keeps its identity across re-imports.
    let id: String

    /// Human-readable label shown in the popover (organization name, falling
    /// back to the browser profile it was imported from).
    var label: String

    /// Organization whose usage is queried for this account.
    let organizationId: UUID

    /// Keychain account under which this account's session key is stored.
    /// The primary account keeps the legacy `"default"` identifier for
    /// backward compatibility; additional accounts use their organization UUID.
    let keychainAccount: String

    /// Browser profile this account was imported from, for display/diagnostics.
    var profileLabel: String?

    /// User-chosen label overriding `label`. Preserved across re-imports;
    /// nil (or blank) means the organization name is shown.
    var customLabel: String?

    /// Where this account's login was discovered. `nil` means the existing
    /// browser-cookie-scan or manual-paste origin. See `AccountOrigin`.
    var origin: AccountOrigin? = nil

    /// Label shown in the popover and menu bar: the user's custom label when
    /// set, otherwise the imported organization name.
    var displayLabel: String {
        let trimmed = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? label : trimmed
    }

    /// The primary account reuses the legacy single-account Keychain slot.
    static let primaryKeychainAccount = "default"

    var isPrimary: Bool { keychainAccount == Self.primaryKeychainAccount }

    /// True when this account exists only because of a CLI login (Codex CLI
    /// or Claude Code), never a stored browser cookie.
    var isCLIOrigin: Bool { origin == .cliLogin }

    // Keeps the persisted key set identical to the synthesized Codable this
    // struct used before `origin` existed, and lets `origin` decode leniently
    // (see the `init(from:)` extension below) so an unknown future origin
    // value can never fail the whole settings decode.
    enum CodingKeys: String, CodingKey {
        case id, label, organizationId, keychainAccount, profileLabel, customLabel, origin
    }
}

extension ClaudeAccount {
    /// Decodes with the preexisting required/optional split (id, label,
    /// organizationId, keychainAccount stay strict; profileLabel, customLabel
    /// stay optional) and adds a lenient decode of `origin`: an unrecognized
    /// raw value decodes to `nil` instead of throwing, so a settings file
    /// written by a future build with a new origin can never wipe this
    /// build's saved accounts. Declared in an extension (not the struct body)
    /// so the compiler keeps synthesizing the memberwise initializer every
    /// call site relies on.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        organizationId = try container.decode(UUID.self, forKey: .organizationId)
        keychainAccount = try container.decode(String.self, forKey: .keychainAccount)
        profileLabel = try container.decodeIfPresent(String.self, forKey: .profileLabel)
        customLabel = try container.decodeIfPresent(String.self, forKey: .customLabel)
        origin = (try? container.decodeIfPresent(AccountOrigin.self, forKey: .origin)) ?? nil
    }
}

/// Non-secret metadata for an account the user does not want browser scans to reconnect.
struct ScanExcludedAccount: Codable, Equatable, Sendable, Identifiable {
    let provider: CredentialProvider
    let accountId: String
    let displayLabel: String

    var id: String { "\(provider.rawValue):\(accountId)" }

    static func claude(_ account: ClaudeAccount) -> Self {
        Self(provider: .claude, accountId: account.id, displayLabel: account.displayLabel)
    }

    static func chatGPT(_ account: ChatGPTAccount) -> Self {
        Self(provider: .chatGPT, accountId: account.id, displayLabel: account.displayLabel)
    }
}
