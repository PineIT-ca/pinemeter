import XCTest
@testable import Pinemeter

final class CredentialStateTests: XCTestCase {
    func test_credentialIdentity_describesProviderAndKindWithoutCredentialMaterial() {
        let claudeIdentity = CredentialIdentity(provider: .claude, kind: .sessionKey)
        let chatGPTIdentity = CredentialIdentity(provider: .chatGPT, kind: .sessionCookie)
        let geminiIdentity = CredentialIdentity(provider: .gemini, kind: .apiKey)

        XCTAssertEqual(claudeIdentity.id, "claude.sessionKey")
        XCTAssertEqual(claudeIdentity.displayName, "Claude session key")
        XCTAssertEqual(chatGPTIdentity.id, "chatGPT.sessionCookie")
        XCTAssertEqual(chatGPTIdentity.displayName, "ChatGPT session cookie")
        XCTAssertEqual(geminiIdentity.id, "gemini.apiKey")
        XCTAssertEqual(geminiIdentity.displayName, "Gemini API key")
    }

    func test_credentialHealthState_marksOnlyUsableStatesAsUsable() {
        XCTAssertTrue(CredentialHealthState.valid.isUsable)
        XCTAssertTrue(CredentialHealthState.refreshRecommended.isUsable)

        XCTAssertFalse(CredentialHealthState.missing.isUsable)
        XCTAssertFalse(CredentialHealthState.invalid.isUsable)
        XCTAssertFalse(CredentialHealthState.expired.isUsable)
        XCTAssertFalse(CredentialHealthState.unavailable.isUsable)
        XCTAssertFalse(CredentialHealthState.unknown.isUsable)
    }

    func test_failureCategories_exposeSanitizedUserFacingDescriptions() {
        let forbiddenFragments = [
            "sk-ant-",
            "sessionKey=",
            "__Secure-next-auth.session-token",
            "Bearer ",
            "access-token"
        ]

        for category in CredentialFailureCategory.allCases {
            let displayText = [
                category.displayTitle,
                category.displayDescription,
                category.recoverySuggestion ?? ""
            ].joined(separator: " ")

            for fragment in forbiddenFragments {
                XCTAssertFalse(
                    displayText.contains(fragment),
                    "\(category.rawValue) leaked credential-like fragment \(fragment)"
                )
            }
        }

        XCTAssertEqual(CredentialFailureCategory.invalidFormat.displayTitle, "Credential format is invalid")
        XCTAssertEqual(CredentialFailureCategory.providerRejected.displayDescription, "The provider rejected the saved credential.")
        XCTAssertEqual(CredentialFailureCategory.storageUnavailable.recoverySuggestion, "Check Keychain access and try again.")
    }

    func test_credentialState_prefersFailureDescriptionWhenPresent() {
        let state = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: .invalid,
            failureCategory: .providerRejected
        )

        XCTAssertEqual(state.displayTitle, "Claude session key: Credential rejected")
        XCTAssertEqual(state.displayDescription, "The provider rejected the saved credential.")
        XCTAssertEqual(state.recoverySuggestion, "Update the credential and try again.")
    }

    func test_credentialState_usesHealthDescriptionWhenNoFailureIsPresent() {
        let state = CredentialState(
            identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
            health: .valid
        )

        XCTAssertEqual(state.displayTitle, "ChatGPT session cookie: Ready")
        XCTAssertEqual(state.displayDescription, "Credential is available and usable.")
        XCTAssertNil(state.recoverySuggestion)
    }

    func test_credentialState_roundTripsThroughCodable() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_762_290_000)
        let original = CredentialState(
            identity: CredentialIdentity(provider: .chatGPT, kind: .accessToken),
            health: .expired,
            failureCategory: .expired,
            checkedAt: checkedAt
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CredentialState.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.identity.displayName, "ChatGPT access token")
    }

    func test_geminiCredentialStateUsesSanitizedProviderDiagnostics() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_234)
        let original = CredentialState(
            identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
            health: .invalid,
            failureCategory: .invalidFormat,
            checkedAt: checkedAt
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CredentialState.self, from: data)

        XCTAssertEqual(decoded.identity.id, "gemini.apiKey")
        XCTAssertEqual(decoded.displayTitle, "Gemini API key: Credential format is invalid")
        XCTAssertEqual(decoded.displayDescription, "The saved credential does not match the expected format.")
        XCTAssertEqual(decoded.recoverySuggestion, "Update the credential and try again.")
        XCTAssertFalse(decoded.displayTitle.contains("AIza"))
        XCTAssertFalse(decoded.displayDescription.contains("Bearer"))
    }
}
