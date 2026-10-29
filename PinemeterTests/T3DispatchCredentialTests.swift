import XCTest
@testable import Pinemeter

final class T3DispatchCredentialTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func test_state_reportsConnectedBeyondThreeDays() {
        let credential = makeCredential(expiresAt: now.addingTimeInterval(3 * 24 * 60 * 60 + 1))

        XCTAssertEqual(credential.state(now: now), .connected)
    }

    func test_state_reportsExpiringSoonAtThreeDayBoundary() {
        let credential = makeCredential(expiresAt: now.addingTimeInterval(3 * 24 * 60 * 60))

        XCTAssertEqual(credential.state(now: now), .expiringSoon)
    }

    func test_state_reportsExpiringSoonInsideThreeDays() {
        let credential = makeCredential(expiresAt: now.addingTimeInterval(3 * 24 * 60 * 60 - 1))

        XCTAssertEqual(credential.state(now: now), .expiringSoon)
    }

    func test_state_reportsExpiredAtDeadline() {
        let credential = makeCredential(expiresAt: now)

        XCTAssertEqual(credential.state(now: now), .expired)
    }

    func test_state_reportsExpiredAfterDeadline() {
        let credential = makeCredential(expiresAt: now.addingTimeInterval(-1))

        XCTAssertEqual(credential.state(now: now), .expired)
    }

    func test_connectionStateUsesOnlyPublishedConnectionMetadata() {
        XCTAssertNil(T3DispatchConnection.notConnected.state(at: now))
        XCTAssertEqual(
            T3DispatchConnection.connected(
                expiresAt: now.addingTimeInterval(T3DispatchCredential.expiringSoonInterval + 1),
                scope: "orchestration:read orchestration:operate"
            ).state(at: now),
            .connected
        )
        XCTAssertEqual(
            T3DispatchConnection.connected(
                expiresAt: now.addingTimeInterval(T3DispatchCredential.expiringSoonInterval),
                scope: "orchestration:read orchestration:operate"
            ).state(at: now),
            .expiringSoon
        )
        XCTAssertEqual(
            T3DispatchConnection.expired(expiredAt: now.addingTimeInterval(-1)).state(at: now),
            .expired
        )
    }

    func test_envelopeRoundTripPreservesFieldsAndTruncatesDeadlineToWholeSeconds() throws {
        let credential = makeCredential(expiresAt: now.addingTimeInterval(10_000.75))

        let decoded = try T3DispatchCredential.decode(credential.encoded())

        XCTAssertEqual(decoded.accessToken, credential.accessToken)
        XCTAssertEqual(decoded.expiresAt, now.addingTimeInterval(10_000))
        XCTAssertEqual(decoded.scope, credential.scope)
    }

    private func makeCredential(expiresAt: Date) -> T3DispatchCredential {
        T3DispatchCredential(
            accessToken: "synthetic-access-token",
            expiresAt: expiresAt,
            scope: "orchestration:read orchestration:operate"
        )
    }
}
