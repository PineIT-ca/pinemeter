//
//  BrokerDecision.swift
//  Pinemeter
//
//  The decision JSON returned by the `pick` MCP tool.
//
//  WARNING: the encoded field names here are a wire contract. Consumers
//  pattern-match `route`, `model`, `degraded`, `invocation.kind` and the
//  `caller` echo. Renaming a key is a breaking change for every consumer.
//  `effort` and `decision_id` are optional additive keys. A legacy decoded
//  decision keeps a nil identity; BrokerService assigns every new pick one.
//

import Foundation

/// How a decision was reached.
enum BrokerDecisionSource: String, Codable, Equatable, Sendable {
    /// A candidate passed every gate.
    case policy
    /// No candidate had headroom; the top invocable candidate was forced.
    case forcedDegraded = "forced-degraded"
}

/// How the caller should actually invoke the picked model.
///
/// `effort` is metadata the lane forwards (e.g. `t3-dispatch --effort`); `nil`
/// means the provider default, so the caller sends no effort at all.
enum BrokerInvocation: Codable, Equatable, Sendable {
    /// Native subagent: spawn an Agent with this model alias.
    case agent(model: String, effort: BrokerEffort? = nil)
    /// Headless Codex CLI lane.
    case codexExec(model: String, effort: BrokerEffort? = nil)
    /// A visible thread in the T3 desktop app, on a named provider instance.
    case t3Dispatch(model: String, instanceId: String, effort: BrokerEffort? = nil)

    var kind: String {
        switch self {
        case .agent: return "agent"
        case .codexExec: return "codex-exec"
        case .t3Dispatch: return "t3-dispatch"
        }
    }

    var command: String? {
        switch self {
        case .agent: return nil
        case .codexExec: return "/codex-exec"
        case .t3Dispatch: return "/t3-dispatch"
        }
    }

    var model: String {
        switch self {
        case .agent(let model, _): return model
        case .codexExec(let model, _): return model
        case .t3Dispatch(let model, _, _): return model
        }
    }

    var effort: BrokerEffort? {
        switch self {
        case .agent(_, let effort): return effort
        case .codexExec(_, let effort): return effort
        case .t3Dispatch(_, _, let effort): return effort
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case command
        case model
        case instanceId
        case effort
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if let command { try container.encode(command, forKey: .command) }
        try container.encode(model, forKey: .model)
        if case .t3Dispatch(_, let instanceId, _) = self {
            try container.encode(instanceId, forKey: .instanceId)
        }
        try container.encodeIfPresent(effort, forKey: .effort)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let model = try container.decode(String.self, forKey: .model)
        let effort = try container.decodeIfPresent(BrokerEffort.self, forKey: .effort)
        switch kind {
        case "agent":
            self = .agent(model: model, effort: effort)
        case "codex-exec":
            self = .codexExec(model: model, effort: effort)
        case "t3-dispatch":
            let instanceId = try container.decode(String.self, forKey: .instanceId)
            self = .t3Dispatch(model: model, instanceId: instanceId, effort: effort)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown invocation kind '\(kind)'"
            )
        }
    }
}

/// One entry of the audit trail explaining why a candidate was or was not chosen.
struct BrokerCandidateTried: Codable, Equatable, Sendable {
    let candidate: String
    let available: Bool
    /// True when the candidate was removed by a structural caller filter
    /// (never a quota event). Encoded only when true, matching the reference.
    let callerFiltered: Bool
    let why: String

    init(candidate: String, available: Bool, callerFiltered: Bool = false, why: String) {
        self.candidate = candidate
        self.available = available
        self.callerFiltered = callerFiltered
        self.why = why
    }

    private enum CodingKeys: String, CodingKey {
        case candidate
        case available
        case callerFiltered
        case why
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(candidate, forKey: .candidate)
        try container.encode(available, forKey: .available)
        if callerFiltered { try container.encode(true, forKey: .callerFiltered) }
        try container.encode(why, forKey: .why)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidate = try container.decode(String.self, forKey: .candidate)
        available = try container.decode(Bool.self, forKey: .available)
        callerFiltered = try container.decodeIfPresent(Bool.self, forKey: .callerFiltered) ?? false
        why = try container.decode(String.self, forKey: .why)
    }
}

/// A ranked fallback the caller may dispatch without a new `pick` call, when
/// the winning invocation fails. Carries the same invocation payload shape as
/// the primary decision, so a caller can act on it directly — see
/// ``BrokerEngine/collectBackups(candidates:winner:filter:policy:oracle:block:cooldowns:now:t3:quotaBlindExpansions:)``
/// for how the ranking is built. Wire key `backups` on the decision: always
/// present, possibly empty, capped at ``BrokerDecision/maxBackups``.
struct BrokerBackupOption: Codable, Equatable, Sendable {
    /// The candidate's canonical id (`<route>[:<instance>]/<model>`), same
    /// form as ``BrokerCandidateTried/candidate``.
    let candidate: String
    let route: BrokerPolicy.Route
    /// The raw model slug, matching what `candidate` embeds — not the agent
    /// alias `invocation.model` may carry for a native pick.
    let model: String
    /// Recommended reasoning effort, or `nil` for the provider default.
    let effort: BrokerEffort?
    /// How the caller should invoke this backup — identical shape to the
    /// primary decision's `invocation`.
    let invocation: BrokerInvocation
    /// Short ranking rationale, e.g. "next in chain", "headroom unverified: …",
    /// or "gated: …" for a quota-capped or cooldown-blocked last resort.
    let why: String

    init(
        candidate: String,
        route: BrokerPolicy.Route,
        model: String,
        effort: BrokerEffort? = nil,
        invocation: BrokerInvocation,
        why: String
    ) {
        self.candidate = candidate
        self.route = route
        self.model = model
        self.effort = effort
        self.invocation = invocation
        self.why = why
    }

    private enum CodingKeys: String, CodingKey {
        case candidate
        case route
        case model
        case effort
        case invocation
        case why
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(candidate, forKey: .candidate)
        try container.encode(route, forKey: .route)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encode(invocation, forKey: .invocation)
        try container.encode(why, forKey: .why)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidate = try container.decode(String.self, forKey: .candidate)
        route = try container.decode(BrokerPolicy.Route.self, forKey: .route)
        model = try container.decode(String.self, forKey: .model)
        effort = try container.decodeIfPresent(BrokerEffort.self, forKey: .effort)
        invocation = try container.decode(BrokerInvocation.self, forKey: .invocation)
        why = try container.decode(String.self, forKey: .why)
    }
}

/// The quota oracle state the decision was made against. Always emitted (with
/// `present: false` when no oracle was available) so the key set is stable.
struct BrokerOracleBlock: Codable, Equatable, Sendable {
    let present: Bool
    let stale: Bool
    let ageSeconds: Double?
    let session: Double?
    let weekly: Double?
    let sonnet: Double?
    let fable: Double?
    let sessionResetAt: Date?
    let weeklyResetAt: Date?
    let sonnetResetAt: Date?
    let fableResetAt: Date?
    let chatGPTRows: [OracleSnapshot.ChatGPTRow]

    init(
        present: Bool,
        stale: Bool,
        ageSeconds: Double? = nil,
        session: Double? = nil,
        weekly: Double? = nil,
        sonnet: Double? = nil,
        fable: Double? = nil,
        sessionResetAt: Date? = nil,
        weeklyResetAt: Date? = nil,
        sonnetResetAt: Date? = nil,
        fableResetAt: Date? = nil,
        chatGPTRows: [OracleSnapshot.ChatGPTRow] = []
    ) {
        self.present = present
        self.stale = stale
        self.ageSeconds = ageSeconds
        self.session = session
        self.weekly = weekly
        self.sonnet = sonnet
        self.fable = fable
        self.sessionResetAt = sessionResetAt
        self.weeklyResetAt = weeklyResetAt
        self.sonnetResetAt = sonnetResetAt
        self.fableResetAt = fableResetAt
        self.chatGPTRows = Array(chatGPTRows.prefix(OracleSnapshot.maxChatGPTRows))
    }

    /// No quota data was available to the engine.
    static let absent = BrokerOracleBlock(present: false, stale: false)

    private enum CodingKeys: String, CodingKey {
        case present, stale, ageSeconds, session, weekly, sonnet, fable
        case sessionResetAt, weeklyResetAt, sonnetResetAt, fableResetAt, chatGPTRows
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(present, forKey: .present)
        try container.encode(stale, forKey: .stale)
        try container.encode(ageSeconds, forKey: .ageSeconds)
        try container.encode(session, forKey: .session)
        try container.encode(weekly, forKey: .weekly)
        try container.encode(sonnet, forKey: .sonnet)
        try container.encode(fable, forKey: .fable)
        try container.encode(sessionResetAt, forKey: .sessionResetAt)
        try container.encode(weeklyResetAt, forKey: .weeklyResetAt)
        try container.encode(sonnetResetAt, forKey: .sonnetResetAt)
        try container.encode(fableResetAt, forKey: .fableResetAt)
        try container.encode(chatGPTRows, forKey: .chatGPTRows)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        present = try container.decode(Bool.self, forKey: .present)
        stale = try container.decode(Bool.self, forKey: .stale)
        ageSeconds = try container.decodeIfPresent(Double.self, forKey: .ageSeconds)
        session = try container.decodeIfPresent(Double.self, forKey: .session)
        weekly = try container.decodeIfPresent(Double.self, forKey: .weekly)
        sonnet = try container.decodeIfPresent(Double.self, forKey: .sonnet)
        fable = try container.decodeIfPresent(Double.self, forKey: .fable)
        sessionResetAt = try container.decodeIfPresent(Date.self, forKey: .sessionResetAt)
        weeklyResetAt = try container.decodeIfPresent(Date.self, forKey: .weeklyResetAt)
        sonnetResetAt = try container.decodeIfPresent(Date.self, forKey: .sonnetResetAt)
        fableResetAt = try container.decodeIfPresent(Date.self, forKey: .fableResetAt)
        chatGPTRows = Array(
            (try container.decodeIfPresent([OracleSnapshot.ChatGPTRow].self, forKey: .chatGPTRows) ?? [])
                .prefix(OracleSnapshot.maxChatGPTRows)
        )
    }
}

/// The result of `BrokerEngine.decide`, serialized as the `pick` tool result.
struct BrokerDecision: Codable, Equatable, Sendable {
    let decisionID: String?
    let role: String
    /// The caller this decision was filtered for. Always echoed back — clients
    /// MUST verify the echo, because an older build silently ignores the param.
    let caller: String
    /// The winning candidate's canonical id (`<route>[:<instance>]/<model>`).
    let model: String
    let route: BrokerPolicy.Route
    /// Agent alias for native picks (`fable`, `opus`, …); nil for other routes.
    let agentModel: String?
    let invocation: BrokerInvocation
    let reason: String
    let source: BrokerDecisionSource
    let oracle: BrokerOracleBlock
    let degraded: Bool
    /// Present only on degraded picks. This is the exact reason the caller
    /// must render before asking the user whether to proceed.
    let degradedReason: String?
    /// Present only on degraded picks. `true` means a refresh and re-pick may
    /// recover a trustworthy route; `false` means the cause is hard.
    let retryable: Bool?
    /// Present only when the degraded pick is retryable.
    let suggestedAction: String?
    let candidatesTried: [BrokerCandidateTried]
    /// The winning candidate's recommended reasoning effort. Encoded only when
    /// present — an absent key means the provider default, never a level.
    let effort: BrokerEffort?
    /// Ranked fallbacks the caller may dispatch without a new `pick` call, if
    /// the winning invocation fails. Always encoded, even when empty, so the
    /// key set is stable; capped at ``maxBackups``.
    let backups: [BrokerBackupOption]

    /// Wire cap on `backups`, both on construction and on decode.
    static let maxBackups = 2

    init(
        role: String,
        caller: String,
        model: String,
        route: BrokerPolicy.Route,
        agentModel: String?,
        invocation: BrokerInvocation,
        reason: String,
        source: BrokerDecisionSource,
        oracle: BrokerOracleBlock,
        degraded: Bool,
        degradedReason: String? = nil,
        retryable: Bool? = nil,
        suggestedAction: String? = nil,
        candidatesTried: [BrokerCandidateTried],
        effort: BrokerEffort? = nil,
        backups: [BrokerBackupOption] = [],
        decisionID: String? = nil
    ) {
        self.decisionID = decisionID
        self.role = role
        self.caller = caller
        self.model = model
        self.route = route
        self.agentModel = agentModel
        self.invocation = invocation
        self.reason = reason
        self.source = source
        self.oracle = oracle
        self.degraded = degraded
        self.degradedReason = degraded ? degradedReason ?? reason : nil
        self.retryable = degraded ? retryable ?? false : nil
        self.suggestedAction = degraded && retryable == true
            ? suggestedAction ?? Self.refreshAndRepickAction
            : nil
        self.candidatesTried = candidatesTried
        self.effort = effort
        self.backups = Array(backups.prefix(BrokerDecision.maxBackups))
    }

    private enum CodingKeys: String, CodingKey {
        case decisionID = "decision_id"
        case role, caller, model, route, agentModel, invocation
        case reason, source, oracle, degraded, degradedReason = "degraded_reason"
        case retryable, suggestedAction = "suggested_action", candidatesTried, effort, backups
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(decisionID, forKey: .decisionID)
        try container.encode(role, forKey: .role)
        try container.encode(caller, forKey: .caller)
        try container.encode(model, forKey: .model)
        try container.encode(route, forKey: .route)
        try container.encode(agentModel, forKey: .agentModel)
        try container.encode(invocation, forKey: .invocation)
        try container.encode(reason, forKey: .reason)
        try container.encode(source, forKey: .source)
        try container.encode(oracle, forKey: .oracle)
        try container.encode(degraded, forKey: .degraded)
        if degraded {
            try container.encode(degradedReason, forKey: .degradedReason)
            try container.encode(retryable, forKey: .retryable)
            if let suggestedAction { try container.encode(suggestedAction, forKey: .suggestedAction) }
        }
        try container.encode(candidatesTried, forKey: .candidatesTried)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encode(backups, forKey: .backups)
    }

    // `backups` is additive: a decision decoded from a build that predates it
    // (a legacy audit record, a cached decision JSON) carries no such key, and
    // must decode to an empty list rather than fail the whole decision.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decisionID = try container.decodeIfPresent(String.self, forKey: .decisionID)
        role = try container.decode(String.self, forKey: .role)
        caller = try container.decode(String.self, forKey: .caller)
        model = try container.decode(String.self, forKey: .model)
        route = try container.decode(BrokerPolicy.Route.self, forKey: .route)
        agentModel = try container.decodeIfPresent(String.self, forKey: .agentModel)
        invocation = try container.decode(BrokerInvocation.self, forKey: .invocation)
        reason = try container.decode(String.self, forKey: .reason)
        source = try container.decode(BrokerDecisionSource.self, forKey: .source)
        oracle = try container.decode(BrokerOracleBlock.self, forKey: .oracle)
        degraded = try container.decode(Bool.self, forKey: .degraded)
        degradedReason = degraded ? try container.decodeIfPresent(String.self, forKey: .degradedReason) ?? reason : nil
        retryable = degraded ? try container.decodeIfPresent(Bool.self, forKey: .retryable) ?? false : nil
        suggestedAction = degraded && retryable == true
            ? try container.decodeIfPresent(String.self, forKey: .suggestedAction) ?? Self.refreshAndRepickAction
            : nil
        candidatesTried = try container.decode([BrokerCandidateTried].self, forKey: .candidatesTried)
        effort = try container.decodeIfPresent(BrokerEffort.self, forKey: .effort)
        backups = Array(
            (try container.decodeIfPresent([BrokerBackupOption].self, forKey: .backups) ?? [])
                .prefix(BrokerDecision.maxBackups)
        )
    }
}

extension BrokerDecision {
    static let refreshAndRepickAction = "Call refresh, then call pick again with the same role and caller. Staleness usually clears within minutes."
}

extension BrokerDecision {
    func attachingDecisionID(_ decisionID: String) -> BrokerDecision {
        BrokerDecision(
            role: role,
            caller: caller,
            model: model,
            route: route,
            agentModel: agentModel,
            invocation: invocation,
            reason: reason,
            source: source,
            oracle: oracle,
            degraded: degraded,
            degradedReason: degradedReason,
            retryable: retryable,
            suggestedAction: suggestedAction,
            candidatesTried: candidatesTried,
            effort: effort,
            backups: backups,
            decisionID: decisionID
        )
    }

    /// Encoder used for the wire form. Slashes stay unescaped so candidate ids
    /// and slash commands read normally in tool output.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// The decision as the JSON string returned in the `pick` tool result.
    func jsonString() throws -> String {
        let data = try BrokerDecision.makeEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
