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

    var sessionKey: String? {
        sessionKeysByAccount["default"]
    }

    var hasSessionKey: Bool {
        sessionKeysByAccount["default"] != nil
    }

    func save(sessionKey: String, account: String) async throws {
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
        sessionKeysByAccount[account] = nil
    }

    func exists(account: String) async -> Bool {
        sessionKeysByAccount[account] != nil
    }
}
