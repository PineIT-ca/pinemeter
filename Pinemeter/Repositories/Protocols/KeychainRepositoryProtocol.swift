//
//  KeychainRepositoryProtocol.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

/// Outcome of an explicit Claude credential repair attempt.
enum ClaudeCredentialRepairResult: Equatable {
    /// No existing credential was found, so a new scoped Keychain item was created.
    case created

    /// An existing credential was found and its value was updated in place.
    case updated
}

/// Protocol for secure keychain operations
protocol KeychainRepositoryProtocol: Actor {
    /// Save session key to keychain
    func save(sessionKey: String, account: String) async throws

    /// Explicitly repair or re-save a Claude session key without broad Keychain deletes.
    func repairClaudeSessionKey(_ sessionKey: String, account: String) async throws -> ClaudeCredentialRepairResult

    /// Retrieve session key from keychain
    func retrieve(account: String) async throws -> String

    /// Update existing session key
    func update(sessionKey: String, account: String) async throws

    /// Delete session key from keychain
    func delete(account: String) async throws

    /// Check if session key exists for account
    func exists(account: String) async -> Bool
}
