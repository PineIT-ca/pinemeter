//
//  BrokerDecision.swift
//  Pinemeter
//
//  The decision JSON returned by the `pick` MCP tool.
//
//  WARNING: the encoded field names here are a wire contract. Consumers
//  pattern-match `route`, `model`, `degraded`, `invocation.kind` and the
//  `caller` echo. Renaming a key is a breaking change for every consumer.
//  `effort` is the one optional, additive key: it is encoded (at top level and
//  inside `invocation`) only when the winning candidate recommends one, so a
//  consumer that ignores it sees exactly the key set it saw before.
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

    init(
        present: Bool,
        stale: Bool,
        ageSeconds: Double? = nil,
        session: Double? = nil,
        weekly: Double? = nil,
        sonnet: Double? = nil,
        fable: Double? = nil
    ) {
        self.present = present
        self.stale = stale
        self.ageSeconds = ageSeconds
        self.session = session
        self.weekly = weekly
        self.sonnet = sonnet
        self.fable = fable
    }

    /// No quota data was available to the engine.
    static let absent = BrokerOracleBlock(present: false, stale: false)

    private enum CodingKeys: String, CodingKey {
        case present, stale, ageSeconds, session, weekly, sonnet, fable
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
    }
}

/// The result of `BrokerEngine.decide`, serialized as the `pick` tool result.
struct BrokerDecision: Codable, Equatable, Sendable {
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
    let candidatesTried: [BrokerCandidateTried]
    /// The winning candidate's recommended reasoning effort. Encoded only when
    /// present — an absent key means the provider default, never a level.
    let effort: BrokerEffort?

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
        candidatesTried: [BrokerCandidateTried],
        effort: BrokerEffort? = nil
    ) {
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
        self.candidatesTried = candidatesTried
        self.effort = effort
    }

    private enum CodingKeys: String, CodingKey {
        case role, caller, model, route, agentModel, invocation
        case reason, source, oracle, degraded, candidatesTried, effort
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
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
        try container.encode(candidatesTried, forKey: .candidatesTried)
        try container.encodeIfPresent(effort, forKey: .effort)
    }
}

extension BrokerDecision {
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
