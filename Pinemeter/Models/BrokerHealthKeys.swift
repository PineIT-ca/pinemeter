import CryptoKit
import Foundation

enum BrokerHealthKeys {
    // The operator adds keygen's public entry in plan 29-11. Private material
    // and golden test keys must never be included in this release map.
    static let encoded: [String: String] = [
        "health-2026-10": "uaK0I9qgGsmr7CMmtGKwW18vCjvyU2qS2Nk5pyOmc8o=",
    ]

    static let trusted: [String: Curve25519.Signing.PublicKey] = {
        var keys: [String: Curve25519.Signing.PublicKey] = [:]
        for (kid, text) in encoded {
            guard kid.range(of: "^health-[0-9]{4}-[0-9]{2}\\z", options: .regularExpression) != nil,
                  let data = Data(base64Encoded: text),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else {
                fatalError("Invalid pinned health public key")
            }
            keys[kid] = key
        }
        return keys
    }()
}
