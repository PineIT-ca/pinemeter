//
//  GeminiAPIKeyRepository.swift
//  Pinemeter
//
//  Created by GSD on 2026-06-24.
//

import Foundation
import Security

/// Secure boundary for Gemini API key material.
///
/// Durable credential-equivalent API keys are stored in Keychain. Sanitized
/// acquisition status is stored separately from AppSettings so diagnostics can
/// recover state without credential leakage.
actor GeminiAPIKeyRepository: GeminiAPIKeyRepositoryProtocol {
    private let serviceName = "com.pinemeter.gemini.api-key"
    private let statusKeyPrefix = "GeminiAPIKeyRepository.status"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func save(_ apiKey: GeminiAPIKey, account: String) async throws {
        let trimmedKey = apiKey.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.isEmpty == false, let data = trimmedKey.data(using: .utf8) else {
            persistStatus(.init(state: .invalid, lastErrorCategory: .invalidAPIKey), account: account)
            throw GeminiAPIKeyRepositoryError.invalidAPIKey
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
            do {
                try update(apiKeyData: data, account: account)
            } catch {
                // The existing item can be un-updatable (e.g. created by a
                // build this binary can no longer access). Replace it.
                try replace(query: query, account: account)
            }
        } else if status != errSecSuccess {
            persistStatus(.init(state: .storageUnavailable, lastErrorCategory: .keychainWriteFailed), account: account)
            throw GeminiAPIKeyRepositoryError.secureStorageUnavailable(.keychainWriteFailed)
        }

        persistStatus(.init(state: .available, lastErrorCategory: nil), account: account)
    }

    func load(account: String) async throws -> GeminiAPIKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            persistStatus(.init(state: .missing, lastErrorCategory: .notFound), account: account)
            throw GeminiAPIKeyRepositoryError.notFound
        }

        guard status == errSecSuccess else {
            persistStatus(.init(state: .storageUnavailable, lastErrorCategory: .keychainReadFailed), account: account)
            throw GeminiAPIKeyRepositoryError.secureStorageUnavailable(.keychainReadFailed)
        }

        guard
            let data = result as? Data,
            let rawValue = String(data: data, encoding: .utf8)
        else {
            persistStatus(.init(state: .invalid, lastErrorCategory: .invalidAPIKey), account: account)
            throw GeminiAPIKeyRepositoryError.invalidAPIKey
        }

        do {
            let apiKey = try GeminiAPIKey(rawValue)
            persistStatus(.init(state: .available, lastErrorCategory: nil), account: account)
            return apiKey
        } catch GeminiAPIKeyRepositoryError.invalidAPIKey {
            persistStatus(.init(state: .invalid, lastErrorCategory: .invalidAPIKey), account: account)
            throw GeminiAPIKeyRepositoryError.invalidAPIKey
        } catch {
            persistStatus(.init(state: .invalid, lastErrorCategory: .invalidAPIKey), account: account)
            throw GeminiAPIKeyRepositoryError.invalidAPIKey
        }
    }

    func validate(account: String) async -> GeminiAPIKeyAcquisitionStatus {
        // Only trust a cached .invalid; a cached .storageUnavailable must not
        // short-circuit, or one transient Keychain failure sticks forever.
        // Re-probe the Keychain instead.
        if let status = persistedStatus(account: account), status.state == .invalid {
            return status
        }

        do {
            _ = try await load(account: account)
            return GeminiAPIKeyAcquisitionStatus(state: .available, lastErrorCategory: nil)
        } catch GeminiAPIKeyRepositoryError.notFound {
            if let status = persistedStatus(account: account), status.state != .available {
                return status
            }
            return GeminiAPIKeyAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
        } catch GeminiAPIKeyRepositoryError.invalidAPIKey {
            return GeminiAPIKeyAcquisitionStatus(state: .invalid, lastErrorCategory: .invalidAPIKey)
        } catch GeminiAPIKeyRepositoryError.secureStorageUnavailable(let category) {
            return GeminiAPIKeyAcquisitionStatus(state: .storageUnavailable, lastErrorCategory: category)
        } catch {
            return GeminiAPIKeyAcquisitionStatus(state: .storageUnavailable, lastErrorCategory: .keychainReadFailed)
        }
    }

    func clear(account: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]

        let status = SecItemDelete(query as CFDictionary)
        persistStatus(.init(state: .missing, lastErrorCategory: .notFound), account: account)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            persistStatus(.init(state: .storageUnavailable, lastErrorCategory: .keychainDeleteFailed), account: account)
            throw GeminiAPIKeyRepositoryError.secureStorageUnavailable(.keychainDeleteFailed)
        }
    }

    private func replace(query: [String: Any], account: String) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            persistStatus(.init(state: .storageUnavailable, lastErrorCategory: .keychainWriteFailed), account: account)
            throw GeminiAPIKeyRepositoryError.secureStorageUnavailable(.keychainWriteFailed)
        }
    }

    private func update(apiKeyData: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: apiKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            persistStatus(.init(state: .storageUnavailable, lastErrorCategory: .keychainWriteFailed), account: account)
            throw GeminiAPIKeyRepositoryError.secureStorageUnavailable(.keychainWriteFailed)
        }
    }

    private func persistStatus(_ status: GeminiAPIKeyAcquisitionStatus, account: String) {
        let encoded: [String: String] = [
            "state": status.state.rawValue,
            "lastErrorCategory": status.lastErrorCategory?.rawValue ?? "",
        ]
        userDefaults.set(encoded, forKey: statusKey(account: account))
    }

    private func persistedStatus(account: String) -> GeminiAPIKeyAcquisitionStatus? {
        guard let encoded = userDefaults.dictionary(forKey: statusKey(account: account)) as? [String: String],
              let stateValue = encoded["state"],
              let state = GeminiAPIKeyAcquisitionState(rawValue: stateValue) else {
            return nil
        }

        let category = encoded["lastErrorCategory"].flatMap { value in
            value.isEmpty ? nil : GeminiAPIKeyFailureCategory(rawValue: value)
        } ?? nil

        return GeminiAPIKeyAcquisitionStatus(state: state, lastErrorCategory: category)
    }

    private func statusKey(account: String) -> String {
        "\(statusKeyPrefix).\(account)"
    }
}
