import Foundation
import XCTest
@testable import Pinemeter

final class HostLoginAlertEvaluatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_404_800)
    private let loginKey = "claude|user-fixture"

    func testExpiredAndChallengedAlertImmediately() {
        let rows = [row(.expired), row(.challenged, provider: .chatgpt)]
        let result = evaluate(rows, labels: [loginKey: "Fixture Claude", "chatgpt|user-fixture": "Fixture Codex"])
        XCTAssertEqual(result.alerts.map(\.key), ["chatgpt|user-fixture|challenged", "\(loginKey)|expired"])
        XCTAssertEqual(result.alerts.map(\.cause), [.challenged, .expired])
        XCTAssertEqual(result.alerts.map(\.accountLabel), ["Fixture Codex", "Fixture Claude"])
        XCTAssertTrue(result.next.deliveredKeys.isEmpty, "Only delivery may insert keys")
        var delivered = result.next
        delivered.deliveredKeys.formUnion(result.alerts.map(\.key))
        XCTAssertTrue(evaluate(rows, previous: delivered).alerts.isEmpty)
    }

    func testRefreshFailedNeeds24ContinuousHours() {
        let first = evaluate([row(.refreshFailed)])
        XCTAssertTrue(first.alerts.isEmpty)
        XCTAssertEqual(first.next.refreshFailedSince[loginKey], now)
        let before = evaluate([row(.refreshFailed)], previous: first.next, at: now.addingTimeInterval(86_399))
        XCTAssertTrue(before.alerts.isEmpty)
        XCTAssertEqual(before.next.refreshFailedSince[loginKey], now)
        let threshold = evaluate([row(.refreshFailed)], previous: before.next, at: now.addingTimeInterval(86_400))
        XCTAssertEqual(threshold.alerts.map(\.key), ["\(loginKey)|refresh_failed"])
        XCTAssertEqual(threshold.alerts.map(\.cause), [.refreshFailed])
        var delivered = threshold.next
        delivered.deliveredKeys.insert("\(loginKey)|refresh_failed")
        XCTAssertTrue(evaluate([row(.refreshFailed)], previous: delivered, at: now.addingTimeInterval(90_000)).alerts.isEmpty)

        for state in [HostLoginState.fresh, .expired, .challenged] {
            let reset = evaluate([row(state)], previous: before.next, at: now.addingTimeInterval(100))
            XCTAssertNil(reset.next.refreshFailedSince[loginKey])
            let restarted = evaluate([row(.refreshFailed)], previous: reset.next, at: now.addingTimeInterval(200))
            XCTAssertEqual(restarted.next.refreshFailedSince[loginKey], now.addingTimeInterval(200))
            XCTAssertTrue(restarted.alerts.isEmpty)
        }
    }

    func testClaudeExpiryWarningWindow() {
        let boundary = now.addingTimeInterval(259_200)
        XCTAssertEqual(evaluate([row(.fresh, expiresAt: boundary)]).alerts.map(\.cause), [.expiryWarning(expiresAt: boundary)])
        XCTAssertTrue(evaluate([row(.fresh, expiresAt: now.addingTimeInterval(259_201))]).alerts.isEmpty)
        let past = now.addingTimeInterval(-60)
        XCTAssertEqual(evaluate([row(.fresh, expiresAt: past)]).alerts.map(\.cause), [.expiryWarning(expiresAt: past)])
        XCTAssertTrue(evaluate([row(.fresh, provider: .chatgpt, expiresAt: boundary)]).alerts.isEmpty)
        XCTAssertTrue(evaluate([row(.refreshFailed, expiresAt: boundary)]).alerts.isEmpty)
        XCTAssertEqual(evaluate([row(.expired, expiresAt: boundary)]).alerts.map(\.cause), [.expired])
        XCTAssertEqual(evaluate([row(.challenged, expiresAt: boundary)]).alerts.map(\.cause), [.challenged])
    }

    func testExpiryKeyUsesUTCDay() throws {
        let formatter = ISO8601DateFormatter()
        for (timestamp, day) in [("2026-10-30T23:30:00Z", "2026-10-30"), ("2026-10-31T00:30:00Z", "2026-10-31")] {
            let expiry = try XCTUnwrap(formatter.date(from: timestamp))
            let result = evaluate([row(.fresh, expiresAt: expiry)], at: expiry.addingTimeInterval(-3_600))
            XCTAssertEqual(result.alerts.map(\.key), ["\(loginKey)|expiry|\(day)"])
        }
    }

    func testNewExpiryDateWarnsAgain() throws {
        let expiry = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-02T00:30:00Z"))
        var previous = RemoteHostLoginAlertState()
        previous.deliveredKeys = ["\(loginKey)|expiry|2026-10-30"]
        let result = evaluate([row(.fresh, expiresAt: expiry)], previous: previous, at: expiry.addingTimeInterval(-86_400))
        XCTAssertTrue(result.next.deliveredKeys.isEmpty)
        XCTAssertEqual(result.alerts.map(\.key), ["\(loginKey)|expiry|2026-11-02"])
        var delivered = result.next
        delivered.deliveredKeys.insert(try XCTUnwrap(result.alerts.first).key)
        XCTAssertTrue(evaluate([row(.fresh, expiresAt: expiry)], previous: delivered, at: expiry.addingTimeInterval(-3_600)).alerts.isEmpty)
    }

    func testRecoveryClearsAndNewCauseRealerts() throws {
        var previous = RemoteHostLoginAlertState()
        previous.deliveredKeys = ["\(loginKey)|expired", "\(loginKey)|challenged", "\(loginKey)|refresh_failed", "\(loginKey)|expiry|2026-10-30"]
        previous.refreshFailedSince[loginKey] = now
        let recovered = evaluate([row(.fresh)], previous: previous)
        XCTAssertTrue(recovered.next.deliveredKeys.isEmpty)
        XCTAssertTrue(recovered.next.refreshFailedSince.isEmpty)
        XCTAssertEqual(evaluate([row(.expired)], previous: recovered.next).alerts.map(\.cause), [.expired])

        let expiry = now.addingTimeInterval(3_600)
        let pending = evaluate([row(.fresh, expiresAt: expiry)], previous: previous)
        XCTAssertTrue(pending.next.deliveredKeys.isEmpty)
        XCTAssertEqual(pending.alerts.map(\.cause), [.expiryWarning(expiresAt: expiry)])
        let expiryKey = try XCTUnwrap(pending.alerts.first).key
        var delivered = previous
        delivered.deliveredKeys.insert(expiryKey)
        let kept = evaluate([row(.fresh, expiresAt: expiry)], previous: delivered)
        XCTAssertEqual(kept.next.deliveredKeys, [expiryKey])
        XCTAssertTrue(kept.alerts.isEmpty)
        for fresh in [row(.fresh), row(.fresh, expiresAt: now.addingTimeInterval(259_201)), row(.fresh, provider: .chatgpt, expiresAt: expiry)] {
            let key = "\(fresh.provider.rawValue)|user-fixture|expiry|2026-10-30"
            var stale = RemoteHostLoginAlertState()
            stale.deliveredKeys = [key]
            XCTAssertTrue(evaluate([fresh], previous: stale).next.deliveredKeys.isEmpty)
        }
    }

    func testMissingRowOrNullLoginPrunesState() {
        let otherKey = "chatgpt|user-fixture"
        var previous = RemoteHostLoginAlertState()
        previous.deliveredKeys = ["\(loginKey)|expired", "\(loginKey)|challenged", "\(loginKey)|refresh_failed", "\(loginKey)|expiry|2026-10-30", "\(otherKey)|challenged"]
        previous.refreshFailedSince = [loginKey: now, otherKey: now]
        for rows in [[row(.refreshFailed, provider: .chatgpt)], [row(nil), row(.refreshFailed, provider: .chatgpt)]] {
            let result = evaluate(rows, previous: previous)
            XCTAssertEqual(result.next.deliveredKeys, ["\(otherKey)|challenged"])
            XCTAssertEqual(result.next.refreshFailedSince, [otherKey: now])
            XCTAssertEqual(evaluate(rows + [row(.expired)], previous: result.next).alerts.map(\.cause), [.expired])
        }
        let empty = evaluate([], previous: previous)
        XCTAssertTrue(empty.next.deliveredKeys.isEmpty)
        XCTAssertTrue(empty.next.refreshFailedSince.isEmpty)
    }

    func testAlertOrderAndLabelFallback() {
        let result = evaluate([row(.expired, id: "z-fixture"), row(.challenged, provider: .chatgpt), row(.expired, id: "a-fixture")])
        XCTAssertEqual(result.alerts.map(\.key), ["chatgpt|user-fixture|challenged", "claude|a-fixture|expired", "claude|z-fixture|expired"])
        XCTAssertEqual(result.alerts.map(\.accountLabel), ["user-fixture", "a-fixture", "z-fixture"])
    }

    private func row(_ state: HostLoginState?, provider: HostLoginProvider = .claude, id: String = "user-fixture", expiresAt: Date? = nil) -> HostSourcesAccountDTO {
        HostSourcesAccountDTO(
            provider: provider, id: id, verdict: .unpolled, observedAt: nil, source: .hostLogin, hostLogin: true,
            login: state.map { HostLoginHealthDTO(state: $0, reason: "", refreshExpiresAt: expiresAt, lastRefreshAt: nil) }
        )
    }

    private func evaluate(_ rows: [HostSourcesAccountDTO], previous: RemoteHostLoginAlertState = RemoteHostLoginAlertState(), labels: [String: String] = [:], at date: Date? = nil) -> (alerts: [HostLoginAlert], next: RemoteHostLoginAlertState) {
        HostLoginAlertEvaluator.evaluate(previous: previous, rows: rows, labels: labels, now: date ?? now)
    }
}
