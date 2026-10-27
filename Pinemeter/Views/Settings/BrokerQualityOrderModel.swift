//
//  BrokerQualityOrderModel.swift
//  Pinemeter
//
//  Load state and pure presentation helpers for the "Quality and order"
//  disclosure (SCORE-04, SC5, OD-10). Every formatter, row order, chip
//  choice, summary-line choice and accessibility label the section renders
//  lives in `BrokerQualityOrderPresentation` so it is unit-testable without
//  rendering a single view — the pixel suite does not run on the private
//  Woodpecker lane (docs/ci.md).
//

import Foundation
import Observation

/// Owns exactly what the section needs across a role switch and a reload:
/// the last loaded snapshot, whether a first load has ever completed, and
/// whether that first load failed. A reload after a successful first load
/// never flips back to "loading" or "failed" — it keeps the previous
/// snapshot visible until the next one arrives (UI-SPEC "Data" section).
@MainActor
@Observable
final class BrokerQualityOrderModel {
    private(set) var snapshot: BrokerRoleScoreSnapshot?
    private(set) var hasLoadedOnce: Bool
    private(set) var loadFailed = false

    init(initialSnapshot: BrokerRoleScoreSnapshot? = nil) {
        snapshot = initialSnapshot
        hasLoadedOnce = initialSnapshot != nil
    }

    /// `true` only before the very first load has completed — the section's
    /// one-shot "Loading order…" state.
    var isLoadingFirstTime: Bool { !hasLoadedOnce }

    /// Loads through the injected closure (`AppModel.brokerScoreSnapshot(role:)`
    /// in production). A `nil` result on the first load sets `loadFailed`;
    /// a `nil` result on any later reload is dropped so the section keeps
    /// showing the last good snapshot rather than flashing an error over
    /// data that was working a moment ago.
    func load(role: String, using loader: (String) async -> BrokerRoleScoreSnapshot?) async {
        let result = await loader(role)
        if let result {
            snapshot = result
            loadFailed = false
        } else if !hasLoadedOnce {
            loadFailed = true
        }
        hasLoadedOnce = true
    }

    /// Resets to the pre-load state. Used when the role (and therefore the
    /// snapshot that belongs to it) changes, so a stale snapshot for the
    /// previous role is never shown under the new role's label while the
    /// first load for it is in flight.
    func reset() {
        snapshot = nil
        hasLoadedOnce = false
        loadFailed = false
    }
}

/// Pure formatting, ordering and copy helpers. No view, no state — every
/// function here is a static transform the tests exercise directly.
enum BrokerQualityOrderPresentation {
    // MARK: - Numbers

    /// One decimal place; U+2212 for a negative value; "—" for `nil`
    /// (UI-SPEC "Formatting").
    static func oneDecimal(_ tenths: Int?) -> String {
        guard let tenths else { return "\u{2014}" }
        let magnitude = abs(tenths)
        let whole = magnitude / 10
        let frac = magnitude % 10
        let sign = tenths < 0 ? "\u{2212}" : ""
        return "\(sign)\(whole).\(frac)"
    }

    /// Same value, spoken for accessibility: "unknown" for `nil`, "minus "
    /// instead of U+2212 (UI-SPEC "Accessibility").
    static func spokenNumber(_ tenths: Int?) -> String {
        guard let tenths else { return "unknown" }
        return oneDecimal(tenths).replacingOccurrences(of: "\u{2212}", with: "minus ")
    }

    /// Whole seconds with a narrow no-break space before the unit ("21 s"),
    /// or "—" for `nil`.
    static func latencySeconds(_ seconds: Int?) -> String {
        guard let seconds else { return "\u{2014}" }
        return "\(seconds)\u{202F}s"
    }

    static func spokenLatency(_ seconds: Int?) -> String {
        guard let seconds else { return "unknown" }
        return "\(seconds) seconds"
    }

    /// An order row's score as the section should display it: `nil` (render
    /// "—"/"unknown") for a derived role, regardless of what the row itself
    /// carries, since a derived role has no quality table and its score is
    /// not a real estimate — no synthetic tier number is ever rendered
    /// (UI-SPEC U3, extended to the order block).
    static func orderRowScore(_ score: Int?, isDerived: Bool) -> Int? {
        isDerived ? nil : score
    }

    /// Price level "0" to "4", or "—" when pricing is off (`level == nil`).
    static func priceLevel(_ level: Int?) -> String {
        guard let level else { return "\u{2014}" }
        return "\(level)"
    }

    static func spokenPrice(_ level: Int?) -> String {
        guard let level else { return "unknown" }
        return "\(level)"
    }

    /// "None" when no latency limit is configured, otherwise the seconds
    /// form (UI-SPEC "Limits line labels").
    static func latencyLimitText(_ limit: Int?) -> String {
        guard let limit else { return "None" }
        return latencySeconds(limit)
    }

    // MARK: - Effort label

    /// "Low"/"Medium"/"High"/"XHigh" for a built-in level; the model's own
    /// nil-effort label for `_default`; the raw key, title-cased, for any
    /// other catalog-declared key this build does not otherwise recognise.
    static func effortLabel(_ key: String, model: String, policy: BrokerPolicy) -> String {
        if key == BrokerScoring.defaultEffortKey {
            return BrokerEffort.support(forModel: model, in: policy.models).nilLabel
        }
        if let effort = BrokerEffort(rawValue: key) {
            return effort.displayLabel
        }
        guard let first = key.first else { return key }
        return first.uppercased() + key.dropFirst()
    }

    // MARK: - Chips

    struct Chip: Equatable {
        var text: String
        var tooltip: String
    }

    static let baseChip = Chip(text: "Base", tooltip: "The effort this chain entry sends.")
    static let raiseChip = Chip(
        text: "Raise",
        tooltip: "Pinemeter can send this effort instead when this model's quota would otherwise expire unused."
    )
    static let derivedChip = Chip(
        text: "Derived from chain order",
        tooltip: "Saved before quality tables existed."
    )

    /// One chip per ineligible reason, in the precedence the scoring engine
    /// itself already evaluates in (no estimate, then below floor, then over
    /// the latency limit) — this function only supplies copy, never logic.
    static func ineligibleChip(_ reason: String?) -> Chip? {
        switch reason {
        case "noEstimate":
            return Chip(
                text: "No estimate",
                tooltip: "No quality estimate for this model at this effort. Quota price never moves it ahead."
            )
        case "belowFloor":
            return Chip(
                text: "Below floor",
                tooltip: "Below this role's quality floor. Quota price never moves it ahead."
            )
        case "overLatencyLimit":
            return Chip(
                text: "Over limit",
                tooltip: "Slower than this role's latency limit. Quota price never moves it ahead."
            )
        default:
            return nil
        }
    }

    static let cappedTooltip =
        "Capped at the effective quality of the model above it, so neutral prices keep the chain order."

    /// A base row's effective value is "capped" when it reads lower than its
    /// own quality — the chain above it set a lower ceiling.
    static func isCapped(quality: Int?, effective: Int?) -> Bool {
        guard let quality, let effective else { return false }
        return effective < quality
    }

    // MARK: - Summary line

    /// One of the five fixed summary sentences (UI-SPEC "Copywriting
    /// Contract"), chosen from pricing state and moved count.
    static func summary(pricing: String, moved: Int) -> String {
        switch pricing {
        case "off":
            return "\u{201C}Spend expiring quota first\u{201D} is off, so this is the chain order."
        case "unconfident":
            return "Quota prices are not reliable yet, so this is the chain order."
        default:
            if moved == 0 { return "Same as the chain order." }
            if moved == 1 { return "Quota price moved 1 route." }
            return "Quota price moved \(moved) routes."
        }
    }

    static let gatesNote = "Pinemeter tries these in order and picks the first one with quota left."

    // MARK: - State-machine copy (UI-SPEC "Copywriting Contract" + "State machine")

    static let loadingText = "Loading order\u{2026}"
    static let updatingText = "Updating order\u{2026}"
    static let noRoutesText = "No account or instance can run these models yet. Add one in Instances."
    static let brokerOffTitle = "The broker is off"
    static let brokerOffHint =
        "Turn the broker on with the switch above to see quality estimates and the current order."
    static let loadFailedTitle = "Quality data could not be loaded"
    static let loadFailedHint = "Use Reload order to try again. Routing still works."
    static let derivedNoteText =
        "This role has no quality table. Pinemeter keeps the chain order, and quota price moves "
            + "only models a preset marked as equal in quality."

    // MARK: - Stale guard

    /// `true` when the snapshot's policy chain (`chainModels`, already in
    /// first-occurrence order) is not the exact same ORDERED list as the
    /// chain the editor currently shows — an edit not yet applied to the
    /// broker, including a plain reorder with the same model set. The
    /// current-order block shows "Updating order…" instead of rows until a
    /// matching snapshot arrives.
    static func isStale(snapshot: BrokerRoleScoreSnapshot, visibleChainModels: [String]) -> Bool {
        snapshot.chainModels != visibleChainModels
    }

    // MARK: - Accessibility labels

    static func modelHeaderAccessibilityLabel(model: String, chainRank: Int, hasBaseEstimate: Bool) -> String {
        "\(model), chain rank \(chainRank)" + (hasBaseEstimate ? "" : ", no estimate")
    }

    static func qualityRowAccessibilityLabel(
        effortLabel: String,
        quality: Int?,
        effective: Int?,
        latency: Int?,
        isBase: Bool,
        capped: Bool
    ) -> String {
        var label = "\(effortLabel), quality \(spokenNumber(quality)), effective \(spokenNumber(effective)), "
            + "latency \(spokenLatency(latency)), \(isBase ? "Base" : "Raise")"
        if capped { label += ", capped" }
        return label
    }

    static func orderRowAccessibilityLabel(
        position: Int,
        candidate: String,
        level: Int?,
        score: Int?,
        chipText: String?,
        isDemoted: Bool = false
    ) -> String {
        var label = "Position \(position), \(candidate), price \(spokenPrice(level)), score \(spokenNumber(score))"
        if isDemoted {
            label += ", demoted"
        } else if let chipText {
            label += ", \(chipText)"
        }
        return label
    }

    // MARK: - Order row chip (29-06)

    static let demotedChip = Chip(
        text: "Demoted",
        tooltip: "Model health reports a quality drop for this model, so it moved behind the others "
            + "in this role. It still runs if nothing above it can."
    )

    /// The one chip a Current order row may show. "Demoted" takes precedence
    /// over the ineligible chips (UI-SPEC "Current order rows").
    static func orderRowChip(isDemoted: Bool, reason: String?) -> Chip? {
        isDemoted ? demotedChip : ineligibleChip(reason)
    }

    // MARK: - Model health block copy (29-06, UI-SPEC "Copywriting Contract")

    static let modelHealthTitle = "Model health"
    static let sourcesTitle = "Sources"
    static let modelHealthOffLine =
        "Model health is off, so this order ignores reported quality drops. Turn it on in Quota Ceilings below."
    static let modelHealthNotReceivedLine = "No model health data yet. This order uses the preset alone."
    static let modelHealthSkippedLine =
        "A quality drop is reported for this role, but no other model here qualifies, so the order is unchanged."
    static let demotionColumnHeaders = ["Model", "Until", "Methods"]
    static let sourceColumnHeaders = ["Source", "State", "Newest data"]
    static let sourcesFootnote =
        "The same for every role. Pinemeter reads only this signed summary and never contacts these sources."
    static let modelHealthToggleTitle = "Avoid models with a reported quality drop"
    static let modelHealthToggleDescription =
        "When Pinemeter's signed model health data reports a quality drop for a model, it moves behind "
        + "the others in each affected role until the report expires. Off keeps the normal order."

    enum ModelHealthLine: Equatable {
        case off, notReceived, outOfDate, skipped, demoted(Int), noneInRole
    }

    /// Status-line precedence, first match wins (UI-SPEC "State machine").
    static func modelHealthLine(_ health: BrokerRoleHealthSnapshot) -> ModelHealthLine {
        if !health.useModelHealth { return .off }
        switch health.state {
        case .notReceived: return .notReceived
        case .outOfDate: return .outOfDate
        case .current:
            if health.demotions.isEmpty { return .noneInRole }
            return health.skipped ? .skipped : .demoted(health.demotions.count)
        }
    }

    static func modelHealthStatusLine(_ health: BrokerRoleHealthSnapshot, locale: Locale = .current) -> String {
        switch modelHealthLine(health) {
        case .off:
            return modelHealthOffLine
        case .notReceived:
            return modelHealthNotReceivedLine
        case .outOfDate:
            return "Model health data issued \(relativeIssued(health, locale: locale)) has expired, so no model is "
                + "demoted. This order uses the preset alone. Routing is not affected."
        case .skipped:
            return modelHealthSkippedLine
        case .demoted(let count):
            return count == 1
                ? "1 model in this role runs only after the others until its report expires."
                : "\(count) models in this role run only after the others until their reports expire."
        case .noneInRole:
            return "No model in this role is demoted. Data issued \(relativeIssued(health, locale: locale))."
        }
    }

    private static func relativeIssued(_ health: BrokerRoleHealthSnapshot, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = locale
        return formatter.localizedString(for: health.issuedAt ?? health.generatedAt, relativeTo: health.generatedAt)
    }

    /// The Demotions grid renders only for a current document, with the
    /// opt-out on, and entries to show (UI-SPEC "Model health block").
    static func showsDemotionsGrid(_ health: BrokerRoleHealthSnapshot) -> Bool {
        health.useModelHealth && health.state == .current && !health.demotions.isEmpty
    }

    /// Sources show for any state that holds a document (current, out of
    /// date, and Off with a document) once the document lists sources.
    static func showsSources(_ health: BrokerRoleHealthSnapshot) -> Bool {
        health.state != .notReceived && !health.sources.isEmpty
    }

    // MARK: - Label maps

    static func methodLabel(_ id: String) -> String {
        switch id {
        case "marginlab-cusum": return "Margin Lab trend"
        case "status-incident": return "Provider status"
        case "own-probe-cusum": return "Pinemeter probes"
        default: return "Other method"
        }
    }

    static func methodLabels(_ ids: [String]) -> String {
        ids.map(methodLabel).joined(separator: ", ")
    }

    struct SourceLabel: Equatable {
        var text: String
        /// `true` for an unknown id shown verbatim (rendered monospaced).
        var isVerbatim: Bool
    }

    static func sourceLabel(_ id: String) -> SourceLabel {
        switch id {
        case "marginlab-claude-code": return SourceLabel(text: "Margin Lab, Claude Code", isVerbatim: false)
        case "marginlab-codex": return SourceLabel(text: "Margin Lab, Codex", isVerbatim: false)
        case "status-claude": return SourceLabel(text: "Claude status page", isVerbatim: false)
        case "status-openai": return SourceLabel(text: "OpenAI status page", isVerbatim: false)
        case "probe-signal": return SourceLabel(text: "Pinemeter probes", isVerbatim: false)
        default:
            if id.hasPrefix("aa") { return SourceLabel(text: "Artificial Analysis", isVerbatim: false) }
            return SourceLabel(text: id, isVerbatim: true)
        }
    }

    /// Chip and tooltip for a source state; `nil` for an unknown state (the
    /// row then shows a tertiary dash).
    static func sourceStateChip(_ state: String, staleLimitDays: Int) -> Chip? {
        let limit = staleLimitDays == 1 ? "1-day" : "\(staleLimitDays)-day"
        switch state {
        case "fresh": return Chip(text: "Fresh", tooltip: "Updated within its \(limit) limit.")
        case "stale":
            return Chip(text: "Stale", tooltip: "No new data within its \(limit) limit, so it has no vote.")
        case "broken":
            return Chip(text: "Broken", tooltip: "Its last response could not be read, so it has no vote.")
        case "paused":
            return Chip(text: "Paused", tooltip: "The source is collecting a new baseline, so it has no vote.")
        case "disabled": return Chip(text: "Off", tooltip: "Not used until its terms allow it.")
        default: return nil
        }
    }

    // MARK: - Dates

    /// "Oct 16, 6:00 AM" in the injected time zone and locale.
    static func untilText(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = timeZone
        day.setLocalizedDateFormatFromTemplate("MMMd")
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")
        return "\(day.string(from: date)), \(plainSpaces(time.string(from: date)))"
    }

    /// Recent ICU releases put U+202F before the day period; a plain space
    /// keeps the text identical across macOS versions.
    private static func plainSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// Full date and time for the spoken demotion row.
    static func spokenUntil(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return plainSpaces(formatter.string(from: date))
    }

    /// "Sep 29", or "—" when absent. The value is a calendar day anchored at
    /// UTC midnight by the snapshot, so it formats in UTC whatever zone the
    /// Mac uses; a local zone west of UTC would otherwise show the day before.
    static func newestDataText(_ date: Date?, locale: Locale = .current) -> String {
        guard let date else { return "\u{2014}" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    // MARK: - Model health accessibility labels

    static func demotionAccessibilityLabel(
        _ demotion: BrokerRoleHealthSnapshot.Demotion, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        "\(demotion.model), demoted until \(spokenUntil(demotion.expiresAt, timeZone: timeZone, locale: locale)), "
            + "methods \(methodLabels(demotion.methods))"
    }

    static func sourceAccessibilityLabel(_ source: BrokerRoleHealthSnapshot.Source, locale: Locale = .current) -> String {
        let chip = sourceStateChip(source.state, staleLimitDays: source.staleLimitDays)?.text ?? "unknown state"
        let date = source.newestDataDate == nil ? "unknown" : newestDataText(source.newestDataDate, locale: locale)
        return "\(sourceLabel(source.id).text), \(chip), newest data \(date)"
    }
}
