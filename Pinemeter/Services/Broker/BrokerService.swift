//
//  BrokerService.swift
//  Pinemeter
//
//  Actor that owns the broker's mutable world and answers tool calls by
//  delegating to the pure engine. Everything stateful and IO-shaped that
//  `BrokerEngine.decide` deliberately excludes lives here: cooldown
//  persistence, T3 liveness, the recent-picks ring buffer and the UI state
//  stream AppModel observes.
//

import Foundation
import os

actor BrokerService: BrokerServiceProtocol {
    /// Recent-picks ring buffer capacity (D-08).
    static let recentPicksCapacity = 50
    static let minimumRefreshInterval: TimeInterval = 10
    private static let logger = Logger(subsystem: "com.pinemeter", category: "BrokerService")

    /// The frozen engine signature, as a value so tests can inject a spy that
    /// asserts the exact world BrokerService assembles without depending on
    /// engine gate internals.
    typealias DecideFunction = @Sendable (
        _ role: String,
        _ caller: String?,
        _ policy: BrokerPolicy,
        _ oracle: OracleSnapshot?,
        _ cooldowns: [String: Date],
        _ now: Date,
        _ t3: [String: T3Liveness]
    ) throws -> BrokerDecision

    private var policy: BrokerPolicy
    private let cooldownStore: BrokerCooldownStore
    private let auditStore: BrokerAuditStore
    private let instructionCheckStore: InstructionCheckStore
    private let livenessChecker: any T3LivenessCheckerProtocol
    /// Stamped onto every instruction check this build grades, so the pane can
    /// tell a verdict produced by the running contract from one produced by an
    /// older build's grader.
    private let appVersion: String
    private var setupRevision: Int?
    private let now: @Sendable () -> Date
    private let idGenerator: @Sendable () -> String
    private let decide: DecideFunction

    /// Latest quota snapshot pushed in from the main actor. `nil` until the
    /// first refresh completes.
    private var oracle: OracleSnapshot?
    /// Reachability keyed by resolved T3 instance id. A missing key means
    /// unreachable: the t3 route fails closed.
    private var t3Liveness: [String: T3Liveness] = [:]
    private var livenessGeneration: UInt64 = 0

    /// Newest-first, capped at `recentPicksCapacity`.
    private var recentPicks: [RecentPick] = []

    private var uiState = BrokerUIState.initial
    private var uiStateContinuations: [UUID: AsyncStream<BrokerUIState>.Continuation] = [:]

    private var refreshHandler: (@Sendable () async throws -> Void)?
    private var lastRefreshAt: Date?

    init(
        policy: BrokerPolicy = .default,
        cooldownStore: BrokerCooldownStore = BrokerCooldownStore(),
        auditStore: BrokerAuditStore = BrokerAuditStore(),
        instructionCheckStore: InstructionCheckStore = InstructionCheckStore(),
        livenessChecker: any T3LivenessCheckerProtocol = T3LivenessChecker(),
        appVersion: String = BrokerMCPServer.appVersion,
        setupRevision: Int? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        decide: @escaping DecideFunction = BrokerEngine.decide
    ) {
        self.policy = policy
        self.cooldownStore = cooldownStore
        self.auditStore = auditStore
        self.instructionCheckStore = instructionCheckStore
        self.livenessChecker = livenessChecker
        self.appVersion = appVersion
        self.setupRevision = setupRevision
        self.now = now
        self.idGenerator = idGenerator
        self.decide = decide
    }

    // MARK: - Intake (pushed by AppModel, wired in 07-04)

    func updatePolicy(_ policy: BrokerPolicy) {
        self.policy = policy
        livenessGeneration &+= 1
        let previousLiveness = t3Liveness
        t3Liveness = policy.t3Instances.reduce(into: [:]) { filtered, instance in
            filtered[instance.id] = previousLiveness[instance.id]
                ?? T3Liveness(reachable: false, why: "not probed")
        }
        uiState.routeHealth = Self.routeHealth(from: t3Liveness)
        publishUIState()
    }

    func updateSetupRevision(_ revision: Int?) {
        setupRevision = revision
    }

    func updateOracleSnapshot(_ oracle: OracleSnapshot?) {
        self.oracle = oracle
        uiState.oracleFreshness = makeOracleFreshness()
        publishUIState()
    }

    func updateT3Liveness(_ liveness: [String: T3Liveness]) {
        livenessGeneration &+= 1
        self.t3Liveness = liveness
        uiState.routeHealth = Self.routeHealth(from: liveness)
        publishUIState()
    }

    /// Pushed by the loopback server's lifecycle (07-01/07-03 own the
    /// listener; the UI observes this seam in 07-04/07-05).
    func updateServerState(_ state: BrokerUIState.ServerState) {
        uiState.serverState = state
        publishUIState()
    }

    /// Sets the async closure `refresh` invokes for the oracle side of a
    /// refresh (quota re-poll). Wired to AppModel in 07-04. `refresh` invokes
    /// this exactly once per call and always re-probes T3 liveness itself,
    /// which needs no data AppModel owns.
    func setRefreshHandler(_ handler: @escaping @Sendable () async throws -> Void) {
        refreshHandler = handler
    }

    /// A continuous view of `BrokerUIState` for the UI to observe. Yields the
    /// current state immediately, then every subsequent update.
    func uiStateUpdates() -> AsyncStream<BrokerUIState> {
        AsyncStream { continuation in
            let id = UUID()
            uiStateContinuations[id] = continuation
            continuation.yield(uiState)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeUIStateContinuation(id) }
            }
        }
    }

    private func removeUIStateContinuation(_ id: UUID) {
        uiStateContinuations.removeValue(forKey: id)
    }

    private func publishUIState() {
        for continuation in uiStateContinuations.values {
            continuation.yield(uiState)
        }
    }

    // MARK: - Tools (D-08)

    func pick(role: String, caller: String?) async throws -> BrokerDecision {
        try await makePick(role: role, caller: caller, overrideCandidate: nil)
    }

    func pick(role: String, caller: String?, overrideCandidate: String) async throws -> BrokerDecision {
        try await makePick(role: role, caller: caller, overrideCandidate: overrideCandidate)
    }

    private func makePick(
        role: String,
        caller: String?,
        overrideCandidate: String?
    ) async throws -> BrokerDecision {
        var cooldowns = await cooldownStore.mergedSnapshot()
        var timestamp = now()
        let picked: BrokerDecision
        if let overrideCandidate {
            do {
                picked = try BrokerEngine.decideOverride(
                    role: role,
                    caller: caller,
                    overrideCandidate: overrideCandidate,
                    policy: policy,
                    oracle: oracle,
                    cooldowns: cooldowns,
                    now: timestamp,
                    t3: t3Liveness
                )
            } catch let error as BrokerError {
                guard case .overrideUnavailable = error else { throw error }
                let refreshed = try await refreshIfAllowed()
                cooldowns = await cooldownStore.mergedSnapshot()
                timestamp = now()
                do {
                    picked = try BrokerEngine.decideOverride(
                        role: role,
                        caller: caller,
                        overrideCandidate: overrideCandidate,
                        policy: policy,
                        oracle: oracle,
                        cooldowns: cooldowns,
                        now: timestamp,
                        t3: t3Liveness
                    )
                } catch BrokerError.overrideUnavailable(let candidate, let reasons, _) {
                    throw BrokerError.overrideUnavailable(
                        candidate: candidate,
                        reasons: reasons,
                        recoveryAttempted: refreshed
                    )
                }
            }
        } else {
            picked = try decide(role, caller, policy, oracle, cooldowns, timestamp, t3Liveness)
        }
        let decision = picked
            .attachingDecisionID(idGenerator())
        do {
            try await auditStore.append(decision: decision, timestamp: timestamp)
        } catch let error as BrokerAuditStoreError {
            auditPersistenceDidFail(category: Self.auditFailureCategory(error))
            throw error
        } catch {
            auditPersistenceDidFail(category: "write_failed")
            throw BrokerAuditStoreError.invalidRecord
        }
        uiState.auditPersistenceFailed = false
        recordPick(decision, timestamp: timestamp)
        if decision.degraded {
            Task { @MainActor in
                NotificationCenter.default.post(name: .brokerDegradedPick, object: decision)
            }
        }
        return decision
    }

    private func auditPersistenceDidFail(category: String) {
        Self.logger.error("Audit append failed: \(category, privacy: .public)")
        guard !uiState.auditPersistenceFailed else { return }
        uiState.auditPersistenceFailed = true
        publishUIState()
    }

    private static func auditFailureCategory(_ error: BrokerAuditStoreError) -> String {
        switch error {
        case .invalidDecisionID: "invalid_decision_id"
        case .duplicateDecisionID: "duplicate_decision_id"
        case .invalidRecord: "invalid_record"
        case .invalidLifecycleReport: "invalid_lifecycle_report"
        }
    }

    func status() async -> BrokerStatus {
        let cooldowns = await cooldownStore.mergedSnapshot()
        let cooldownEntries = cooldowns
            .map { BrokerStatus.CooldownEntry(key: $0.key, availableAt: $0.value) }
            .sorted { $0.key < $1.key }

        let running: Bool
        let port: UInt16?
        switch uiState.serverState {
        case .running(let boundPort):
            running = true
            port = boundPort
        default:
            running = false
            port = nil
        }

        return BrokerStatus(
            running: running,
            port: port,
            oracle: makeOracleFreshness(),
            cooldowns: cooldownEntries,
            t3: Self.routeHealth(from: t3Liveness).sorted { $0.instanceId < $1.instanceId },
            roles: policy.roles.keys.sorted(),
            recentPicksCount: recentPicks.count
        )
    }

    func down(target: String, minutes: Int?) async throws {
        guard target.unicodeScalars.count <= BrokerCooldownStore.maxTargetScalars,
              !target.contains(BrokerCandidate.anyInstance),
              validCooldownTargets().contains(target) else {
            throw BrokerCooldownError.invalidTarget
        }
        try await cooldownStore.down(target: target, minutes: minutes)
    }

    func up(target: String) async throws {
        guard target.unicodeScalars.count <= BrokerCooldownStore.maxTargetScalars,
              !target.contains(BrokerCandidate.anyInstance),
              validCooldownTargets().contains(target) else {
            throw BrokerCooldownError.invalidTarget
        }
        try await cooldownStore.up(target: target)
    }

    func resetCooldowns() async throws {
        try await cooldownStore.reset()
    }

    func refresh() async throws {
        _ = try await refreshIfAllowed()
    }

    private func refreshIfAllowed() async throws -> Bool {
        let timestamp = now()
        guard lastRefreshAt.map({ timestamp.timeIntervalSince($0) >= Self.minimumRefreshInterval }) ?? true else {
            return false
        }
        lastRefreshAt = timestamp
        _ = await refreshT3Liveness()
        if let refreshHandler {
            try await refreshHandler()
        }
        return true
    }

    func refreshT3Liveness() async -> [String: T3Liveness] {
        livenessGeneration &+= 1
        let generation = livenessGeneration
        let liveness = await livenessChecker.checkLiveness(instances: policy.t3Instances)
        if generation == livenessGeneration {
            t3Liveness = liveness
            uiState.routeHealth = Self.routeHealth(from: liveness)
            publishUIState()
        }
        return t3Liveness
    }

    func t3LivenessSnapshot() async -> [String: T3Liveness] { t3Liveness }

    func reportLifecycle(_ report: BrokerLifecycleReport) async throws -> BrokerLifecycleResult {
        try await auditStore.reportLifecycle(report)
    }

    func recordInstructionCheck(
        report: InstructionAuditReport,
        runID: String?,
        caller: String?
    ) async {
        let timestamp = now()
        await instructionCheckStore.record(
            report: report,
            runID: runID,
            caller: caller,
            gradedBy: appVersion,
            setupRevision: setupRevision,
            at: timestamp
        )
        uiState.lastInstructionCheckAt = timestamp
        publishUIState()
    }

    /// The last check this machine ran, for the Instructions pane.
    func latestInstructionCheck() async -> InstructionCheck? {
        await instructionCheckStore.latest()
    }

    private func validCooldownTargets() -> Set<String> {
        let timestamp = now()
        var targets = Set(policy.roles.values
            .flatMap {
                BrokerEngine.expandingModelChoices($0, policy: policy, oracle: oracle, now: timestamp)
            }
            .flatMap { BrokerEngine.cooldownKeys(for: $0, policy: policy) }
            .filter { !$0.contains(BrokerCandidate.anyInstance) })
        if !policy.t3Instances.isEmpty { targets.insert(BrokerPolicy.Route.t3.rawValue) }
        return targets
    }

    // MARK: - Recent picks

    private func recordPick(_ decision: BrokerDecision, timestamp: Date) {
        let entry = RecentPick(
            timestamp: timestamp,
            role: decision.role,
            caller: decision.caller,
            candidate: decision.model,
            route: decision.route.rawValue,
            degraded: decision.degraded,
            reason: decision.reason
        )
        recentPicks.insert(entry, at: 0)
        if recentPicks.count > Self.recentPicksCapacity {
            recentPicks.removeLast(recentPicks.count - Self.recentPicksCapacity)
        }
        uiState.lastPickSummary = "\(decision.role) \u{2192} \(decision.model)"
        uiState.lastPickDegraded = decision.degraded
        publishUIState()
    }

    /// Test-only accessor for the ring buffer contents (newest-first).
    var recentPicksSnapshot: [RecentPick] { recentPicks }

    // MARK: - Oracle freshness

    private func makeOracleFreshness() -> BrokerStatus.OracleFreshness {
        guard let oracle else {
            return BrokerStatus.OracleFreshness(present: false, stale: false, ageSeconds: nil, accounts: [])
        }
        let ageSeconds = oracle.newestDataAt.flatMap { BrokerFreshness.age(since: $0, now: now()) }
        let stale = ageSeconds.map { $0 > policy.thresholds.stalenessSeconds } ?? true
        let accounts = oracle.accounts.map {
            BrokerStatus.AccountFreshness(id: $0.id, label: $0.label, state: $0.state.rawValue)
        }
        return BrokerStatus.OracleFreshness(
            present: true,
            stale: stale,
            ageSeconds: ageSeconds,
            accounts: accounts
        )
    }

    private static func routeHealth(from liveness: [String: T3Liveness]) -> [BrokerStatus.RouteHealth] {
        liveness.map { key, value in
            BrokerStatus.RouteHealth(instanceId: key, reachable: value.reachable, why: value.why)
        }
    }
}

extension Notification.Name {
    static let brokerDegradedPick = Notification.Name("brokerDegradedPick")
}

/// One entry of the recent-picks ring buffer (D-08). Labels/percentages/ids
/// only — never credential material.
struct RecentPick: Sendable, Equatable {
    let timestamp: Date
    let role: String
    let caller: String
    let candidate: String
    let route: String
    let degraded: Bool
    let reason: String
}

/// Snapshot returned by the `status` tool. Labels, percentages, ISO timestamps
/// and candidate/instance ids only — never credential material (D-07).
struct BrokerStatus: Sendable, Equatable, Encodable {
    struct AccountFreshness: Sendable, Equatable, Encodable {
        let id: String
        let label: String
        let state: String
    }

    struct OracleFreshness: Sendable, Equatable, Encodable {
        let present: Bool
        let stale: Bool
        let ageSeconds: Double?
        let accounts: [AccountFreshness]
    }

    struct CooldownEntry: Sendable, Equatable, Encodable {
        let key: String
        let availableAt: Date
    }

    struct RouteHealth: Sendable, Equatable, Encodable {
        let instanceId: String
        let reachable: Bool
        let why: String
    }

    let running: Bool
    let port: UInt16?
    let oracle: OracleFreshness
    let cooldowns: [CooldownEntry]
    let t3: [RouteHealth]
    let roles: [String]
    let recentPicksCount: Int
}

extension BrokerStatus {
    /// The status JSON returned in the `status` tool result. Slashes stay
    /// unescaped so candidate ids read normally, matching `BrokerDecision`.
    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

/// UI-facing broker state, published to AppModel/07-05 via `uiStateUpdates()`.
struct BrokerUIState: Sendable, Equatable {
    enum ServerState: Sendable, Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(message: String)
    }

    var serverState: ServerState
    var lastPickSummary: String?
    var lastPickDegraded: Bool
    var auditPersistenceFailed: Bool = false
    var routeHealth: [BrokerStatus.RouteHealth]
    var oracleFreshness: BrokerStatus.OracleFreshness
    /// When the broker last recorded an instruction check. The record itself
    /// stays in `InstructionCheckStore`; this stamp only tells an open
    /// Instructions pane to reload it, so a check that lands while the pane
    /// is visible shows up without reopening the tab.
    var lastInstructionCheckAt: Date? = nil

    static let initial = BrokerUIState(
        serverState: .stopped,
        lastPickSummary: nil,
        lastPickDegraded: false,
        routeHealth: [],
        oracleFreshness: BrokerStatus.OracleFreshness(
            present: false, stale: false, ageSeconds: nil, accounts: []
        )
    )
}
