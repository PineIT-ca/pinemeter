//
//  KeychainRepositoryFake.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import Foundation
@testable import Pinemeter

actor KeychainRepositoryFake: KeychainRepositoryProtocol {
    private var sessionKeysByAccount: [String: String] = [:]
    /// Counts `save(sessionKey:account:)` calls only -- not
    /// `repairClaudeSessionKey`, which is a distinct repair path with its own
    /// call sites. Used by CLI-source tests (phase 19) to prove a CLI login
    /// or a CLI failure never writes a stored Claude session key (D-04).
    private(set) var saveCallCount = 0
    /// Counts `delete(account:)` calls, for the same D-04 assertion.
    private(set) var deleteCallCount = 0

    var sessionKey: String? {
        sessionKeysByAccount["default"]
    }

    var hasSessionKey: Bool {
        sessionKeysByAccount["default"] != nil
    }

    func save(sessionKey: String, account: String) async throws {
        saveCallCount += 1
        sessionKeysByAccount[account] = sessionKey
    }

    func repairClaudeSessionKey(_ sessionKey: String, account: String) async throws -> ClaudeCredentialRepairResult {
        let result: ClaudeCredentialRepairResult = sessionKeysByAccount[account] == nil ? .created : .updated
        sessionKeysByAccount[account] = sessionKey
        return result
    }

    func retrieve(account: String) async throws -> String {
        guard let sessionKey = sessionKeysByAccount[account] else {
            throw KeychainError.notFound
        }
        return sessionKey
    }

    func update(sessionKey: String, account: String) async throws {
        sessionKeysByAccount[account] = sessionKey
    }

    func delete(account: String) async throws {
        deleteCallCount += 1
        sessionKeysByAccount[account] = nil
    }

    func exists(account: String) async -> Bool {
        sessionKeysByAccount[account] != nil
    }
}
