//
//  CLILoginReadingProtocol.swift
//  Pinemeter
//

import Foundation

/// A source of CLI logins, read once per poll cycle. `CLILoginService` is
/// the real implementation; `NullCLILoginReader` is the test-safe default
/// (CLI-10) so a test that forgets to inject a fake never reads the
/// developer's real `auth.json` or Keychain.
protocol CLILoginReading: Sendable {
    func snapshot() async -> CLILoginSnapshot
}

/// A source of Claude Code logins, mapped to the `ClaudeAccount` org UUID
/// each belongs to. Injected into `CLILoginService` so plan 19-05 can supply
/// the real Keychain-backed implementation without this plan depending on
/// it.
protocol ClaudeCodeLoginSource: Sendable {
    func logins(now: Date) async -> [ClaudeCodeLogin]
}

/// Answers every snapshot with `.empty`. The default `CLILoginReading` under
/// XCTest (CLI-10), matching the `T3NullInstanceDiscovery` /
/// `ChatGPTUsageNullCacheRepository` pattern already used for other
/// test-unsafe defaults in `AppModel`.
struct NullCLILoginReader: CLILoginReading {
    func snapshot() async -> CLILoginSnapshot {
        .empty
    }
}
