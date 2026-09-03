//
//  GeminiAccount.swift
//  Pinemeter
//

import Foundation

/// Metadata for one connected Gemini API key.
///
/// Mirrors `ClaudeAccount` and `ChatGPTAccount`: the key itself lives in
/// Keychain under `keychainAccount`, and this value type carries only the
/// non-secret metadata needed to poll and label it. Gemini has no identity
/// endpoint and no browser cookie to scan, so each key is added manually and
/// gets a generated identifier.
struct GeminiAccount: Codable, Equatable, Sendable, Identifiable {
    /// Stable identifier, generated when the key is added.
    let id: String

    /// Default label shown when the user has not set a custom one.
    var label: String

    /// Keychain account under which this key is stored. The primary account
    /// keeps the legacy `"generativelanguage.googleapis.com"` identifier for
    /// backward compatibility; additional keys use their generated id.
    let keychainAccount: String

    /// User-chosen label overriding `label`.
    var customLabel: String?

    init(
        id: String,
        label: String = "Gemini",
        keychainAccount: String,
        customLabel: String? = nil
    ) {
        self.id = id
        self.label = label
        self.keychainAccount = keychainAccount
        self.customLabel = customLabel
    }

    var displayLabel: String {
        let custom = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let reported = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return reported.isEmpty ? "Gemini" : reported
    }

    /// The primary account reuses the legacy single-account Keychain slot.
    static let primaryKeychainAccount = GeminiUsageService.defaultAPIKeyAccount

    /// Identifier of the account a legacy single-key install is migrated to.
    static let legacyPrimaryId = "gemini.default"

    var isPrimary: Bool { keychainAccount == Self.primaryKeychainAccount }

    static func legacyPrimary(customLabel: String?) -> Self {
        Self(
            id: legacyPrimaryId,
            label: "Gemini",
            keychainAccount: primaryKeychainAccount,
            customLabel: customLabel
        )
    }

    // Per-key fallback decode, for the same reason `ChatGPTAccount` has one.
    enum CodingKeys: String, CodingKey {
        case id
        case label
        case keychainAccount = "keychain_account"
        case customLabel = "custom_label"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self.id = id
        self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? "Gemini"
        self.keychainAccount = try container.decodeIfPresent(String.self, forKey: .keychainAccount) ?? id
        self.customLabel = try container.decodeIfPresent(String.self, forKey: .customLabel)
    }
}
