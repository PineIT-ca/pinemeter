//
//  ChatGPTSessionRepositoryProtocol.swift
//  Pinemeter
//
//  Created by GSD on 2026-06-18.
//

import Foundation

/// Credential-equivalent ChatGPT session material.
///
/// The session cookie is durable credential material and must only cross secure storage
/// boundaries. The access token is intentionally transient and must never be persisted.
struct ChatGPTSession: Equatable, Sendable {
    let sessionCookie: String
    let accessToken: String?

    init(sessionCookie: String, accessToken: String? = nil) {
        self.sessionCookie = sessionCookie
        self.accessToken = accessToken
    }
}

/// Sanitized persisted/acquisition state safe for settings, diagnostics, and logs.
struct ChatGPTSessionAcquisitionStatus: Equatable, Sendable, CustomDebugStringConvertible {
    let state: ChatGPTSessionAcquisitionState
    let lastErrorCategory: ChatGPTSessionFailureCategory?

    var debugDescription: String {
        "ChatGPTSessionAcquisitionStatus(state: \(state), lastErrorCategory: \(String(describing: lastErrorCategory)))"
    }
}

enum ChatGPTSessionAcquisitionState: String, Equatable, Sendable {
    case available
    case missing
    case invalid
    case storageUnavailable
}

enum ChatGPTSessionFailureCategory: String, Equatable, Sendable {
    case notFound
    case invalidSessionCookie
    case keychainReadFailed
    case keychainWriteFailed
    case keychainDeleteFailed
}

extension ChatGPTSessionAcquisitionState {
    var credentialHealth: CredentialHealthState {
        switch self {
        case .available:
            return .valid
        case .missing:
            return .missing
        case .invalid:
            return .invalid
        case .storageUnavailable:
            return .unavailable
        }
    }

    var defaultFailureCategory: CredentialFailureCategory? {
        switch self {
        case .available:
            return nil
        case .missing:
            return .missing
        case .invalid:
            return .providerRejected
        case .storageUnavailable:
            return .storageUnavailable
        }
    }
}

extension ChatGPTSessionFailureCategory {
    var credentialFailureCategory: CredentialFailureCategory {
        switch self {
        case .notFound:
            return .missing
        case .invalidSessionCookie:
            return .providerRejected
        case .keychainReadFailed, .keychainWriteFailed, .keychainDeleteFailed:
            return .storageUnavailable
        }
    }
}

enum ChatGPTSessionRepositoryError: LocalizedError, Equatable {
    case invalidSessionCookie
    case notFound
    case secureStorageUnavailable(ChatGPTSessionFailureCategory)

    var errorDescription: String? {
        switch self {
        case .invalidSessionCookie:
            return "ChatGPT session cookie is empty or invalid."
        case .notFound:
            return "ChatGPT session is not stored."
        case .secureStorageUnavailable(let category):
            return "ChatGPT secure session storage failed: \(category)."
        }
    }
}

protocol ChatGPTSessionRepositoryProtocol: Actor {
    func save(_ session: ChatGPTSession, account: String) async throws
    func load(account: String) async throws -> ChatGPTSession
    func validate(account: String) async -> ChatGPTSessionAcquisitionStatus
    func clear(account: String) async throws
}
