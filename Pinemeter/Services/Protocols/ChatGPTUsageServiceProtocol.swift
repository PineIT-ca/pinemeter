//
//  ChatGPTUsageServiceProtocol.swift
//  Pinemeter
//

import Foundation

protocol ChatGPTUsageServiceProtocol: Sendable {
    func fetchUsage() async throws -> ChatGPTUsageData
    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData
    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool
}

protocol ChatGPTHTTPClientProtocol: Sendable {
    func request<T: Decodable>(
        _ endpoint: String,
        cookieHeader: String,
        authorization: String?,
        referer: String
    ) async throws -> T
}
