//
//  KeychainRepository.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation
import Security

/// Actor-isolated repository for secure Keychain operations
actor KeychainRepository: KeychainRepositoryProtocol {
    // Renaming this orphans every stored Claude session key; users must
    // reconnect via browser scan after a change.
    private let serviceName = "ca.pineit.pinemeter.sessionkey"

    /// Save session key to Keychain with security attributes
    func save(sessionKey: String, account: String) async throws {
        guard let data = sessionKey.data(using: .utf8) else {
            throw KeychainError.saveFailed(OSStatus: errSecParam)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Item already exists, update it instead
            try await update(sessionKey: sessionKey, account: account)
        } else if status != errSecSuccess {
            // A stale item written by a previous build can make SecItemAdd
            // fail with errSecItemNotFound instead of errSecDuplicateItem;
            // delete it and retry the add once before giving up.
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecAttrService as String: serviceName,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            let retryStatus = SecItemAdd(query as CFDictionary, nil)
            guard retryStatus == errSecSuccess else {
                throw KeychainError.saveFailed(OSStatus: retryStatus)
            }
        }
    }

    /// Explicitly repair or re-save a Claude session key without deleting existing Keychain items.
    func repairClaudeSessionKey(_ sessionKey: String, account: String) async throws -> ClaudeCredentialRepairResult {
        guard let data = sessionKey.data(using: .utf8) else {
            throw KeychainError.saveFailed(OSStatus: errSecParam)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return .updated
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.updateFailed(OSStatus: updateStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return .created
        }

        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if retryStatus == errSecSuccess {
                return .updated
            }
            throw KeychainError.updateFailed(OSStatus: retryStatus)
        }

        throw KeychainError.saveFailed(OSStatus: addStatus)
    }

    /// Retrieve session key from Keychain
    func retrieve(account: String) async throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let sessionKey = String(data: data, encoding: .utf8) else {
            throw KeychainError.notFound
        }

        return sessionKey
    }

    /// Update existing session key in Keychain
    func update(sessionKey: String, account: String) async throws {
        guard let data = sessionKey.data(using: .utf8) else {
            throw KeychainError.updateFailed(OSStatus: errSecParam)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        guard status == errSecSuccess else {
            throw KeychainError.updateFailed(OSStatus: status)
        }
    }

    /// Delete session key from Keychain
    func delete(account: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(OSStatus: status)
        }
    }

    /// Check if session key exists for account
    func exists(account: String) async -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}
