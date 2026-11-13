//
//  ChatGPTSessionRepositoryTests.swift
//  PinemeterTests
//
//  Created by GSD on 2026-06-18.
//

import XCTest
@testable import Pinemeter

final class ChatGPTSessionRepositoryTests: XCTestCase {
    private var accountsToCleanUp: [String] = []

    override func tearDown() async throws {
        let repository = ChatGPTSessionRepository()
        for account in accountsToCleanUp {
            try? await repository.clear(account: account)
        }
        accountsToCleanUp.removeAll()
        try await super.tearDown()
    }

    func test_saveAndLoadPersistsCookieButKeepsAccessTokenTransient() async throws {
        let account = uniqueAccount()
        let repository = ChatGPTSessionRepository()
        let session = ChatGPTSession(
            sessionCookie: "__Secure-next-auth.session-token=synthetic-cookie-secret",
            accessToken: "synthetic-access-token-secret"
        )

        try await repository.save(session, account: account)

        let loadedSession = try await repository.load(account: account)
        XCTAssertEqual(loadedSession, session)

        let rehydratedRepository = ChatGPTSessionRepository()
        let rehydratedSession = try await rehydratedRepository.load(account: account)
        XCTAssertEqual(rehydratedSession.sessionCookie, session.sessionCookie)
        XCTAssertNil(rehydratedSession.accessToken, "Access tokens must remain transient and never be durably stored.")
    }

    func test_validateReturnsSanitizedAvailableStatusWithoutCredentialMaterial() async throws {
        let account = uniqueAccount()
        let repository = ChatGPTSessionRepository()
        try await repository.save(
            ChatGPTSession(
                sessionCookie: "__Secure-next-auth.session-token=synthetic-cookie-secret",
                accessToken: "synthetic-access-token-secret"
            ),
            account: account
        )

        let status = await repository.validate(account: account)

        XCTAssertEqual(status.state, .available)
        XCTAssertNil(status.lastErrorCategory)
        assertSanitized(status)
    }

    func test_validateClassifiesMissingSessionWithoutThrowing() async {
        let repository = ChatGPTSessionRepository()

        let status = await repository.validate(account: uniqueAccount(trackForCleanup: false))

        XCTAssertEqual(status.state, .missing)
        XCTAssertEqual(status.lastErrorCategory, .notFound)
        assertSanitized(status)
    }

    func test_saveRejectsBlankCookieAndRecordsSanitizedFailureCategory() async {
        let account = uniqueAccount()
        let repository = ChatGPTSessionRepository()

        do {
            try await repository.save(ChatGPTSession(sessionCookie: "   \n\t", accessToken: "synthetic-access-token-secret"), account: account)
            XCTFail("Expected blank ChatGPT session cookie to be rejected")
        } catch ChatGPTSessionRepositoryError.invalidSessionCookie {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let status = await repository.validate(account: account)
        XCTAssertEqual(status.state, .invalid)
        XCTAssertEqual(status.lastErrorCategory, .invalidSessionCookie)
        assertSanitized(status)
    }

    func test_clearRemovesDurableCookieAndTransientAccessToken() async throws {
        let account = uniqueAccount()
        let repository = ChatGPTSessionRepository()
        try await repository.save(
            ChatGPTSession(sessionCookie: "__Secure-next-auth.session-token=synthetic-cookie-secret", accessToken: "synthetic-access-token-secret"),
            account: account
        )

        try await repository.clear(account: account)

        do {
            _ = try await repository.load(account: account)
            XCTFail("Expected cleared ChatGPT session to be absent")
        } catch ChatGPTSessionRepositoryError.notFound {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let status = await repository.validate(account: account)
        XCTAssertEqual(status.state, .missing)
        XCTAssertEqual(status.lastErrorCategory, .notFound)
        assertSanitized(status)
    }

    private func uniqueAccount(trackForCleanup: Bool = true) -> String {
        let account = "ChatGPTSessionRepositoryTests.\(UUID().uuidString)"
        if trackForCleanup {
            accountsToCleanUp.append(account)
        }
        return account
    }

    private func assertSanitized(_ status: ChatGPTSessionAcquisitionStatus, file: StaticString = #filePath, line: UInt = #line) {
        let forbiddenFragments = [
            "synthetic-cookie-secret",
            "synthetic-access-token-secret",
            "__Secure-next-auth",
            "Cookie:",
            "Bearer"
        ]
        let statusDescription = String(describing: status)
        let debugDescription = status.debugDescription

        for fragment in forbiddenFragments {
            XCTAssertFalse(statusDescription.contains(fragment), "Status must not expose credential material: \(fragment)", file: file, line: line)
            XCTAssertFalse(debugDescription.contains(fragment), "Debug status must not expose credential material: \(fragment)", file: file, line: line)
        }
    }
}
