//
//  CredentialStatusService.swift
//  Pinemeter
//

import Foundation

/// Keychain-backed credential status reporter that never reads or returns raw credential values.
struct CredentialStatusService: CredentialStatusServiceProtocol {
    private let keychainRepository: KeychainRepositoryProtocol

    init(keychainRepository: KeychainRepositoryProtocol = KeychainRepository()) {
        self.keychainRepository = keychainRepository
    }

    func status(for provider: CredentialProvider) async -> ProviderCredentialStatus {
        let exists = await keychainRepository.exists(account: provider.keychainAccount)
        return ProviderCredentialStatus(
            identity: provider.credentialIdentity,
            state: exists ? .valid : .missing
        )
    }

    func statuses() async -> [ProviderCredentialStatus] {
        var results: [ProviderCredentialStatus] = []
        results.reserveCapacity(CredentialProvider.allCases.count)

        for provider in CredentialProvider.allCases {
            results.append(await status(for: provider))
        }

        return results
    }
}

private extension CredentialProvider {
    var credentialIdentity: CredentialIdentity {
        switch self {
        case .claude:
            CredentialIdentity(provider: .claude, kind: .sessionKey)
        case .chatGPT:
            CredentialIdentity(provider: .chatGPT, kind: .sessionCookie)
        case .gemini:
            CredentialIdentity(provider: .gemini, kind: .apiKey)
        }
    }

    var keychainAccount: String {
        switch self {
        case .claude:
            "default"
        case .chatGPT:
            "chatgpt"
        case .gemini:
            "gemini"
        }
    }
}
