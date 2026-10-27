import Foundation

enum T3DispatchFailure: Equatable, Sendable {
    case t3NotRunning
    case originRefused
    case notConnected
    case credentialLapsed
    case credentialRejected
    case unusablePairingInput
    case proofKeyBoundPairingToken
    case insufficientScope(String)
    case commandRefused
    case projectGone
    case noModelResolvable
    case responseTooLarge
    case transportFailure
    case invalidResponse
    case unexpectedStatus(Int)

    static func classify(_ error: Error) -> T3DispatchFailure {
        guard let error = error as? T3DispatchClientError else { return .transportFailure }
        switch error {
        case .invalidOrigin:
            return .originRefused
        case .unauthorized:
            return .credentialRejected
        case .insufficientScope(let scope):
            return .insufficientScope(displayedScope(scope))
        case .invalidCommand:
            return .commandRefused
        case .badStatus(let status):
            return .unexpectedStatus(status)
        case .tooLarge:
            return .responseTooLarge
        case .transport:
            return .transportFailure
        case .dpopTokenIssued, .unsupportedTokenType:
            return .proofKeyBoundPairingToken
        case .invalidResponse:
            return .invalidResponse
        }
    }

    var message: String {
        switch self {
        case .t3NotRunning, .originRefused:
            "T3 is not running on this Mac. Open T3 on this Mac and try again."
        case .notConnected:
            "Connect T3 before starting an instruction check."
        case .credentialLapsed:
            "The T3 connection expired. Create a new pairing link in T3 under \(T3AppLauncher.pairingLocation)."
        case .credentialRejected:
            "T3 rejected the connection. Create a new pairing link in T3 under \(T3AppLauncher.pairingLocation)."
        case .unusablePairingInput:
            "The pairing value is unusable. Copy a new pairing token or pairing link from T3."
        case .proofKeyBoundPairingToken:
            "A plain pairing token is needed. The token from T3 is bound to a proof key."
        case .insufficientScope(let displayedScope):
            "The T3 connection does not grant \(displayedScope). Create a new pairing link in T3 under \(T3AppLauncher.pairingLocation), with that scope."
        case .commandRefused:
            "T3 refused the instruction-check command. Update T3 or choose the project again."
        case .projectGone:
            "The chosen project no longer exists in T3. Choose another project."
        case .noModelResolvable:
            "Set a default model on the project in T3, or add a T3 instance to the broker."
        case .responseTooLarge:
            "T3 returned a response over Pinemeter's size limit. Reduce the project list in T3 and try again."
        case .transportFailure:
            "Pinemeter could not reach T3. Open T3 on this Mac and try again."
        case .invalidResponse:
            "T3 returned an invalid response. Update or restart T3 and try again."
        case .unexpectedStatus(let status):
            "T3 returned status \(status). Check T3 and try again."
        }
    }

    private static func displayedScope(_ scope: String) -> String {
        switch scope {
        case "orchestration:read", "orchestration:operate":
            scope
        default:
            "the required T3 orchestration scope"
        }
    }
}
