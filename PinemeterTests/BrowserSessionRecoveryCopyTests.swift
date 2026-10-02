//
//  BrowserSessionRecoveryCopyTests.swift
//  PinemeterTests
//
//  Locks the per-provider login prompt (D-03) and the "reconnected" copy
//  (D-04) so the real recheck window and the real site names never drift
//  from what the code actually does.
//

import XCTest
@testable import Pinemeter

final class BrowserSessionRecoveryCopyTests: XCTestCase {
    func test_chatGPTOnly_titleMessageButtonsAndDismiss() {
        let copy = BrowserLoginPromptCopy(providers: [.chatGPT])

        XCTAssertEqual(copy.title, "Sign In to ChatGPT Again")
        XCTAssertEqual(
            copy.message,
            "Pinemeter could not restore your ChatGPT browser session. Codex routes use your ChatGPT account. "
                + "Sign in at chatgpt.com in Chrome, Safari, or Firefox. Pinemeter rechecks your browsers every "
                + "30 seconds for the next 10 minutes and reconnects automatically."
        )
        XCTAssertEqual(copy.signInButtons, [
            BrowserSignInButton(title: "Open chatgpt.com", url: URL(string: "https://chatgpt.com/auth/login")!)
        ])
        XCTAssertEqual(copy.dismissButtonTitle, "Later")
    }

    func test_claudeOnly_namesClaudeSiteAndRouteDependency() {
        let copy = BrowserLoginPromptCopy(providers: [.claude])

        XCTAssertEqual(copy.title, "Sign In to Claude Again")
        XCTAssertTrue(copy.message.contains("claude.ai"))
        XCTAssertTrue(copy.message.contains("Claude routes use your Claude account."))
        XCTAssertEqual(copy.signInButtons, [
            BrowserSignInButton(title: "Open claude.ai", url: URL(string: "https://claude.ai/login")!)
        ])
    }

    func test_bothProviders_pluralizesAndListsBothSitesAndButtonsInOrder() {
        let copy = BrowserLoginPromptCopy(providers: [.chatGPT, .claude])

        XCTAssertEqual(copy.title, "Sign In to ChatGPT and Claude Again")
        XCTAssertTrue(copy.message.contains("browser sessions"))
        XCTAssertTrue(copy.message.contains("Codex routes use your ChatGPT account."))
        XCTAssertTrue(copy.message.contains("Claude routes use your Claude account."))
        XCTAssertTrue(copy.message.contains("chatgpt.com and claude.ai"))
        XCTAssertEqual(copy.signInButtons.map(\.title), ["Open chatgpt.com", "Open claude.ai"])
    }

    func test_secondsAndMinutes_areDerivedFromThePolicy() {
        let copy = BrowserLoginPromptCopy(
            providers: [.chatGPT],
            policy: BrowserRecoveryWatchPolicy(interval: .seconds(15), maxAttempts: 8)
        )

        XCTAssertTrue(
            copy.message.contains("every 15 seconds for the next 2 minutes"),
            copy.message
        )
    }

    func test_reconnectedCopy_chatGPT() {
        let notice = BrowserReconnectedNotice(provider: .chatGPT)
        XCTAssertEqual(notice.title, "ChatGPT reconnected")
        XCTAssertEqual(notice.body, "Codex routes use fresh ChatGPT quota again.")
    }

    func test_reconnectedCopy_claude() {
        let notice = BrowserReconnectedNotice(provider: .claude)
        XCTAssertEqual(notice.title, "Claude reconnected")
        XCTAssertEqual(notice.body, "Claude routes use fresh Claude quota again.")
    }
}
