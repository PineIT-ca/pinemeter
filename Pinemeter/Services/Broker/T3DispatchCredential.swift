import Foundation

enum T3DispatchConnectionState: Equatable, Sendable {
    case connected
    case expiringSoon
    case expired
}

struct T3DispatchCredential: Codable, Equatable, Sendable {
    static let keychainAccount = "t3-dispatch-token"
    static let expiringSoonInterval: TimeInterval = 3 * 24 * 60 * 60

    let accessToken: String
    let expiresAt: Date
    let scope: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresAt = "expires_at"
        case scope
    }

    func state(now: Date) -> T3DispatchConnectionState {
        Self.state(expiresAt: expiresAt, now: now)
    }

    static func state(expiresAt: Date, now: Date) -> T3DispatchConnectionState {
        if expiresAt <= now { return .expired }
        if expiresAt.timeIntervalSince(now) <= expiringSoonInterval { return .expiringSoon }
        return .connected
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decode(_ value: String) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: Data(value.utf8))
    }
}

enum T3DispatchConnection: Equatable, Sendable {
    case notConnected
    case connected(expiresAt: Date, scope: String)
    case expired(expiredAt: Date)

    func state(at date: Date) -> T3DispatchConnectionState? {
        switch self {
        case .notConnected:
            return nil
        case .expired:
            return .expired
        case .connected(let expiresAt, _):
            return T3DispatchCredential.state(expiresAt: expiresAt, now: date)
        }
    }
}

enum InstructionDispatchTrigger: Equatable, Sendable {
    case manual
    case automatic
}
