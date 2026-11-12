//
//  CLILogin.swift
//  Pinemeter
//
//  Runtime-only value types for a CLI tool's own login (Codex CLI, Claude
//  Code), read passively off disk/Keychain (D-02) and held in memory only
//  (D-08): nothing in this file conforms to `Codable`, so none of it can be
//  accidentally persisted into `AppSettings`, a Pinemeter Keychain item, or a
//  usage cache by a later change that adds a blanket `Codable` conformance.
//

import Foundation

/// An OAuth access token read from a CLI tool's own login file/Keychain item.
/// Never logged, described, or dumped in the clear (D-08): every reflective
/// surface Swift provides (`description`, `debugDescription`, string
/// interpolation, `dump()`) renders `<redacted>` instead of the value, and
/// `customMirror` exposes no children for `dump()` to walk into.
struct CLIAccessToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    init(_ value: String) {
        self.value = value
    }

    /// The `Authorization` header value for a bearer request: `"Bearer "`
    /// followed by the raw token. This is the only place the raw value
    /// leaves this type.
    var authorizationHeaderValue: String {
        "Bearer \(value)"
    }

    var isBlank: Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }

    var customMirror: Mirror {
        Mirror(self, children: [])
    }
}

/// The expiry skew every CLI login check applies: a token within `skew`
/// seconds of its own `exp` is treated as already expired (D-05), so a
/// request is never sent moments before the provider would reject it anyway.
enum CLILoginExpiry {
    static let skew: TimeInterval = 60
}

/// A Codex CLI login read from `$CODEX_HOME/auth.json` (default
/// `~/.codex/auth.json`). See `CodexCLILoginReader` for what is decoded and
/// what is deliberately never decoded (the refresh token, the id token, the
/// API key -- D-06, D-08).
struct CodexCLILogin: Sendable {
    let accessToken: CLIAccessToken
    /// `tokens.account_id`: the ChatGPT workspace Codex CLI is bound to.
    let accountId: String
    /// The access token's `chatgpt_user_id` claim: equals `ChatGPTAccount.id`
    /// for the account this login belongs to.
    let chatgptUserId: String
    let planType: String?
    let email: String?
    let expiresAt: Date

    /// `true` when `expiresAt` is at or before `now + CLILoginExpiry.skew`
    /// (the boundary itself counts as expired).
    func isExpired(now: Date) -> Bool {
        expiresAt <= now.addingTimeInterval(CLILoginExpiry.skew)
    }
}

/// One Claude Code Keychain item's decoded `claudeAiOauth` payload, before it
/// is mapped to an organization. Plan 19-02 produces these; defined here so
/// the contract plans 19-02 and 19-03 build against is fixed from this plan
/// forward.
struct ClaudeCodeKeychainCredential: Sendable {
    /// The Keychain service name this credential was read from:
    /// `"Claude Code-credentials"` or `"Claude Code-credentials-<8 hex>"`.
    let service: String
    let accessToken: CLIAccessToken
    let expiresAt: Date
    let subscriptionType: String?
    let rateLimitTier: String?
    let scopes: [String]?

    /// The 8 hex characters after the `Claude Code-credentials-` prefix, for
    /// a suffixed service. `nil` for the unsuffixed default service.
    var configDirectoryHashSuffix: String? {
        let prefix = "Claude Code-credentials-"
        guard service.hasPrefix(prefix) else { return nil }
        let suffix = String(service.dropFirst(prefix.count))
        return suffix.isEmpty ? nil : suffix
    }

    func isExpired(now: Date) -> Bool {
        expiresAt <= now.addingTimeInterval(CLILoginExpiry.skew)
    }
}

/// A Claude Code login, mapped to the `ClaudeAccount` org UUID it belongs to.
struct ClaudeCodeLogin: Sendable {
    let accessToken: CLIAccessToken
    let expiresAt: Date
    let organizationId: UUID
    let organizationName: String?
    let subscriptionType: String?
    /// The Keychain service this login was read from, carried through for
    /// diagnostics; never used as the account identity (the org UUID is).
    let keychainService: String

    func isExpired(now: Date) -> Bool {
        expiresAt <= now.addingTimeInterval(CLILoginExpiry.skew)
    }
}

/// Which accounts a CLI login snapshot currently covers, independent of
/// whether any poll has used them yet.
struct CLILoginPresence: Equatable, Sendable {
    let claudeOrganizationIds: Set<UUID>
    let codexChatGPTUserId: String?

    static let none = CLILoginPresence(claudeOrganizationIds: [], codexChatGPTUserId: nil)
}

/// One read of every CLI login source, taken once per poll cycle
/// (`CLILoginService.snapshot()`). Runtime-only (D-08): never persisted, and
/// `AppModel` keeps its copy `@ObservationIgnored`.
struct CLILoginSnapshot: Sendable {
    let codex: CodexCLILogin?
    let claude: [ClaudeCodeLogin]

    static let empty = CLILoginSnapshot(codex: nil, claude: [])

    /// The Codex login for a given ChatGPT user id, by exact string match.
    /// `nil` for a blank id, so an unidentified account (`ChatGPTAccount
    /// .unidentifiedId`-style blank) never accidentally matches a login.
    func codexLogin(forChatGPTUserId id: String) -> CodexCLILogin? {
        guard !id.isEmpty, let codex, codex.chatgptUserId == id else { return nil }
        return codex
    }

    /// The Claude Code login mapped to a given organization, by UUID
    /// equality (never raw string comparison -- the persisted form differs
    /// in case from the Keychain-derived one).
    func claudeLogin(forOrganizationId id: UUID) -> ClaudeCodeLogin? {
        claude.first { $0.organizationId == id }
    }

    var presence: CLILoginPresence {
        CLILoginPresence(
            claudeOrganizationIds: Set(claude.map(\.organizationId)),
            codexChatGPTUserId: codex?.chatgptUserId
        )
    }
}

/// Which credential a provider's last successful poll used. Runtime-only
/// state on `AppModel`, keyed by account id -- never persisted (D-08).
enum UsageCredentialSource: Equatable, Sendable {
    case claudeCode
    case codexCLI
    case storedSession

    var settingsDetail: String {
        switch self {
        case .claudeCode:
            return "Using Claude Code login"
        case .codexCLI:
            return "Using Codex CLI login"
        case .storedSession:
            return "Using saved session"
        }
    }
}

/// Sanitized failure from a CLI-token usage fetch. Never carries the
/// underlying transport error or any credential material.
enum CLIUsageFetchError: LocalizedError, Equatable {
    /// The provider rejected the token outright (401, 403, 429) or the
    /// response named a different account than the token claims to belong
    /// to.
    case rejected
    /// The response could not be parsed into the expected usage shape.
    case invalidResponse
    case httpError(statusCode: Int)
    case networkUnavailable

    /// `true` only for the two cases that mean "this token did not work for
    /// this account" -- the cases where falling back to the stored cookie in
    /// the same cycle (D-03) is correct. `httpError` and `networkUnavailable`
    /// mean "something else is wrong" and must not trigger a second request.
    var fallsBackToStoredSession: Bool {
        switch self {
        case .rejected, .invalidResponse:
            return true
        case .httpError, .networkUnavailable:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .rejected:
            return "The CLI login was rejected."
        case .invalidResponse:
            return "Unable to parse usage data from the CLI login."
        case .httpError(let statusCode):
            return "The usage request failed with HTTP \(statusCode)."
        case .networkUnavailable:
            return "Usage data is unavailable. Check your connection and try again."
        }
    }
}

/// Why a provider has no usable CLI source right now, for a sanitized
/// Settings message. Never names the specific HTTP status or file-system
/// cause -- only "missing/expired" versus "the provider rejected it".
enum CLISourceUnavailableReason: Equatable, Sendable {
    case missingOrExpired
    case rejected

    func message(for provider: CredentialProvider) -> String {
        switch (provider, self) {
        case (.claude, .missingOrExpired):
            return "No current Claude Code login. Run claude once, or connect a browser session."
        case (.chatGPT, .missingOrExpired):
            return "No current Codex CLI login. Run codex once, or connect a browser session."
        case (.claude, .rejected):
            return "Claude rejected the Claude Code login. Run claude once, or connect a browser session."
        case (.chatGPT, .rejected):
            return "ChatGPT rejected the Codex CLI login. Run codex once, or connect a browser session."
        case (.gemini, _):
            // No Gemini CLI source exists yet (D-09).
            return ""
        }
    }
}
