//
//  CLILoginService.swift
//  Pinemeter
//

import Foundation

/// Combines the Codex CLI reader and an optional Claude Code login source
/// into one `CLILoginReading.snapshot()` call, taken once per poll cycle
/// (mirrors `AppModel.resolveCodexWorkspace()`'s once-per-cycle pattern).
///
/// With `claudeSource` nil (the plan 19-01 default), `snapshot()` never
/// touches the Keychain. `CLILoginService.live()` supplies the real
/// `ClaudeCodeLoginPipeline` (plan 19-05).
///
/// `snapshot()` is single-flight: two overlapping calls share one underlying
/// read instead of each starting their own. The in-flight task is recorded
/// and consulted before any `await`, so actor reentrancy can never let a
/// second overlapping call start a second read. An actor, so the
/// file/Keychain work this does runs off the main actor.
actor CLILoginService: CLILoginReading {
    private let codexEnvironment: [String: String]
    private let claudeSource: (any ClaudeCodeLoginSource)?
    private let now: @Sendable () -> Date
    private var inFlight: Task<CLILoginSnapshot, Never>?

    init(
        codexEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        claudeSource: (any ClaudeCodeLoginSource)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.codexEnvironment = codexEnvironment
        self.claudeSource = claudeSource
        self.now = now
    }

    /// The production `CLILoginReading`: the real Codex CLI reader plus the
    /// real Claude Code login pipeline (Keychain reader + organization
    /// resolver, both reading real files/Keychain items and calling the real
    /// Claude OAuth endpoints only as a fallback). `defaultCLILoginReader()`
    /// in `AppModel` returns this outside XCTest.
    static func live() -> CLILoginService {
        let profileService = ClaudeOAuthUsageService()
        let resolver = ClaudeCodeOrganizationResolver(profileService: profileService)
        let reader = ClaudeCodeLoginReader()
        let pipeline = ClaudeCodeLoginPipeline(reader: reader, resolver: resolver)
        return CLILoginService(claudeSource: pipeline)
    }

    func snapshot() async -> CLILoginSnapshot {
        if let inFlight {
            return await inFlight.value
        }
        let currentTime = now()
        let codexEnvironment = codexEnvironment
        let claudeSource = claudeSource
        let task = Task<CLILoginSnapshot, Never> {
            let codex = CodexCLILoginReader.read(environment: codexEnvironment, now: currentTime)
            let claude = await claudeSource?.logins(now: currentTime) ?? []
            return CLILoginSnapshot(codex: codex, claude: claude)
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }
}

/// Combines a Claude Code Keychain login (plan 19-02) with its organization
/// mapping (plan 19-03) into the `[ClaudeCodeLogin]` `CLILoginService`
/// expects, then deduplicates so a poll cycle sees at most one current login
/// per organization (CLI-02, CLI-03).
actor ClaudeCodeLoginPipeline: ClaudeCodeLoginSource {
    private let reader: ClaudeCodeLoginReader
    private let resolver: ClaudeCodeOrganizationResolver

    init(reader: ClaudeCodeLoginReader, resolver: ClaudeCodeOrganizationResolver) {
        self.reader = reader
        self.resolver = resolver
    }

    func logins(now: Date) async -> [ClaudeCodeLogin] {
        let credentials = await reader.readCredentials(now: now)
        var logins: [ClaudeCodeLogin] = []
        for credential in credentials {
            guard let organization = await resolver.organization(for: credential) else { continue }
            logins.append(ClaudeCodeLogin(
                accessToken: credential.accessToken,
                expiresAt: credential.expiresAt,
                organizationId: organization.id,
                organizationName: organization.name,
                subscriptionType: credential.subscriptionType,
                keychainService: credential.service
            ))
        }
        return Self.deduplicated(logins, now: now)
    }

    /// Drops anything already expired (D-05), then keeps at most one login
    /// per organization: the latest `expiresAt` wins; on a tie, the
    /// unsuffixed `"Claude Code-credentials"` service wins over a suffixed
    /// one; on a further tie (two suffixed services, equal expiry), the
    /// lower service name wins. Output is sorted by organization UUID string
    /// ascending, so the result order never depends on read/resolve timing.
    static func deduplicated(_ logins: [ClaudeCodeLogin], now: Date) -> [ClaudeCodeLogin] {
        var bestByOrganization: [UUID: ClaudeCodeLogin] = [:]
        for login in logins {
            guard !login.isExpired(now: now) else { continue }
            guard let existing = bestByOrganization[login.organizationId] else {
                bestByOrganization[login.organizationId] = login
                continue
            }
            if isPreferred(login, over: existing) {
                bestByOrganization[login.organizationId] = login
            }
        }
        return bestByOrganization.values.sorted { $0.organizationId.uuidString < $1.organizationId.uuidString }
    }

    private static let unsuffixedService = "Claude Code-credentials"

    private static func isPreferred(_ candidate: ClaudeCodeLogin, over existing: ClaudeCodeLogin) -> Bool {
        if candidate.expiresAt != existing.expiresAt {
            return candidate.expiresAt > existing.expiresAt
        }
        let candidateIsDefault = candidate.keychainService == unsuffixedService
        let existingIsDefault = existing.keychainService == unsuffixedService
        if candidateIsDefault != existingIsDefault {
            return candidateIsDefault
        }
        return candidate.keychainService < existing.keychainService
    }
}
