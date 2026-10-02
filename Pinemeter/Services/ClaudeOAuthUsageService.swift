//
//  ClaudeOAuthUsageService.swift
//  Pinemeter
//
//  Fetches Claude usage and organization identity using a Claude Code
//  login's own OAuth access token (CLI-04). The OAuth usage body has the
//  same `five_hour` / `seven_day` / `limits[]` shape the existing claude.ai
//  cookie path already decodes, including the `weekly_scoped` Fable row
//  (RESEARCH F-U2), so this service decodes it with the existing
//  `UsageAPIResponse.toDomain()` rather than a new response model.
//
//  Calls only `/api/oauth/usage` and `/api/oauth/profile` -- never a token or
//  refresh endpoint (D-06, T-19-18). Never retries, never persists or logs
//  the token or a response body, and logs only the request path and HTTP
//  status (D-08, T-19-17, mirroring NetworkService.swift / ChatGPTHTTPClient).
//

import Foundation
import os

actor ClaudeOAuthUsageService: ClaudeOAuthUsageServiceProtocol {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    private static let logger = Logger(subsystem: "com.pinemeter", category: "ClaudeOAuth")

    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func fetchUsage(accessToken: CLIAccessToken) async throws -> UsageData {
        let data = try await performRequest(url: Self.usageURL, accessToken: accessToken)
        do {
            return try JSONDecoder().decode(UsageAPIResponse.self, from: data).toDomain()
        } catch {
            // Covers both a JSONDecoder failure and `MappingError` from
            // `toDomain()` -- either way the caller only needs to know the
            // CLI token did not yield usable usage data.
            throw CLIUsageFetchError.invalidResponse
        }
    }

    func fetchProfileOrganization(accessToken: CLIAccessToken) async throws -> ClaudeOAuthProfileOrganization {
        let data = try await performRequest(url: Self.profileURL, accessToken: accessToken)
        guard let payload = try? JSONDecoder().decode(ProfilePayload.self, from: data),
              let uuidString = payload.organization?.uuid,
              let uuid = UUID(uuidString: uuidString) else {
            throw CLIUsageFetchError.invalidResponse
        }
        return ClaudeOAuthProfileOrganization(id: uuid, name: payload.organization?.name)
    }

    /// Decodes only `organization.uuid` and `organization.name` -- the
    /// account email and every other profile field are never decoded into
    /// anything this type keeps (D-08).
    private struct ProfilePayload: Decodable {
        struct Organization: Decodable {
            let uuid: String?
            let name: String?
        }
        let organization: Organization?
    }

    private func performRequest(url: URL, accessToken: CLIAccessToken) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue(accessToken.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        request.setValue(Constants.ClaudeCode.oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(Constants.ClaudeCode.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            Self.logger.warning(
                """
                Claude OAuth request failed: path=\(url.path, privacy: .public) \
                domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)
                """
            )
            throw CLIUsageFetchError.networkUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw CLIUsageFetchError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            Self.logger.warning(
                "Claude OAuth request failed: path=\(url.path, privacy: .public) http=\(http.statusCode, privacy: .public)"
            )
            if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 429 {
                throw CLIUsageFetchError.rejected
            }
            throw CLIUsageFetchError.httpError(statusCode: http.statusCode)
        }

        return data
    }
}
