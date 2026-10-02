import XCTest
@testable import Pinemeter

final class SessionKeyTests: XCTestCase {
    func test_sessionKey_acceptsRawSessionKey() throws {
        let sessionKey = try SessionKey("  \(TestConstants.sessionKeyValue)  ")

        XCTAssertEqual(sessionKey.value, TestConstants.sessionKeyValue)
    }

    func test_sessionKey_extractsValueFromCookieHeader() throws {
        let sessionKey = try SessionKey("Cookie: foo=bar; sessionKey=\(TestConstants.sessionKeyValue); other=value")

        XCTAssertEqual(sessionKey.value, TestConstants.sessionKeyValue)
    }

    func test_sessionKey_rejectsCookieHeaderWithoutSessionKey() {
        XCTAssertThrowsError(try SessionKey("Cookie: foo=bar"))
    }

    func test_sessionKeyErrorDescriptions_useClaudeSpecificCredentialCopy() {
        XCTAssertEqual(SessionKeyError.invalidFormat.errorDescription, "Claude session key must start with 'sk-ant-'")
        XCTAssertEqual(SessionKeyError.tooShort.errorDescription, "Claude session key is too short")
        XCTAssertEqual(SessionKeyError.validationFailed.errorDescription, "Claude session key could not be validated with Claude API")
    }
}

