//
//  AppError.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

/// Application-level errors with user-facing messages
enum AppError: LocalizedError {
    case noSessionKey
    case networkError(NetworkError)
    case keychainError(KeychainError)
    case sessionKeyInvalid
    case apiResponseInvalid
    case organizationNotFound
    case cacheCorrupted

    var errorDescription: String? {
        switch self {
        case .noSessionKey:
            return "No Claude session key found. Please complete setup."
        case .networkError(let error):
            return error.localizedDescription
        case .keychainError(let error):
            return error.localizedDescription
        case .sessionKeyInvalid:
            return "Claude session key is invalid or expired. Please update in settings."
        case .apiResponseInvalid:
            return "Unable to parse usage data from server."
        case .organizationNotFound:
            return "No organizations found for this account."
        case .cacheCorrupted:
            return "Cached data is corrupted. Fetching fresh data..."
        }
    }

    /// Whether error is recoverable without user action
    var isRecoverable: Bool {
        switch self {
        case .networkError, .cacheCorrupted, .apiResponseInvalid:
            return true
        case .noSessionKey, .sessionKeyInvalid, .organizationNotFound, .keychainError:
            return false
        }
    }

    /// User action to resolve error
    var recoveryAction: String? {
        switch self {
        case .noSessionKey:
            return "Complete Claude Setup"
        case .sessionKeyInvalid:
            return "Update Claude Session Key"
        case .networkError:
            return "Retry"
        case .organizationNotFound:
            return "Check Account"
        default:
            return nil
        }
    }
}
