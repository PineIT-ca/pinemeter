//
//  BrokerEngine.swift
//  Pinemeter
//
//  Pure decision function. Every input from the outside world (policy, quota
//  oracle, cooldowns, clock, T3 reachability) arrives as a parameter, so the
//  engine is fully testable without any IO.
//

import Foundation

enum BrokerError: LocalizedError, Equatable {
    case unknownRole(role: String, known: [String])
    case unknownCaller(caller: String, known: [String])
    case configError(String)

    var errorDescription: String? {
        switch self {
        case .unknownRole(let role, let known):
            return "Unknown role '\(role)'. Known roles: \(known.joined(separator: ", "))"
        case .unknownCaller(let caller, let known):
            return "Unknown caller '\(caller)'. Known callers: \(known.joined(separator: ", "))"
        case .configError(let message):
            return "Broker policy error: \(message)"
        }
    }
}

/// Freshness of one quota row, mirroring `AppModel.aggregateQuotaState`.
enum BrokerQuotaState: String, Sendable, Equatable {
    case fresh
    case stale
    case error
    case unavailable
}

/// A Sendable snapshot of Pinemeter's in-memory quota state, pushed into the
/// broker on the same code path that exports the aggregate snapshot. The server
/// never hops to the main actor to answer a pick.
struct OracleSnapshot: Sendable, Equatable {
    struct AccountRow: Sendable, Equatable {
        let id: String
        let label: String
        let isPrimary: Bool
        let lastUpdated: Date?
        let state: BrokerQuotaState
        /// Utilization percentages, 0–100. `nil` when the provider did not report one.
        let session: Double?
        let weekly: Double?
        let sonnet: Double?
        let fable: Double?

        init(
            id: String,
            label: String,
            isPrimary: Bool,
            lastUpdated: Date?,
            state: BrokerQuotaState,
            session: Double?,
            weekly: Double?,
            sonnet: Double?,
            fable: Double?
        ) {
            self.id = id
            self.label = label
            self.isPrimary = isPrimary
            self.lastUpdated = lastUpdated
            self.state = state
            self.session = session
            self.weekly = weekly
            self.sonnet = sonnet
            self.fable = fable
        }
    }

    struct ChatGPTRow: Sendable, Equatable {
        let label: String
        let usedPercent: Double?

        init(label: String, usedPercent: Double?) {
            self.label = label
            self.usedPercent = usedPercent
        }
    }

    let generatedAt: Date
    let accounts: [AccountRow]
    let chatGPTState: BrokerQuotaState
    let chatGPTRows: [ChatGPTRow]

    init(
        generatedAt: Date,
        accounts: [AccountRow],
        chatGPTState: BrokerQuotaState,
        chatGPTRows: [ChatGPTRow]
    ) {
        self.generatedAt = generatedAt
        self.accounts = accounts
        self.chatGPTState = chatGPTState
        self.chatGPTRows = chatGPTRows
    }

    /// The primary Claude account row, which gates every `native` candidate.
    var primaryAccount: AccountRow? {
        accounts.first { $0.isPrimary }
    }
}

/// Whether a T3 base URL answered. Any HTTP response counts as reachable,
/// including 401 — "no credential" is not "app not running".
struct T3Liveness: Sendable, Equatable {
    let reachable: Bool
    let why: String

    init(reachable: Bool, why: String) {
        self.reachable = reachable
        self.why = why
    }
}

enum BrokerEngine {
    /// Picks a route/model for `role`, filtered for `caller`.
    ///
    /// The signature is frozen: it takes the whole injected world so the
    /// function stays pure and hermetically testable.
    ///
    /// - Parameters:
    ///   - role: Task role. An unknown role fails loud.
    ///   - caller: Invoking harness id; `nil`/empty resolves to the default caller.
    ///   - policy: The routing policy.
    ///   - oracle: Latest quota snapshot, or `nil` when none is available.
    ///   - cooldowns: Cooldown key → the instant the key becomes available again.
    ///   - now: Injected clock; the only time source the engine reads.
    ///   - t3: Reachability keyed by resolved T3 instance id. A missing key means
    ///     unreachable — the t3 route fails closed.
    ///
    /// - Note: the walk applies, in order, the structural caller filter (never a
    ///   quota event), then the cooldown gate, then the per-route availability
    ///   gates. The first available candidate wins.
    static func decide(
        role: String,
        caller: String?,
        policy: BrokerPolicy,
        oracle: OracleSnapshot?,
        cooldowns: [String: Date],
        now: Date,
        t3: [String: T3Liveness]
    ) throws -> BrokerDecision {
        let resolvedCaller = BrokerPolicy.resolveCaller(caller)

        guard let candidates = policy.roles[role] else {
            throw BrokerError.unknownRole(role: role, known: policy.roles.keys.sorted())
        }
        guard !candidates.isEmpty else {
            throw BrokerError.configError("role '\(role)' has no candidates")
        }

        let filter = try CallerFilter(caller: resolvedCaller, policy: policy)
        let block = oracleBlock(from: oracle, thresholds: policy.thresholds, now: now)

        var tried: [BrokerCandidateTried] = []
        var chosen: (candidate: BrokerCandidate, evaluation: Evaluation)?

        for candidate in candidates {
            if let why = filter.rejection(for: candidate, policy: policy) {
                tried.append(
                    BrokerCandidateTried(
                        candidate: candidate.id,
                        available: false,
                        callerFiltered: true,
                        why: why
                    )
                )
                continue
            }

            let evaluation = evaluate(
                candidate: candidate,
                policy: policy,
                oracle: oracle,
                block: block,
                cooldowns: cooldowns,
                now: now,
                t3: t3
            )
            tried.append(
                BrokerCandidateTried(
                    candidate: candidate.id,
                    available: evaluation.available,
                    why: evaluation.why
                )
            )
            if evaluation.available {
                chosen = (candidate, evaluation)
                break
            }
        }

        let winner: BrokerCandidate
        let source: BrokerDecisionSource
        let degraded: Bool
        let reason: String

        if let chosen {
            winner = chosen.candidate
            source = .policy
            degraded = chosen.evaluation.failOpen
            reason = buildReason(source: .policy, winner: chosen.candidate, evaluation: chosen.evaluation, tried: tried)
        } else {
            guard policy.allowsForcedDegraded(role: role) else {
                throw BrokerError.configError(
                    "role '\(role)' has no candidate with headroom and forced-degraded is disabled for it"
                )
            }
            // Nothing had headroom: force the top-ranked candidate the caller can
            // actually invoke. Forcing a structurally filtered candidate — or a
            // t3 lane with no proof the local server is up — would hand back an
            // unactionable pick, so the fail-closed guarantee holds here too.
            guard let forced = candidates.first(where: { candidate in
                guard filter.rejection(for: candidate, policy: policy) == nil else { return false }
                guard candidate.route == .t3 else { return true }
                return t3[policy.resolvedInstance(for: candidate)]?.reachable == true
            }) else {
                throw BrokerError.configError(
                    "role '\(role)' has no candidates invocable by caller '\(resolvedCaller)'"
                )
            }
            winner = forced
            source = .forcedDegraded
            degraded = true
            reason = buildReason(source: .forcedDegraded, winner: forced, evaluation: nil, tried: tried)
        }

        return BrokerDecision(
            role: role,
            caller: resolvedCaller,
            model: winner.id,
            route: winner.route,
            agentModel: agentModel(for: winner, policy: policy),
            invocation: invocation(for: winner, policy: policy),
            reason: reason,
            source: source,
            oracle: block,
            degraded: degraded,
            candidatesTried: tried
        )
    }

    // MARK: - Reasons

    /// The human-readable explanation attached to a decision.
    ///
    /// Three rules, all inherited from the reference: a forced pick distinguishes
    /// "nothing had headroom" from "nothing the caller can *reach* had headroom";
    /// a native fail-open pick is marked degraded inline; and a non-native pick
    /// explains what it routed around, preferring a real quota or cooldown event
    /// over a structural filter (for a route-restricted caller the filter is
    /// almost always first, and it would otherwise mask the actual event).
    static func buildReason(
        source: BrokerDecisionSource,
        winner: BrokerCandidate,
        evaluation: Evaluation?,
        tried: [BrokerCandidateTried]
    ) -> String {
        if source == .forcedDegraded {
            return tried.contains(where: \.callerFiltered)
                ? "no reachable candidate had headroom; forcing top reachable choice \(winner.id) (degraded)"
                : "no candidate had headroom; forcing top choice \(winner.id) (degraded)"
        }
        guard let evaluation else { return "no reason available" }
        if winner.route == .native {
            return evaluation.failOpen ? "\(evaluation.why) (degraded)" : evaluation.why
        }
        let skipped = tried.first { !$0.available && !$0.callerFiltered }
            ?? tried.first { !$0.available }
        if let skipped {
            return "\(skipped.why), routing to \(winner.route.rawValue)"
        }
        return evaluation.why
    }

    // MARK: - Availability

    /// The verdict for one candidate. `failOpen` marks a pick made *without*
    /// trustworthy quota data — the decision is then flagged `degraded` even
    /// though the source stays `policy`.
    struct Evaluation: Equatable {
        let available: Bool
        let failOpen: Bool
        let why: String

        static func available(failOpen: Bool = false, _ why: String) -> Evaluation {
            Evaluation(available: true, failOpen: failOpen, why: why)
        }

        static func unavailable(_ why: String) -> Evaluation {
            Evaluation(available: false, failOpen: false, why: why)
        }
    }

    /// Live gates, in order. The cooldown check runs first for every route: a
    /// down-mark is a stronger, more specific signal than a stale oracle, so it
    /// must beat the native fail-open path.
    static func evaluate(
        candidate: BrokerCandidate,
        policy: BrokerPolicy,
        oracle: OracleSnapshot?,
        block: BrokerOracleBlock,
        cooldowns: [String: Date],
        now: Date,
        t3: [String: T3Liveness]
    ) -> Evaluation {
        if let cooling = cooldownState(for: candidate, policy: policy, cooldowns: cooldowns, now: now) {
            return .unavailable(
                "\(candidate.id) in cooldown until \(iso8601(cooling.availableAt)) (key \(cooling.key))"
            )
        }

        switch candidate.route {
        case .native:
            return evaluateNativePools(
                model: candidate.model,
                thresholds: policy.thresholds,
                block: block
            )

        case .t3:
            // Fail closed: only an injected signal proving the local T3 server
            // is reachable makes this route available.
            let instance = policy.resolvedInstance(for: candidate)
            guard let liveness = t3[instance] else {
                return .unavailable(
                    "t3 signal absent for instance \"\(instance)\" (route unavailable off the T3 desktop host)"
                )
            }
            guard liveness.reachable else {
                return .unavailable("t3 unreachable: \(liveness.why)")
            }
            if let verdict = laneVerdict(for: candidate, policy: policy, oracle: oracle) {
                return verdict
            }
            if case .claudeAccount = policy.usageLanes[candidate.id] {
                // A mapped Claude lane with no fresh row fails OPEN like the
                // native oracle does: available, but the pick is quota-blind.
                return .available(
                    failOpen: true,
                    "\(candidate.id) lane oracle has no fresh data; t3 reachable, failing open"
                )
            }
            return .available("t3 reachable (\(liveness.why))")

        case .codex:
            // The lane oracle is the only proactive signal codex has; without a
            // verdict, cooldowns are what gate it.
            return laneVerdict(for: candidate, policy: policy, oracle: oracle)
                ?? .available("codex available (no cooldown)")
        }
    }

    /// Gates a native candidate on the primary account's pools.
    ///
    /// FAIL OPEN when the oracle is absent, stale, or missing session/weekly:
    /// the candidate stays available but the pick is flagged `degraded`, because
    /// it was made without trustworthy quota data.
    static func evaluateNativePools(
        model: String,
        thresholds: BrokerThresholds,
        block: BrokerOracleBlock
    ) -> Evaluation {
        guard block.present else {
            return .available(failOpen: true, "oracle missing, failing open to native claude")
        }
        guard !block.stale else {
            let age = block.ageSeconds.map { "\(percent($0))s" } ?? "unknown"
            return .available(
                failOpen: true,
                "oracle stale (age \(age) > \(percent(thresholds.stalenessSeconds))s), failing open to native claude"
            )
        }
        guard let session = block.session, let weekly = block.weekly else {
            return .available(
                failOpen: true,
                "oracle present but session/weekly utilization missing, failing open to native claude"
            )
        }

        // Gate order fixes which reason surfaces first when several gates fail.
        if weekly >= thresholds.weeklyPct {
            return .unavailable(
                "native weekly \(percent(weekly))% >= \(percent(thresholds.weeklyPct))%"
            )
        }
        if session >= thresholds.sessionPct {
            return .unavailable(
                "native session \(percent(session))% >= \(percent(thresholds.sessionPct))%"
            )
        }
        // The per-model pools are independent caps: they gate only their own
        // model, and only when the oracle actually carries the datum.
        let sonnet = model == "claude-sonnet-5" ? block.sonnet : nil
        if let sonnet, sonnet >= thresholds.sonnetWeeklyPct {
            return .unavailable(
                "native sonnet pool \(percent(sonnet))% >= \(percent(thresholds.sonnetWeeklyPct))%"
            )
        }
        let fable = model == "claude-fable-5" ? block.fable : nil
        if let fable, fable >= thresholds.fableWeeklyPct {
            return .unavailable(
                "native fable pool \(percent(fable))% >= \(percent(thresholds.fableWeeklyPct))%"
            )
        }

        var why = "native weekly \(percent(weekly))% < \(percent(thresholds.weeklyPct))% ok"
        why += "; session \(percent(session))% ok"
        if let sonnet {
            why += "; sonnet \(percent(sonnet))% < \(percent(thresholds.sonnetWeeklyPct))% ok"
        }
        if let fable {
            why += "; fable \(percent(fable))% < \(percent(thresholds.fableWeeklyPct))% ok"
        }
        return .available(why)
    }

    // MARK: - Lane oracle

    /// Cross-account quota verdict for a non-native candidate.
    ///
    /// Returns `nil` when no verdict is possible — no mapping, no matching row,
    /// or no fresh data. Lane matching is a pure tightening: real quota data
    /// blocks a capped lane sooner, but its absence never blocks anything the
    /// cooldowns would allow.
    static func laneVerdict(
        for candidate: BrokerCandidate,
        policy: BrokerPolicy,
        oracle: OracleSnapshot?
    ) -> Evaluation? {
        guard let lane = policy.usageLanes[candidate.id], let oracle else { return nil }
        let thresholds = policy.thresholds

        switch lane {
        case .claudeAccount(let accountId, let labelContains, let isPrimary):
            guard let row = claudeAccountRow(
                for: candidate,
                policy: policy,
                oracle: oracle,
                accountId: accountId,
                labelContains: labelContains,
                isPrimary: isPrimary
            ), row.state == .fresh else { return nil }

            // Gate order mirrors the native pools: the shared pools are
            // independent caps, so a fable pool with headroom must not bypass a
            // capped shared weekly.
            if let weekly = row.weekly, weekly >= thresholds.weeklyPct {
                return .unavailable(
                    "\(candidate.id) account \"\(row.label)\" weekly \(percent(weekly))% >= \(percent(thresholds.weeklyPct))%"
                )
            }
            if let session = row.session, session >= thresholds.sessionPct {
                return .unavailable(
                    "\(candidate.id) account \"\(row.label)\" session \(percent(session))% >= \(percent(thresholds.sessionPct))%"
                )
            }
            let isFable = candidate.model.contains("fable")
            if isFable, let fable = row.fable, fable >= thresholds.fableWeeklyPct {
                return .unavailable(
                    "\(candidate.id) account \"\(row.label)\" fable pool \(percent(fable))% >= \(percent(thresholds.fableWeeklyPct))%"
                )
            }

            var why = "\(candidate.id) account \"\(row.label)\" weekly "
            why += row.weekly.map { "\(percent($0))%" } ?? "n/a"
            why += " ok"
            if isFable, let fable = row.fable {
                why += "; fable \(percent(fable))% < \(percent(thresholds.fableWeeklyPct))% ok"
            }
            return .available(why)

        case .chatGPT(let labelContains):
            guard oracle.chatGPTState == .fresh else { return nil }
            let needle = labelContains?.lowercased()
            let rows = oracle.chatGPTRows.filter { row in
                guard row.usedPercent != nil else { return false }
                guard let needle, !needle.isEmpty else { return true }
                return row.label.lowercased().contains(needle)
            }
            guard let worst = rows.max(by: { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }),
                  let used = worst.usedPercent
            else { return nil }

            // Several matched rows (e.g. "Codex" + "Codex Tasks") gate on the
            // WORST one: if any shared window is capped, the lane is capped.
            if used >= thresholds.chatgptWeeklyPct {
                return .unavailable(
                    "\(candidate.id) chatgpt \"\(worst.label)\" \(percent(used))% >= \(percent(thresholds.chatgptWeeklyPct))%"
                )
            }
            return .available(
                "\(candidate.id) chatgpt \"\(worst.label)\" \(percent(used))% < \(percent(thresholds.chatgptWeeklyPct))% ok"
            )
        }
    }

    /// Resolves the Claude account row a lane gates on.
    ///
    /// Precedence: the resolved T3 instance's bound account id (the in-app
    /// binding the editor writes), then the matcher's explicit id, then a
    /// case-insensitive label match, then the primary flag — and the primary
    /// flag only when it selects exactly one row.
    static func claudeAccountRow(
        for candidate: BrokerCandidate,
        policy: BrokerPolicy,
        oracle: OracleSnapshot,
        accountId: String?,
        labelContains: String?,
        isPrimary: Bool?
    ) -> OracleSnapshot.AccountRow? {
        if candidate.route == .t3 {
            let instance = policy.resolvedInstance(for: candidate)
            if let bound = policy.t3Instances.first(where: { $0.id == instance })?.boundAccountId,
               !bound.isEmpty {
                return oracle.accounts.first { $0.id == bound }
            }
        }
        if let accountId, !accountId.isEmpty {
            return oracle.accounts.first { $0.id == accountId }
        }
        if let labelContains, !labelContains.isEmpty {
            let needle = labelContains.lowercased()
            return oracle.accounts.first { $0.label.lowercased().contains(needle) }
        }
        if let isPrimary {
            let flagged = oracle.accounts.filter { $0.isPrimary == isPrimary }
            return flagged.count == 1 ? flagged[0] : nil
        }
        return nil
    }

    /// Percentages read better without a trailing `.0` in reasons.
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// A cooldown entry that is still in the future, with the key that matched.
    struct CooldownHit: Equatable {
        let key: String
        let availableAt: Date
    }

    /// Cooldown keys in precedence order: the full candidate id (so a qualified
    /// lane cools alone), then — for t3 — the instance-resolved id (t3-dispatch
    /// knows only the instance+model it dispatched to, never which candidate id
    /// ranked it), then the bare route (`t3` cools every t3 lane).
    static func cooldownKeys(for candidate: BrokerCandidate, policy: BrokerPolicy) -> [String] {
        var keys = [candidate.id]
        if candidate.route == .t3 {
            let resolved = "t3:\(policy.resolvedInstance(for: candidate))/\(candidate.model)"
            if resolved != candidate.id {
                keys.append(resolved)
            }
        }
        keys.append(candidate.route.rawValue)
        return keys
    }

    /// An entry cools iff its `availableAt` is in the future relative to the
    /// injected clock. Past entries self-expire — there is no cleanup pass.
    static func cooldownState(
        for candidate: BrokerCandidate,
        policy: BrokerPolicy,
        cooldowns: [String: Date],
        now: Date
    ) -> CooldownHit? {
        for key in cooldownKeys(for: candidate, policy: policy) {
            guard let availableAt = cooldowns[key], availableAt > now else { continue }
            return CooldownHit(key: key, availableAt: availableAt)
        }
        return nil
    }

    static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Structural caller filter

    /// The caller's structural allowances, resolved once per decision.
    ///
    /// These are never quota events: a Codex session cannot invoke the Agent
    /// tool, so handing it a native pick is a defect, not a routing preference.
    /// Filtered candidates are excluded from the forced-degraded fallback too.
    struct CallerFilter {
        let caller: String
        /// `nil` means the policy declares no callers — every route is allowed.
        let allowedRoutes: Set<BrokerPolicy.Route>?
        let deniedCandidates: Set<String>
        let deniedInstances: Set<String>

        init(caller: String, policy: BrokerPolicy) throws {
            self.caller = caller
            guard !policy.callers.isEmpty else {
                allowedRoutes = nil
                deniedCandidates = []
                deniedInstances = []
                return
            }
            guard let declared = policy.callers[caller] else {
                // Fail loud: a typo'd caller must never silently gain all routes.
                throw BrokerError.unknownCaller(
                    caller: caller,
                    known: policy.callers.keys.sorted()
                )
            }
            allowedRoutes = Set(declared.routes)
            deniedCandidates = Set(declared.denyCandidates.map(\.id))
            deniedInstances = Set(declared.denyInstances)
        }

        /// The reason this candidate is structurally out of reach, or `nil`.
        func rejection(for candidate: BrokerCandidate, policy: BrokerPolicy) -> String? {
            if let allowedRoutes, !allowedRoutes.contains(candidate.route) {
                return "route \"\(candidate.route.rawValue)\" not invocable by caller \"\(caller)\""
            }
            if deniedCandidates.contains(candidate.id) {
                return "candidate \"\(candidate.id)\" denied for caller \"\(caller)\""
            }
            if candidate.route == .t3, !deniedInstances.isEmpty {
                // Judged on the RESOLVED instance so a new model, or an
                // instance_by_model entry, cannot silently reopen the deny.
                let instance = policy.resolvedInstance(for: candidate)
                if deniedInstances.contains(instance) {
                    return "t3 instance \"\(instance)\" denied for caller \"\(caller)\""
                }
            }
            return nil
        }
    }

    /// The agent alias used for native invocations, if the policy defines one.
    static func agentModel(for candidate: BrokerCandidate, policy: BrokerPolicy) -> String? {
        guard candidate.route == .native else { return nil }
        return policy.agentModelAliases[candidate.model]
    }

    /// How the caller should invoke this candidate.
    static func invocation(for candidate: BrokerCandidate, policy: BrokerPolicy) -> BrokerInvocation {
        switch candidate.route {
        case .native:
            return .agent(model: policy.agentModelAliases[candidate.model] ?? candidate.model)
        case .codex:
            return .codexExec(model: candidate.model)
        case .t3:
            return .t3Dispatch(
                model: candidate.model,
                instanceId: policy.resolvedInstance(for: candidate)
            )
        }
    }

    /// Projects the primary account's row into the decision's `oracle` block.
    static func oracleBlock(
        from snapshot: OracleSnapshot?,
        thresholds: BrokerThresholds,
        now: Date
    ) -> BrokerOracleBlock {
        guard let snapshot, let row = snapshot.primaryAccount else { return .absent }
        let ageSeconds = row.lastUpdated.map { now.timeIntervalSince($0) }
        let stale = row.state != .fresh
            || (ageSeconds.map { $0 > thresholds.stalenessSeconds } ?? true)
        return BrokerOracleBlock(
            present: true,
            stale: stale,
            ageSeconds: ageSeconds,
            session: row.session,
            weekly: row.weekly,
            sonnet: row.sonnet,
            fable: row.fable
        )
    }
}
