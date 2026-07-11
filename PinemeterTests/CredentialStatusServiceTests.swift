//
//  CredentialStatusServiceTests.swift
//  PinemeterTests
//

import Foundation
import XCTest
@testable import Pinemeter

final class CredentialStatusServiceTests: XCTestCase {
    func test_statuses_reportMissingProvidersWhenNoCredentialsExist() async {
        let keychainRepository = CredentialStatusKeychainRepositoryStub(existingAccounts: [])
        let service = CredentialStatusService(keychainRepository: keychainRepository)

        let statuses = await service.statuses()

        XCTAssertEqual(statuses, [
            ProviderCredentialStatus(identity: CredentialIdentity(provider: .claude, kind: .sessionKey), state: .missing),
            ProviderCredentialStatus(identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie), state: .missing),
            ProviderCredentialStatus(identity: CredentialIdentity(provider: .gemini, kind: .apiKey), state: .missing),
        ])
        let requestedAccounts = await keychainRepository.recordedRequestedAccounts()
        XCTAssertEqual(requestedAccounts, ["default", "chatgpt", "gemini"])
    }

    func test_statuses_reportAvailableProvidersWithoutRetrievingSecretValues() async throws {
        let keychainRepository = CredentialStatusKeychainRepositoryStub(existingAccounts: ["default", "chatgpt", "gemini"])
        let service = CredentialStatusService(keychainRepository: keychainRepository)

        let statuses = await service.statuses()

        XCTAssertEqual(statuses, [
            ProviderCredentialStatus(identity: CredentialIdentity(provider: .claude, kind: .sessionKey), state: .valid),
            ProviderCredentialStatus(identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie), state: .valid),
            ProviderCredentialStatus(identity: CredentialIdentity(provider: .gemini, kind: .apiKey), state: .valid),
        ])
        let retrieveCallCount = await keychainRepository.recordedRetrieveCallCount()
        XCTAssertEqual(retrieveCallCount, 0)
    }

    func test_status_reportsSingleProviderCredentialState() async {
        let keychainRepository = CredentialStatusKeychainRepositoryStub(existingAccounts: ["chatgpt"])
        let service = CredentialStatusService(keychainRepository: keychainRepository)

        let claudeStatus = await service.status(for: .claude)
        let chatGPTStatus = await service.status(for: .chatGPT)
        let geminiStatus = await service.status(for: .gemini)

        XCTAssertEqual(claudeStatus, ProviderCredentialStatus(identity: CredentialIdentity(provider: .claude, kind: .sessionKey), state: .missing))
        XCTAssertEqual(chatGPTStatus, ProviderCredentialStatus(identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie), state: .valid))
        XCTAssertEqual(geminiStatus, ProviderCredentialStatus(identity: CredentialIdentity(provider: .gemini, kind: .apiKey), state: .missing))
    }
}

private actor CredentialStatusKeychainRepositoryStub: KeychainRepositoryProtocol {
    private let existingAccounts: Set<String>
    private(set) var requestedAccounts: [String] = []
    private(set) var retrieveCallCount = 0

    init(existingAccounts: Set<String>) {
        self.existingAccounts = existingAccounts
    }

    func save(sessionKey: String, account: String) async throws {}

    func repairClaudeSessionKey(_ sessionKey: String, account: String) async throws -> ClaudeCredentialRepairResult {
        existingAccounts.contains(account) ? .updated : .created
    }

    func retrieve(account: String) async throws -> String {
        retrieveCallCount += 1
        throw KeychainError.notFound
    }

    func update(sessionKey: String, account: String) async throws {}

    func delete(account: String) async throws {}

    func exists(account: String) async -> Bool {
        requestedAccounts.append(account)
        return existingAccounts.contains(account)
    }

    func recordedRequestedAccounts() -> [String] {
        requestedAccounts
    }

    func recordedRetrieveCallCount() -> Int {
        retrieveCallCount
    }
}
