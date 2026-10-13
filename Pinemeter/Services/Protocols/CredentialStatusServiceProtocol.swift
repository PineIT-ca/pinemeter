//
//  CredentialStatusServiceProtocol.swift
//  Pinemeter
//

import Foundation

/// Sanitized credential availability for a provider credential. Never contains raw credential material.
struct ProviderCredentialStatus: Equatable, Sendable {
    let identity: CredentialIdentity
    let state: CredentialHealthState
}

/// Reports provider credential state without exposing raw secret values.
protocol CredentialStatusServiceProtocol: Sendable {
    func status(for provider: CredentialProvider) async -> ProviderCredentialStatus
    func statuses() async -> [ProviderCredentialStatus]
}
