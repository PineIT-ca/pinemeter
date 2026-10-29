import Foundation

enum HostLoginProvider: String, Decodable, Sendable, Hashable {
    case claude
    case chatgpt

    var loginWord: String { self == .claude ? "claude" : "codex" }
    var displayName: String { self == .claude ? "Claude" : "Codex" }
}

enum HostLoginState: String, Decodable, Equatable, Sendable {
    case fresh
    case refreshFailed = "refresh_failed"
    case expired
    case challenged
}

enum HostCredentialSource: String, Decodable, Equatable, Sendable {
    case hostLogin = "host_login"
    case pushedCookie = "pushed_cookie"
    case none
}

struct HostLoginHealthDTO: Decodable, Equatable, Sendable {
    let state: HostLoginState
    let reason: String
    let refreshExpiresAt: Date?
    let lastRefreshAt: Date?
}

struct HostSourcesAccountDTO: Decodable, Equatable, Sendable {
    let provider: HostLoginProvider
    let id: String
    let verdict: HostStatusVerdict
    let observedAt: Date?
    let source: HostCredentialSource
    let hostLogin: Bool
    let login: HostLoginHealthDTO?
}

struct HostSourcesDTO: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let acceptedGeneration: UInt64
    let accounts: [HostSourcesAccountDTO]

    static let validLoginReasons: Set<String> = [
        "", "rate_limited", "server_error", "transport", "rejected", "invalid_response",
        "persist_failed", "lock_busy", "unsupported_client", "unsupported_login", "invalid_endpoint",
        "invalid_grant", "refresh_expired", "refresh_reused", "refresh_revoked", "no_refresh",
        "challenge_refresh", "challenge_usage",
    ]
}

struct RemoteHostLoginDisplay: Equatable, Sendable {
    let rows: [HostSourcesAccountDTO]
    let fetchedAt: Date?
    let isCurrent: Bool
}
