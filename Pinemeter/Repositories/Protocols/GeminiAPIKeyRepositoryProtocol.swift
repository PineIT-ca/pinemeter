//
//  GeminiAPIKeyRepositoryProtocol.swift
//  Pinemeter
//
//  Created by GSD on 2026-06-24.
//

import Foundation

/// Stable Gemini credential storage identifiers.
///
/// The service name is part of the security boundary: durable Gemini API keys belong in a dedicated
/// Keychain item namespace, not in `AppSettings`, `UserDefaults`, logs, or shared Claude/ChatGPT
/// credential accounts.
enum GeminiAPIKeyStorage {
    static let serviceName = "com.pinemeter.gemini.api-key"
    static let defaultAccount = "gemini"
}

/// Credential-equivalent Gemini API key material.
///
/// The raw value must only cross secure storage boundaries and must never be
/// encoded into settings, logs, diagnostics, or user-facing errors.
struct GeminiAPIKey: Equatable, Sendable, CustomDebugStringConvertible {
    let value: String

    init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw GeminiAPIKeyRepositoryError.invalidAPIKey
        }
        self.value = trimmed
    }

    var debugDescription: String {
        "GeminiAPIKey(<redacted>)"
    }
}

/// Sanitized persisted/acquisition state safe for settings, diagnostics, and logs.
struct GeminiAPIKeyAcquisitionStatus: Equatable, Sendable, CustomDebugStringConvertible {
    let state: GeminiAPIKeyAcquisitionState
    let lastErrorCategory: GeminiAPIKeyFailureCategory?

    var debugDescription: String {
        "GeminiAPIKeyAcquisitionStatus(state: \(state), lastErrorCategory: \(String(describing: lastErrorCategory)))"
    }
}

enum GeminiAPIKeyAcquisitionState: String, Equatable, Sendable {
    case available
    case missing
    case invalid
    case storageUnavailable
}

enum GeminiAPIKeyFailureCategory: String, Equatable, Sendable {
    case notFound
    case invalidAPIKey
    case keychainReadFailed
    case keychainWriteFailed
    case keychainDeleteFailed
}

extension GeminiAPIKeyAcquisitionState {
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

extension GeminiAPIKeyFailureCategory {
    var credentialFailureCategory: CredentialFailureCategory {
        switch self {
        case .notFound:
            return .missing
        case .invalidAPIKey:
            return .providerRejected
        case .keychainReadFailed, .keychainWriteFailed, .keychainDeleteFailed:
            return .storageUnavailable
        }
    }
}

enum GeminiAPIKeyRepositoryError: LocalizedError, Equatable {
    case invalidAPIKey
    case notFound
    case secureStorageUnavailable(GeminiAPIKeyFailureCategory)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Gemini API key is empty or invalid."
        case .notFound:
            return "Gemini API key is not stored."
        case .secureStorageUnavailable(let category):
            return "Gemini secure API key storage failed: \(category)."
        }
    }
}

/// Secure boundary for Gemini API key material.
///
/// Implementations may persist raw API keys only in Keychain under
/// `GeminiAPIKeyStorage.serviceName`. Status methods must return sanitized enum state only.
protocol GeminiAPIKeyRepositoryProtocol: Actor {
    func save(_ apiKey: GeminiAPIKey, account: String) async throws
    func load(account: String) async throws -> GeminiAPIKey
    func validate(account: String) async -> GeminiAPIKeyAcquisitionStatus
    func clear(account: String) async throws
}
