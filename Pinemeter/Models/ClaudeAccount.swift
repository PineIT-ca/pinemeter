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

    /// Label shown in the popover and menu bar: the user's custom label when
    /// set, otherwise the imported organization name.
    var displayLabel: String {
        let trimmed = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? label : trimmed
    }

    /// The primary account reuses the legacy single-account Keychain slot.
    static let primaryKeychainAccount = "default"

    var isPrimary: Bool { keychainAccount == Self.primaryKeychainAccount }
}
