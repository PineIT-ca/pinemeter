//
//  BrokerSettings.swift
//  Pinemeter
//
//  Persisted broker configuration (D-04, D-07). Follows the AppSettings
//  decode-safety convention exactly: an explicit snake_case `CodingKeys`, a
//  `static let default`, a custom `init(from:)` that falls back per key, and
//  a full `encode(to:)`. Synthesized Codable is deliberately avoided.
//

import Foundation

/// Broker configuration: whether the loopback MCP server runs, which port it
/// binds to, and the routing policy it serves picks from.
struct BrokerSettings: Codable, Equatable, Sendable {
    /// The server is opt-in — `false` until the user turns it on (D-07).
    var isEnabled: Bool

    /// Loopback port the MCP server binds to.
    var port: Int

    /// Valid loopback port range (review WR-02), mirroring the Broker
    /// settings tab's `portFormatter` bounds (`BrokerSettingsTab.swift`).
    /// Ports below 1024 are typically privileged and ports above 65535
    /// don't exist.
    static let portRange: ClosedRange<Int> = 1024...65535

    private static func clampedPort(_ port: Int) -> Int {
        min(max(port, portRange.lowerBound), portRange.upperBound)
    }

    /// Routing policy. Defaults to the bundled seed (D-04): any pre-phase
    /// save or fresh install decodes with no `policy` key, which falls back
    /// to `BrokerPolicy.bundledDefault` below — the effective first-launch
    /// policy without any dedicated seeding step.
    var policy: BrokerPolicy

    static let `default` = BrokerSettings(
        isEnabled: false,
        port: 43117,
        policy: .bundledDefault
    )

    init(isEnabled: Bool, port: Int, policy: BrokerPolicy) {
        self.isEnabled = isEnabled
        self.port = BrokerSettings.clampedPort(port)
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case port
        case policy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrokerSettings.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        let decodedPort = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        port = BrokerSettings.clampedPort(decodedPort)
        policy = try container.decodeIfPresent(BrokerPolicy.self, forKey: .policy) ?? defaults.policy
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(port, forKey: .port)
        try container.encode(policy, forKey: .policy)
    }
}
