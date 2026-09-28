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
        referer: String
    ) async throws -> T
}
