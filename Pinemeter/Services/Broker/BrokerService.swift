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

    /// The demand-aware engine signature, as a value so tests can inject a spy that
    /// asserts the exact world BrokerService assembles without depending on
    /// engine gate internals.
    typealias DecideFunction = @Sendable (
        _ role: String,
        _ caller: String?,
        _ policy: BrokerPolicy,
        _ oracle: OracleSnapshot?,
        _ cooldowns: [String: Date],
        _ now: Date,
        _ t3: [String: T3Liveness],
        _ demand: BrokerDemand?,
        _ health: BrokerHealthSnapshot?,
        _ local: BrokerLocalLoad?,
        _ residency: BrokerResidency?,
        _ executionContext: BrokerExecutionContext?
    ) throws -> BrokerDecision

    private var policy: BrokerPolicy
    private let cooldownStore: BrokerCooldownStore
    private let auditStore: BrokerAuditStore
    private let outcomeStore: BrokerOutcomeStore
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
    private var modelHealth: BrokerHealthState?
    private var localLoad: BrokerLocalLoad?
    private var localPicks: [(candidate: String, at: Date)] = []
    private var localRefreshHandler: (@Sendable () async -> Void)?
    /// Reachability keyed by resolved T3 instance id. A missing key means
    /// unreachable: the t3 route fails closed.
    private var t3Liveness: [String: T3Liveness] = [:]
    private var livenessGeneration: UInt64 = 0

    /// Newest-first, capped at `recentPicksCapacity`.
    private var recentPicks: [RecentPick] = []

    private var uiState = BrokerUIState.initial
    private var uiStateContinuations: [UUID: AsyncStream<BrokerUIState>.Continuation] = [:]

    private var refreshHandler: (@Sendable () async throws -> Void)?
    private var successfulCooldownMutationHandler: (@Sendable () -> Void)?
    private var lastRefreshAt: Date?

    init(
        policy: BrokerPolicy = .default,
        cooldownStore: BrokerCooldownStore = BrokerCooldownStore(),
        auditStore: BrokerAuditStore = BrokerAuditStore(),
        outcomeStore: BrokerOutcomeStore = BrokerOutcomeStore(),
        instructionCheckStore: InstructionCheckStore = InstructionCheckStore(),
        livenessChecker: any T3LivenessCheckerProtocol = T3LivenessChecker(),
        appVersion: String = BrokerMCPServer.appVersion,
        setupRevision: Int? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        decide: @escaping DecideFunction = {
            try BrokerEngine.decide(role: $0, caller: $1, policy: $2, oracle: $3,
                                    cooldowns: $4, now: $5, t3: $6, demand: $7, health: $8, local: $9, residency: $10, executionContext: $11)
        }
    ) {
        self.policy = policy
        self.cooldownStore = cooldownStore
        self.auditStore = auditStore
        self.outcomeStore = outcomeStore
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
        if self.policy.localRoutes != policy.localRoutes { localLoad = nil }
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

    func setModelHealth(_ state: BrokerHealthState) async {
        modelHealth = state
    }

    func setLocalLoad(_ load: BrokerLocalLoad) async {
        localLoad = load
    }

    func setLocalRefreshHandler(_ handler: @escaping @Sendable () async -> Void) async {
        localRefreshHandler = handler
    }

    private func localSnapshot() -> BrokerLocalLoad? {
        guard var load = localLoad else { return nil }
        for index in load.hosts.indices {
            let ids = Set(policy.localRoutes.filter { $0.host == load.hosts[index].host }.map(\.candidate))
            load.hosts[index].pending = localPicks.filter {
                $0.at > load.hosts[index].observedAt && ids.contains($0.candidate)
            }.count
        }
        return load
    }

    func localRouteRows(now: Date, brokerEnabled: Bool = true) async -> [BrokerLocalRouteRow] {
        let load = localSnapshot()
        return policy.localRoutes.map {
            BrokerLocalRouteRow(route: $0, load: load, now: now, brokerEnabled: brokerEnabled)
        }
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

    func setSuccessfulCooldownMutationHandler(_ handler: (@Sendable () -> Void)?) {
        successfulCooldownMutationHandler = handler
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

    func pick(role: String, caller: String?, residency: BrokerResidency? = nil) async throws -> BrokerDecision {
        try await makePick(role: role, caller: caller, overrideCandidate: nil, residency: residency)
    }

    func pickForT3(role: String, caller: String?) async throws -> BrokerDecision {
        try await makePick(role: role, caller: caller, overrideCandidate: nil, residency: nil, t3Only: true)
    }

    func pick(role: String, caller: String?, overrideCandidate: String, residency: BrokerResidency? = nil) async throws -> BrokerDecision {
        try await makePick(role: role, caller: caller, overrideCandidate: overrideCandidate, residency: residency)
    }

    func pick(
        role: String, caller: String?, overrideCandidate: String?,
        executionContext: BrokerExecutionContext, residency: BrokerResidency? = nil
    ) async throws -> BrokerDecision {
        try await makePick(role: role, caller: caller, overrideCandidate: overrideCandidate, residency: residency, executionContext: executionContext)
    }

    private func makePick(
        role: String,
        caller: String?,
        overrideCandidate: String?,
        residency: BrokerResidency?,
        executionContext: BrokerExecutionContext? = nil,
        t3Only: Bool = false
    ) async throws -> BrokerDecision {
        // Rebuild after each suspension so policy updates still apply to retries.
        var requestPolicy: BrokerPolicy {
            guard t3Only else { return policy }
            var limited = policy
            let resolvedCaller = BrokerPolicy.resolveCaller(caller)
            if limited.callers.isEmpty {
                limited.callers[resolvedCaller] = BrokerCallerPolicy(routes: [.t3])
            } else if var rules = limited.callers[resolvedCaller] {
                rules.routes = rules.routes.filter { $0 == .t3 }
                limited.callers[resolvedCaller] = rules
            }
            return limited
        }
        var cooldowns = await cooldownStore.mergedSnapshot()
        var timestamp = now()
        var picked: BrokerDecision
        if let overrideCandidate {
            do {
                picked = try BrokerEngine.decideOverride(
                    role: role,
                    caller: caller,
                    overrideCandidate: overrideCandidate,
                    policy: requestPolicy,
                    oracle: oracle,
                    cooldowns: cooldowns,
                    now: timestamp,
                    t3: t3Liveness,
                    local: localSnapshot(),
                    residency: residency, executionContext: executionContext
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
                        policy: requestPolicy,
                        oracle: oracle,
                        cooldowns: cooldowns,
                        now: timestamp,
                        t3: t3Liveness,
                        local: localSnapshot(),
                        residency: residency, executionContext: executionContext
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
            do {
                let demand = await demandSnapshot(now: timestamp)
                picked = try decide(role, caller, requestPolicy, oracle, cooldowns, timestamp, t3Liveness, demand, modelHealth?.snapshot(now: timestamp), localSnapshot(), residency, executionContext)
            } catch let error as BrokerError {
                // Exhaustion is the only pick failure re-polling can fix: a
                // snapshot that has gone stale can already have rolled over
                // into a new quota window. An unknown role or a malformed
                // caller is the caller's own input and surfaces unchanged, so
                // neither costs a refresh.
                guard case .noHeadroom = error else { throw error }
                _ = try? await refreshIfAllowed()
                cooldowns = await cooldownStore.mergedSnapshot()
                timestamp = now()
                do {
                    let demand = await demandSnapshot(now: timestamp)
                    picked = try decide(role, caller, requestPolicy, oracle, cooldowns, timestamp, t3Liveness, demand, modelHealth?.snapshot(now: timestamp), localSnapshot(), residency, executionContext)
                } catch {
                    // Blocked for real, and only now: recording before the
                    // retry would file a phantom block for a pick that healed
                    // itself. One refresh per pick, so this cannot loop.
                    await recordBlock(error, role: role, caller: caller, timestamp: timestamp)
                    throw error
                }
            }
        }
        if picked.retryable == true,
           (try? await refreshIfAllowed()) == true {
            cooldowns = await cooldownStore.mergedSnapshot()
            timestamp = now()
            let demand = await demandSnapshot(now: timestamp)
            if let repaired = try? decide(
                role, caller, requestPolicy, oracle, cooldowns, timestamp, t3Liveness, demand, modelHealth?.snapshot(now: timestamp), localSnapshot(), residency, executionContext
            ) {
                picked = repaired
            }
        }
        let decision = picked
            .attachingDecisionID(idGenerator())
        let record: BrokerAuditRecord
        do {
            record = try await auditStore.append(decision: decision, timestamp: timestamp)
        } catch let error as BrokerAuditStoreError {
            auditPersistenceDidFail(category: Self.auditFailureCategory(error))
            throw error
        } catch {
            auditPersistenceDidFail(category: "write_failed")
            throw BrokerAuditStoreError.invalidRecord
        }
        do { try await outcomeStore.notePick(record) }
        catch { Self.logger.error("outcome_write_failed") }
        uiState.auditPersistenceFailed = false
        recordPick(decision, timestamp: timestamp)
        if decision.degraded {
            Task { @MainActor in
                NotificationCenter.default.post(name: .brokerDegradedPick, object: decision)
            }
        }
        return decision
    }

    /// Persists a pick that produced no decision, so a blocked caller still
    /// leaves something to reconstruct the incident from: which candidates
    /// were rejected, why each one was, and the quota snapshot behind it.
    ///
    /// Deliberately non-throwing. The caller is already being handed the pick
    /// error, and swapping it for an audit error would take away the one
    /// message that says why the pick failed. A failed write is logged and
    /// raised in the UI exactly as it is on the decision path — it just never
    /// changes what the caller is told.
    private func recordBlock(_ error: Error, role: String, caller: String?, timestamp: Date) async {
        guard let brokerError = error as? BrokerError,
              case .noHeadroom(_, let candidatesTried, let oracleBlock) = brokerError else { return }
        do {
            try await auditStore.append(block: BrokerAuditBlock(
                timestamp: timestamp,
                role: role,
                caller: BrokerPolicy.resolveCaller(caller),
                message: brokerError.errorDescription ?? "Broker error",
                candidatesTried: candidatesTried,
                oracle: oracleBlock
            ))
        } catch {
            auditPersistenceDidFail(category: "block_write_failed")
        }
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

    private func demandSnapshot(now: Date) async -> BrokerDemand {
        let records = await auditStore.recordsSnapshot
        let rollup = await outcomeStore.snapshot()
        let failed = await outcomeStore.loadFailed
        return BrokerDemandForecast.summarize(
            policy: policy, oracle: oracle,
            records: BrokerDemandForecast.ledgerRecords(from: records),
            days: BrokerDemandForecast.ledgerDays(from: rollup),
            rollupLoadFailed: failed, now: now
        )
    }

    /// The Routing pane's "Quality and order" section (SCORE-04, SC5):
    /// assembles the same policy, oracle and demand snapshots `pick` uses
    /// and scores the role through the identical engine call `decide` walks
    /// (`BrokerScoringEngine.scoredRole`), so the view never ranks anything
    /// itself. `nil` on an unknown role or an engine error.
    func scoreSnapshot(role: String) async -> BrokerRoleScoreSnapshot? {
        let timestamp = now()
        let demand = await demandSnapshot(now: timestamp)
        guard let scored = try? BrokerScoringEngine.scoredRole(
            role: role, policy: policy, oracle: oracle, demand: demand, now: timestamp, local: localSnapshot()
        ) else { return nil }
        let useModelHealth = policy.thresholds.useModelHealth
        let status = (modelHealth ?? BrokerHealthState()).status(now: timestamp, useModelHealth: useModelHealth)

        // Repeat the candidate expansion and ranking `decide` feeds to the
        // demotion partition, then apply that exact partition to the scored
        // order so the view shows what `pick` walks (T-29-22).
        let chain = policy.roles[scored.role] ?? []
        let initial = BrokerEngine.rankingEquivalentCandidatesByHeadroom(
            BrokerEngine.expandingModelChoices(chain, policy: policy, oracle: oracle, now: timestamp),
            policy: policy, oracle: oracle, now: timestamp
        )
        let injection = BrokerLocalRouting.inject(initial, role: scored.role, policy: policy)
        let ranked = injection.candidates
        let policy = injection.policy
        var byId: [String: [BrokerCandidate]] = [:]
        for candidate in ranked { byId[candidate.id, default: []].append(candidate) }
        let scoredOrder: [BrokerCandidate] = scored.rows.compactMap {
            byId[$0.candidate]?.isEmpty == false ? byId[$0.candidate]!.removeFirst() : nil
        }
        let partition = BrokerDemotion.apply(
            scoredOrder, unpriced: ranked, health: modelHealth?.snapshot(now: timestamp),
            role: scored.role, policy: policy, oracle: oracle, now: timestamp
        )
        let health = BrokerRoleHealthSnapshot(
            status: status, resolvedRole: scored.role, policy: policy,
            skipped: partition.skipped, now: timestamp
        )
        var snapshot = BrokerRoleScoreSnapshot(scored: scored, policy: policy, health: health)
        if partition.applied {
            // A route moved exactly when a non-demoted route follows it.
            let demotedModels = Set(health.demotions.map(\.model))
            var movedIds = Set<String>()
            for (index, candidate) in scoredOrder.enumerated() where demotedModels.contains(candidate.model) {
                if scoredOrder[(index + 1)...].contains(where: { !demotedModels.contains($0.model) }) {
                    movedIds.insert(candidate.id)
                }
            }
            snapshot.applyDemotionPartition(order: partition.order.map(\.id), demotedIds: movedIds)
        }
        return snapshot
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

        let timestamp = now()
        let demand = await demandSnapshot(now: timestamp)
        let pricing = BrokerPricingStatus(
            enabled: policy.thresholds.preferExpiringQuota,
            historyDays: demand.historyDays, historySufficient: demand.historySufficient,
            roles: Array(demand.roles.keys.sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }.prefix(32)).map {
                .init(role: $0, decisionsPerHourMilli: demand.roles[$0]!)
            },
            pools: Array(BrokerPoolPricing.poolPrices(
                policy: policy, oracle: oracle, demand: demand, now: timestamp
            ).prefix(32))
        )
        return BrokerStatus(
            running: running,
            port: port,
            oracle: makeOracleFreshness(),
            cooldowns: cooldownEntries,
            t3: Self.routeHealth(from: t3Liveness).sorted { $0.instanceId < $1.instanceId },
            roles: policy.roles.keys.sorted(),
            recentPicksCount: recentPicks.count,
            pricing: pricing,
            residency: BrokerResidencyStatus(supported: true, roles: policy.residencyRoles),
            health: modelHealth?.status(now: timestamp, useModelHealth: policy.thresholds.useModelHealth),
            local: policy.localRoutes.isEmpty ? nil : BrokerLocalStatus(routes: policy.localRoutes, load: localSnapshot(), now: timestamp)
        )
    }

    func down(target: String, minutes: Int?) async throws {
        guard target.unicodeScalars.count <= BrokerCooldownStore.maxTargetScalars,
              !target.contains(BrokerCandidate.anyInstance),
              validCooldownTargets().contains(target) else {
            throw BrokerCooldownError.invalidTarget
        }
        try await cooldownStore.down(target: target, minutes: minutes)
        successfulCooldownMutationHandler?()
    }

    func down(target: String, until: Date) async throws -> Date {
        guard target.unicodeScalars.count <= BrokerCooldownStore.maxTargetScalars,
              !target.contains(BrokerCandidate.anyInstance),
              validCooldownTargets().contains(target) else {
            throw BrokerCooldownError.invalidTarget
        }
        let availableAt = try await cooldownStore.down(target: target, until: until)
        successfulCooldownMutationHandler?()
        return availableAt
    }

    func up(target: String) async throws {
        guard target.unicodeScalars.count <= BrokerCooldownStore.maxTargetScalars,
              !target.contains(BrokerCandidate.anyInstance),
              validCooldownTargets().contains(target) else {
            throw BrokerCooldownError.invalidTarget
        }
        try await cooldownStore.up(target: target)
        successfulCooldownMutationHandler?()
    }

    func resetCooldowns() async throws {
        try await cooldownStore.reset()
        successfulCooldownMutationHandler?()
    }

    func refresh() async throws {
        await localRefreshHandler?()
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

    func reportLifecycle(_ report: BrokerLifecycleReport, outcome: BrokerOutcomeDetail?) async throws -> BrokerLifecycleResult {
        let transition = try await auditStore.reportLifecycleWithRecords(report, outcome: outcome)
        if transition.result == .recorded, report.status.isTerminal, let record = transition.record {
            do { try await outcomeStore.noteTerminal(record, reviewed: transition.reviewed) }
            catch { Self.logger.error("outcome_write_failed") }
        }
        return transition.result
    }

    /// The Outcomes pane's per-role, per-model trend (OUTC-03). Reads the
    /// outcome store's own snapshot and hands it to the pure trend function
    /// with this service's clock; the pane never touches the store directly.
    /// `loadFailed` is true only when the on-disk rollup was rejected and
    /// replaced with an empty one, so a healthy empty history never reads as
    /// an error.
    func outcomeTrend(role: String?, includeAllReasons: Bool) async -> BrokerOutcomeView {
        let rollup = await outcomeStore.snapshot()
        let failed = await outcomeStore.loadFailed
        let trend = BrokerOutcomeTrend.make(
            rollup: rollup, now: now(), role: role, includeAllReasons: includeAllReasons
        )
        return BrokerOutcomeView(trend: trend, loadFailed: failed && rollup.buckets.isEmpty)
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
            reason: decision.reason,
            pickBasis: decision.pickBasis,
            residency: decision.residency,
            routeClass: decision.routeClass
        )
        localPicks.insert((candidate: decision.model, at: timestamp), at: 0)
        if localPicks.count > Self.recentPicksCapacity { localPicks.removeLast() }
        recentPicks.insert(entry, at: 0)
        if recentPicks.count > Self.recentPicksCapacity {
            recentPicks.removeLast(recentPicks.count - Self.recentPicksCapacity)
        }
        uiState.lastPickSummary = "\(decision.role) \u{2192} \(decision.model)"
        uiState.lastPickDegraded = decision.degraded
        uiState.lastPickDegradedReason = decision.degraded ? decision.degradedReason : nil
        publishUIState()
    }

    /// Test-only accessor for the ring buffer contents (newest-first).
    var recentPicksSnapshot: [RecentPick] { recentPicks }

    // MARK: - Oracle freshness

    private func makeOracleFreshness() -> BrokerStatus.OracleFreshness {
        guard let oracle else {
            return BrokerStatus.OracleFreshness(present: false, stale: false, ageSeconds: nil, accounts: [])
        }
        let currentDate = now()
        let threshold = policy.thresholds.stalenessSeconds
        let ageSeconds = oracle.newestDataAt.flatMap {
            BrokerFreshness.age(since: $0, now: currentDate)
        } ?? (oracle.accounts.compactMap(\.lastUpdated) + [oracle.chatGPTLastUpdated].compactMap { $0 })
            .compactMap { BrokerFreshness.age(since: $0, now: currentDate) }
            .min()
        let ageIsStale = ageSeconds.map { $0 > threshold } ?? true
        let claudeIsStale = oracle.accounts.contains { account in
            account.state != .fresh
                || (account.lastUpdated.map {
                    !BrokerFreshness.isFresh($0, now: currentDate, threshold: threshold)
                } ?? true)
        }
        let chatGPTIsStale = oracle.chatGPTConfigured && (
            oracle.chatGPTState != .fresh
                || (oracle.chatGPTLastUpdated.map {
                    !BrokerFreshness.isFresh($0, now: currentDate, threshold: threshold)
                } ?? true)
        )
        let accounts = oracle.accounts.map {
            BrokerStatus.AccountFreshness(id: $0.id, label: $0.label, state: $0.state.rawValue)
        }
        return BrokerStatus.OracleFreshness(
            present: true,
            stale: ageIsStale || claudeIsStale || chatGPTIsStale,
            ageSeconds: ageSeconds,
            accounts: accounts
        )
    }

    private static func routeHealth(from liveness: [String: T3Liveness]) -> [BrokerStatus.RouteHealth] {
        liveness.filter { $0.key != "t3:pi/default" }.map { key, value in
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
    /// Why this pick won, copied from the decision (OUTC-01 made visible).
    /// `nil` for picks recorded before this field existed, or when the
    /// engine never classified a basis. `.quality` and `nil` both show no
    /// chip on the Activity row (U5): quality is the common case.
    var pickBasis: BrokerPickBasis? = nil
    var residency: String? = nil
    var routeClass: String? = nil
}

/// The Outcomes pane's load result: the computed trend plus whether the
/// on-disk rollup was rejected and replaced with an empty one (the pane's
/// "Read failed" state).
struct BrokerOutcomeView: Equatable, Sendable {
    let trend: BrokerOutcomeTrend
    let loadFailed: Bool
}

/// Snapshot returned by the `status` tool. Labels, percentages, ISO timestamps
/// and candidate/instance ids only — never credential material (D-07).
struct BrokerPricingStatus: Sendable, Equatable, Encodable {
    struct RoleRate: Sendable, Equatable, Encodable {
        let role: String
        let decisionsPerHourMilli: Int
    }
    let enabled: Bool
    let historyDays: Int
    let historySufficient: Bool
    let roles: [RoleRate]
    let pools: [BrokerPoolPrice]

    static let empty = BrokerPricingStatus(
        enabled: false, historyDays: 0, historySufficient: false, roles: [], pools: []
    )
}

struct BrokerResidencyStatus: Sendable, Equatable, Encodable {
    let supported: Bool
    let roles: [String: BrokerResidency]
}

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

        /// An exported envelope can exist before any provider has returned usage.
        var hasUsageData: Bool { present && ageSeconds != nil }
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
    var pricing: BrokerPricingStatus = .empty
    var residency = BrokerResidencyStatus(supported: true, roles: [:])
    var health: BrokerHealthStatus? = nil
    var local: BrokerLocalStatus? = nil
}

struct BrokerLocalStatus: Sendable, Equatable, Encodable {
    struct Host: Sendable, Equatable, Encodable {
        let host: String
        let state: String
        let ageSeconds: Double
        let loadedPreset: String?
        let slotsBusy: Int
        let slotsTotal: Int
        let pending: Int
    }
    struct Route: Sendable, Equatable, Encodable {
        let candidate: String
        let residency: BrokerResidency?
        let enabled: Bool
        let roles: [String]
        let available: Bool
        let priceLevel: Int?
        let reason: String?
    }
    let hosts: [Host]
    let routes: [Route]

    init(routes: [BrokerLocalRoute], load: BrokerLocalLoad?, now: Date) {
        hosts = (load?.hosts ?? []).map { host in
            let loaded = host.presets.filter { $0.value.status == "loaded" }
            let id = loaded.keys.sorted().first { T3InstanceConfig.isValidModelSlug($0) }
            return Host(host: host.host, state: host.state,
                ageSeconds: max(0, now.timeIntervalSince(host.observedAt)), loadedPreset: id,
                slotsBusy: loaded.values.reduce(0) { $0 + min(64, max(0, $1.slotsBusy)) },
                slotsTotal: loaded.values.reduce(0) { $0 + min(64, max(0, $1.slotsTotal)) },
                pending: host.pending)
        }
        self.routes = routes.map { route in
            let reason = route.enabled ? BrokerLocalRouting.gate(route: route, load: load, now: now) : "local route disabled"
            return Route(candidate: route.candidate, residency: route.residency, enabled: route.enabled,
                roles: route.roles, available: reason == nil,
                priceLevel: reason == nil ? BrokerLocalRouting.level(route: route, load: load, now: now) : nil,
                reason: reason)
        }
    }
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
    /// The engine's own account of why the last pick was degraded, so a
    /// warning can say why instead of only that it happened.
    var lastPickDegradedReason: String? = nil
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
