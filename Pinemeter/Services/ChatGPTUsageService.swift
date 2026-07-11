//
//  ChatGPTUsageService.swift
//  Pinemeter
//

import Foundation

enum ChatGPTUsageError: LocalizedError, Equatable {
    case missingSessionCookie
    case invalidSessionCookie
    case invalidResponse
    case httpError(statusCode: Int)
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .missingSessionCookie:
            return "No ChatGPT session cookie found. Add one in Settings."
        case .invalidSessionCookie:
            return "ChatGPT session is invalid or expired. Update it in Settings."
        case .invalidResponse:
            return "Unable to parse ChatGPT usage data."
        case .httpError(let statusCode):
            return "ChatGPT quota request failed with HTTP \(statusCode)."
        case .networkUnavailable:
            return "ChatGPT quota data is unavailable. Check your connection and try again."
        }
    }
}

actor ChatGPTUsageService: ChatGPTUsageServiceProtocol {
    static let defaultSessionAccount = "chatgpt.com"

    private let httpClient: ChatGPTHTTPClientProtocol
    private let sessionRepository: any ChatGPTSessionRepositoryProtocol
    private let now: @Sendable () -> Date
    private let baseURL = "https://chatgpt.com"

    init(
        httpClient: ChatGPTHTTPClientProtocol = ChatGPTHTTPClient(),
        sessionRepository: any ChatGPTSessionRepositoryProtocol = ChatGPTSessionRepository(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.httpClient = httpClient
        self.sessionRepository = sessionRepository
        self.now = now
    }

    func fetchUsage() async throws -> ChatGPTUsageData {
        let session: ChatGPTSession
        do {
            session = try await sessionRepository.load(account: Self.defaultSessionAccount)
        } catch ChatGPTSessionRepositoryError.notFound {
            throw ChatGPTUsageError.missingSessionCookie
        } catch ChatGPTSessionRepositoryError.invalidSessionCookie {
            throw ChatGPTUsageError.invalidSessionCookie
        } catch ChatGPTSessionRepositoryError.secureStorageUnavailable {
            throw ChatGPTUsageError.networkUnavailable
        }

        do {
            let (usage, accessToken) = try await fetchUsageAndAccessToken(sessionCookie: session.sessionCookie)
            try await sessionRepository.save(
                ChatGPTSession(sessionCookie: session.sessionCookie, accessToken: accessToken),
                account: Self.defaultSessionAccount
            )
            return usage
        } catch ChatGPTUsageError.invalidSessionCookie {
            try? await sessionRepository.clear(account: Self.defaultSessionAccount)
            throw ChatGPTUsageError.invalidSessionCookie
        } catch ChatGPTUsageError.missingSessionCookie {
            try? await sessionRepository.clear(account: Self.defaultSessionAccount)
            throw ChatGPTUsageError.missingSessionCookie
        }
    }

    func fetchUsage(sessionCookie: String) async throws -> ChatGPTUsageData {
        let (usage, _) = try await fetchUsageAndAccessToken(sessionCookie: sessionCookie)
        return usage
    }

    private func fetchUsageAndAccessToken(sessionCookie: String) async throws -> (ChatGPTUsageData, String) {
        let cookieHeader = Self.cookieHeader(from: sessionCookie)
        guard !cookieHeader.isEmpty else {
            throw ChatGPTUsageError.missingSessionCookie
        }

        let authSession: ChatGPTAuthSessionResponse = try await httpClient.request(
            "\(baseURL)/api/auth/session",
            cookieHeader: cookieHeader,
            authorization: nil,
            referer: "\(baseURL)/codex/settings/usage"
        )

        guard let accessToken = authSession.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            throw ChatGPTUsageError.invalidSessionCookie
        }

        let usage: ChatGPTWHAMUsageResponse = try await httpClient.request(
            "\(baseURL)/backend-api/wham/usage",
            cookieHeader: cookieHeader,
            authorization: "Bearer \(accessToken)",
            referer: "\(baseURL)/codex/settings/usage"
        )

        return (try usage.toDomain(lastUpdated: now()), accessToken)
    }

    func validateSessionCookie(_ sessionCookie: String) async throws -> Bool {
        do {
            _ = try await fetchUsage(sessionCookie: sessionCookie)
            return true
        } catch ChatGPTUsageError.missingSessionCookie {
            return false
        } catch ChatGPTUsageError.invalidSessionCookie {
            return false
        } catch ChatGPTUsageError.httpError(let statusCode) where statusCode == 401 || statusCode == 403 {
            return false
        }
    }

    /// Accept a raw session token, a full Cookie header, or split NextAuth/Auth.js cookie chunks.
    static func cookieHeader(from rawValue: String) -> String {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return "" }

        if !trimmedValue.contains("=") {
            return "__Secure-next-auth.session-token=\(trimmedValue)"
        }

        let cookiePairs = cookiePairs(from: trimmedValue)
        guard !cookiePairs.isEmpty else { return trimmedValue }

        for cookieName in sessionCookieNames {
            if let unsplitToken = cookiePairs.first(where: { $0.name == cookieName })?.value,
               !unsplitToken.isEmpty {
                return cookiePairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
        }

        for cookieName in sessionCookieNames {
            let splitPrefix = "\(cookieName)."
            let splitToken = cookiePairs
                .compactMap { pair -> (Int, String)? in
                    guard pair.name.hasPrefix(splitPrefix),
                          let index = Int(pair.name.dropFirst(splitPrefix.count)) else {
                        return nil
                    }
                    return (index, pair.value)
                }
                .sorted { $0.0 < $1.0 }
                .map(\.1)
                .joined()

            if !splitToken.isEmpty {
                let otherPairs = cookiePairs.filter { !$0.name.hasPrefix(splitPrefix) }
                return (["\(cookieName)=\(splitToken)"] + otherPairs.map { "\($0.name)=\($0.value)" })
                    .joined(separator: "; ")
            }
        }

        return cookiePairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static let sessionCookieNames = [
        "__Secure-next-auth.session-token",
        "__Secure-authjs.session-token",
    ]

    private static func cookiePairs(from rawValue: String) -> [(name: String, value: String)] {
        rawValue
            .replacingOccurrences(of: "Cookie:", with: "", options: [.caseInsensitive, .anchored])
            .split(whereSeparator: { $0 == ";" || $0 == "\n" || $0 == "\r" })
            .compactMap { part -> (name: String, value: String)? in
                let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separatorIndex = trimmedPart.firstIndex(of: "=") else { return nil }

                let name = trimmedPart[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = trimmedPart[trimmedPart.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return (String(name), String(value))
            }
    }
}

actor ChatGPTHTTPClient: ChatGPTHTTPClientProtocol {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .default) {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    func request<T: Decodable>(
        _ endpoint: String,
        cookieHeader: String,
        authorization: String?,
        referer: String
    ) async throws -> T {
        guard endpoint.hasPrefix("https://"), let url = URL(string: endpoint) else {
            throw ChatGPTUsageError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.get.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ChatGPTUsageError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    throw ChatGPTUsageError.invalidSessionCookie
                }
                throw ChatGPTUsageError.httpError(statusCode: httpResponse.statusCode)
            }

            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                return try decoder.decode(T.self, from: data)
            } catch {
                throw ChatGPTUsageError.invalidResponse
            }
        } catch let error as ChatGPTUsageError {
            throw error
        } catch {
            throw ChatGPTUsageError.networkUnavailable
        }
    }
}
