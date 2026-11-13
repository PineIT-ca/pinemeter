import Foundation
import XCTest
@testable import Pinemeter

final class HealthDocumentServiceTests: XCTestCase {
    func test_compiledURLHeadersTimeoutAndETag() async throws {
        let body = try HealthTestSupport.body("valid-empty")
        let session = HealthTestSupport.session(body: body, headers: ["ETag": "new"])
        defer { session.invalidateAndCancel() }
        let outcome = try await HealthDocumentService(session: session).fetch(etag: "previous")
        XCTAssertEqual(outcome, .updated(body: body, etag: "new"))
        let request = try XCTUnwrap(HealthStubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, BrokerHealthDocument.officialURL)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Pinemeter")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "previous")
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 1)
    }

    func test_304ReturnsUnchangedWithoutReadingBody() async throws {
        let session = HealthTestSupport.session(status: 304, body: Data(repeating: 0, count: 32769))
        defer { session.invalidateAndCancel() }
        let outcome = try await HealthDocumentService(session: session).fetch(etag: "same")
        XCTAssertEqual(outcome, .notModified)
    }

    func test_allOtherStatusesAreFetchFailed() async throws {
        for status in [201, 204, 301, 302, 400, 404, 500] {
            let session = HealthTestSupport.session(status: status)
            defer { session.invalidateAndCancel() }
            await assertFailure(.fetchFailed, session: session)
        }
    }

    func test_networkErrorIsCategoryOnly() async throws {
        let session = HealthTestSupport.session()
        defer { session.invalidateAndCancel() }
        HealthStubURLProtocol.configure { _ in throw URLError(.timedOut) }
        await assertFailure(.fetchFailed, session: session)
    }

    func test_streamedBodyAboveCapIsTooLarge() async throws {
        let session = HealthTestSupport.session(body: Data(repeating: 32, count: BrokerHealthDocument.maxBytes + 1))
        defer { session.invalidateAndCancel() }
        await assertFailure(.tooLarge, session: session)
    }

    func test_exactBodyCapIsAcceptedByTransport() async throws {
        let body = Data(repeating: 32, count: BrokerHealthDocument.maxBytes)
        let session = HealthTestSupport.session(body: body)
        defer { session.invalidateAndCancel() }
        let outcome = try await HealthDocumentService(session: session).fetch(etag: "")
        XCTAssertEqual(outcome, .updated(body: body, etag: nil))
        XCTAssertNil(HealthStubURLProtocol.requests.first?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func test_declaredTooLargeRefusedWithNoBody() async throws {
        let session = HealthTestSupport.session(headers: ["Content-Length": "32769"])
        defer { session.invalidateAndCancel() }
        await assertFailure(.tooLarge, session: session)
    }

    func test_crossHostRedirectRefusedBeforeDestinationRequest() async throws {
        let session = HealthTestSupport.session()
        defer { session.invalidateAndCancel() }
        HealthStubURLProtocol.configure { _ in
            .init(status: 301, redirect: URL(string: "https://example.invalid/health.signed"))
        }
        await assertFailure(.fetchFailed, session: session)
        XCTAssertEqual(HealthStubURLProtocol.requests.map { $0.url?.host }, ["pinemeter-dist.pineit.ca"])
    }

    func test_plaintextRedirectOnOfficialHostRefused() async throws {
        let session = HealthTestSupport.session()
        defer { session.invalidateAndCancel() }
        HealthStubURLProtocol.configure { _ in
            .init(status: 301, redirect: URL(string: "http://pinemeter-dist.pineit.ca/health.signed"))
        }
        await assertFailure(.fetchFailed, session: session)
        XCTAssertEqual(HealthStubURLProtocol.requests.count, 1)
    }

    func test_redirectStubNegativeControlFollowsWithoutTaskDelegate() async throws {
        let session = HealthTestSupport.session()
        defer { session.invalidateAndCancel() }
        HealthStubURLProtocol.configure { request in
            if request.url?.host == "pinemeter-dist.pineit.ca" {
                return .init(status: 301, redirect: URL(string: "https://example.invalid/health.signed"))
            }
            return .init(body: Data("stub".utf8))
        }
        let request = URLRequest(url: URL(string: BrokerHealthDocument.officialURL)!, timeoutInterval: 1)
        let (bytes, response) = try await session.bytes(for: request)
        for try await _ in bytes {}
        XCTAssertEqual(response.url?.host, "example.invalid")
        XCTAssertEqual(HealthStubURLProtocol.requests.map { $0.url?.host }, ["pinemeter-dist.pineit.ca", "example.invalid"])
    }

    private func assertFailure(_ expected: HealthDocumentService.FetchError, session: URLSession,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await HealthDocumentService(session: session).fetch(etag: nil)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? HealthDocumentService.FetchError, expected, file: file, line: line)
        }
    }
}
