import CryptoKit
import Foundation

enum BrokerPresetSignature {
    static let type = "pinemeter-presets"
    static let maxBytes = 524288
    static let maxSequence: UInt64 = 9007199254740991

    enum Rejection: String, LocalizedError, Codable, Sendable {
        case tooLarge = "too_large"
        case malformed
        case unknownKey = "unknown_key"
        case signature
        case wrongType = "wrong_type"
        case unsupportedVersion = "unsupported_version"
        case futureIssued = "future_issued"
        case seqConflict = "seq_conflict"
        case undecodable

        var errorDescription: String? {
            switch self {
            case .unknownKey:
                "This build cannot verify official preset updates. Current presets stay in use."
            case .futureIssued:
                "The official preset update has a date in the future. Current presets stay in use."
            case .undecodable:
                "This version cannot read the official preset update. Update Pinemeter to receive it. Current presets stay in use."
            default:
                "The official preset update failed its signature check. Current presets stay in use."
            }
        }
    }

    static func verify(line: Data, keys: [String: Curve25519.Signing.PublicKey]) throws -> Data {
        guard line.count <= maxBytes else { throw Rejection.tooLarge }
        var trimmed = line
        while let last = trimmed.last, [9, 10, 13, 32].contains(last) { trimmed.removeLast() }
        let parts = trimmed.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = decodeBase64URL(parts[0]),
              let signature = decodeBase64URL(parts[1]), signature.count == 64,
              String(data: payload, encoding: .utf8) != nil,
              let fields = try? fields(in: payload),
              let rawKid = fields.last(where: { $0.name == "kid" })?.value,
              let kid = try? JSONDecoder().decode(String.self, from: rawKid) else { throw Rejection.malformed }
        guard let key = keys[kid] else { throw Rejection.unknownKey }
        guard key.isValidSignature(signature, for: payload) else { throw Rejection.signature }
        return payload
    }

    static func accept(line: Data, stored: Data?, keys: [String: Curve25519.Signing.PublicKey], now: Date) -> BrokerPresetAcceptance {
        do {
            let payload = try parse(line: line, keys: keys, now: now)
            if let stored, let previous = try? parse(line: stored, keys: keys, now: now) {
                if payload.seq < previous.seq {
                    return BrokerPresetAcceptance(outcome: .staleCopy, payload: previous, line: stored)
                }
                if payload.seq == previous.seq {
                    guard line == stored else { throw Rejection.seqConflict }
                    return BrokerPresetAcceptance(outcome: .unchanged, payload: previous, line: stored)
                }
            }
            return BrokerPresetAcceptance(outcome: .accepted, payload: payload, line: line)
        } catch let rejection as Rejection {
            return BrokerPresetAcceptance(outcome: .rejected, category: rejection)
        } catch {
            return BrokerPresetAcceptance(outcome: .rejected, category: .malformed)
        }
    }

    private static func decodeBase64URL(_ part: Data.SubSequence) -> Data? {
        guard !part.isEmpty, let text = String(data: Data(part), encoding: .utf8) else { return nil }
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        let canonical = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return canonical == text ? data : nil
    }

    private static func parse(line: Data, keys: [String: Curve25519.Signing.PublicKey], now: Date) throws -> BrokerPresetPayload {
        let raw = try verify(line: line, keys: keys)
        let entries = try fields(in: raw)
        let names = Set(entries.map(\.name))
        guard entries.count == 6, names == ["v", "typ", "kid", "seq", "issued_at", "manifest"] else { throw Rejection.malformed }
        let fields = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.value) })
        let decoder = JSONDecoder()
        func string(_ name: String) throws -> String { try decoder.decode(String.self, from: fields[name]!) }
        func integer(_ name: String) throws -> UInt64 {
            let text = String(decoding: fields[name]!, as: UTF8.self)
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = UInt64(text) else { throw Rejection.malformed }
            return value
        }
        let version = try integer("v")
        guard version <= UInt64(Int.max) else { throw Rejection.malformed }
        let typ = try string("typ")
        let kid = try string("kid")
        let seq = try integer("seq")
        guard (1...maxSequence).contains(seq),
              let issuedAt = BrokerHealthDocument.parseTime(try string("issued_at")),
              let manifest = try JSONSerialization.jsonObject(with: fields["manifest"]!) as? [String: Any],
              let presets = manifest["presets"] as? [Any], !presets.isEmpty else { throw Rejection.malformed }
        guard typ == type else { throw Rejection.wrongType }
        guard version == 1 else { throw Rejection.unsupportedVersion }
        guard issuedAt <= now.addingTimeInterval(24 * 3600) else { throw Rejection.futureIssued }
        return BrokerPresetPayload(seq: seq, issuedAt: issuedAt, kid: kid,
            manifest: try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]))
    }

    /// Foundation validates JSON; this shallow scan preserves duplicate envelope keys
    /// and integer spellings that dictionary/number decoding would otherwise erase.
    private static func fields(in raw: Data) throws -> [(name: String, value: Data)] {
        guard (try JSONSerialization.jsonObject(with: raw)) is [String: Any] else { throw Rejection.malformed }
        let bytes = Array(raw)
        var index = 0
        func skipSpace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        func stringEnd() -> Int {
            index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 { index += 1 }
                else if byte == 34 { break }
            }
            return index
        }
        skipSpace(); index += 1; skipSpace()
        var result: [(name: String, value: Data)] = []
        while index < bytes.count, bytes[index] != 125 {
            let nameStart = index
            let nameEnd = stringEnd()
            let name = try JSONDecoder().decode(String.self, from: Data(bytes[nameStart..<nameEnd]))
            skipSpace(); index += 1; skipSpace()
            let start = index
            var depth = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 34 { _ = stringEnd(); continue }
                if depth == 0 && (byte == 44 || byte == 125) { break }
                if byte == 123 || byte == 91 { depth += 1 }
                if byte == 125 || byte == 93 { depth -= 1 }
                index += 1
            }
            var end = index
            while end > start, [9, 10, 13, 32].contains(bytes[end - 1]) { end -= 1 }
            result.append((name, Data(bytes[start..<end])))
            if index < bytes.count, bytes[index] == 44 { index += 1; skipSpace() }
        }
        return result
    }
}

struct BrokerPresetPayload: Sendable, Equatable {
    let seq: UInt64
    let issuedAt: Date
    let kid: String
    let manifest: Data
}

struct BrokerPresetAcceptance: Sendable {
    enum Outcome: String, Codable, Sendable { case accepted, unchanged, rejected; case staleCopy = "stale_copy" }
    let outcome: Outcome
    var category: BrokerPresetSignature.Rejection? = nil
    var payload: BrokerPresetPayload? = nil
    var line: Data? = nil
}
