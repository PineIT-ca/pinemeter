import Foundation

enum BrokerResidency: String, Codable, Sendable {
    case controlled, vendor
}

/// An operator declaration stored on this machine, never in portable rules.
struct BrokerLocalRoute: Codable, Equatable, Sendable {
    /// Session identity survives edits; it is never persisted or compared as policy data.
    let rowKey = UUID()
    var candidate: String
    var host: String
    var probeURL: String
    var preset: String
    var residency: BrokerResidency?
    var enabled: Bool = false
    var roles: [String] = []
    var baseEffort: BrokerEffort = .high
    var quality: [String: Int] = [:]

    static let allowedRoles = ["explore", "verification", "execution"]
    static let forbiddenRoles = ["review", "legal-review", "planning", "design", "research", "heavy"]
    static let maxRoutes = 8
    static let maxHosts = 4

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.candidate == rhs.candidate && lhs.host == rhs.host && lhs.probeURL == rhs.probeURL
            && lhs.preset == rhs.preset && lhs.residency == rhs.residency && lhs.enabled == rhs.enabled
            && lhs.roles == rhs.roles && lhs.baseEffort == rhs.baseEffort && lhs.quality == rhs.quality
    }

    private enum CodingKeys: String, CodingKey {
        case candidate, host, preset, residency, enabled, roles, quality
        case probeURL = "probe_url"
        case baseEffort = "base_effort"
    }

    init(candidate: String, host: String, probeURL: String, preset: String,
         residency: BrokerResidency? = nil, enabled: Bool = false,
         roles: [String] = [], baseEffort: BrokerEffort = .high, quality: [String: Int] = [:]) {
        self.candidate = candidate
        self.host = host
        self.probeURL = probeURL
        self.preset = preset
        self.residency = residency
        self.enabled = enabled
        self.roles = roles
        self.baseEffort = baseEffort
        self.quality = quality
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        candidate = try c.decode(String.self, forKey: .candidate)
        host = try c.decode(String.self, forKey: .host)
        probeURL = try c.decode(String.self, forKey: .probeURL)
        preset = try c.decode(String.self, forKey: .preset)
        residency = (try? c.decode(BrokerResidency.self, forKey: .residency)) == .controlled ? .controlled : nil
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        roles = ((try? c.decode([LocalRouteValue<String>].self, forKey: .roles)) ?? []).compactMap(\.value)
        baseEffort = (try? c.decode(BrokerEffort.self, forKey: .baseEffort)) ?? .high
        quality = ((try? c.decode([String: LocalRouteValue<Int>].self, forKey: .quality)) ?? [:]).compactMapValues(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(candidate, forKey: .candidate)
        try c.encode(host, forKey: .host)
        try c.encode(probeURL, forKey: .probeURL)
        try c.encode(preset, forKey: .preset)
        try c.encodeIfPresent(residency, forKey: .residency)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(roles, forKey: .roles)
        try c.encode(baseEffort, forKey: .baseEffort)
        if !quality.isEmpty { try c.encode(quality, forKey: .quality) }
    }

    static func normalized(_ raw: [BrokerLocalRoute]) -> [BrokerLocalRoute] {
        var result: [BrokerLocalRoute] = []
        var candidates: Set<String> = []
        var hosts: [String: String] = [:]
        for var route in raw {
            guard result.count < maxRoutes,
                  let candidate = BrokerCandidate(id: route.candidate), candidate.route == .t3,
                  let instance = candidate.instance, T3InstanceConfig.isValidId(instance),
                  candidate.model != "default", T3InstanceConfig.isValidModelSlug(candidate.model),
                  T3InstanceConfig.isValidIdentifier(route.host, maxLength: 64),
                  isValidProbeURL(route.probeURL),
                  (1...128).contains(route.preset.unicodeScalars.count),
                  T3InstanceConfig.isValidIdentifier(route.preset.replacingOccurrences(of: ":", with: "_"), maxLength: 128),
                  !candidates.contains(route.candidate) else { continue }
            let url = route.probeURL.hasSuffix("/") ? String(route.probeURL.dropLast()) : route.probeURL
            if let previous = hosts[route.host] {
                guard previous == url else { continue }
            } else {
                guard hosts.count < maxHosts else { continue }
            }
            var seen: Set<String> = []
            route.roles = route.roles.filter { allowedRoles.contains($0) && seen.insert($0).inserted }
            route.quality = route.quality.filter { ["low", "medium", "high"].contains($0.key) && (0...1000).contains($0.value) }
            if route.residency != .controlled { route.residency = nil }
            if ![BrokerEffort.low, .medium, .high].contains(route.baseEffort) { route.baseEffort = .high }
            route.probeURL = url
            candidates.insert(route.candidate)
            hosts[route.host] = url
            result.append(route)
        }
        return result
    }

    static func isValidProbeURL(_ raw: String) -> Bool {
        guard raw.unicodeScalars.count <= 256,
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !raw.contains("?"), !raw.contains("#"), !raw.contains("\\"),
              let url = URLComponents(string: raw), ["http", "https"].contains(url.scheme),
              let host = url.host, !host.isEmpty, let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil,
              url.percentEncodedPath.isEmpty || url.percentEncodedPath == "/" else { return false }
        return true
    }

    static func normalizedResidencyRoles(_ raw: [String: BrokerResidency]) -> [String: BrokerResidency] {
        var result: [String: BrokerResidency] = [:]
        for role in raw.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            guard result.count < 64, raw[role] == .controlled,
                  (1...128).contains(role.unicodeScalars.count),
                  BrokerPresetManifest.sanitize(role, maxScalars: 128) == role else { continue }
            result[role] = .controlled
        }
        return result
    }
}

/// A malformed sibling must never discard an otherwise valid declaration.
struct LocalRouteValue<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}
