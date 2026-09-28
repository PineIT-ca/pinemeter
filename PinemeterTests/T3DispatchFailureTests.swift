import XCTest
@testable import Pinemeter

final class T3DispatchFailureTests: XCTestCase {
    func test_classify_mapsEveryClientErrorToANamedFailure() {
        for error in representativeClientErrors {
            XCTAssertEqual(T3DispatchFailure.classify(error), expectedFailure(for: error))
        }
    }

    func test_notRunningAndNonLoopbackOriginNameTheT3SideToFix() {
        let expected = "T3 is not running on this Mac. Open T3 on this Mac and try again."

        XCTAssertEqual(T3DispatchFailure.t3NotRunning.message, expected)
        XCTAssertEqual(T3DispatchFailure.classify(T3DispatchClientError.invalidOrigin).message, expected)
    }

    func test_nonBearerTokenResultsNameTheProofKeyFix() {
        for error in [
            T3DispatchClientError.dpopTokenIssued,
            T3DispatchClientError.unsupportedTokenType,
        ] {
            let failure = T3DispatchFailure.classify(error)
            XCTAssertEqual(failure, .proofKeyBoundPairingToken)
            XCTAssertTrue(failure.message.contains("plain pairing token"))
            XCTAssertTrue(failure.message.contains("proof key"))
        }
    }

    func test_insufficientScopeMessageNamesTheRequiredScope() {
        let failure = T3DispatchFailure.classify(
            T3DispatchClientError.insufficientScope("orchestration:operate")
        )

        XCTAssertEqual(failure, .insufficientScope("orchestration:operate"))
        XCTAssertTrue(failure.message.contains("orchestration:operate"))
        XCTAssertTrue(failure.message.contains("T3"))
    }

    func test_projectGoneIsDistinctFromNoModelResolvable() {
        XCTAssertNotEqual(T3DispatchFailure.projectGone, .noModelResolvable)
        XCTAssertTrue(T3DispatchFailure.projectGone.message.contains("project"))
        XCTAssertTrue(T3DispatchFailure.noModelResolvable.message.contains("default model"))
        XCTAssertTrue(T3DispatchFailure.noModelResolvable.message.contains("broker"))
    }

    func test_messagesAndDescriptionsNeverCarryCredentialHeaderOrResponseMaterial() {
        let failures = allFailures + [
            T3DispatchFailure.classify(
                T3DispatchClientError.transport("Authorization: Bearer access-token response-body")
            ),
            T3DispatchFailure.classify(
                T3DispatchClientError.insufficientScope("Authorization: Bearer access-token response-body")
            ),
        ]

        for failure in failures {
            for text in [failure.message, String(describing: failure)] {
                for forbidden in ["access-token", "Authorization", "Bearer", "response-body"] {
                    XCTAssertFalse(text.contains(forbidden), "Failure exposed \(forbidden)")
                }
            }
        }
    }

    private var representativeClientErrors: [T3DispatchClientError] {
        [
            .invalidOrigin,
            .unauthorized,
            .insufficientScope("orchestration:operate"),
            .invalidCommand,
            .badStatus(503),
            .tooLarge,
            .transport("private transport detail"),
            .dpopTokenIssued,
            .unsupportedTokenType,
            .invalidResponse,
        ]
    }

    private func expectedFailure(for error: T3DispatchClientError) -> T3DispatchFailure {
        switch error {
        case .invalidOrigin:
            .originRefused
        case .unauthorized:
            .credentialRejected
        case .insufficientScope(let scope):
            .insufficientScope(scope)
        case .invalidCommand:
            .commandRefused
        case .badStatus(let status):
            .unexpectedStatus(status)
        case .tooLarge:
            .responseTooLarge
        case .transport:
            .transportFailure
        case .dpopTokenIssued, .unsupportedTokenType:
            .proofKeyBoundPairingToken
        case .invalidResponse:
            .invalidResponse
        }
    }

    private var allFailures: [T3DispatchFailure] {
        [
            .t3NotRunning,
            .originRefused,
            .notConnected,
            .credentialLapsed,
            .credentialRejected,
            .unusablePairingInput,
            .proofKeyBoundPairingToken,
            .insufficientScope("orchestration:operate"),
            .commandRefused,
            .projectGone,
            .noModelResolvable,
            .responseTooLarge,
            .transportFailure,
            .invalidResponse,
            .unexpectedStatus(503),
        ]
    }
}
