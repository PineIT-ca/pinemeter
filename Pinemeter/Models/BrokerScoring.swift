import Foundation

/// Optional, portable estimates. Missing estimates never inherit bundled data.
struct BrokerScoring: Codable, Equatable, Sendable {
    var latency: [String: [String: Int]]
    var roles: [String: BrokerRoleScoring]

    init(latency: [String: [String: Int]] = [:], roles: [String: BrokerRoleScoring] = [:]) {
        self.latency = latency
        self.roles = roles
    }

    static let empty = BrokerScoring()
    static let defaultEffortKey = "_default"
    var isEmpty: Bool { latency.isEmpty && roles.isEmpty }
    static func effortKey(_ effort: BrokerEffort?) -> String { effort?.rawValue ?? defaultEffortKey }
    func role(_ resolvedRole: String) -> BrokerRoleScoring? { roles[resolvedRole] }

    func normalized() -> BrokerScoring {
        func valid(_ key: String) -> Bool {
            (1...128).contains(key.unicodeScalars.count)
                && BrokerPresetManifest.sanitize(key, maxScalars: 128) == key
        }
        func sorted<Value>(_ keys: Dictionary<String, Value>.Keys) -> [String] {
            keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        }
        func estimates(_ raw: [String: [String: Int]], models: Int, maximum: Int) -> [String: [String: Int]] {
            var result: [String: [String: Int]] = [:]
            for model in sorted(raw.keys) {
                guard result.count < models else { break }
                guard valid(model) else { continue }
                var efforts: [String: Int] = [:]
                for key in sorted(raw[model]!.keys) {
                    guard efforts.count < 8 else { break }
                    let value = raw[model]![key]!
                    guard key == Self.defaultEffortKey || BrokerEffort(rawValue: key) != nil,
                          (0...maximum).contains(value) else { continue }
                    efforts[key] = value
                }
                if !efforts.isEmpty { result[model] = efforts }
            }
            return result
        }
        func bounded(_ value: Int?, maximum: Int) -> Int? {
            value.flatMap { (0...maximum).contains($0) ? $0 : nil }
        }
        var result = BrokerScoring(latency: estimates(latency, models: 64, maximum: 86400))
        for role in sorted(roles.keys) {
            guard result.roles.count < 64 else { break }
            guard valid(role) else { continue }
            let row = roles[role]!
            result.roles[role] = BrokerRoleScoring(
                floor: bounded(row.floor, maximum: 10000),
                latencyLimit: bounded(row.latencyLimit, maximum: 86400),
                latencyWeight: bounded(row.latencyWeight, maximum: 100),
                quality: estimates(row.quality, models: 32, maximum: 10000))
        }
        return result
    }

    private enum CodingKeys: String, CodingKey { case latency, roles }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        latency = try c.decodeIfPresent([String: [String: Int]].self, forKey: .latency) ?? [:]
        roles = try c.decodeIfPresent([String: BrokerRoleScoring].self, forKey: .roles) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !latency.isEmpty { try c.encode(latency, forKey: .latency) }
        if !roles.isEmpty { try c.encode(roles, forKey: .roles) }
    }
}

struct BrokerRoleScoring: Codable, Equatable, Sendable {
    var floor: Int?
    var latencyLimit: Int?
    var latencyWeight: Int?
    var quality: [String: [String: Int]]

    init(floor: Int? = nil, latencyLimit: Int? = nil, latencyWeight: Int? = nil,
         quality: [String: [String: Int]] = [:]) {
        self.floor = floor
        self.latencyLimit = latencyLimit
        self.latencyWeight = latencyWeight
        self.quality = quality
    }
    private enum CodingKeys: String, CodingKey {
        case floor, quality
        case latencyLimit = "latency_limit"
        case latencyWeight = "latency_weight"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        floor = try c.decodeIfPresent(Int.self, forKey: .floor)
        latencyLimit = try c.decodeIfPresent(Int.self, forKey: .latencyLimit)
        latencyWeight = try c.decodeIfPresent(Int.self, forKey: .latencyWeight)
        quality = try c.decodeIfPresent([String: [String: Int]].self, forKey: .quality) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(floor, forKey: .floor)
        try c.encodeIfPresent(latencyLimit, forKey: .latencyLimit)
        try c.encodeIfPresent(latencyWeight, forKey: .latencyWeight)
        if !quality.isEmpty { try c.encode(quality, forKey: .quality) }
    }
}
