//
//  KeychainRepositoryTests.swift
//  PinemeterTests
//
//  Created by GSD on 2026-06-18.
//

import XCTest
@testable import Pinemeter

final class KeychainRepositoryTests: XCTestCase {
    private var accountsToCleanUp: [String] = []

    override func tearDown() async throws {
        let repository = KeychainRepository()
        for account in accountsToCleanUp {
            try? await repository.delete(account: account)
        }
        accountsToCleanUp.removeAll()
        try await super.tearDown()
    }

    func testRepairClaudeSessionKeyCreatesMissingCredential() async throws {
        let repository = KeychainRepository()
        let account = uniqueAccount()

        let result = try await repository.repairClaudeSessionKey("sk-ant-repaired-created", account: account)

        XCTAssertEqual(result, .created)
        let storedKey = try await repository.retrieve(account: account)
        XCTAssertEqual(storedKey, "sk-ant-repaired-created")
    }

    func testRepairClaudeSessionKeyUpdatesExistingCredential() async throws {
        let repository = KeychainRepository()
        let account = uniqueAccount()
        try await repository.save(sessionKey: "sk-ant-original", account: account)

        let result = try await repository.repairClaudeSessionKey("sk-ant-repaired-updated", account: account)

        XCTAssertEqual(result, .updated)
        let storedKey = try await repository.retrieve(account: account)
        XCTAssertEqual(storedKey, "sk-ant-repaired-updated")
    }

    func testRepairClaudeSessionKeyDoesNotDeleteOtherAccounts() async throws {
        let repository = KeychainRepository()
        let account = uniqueAccount()
        let otherAccount = uniqueAccount()
        try await repository.save(sessionKey: "sk-ant-other-account", account: otherAccount)

        let result = try await repository.repairClaudeSessionKey("sk-ant-repaired-account", account: account)

        XCTAssertEqual(result, .created)
        let otherStoredKey = try await repository.retrieve(account: otherAccount)
        XCTAssertEqual(otherStoredKey, "sk-ant-other-account")
    }

    private func uniqueAccount() -> String {
        let account = "KeychainRepositoryTests.\(UUID().uuidString)"
        accountsToCleanUp.append(account)
        return account
    }
}
