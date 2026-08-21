//
//  GeminiUsageServiceProtocol.swift
//  Pinemeter
//
//  Created by GSD on 2026-06-24.
//

import Foundation

/// Sanitized Gemini monitoring errors. Cases must never include raw API keys or response bodies that
/// may echo credential material.
enum GeminiUsageError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case quotaUnavailable
    case invalidResponse
    case httpError(statusCode: Int)
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Gemini API key found. Add one in Settings."
        case .invalidAPIKey:
            return "Gemini API key is invalid. Update it in Settings."
        case .quotaUnavailable:
            return "Gemini quota data is unavailable for this credential."
        case .invalidResponse:
            return "Unable to parse Gemini usage data."
        case .httpError(let statusCode):
            return "Gemini quota request failed with HTTP \(statusCode)."
        case .networkUnavailable:
            return "Gemini quota data is unavailable. Check your connection and try again."
        }
    }
}

protocol GeminiUsageServiceProtocol: Sendable {
    func fetchUsage() async throws -> GeminiUsageData
    func fetchUsage(apiKey: GeminiAPIKey) async throws -> GeminiUsageData
    func validateAPIKey(_ apiKey: GeminiAPIKey) async throws -> Bool
}

protocol GeminiHTTPClientProtocol: Sendable {
    func request<T: Decodable>(
        _ endpoint: String,
        apiKey: GeminiAPIKey
    ) async throws -> T
}
