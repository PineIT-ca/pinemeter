//
//  BrokerServiceProtocol.swift
//  Pinemeter
//

import Foundation

/// The broker's tool surface, as consumed by the MCP layer (D-08: pick,
/// status, down, up, refresh).
protocol BrokerServiceProtocol: Sendable {
    /// Picks a route/model for a task role.
    /// - Parameters:
    ///   - role: Task role, e.g. `planning` or `execution`.
    ///   - caller: Invoking harness id. `nil`/empty resolves to the default caller
    ///     and is echoed back in the decision.
    func pick(role: String, caller: String?) async throws -> BrokerDecision

    /// Server/oracle/cooldown/T3 status — labels, percentages and ISO
    /// timestamps only, never credential material (D-07).
    func status() async -> BrokerStatus

    /// Marks `target` unavailable until `now + minutes` (clamped 1...10080,
    /// default 60). `target` is a cooldown key: a full candidate id, an
    /// instance-resolved id, or a bare route.
    func down(target: String, minutes: Int?) async

    /// Restores `target` to immediate availability.
    func up(target: String) async

    /// Invokes the injected refresh handler (oracle poll) and re-probes T3
    /// liveness. The slow path is explicit — `pick` never triggers a poll.
    func refresh() async throws
}
