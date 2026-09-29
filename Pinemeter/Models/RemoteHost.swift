import CryptoKit
import Darwin
import Foundation

enum RemotePushResult: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
}

enum RemoteCredentialStatus: String, Codable, Equatable, Sendable {
    case unknown
    case fresh
    case expired
    case challenged
}

struct RemoteHost: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var host: String
    var sshUser: String
    var keyPath: String
    var secretReference: String
    var pinnedHostKeyFingerprint: String
    var lastPushAt: Date?
    var lastPushResult: RemotePushResult?
    var sanitizedError: String?
    var credentialStatus: RemoteCredentialStatus
    var observedAt: Date?
    var observedGeneration: UInt64?

    init(
        id: UUID = UUID(),
        host: String,
        sshUser: String,
        keyPath: String,
        secretReference: String,
        pinnedHostKeyFingerprint: String,
        lastPushAt: Date? = nil,
        lastPushResult: RemotePushResult? = nil,
        sanitizedError: String? = nil,
        credentialStatus: RemoteCredentialStatus = .unknown,
        observedAt: Date? = nil,
        observedGeneration: UInt64? = nil
    ) {
        self.id = id
        self.host = host
        self.sshUser = sshUser
        self.keyPath = keyPath
        self.secretReference = secretReference
        self.pinnedHostKeyFingerprint = pinnedHostKeyFingerprint
        self.lastPushAt = lastPushAt
        self.lastPushResult = lastPushResult
        self.sanitizedError = sanitizedError
        self.credentialStatus = credentialStatus
        self.observedAt = observedAt
        self.observedGeneration = observedGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case id, host, sshUser = "ssh_user", keyPath = "key_path"
        case secretReference = "secret_reference"
        case pinnedHostKeyFingerprint = "pinned_host_key_fingerprint"
        case lastPushAt = "last_push_at", lastPushResult = "last_push_result"
        case sanitizedError = "sanitized_error", credentialStatus = "credential_status"
        case observedAt = "observed_at", observedGeneration = "observed_generation"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        host = try container.decode(String.self, forKey: .host)
        sshUser = try container.decode(String.self, forKey: .sshUser)
        keyPath = try container.decode(String.self, forKey: .keyPath)
        secretReference = try container.decode(String.self, forKey: .secretReference)
        pinnedHostKeyFingerprint = try container.decode(String.self, forKey: .pinnedHostKeyFingerprint)
        lastPushAt = try container.decodeIfPresent(Date.self, forKey: .lastPushAt)
        lastPushResult = try container.decodeIfPresent(RemotePushResult.self, forKey: .lastPushResult)
        sanitizedError = try container.decodeIfPresent(String.self, forKey: .sanitizedError)
        credentialStatus = try container.decodeIfPresent(RemoteCredentialStatus.self, forKey: .credentialStatus) ?? .unknown
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        observedGeneration = try container.decodeIfPresent(UInt64.self, forKey: .observedGeneration)
    }
}

struct ParsedHostKey: Equatable, Sendable {
    let record: String
    let fingerprint: String
}

enum RemoteHostValidationError: LocalizedError, Equatable {
    case invalidHost
    case invalidSSHUser
    case invalidKeyPath
    case unreadablePrivateKey
    case encryptedPrivateKey
    case invalidPinnedHostKey
    case duplicateHost

    var errorDescription: String? {
        switch self {
        case .invalidHost: "Enter a valid DNS name or IP address without a scheme or port."
        case .invalidSSHUser: "Enter a valid SSH user."
        case .invalidKeyPath, .unreadablePrivateKey: "Cannot read the SSH key. Check the path and permissions."
        case .encryptedPrivateKey: "Encrypted SSH keys are not supported for automatic push. Select an unencrypted key."
        case .invalidPinnedHostKey: "Enter one valid SSH public host key."
        case .duplicateHost: "This SSH user and host are already configured."
        }
    }
}

enum RemoteHostValidator {
    static func normalizedHost(_ value: String) throws -> String {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.hasPrefix("-"),
              value.unicodeScalars.allSatisfy({
                  !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
              }),
              !value.contains("://"),
              !value.contains("@"),
              !value.contains("[") && !value.contains("]")
        else { throw RemoteHostValidationError.invalidHost }

        if isIPAddress(value) { return value.lowercased() }
        guard !value.contains(":"), value.utf8.count <= 253 else {
            throw RemoteHostValidationError.invalidHost
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first?.isASCII == true, label.last?.isASCII == true,
                  label.first?.isLetter == true || label.first?.isNumber == true,
                  label.last?.isLetter == true || label.last?.isNumber == true
            else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { throw RemoteHostValidationError.invalidHost }
        return value.lowercased()
    }

    static func normalizedSSHUser(_ value: String) throws -> String {
        guard (1...32).contains(value.utf8.count),
              value.first?.isLetter == true || value.first == "_",
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) })
        else { throw RemoteHostValidationError.invalidSSHUser }
        return value
    }

    static func readPrivateKey(at path: String) throws -> Data {
        guard path.hasPrefix("/") || path.hasPrefix("~/"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw RemoteHostValidationError.invalidKeyPath }
        let expanded = path.hasPrefix("~/")
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path
            : path
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let data = try? Data(contentsOf: url),
              !data.isEmpty, data.count <= 1_048_576
        else { throw RemoteHostValidationError.unreadablePrivateKey }
        try validatePrivateKey(data)
        return data
    }

    static func parsePinnedHostKey(_ value: String) throws -> ParsedHostKey {
        let lines = value.split(whereSeparator: \Character.isNewline)
        guard lines.count == 1 else { throw RemoteHostValidationError.invalidPinnedHostKey }
        let fields = lines[0].split(whereSeparator: \Character.isWhitespace)
        guard fields.count == 2 else { throw RemoteHostValidationError.invalidPinnedHostKey }
        let type = String(fields[0])
        guard ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"].contains(type),
              let blob = Data(base64Encoded: String(fields[1]), options: []),
              validHostKeyBlob(blob, declaredType: type)
        else { throw RemoteHostValidationError.invalidPinnedHostKey }
        let encoded = blob.base64EncodedString()
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return ParsedHostKey(record: "\(type) \(encoded)", fingerprint: "SHA256:\(digest)")
    }

    static func isDuplicate(host: String, sshUser: String, among existing: [RemoteHost]) throws -> Bool {
        let host = try normalizedHost(host)
        let user = try normalizedSSHUser(sshUser)
        return existing.contains { $0.host.lowercased() == host && $0.sshUser.lowercased() == user }
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return value.withCString {
            inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1
        }
    }

    private static func validatePrivateKey(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RemoteHostValidationError.unreadablePrivateKey
        }
        if text.contains("ENCRYPTED PRIVATE KEY") || text.contains("Proc-Type: 4,ENCRYPTED") {
            throw RemoteHostValidationError.encryptedPrivateKey
        }
        if text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
            let body = text
                .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
                .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
                .filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: body),
                  decoded.starts(with: Data("openssh-key-v1\0".utf8))
            else { throw RemoteHostValidationError.unreadablePrivateKey }
            var cursor = SSHBlobCursor(data: decoded, offset: 15)
            guard let cipher = cursor.readString() else { throw RemoteHostValidationError.unreadablePrivateKey }
            guard cipher == Data("none".utf8) else { throw RemoteHostValidationError.encryptedPrivateKey }
            return
        }
        let acceptedHeaders = [
            "-----BEGIN PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN EC PRIVATE KEY-----", "-----BEGIN DSA PRIVATE KEY-----",
        ]
        guard acceptedHeaders.contains(where: text.contains) else {
            throw RemoteHostValidationError.unreadablePrivateKey
        }
    }

    private static func validHostKeyBlob(_ data: Data, declaredType: String) -> Bool {
        var cursor = SSHBlobCursor(data: data)
        guard let embedded = cursor.readString().flatMap({ String(data: $0, encoding: .utf8) }),
              embedded == declaredType
        else { return false }
        switch declaredType {
        case "ssh-ed25519":
            return cursor.readString()?.count == 32 && cursor.isAtEnd
        case "ssh-rsa":
            guard let exponent = cursor.readString(), !exponent.isEmpty,
                  let modulus = cursor.readString(), !modulus.isEmpty
            else { return false }
            return cursor.isAtEnd
        default:
            guard let curve = cursor.readString().flatMap({ String(data: $0, encoding: .utf8) }),
                  declaredType == "ecdsa-sha2-\(curve)",
                  let point = cursor.readString(), !point.isEmpty
            else { return false }
            return cursor.isAtEnd
        }
    }
}

private struct SSHBlobCursor {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readString() -> Data? {
        guard offset <= data.count - 4 else { return nil }
        let length = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        guard length >= 0, offset <= data.count - length else { return nil }
        defer { offset += length }
        return data[offset..<(offset + length)]
    }
}
