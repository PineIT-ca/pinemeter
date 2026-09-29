//
//  ChatGPTUsageServiceProtocol.swift
//  Pinemeter
//

import Foundation

protocol ChatGPTUsageServiceProtocol: Sendable {
    func fetchUsage() async throws -> ChatGPTUsageData
    func fetchUsage(account: String) async throws -> ChatGPTUsageData
    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData
    func fetchUsageAndIdentity(
        account: String
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity)
    /// `chatgptAccountId`, when non-nil, is sent as the `chatgpt-account-id`
    /// header so the returned rows reflect that ChatGPT workspace rather
    /// than whichever one the server treats as ambient/default for the
    /// cookie. See pinemeter-private#126/#127.
    func fetchUsageAndIdentity(
        account: String,
        chatgptAccountId: String?
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity)
    func fetchUsageAndIdentity(
        sessionCookie: String
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity)
    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool
}

/// Single-account defaults. The real service overrides all of these; they exist
/// so a conformer that models only one account (chiefly a test double) answers
/// every account with the data it has, rather than having to restate the
/// account plumbing.
extension ChatGPTUsageServiceProtocol {
    func fetchUsage(account: String) async throws -> ChatGPTUsageData {
        try await fetchUsage()
    }

    func fetchUsageAndIdentity(
        account: String
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        (try await fetchUsage(account: account), .unidentified)
    }

    /// Conformers that do not model workspace selection (chiefly test
    /// doubles) ignore `chatgptAccountId` and answer from `fetchUsage`.
    func fetchUsageAndIdentity(
        account: String,
        chatgptAccountId: String?
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        try await fetchUsageAndIdentity(account: account)
    }

    func fetchUsageAndIdentity(
        sessionCookie: String
    ) async throws -> (usage: ChatGPTUsageData, identity: ChatGPTAccountIdentity) {
        (try await fetchUsage(sessionCookie: sessionCookie), .unidentified)
    }
}

protocol ChatGPTHTTPClientProtocol: Sendable {
    func request<T: Decodable>(
        _ endpoint: String,
        cookieHeader: String,
        authorization: String?,
        referer: String,
        chatgptAccountId: String?
    ) async throws -> T
}
