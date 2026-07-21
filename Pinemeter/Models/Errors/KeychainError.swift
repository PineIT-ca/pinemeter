//
//  KeychainError.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

/// Errors that can occur during Keychain operations
enum KeychainError: LocalizedError {
    case saveFailed(OSStatus: OSStatus)
    case notFound
    case updateFailed(OSStatus: OSStatus)
    case deleteFailed(OSStatus: OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save to Keychain (status: \(status))"
        case .notFound:
            return "Session key not found in Keychain"
        case .updateFailed(let status):
            return "Failed to update Keychain (status: \(status))"
        case .deleteFailed(let status):
            return "Failed to delete from Keychain (status: \(status))"
        }
    }
}
