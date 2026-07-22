//
//  GeminiUsageService.swift
//  Pinemeter
//
//  Created by GSD on 2026-06-24.
//

import Foundation

/// Normalized Gemini quota usage data.
struct GeminiUsageData: Codable, Equatable, Sendable {
    let label: String
    let usedPercent: Double
    let resetAt: Date?
    let lastUpdated: Date

    var percentage: Double {
        min(max(usedPercent, 0), 100)
    }

    var status: UsageStatus {
        switch percentage {
        case 0..<Constants.Thresholds.Status.warningStart:
            return .safe
        case Constants.Thresholds.Status.warningStart..<Constants.Thresholds.Status.criticalStart:
            return .warning
        default:
            return .critical
        }
    }
}

/// Flexible response for Gemini quota/usage endpoints.
///
/// The first integration ships with defensive decoding because Gemini quota
/// availability depends on the credential and Google surface available to the
/// user. Known responses can provide either direct quota fields or a populated
/// model list proving the credential is valid while quota remains unavailable.
struct GeminiUsageAPIResponse: Decodable, Equatable, Sendable {
    let usedPercent: Double?
    let limitLabel: String?
    let resetAt: Date?
    let models: [GeminiModelResponse]?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case limitLabel
        case resetAt
        case models
    }
}

struct GeminiModelResponse: Decodable, Equatable, Sendable {
    let name: String?
}

extension GeminiUsageAPIResponse {
    func toDomain(lastUpdated: Date = Date()) throws -> GeminiUsageData {
        if let usedPercent {
            return GeminiUsageData(
                label: limitLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Gemini API quota",
                usedPercent: usedPercent,
                resetAt: resetAt,
                lastUpdated: lastUpdated
            )
        }

        throw GeminiUsageError.quotaUnavailable
    }
}

actor GeminiUsageService: GeminiUsageServiceProtocol {
    static let defaultAPIKeyAccount = "generativelanguage.googleapis.com"

    private let httpClient: GeminiHTTPClientProtocol
    private let apiKeyRepository: any GeminiAPIKeyRepositoryProtocol
    private let now: @Sendable () -> Date
    private let baseURL = "https://generativelanguage.googleapis.com"

    init(
        httpClient: GeminiHTTPClientProtocol = GeminiHTTPClient(),
        apiKeyRepository: any GeminiAPIKeyRepositoryProtocol = GeminiAPIKeyRepository(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.httpClient = httpClient
        self.apiKeyRepository = apiKeyRepository
        self.now = now
    }

    func fetchUsage() async throws -> GeminiUsageData {
        let apiKey: GeminiAPIKey
        do {
            apiKey = try await apiKeyRepository.load(account: Self.defaultAPIKeyAccount)
        } catch GeminiAPIKeyRepositoryError.notFound {
            throw GeminiUsageError.missingAPIKey
        } catch GeminiAPIKeyRepositoryError.invalidAPIKey {
            throw GeminiUsageError.invalidAPIKey
        } catch GeminiAPIKeyRepositoryError.secureStorageUnavailable {
            throw GeminiUsageError.networkUnavailable
        }

        do {
            return try await fetchUsage(apiKey: apiKey)
        } catch GeminiUsageError.invalidAPIKey {
            try? await apiKeyRepository.clear(account: Self.defaultAPIKeyAccount)
            throw GeminiUsageError.invalidAPIKey
        }
    }

    func fetchUsage(apiKey: GeminiAPIKey) async throws -> GeminiUsageData {
        do {
            let response: GeminiUsageAPIResponse = try await httpClient.request(
                "\(baseURL)/v1beta/models",
                apiKey: apiKey
            )
            return try response.toDomain(lastUpdated: now())
        } catch GeminiUsageError.httpError(let statusCode) where statusCode == 401 || statusCode == 403 {
            throw GeminiUsageError.invalidAPIKey
        } catch let error as GeminiUsageError {
            throw error
        } catch {
            throw GeminiUsageError.networkUnavailable
        }
    }

    func validateAPIKey(_ apiKey: GeminiAPIKey) async throws -> Bool {
        do {
            _ = try await fetchUsage(apiKey: apiKey)
            return true
        } catch GeminiUsageError.invalidAPIKey, GeminiUsageError.missingAPIKey {
            return false
        } catch GeminiUsageError.httpError(let statusCode) where statusCode == 401 || statusCode == 403 {
            return false
        } catch GeminiUsageError.quotaUnavailable {
            return true
        }
    }
}

actor GeminiHTTPClient: GeminiHTTPClientProtocol {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .default) {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    func request<T: Decodable>(_ endpoint: String, apiKey: GeminiAPIKey) async throws -> T {
        guard endpoint.hasPrefix("https://"), var components = URLComponents(string: endpoint) else {
            throw GeminiUsageError.invalidResponse
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "key", value: apiKey.value))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw GeminiUsageError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.get.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Pinemeter", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GeminiUsageError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    throw GeminiUsageError.invalidAPIKey
                }
                throw GeminiUsageError.httpError(statusCode: httpResponse.statusCode)
            }

            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                return try decoder.decode(T.self, from: data)
            } catch {
                throw GeminiUsageError.invalidResponse
            }
        } catch let error as GeminiUsageError {
            throw error
        } catch {
            throw GeminiUsageError.networkUnavailable
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
