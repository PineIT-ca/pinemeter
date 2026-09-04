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

    /// Picks one exact configured candidate after an explicit operator instruction.
    func pick(role: String, caller: String?, overrideCandidate: String) async throws -> BrokerDecision

    /// Server/oracle/cooldown/T3 status — labels, percentages and ISO
    /// timestamps only, never credential material (D-07).
    func status() async -> BrokerStatus

    /// Marks `target` unavailable until `now + minutes` (clamped 1...10080,
    /// default 60). `target` is a cooldown key: a full candidate id, an
    /// instance-resolved id, or a bare route.
    func down(target: String, minutes: Int?) async throws

    /// Restores `target` to immediate availability.
    func up(target: String) async throws

    /// Clears all persisted cooldowns so every path is reconsidered.
    func resetCooldowns() async throws

    /// Invokes the injected refresh handler (oracle poll) and re-probes T3
    /// liveness. The slow path is explicit — `pick` never triggers a poll.
    func refresh() async throws

    /// Attaches one validated started or terminal outcome to a durable decision.
    func reportLifecycle(_ report: BrokerLifecycleReport) async throws -> BrokerLifecycleResult

    /// Keeps the verdict of one graded `audit` call, so the Instructions pane
    /// can show when this machine was last checked and by whom. Paths,
    /// verdicts and finding text only; the graded content is already gone.
    func recordInstructionCheck(
        report: InstructionAuditReport,
        runID: String?,
        caller: String?
    ) async
}

extension BrokerServiceProtocol {
    func pick(role: String, caller: String?, overrideCandidate: String) async throws -> BrokerDecision {
        throw BrokerError.configError("human override is unsupported by this broker")
    }

    func reportLifecycle(_ report: BrokerLifecycleReport) async throws -> BrokerLifecycleResult {
        .unknownDecision
    }

    func resetCooldowns() async throws {
        for cooldown in await status().cooldowns {
            try await up(target: cooldown.key)
        }
    }

    func recordInstructionCheck(
        report: InstructionAuditReport,
        runID: String?,
        caller: String?
    ) async {}
}
