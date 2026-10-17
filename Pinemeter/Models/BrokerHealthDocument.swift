import CryptoKit
import Foundation

enum BrokerHealthDocument {
    static let officialURL = "https://raw.githubusercontent.com/PineIT-ca/pinemeter-health/main/v1/model-health.signed"
    static let type = "pinemeter-health"
    static let version = 1
    static let maxBytes = 32768
    static let maxDemotions = 2
    static let maxMethods = 8
    static let maxRoles = 32
    static let maxSources = 16
    static let maxRecent = 16
    static let maxAttribution = 8
    static let maxSequence: Double = 9007199254740991
    static let maxEntryLife: TimeInterval = 72 * 3600
    static let maxEpisode: TimeInterval = 14 * 24 * 3600
    static let maxFutureSkew: TimeInterval = 24 * 3600

    enum Rejection: String, Error, Codable, Sendable {
        case tooLarge = "too_large"
        case malformed
        case unknownKey = "unknown_key"
        case signature
        case wrongType = "wrong_type"
        case unsupportedVersion = "unsupported_version"
        case futureIssued = "future_issued"
        case bounds
        case seqConflict = "seq_conflict"
    }

    static func verify(line: Data, keys: [String: Curve25519.Signing.PublicKey]) throws -> Data {
        guard line.count <= maxBytes else { throw Rejection.tooLarge }
        var trimmed = line
        while let last = trimmed.last, [9, 10, 13, 32].contains(last) { trimmed.removeLast() }
        let parts = trimmed.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payload = decodeBase64URL(parts[0]),
              let signature = decodeBase64URL(parts[1]), signature.count == 64,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let kid = object["kid"] as? String else { throw Rejection.malformed }
        guard let key = keys[kid] else { throw Rejection.unknownKey }
        guard key.isValidSignature(signature, for: payload) else { throw Rejection.signature }
        return payload
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

    static func parseTime(_ text: String) -> Date? {
        guard text.utf8.count == 20,
              text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", options: .regularExpression) != nil else { return nil }
        let fields = text.split(whereSeparator: { "-T:Z".contains($0) }).compactMap { Int($0) }
        guard fields.count == 6 else { return nil }
        let (year, month, day, hour, minute, second) = (fields[0], fields[1], fields[2], fields[3], fields[4], fields[5])
        guard (1...12).contains(month), (1...monthDays(year)[month - 1]).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        // Foundation's ISO formatter uses a Julian calendar before 1582.
        // The signed contract uses proleptic Gregorian dates, as Go does.
        let days = daysBeforeYear(year) - daysBeforeYear(1970) + monthDays(year).prefix(month - 1).reduce(0, +) + day - 1
        return Date(timeIntervalSince1970: Double(days * 86400 + hour * 3600 + minute * 60 + second))
    }

    private static func daysBeforeYear(_ year: Int) -> Int {
        let y = year - 1
        func floorDivide(_ value: Int, _ divisor: Int) -> Int { Int(floor(Double(value) / Double(divisor))) }
        return 365 * y + floorDivide(y, 4) - floorDivide(y, 100) + floorDivide(y, 400)
    }

    private static func monthDays(_ year: Int) -> [Int] {
        [31, year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    }

    static func formatTime(_ date: Date) -> String {
        let seconds = Int(floor(date.timeIntervalSince1970))
        let days = Int(floor(Double(seconds) / 86400))
        let absoluteDays = days + daysBeforeYear(1970)
        var lower = 0, upper = 10000
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if daysBeforeYear(middle) <= absoluteDays { lower = middle } else { upper = middle }
        }
        var day = absoluteDays - daysBeforeYear(lower), month = 1
        for length in monthDays(lower) {
            if day < length { break }
            day -= length; month += 1
        }
        let clock = seconds - days * 86400
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", lower, month, day + 1, clock / 3600, clock / 60 % 60, clock % 60)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseTime(text) else { throw Rejection.malformed }
            return date
        }
        return decoder
    }

    static func accept(body: Data, stored: Data?, keys: [String: Curve25519.Signing.PublicKey], now: Date) -> BrokerHealthAcceptance {
        do {
            let payload = try parse(body: body, keys: keys, now: now)
            if let stored, let previous = try? parse(body: stored, keys: keys, now: now) {
                if payload.seq < previous.seq { return BrokerHealthAcceptance(outcome: .staleCopy, payload: previous, line: stored) }
                if payload.seq == previous.seq {
                    guard body == stored else { throw Rejection.seqConflict }
                    return BrokerHealthAcceptance(outcome: .unchanged, payload: previous, line: stored)
                }
            }
            return BrokerHealthAcceptance(outcome: .accepted, payload: payload, line: body)
        } catch let rejection as Rejection {
            return BrokerHealthAcceptance(outcome: .rejected, category: rejection)
        } catch {
            return BrokerHealthAcceptance(outcome: .rejected, category: .malformed)
        }
    }

    private static func parse(body: Data, keys: [String: Curve25519.Signing.PublicKey], now: Date) throws -> BrokerHealthPayload {
        let raw = try verify(line: body, keys: keys)
        let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
        guard object["typ"] as? String == type else { throw Rejection.wrongType }
        struct Version: Decodable { let v: BrokerHealthInteger }
        let version = try decoder().decode(Version.self, from: raw)
        guard version.v.value == 1 else { throw Rejection.unsupportedVersion }
        guard validShape(object) else { throw Rejection.malformed }
        let payload = try decoder().decode(BrokerHealthPayload.self, from: raw)
        guard payload.issuedAt <= now.addingTimeInterval(maxFutureSkew) else { throw Rejection.futureIssued }
        guard validBounds(payload) else { throw Rejection.bounds }
        return payload
    }

    private static func validShape(_ object: [String: Any]) -> Bool {
        for key in ["recent", "sources", "attribution"] {
            if let value = object[key], !(value is [Any]) { return false }
        }
        if let sources = object["sources"] as? [Any] {
            for value in sources {
                guard let source = value as? [String: Any], source["last_fetch_ok"] != nil, source["newest_data_date"] != nil else { return false }
                for key in ["digest", "series_len"] {
                    if source[key] is NSNull { return false }
                }
            }
        }
        return true
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern.replacingOccurrences(of: "$", with: "\\z"), options: .regularExpression) != nil
    }

    private static func validBounds(_ p: BrokerHealthPayload) -> Bool {
        guard p.seq >= 1, p.seq <= UInt64(maxSequence), p.demotions.count <= maxDemotions,
              (p.sources?.count ?? 0) <= maxSources, (p.recent?.count ?? 0) <= maxRecent,
              (p.attribution?.count ?? 0) <= maxAttribution,
              p.validUntil > p.issuedAt, p.validUntil <= p.issuedAt.addingTimeInterval(maxEntryLife) else { return false }
        var models = Set<String>()
        for d in p.demotions {
            guard matches(d.model, "^[a-z0-9][a-z0-9._-]{0,127}$"), models.insert(d.model).inserted,
                  matches(d.reason, "^[a-z0-9-]{1,64}$"), d.roles.count <= maxRoles,
                  Set(d.roles).count == d.roles.count, d.roles.allSatisfy({ matches($0, "^[a-z0-9][a-z0-9_-]{0,63}$") }),
                  d.methods.count <= maxMethods, Set(d.methods).count >= 2,
                  d.methods.allSatisfy({ matches($0, "^[a-z0-9][a-z0-9-]{0,47}$") }),
                  d.expiresAt > p.issuedAt, d.expiresAt <= p.issuedAt.addingTimeInterval(maxEntryLife),
                  d.since >= p.issuedAt.addingTimeInterval(-maxEpisode), d.since <= p.issuedAt,
                  d.expiresAt <= d.since.addingTimeInterval(maxEpisode) else { return false }
        }
        for s in p.sources ?? [] {
            guard matches(s.id, "^[a-z0-9][a-z0-9-]{0,47}$"), matches(s.state, "^[a-z]{1,16}$"),
                  (1...365).contains(s.staleLimitDays) else { return false }
            if let digest = s.digest, !matches(digest, "^[0-9a-f]{0,64}$") { return false }
            if let length = s.seriesLen, !(0...100000).contains(length) { return false }
            if let day = s.newestDataDate, parseTime(day + "T00:00:00Z") == nil { return false }
        }
        for r in p.recent ?? [] {
            guard matches(r.model, "^[a-z0-9][a-z0-9._-]{0,127}$"), r.endedAt <= p.issuedAt else { return false }
        }
        for line in p.attribution ?? [] {
            guard (1...200).contains(line.unicodeScalars.count), !line.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        }
        return true
    }

    static func status(stored: BrokerHealthPayload?, now: Date, useModelHealth: Bool, lastCheck: BrokerHealthCheck?) -> BrokerHealthStatus {
        let expired = stored.map { now >= $0.validUntil }
        return BrokerHealthStatus(present: stored != nil, useModelHealth: useModelHealth,
            seq: stored?.seq, issuedAt: stored?.issuedAt, validUntil: stored?.validUntil,
            ageSeconds: stored.map { Int(now.timeIntervalSince($0.issuedAt)) }, expired: expired,
            lastCheck: lastCheck,
            demotions: stored.map { p in
                now < p.validUntil ? p.demotions.filter { now < $0.expiresAt }.map {
                    BrokerHealthStatus.Demotion(model: $0.model, roles: $0.roles, expiresAt: $0.expiresAt, methods: $0.methods)
                } : []
            } ?? [],
            sources: (stored?.sources ?? []).map { BrokerHealthStatus.Source(id: $0.id, state: $0.state, lastFetchOk: $0.lastFetchOk, newestDataDate: $0.newestDataDate, staleLimitDays: $0.staleLimitDays) },
            attribution: stored?.attribution.flatMap { $0.isEmpty ? nil : $0 })
    }
}

// Decode exact decimal integers before converting to machine integers. JSON
// booleans and fractional sequences must never acquire a rounded sequence.
private struct BrokerHealthInteger: Decodable {
    let value: Decimal
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        var number = try container.decode(Decimal.self)
        var whole = Decimal()
        NSDecimalRound(&whole, &number, 0, .plain)
        guard whole == number else { throw BrokerHealthDocument.Rejection.malformed }
        value = number
    }
    var boundedInt: Int {
        guard value >= Decimal(Int.min), value <= Decimal(Int.max) else { return -1 }
        return NSDecimalNumber(decimal: value).intValue
    }
}

struct BrokerHealthAcceptance: Sendable {
    enum Outcome: String, Codable, Sendable { case accepted, unchanged, rejected; case staleCopy = "stale_copy" }
    let outcome: Outcome
    var category: BrokerHealthDocument.Rejection? = nil
    var payload: BrokerHealthPayload? = nil
    var line: Data? = nil
}

struct BrokerHealthPayload: Codable, Sendable, Equatable {
    let v: Int
    let typ: String
    let kid: String
    let seq: UInt64
    let issuedAt: Date
    let validUntil: Date
    let demotions: [BrokerHealthDemotion]
    var recent: [BrokerHealthRecent]? = nil
    var sources: [BrokerHealthSource]? = nil
    var attribution: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case v, typ, kid, seq, demotions, recent, sources, attribution
        case issuedAt = "issued_at", validUntil = "valid_until"
    }

    func snapshot(now: Date) -> BrokerHealthSnapshot {
        BrokerHealthSnapshot(validUntil: validUntil, demotions: now < validUntil ? demotions.filter { now < $0.expiresAt }.map {
            BrokerHealthSnapshot.Entry(model: $0.model, roles: $0.roles, expiresAt: $0.expiresAt)
        } : [])
    }
}

extension BrokerHealthPayload {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(BrokerHealthInteger.self, forKey: .v).boundedInt
        typ = try c.decode(String.self, forKey: .typ)
        kid = try c.decode(String.self, forKey: .kid)
        let sequence = try c.decode(BrokerHealthInteger.self, forKey: .seq).value
        seq = sequence >= 0 && sequence <= Decimal(UInt64.max) ? NSDecimalNumber(decimal: sequence).uint64Value : 0
        issuedAt = try c.decode(Date.self, forKey: .issuedAt)
        validUntil = try c.decode(Date.self, forKey: .validUntil)
        demotions = try c.decode([BrokerHealthDemotion].self, forKey: .demotions)
        recent = try c.decodeIfPresent([BrokerHealthRecent].self, forKey: .recent)
        sources = try c.decodeIfPresent([BrokerHealthSource].self, forKey: .sources)
        attribution = try c.decodeIfPresent([String].self, forKey: .attribution)
    }
}

struct BrokerHealthDemotion: Codable, Sendable, Equatable {
    let model: String
    let roles: [String]
    let since: Date
    let expiresAt: Date
    let methods: [String]
    let reason: String
    enum CodingKeys: String, CodingKey { case model, roles, since, methods, reason; case expiresAt = "expires_at" }
}

struct BrokerHealthRecent: Codable, Sendable, Equatable {
    let model: String
    let endedAt: Date
    enum CodingKeys: String, CodingKey { case model; case endedAt = "ended_at" }
}

struct BrokerHealthSource: Codable, Sendable, Equatable {
    let id: String
    let state: String
    let lastFetchOk: Date?
    let newestDataDate: String?
    let staleLimitDays: Int
    var digest: String? = nil
    var seriesLen: Int? = nil
    enum CodingKeys: String, CodingKey {
        case id, state, digest
        case lastFetchOk = "last_fetch_ok", newestDataDate = "newest_data_date"
        case staleLimitDays = "stale_limit_days", seriesLen = "series_len"
    }
}

extension BrokerHealthSource {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decode(String.self, forKey: .state)
        lastFetchOk = try c.decodeIfPresent(Date.self, forKey: .lastFetchOk)
        newestDataDate = try c.decodeIfPresent(String.self, forKey: .newestDataDate)
        staleLimitDays = try c.decode(BrokerHealthInteger.self, forKey: .staleLimitDays).boundedInt
        digest = try c.decodeIfPresent(String.self, forKey: .digest)
        seriesLen = try c.decodeIfPresent(BrokerHealthInteger.self, forKey: .seriesLen)?.boundedInt
    }
}

struct BrokerHealthCheck: Codable, Sendable, Equatable {
    let at: Date
    let result: String
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(BrokerHealthDocument.formatTime(at), forKey: .at)
        try c.encode(result, forKey: .result)
    }
    enum CodingKeys: String, CodingKey { case at, result }
}

struct BrokerHealthStatus: Encodable, Sendable, Equatable {
    let present: Bool
    let useModelHealth: Bool
    let seq: UInt64?
    let issuedAt: Date?
    let validUntil: Date?
    let ageSeconds: Int?
    let expired: Bool?
    let lastCheck: BrokerHealthCheck?
    let demotions: [Demotion]
    let sources: [Source]
    let attribution: [String]?

    enum CodingKeys: String, CodingKey {
        case present, useModelHealth, seq, issuedAt, validUntil, ageSeconds, expired, lastCheck, demotions, sources, attribution
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(present, forKey: .present)
        try c.encode(useModelHealth, forKey: .useModelHealth)
        try c.encodeIfPresent(seq, forKey: .seq)
        try c.encodeIfPresent(issuedAt.map(BrokerHealthDocument.formatTime), forKey: .issuedAt)
        try c.encodeIfPresent(validUntil.map(BrokerHealthDocument.formatTime), forKey: .validUntil)
        try c.encodeIfPresent(ageSeconds, forKey: .ageSeconds)
        try c.encodeIfPresent(expired, forKey: .expired)
        try c.encodeIfPresent(lastCheck, forKey: .lastCheck)
        try c.encode(demotions, forKey: .demotions)
        try c.encode(sources, forKey: .sources)
        try c.encodeIfPresent(attribution, forKey: .attribution)
    }

    struct Demotion: Encodable, Sendable, Equatable {
        let model: String
        let roles: [String]
        let expiresAt: Date
        let methods: [String]
        enum CodingKeys: String, CodingKey { case model, roles, expiresAt, methods }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model, forKey: .model); try c.encode(roles, forKey: .roles)
            try c.encode(BrokerHealthDocument.formatTime(expiresAt), forKey: .expiresAt); try c.encode(methods, forKey: .methods)
        }
    }
    struct Source: Encodable, Sendable, Equatable {
        let id: String
        let state: String
        let lastFetchOk: Date?
        let newestDataDate: String?
        let staleLimitDays: Int
        enum CodingKeys: String, CodingKey { case id, state, lastFetchOk, newestDataDate, staleLimitDays }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(state, forKey: .state)
            try c.encodeIfPresent(lastFetchOk.map(BrokerHealthDocument.formatTime), forKey: .lastFetchOk)
            try c.encodeIfPresent(newestDataDate, forKey: .newestDataDate); try c.encode(staleLimitDays, forKey: .staleLimitDays)
        }
    }
}

struct BrokerHealthSnapshot: Codable, Sendable, Equatable {
    let validUntil: Date
    let demotions: [Entry]
    enum CodingKeys: String, CodingKey { case demotions; case validUntil = "valid_until" }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(BrokerHealthDocument.formatTime(validUntil), forKey: .validUntil)
        try c.encode(demotions, forKey: .demotions)
    }
    struct Entry: Codable, Sendable, Equatable {
        let model: String
        let roles: [String]
        let expiresAt: Date
        enum CodingKeys: String, CodingKey { case model, roles; case expiresAt = "expires_at" }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model, forKey: .model); try c.encode(roles, forKey: .roles)
            try c.encode(BrokerHealthDocument.formatTime(expiresAt), forKey: .expiresAt)
        }
    }
}
