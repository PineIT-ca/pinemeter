import XCTest
@testable import Pinemeter

final class SessionKeyImportServiceTests: XCTestCase {
    func test_cookieImportsUseOnlyExactSupportedHosts() {
        XCTAssertEqual(SessionKeyImportService.claudeCookieHosts, ["claude.ai"])
        XCTAssertEqual(SessionKeyImportService.chatGPTCookieHosts, ["chatgpt.com", "chat.openai.com"])
        XCTAssertEqual(
            ChatGPTChromiumCookieFallbackImporter.supportedHosts,
            ["chatgpt.com", ".chatgpt.com", "chat.openai.com", ".chat.openai.com"]
        )
        XCTAssertTrue(ChatGPTChromiumCookieFallbackImporter.cookieQuerySQL.contains("host_key IN"))
        XCTAssertFalse(ChatGPTChromiumCookieFallbackImporter.cookieQuerySQL.contains("%"))
        XCTAssertFalse(ChatGPTChromiumCookieFallbackImporter.cookieQuerySQL.contains("LIKE"))
    }
}
