//
//  BrokerEngine.swift
//  Pinemeter
//
//  Pure decision function. Every input from the outside world (policy, quota
//  oracle, cooldowns, clock, T3 reachability) arrives as a parameter, so the
//  engine is fully testable without any IO.
//

import Foundation

enum BrokerFreshness {
    static func age(since timestamp: Date, now: Date) -> TimeInterval? {
        let age = now.timeIntervalSince(timestamp)
        return age.isFinite && age >= 0 ? age : nil
    }

    static func isFresh(_ timestamp: Date, now: Date, threshold: TimeInterval) -> Bool {
        age(since: timestamp, now: now).map { $0 <= threshold } ?? false
    }
}

enum BrokerError: LocalizedError, Equatable {
    case unknownRole(role: String, known: [String])
    case unknownCaller(caller: String, known: [String])
    case malformedCaller(caller: String)
    case configError(String)

    var errorDescription: String? {
        switch self {
        case .unknownRole(let role, let known):
            // `role` is arbitrary input from the same unauthenticated port as
            // `caller`, so it gets the same redaction on the way out.
            return "Unknown role '\(BrokerPolicy.redactedCaller(role))'. "
                + "Known roles: \(known.joined(separator: ", "))"
        case .unknownCaller(let caller, let known):
            return "Unknown caller '\(caller)'. Known callers: \(known.joined(separator: ", "))"
        case .malformedCaller(let caller):
            // The offending value is echoed back bounded and escaped — it
            // arrives from an unauthenticated loopback port, and this message
            // is rendered in the UI and written to the audit store.
            return "Malformed caller '\(BrokerPolicy.redactedCaller(caller))'. "
                + "A caller id is 1-\(BrokerPolicy.maxCallerLength) characters: "
                + "letters, numbers, underscore, period, or hyphen."
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
        let sessionResetAt: Date?
        let weeklyResetAt: Date?
        let sonnetResetAt: Date?
        let fableResetAt: Date?

        init(
            id: String,
            label: String,
            isPrimary: Bool,
            lastUpdated: Date?,
            state: BrokerQuotaState,
            session: Double?,
            weekly: Double?,
            sonnet: Double?,
            fable: Double?,
            sessionResetAt: Date? = nil,
            weeklyResetAt: Date? = nil,
            sonnetResetAt: Date? = nil,
            fableResetAt: Date? = nil
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
            self.sessionResetAt = sessionResetAt
            self.weeklyResetAt = weeklyResetAt
            self.sonnetResetAt = sonnetResetAt
            self.fableResetAt = fableResetAt
        }
    }

    struct ChatGPTRow: Codable, Sendable, Equatable {
        let label: String
        let usedPercent: Double?
        let resetAt: Date?
        let windowRole: ChatGPTUsageData.MenuBarQuotaRole?

        init(
            label: String,
            usedPercent: Double?,
            resetAt: Date? = nil,
            windowRole: ChatGPTUsageData.MenuBarQuotaRole? = nil
        ) {
            self.label = label
            self.usedPercent = usedPercent
            self.resetAt = resetAt
            self.windowRole = windowRole
        }
    }

    static let maxChatGPTRows = 64

    let generatedAt: Date
    let accounts: [AccountRow]
    let chatGPTState: BrokerQuotaState
    let chatGPTRows: [ChatGPTRow]
    /// Whether a ChatGPT credential exists on this machine, independent of
    /// whether any usage has been fetched yet.
    ///
    /// `chatGPTState` is derived from *data*, and ChatGPT usage is never
    /// restored from cache at launch, so a fully configured machine reports
    /// `.unavailable` from launch until its first fetch lands. Anything asking
    /// "does this machine have ChatGPT at all" must read this instead, or it
    /// will answer "no" once per launch.
    let chatGPTConfigured: Bool

    init(
        generatedAt: Date,
        accounts: [AccountRow],
        chatGPTState: BrokerQuotaState,
        chatGPTRows: [ChatGPTRow],
        chatGPTConfigured: Bool = false
    ) {
        self.generatedAt = generatedAt
        self.accounts = accounts
        self.chatGPTState = chatGPTState
        self.chatGPTRows = chatGPTRows
        self.chatGPTConfigured = chatGPTConfigured
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
        // The port is loopback but unauthenticated, and this value is echoed
        // into the decision, rendered, and persisted. Reject a malformed id
        // before it reaches any of those sinks.
        //
        // A caller the policy itself declares is exempt: that string is
        // user-authored config, at the same trust level as an instance name,
        // and there is no callers editor yet, so hand-writing the policy is
        // the only way to add one. The charset rule exists for port input.
        guard BrokerPolicy.isValidCaller(resolvedCaller)
            || policy.callers[resolvedCaller] != nil else {
            throw BrokerError.malformedCaller(caller: resolvedCaller)
        }

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
        // A candidate that is only available because its lane has no configured
        // quota source at all. It is held back rather than taken, so a lower-
        // ranked candidate whose headroom was actually verified can win. See
        // `laneSourceUnconfigured` for why this demotes instead of excluding.
        var unverified: (candidate: BrokerCandidate, evaluation: Evaluation)?

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
                    // Say so on the row itself: without this, an audit reader
                    // sees an `available` candidate that the walk passed over
                    // and cannot tell why. Worded for the outcome it does NOT
                    // yet know — this same candidate still wins when nothing
                    // source-verified follows it.
                    why: evaluation.unconfigured
                        ? "\(evaluation.why); held back for a source-verified candidate"
                        : evaluation.why
                )
            )
            guard evaluation.available else { continue }
            if evaluation.unconfigured {
                // Rank still decides among equally unverified candidates: only
                // the first one is kept.
                if unverified == nil { unverified = (candidate, evaluation) }
                continue
            }
            chosen = (candidate, evaluation)
            break
        }
        // Nothing verified: the held-back candidate is better than forcing.
        chosen = chosen ?? unverified

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
            // Nothing had headroom: force the top-ranked candidate the caller
            // can actually invoke. Forcing a structurally filtered candidate —
            // or a t3 lane with no proof the local server is up — would hand
            // back an unactionable pick.
            //
            // `native` and `codex` have no reachability signal of their own, so
            // this is not a general fail-closed guarantee, only the strongest
            // one available per route. Two passes: prefer a candidate whose
            // lane has a configured quota source, and fall back to any
            // invocable candidate. Quota gates stay excluded from both passes —
            // every candidate is over its ceiling by the time this runs, so
            // consulting them would leave nothing to force.
            func isInvocable(_ candidate: BrokerCandidate) -> Bool {
                guard filter.rejection(for: candidate, policy: policy) == nil else { return false }
                guard candidate.route == .t3 else { return true }
                return t3[policy.resolvedInstance(for: candidate)]?.reachable == true
            }
            let configured = candidates.first {
                isInvocable($0)
                    && !laneSourceUnconfigured(for: $0, policy: policy, oracle: oracle)
            }
            guard let forced = configured ?? candidates.first(where: isInvocable) else {
                throw BrokerError.configError(
                    "role '\(role)' has no candidates invocable by caller '\(resolvedCaller)'"
                )
            }
            winner = forced
            source = .forcedDegraded
            degraded = true
            reason = buildReason(source: .forcedDegraded, winner: forced, evaluation: nil, tried: tried)
        }

        // Dispatch boundary (D-03): the editor clamps on write, but a policy
        // written anywhere else — hand-edited JSON, an import, a build from
        // before the clamp existed — can still carry an effort on a model with
        // no effort parameter. Drop it here so nothing unactionable ever
        // reaches a provider. Only a model known to have no effort parameter
        // is clamped; an unknown model keeps its effort (fail soft, D-02).
        // The clamp cannot move the decision: `effort` is excluded from
        // `BrokerCandidate.id`, so route, model, instance, cooldown keying and
        // every `candidatesTried` row are unchanged.
        let dispatched = winner.clampingEffortToModelSupport()

        return BrokerDecision(
            role: role,
            caller: resolvedCaller,
            model: dispatched.id,
            route: dispatched.route,
            agentModel: agentModel(for: dispatched, policy: policy),
            invocation: invocation(for: dispatched, policy: policy),
            reason: reason,
            source: source,
            oracle: block,
            degraded: degraded,
            candidatesTried: tried,
            effort: dispatched.effort
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
        /// Only ever set alongside `failOpen`. Distinguishes "this lane's quota
        /// source was never configured on this machine" from "it is configured
        /// but currently stale, erroring, or missing a field".
        ///
        /// That distinction is what the walk uses to demote a *weak* yes below
        /// a verified one. It must stay narrow: a stale or erroring source means
        /// the user does have the account, so treating it as unconfigured would
        /// silently migrate work off a route every time a poll ages out.
        let unconfigured: Bool
        let why: String

        static func available(
            failOpen: Bool = false,
            unconfigured: Bool = false,
            _ why: String
        ) -> Evaluation {
            Evaluation(available: true, failOpen: failOpen, unconfigured: unconfigured, why: why)
        }

        static func unavailable(_ why: String) -> Evaluation {
            Evaluation(available: false, failOpen: false, unconfigured: false, why: why)
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
                block: block,
                now: now
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
            if let verdict = laneVerdict(for: candidate, policy: policy, oracle: oracle, now: now) {
                return verdict
            }
            if let blind = quotaBlindEvaluation(
                for: candidate,
                policy: policy,
                oracle: oracle,
                suffix: "t3 reachable, failing open"
            ) {
                // A mapped lane with no verdict fails OPEN like the native
                // oracle does: available, but the pick is quota-blind. Every
                // mapped lane is flagged, not just `.claudeAccount` ones — an
                // unflagged fail-open reports a quota-blind pick as verified.
                return blind
            }
            return .available("t3 reachable (\(liveness.why))")

        case .codex:
            // The lane oracle is the only proactive signal codex has; without a
            // verdict, cooldowns are what gate it.
            if let verdict = laneVerdict(for: candidate, policy: policy, oracle: oracle, now: now) {
                return verdict
            }
            if let blind = quotaBlindEvaluation(
                for: candidate,
                policy: policy,
                oracle: oracle,
                suffix: "failing open"
            ) {
                return blind
            }
            return .available("codex available (no cooldown)")
        }
    }

    /// The fail-open verdict for a candidate whose `usage_lanes` mapping exists
    /// but produced no judgement, or `nil` when the candidate is unmapped.
    ///
    /// An unmapped candidate deliberately gets no verdict here: mapping a lane
    /// is what declares "this candidate's headroom is knowable", so absence of
    /// a mapping is a policy gap, not a quota event (that gap is a separate
    /// problem — an edited chain silently orphans its lane).
    static func quotaBlindEvaluation(
        for candidate: BrokerCandidate,
        policy: BrokerPolicy,
        oracle: OracleSnapshot?,
        suffix: String
    ) -> Evaluation? {
        guard policy.usageLanes[candidate.id] != nil else { return nil }
        guard laneSourceUnconfigured(for: candidate, policy: policy, oracle: oracle) else {
            return .available(
                failOpen: true,
                "\(candidate.id) lane oracle has no fresh data; \(suffix)"
            )
        }
        return .available(
            failOpen: true,
            unconfigured: true,
            "\(candidate.id) lane has no configured quota source; \(suffix) unverified"
        )
    }

    /// Whether the quota source a candidate's lane maps to has **never**
    /// produced data on this machine, as opposed to being configured but stale
    /// or erroring.
    ///
    /// This is the capability signal the broker already owns. A `codex`
    /// candidate maps to a ChatGPT lane, and Codex CLI authenticates against a
    /// ChatGPT account, so "Pinemeter has never seen ChatGPT usage" is decent
    /// evidence that this machine has no Codex lane to route to. It is evidence,
    /// not proof — a user may run Codex without giving Pinemeter their ChatGPT
    /// session cookie — which is exactly why it only ever *demotes* a candidate
    /// below a verified one instead of removing it. If nothing else can serve
    /// the role, the candidate is still picked.
    ///
    /// `.error` and `.stale` are deliberately NOT unconfigured: both mean the
    /// account exists and a poll has succeeded at least once.
    ///
    /// This answers only with POSITIVE knowledge that a source is absent. Not
    /// knowing — no oracle pushed yet, no credential state — returns false.
    /// Demoting on ignorance is the same mistake as gating a route on a probe
    /// that cannot see it: it would silently reroute work during every launch
    /// window, before the first quota poll lands.
    static func laneSourceUnconfigured(
        for candidate: BrokerCandidate,
        policy: BrokerPolicy,
        oracle: OracleSnapshot?
    ) -> Bool {
        // `native` is invocable by construction — the caller asking for a pick
        // is the harness that runs the Agent tool — so its capability is never
        // in question and a lane mapped to it must not demote it. The walk
        // never consults lanes for native either; this keeps the forced-degraded
        // pass consistent with it.
        guard candidate.route != .native else { return false }
        guard let lane = policy.usageLanes[candidate.id] else { return false }
        guard let oracle else { return false }
        switch lane {
        case .chatGPT:
            // Credential presence beats data presence: `.unavailable` alone is
            // also what a configured machine reports before its first fetch.
            return oracle.chatGPTState == .unavailable && !oracle.chatGPTConfigured
        case .claudeAccount:
            // Deliberately NOT "the matcher resolved no row". An ambiguous
            // label, an `account_id` naming a row that no longer exists, and an
            // unbound `claude_secondary` are all *misconfigurations* of a
            // machine that does have Claude accounts — the source exists, the
            // matcher just missed. Only a snapshot with no accounts at all
            // means there is nothing here to route to.
            return oracle.accounts.isEmpty
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
        block: BrokerOracleBlock,
        now: Date
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

        if let verdict = paceVerdict(
            label: "native weekly",
            utilization: weekly,
            resetAt: block.weeklyResetAt,
            windowDuration: Constants.Pacing.weeklyWindow,
            now: now
        ) { return verdict }
        if let verdict = paceVerdict(
            label: "native session",
            utilization: session,
            resetAt: block.sessionResetAt,
            windowDuration: Constants.Pacing.sessionWindow,
            now: now
        ) { return verdict }
        if let sonnet, let verdict = paceVerdict(
            label: "native sonnet pool",
            utilization: sonnet,
            resetAt: block.sonnetResetAt,
            windowDuration: Constants.Pacing.weeklyWindow,
            now: now
        ) { return verdict }
        if let fable, let verdict = paceVerdict(
            label: "native fable pool",
            utilization: fable,
            resetAt: block.fableResetAt,
            windowDuration: Constants.Pacing.weeklyWindow,
            now: now
        ) { return verdict }

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
    ///
    /// That holds for this function only. A nil verdict is not outcome-neutral
    /// further up: ``laneSourceUnconfigured`` can rank the candidate below a
    /// source-verified one, and the forced-degraded fallback prefers a
    /// configured lane. Neither path makes a candidate *unavailable*.
    static func laneVerdict(
        for candidate: BrokerCandidate,
        policy: BrokerPolicy,
        oracle: OracleSnapshot?,
        now: Date
    ) -> Evaluation? {
        guard let lane = policy.usageLanes[candidate.id], let oracle else { return nil }
        let thresholds = policy.thresholds
        guard BrokerFreshness.isFresh(
            oracle.generatedAt,
            now: now,
            threshold: thresholds.stalenessSeconds
        ) else {
            return nil
        }

        switch lane {
        case .claudeAccount(let accountId, let labelContains, let isPrimary):
            guard let row = claudeAccountRow(
                for: candidate,
                policy: policy,
                oracle: oracle,
                accountId: accountId,
                labelContains: labelContains,
                isPrimary: isPrimary
            ), row.state == .fresh,
               let lastUpdated = row.lastUpdated,
               BrokerFreshness.isFresh(
                lastUpdated,
                now: now,
                threshold: thresholds.stalenessSeconds
               ) else { return nil }
            guard let session = row.session, let weekly = row.weekly else {
                return .available(
                    failOpen: true,
                    "\(candidate.id) account \"\(row.label)\" session/weekly utilization missing; failing open"
                )
            }

            // Gate order mirrors the native pools: the shared pools are
            // independent caps, so a fable pool with headroom must not bypass a
            // capped shared weekly.
            if weekly >= thresholds.weeklyPct {
                return .unavailable(
                    "\(candidate.id) account \"\(row.label)\" weekly \(percent(weekly))% >= \(percent(thresholds.weeklyPct))%"
                )
            }
            if session >= thresholds.sessionPct {
                return .unavailable(
                    "\(candidate.id) account \"\(row.label)\" session \(percent(session))% >= \(percent(thresholds.sessionPct))%"
                )
            }
            let isFable = candidate.model.contains("fable")
            let isSonnet = candidate.model.contains("sonnet")
            if isSonnet, let sonnet = row.sonnet, sonnet >= thresholds.sonnetWeeklyPct {
                return .unavailable(
                    "\(candidate.id) account \"\(row.label)\" sonnet pool \(percent(sonnet))% >= \(percent(thresholds.sonnetWeeklyPct))%"
                )
            }
            if isFable, let fable = row.fable, fable >= thresholds.fableWeeklyPct {
                return .unavailable(
                    "\(candidate.id) account \"\(row.label)\" fable pool \(percent(fable))% >= \(percent(thresholds.fableWeeklyPct))%"
                )
            }

            if let verdict = paceVerdict(
                label: "\(candidate.id) account \"\(row.label)\" weekly",
                utilization: weekly,
                resetAt: row.weeklyResetAt,
                windowDuration: Constants.Pacing.weeklyWindow,
                now: now
            ) { return verdict }
            if let verdict = paceVerdict(
                label: "\(candidate.id) account \"\(row.label)\" session",
                utilization: session,
                resetAt: row.sessionResetAt,
                windowDuration: Constants.Pacing.sessionWindow,
                now: now
            ) { return verdict }
            if isSonnet, let sonnet = row.sonnet, let verdict = paceVerdict(
                label: "\(candidate.id) account \"\(row.label)\" sonnet pool",
                utilization: sonnet,
                resetAt: row.sonnetResetAt,
                windowDuration: Constants.Pacing.weeklyWindow,
                now: now
            ) { return verdict }
            if isFable, let fable = row.fable, let verdict = paceVerdict(
                label: "\(candidate.id) account \"\(row.label)\" fable pool",
                utilization: fable,
                resetAt: row.fableResetAt,
                windowDuration: Constants.Pacing.weeklyWindow,
                now: now
            ) { return verdict }

            var why = "\(candidate.id) account \"\(row.label)\" weekly \(percent(weekly))% ok"
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
            if let row = rows.first(where: { row in
                guard let duration = chatGPTWindowDuration(for: row.windowRole),
                      let used = row.usedPercent,
                      let resetAt = row.resetAt else { return false }
                return UsageLimit(utilization: used, resetAt: resetAt)
                    .isAtRisk(windowDuration: duration, now: now)
            }) {
                return .unavailable(
                    "\(candidate.id) chatgpt \"\(row.label)\" pacing risk"
                )
            }
            return .available(
                "\(candidate.id) chatgpt \"\(worst.label)\" \(percent(used))% < \(percent(thresholds.chatgptWeeklyPct))% ok"
            )
        }
    }

    static func paceVerdict(
        label: String,
        utilization: Double,
        resetAt: Date?,
        windowDuration: TimeInterval,
        now: Date
    ) -> Evaluation? {
        guard let resetAt,
              UsageLimit(utilization: utilization, resetAt: resetAt)
                .isAtRisk(windowDuration: windowDuration, now: now) else { return nil }
        return .unavailable("\(label) pacing risk")
    }

    static func chatGPTWindowDuration(
        for role: ChatGPTUsageData.MenuBarQuotaRole?
    ) -> TimeInterval? {
        switch role {
        case .chatGPT5h:
            return Constants.Pacing.sessionWindow
        case .chatGPTWeekly, .chatGPTPro, .chatGPTCodexSpark:
            return Constants.Pacing.weeklyWindow
        case nil:
            return nil
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
            let matches = oracle.accounts.filter { $0.label.lowercased().contains(needle) }
            return matches.count == 1 ? matches[0] : nil
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

    /// How the caller should invoke this candidate. The candidate's effort
    /// rides along untouched — no gate reads it.
    static func invocation(for candidate: BrokerCandidate, policy: BrokerPolicy) -> BrokerInvocation {
        switch candidate.route {
        case .native:
            return .agent(
                model: policy.agentModelAliases[candidate.model] ?? candidate.model,
                effort: candidate.effort
            )
        case .codex:
            return .codexExec(model: candidate.model, effort: candidate.effort)
        case .t3:
            return .t3Dispatch(
                model: candidate.model,
                instanceId: policy.resolvedInstance(for: candidate),
                effort: candidate.effort
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
        let ageSeconds = row.lastUpdated.flatMap { BrokerFreshness.age(since: $0, now: now) }
        let stale = row.state != .fresh
            || (ageSeconds.map { $0 > thresholds.stalenessSeconds } ?? true)
        return BrokerOracleBlock(
            present: true,
            stale: stale,
            ageSeconds: ageSeconds,
            session: row.session,
            weekly: row.weekly,
            sonnet: row.sonnet,
            fable: row.fable,
            sessionResetAt: row.sessionResetAt,
            weeklyResetAt: row.weeklyResetAt,
            sonnetResetAt: row.sonnetResetAt,
            fableResetAt: row.fableResetAt,
            chatGPTRows: snapshot.chatGPTRows
        )
    }
}
