import XCTest
@testable import Pinemeter

final class RemoteHostLoginRowModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let claudeID = "00000000-0000-4000-8000-000000000022"

    func testRowsCoverEveryStateAndSource() {
        let accounts = [
            account(.chatgpt, "user-zulu", .fresh, source: .pushedCookie),
            account(.claude, claudeID, .fresh),
            account(.chatgpt, "user-bravo", .refreshFailed),
            account(.claude, "00000000-0000-4000-8000-000000000023", .expired),
            account(.chatgpt, "user-charlie", .challenged),
            account(.claude, "claude.default", nil, source: .none),
        ]
        let rows = RemoteHostLoginRowModel.rows(display: display(accounts), labels: [
            "claude|\(claudeID)": "Alpha",
            "claude|00000000-0000-4000-8000-000000000023": "Bravo",
            "chatgpt|user-zulu": "Zulu",
        ], now: now)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.map(\.providerTitle), ["Claude", "Claude", "Claude", "Codex", "Codex", "Codex"])
        XCTAssertEqual(rows.map(\.provider), [.claude, .claude, .claude, .chatgpt, .chatgpt, .chatgpt])
        XCTAssertEqual(rows.map(\.accountLabel), ["Alpha", "Bravo", "claude.default", "Zulu", "user-bravo", "user-charlie"])
        XCTAssertEqual(rows.map(\.accountID), [claudeID, "00000000-0000-4000-8000-000000000023", "claude.default", "user-zulu", "user-bravo", "user-charlie"])
        XCTAssertEqual(rows.map(\.id), ["claude|\(claudeID)", "claude|00000000-0000-4000-8000-000000000023", "claude|claude.default", "chatgpt|user-zulu", "chatgpt|user-bravo", "chatgpt|user-charlie"])
        XCTAssertEqual(rows.map(\.badgeText), ["Fresh", "Expired", "No host login", "Fresh", "Refresh failing", "Challenged"])
        XCTAssertEqual(rows.map(\.badgeTone), [.good, .critical, .neutral, .good, .warning, .warning])
        XCTAssertEqual(rows.map(\.sourceText), ["Host login", "Host login", "No credential", "Pushed cookies", "Host login", "Host login"])
        XCTAssertTrue(rows.allSatisfy { $0.expiryText == nil })
    }

    func testClaudeExpiryTextAndExpiresSoonBadge() throws {
        let cases: [(TimeInterval, String, RemoteHostLoginRowModel.Tone)] = [
            (48 * 3_600.0, "Expires soon", RemoteHostLoginRowModel.Tone.warning),
            (72 * 3_600.0, "Expires soon", .warning),
            (72 * 3_600.0 + 1, "Fresh", .good),
            (10 * 86_400.0, "Fresh", .good),
            (-1.0, "Expires soon", .warning),
        ]
        for (offset, badge, tone) in cases {
            let expiry = now.addingTimeInterval(offset)
            let row = try XCTUnwrap(RemoteHostLoginRowModel.rows(
                display: display([account(.claude, claudeID, .fresh, expiresAt: expiry)]), labels: [:], now: now
            ).first)
            XCTAssertEqual(row.badgeText, badge, "offset \(offset)")
            XCTAssertEqual(row.badgeTone, tone)
            XCTAssertEqual(row.expiryText, "Refresh expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
        }
        let codex = try XCTUnwrap(RemoteHostLoginRowModel.rows(
            display: display([account(.chatgpt, "user-fixture", .fresh, expiresAt: now)]), labels: [:], now: now
        ).first)
        XCTAssertEqual(codex.badgeText, "Fresh")
        XCTAssertEqual(codex.badgeTone, .good)
        XCTAssertNil(codex.expiryText)
        let expired = try XCTUnwrap(RemoteHostLoginRowModel.rows(
            display: display([account(.claude, claudeID, .expired, expiresAt: now)]), labels: [:], now: now
        ).first)
        XCTAssertEqual(expired.badgeText, "Expired")
        XCTAssertEqual(expired.badgeTone, .critical)
        XCTAssertNotNil(expired.expiryText)
    }

    func testLogInEligibility() throws {
        let cases: [(HostLoginProvider, String, Bool)] = [
            (.claude, claudeID, true), (.chatgpt, "user-fixture", true),
            (.chatgpt, claudeID, true), (.claude, "user-fixture", false),
            (.chatgpt, "legacy-chatgpt", false), (.claude, "claude.default", false),
            (.chatgpt, "chatgpt.legacy", false), (.chatgpt, "user-'fixture", false),
        ]
        for (provider, id, eligible) in cases {
            let row = try XCTUnwrap(RemoteHostLoginRowModel.rows(
                display: display([account(provider, id, nil, source: .none)]), labels: [:], now: now
            ).first)
            XCTAssertEqual(row.canLogIn, eligible, "\(provider.rawValue)|\(id)")
        }
    }

    func testUnknownWhenNoDisplayOrNotCurrent() {
        XCTAssertTrue(RemoteHostLoginRowModel.rows(display: nil, labels: [:], now: now).isEmpty)
        XCTAssertTrue(RemoteHostLoginRowModel.rows(display: display([], isCurrent: false), labels: [:], now: now).isEmpty)
        let accounts = [
            account(.claude, claudeID, .fresh, expiresAt: now),
            account(.chatgpt, "user-fixture", .refreshFailed),
            account(.chatgpt, "legacy-chatgpt", .expired),
            account(.chatgpt, "user-challenged", .challenged),
            account(.claude, "claude.default", nil, source: .none),
        ]
        let current = RemoteHostLoginRowModel.rows(display: display(accounts), labels: [:], now: now)
        let stale = RemoteHostLoginRowModel.rows(display: display(accounts, isCurrent: false), labels: [:], now: now)
        XCTAssertEqual(stale.count, accounts.count)
        XCTAssertEqual(stale.map(\.id), current.map(\.id))
        XCTAssertEqual(stale.map(\.canLogIn), current.map(\.canLogIn))
        XCTAssertEqual(stale.map(\.sourceText), current.map(\.sourceText))
        XCTAssertEqual(stale.map(\.expiryText), current.map(\.expiryText))
        XCTAssertTrue(stale.allSatisfy { $0.badgeText == "Unknown" && $0.badgeTone == .neutral })
    }

    private func account(_ provider: HostLoginProvider, _ id: String, _ state: HostLoginState?,
                         source: HostCredentialSource = .hostLogin, expiresAt: Date? = nil) -> HostSourcesAccountDTO {
        HostSourcesAccountDTO(
            provider: provider, id: id, verdict: .unpolled, observedAt: nil, source: source, hostLogin: source == .hostLogin,
            login: state.map { HostLoginHealthDTO(state: $0, reason: "", refreshExpiresAt: expiresAt, lastRefreshAt: nil) }
        )
    }

    private func display(_ accounts: [HostSourcesAccountDTO], isCurrent: Bool = true) -> RemoteHostLoginDisplay {
        RemoteHostLoginDisplay(rows: accounts, fetchedAt: isCurrent ? now : nil, isCurrent: isCurrent)
    }
}
