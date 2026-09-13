//
//  BrokerAccessPolicy.swift
//  Pinemeter
//
//  Who is allowed to talk to the broker's MCP endpoint.
//
//  The policy is a plain value rather than a service so the HTTP front-end
//  can carry it as a `@Sendable` closure and AppModel can compare two of them
//  to decide whether a running server needs restarting. It holds the API key
//  in memory for exactly as long as the server it configured is running; the
//  durable copy lives in the Keychain and nowhere else.
//

import Foundation
import Security

/// The access rules a running broker server was built with: which interface
/// it is bound to, when a caller must present the API key, and the key to
/// compare against.
struct BrokerAccessPolicy: Sendable, Equatable {
    /// Which interface the listener binds to.
    var networkAccess: BrokerNetworkAccess

    /// When a caller must present the key.
    var apiKeyMode: BrokerAPIKeyMode

    /// The provisioned key, or `nil` when none has been generated yet.
    /// A `nil` key with a mode that requires one fails closed: every request
    /// that needs a key is rejected rather than waved through.
    var apiKey: String?

    /// The historical behaviour, byte for byte: loopback-bound, no auth.
    static let loopbackDefault = BrokerAccessPolicy(
        networkAccess: .loopback,
        apiKeyMode: .none,
        apiKey: nil
    )

    /// The Keychain account the broker's API key is stored under. The key is
    /// never written to settings, logs, or any other store.
    static let keychainAccount = "broker-api-key"

    /// Whether a request presenting `headers` from a peer that is (or is not)
    /// on the loopback interface may proceed.
    ///
    /// - Parameters:
    ///   - headers: The request's headers, exactly as parsed off the wire.
    ///   - isLoopbackPeer: Whether the remote peer address is a loopback
    ///     address. Callers that cannot determine the peer must pass `false`.
    func authorizes(headers: [String: String], isLoopbackPeer: Bool) -> Bool {
        guard requiresKey(isLoopbackPeer: isLoopbackPeer) else { return true }
        guard let apiKey, !apiKey.isEmpty else { return false }
        guard let presented = Self.presentedKey(in: headers), !presented.isEmpty else { return false }
        return Self.constantTimeEquals(presented, apiKey)
    }

    /// Whether a peer on this side of the loopback boundary needs a key.
    func requiresKey(isLoopbackPeer: Bool) -> Bool {
        switch apiKeyMode {
        case .none: return false
        case .all: return true
        case .nonLoopback: return !isLoopbackPeer
        }
    }

    // MARK: - Key material

    /// A fresh key: 32 random bytes, base64url without padding, prefixed so
    /// it is recognizable in a client config at a glance.
    static func generateAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // `SecRandomCopyBytes` failing is close to impossible, but the
            // fallback must still be a CSPRNG rather than anything derived
            // from time or process state.
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
            }
        }
        let base64URL = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "pm_\(base64URL)"
    }

    /// The key a request presents, from either accepted header.
    ///
    /// `Authorization: Bearer <key>` is what MCP clients send; `X-API-Key` is
    /// the shape most shell and script callers reach for first. Both header
    /// names and the `Bearer` scheme are matched case-insensitively, per
    /// RFC 9110.
    static func presentedKey(in headers: [String: String]) -> String? {
        if let authorization = header("Authorization", in: headers) {
            let trimmed = authorization.trimmingCharacters(in: .whitespaces)
            let scheme = "bearer "
            if trimmed.count > scheme.count, trimmed.prefix(scheme.count).lowercased() == scheme {
                return String(trimmed.dropFirst(scheme.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let apiKeyHeader = header("X-API-Key", in: headers) {
            return apiKeyHeader.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }

    /// Compares two keys without leaking their common prefix length through
    /// timing. The length check cannot early-return before the byte loop, so
    /// a mismatched length is folded into the same accumulator as a
    /// mismatched byte.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        var difference = UInt8(lhsBytes.count == rhsBytes.count ? 0 : 1)
        // Walk the longer of the two, indexing each side modulo its own
        // length, so the loop's trip count never depends on where the first
        // differing byte is.
        let count = max(lhsBytes.count, rhsBytes.count)
        guard count > 0 else { return difference == 0 }
        for index in 0..<count {
            let lhsByte = lhsBytes.isEmpty ? 0 : lhsBytes[index % lhsBytes.count]
            let rhsByte = rhsBytes.isEmpty ? 0 : rhsBytes[index % rhsBytes.count]
            difference |= lhsByte ^ rhsByte
        }
        return difference == 0
    }
}
