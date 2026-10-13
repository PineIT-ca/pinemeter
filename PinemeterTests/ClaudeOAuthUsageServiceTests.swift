//
//  ClaudeOAuthUsageServiceTests.swift
//  PinemeterTests
//

import Foundation
import XCTest
@testable import Pinemeter

final class ClaudeOAuthUsageServiceTests: XCTestCase {
    override func tearDown() {
        ClaudeOAuthRequestURLProtocol.handler = nil
        super.tearDown()
    }

    private static let token = CLIAccessToken("synthetic-access-token")

    private static let fixtureUsageBody = """
    {
      "five_hour": {
        "utilization": 41.0,
        "resets_at": "2026-10-01T20:50:00.739120+00:00",
        "limit_dollars": 100,
        "remaining_dollars": 59,
        "used_dollars": 41,
        "locked_reason": null
      },
      "seven_day": {
        "utilization": 12.0,
        "resets_at": "2026-10-08T20:50:00.739120+00:00"
      },
      "limits": [
        {
          "group": "session",
          "is_active": true,
          "kind": "session",
          "percent": 41,
          "resets_at": "2026-10-01T20:50:00.739120+00:00",
          "scope": null,
          "severity": "ok"
        },
        {
          "group": "weekly",
          "is_active": true,
          "kind": "weekly_all",
          "percent": 12,
          "resets_at": "2026-10-08T20:50:00.739120+00:00",
          "scope": null,
          "severity": "ok"
        },
        {
          "group": "weekly",
          "is_active": true,
          "kind": "weekly_scoped",
          "percent": 7,
          "resets_at": "2026-10-08T20:50:00.739120+00:00",
          "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
          "severity": "ok"
        }
      ],
      "extra_usage": {},
      "spend": {},
      "seven_day_breakdown": {},
      "member_dashboard_available": false,
      "seven_day_opus": null,
      "iguana_necktie": {}
    }
    """

    private func makeService() -> ClaudeOAuthUsageService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeOAuthRequestURLProtocol.self]
        return ClaudeOAuthUsageService(configuration: configuration)
    }

    private func respond(statusCode: Int, body: Data) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }
    }

    // MARK: - Request shape

    func test_fetchUsage_sendsExpectedMethodURLAndHeadersAndNoCookie() async throws {
        var captured: URLRequest?
        ClaudeOAuthRequestURLProtocol.handler = { request in
            captured = request
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.fixtureUsageBody.data(using: .utf8)!)
        }

        _ = try await makeService().fetchUsage(accessToken: Self.token)

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, ClaudeOAuthUsageService.usageURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "claude-code/2.1.280")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func test_fetchUsage_issuesExactlyOneRequest() async throws {
        var requestCount = 0
        ClaudeOAuthRequestURLProtocol.handler = { request in
            requestCount += 1
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.fixtureUsageBody.data(using: .utf8)!)
        }

        _ = try await makeService().fetchUsage(accessToken: Self.token)

        XCTAssertEqual(requestCount, 1)
    }

    // MARK: - Fixture decode (CLI-04)

    func test_fetchUsage_fixtureBody_mapsToSessionWeeklyAndFableUsage() async throws {
        ClaudeOAuthRequestURLProtocol.handler = respond(statusCode: 200, body: Self.fixtureUsageBody.data(using: .utf8)!)

        let usage = try await makeService().fetchUsage(accessToken: Self.token)

        XCTAssertEqual(usage.sessionUsage.utilization, 41)
        XCTAssertEqual(usage.weeklyUsage.utilization, 12)
        XCTAssertEqual(usage.fableUsage?.utilization, 7)
        XCTAssertGreaterThan(usage.sessionUsage.resetAt.timeIntervalSince1970, 0)
        XCTAssertGreaterThan(usage.weeklyUsage.resetAt.timeIntervalSince1970, 0)
    }

    // MARK: - Status mapping

    func test_fetchUsage_status401_throwsRejected() async throws {
        ClaudeOAuthRequestURLProtocol.handler = respond(statusCode: 401, body: Data())
        await assertThrowsRejected { try await self.makeService().fetchUsage(accessToken: Self.token) }
    }

    func test_fetchUsage_status403_throwsRejected() async throws {
        ClaudeOAuthRequestURLProtocol.handler = respond(statusCode: 403, body: Data())
        await assertThrowsRejected { try await self.makeService().fetchUsage(accessToken: Self.token) }
    }

    func test_fetchUsage_status429_throwsRejected() async throws {
        ClaudeOAuthRequestURLProtocol.handler = respond(statusCode: 429, body: Data())
        await assertThrowsRejected { try await self.makeService().fetchUsage(accessToken: Self.token) }
    }

    func test_fetchUsage_status500_throwsHttpError() async throws {
        ClaudeOAuthRequestURLProtocol.handler = respond(statusCode: 500, body: Data())

        do {
            _ = try await makeService().fetchUsage(accessToken: Self.token)
            XCTFail("Expected httpError")
        } catch CLIUsageFetchError.httpError(let statusCode) {
            XCTAssertEqual(statusCode, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_fetchUsage_notJSONBody_throwsInvalidResponse() async throws {
        ClaudeOAuthRequestURLProtocol.handler = respond(statusCode: 200, body: "not json".data(using: .utf8)!)
        await assertThrowsInvalidResponse { try await self.makeService().fetchUsage(accessToken: Self.token) }
    }

    func test_fetchUsage_emptyObjectBody_throwsInvalidResponse() async throws {
        ClaudeOAuthRequestURLProtocol.handler = respond(statusCode: 200, body: "{}".data(using: .utf8)!)
        await assertThrowsInvalidResponse { try await self.makeService().fetchUsage(accessToken: Self.token) }
    }

    func test_fetchUsage_urlErrorNotConnected_throwsNetworkUnavailable() async throws {
        ClaudeOAuthRequestURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await makeService().fetchUsage(accessToken: Self.token)
            XCTFail("Expected networkUnavailable")
        } catch CLIUsageFetchError.networkUnavailable {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_fetchUsage_urlErrorCancelled_rethrowsCancellationError() async throws {
        ClaudeOAuthRequestURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await makeService().fetchUsage(accessToken: Self.token)
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Profile (CLI-03 contract, used by 19-03's resolver)

    func test_fetchProfileOrganization_decodesIdAndName() async throws {
        let body = """
        {"account":{"email":"user@example.com"},"organization":{"uuid":"00000000-0000-0000-0000-0000000000c1","name":"Example Org"}}
        """
        ClaudeOAuthRequestURLProtocol.handler = respond(statusCode: 200, body: body.data(using: .utf8)!)

        let organization = try await makeService().fetchProfileOrganization(accessToken: Self.token)

        XCTAssertEqual(organization.id, UUID(uuidString: "00000000-0000-0000-0000-0000000000c1"))
        XCTAssertEqual(organization.name, "Example Org")
    }

    func test_fetchProfileOrganization_missingOrganizationUuid_throwsInvalidResponse() async throws {
        let body = """
        {"account":{"email":"user@example.com"},"organization":{"name":"Example Org"}}
        """
        ClaudeOAuthRequestURLProtocol.handler = respond(statusCode: 200, body: body.data(using: .utf8)!)
        await assertThrowsInvalidResponse { try await self.makeService().fetchProfileOrganization(accessToken: Self.token) }
    }

    func test_fetchProfileOrganization_issuesExactlyOneRequest() async throws {
        var requestCount = 0
        let body = """
        {"organization":{"uuid":"00000000-0000-0000-0000-0000000000c1","name":"Example Org"}}
        """
        ClaudeOAuthRequestURLProtocol.handler = { request in
            requestCount += 1
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }

        _ = try await makeService().fetchProfileOrganization(accessToken: Self.token)

        XCTAssertEqual(requestCount, 1)
    }

    // MARK: - Helpers

    private func assertThrowsRejected(
        _ operation: @escaping () async throws -> UsageData,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected rejected", file: file, line: line)
        } catch CLIUsageFetchError.rejected {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertThrowsInvalidResponse(
        _ operation: @escaping () async throws -> UsageData,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected invalidResponse", file: file, line: line)
        } catch CLIUsageFetchError.invalidResponse {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertThrowsInvalidResponse(
        _ operation: @escaping () async throws -> ClaudeOAuthProfileOrganization,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected invalidResponse", file: file, line: line)
        } catch CLIUsageFetchError.invalidResponse {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private final class ClaudeOAuthRequestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
