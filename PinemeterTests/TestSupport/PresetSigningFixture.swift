import CryptoKit
import Foundation
@testable import Pinemeter

enum PresetSigningFixture {
    static let kid = "presets-1999-01"
    static let now = BrokerHealthDocument.parseTime("2026-10-17T12:00:00Z")!
    // Same runtime derivation as the Go golden generator. Test target only.
    static var privateKey: Curve25519.Signing.PrivateKey {
        get throws {
            try Curve25519.Signing.PrivateKey(rawRepresentation:
                Data(SHA256.hash(data: Data("pinemeter presets golden test key v1".utf8))))
        }
    }
    static var keys: [String: Curve25519.Signing.PublicKey] {
        get throws { [kid: try privateKey.publicKey] }
    }

    static func sign(_ payload: Data) throws -> Data {
        func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return Data((encode(payload) + "." + encode(try privateKey.signature(for: payload))).utf8)
    }

    static func line(seq: UInt64 = 1, name: String = "Signed preset") throws -> Data {
        try sign(JSONSerialization.data(withJSONObject: [
            "v": 1, "typ": "pinemeter-presets", "kid": kid, "seq": seq,
            "issued_at": BrokerHealthDocument.formatTime(now),
            "manifest": ["schema_version": 1, "manifest_revision": 1,
                "presets": [["id": "10000000-0000-0000-0000-000000000001", "name": name,
                    "rules": ["default_instance": "claudeAgent"]]],
                "agent_setup": ["revision": 1, "summary": "Signed setup"]]
        ], options: [.sortedKeys]))
    }

    static func line(manifest: BrokerPresetManifest, seq: UInt64 = 1, issuedAt: Date = now) throws -> Data {
        var object: [String: Any] = [
            "schema_version": manifest.schemaVersion,
            "presets": try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest.presets))
        ]
        if let setup = manifest.agentSetup {
            object["agent_setup"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(setup))
        }
        if let revision = manifest.manifestRevision { object["manifest_revision"] = revision }
        if let published = manifest.publishedAt { object["published_at"] = BrokerHealthDocument.formatTime(published) }
        if let summary = manifest.summary { object["summary"] = summary }
        return try sign(JSONSerialization.data(withJSONObject: [
            "v": 1, "typ": "pinemeter-presets", "kid": kid, "seq": seq,
            "issued_at": BrokerHealthDocument.formatTime(issuedAt), "manifest": object
        ], options: [.sortedKeys]))
    }

    static func manifest() throws -> BrokerPresetManifest {
        let part = try line().split(separator: UInt8(ascii: "."))[0]
        var encoded = String(decoding: part, as: UTF8.self).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let root = try JSONSerialization.jsonObject(with: Data(base64Encoded: encoded)!) as! [String: Any]
        return try BrokerPresetManifest.decode(from: JSONSerialization.data(withJSONObject: root["manifest"]!))
    }
}
