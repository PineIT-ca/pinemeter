import Foundation

/// Provider that owns a credential used by Pinemeter.
enum CredentialProvider: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case claude
    case chatGPT
    case gemini

    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .chatGPT:
            return "ChatGPT"
        case .gemini:
            return "Gemini"
        }
    }
}

/// Credential material type, without storing the credential material itself.
enum CredentialKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case sessionKey
    case sessionCookie
    case accessToken
    case apiKey

    var displayName: String {
        switch self {
        case .sessionKey:
            return "session key"
        case .sessionCookie:
            return "session cookie"
        case .accessToken:
            return "access token"
        case .apiKey:
            return "API key"
        }
    }
}

/// Stable identity for a provider credential. This intentionally contains no raw credential value.
struct CredentialIdentity: Codable, Equatable, Hashable, Identifiable, Sendable {
    let provider: CredentialProvider
    let kind: CredentialKind

    var id: String {
        "\(provider.rawValue).\(kind.rawValue)"
    }

    var displayName: String {
        "\(provider.displayName) \(kind.displayName)"
    }
}

/// Sanitized credential health state suitable for service/UI boundaries.
enum CredentialHealthState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case unknown
    case missing
    case validating
    case valid
    case refreshRecommended
    case invalid
    case expired
    case unavailable

    var isUsable: Bool {
        switch self {
        case .valid, .refreshRecommended:
            return true
        case .unknown, .missing, .validating, .invalid, .expired, .unavailable:
            return false
        }
    }

    var displayTitle: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .missing:
            return "Missing"
        case .validating:
            return "Checking"
        case .valid:
            return "Ready"
        case .refreshRecommended:
            return "Refresh recommended"
        case .invalid:
            return "Invalid"
        case .expired:
            return "Expired"
        case .unavailable:
            return "Unavailable"
        }
    }

    var displayDescription: String {
        switch self {
        case .unknown:
            return "Credential status has not been checked yet."
        case .missing:
            return "No credential is saved for this provider."
        case .validating:
            return "Credential status is being checked."
        case .valid:
            return "Credential is available and usable."
        case .refreshRecommended:
            return "Credential is usable, but refreshing it is recommended."
        case .invalid:
            return "Credential cannot be used in its current state."
        case .expired:
            return "Credential has expired and needs to be updated."
        case .unavailable:
            return "Credential status cannot be checked right now."
        }
    }
}

/// Sanitized failure category for credential diagnostics. Cases avoid carrying raw errors or credential values.
enum CredentialFailureCategory: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case missing
    case invalidFormat
    case providerRejected
    case expired
    case providerUnavailable
    case networkUnavailable
    case storageUnavailable
    case rateLimited
    case unknown

    var displayTitle: String {
        switch self {
        case .missing:
            return "Credential missing"
        case .invalidFormat:
            return "Credential format is invalid"
        case .providerRejected:
            return "Credential rejected"
        case .expired:
            return "Credential expired"
        case .providerUnavailable:
            return "Provider unavailable"
        case .networkUnavailable:
            return "Network unavailable"
        case .storageUnavailable:
            return "Credential storage unavailable"
        case .rateLimited:
            return "Provider rate limited"
        case .unknown:
            return "Credential check failed"
        }
    }

    var displayDescription: String {
        switch self {
        case .missing:
            return "No saved credential was found."
        case .invalidFormat:
            return "The saved credential does not match the expected format."
        case .providerRejected:
            return "The provider rejected the saved credential."
        case .expired:
            return "The saved credential is no longer active."
        case .providerUnavailable:
            return "The provider could not verify the credential right now."
        case .networkUnavailable:
            return "The network request needed to verify the credential failed."
        case .storageUnavailable:
            return "The credential store could not be reached."
        case .rateLimited:
            return "The provider temporarily limited credential verification."
        case .unknown:
            return "Credential verification failed for an unknown reason."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missing:
            return "Add a credential in settings."
        case .invalidFormat, .providerRejected, .expired:
            return "Update the credential and try again."
        case .providerUnavailable, .networkUnavailable, .rateLimited:
            return "Try again later."
        case .storageUnavailable:
            return "Check Keychain access and try again."
        case .unknown:
            return "Try again or update the credential if the problem continues."
        }
    }
}

/// Current sanitized state for a provider credential.
struct CredentialState: Codable, Equatable, Hashable, Sendable {
    let identity: CredentialIdentity
    let health: CredentialHealthState
    let failureCategory: CredentialFailureCategory?
    let checkedAt: Date?

    init(
        identity: CredentialIdentity,
        health: CredentialHealthState,
        failureCategory: CredentialFailureCategory? = nil,
        checkedAt: Date? = nil
    ) {
        self.identity = identity
        self.health = health
        self.failureCategory = failureCategory
        self.checkedAt = checkedAt
    }

    var isUsable: Bool {
        health.isUsable
    }

    var displayTitle: String {
        let status = failureCategory?.displayTitle ?? health.displayTitle
        return "\(identity.displayName): \(status)"
    }

    var displayDescription: String {
        failureCategory?.displayDescription ?? health.displayDescription
    }

    var recoverySuggestion: String? {
        failureCategory?.recoverySuggestion
    }
}
