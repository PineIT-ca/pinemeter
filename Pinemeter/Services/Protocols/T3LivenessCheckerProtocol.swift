//
//  T3LivenessCheckerProtocol.swift
//  Pinemeter
//

import Foundation

/// Probes whether the local T3 desktop app is reachable, per registered
/// provider instance. Fails closed: a missing/invalid pointer file means
/// unreachable with no HTTP attempted (D-03).
protocol T3LivenessCheckerProtocol: Sendable {
    /// Probes reachability for every instance in `instances`, keyed by
    /// instance id (`T3InstanceConfig.id`) — the same keying `BrokerEngine.decide`
    /// reads via `policy.resolvedInstance(for:)`. Probes are deduped per
    /// distinct resolved base URL and the result is fanned out to every
    /// instance sharing it.
    func checkLiveness(instances: [T3InstanceConfig]) async -> [String: T3Liveness]
}
