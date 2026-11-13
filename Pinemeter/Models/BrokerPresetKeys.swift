import CryptoKit
import Foundation

enum BrokerPresetKeys {
    // The operator pins public entries in D-6. Private material and golden,
    // health or license test keys must never enter this release map.
    static let encoded: [String: String] = [
        "presets-2026-10": "xpzcNT7dquFe4Xlrtvkew+GomQOQYNkQcJ1gBXjejZQ=",
    ]

    static let trusted: [String: Curve25519.Signing.PublicKey] = {
        var keys: [String: Curve25519.Signing.PublicKey] = [:]
        for (kid, text) in encoded {
            guard kid.range(of: "^presets-[0-9]{4}-[0-9]{2}\\z", options: .regularExpression) != nil,
                  let data = Data(base64Encoded: text),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else {
                fatalError("Invalid pinned presets public key")
            }
            keys[kid] = key
        }
        return keys
    }()
}

enum BrokerPresetDistribution {
    static let officialURL = "https://pinemeter-dist.pineit.ca/v1/broker-presets.signed"
    static let freezeWarningDays = 14
}
