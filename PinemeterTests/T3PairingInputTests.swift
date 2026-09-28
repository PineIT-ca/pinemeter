import XCTest
@testable import Pinemeter

final class T3PairingInputTests: XCTestCase {
    func test_credential_trimsABareCredential() {
        XCTAssertEqual(
            T3PairingInput.credential(from: "  pair-token+value\n"),
            "pair-token+value"
        )
    }

    func test_credential_takesTheTokenFromAPairingURLFragment() {
        XCTAssertEqual(
            T3PairingInput.credential(from: "t3code://app/pair#token=abc%2Bdef"),
            "abc+def"
        )
    }

    func test_credential_takesTheTokenFromAKeyedFragment() {
        XCTAssertEqual(
            T3PairingInput.credential(from: "t3code://app/pair#a=1&token=abc"),
            "abc"
        )
    }

    func test_credential_takesTheTokenFromAPairingURLQuery() {
        XCTAssertEqual(
            T3PairingInput.credential(from: "t3code://app/pair?token=query%2Btoken+value"),
            "query+token+value"
        )
    }

    func test_credential_prefersTheFragmentTokenOverTheQueryToken() {
        XCTAssertEqual(
            T3PairingInput.credential(from: "https://other.example/pair?token=query#token=fragment"),
            "fragment"
        )
    }

    func test_credential_takesTheQueryTokenWhenTheFragmentHasNoTokenItem() {
        XCTAssertEqual(
            T3PairingInput.credential(from: "https://127.0.0.1:43118/pair?token=REAL#anything"),
            "REAL"
        )
    }

    func test_credential_percentDecodesOnceAndPreservesPlus() {
        XCTAssertEqual(
            T3PairingInput.credential(from: "https://other.example/pair#token=once%252Bplus+value"),
            "once%2Bplus+value"
        )
    }

    func test_credential_returnsNilForAURLWithoutAToken() {
        XCTAssertNil(T3PairingInput.credential(from: "https://other.example/pair?other=value"))
    }

    func test_credential_returnsNilForAnEmptyPaste() {
        XCTAssertNil(T3PairingInput.credential(from: " \n\t "))
    }

    func test_credential_returnsNilForMalformedBareValues() {
        XCTAssertNil(T3PairingInput.credential(from: "two words"))
        XCTAssertNil(T3PairingInput.credential(from: "token\u{0000}value"))
    }

    func test_credential_returnsNilForAPasteOverTheAcceptedBound() {
        XCTAssertEqual(
            T3PairingInput.credential(from: String(repeating: "a", count: 4_096))?.count,
            4_096
        )
        XCTAssertNil(T3PairingInput.credential(from: String(repeating: "a", count: 4_097)))
        XCTAssertNil(
            T3PairingInput.credential(from: String(repeating: " ", count: 4_097) + "token")
        )
    }
}
