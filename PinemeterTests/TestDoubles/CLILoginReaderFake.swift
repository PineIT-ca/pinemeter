//
//  CLILoginReaderFake.swift
//  PinemeterTests
//
//  A scriptable `CLILoginReading` fake with synthetic logins. Non-private so
//  more than one test file can use it, mirroring `T3InstanceDiscoveryFake`.
//  Every login it builds carries the fixed synthetic token
//  "synthetic-access-token" -- never a real credential.
//

import Foundation
@testable import Pinemeter

actor CLILoginReaderFake: CLILoginReading {
    private(set) var snapshotCallCount = 0
    private var storedSnapshot: CLILoginSnapshot

    init(snapshot: CLILoginSnapshot = .empty) {
        self.storedSnapshot = snapshot
    }

    func setSnapshot(_ snapshot: CLILoginSnapshot) {
        self.storedSnapshot = snapshot
    }

    func snapshot() async -> CLILoginSnapshot {
        snapshotCallCount += 1
        return storedSnapshot
    }

    /// Builds a synthetic Codex CLI login. `expiresIn` is relative to `now`
    /// (negative/zero/small values build an already-expired or
    /// about-to-expire login for D-05 tests).
    static func codexLogin(
        chatgptUserId: String,
        accountId: String,
        expiresIn: TimeInterval,
        now: Date = Date()
    ) -> CodexCLILogin {
        CodexCLILogin(
            accessToken: CLIAccessToken("synthetic-access-token"),
            accountId: accountId,
            chatgptUserId: chatgptUserId,
            planType: "pro",
            email: "user@example.com",
            expiresAt: now.addingTimeInterval(expiresIn)
        )
    }

    /// Builds a synthetic Claude Code login.
    static func claudeLogin(
        organizationId: UUID,
        organizationName: String? = nil,
        expiresIn: TimeInterval,
        service: String = "Claude Code-credentials",
        now: Date = Date()
    ) -> ClaudeCodeLogin {
        ClaudeCodeLogin(
            accessToken: CLIAccessToken("synthetic-access-token"),
            expiresAt: now.addingTimeInterval(expiresIn),
            organizationId: organizationId,
            organizationName: organizationName,
            subscriptionType: "max",
            keychainService: service
        )
    }
}
