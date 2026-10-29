//
//  BrokerRoleScoreSnapshot.swift
//  Pinemeter
//
//  View-facing snapshot of one role's quality table and current effective
//  order (SCORE-04, SC5, OD-10). Built from `BrokerScoredRole`, the exact
//  rows `BrokerEngine.decide` walks through `BrokerPoolPricing.pricedOrder`
//  (`BrokerScoringEngine.scoredOrder`/`scoredRows`) — this type never ranks
//  anything itself, it only reshapes already-ranked rows plus the policy's
//  raw per-effort quality/latency table for display.
//

import Foundation

/// Portable, Settings-view-facing snapshot for one role. `BrokerService`
/// builds it from the same policy, oracle and demand snapshots `pick` uses
/// (`BrokerService.scoreSnapshot(role:)`); the view never recomputes an
/// order.
struct BrokerRoleScoreSnapshot: Sendable, Equatable {
    /// One effort row inside a model's quality table block.
    struct QualityRow: Sendable, Equatable {
        var effortKey: String
        var quality: Int?
        /// Set only on the model's base (chain) row; `nil` on every raise row.
        var effective: Int?
        var latency: Int?
        var isBase: Bool
    }

    /// One model's quality table, in the fixed effort-row order (UI-SPEC
    /// "Quality table block"): low, medium, high, xhigh, then the model's
    /// other declared levels, then any other key, then `_default` last.
    struct ModelTable: Sendable, Equatable {
        var model: String
        /// This model's rank in the role's chain, counting only its first
        /// occurrence — matches the badge shown on its header row.
        var chainRank: Int
        var hasBaseEstimate: Bool
        var rows: [QualityRow]
    }

    /// One row in the current-order grid — one per scored (ranked) candidate,
    /// in the exact order `pick` would walk.
    struct OrderRow: Sendable, Equatable {
        var position: Int
        var candidate: String
        var model: String
        var level: Int?
        var score: Int?
        /// One of `noEstimate`, `belowFloor`, `overLatencyLimit`, or `nil`
        /// when the row is eligible.
        var ineligibleReason: String?
        /// `true` when the model health partition moved this route behind
        /// the others (the same `BrokerDemotion.apply` `decide` runs).
        var isDemoted: Bool = false
    }

    var role: String
    var isDerived: Bool
    var floor: Int?
    var latencyLimit: Int?
    /// `off`, `unconfident` or `active` (`BrokerScoredRole.pricing`).
    var pricing: String
    /// Distinct models in the POLICY chain (`policy.roles[resolvedRole]`),
    /// first-occurrence order — the chain the snapshot was scored FROM, not
    /// the expanded/route-filtered rows `scored.rows` holds.
    /// `expandingModelChoices` silently drops any `auto/<model>` entry that
    /// has no agent alias, no ChatGPT lane and no T3 instance reporting the
    /// model, so a model like that never appears in `scored.rows` at all.
    /// Building this list from the scored rows would then never contain
    /// that model, so the view's stale guard below would never match the
    /// editor's (unexpanded) chain and would render "Updating order…"
    /// forever for a chain that is not stale — it just has one unrouted
    /// model. Used by the view's stale guard: when this ordered list
    /// differs from the chain the editor currently shows, the order block
    /// renders "Updating order…" instead of rows.
    var chainModels: [String]
    /// Empty for a derived role (no explicit quality table exists).
    var modelTables: [ModelTable]
    var orderRows: [OrderRow]
    /// Order rows whose position differs from their neutral position.
    var moved: Int
    /// Signed model health as the engine saw it for this role at snapshot time.
    var health: BrokerRoleHealthSnapshot

    init(
        scored: BrokerScoredRole,
        policy: BrokerPolicy,
        health: BrokerRoleHealthSnapshot = .notReceived(useModelHealth: true, generatedAt: .distantPast)
    ) {
        self.health = health
        role = scored.role
        isDerived = scored.derived
        floor = scored.floor
        latencyLimit = scored.latencyLimit
        pricing = scored.pricing

        let neutralOrder = scored.rows.sorted { $0.neutralPosition < $1.neutralPosition }
        var seen = Set<String>()
        var modelsInChainOrder: [String] = []
        // `quality`/`effective`/`latency` on every row of one model are
        // identical regardless of which row we pick: `scoredRows` derives
        // all three from `baseKeys(role:policy:)` (the model's chain-base
        // effort), never from the row's own candidate effort. So any row
        // for the model carries the right numbers — only the effort KEY
        // that should be marked `isBase` (below) depends on the policy
        // chain's first occurrence, not on which row ranked first.
        var baseRowByModel: [String: BrokerScoredRole.Row] = [:]
        for row in neutralOrder where !seen.contains(row.model) {
            seen.insert(row.model)
            modelsInChainOrder.append(row.model)
            baseRowByModel[row.model] = row
        }

        // See the `chainModels` doc comment: this must be the raw policy
        // chain's model set, not `modelsInChainOrder` above (which only
        // holds models that survived route expansion).
        var seenChain = Set<String>()
        var chainModelsInOrder: [String] = []
        for candidate in policy.roles[role] ?? [] where !seenChain.contains(candidate.model) {
            seenChain.insert(candidate.model)
            chainModelsInOrder.append(candidate.model)
        }
        chainModels = chainModelsInOrder

        // The engine (`BrokerScoringEngine.baseKeys`) picks a model's base
        // (chain) effort from its first occurrence in the POLICY chain, not
        // from the first row this model has after headroom ranking —
        // reusing the engine's own lookup keeps the "Base" row this table
        // marks in sync with the effort `pick` actually treats as the base.
        let policyBaseKeys = BrokerScoringEngine.baseKeys(role: role, policy: policy)

        if isDerived {
            modelTables = []
        } else {
            let table = policy.scoring.role(scored.role)
            modelTables = modelsInChainOrder.enumerated().map { index, model in
                let baseRow = baseRowByModel[model]
                let qualityKey = baseRow.flatMap { BrokerCandidate(id: $0.candidate) }
                    .map { BrokerScoringEngine.qualityKey($0) } ?? model
                let baseKey = policyBaseKeys[qualityKey] ?? BrokerScoring.defaultEffortKey
                let keys = Set((table?.quality[qualityKey] ?? [:]).keys)
                let orderedKeys = Self.effortOrder(keys: keys, model: model, policy: policy)
                let rows: [QualityRow] = orderedKeys.map { key in
                    guard key == baseKey else {
                        return QualityRow(
                            effortKey: key,
                            quality: table?.quality[qualityKey]?[key],
                            effective: nil,
                            latency: policy.scoring.latency[model]?[key],
                            isBase: false
                        )
                    }
                    return QualityRow(
                        effortKey: key,
                        quality: baseRow?.quality,
                        effective: baseRow?.effective,
                        latency: baseRow?.latency,
                        isBase: true
                    )
                }
                return ModelTable(
                    model: model,
                    chainRank: index + 1,
                    hasBaseEstimate: baseRow?.quality != nil,
                    rows: rows
                )
            }
        }

        orderRows = scored.rows.map { row in
            OrderRow(
                position: row.position,
                candidate: row.candidate,
                model: row.model,
                level: row.level,
                score: row.score,
                ineligibleReason: row.eligible ? nil : row.reason
            )
        }
        // Counts routes quota price pulled ahead of their neutral slot, not
        // every row a single swap displaces: a plain two-way swap moves one
        // route ahead of the other, so this reads "moved 1 route", matching
        // the UI-SPEC summary copy, rather than "moved 2" for the same swap.
        moved = scored.rows.filter { $0.position < $0.neutralPosition }.count
    }

    /// Reorders the order rows into the demotion partition's order and flags
    /// the routes it moved. `order` lists candidate ids in the partitioned
    /// order; `demotedIds` are the ids the partition moved. `moved` is left
    /// untouched: it counts pricing moves only (UI-SPEC U8).
    mutating func applyDemotionPartition(order: [String], demotedIds: Set<String>) {
        var remaining = orderRows
        var next: [OrderRow] = []
        for id in order {
            guard let index = remaining.firstIndex(where: { $0.candidate == id }) else { continue }
            next.append(remaining.remove(at: index))
        }
        next.append(contentsOf: remaining)
        orderRows = next.enumerated().map { index, row in
            var row = row
            row.position = index + 1
            row.isDemoted = demotedIds.contains(row.candidate)
            return row
        }
    }

    /// Effort-row order for one model's quality table (UI-SPEC "Quality
    /// table block"): built-in levels present in `keys`, then the model's
    /// other catalog-declared levels in declared order, then any remaining
    /// key in UTF-8 byte order, then `_default` last.
    static func effortOrder(keys: Set<String>, model: String, policy: BrokerPolicy) -> [String] {
        guard !keys.isEmpty else { return [] }
        var ordered: [String] = []
        for level in BrokerEffort.builtInLevels where keys.contains(level.rawValue) {
            ordered.append(level.rawValue)
        }
        let support = BrokerEffort.support(forModel: model, in: policy.models)
        for level in support.selectableLevels
        where keys.contains(level.rawValue) && !ordered.contains(level.rawValue) {
            ordered.append(level.rawValue)
        }
        let known = Set(ordered)
        let remaining = keys.subtracting(known).subtracting([BrokerScoring.defaultEffortKey])
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        ordered.append(contentsOf: remaining)
        if keys.contains(BrokerScoring.defaultEffortKey) {
            ordered.append(BrokerScoring.defaultEffortKey)
        }
        return ordered
    }
}

/// One role's view of the signed model health document (29-06, UI-SPEC "Data
/// for the health block"). Built by `BrokerService` from the same health
/// state, policy and clock reading `decide` uses; the view never filters by
/// time or role and never reorders.
struct BrokerRoleHealthSnapshot: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case notReceived
        case outOfDate
        case current
    }

    struct Demotion: Sendable, Equatable {
        var model: String
        var expiresAt: Date
        var methods: [String]
    }

    struct Source: Sendable, Equatable {
        var id: String
        var state: String
        /// Calendar day of the newest data, anchored at UTC midnight.
        var newestDataDate: Date?
        var staleLimitDays: Int
    }

    var state: State
    var useModelHealth: Bool
    var generatedAt: Date
    var issuedAt: Date?
    var validUntil: Date?
    /// This role's active demotions in document order.
    var demotions: [Demotion]
    /// The role-safety rule kept the order unchanged for this role.
    var skipped: Bool
    var sources: [Source]
    var attribution: [String]

    static func notReceived(useModelHealth: Bool, generatedAt: Date) -> BrokerRoleHealthSnapshot {
        BrokerRoleHealthSnapshot(
            state: .notReceived, useModelHealth: useModelHealth, generatedAt: generatedAt,
            issuedAt: nil, validUntil: nil, demotions: [], skipped: false, sources: [], attribution: []
        )
    }

    /// Derives the snapshot from the status the broker already reports.
    /// `resolvedRole` is the policy-resolved role the order was scored for.
    init(status: BrokerHealthStatus, resolvedRole: String, policy: BrokerPolicy, skipped: Bool, now: Date) {
        if !status.present {
            state = .notReceived
        } else if status.expired == true {
            state = .outOfDate
        } else {
            state = .current
        }
        useModelHealth = status.useModelHealth
        generatedAt = now
        issuedAt = status.issuedAt
        validUntil = status.validUntil
        // Same role test as `BrokerDemotion.apply`: an empty list means every role.
        let role = policy.resolveRole(resolvedRole)
        demotions = status.demotions.filter { $0.roles.isEmpty || $0.roles.contains(role) }.map { Demotion(model: $0.model, expiresAt: $0.expiresAt, methods: $0.methods) }
        self.skipped = skipped
        sources = status.sources.map {
            Source(
                id: $0.id, state: $0.state,
                newestDataDate: $0.newestDataDate.flatMap { BrokerHealthDocument.parseTime($0 + "T00:00:00Z") },
                staleLimitDays: $0.staleLimitDays
            )
        }
        attribution = status.attribution ?? []
    }

    init(
        state: State, useModelHealth: Bool, generatedAt: Date, issuedAt: Date?, validUntil: Date?,
        demotions: [Demotion], skipped: Bool, sources: [Source], attribution: [String]
    ) {
        self.state = state
        self.useModelHealth = useModelHealth
        self.generatedAt = generatedAt
        self.issuedAt = issuedAt
        self.validUntil = validUntil
        self.demotions = demotions
        self.skipped = skipped
        self.sources = sources
        self.attribution = attribution
    }
}
