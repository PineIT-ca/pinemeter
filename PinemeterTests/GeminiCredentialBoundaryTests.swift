//
//  GeminiCredentialBoundaryTests.swift
//  PinemeterTests
//
//  Created by GSD on 2026-06-24.
//

import XCTest
@testable import Pinemeter

final class GeminiCredentialBoundaryTests: XCTestCase {
    func test_apiKeyTrimsWhitespaceAndRedactsDebugOutput() throws {
        let apiKey = try GeminiAPIKey("  AIzaSySyntheticGeminiCredential  ")

        XCTAssertEqual(apiKey.value, "AIzaSySyntheticGeminiCredential")
        XCTAssertEqual(apiKey.debugDescription, "GeminiAPIKey(<redacted>)")
        XCTAssertFalse(apiKey.debugDescription.contains(apiKey.value))
    }

    func test_emptyAPIKeyIsRejected() {
        XCTAssertThrowsError(try GeminiAPIKey("   ")) { error in
            XCTAssertEqual(error as? GeminiAPIKeyRepositoryError, .invalidAPIKey)
        }
    }

    func test_acquisitionStatusDoesNotDiscloseAPIKey() throws {
        let apiKey = try GeminiAPIKey("AIzaSySyntheticGeminiCredential")
        let status = GeminiAPIKeyAcquisitionStatus(state: .invalid, lastErrorCategory: .invalidAPIKey)

        XCTAssertFalse(status.debugDescription.contains(apiKey.value))
    }

    func test_geminiCredentialStorageUsesDedicatedKeychainNamespace() {
        XCTAssertEqual(GeminiAPIKeyStorage.serviceName, "com.pinemeter.gemini.api-key")
        XCTAssertEqual(GeminiAPIKeyStorage.defaultAccount, "gemini")
    }

    func test_geminiCredentialHealthMapsToSanitizedHealthStates() {
        XCTAssertEqual(GeminiAPIKeyAcquisitionState.available.credentialHealth, .valid)
        XCTAssertEqual(GeminiAPIKeyAcquisitionState.missing.credentialHealth, .missing)
        XCTAssertEqual(GeminiAPIKeyAcquisitionState.invalid.credentialHealth, .invalid)
        XCTAssertEqual(GeminiAPIKeyAcquisitionState.storageUnavailable.credentialHealth, .unavailable)
    }

    func test_geminiUsageErrorDescriptionsDoNotDiscloseCredentialMaterial() {
        let forbiddenCredential = "AIzaSySyntheticGeminiCredential"
        let descriptions = [
            GeminiUsageError.missingAPIKey,
            .invalidAPIKey,
            .quotaUnavailable,
            .invalidResponse,
            .httpError(statusCode: 401),
            .networkUnavailable,
        ].compactMap(\.errorDescription)

        XCTAssertFalse(descriptions.isEmpty)
        for description in descriptions {
            XCTAssertFalse(description.contains(forbiddenCredential))
        }
    }
}
