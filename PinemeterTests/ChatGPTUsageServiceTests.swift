//
//  ChatGPTUsageServiceTests.swift
//  PinemeterTests
//

import Foundation
import XCTest
@testable import Pinemeter

final class ChatGPTUsageServiceTests: XCTestCase {
    func test_chatGPTUsageData_usesWorstQuotaBucketForOverallStatus() {
        let data = ChatGPTUsageData(
            rows: [
                .init(label: "Codex Tasks", usedPercent: 12, resetAt: nil),
                .init(label: "Code Review", usedPercent: 92, resetAt: nil),
            ],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(data.percentage, 92)
        XCTAssertEqual(data.status, .critical)
    }

    func test_cookieHeader_acceptsRawSessionToken() {
        let header = ChatGPTUsageService.cookieHeader(from: " token-redacted \n")

        XCTAssertEqual(header, "__Secure-next-auth.session-token=token-redacted")
    }

    func test_cookieHeader_acceptsFullCookieHeader() {
        let header = ChatGPTUsageService.cookieHeader(from: "a=b; __Secure-next-auth.session-token=token-redacted")

        XCTAssertEqual(header, "a=b; __Secure-next-auth.session-token=token-redacted")
    }

    func test_cookieHeader_joinsSplitSessionTokenCookies() {
        let header = ChatGPTUsageService.cookieHeader(
            from: "__Secure-next-auth.session-token.0=first; __Secure-next-auth.session-token.1=second"
        )

        XCTAssertEqual(header, "__Secure-next-auth.session-token=firstsecond")
    }

    func test_cookieHeader_joinsSplitAuthJSSessionTokenCookies() {
        let header = ChatGPTUsageService.cookieHeader(
            from: "__Secure-authjs.session-token.0=first; __Secure-authjs.session-token.1=second"
        )

        XCTAssertEqual(header, "__Secure-authjs.session-token=firstsecond")
    }

    func test_cookieHeader_acceptsCookiePrefixAndNewlineSeparatedSplitCookies() {
        let header = ChatGPTUsageService.cookieHeader(
            from: "Cookie: __Secure-next-auth.session-token.0=first\n__Secure-next-auth.session-token.1=second"
        )

        XCTAssertEqual(header, "__Secure-next-auth.session-token=firstsecond")
    }

    func test_whamToDomain_classifiesMenuBarRowsAndPreservesUnknownRows() throws {
        let json = #"""
        {
          "rate_limit": {
            "primary_window": { "used_percent": 25, "reset_at": 1770000000 },
            "secondary_window": { "used_percent": 35, "reset_at": 1770600000 }
          },
          "code_review_rate_limit": { "primary_window": { "used_percent": 50, "reset_at": 1770003600 } },
          "additional_rate_limits": [
            { "type": "chatgpt_pro", "primary_window": { "used_percent": 40, "reset_at": 1770700000 } },
            { "name": "unknown_bucket", "primary_window": { "used_percent": 15, "reset_at": 1770800000 } }
          ]
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let response = try decoder.decode(ChatGPTWHAMUsageResponse.self, from: json)

        let usage = try response.toDomain(lastUpdated: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(usage.rows.map(\.sourceLabel), [
            "rate_limit",
            "rate_limit.secondary_window",
            "code_review_rate_limit",
            "chatgpt_pro",
            "unknown_bucket"
        ])
        XCTAssertEqual(usage.rows.map(\.label), [
            "ChatGPT 5h",
            "ChatGPT weekly",
            "Code Review",
            "ChatGPT Pro",
            "Unknown Bucket"
        ])
        XCTAssertEqual(usage.menuBarRows.map(\.menuBarRole), [.chatGPT5h, .chatGPTWeekly, .chatGPTPro])
        XCTAssertEqual(usage.menuBarRows.map(\.label), ["ChatGPT 5h", "ChatGPT weekly", "ChatGPT Pro"])

        let unknownRow = try XCTUnwrap(usage.rows.last)
        XCTAssertNil(unknownRow.menuBarRole)
        XCTAssertEqual(unknownRow.subtitle, "WHAM: unknown_bucket")
    }

    func test_fetchUsage_withBlankSessionCookie_throwsMissingSessionCookie() async {
        let service = ChatGPTUsageService(httpClient: ChatGPTHTTPClientStub())

        do {
            _ = try await service.fetchUsage(sessionCookie: "   ")
            XCTFail("Expected missing session cookie error")
        } catch ChatGPTUsageError.missingSessionCookie {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_fetchUsage_exchangesCookieForAccessTokenThenFetchesWhamUsage() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-06-05T12:00:00Z")!
        let httpClient = ChatGPTHTTPClientStub(
            responses: [
                "auth": #"{"accessToken":"access-token-redacted"}"#.data(using: .utf8)!,
                "usage": #"{"rate_limit":{"primary_window":{"used_percent":25,"reset_at":1770000000}},"code_review_rate_limit":{"primary_window":{"used_percent":50,"reset_at":1770003600}}}"#.data(using: .utf8)!
            ]
        )
        let service = ChatGPTUsageService(
            httpClient: httpClient,
            now: { now }
        )

        let usage = try await service.fetchUsage(sessionCookie: "session-token-redacted")

        XCTAssertEqual(usage.rows.map(\.label), ["ChatGPT 5h", "Code Review"])
        XCTAssertEqual(usage.rows.map(\.sourceLabel), ["rate_limit", "code_review_rate_limit"])
        XCTAssertEqual(usage.rows.map(\.usedPercent), [25, 50])
        XCTAssertEqual(usage.lastUpdated, now)

        let requests = await httpClient.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].endpoint.hasSuffix("/api/auth/session"))
        XCTAssertNil(requests[0].authorization)
        XCTAssertTrue(requests[1].endpoint.hasSuffix("/backend-api/wham/usage"))
        XCTAssertEqual(requests[1].authorization, "Bearer access-token-redacted")
        XCTAssertEqual(
            requests.map(\.cookieHeader),
            [
                "__Secure-next-auth.session-token=session-token-redacted",
                "__Secure-next-auth.session-token=session-token-redacted"
            ]
        )
    }

    func test_fetchUsage_loadsPersistedSessionAndStoresTransientAccessToken() async throws {
        let repository = ChatGPTSessionRepositoryStub()
        try await repository.save(ChatGPTSession(sessionCookie: "session-token-redacted"), account: ChatGPTUsageService.defaultSessionAccount)
        let httpClient = ChatGPTHTTPClientStub(
            responses: [
                "auth": #"{"accessToken":"access-token-redacted"}"#.data(using: .utf8)!,
                "usage": #"{"rate_limit":{"primary_window":{"used_percent":25,"reset_at":1770000000}}}"#.data(using: .utf8)!
            ]
        )
        let service = ChatGPTUsageService(httpClient: httpClient, sessionRepository: repository)

        _ = try await service.fetchUsage()

        let storedSession = try await repository.load(account: ChatGPTUsageService.defaultSessionAccount)
        XCTAssertEqual(storedSession.sessionCookie, "session-token-redacted")
        XCTAssertEqual(storedSession.accessToken, "access-token-redacted")
        let status = await repository.status
        XCTAssertEqual(status.state, .available)
    }

    func test_fetchUsage_withoutPersistedSessionReportsMissingSession() async {
        let repository = ChatGPTSessionRepositoryStub()
        let service = ChatGPTUsageService(httpClient: ChatGPTHTTPClientStub(), sessionRepository: repository)

        do {
            _ = try await service.fetchUsage()
            XCTFail("Expected missing session cookie error")
        } catch ChatGPTUsageError.missingSessionCookie {
            let status = await repository.status
            XCTAssertEqual(status.state, .missing)
            XCTAssertEqual(status.lastErrorCategory, .notFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_fetchUsage_withPersistedSessionClearsRepositoryWhenSessionIsInvalid() async throws {
        let repository = ChatGPTSessionRepositoryStub()
        try await repository.save(ChatGPTSession(sessionCookie: "session-token-redacted"), account: ChatGPTUsageService.defaultSessionAccount)
        let httpClient = ChatGPTHTTPClientStub(
            responses: ["auth": #"{}"#.data(using: .utf8)!]
        )
        let service = ChatGPTUsageService(httpClient: httpClient, sessionRepository: repository)

        do {
            _ = try await service.fetchUsage()
            XCTFail("Expected invalid session cookie error")
        } catch ChatGPTUsageError.invalidSessionCookie {
            let clearCalled = await repository.clearCalled
            let status = await repository.status
            XCTAssertTrue(clearCalled)
            XCTAssertEqual(status.state, .missing)
            XCTAssertEqual(status.lastErrorCategory, .notFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_fetchUsage_afterInvalidSessionClearCanReacquirePersistedSession() async throws {
        let repository = ChatGPTSessionRepositoryStub()
        try await repository.save(ChatGPTSession(sessionCookie: "expired-session-token-redacted"), account: ChatGPTUsageService.defaultSessionAccount)
        let invalidHTTPClient = ChatGPTHTTPClientStub(responses: ["auth": #"{}"#.data(using: .utf8)!])
        let invalidService = ChatGPTUsageService(httpClient: invalidHTTPClient, sessionRepository: repository)

        do {
            _ = try await invalidService.fetchUsage()
            XCTFail("Expected invalid session cookie error")
        } catch ChatGPTUsageError.invalidSessionCookie {
            let status = await repository.status
            XCTAssertEqual(status.state, .missing)
            XCTAssertEqual(status.lastErrorCategory, .notFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try await repository.save(ChatGPTSession(sessionCookie: "reacquired-session-token-redacted"), account: ChatGPTUsageService.defaultSessionAccount)
        let validHTTPClient = ChatGPTHTTPClientStub(
            responses: [
                "auth": #"{"accessToken":"access-token-redacted"}"#.data(using: .utf8)!,
                "usage": #"{"rate_limit":{"primary_window":{"used_percent":34,"reset_at":1770000000}}}"#.data(using: .utf8)!
            ]
        )
        let validService = ChatGPTUsageService(httpClient: validHTTPClient, sessionRepository: repository)

        let usage = try await validService.fetchUsage()

        XCTAssertEqual(usage.percentage, 34)
        let storedSession = try await repository.load(account: ChatGPTUsageService.defaultSessionAccount)
        XCTAssertEqual(storedSession.sessionCookie, "reacquired-session-token-redacted")
        XCTAssertEqual(storedSession.accessToken, "access-token-redacted")
        let status = await repository.status
        XCTAssertEqual(status.state, .available)
        XCTAssertNil(status.lastErrorCategory)
    }

    func test_fetchUsage_withoutAccessToken_treatsCookieAsInvalid() async {
        let httpClient = ChatGPTHTTPClientStub(
            responses: ["auth": #"{}"#.data(using: .utf8)!]
        )
        let service = ChatGPTUsageService(httpClient: httpClient)

        do {
            _ = try await service.fetchUsage(sessionCookie: "session-token-redacted")
            XCTFail("Expected invalid session cookie error")
        } catch ChatGPTUsageError.invalidSessionCookie {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor ChatGPTSessionRepositoryStub: ChatGPTSessionRepositoryProtocol {
    private var sessions: [String: ChatGPTSession] = [:]
    private(set) var clearCalled = false
    private(set) var status = ChatGPTSessionAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)

    func save(_ session: ChatGPTSession, account: String) async throws {
        sessions[account] = session
        status = ChatGPTSessionAcquisitionStatus(state: .available, lastErrorCategory: nil)
    }

    func load(account: String) async throws -> ChatGPTSession {
        guard let session = sessions[account] else {
            status = ChatGPTSessionAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
            throw ChatGPTSessionRepositoryError.notFound
        }
        return session
    }

    func validate(account: String) async -> ChatGPTSessionAcquisitionStatus {
        status
    }

    func clear(account: String) async throws {
        sessions[account] = nil
        clearCalled = true
        status = ChatGPTSessionAcquisitionStatus(state: .missing, lastErrorCategory: .notFound)
    }
}

private actor ChatGPTHTTPClientStub: ChatGPTHTTPClientProtocol {
    struct RecordedRequest: Equatable {
        let endpoint: String
        let cookieHeader: String
        let authorization: String?
        let referer: String
    }

    private let responses: [String: Data]
    private(set) var requests: [RecordedRequest] = []

    init(responses: [String: Data] = [:]) {
        self.responses = responses
    }

    func request<T: Decodable>(
        _ endpoint: String,
        cookieHeader: String,
        authorization: String?,
        referer: String
    ) async throws -> T {
        requests.append(RecordedRequest(
            endpoint: endpoint,
            cookieHeader: cookieHeader,
            authorization: authorization,
            referer: referer
        ))

        let key = endpoint.contains("auth/session") ? "auth" : "usage"
        guard let data = responses[key] else {
            throw ChatGPTUsageError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(T.self, from: data)
    }
}
