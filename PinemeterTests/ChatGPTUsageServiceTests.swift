//
//  ChatGPTUsageServiceTests.swift
//  PinemeterTests
//

import Foundation
import XCTest
@testable import Pinemeter

final class ChatGPTUsageServiceTests: XCTestCase {
    func test_httpClientDefaultsPreventPersistentCaching() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pinemeter/Services/ChatGPTUsageService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("init(configuration: URLSessionConfiguration = .ephemeral)"))

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = .shared
        _ = ChatGPTHTTPClient(configuration: configuration)

        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

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
            "Codex 5h",
            "Codex weekly",
            "Code Review",
            "ChatGPT Pro",
            "Unknown Bucket"
        ])
        XCTAssertEqual(usage.displayRows.compactMap(\.menuBarRole), [.chatGPT5h, .chatGPTWeekly, .chatGPTPro])
        XCTAssertEqual(
            usage.displayRows.filter { $0.menuBarRole != nil }.map(\.label),
            ["Codex 5h", "Codex weekly", "ChatGPT Pro"]
        )

        let unknownRow = try XCTUnwrap(usage.rows.last)
        XCTAssertNil(unknownRow.menuBarRole)
        XCTAssertEqual(unknownRow.subtitle, "WHAM: unknown_bucket")
    }

    /// Two windows resolving to the same role must not render twin bars, while
    /// unclassified rows are all kept.
    func test_displayRows_collapseDuplicateRolesAndKeepUnclassifiedRows() {
        let usage = ChatGPTUsageData(
            rows: [
                .init(label: "Codex weekly", usedPercent: 10, resetAt: nil, sourceLabel: "a", menuBarRole: .chatGPTWeekly),
                .init(label: "Codex weekly dup", usedPercent: 20, resetAt: nil, sourceLabel: "b", menuBarRole: .chatGPTWeekly),
                .init(label: "Mystery One", usedPercent: 30, resetAt: nil, sourceLabel: "c"),
                .init(label: "Mystery Two", usedPercent: 40, resetAt: nil, sourceLabel: "d"),
            ],
            lastUpdated: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(
            usage.displayRows.map(\.sourceLabel),
            ["a", "c", "d"],
            "First row per role wins; unclassified rows are never collapsed"
        )
    }

    /// July 2026 WHAM shape: primary window is weekly (secondary null) and
    /// additional limits nest their window under rate_limit with limit_name /
    /// metered_feature labels. The Codex meter must survive both changes.
    func test_whamToDomain_mapsMid2026NestedAdditionalLimitsShape() throws {
        let json = #"""
        {
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 1,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 602386,
              "reset_at": 1786112220
            },
            "secondary_window": null
          },
          "code_review_rate_limit": null,
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "codex_bengalfox",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 40,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 604800,
                  "reset_at": 1786114634
                },
                "secondary_window": null
              }
            }
          ]
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let response = try decoder.decode(ChatGPTWHAMUsageResponse.self, from: json)

        let usage = try response.toDomain(lastUpdated: Date(timeIntervalSince1970: 0))

        // Primary window self-identifies as weekly via its duration.
        XCTAssertEqual(usage.rows.map(\.menuBarRole), [.chatGPTWeekly, .chatGPTCodexSpark])
        XCTAssertEqual(usage.rows.map(\.label), ["Codex weekly", "Codex Spark"])
        XCTAssertEqual(usage.rows.map(\.usedPercent), [1, 40])
        XCTAssertEqual(usage.rows.last?.sourceLabel, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(
            usage.rows.last?.resetAt,
            Date(timeIntervalSince1970: 1_786_114_634)
        )
    }

    /// August 2026 WHAM shape: the 5h window returned, but as the *primary*
    /// window of a per-model additional limit whose secondary window is the
    /// weekly one. Both windows must surface, and each must carry its own
    /// server-reported duration.
    func test_whamToDomain_mapsAugust2026FiveHourAndWeeklyWindowsOnOneFeature() throws {
        let json = #"""
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 34,
              "limit_window_seconds": 604800,
              "reset_at": 1788272043
            },
            "secondary_window": null
          },
          "code_review_rate_limit": null,
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "codex_bengalfox",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 12,
                  "limit_window_seconds": 18000,
                  "reset_at": 1787798887
                },
                "secondary_window": {
                  "used_percent": 5,
                  "limit_window_seconds": 604800,
                  "reset_at": 1788385687
                }
              }
            },
            {
              "limit_name": "gpt-reserve",
              "metered_feature": "base_model_inference",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 7,
                  "limit_window_seconds": 604800,
                  "reset_at": 1788385687
                },
                "secondary_window": null
              }
            }
          ]
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let response = try decoder.decode(ChatGPTWHAMUsageResponse.self, from: json)

        let usage = try response.toDomain(lastUpdated: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(usage.rows.map(\.sourceLabel), [
            "rate_limit",
            "GPT-5.3-Codex-Spark",
            "GPT-5.3-Codex-Spark.secondary_window",
            "gpt-reserve",
        ])
        XCTAssertEqual(usage.rows.map(\.label), [
            "Codex weekly",
            "Codex Spark 5h",
            "Codex Spark weekly",
            "Gpt Reserve",
        ])
        XCTAssertEqual(usage.rows.map(\.usedPercent), [34, 12, 5, 7])
        XCTAssertEqual(usage.rows.map(\.windowSeconds), [604_800, 18_000, 604_800, 604_800])
        // Only one row per feature keeps the role, so `displayRows` cannot
        // collapse the pair; the weekly companion stays visible unclassified.
        XCTAssertEqual(usage.rows.map(\.menuBarRole), [.chatGPTWeekly, .chatGPTCodexSpark, nil, nil])
        XCTAssertEqual(usage.displayRows.map(\.sourceLabel), usage.rows.map(\.sourceLabel))
        XCTAssertEqual(usage.rows.map(\.menuBarHeading), [nil, "Spark 5h", "Spark weekly", "Gpt Reserve"])
    }

    /// The identity fields are what let two connected ChatGPT accounts be told
    /// apart, so they must survive decoding of the live response shape.
    func test_whamResponse_decodesAccountIdentity() throws {
        let json = #"""
        {
          "user_id": "user-ne1edCihJnnO78tre4FJfSyi",
          "account_id": "02725b43-16a0-40c0-bd72-b30acf14232a",
          "email": "someone@example.com",
          "plan_type": "pro",
          "rate_limit": { "primary_window": { "used_percent": 1, "limit_window_seconds": 604800 } }
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let identity = try decoder.decode(ChatGPTWHAMUsageResponse.self, from: json).identity

        XCTAssertEqual(identity.stableId, "user-ne1edCihJnnO78tre4FJfSyi")
        XCTAssertEqual(identity.displayLabel, "someone@example.com")
        XCTAssertEqual(identity.planType, "pro")
    }

    /// A response that names only the workspace account still identifies one
    /// account, so the workspace id is the fallback key.
    func test_whamResponse_fallsBackToWorkspaceAccountIdWhenUserIdIsAbsent() throws {
        let json = #"""
        {
          "account_id": "02725b43-16a0-40c0-bd72-b30acf14232a",
          "rate_limit": { "primary_window": { "used_percent": 1, "limit_window_seconds": 604800 } }
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let identity = try decoder.decode(ChatGPTWHAMUsageResponse.self, from: json).identity

        XCTAssertEqual(identity.stableId, "02725b43-16a0-40c0-bd72-b30acf14232a")
        XCTAssertEqual(identity.displayLabel, "ChatGPT")
    }

    /// An empty `account_id` is what a personal (non-workspace) plan reports,
    /// and must not be mistaken for an account key.
    func test_whamResponse_treatsBlankIdentityFieldsAsAbsent() throws {
        let json = #"""
        {
          "user_id": "",
          "account_id": "",
          "rate_limit": { "primary_window": { "used_percent": 1, "limit_window_seconds": 604800 } }
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let identity = try decoder.decode(ChatGPTWHAMUsageResponse.self, from: json).identity

        XCTAssertNil(identity.stableId)
    }

    /// Free plans meter Codex over a rolling 30 days; that window used to be
    /// labelled "Codex weekly" because anything past a day read as weekly.
    func test_whamToDomain_labelsThirtyDayWindowAsMonthly() throws {
        let json = #"""
        {
          "plan_type": "free",
          "rate_limit": {
            "primary_window": {
              "used_percent": 3,
              "limit_window_seconds": 2592000,
              "reset_at": 1790372814
            },
            "secondary_window": null
          }
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let response = try decoder.decode(ChatGPTWHAMUsageResponse.self, from: json)

        let usage = try response.toDomain(lastUpdated: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(usage.rows.map(\.label), ["Codex monthly"])
        XCTAssertEqual(usage.rows.map(\.menuBarRole), [.chatGPTMonthly])
        XCTAssertEqual(usage.rows.first?.windowSeconds, 2_592_000)
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

        XCTAssertEqual(usage.rows.map(\.label), ["Codex 5h", "Code Review"])
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

    func test_fetchUsage_loadsPersistedSessionWithoutRewritingIt() async throws {
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
        XCTAssertNil(storedSession.accessToken)
        let status = await repository.status
        XCTAssertEqual(status.state, .available)
    }

    func test_fetchUsage_neverRewritesThePersistedSession() async throws {
        let repository = ChatGPTSessionRepositorySaveFailureStub()
        let httpClient = ChatGPTHTTPClientStub(
            responses: [
                "auth": #"{"accessToken":"access-token-redacted"}"#.data(using: .utf8)!,
                "usage": #"{"rate_limit":{"primary_window":{"used_percent":25,"reset_at":1770000000}}}"#.data(using: .utf8)!
            ]
        )
        let service = ChatGPTUsageService(httpClient: httpClient, sessionRepository: repository)

        let usage = try await service.fetchUsage()
        let saveCount = await repository.saveCount

        XCTAssertEqual(usage.percentage, 25)
        XCTAssertEqual(saveCount, 0)
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

    /// Target invariant B: a poll never deletes the keychain session, even
    /// when every attempt (including the target invariant C retry) fails.
    func test_fetchUsage_withPersistentlyInvalidSessionRetriesOnceAndNeverClearsRepository() async throws {
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
            XCTAssertFalse(clearCalled, "A poll must never delete the keychain session")
            XCTAssertEqual(status.state, .available, "The persisted session is untouched by a failed poll")
            let requests = await httpClient.requests
            XCTAssertEqual(requests.count, 2, "fetchUsage() must retry the auth exchange exactly once")
            XCTAssertTrue(requests.allSatisfy { $0.endpoint.hasSuffix("/api/auth/session") })
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // The still-persisted session can be retried again later without
        // reconnecting (no clear ever happened above).
        let storedSession = try await repository.load(account: ChatGPTUsageService.defaultSessionAccount)
        XCTAssertEqual(storedSession.sessionCookie, "session-token-redacted")
    }

    /// Target invariant C: a single invalidSessionCookie response is
    /// retried once within the same `fetchUsage()` call, so a transient 401
    /// (session refresh timing, momentary upstream hiccup) recovers without
    /// surfacing an error to the caller at all.
    func test_fetchUsage_retriesOnceOnInvalidSessionCookieAndSucceedsWhenRetrySucceeds() async throws {
        let repository = ChatGPTSessionRepositoryStub()
        try await repository.save(ChatGPTSession(sessionCookie: "session-token-redacted"), account: ChatGPTUsageService.defaultSessionAccount)
        let httpClient = ChatGPTHTTPClientStub(
            // First auth exchange has no accessToken (invalid); the retried
            // one succeeds.
            authResponses: [
                #"{}"#.data(using: .utf8)!,
                #"{"accessToken":"access-token-redacted"}"#.data(using: .utf8)!
            ],
            usageResponses: [
                #"{"rate_limit":{"primary_window":{"used_percent":34,"reset_at":1770000000}}}"#.data(using: .utf8)!
            ]
        )
        let service = ChatGPTUsageService(httpClient: httpClient, sessionRepository: repository)

        let usage = try await service.fetchUsage()

        XCTAssertEqual(usage.percentage, 34)
        let requests = await httpClient.requests
        XCTAssertEqual(requests.map(\.endpoint).filter { $0.hasSuffix("/api/auth/session") }.count, 2)
        XCTAssertEqual(requests.map(\.endpoint).filter { $0.hasSuffix("/backend-api/wham/usage") }.count, 1)
        let clearCalled = await repository.clearCalled
        XCTAssertFalse(clearCalled)
        let storedSession = try await repository.load(account: ChatGPTUsageService.defaultSessionAccount)
        XCTAssertNil(storedSession.accessToken)
    }

    func test_fetchUsage_retriesOnceAfterTransientNetworkFailure() async throws {
        let repository = ChatGPTSessionRepositoryStub()
        try await repository.save(ChatGPTSession(sessionCookie: "session-token-redacted"), account: ChatGPTUsageService.defaultSessionAccount)
        let httpClient = ChatGPTHTTPClientStub(
            firstAuthError: .networkUnavailable,
            authResponses: [#"{"accessToken":"access-token-redacted"}"#.data(using: .utf8)!],
            usageResponses: [#"{"rate_limit":{"primary_window":{"used_percent":34,"reset_at":1770000000}}}"#.data(using: .utf8)!]
        )
        let service = ChatGPTUsageService(
            httpClient: httpClient,
            sessionRepository: repository,
            networkRetryDelay: .zero
        )

        let usage = try await service.fetchUsage()

        XCTAssertEqual(usage.percentage, 34)
        let requests = await httpClient.requests
        XCTAssertEqual(requests.map(\.endpoint).filter { $0.hasSuffix("/api/auth/session") }.count, 2)
    }

    /// F10: a Keychain read failure is not the same thing as "no session" or
    /// "provider rejected the session" -- it must surface its own honest
    /// error rather than being folded into `networkUnavailable`'s "check
    /// your connection" copy, which is actively misleading for a local
    /// Keychain problem.
    func test_fetchUsage_withSecureStorageUnavailable_throwsDedicatedError() async {
        let repository = ChatGPTSessionRepositoryStorageFailureStub()
        let service = ChatGPTUsageService(httpClient: ChatGPTHTTPClientStub(), sessionRepository: repository)

        do {
            _ = try await service.fetchUsage()
            XCTFail("Expected secureStorageUnavailable error")
        } catch ChatGPTUsageError.secureStorageUnavailable {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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

/// A `load(account:)` that always fails as if the Keychain itself could not
/// be reached (locked, permission denied, etc.) -- distinct from `.notFound`
/// (no session saved), which `ChatGPTSessionRepositoryStub` already covers.
private actor ChatGPTSessionRepositoryStorageFailureStub: ChatGPTSessionRepositoryProtocol {
    func save(_ session: ChatGPTSession, account: String) async throws {}

    func load(account: String) async throws -> ChatGPTSession {
        throw ChatGPTSessionRepositoryError.secureStorageUnavailable(.keychainReadFailed)
    }

    func validate(account: String) async -> ChatGPTSessionAcquisitionStatus {
        ChatGPTSessionAcquisitionStatus(state: .storageUnavailable, lastErrorCategory: .keychainReadFailed)
    }

    func clear(account: String) async throws {}
}

private actor ChatGPTSessionRepositorySaveFailureStub: ChatGPTSessionRepositoryProtocol {
    private(set) var saveCount = 0

    func save(_ session: ChatGPTSession, account: String) async throws {
        saveCount += 1
        throw ChatGPTSessionRepositoryError.secureStorageUnavailable(.keychainWriteFailed)
    }

    func load(account: String) async throws -> ChatGPTSession {
        ChatGPTSession(sessionCookie: "session-token-redacted")
    }

    func validate(account: String) async -> ChatGPTSessionAcquisitionStatus {
        ChatGPTSessionAcquisitionStatus(state: .available, lastErrorCategory: nil)
    }

    func clear(account: String) async throws {}
}

private actor ChatGPTHTTPClientStub: ChatGPTHTTPClientProtocol {
    struct RecordedRequest: Equatable {
        let endpoint: String
        let cookieHeader: String
        let authorization: String?
        let referer: String
    }

    // Queued per endpoint: each call pops the front entry (last one sticks
    // once exhausted), so a single stub can drive a fetchUsage() retry
    // (target invariant C) through e.g. an invalid first auth response
    // followed by a valid second one.
    private var authResponses: [Data]
    private var usageResponses: [Data]
    private var firstAuthError: ChatGPTUsageError?
    private(set) var requests: [RecordedRequest] = []

    init(responses: [String: Data] = [:]) {
        self.authResponses = responses["auth"].map { [$0] } ?? []
        self.usageResponses = responses["usage"].map { [$0] } ?? []
        self.firstAuthError = nil
    }

    init(
        firstAuthError: ChatGPTUsageError? = nil,
        authResponses: [Data],
        usageResponses: [Data] = []
    ) {
        self.authResponses = authResponses
        self.usageResponses = usageResponses
        self.firstAuthError = firstAuthError
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

        let isAuthEndpoint = endpoint.contains("auth/session")
        let data: Data
        if isAuthEndpoint {
            if let error = firstAuthError {
                firstAuthError = nil
                throw error
            }
            guard !authResponses.isEmpty else { throw ChatGPTUsageError.invalidResponse }
            data = authResponses.count > 1 ? authResponses.removeFirst() : authResponses[0]
        } else {
            guard !usageResponses.isEmpty else { throw ChatGPTUsageError.invalidResponse }
            data = usageResponses.count > 1 ? usageResponses.removeFirst() : usageResponses[0]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(T.self, from: data)
    }
}
