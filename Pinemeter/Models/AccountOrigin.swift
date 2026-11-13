//
//  AccountOrigin.swift
//  Pinemeter
//

import Foundation

/// Where a connected account's login was discovered.
///
/// `nil` on `ClaudeAccount.origin` / `ChatGPTAccount.origin` means the
/// existing browser-cookie-scan or manual-paste origin -- the only origin
/// that existed before this phase. `.cliLogin` marks an account that
/// reconciliation created from a passive local CLI login read (Codex CLI
/// `auth.json` or the Claude Code Keychain item), never from a stored
/// cookie (D-03).
///
/// The raw value is persisted inside `AppSettings` (`claude_accounts[]`,
/// `chatgpt_accounts[]`). It must never contain a credential-shaped
/// fragment: `SecurityInvariantTests.assertNoCredentialPersistenceFragments`
/// bans `accessToken`, `access_token`, `sessionKey`, `Cookie`, and `Bearer`
/// (substring match) anywhere in encoded settings.
enum AccountOrigin: String, Codable, Equatable, Sendable {
    case cliLogin = "cli_login"
}
