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

actor BrokerService: BrokerServiceProtocol {
    /// Recent-picks ring buffer capacity (D-08).
    static let recentPicksCapacity = 50

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
    private let livenessChecker: any T3LivenessCheckerProtocol
    private let now: @Sendable () -> Date
    private let decide: DecideFunction

    /// Latest quota snapshot pushed in from the main actor. `nil` until the
    /// first refresh completes.
    private var oracle: OracleSnapshot?
    /// Reachability keyed by resolved T3 instance id. A missing key means
    /// unreachable: the t3 route fails closed.
    private var t3Liveness: [String: T3Liveness] = [:]

    /// Newest-first, capped at `recentPicksCapacity`.
    private var recentPicks: [RecentPick] = []

    private var uiState = BrokerUIState.initial
    private var uiStateContinuations: [UUID: AsyncStream<BrokerUIState>.Continuation] = [:]

    private var refreshHandler: (@Sendable () async throws -> Void)?

    init(
        policy: BrokerPolicy = .default,
        cooldownStore: BrokerCooldownStore = BrokerCooldownStore(),
        livenessChecker: any T3LivenessCheckerProtocol = T3LivenessChecker(),
        now: @escaping @Sendable () -> Date = { Date() },
        decide: @escaping DecideFunction = BrokerEngine.decide
    ) {
        self.policy = policy
        self.cooldownStore = cooldownStore
        self.livenessChecker = livenessChecker
        self.now = now
        self.decide = decide
    }

    // MARK: - Intake (pushed by AppModel, wired in 07-04)

    func updatePolicy(_ policy: BrokerPolicy) {
        self.policy = policy
    }

    func updateOracleSnapshot(_ oracle: OracleSnapshot?) {
        self.oracle = oracle
        uiState.oracleFreshness = makeOracleFreshness()
        publishUIState()
    }

    func updateT3Liveness(_ liveness: [String: T3Liveness]) {
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
        let cooldowns = await cooldownStore.mergedSnapshot()
        let decision = try decide(role, caller, policy, oracle, cooldowns, now(), t3Liveness)
        recordPick(decision)
        return decision
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

    func down(target: String, minutes: Int?) async {
        await cooldownStore.down(target: target, minutes: minutes)
    }

    func up(target: String) async {
        await cooldownStore.up(target: target)
    }

    func refresh() async throws {
        let liveness = await livenessChecker.checkLiveness(instances: policy.t3Instances)
        updateT3Liveness(liveness)
        if let refreshHandler {
            try await refreshHandler()
        }
    }

    // MARK: - Recent picks

    private func recordPick(_ decision: BrokerDecision) {
        let entry = RecentPick(
            timestamp: now(),
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
        let ageSeconds = now().timeIntervalSince(oracle.generatedAt)
        let stale = ageSeconds > policy.thresholds.stalenessSeconds
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
    var routeHealth: [BrokerStatus.RouteHealth]
    var oracleFreshness: BrokerStatus.OracleFreshness

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
