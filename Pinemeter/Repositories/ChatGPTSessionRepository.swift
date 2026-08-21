//
//  ChatGPTSessionRepository.swift
//  Pinemeter
//
//  Created by GSD on 2026-06-18.
//

import Foundation
import Security

/// Secure boundary for ChatGPT session acquisition material.
///
/// Durable credential-equivalent cookies are stored in Keychain. Transient access
/// tokens are retained only in actor memory and intentionally disappear when the
/// repository is recreated. Sanitized acquisition status is stored separately from
/// AppSettings so diagnostics can recover state without credential leakage.
actor ChatGPTSessionRepository: ChatGPTSessionRepositoryProtocol {
    private let serviceName = "com.pinemeter.chatgpt.session"
    private let statusKeyPrefix = "ChatGPTSessionRepository.status"
    private let userDefaults: UserDefaults
    private var transientAccessTokens: [String: String] = [:]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func save(_ session: ChatGPTSession, account: String) async throws {
        let sessionCookie = session.sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sessionCookie.isEmpty == false else {
            persistStatus(.init(state: .invalid, lastErrorCategory: .invalidSessionCookie), account: account)
            throw ChatGPTSessionRepositoryError.invalidSessionCookie
        }

        guard let data = sessionCookie.data(using: .utf8) else {
            persistStatus(.init(state: .invalid, lastErrorCategory: .invalidSessionCookie), account: account)
            throw ChatGPTSessionRepositoryError.invalidSessionCookie
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
                try update(sessionCookieData: data, account: account)
            } catch {
                // The existing item can be un-updatable (e.g. created by a
                // build this binary can no longer access). Replace it.
                try replace(query: query, account: account)
            }
        } else if status != errSecSuccess {
            // A stale item written by a previous build can make SecItemAdd
            // fail with errSecItemNotFound instead of errSecDuplicateItem;
            // replacing (delete + add) clears it.
            try replace(query: query, account: account)
        }

        transientAccessTokens[account] = session.accessToken
        persistStatus(.init(state: .available, lastErrorCategory: nil), account: account)
    }

    func load(account: String) async throws -> ChatGPTSession {
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
            throw ChatGPTSessionRepositoryError.notFound
        }

        guard status == errSecSuccess else {
            persistStatus(.init(state: .storageUnavailable, lastErrorCategory: .keychainReadFailed), account: account)
            throw ChatGPTSessionRepositoryError.secureStorageUnavailable(.keychainReadFailed)
        }

        guard
            let data = result as? Data,
            let sessionCookie = String(data: data, encoding: .utf8),
            sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            persistStatus(.init(state: .invalid, lastErrorCategory: .invalidSessionCookie), account: account)
            throw ChatGPTSessionRepositoryError.invalidSessionCookie
        }

        persistStatus(.init(state: .available, lastErrorCategory: nil), account: account)
        return ChatGPTSession(sessionCookie: sessionCookie, accessToken: transientAccessTokens[account] ?? nil)
    }

    func validate(account: String) async -> ChatGPTSessionAcquisitionStatus {
        // Only trust a cached .invalid; a cached .storageUnavailable must not
        // short-circuit, or one transient Keychain failure sticks forever.
        // Re-probe the Keychain instead.
        if let status = persistedStatus(account: account), status.state == .invalid {
            return status
        }

        do {
            _ = try await load(account: account)
            return ChatGPTSessionAcquisitionStatus(state: .available, lastErrorCategory: nil)
        } catch ChatGPTSessionRepositoryError.notFound {
            if let status = persistedStatus(account: account), status.state != .available {
                return status
            }
            return ChatGPTSessionAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
        } catch ChatGPTSessionRepositoryError.invalidSessionCookie {
            return ChatGPTSessionAcquisitionStatus(state: .invalid, lastErrorCategory: .invalidSessionCookie)
        } catch ChatGPTSessionRepositoryError.secureStorageUnavailable(let category) {
            return ChatGPTSessionAcquisitionStatus(state: .storageUnavailable, lastErrorCategory: category)
        } catch {
            return ChatGPTSessionAcquisitionStatus(state: .storageUnavailable, lastErrorCategory: .keychainReadFailed)
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
        transientAccessTokens[account] = nil
        persistStatus(.init(state: .missing, lastErrorCategory: .notFound), account: account)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            persistStatus(.init(state: .storageUnavailable, lastErrorCategory: .keychainDeleteFailed), account: account)
            throw ChatGPTSessionRepositoryError.secureStorageUnavailable(.keychainDeleteFailed)
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
            throw ChatGPTSessionRepositoryError.secureStorageUnavailable(.keychainWriteFailed)
        }
    }

    private func update(sessionCookieData: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: sessionCookieData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            persistStatus(.init(state: .storageUnavailable, lastErrorCategory: .keychainWriteFailed), account: account)
            throw ChatGPTSessionRepositoryError.secureStorageUnavailable(.keychainWriteFailed)
        }
    }

    private func persistStatus(_ status: ChatGPTSessionAcquisitionStatus, account: String) {
        let encoded: [String: String] = [
            "state": status.state.rawValue,
            "lastErrorCategory": status.lastErrorCategory?.rawValue ?? "",
        ]
        userDefaults.set(encoded, forKey: statusKey(account: account))
    }

    private func persistedStatus(account: String) -> ChatGPTSessionAcquisitionStatus? {
        guard let encoded = userDefaults.dictionary(forKey: statusKey(account: account)) as? [String: String],
              let stateValue = encoded["state"],
              let state = ChatGPTSessionAcquisitionState(rawValue: stateValue) else {
            return nil
        }

        let category = encoded["lastErrorCategory"].flatMap { value in
            value.isEmpty ? nil : ChatGPTSessionFailureCategory(rawValue: value)
        } ?? nil

        return ChatGPTSessionAcquisitionStatus(state: state, lastErrorCategory: category)
    }

    private func statusKey(account: String) -> String {
        "\(statusKeyPrefix).\(account)"
    }
}
