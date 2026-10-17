//
//  GoldenRecorder.swift
//  PinemeterTests
//
//  Recording wrappers around `BrokerEngine.decide` / `decideOverride`.
//
//  Every decision-producing test call site goes through these instead of
//  calling the engine directly, so the golden corpus is a byproduct of the
//  suite that already exists rather than a second, hand-maintained set of
//  cases that can drift from it.
//
//  Recording is opt-in: with no export directory configured these are pure
//  pass-throughs that return or rethrow exactly what the engine did, so an
//  ordinary `xcodebuild test` run behaves identically and never writes to the
//  working tree.
//

import Foundation
import XCTest
@testable import Pinemeter

/// Per-test call counters. Keyed by `XCTestCase.name` so each test numbers its
/// own calls from 1 and fixture names do not depend on execution order.
private enum GoldenCallCounter {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]

    static func next(for testName: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (counts[testName] ?? 0) + 1
        counts[testName] = next
        return next
    }
}

// Explicit child variants reuse selected injected worlds. The exporter regenerates
// them from Swift execution while preserving every default-world fixture byte.
private enum GoldenChildVariants {
    static let names: [String: String] = [
        "BrokerBackupOptionTests.test_backups_neverIncludeAStructurallyFilteredCandidate.1": "T3ChildContext.normal",
        "BrokerBackupOptionTests.test_backups_preferVerifiedOverUnverifiedOverGated.1": "T3ChildContext.codex-backup",
        "BrokerEngineTests.testHealthyLaneStillOutranksAPacedOneAndThePacedOneBecomesABackup.1": "T3ChildContext.backups",
        "BrokerEngineTests.test_ambiguousClaudeLabelLaneDoesNotDependOnAccountOrder.1": "T3ChildContext.degraded",
        "BrokerEngineTests.test_explicitAnyInstanceOverrideUsesHealthyBoundAccount.1": "T3ChildContext.override",
        "BrokerEngineTests.test_explicitAutoOverrideSkipsRoutesTheCallerCannotInvoke.1": "T3ChildContext.fable-override",
        "BrokerEngineTests.test_t3WithoutAReachableSignal_isUnavailableEvenWhenEverythingElseIsCapped.1": "T3ChildContext.unavailable",
        "BrokerEngineTests.test_winnersEffort_reachesBothTheDecisionAndTheInvocation.2": "T3ChildContext.effort",
    ]
}

extension XCTestCase {

    /// `BrokerEngine.decide` with corpus recording. Same parameter labels,
    /// same defaults, same throwing behaviour.
    @discardableResult
    func recordedDecide(
        role: String,
        caller: String?,
        policy: BrokerPolicy,
        oracle: OracleSnapshot?,
        cooldowns: [String: Date],
        now: Date,
        t3: [String: T3Liveness],
        demand: BrokerDemand? = nil,
        health: BrokerHealthSnapshot? = nil,
        local: BrokerLocalLoad? = nil,
        residency: BrokerResidency? = nil,
        executionContext: BrokerExecutionContext? = nil
    ) throws -> BrokerDecision {
        try record(
            role: role,
            caller: caller,
            overrideCandidate: nil,
            policy: policy,
            oracle: oracle,
            cooldowns: cooldowns,
            now: now,
            t3: t3,
            demand: demand,
            health: health, local: local, residency: residency, executionContext: executionContext
        ) {
            try BrokerEngine.decide(
                role: role,
                caller: caller,
                policy: policy,
                oracle: oracle,
                cooldowns: cooldowns,
                now: now,
                t3: t3,
                demand: demand,
                health: health, local: local, residency: residency, executionContext: executionContext
            )
        }
    }

    /// `BrokerEngine.decideOverride` with corpus recording.
    @discardableResult
    func recordedDecideOverride(
        role: String,
        caller: String?,
        overrideCandidate rawOverride: String,
        policy: BrokerPolicy,
        oracle: OracleSnapshot?,
        cooldowns: [String: Date],
        now: Date,
        t3: [String: T3Liveness],
        health: BrokerHealthSnapshot? = nil,
        local: BrokerLocalLoad? = nil,
        residency: BrokerResidency? = nil,
        executionContext: BrokerExecutionContext? = nil
    ) throws -> BrokerDecision {
        try record(
            role: role,
            caller: caller,
            overrideCandidate: rawOverride,
            policy: policy,
            oracle: oracle,
            cooldowns: cooldowns,
            now: now,
            t3: t3,
            health: health, local: local, residency: residency, executionContext: executionContext
        ) {
            try BrokerEngine.decideOverride(
                role: role,
                caller: caller,
                overrideCandidate: rawOverride,
                policy: policy,
                oracle: oracle,
                cooldowns: cooldowns,
                now: now,
                t3: t3, local: local, residency: residency, executionContext: executionContext
            )
        }
    }

    // MARK: - Recording

    private func record(
        role: String,
        caller: String?,
        overrideCandidate: String?,
        policy: BrokerPolicy,
        oracle: OracleSnapshot?,
        cooldowns: [String: Date],
        now: Date,
        t3: [String: T3Liveness],
        demand: BrokerDemand? = nil,
        health: BrokerHealthSnapshot? = nil,
        local: BrokerLocalLoad? = nil,
        residency: BrokerResidency? = nil,
        executionContext: BrokerExecutionContext? = nil,
        engine: () throws -> BrokerDecision
    ) throws -> BrokerDecision {
        guard let directory = GoldenFixture.exportDirectory() else {
            // Not exporting: stay out of the way entirely.
            return try engine()
        }

        let caseName = GoldenFixture.caseName(
            for: self, counter: GoldenCallCounter.next(for: name)
        )
        let input = GoldenInput(
            role: role,
            caller: caller,
            overrideCandidate: overrideCandidate,
            executionContext: executionContext,
            now: now,
            policy: policy,
            oracle: oracle,
            cooldowns: cooldowns,
            t3: t3,
            demand: demand,
            health: health, local: local, residency: residency
        )

        do {
            let decision = try engine()
            try writeFixture(
                caseName: caseName,
                directory: directory,
                input: input,
                payloadSuffix: "decision.json",
                payload: try GoldenFixture.canonicalEncoder().encode(decision)
            )
            if let childName = GoldenChildVariants.names[caseName] {
                let childInput = GoldenInput(
                    role: role, caller: caller, overrideCandidate: overrideCandidate,
                    executionContext: .t3Child, now: now, policy: policy, oracle: oracle,
                    cooldowns: cooldowns, t3: t3, demand: demand, health: health, local: local, residency: residency
                )
                let child = if let overrideCandidate {
                    try BrokerEngine.decideOverride(
                        role: role, caller: caller, overrideCandidate: overrideCandidate,
                        policy: policy, oracle: oracle, cooldowns: cooldowns, now: now,
                        t3: t3, local: local, residency: residency, executionContext: .t3Child
                    )
                } else {
                    try BrokerEngine.decide(
                        role: role, caller: caller, policy: policy, oracle: oracle,
                        cooldowns: cooldowns, now: now, t3: t3, demand: demand, health: health, local: local, residency: residency, executionContext: .t3Child
                    )
                }
                try writeFixture(
                    caseName: childName, directory: directory, input: childInput,
                    payloadSuffix: "decision.json",
                    payload: try GoldenFixture.canonicalEncoder().encode(child)
                )
            }
            return decision
        } catch {
            guard let fixture = GoldenErrorFixture(error) else {
                // Not a `BrokerError`: a harness failure, not engine
                // behaviour. Record nothing and let the test see it.
                throw error
            }
            try writeFixture(
                caseName: caseName,
                directory: directory,
                input: input,
                payloadSuffix: "error.json",
                payload: try GoldenFixture.canonicalEncoder().encode(fixture)
            )
            throw error
        }
    }

    private func writeFixture(
        caseName: String,
        directory: URL,
        input: GoldenInput,
        payloadSuffix: String,
        payload: Data
    ) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let inputData = try GoldenFixture.inputEncoder().encode(input)
        try inputData.write(
            to: directory.appendingPathComponent("\(caseName).input.json"), options: .atomic
        )
        // Compact, no trailing newline: these bytes ARE the expected output,
        // compared with `==` by both the Swift and the Go replay.
        try payload.write(
            to: directory.appendingPathComponent("\(caseName).\(payloadSuffix)"), options: .atomic
        )
    }
}
