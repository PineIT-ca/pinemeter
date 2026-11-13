import Foundation

/// What the Fable campaign pane, the Broker sidebar and the popover card show
/// about the campaign. Derived on every render from values the app already
/// holds; nothing here is persisted and nothing here changes routing.
struct FableCampaignStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case stopped
        /// The overlay is applied until this date.
        case running(until: Date)
        /// A campaign is still saved, but its deadline passed, so the overlay
        /// no longer applies (`FableCampaign.applying` returns the base policy).
        case expired(at: Date)
    }

    /// Broker picks seen while the campaign was running.
    struct Evidence: Equatable, Sendable {
        /// Picks that went to the campaign model.
        let fablePicks: Int
        /// Every pick in the window, whatever model it went to.
        let totalPicks: Int
        let latestRole: String?
        let latestModel: String?
        /// False when the start time is unknown, which happens after a
        /// relaunch into a campaign that is already running: the start time
        /// is runtime-only. The pick list is also runtime-only, so every held
        /// pick was then made under the campaign. A campaign that only starts
        /// running later (an inventory edit revives it) gets a start time
        /// from `AppModel.syncFableCampaign`, so base-rule picks stay out.
        let sinceStart: Bool
    }

    let state: State
    /// Nil unless the campaign is running.
    let evidence: Evidence?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// The date the popover card shows as "on until".
    var runningUntil: Date? {
        if case .running(let until) = state { return until }
        return nil
    }

    init(campaign: FableCampaign?, startedAt: Date?, picks: [RecentPick], now: Date) {
        guard let campaign else {
            state = .stopped
            evidence = nil
            return
        }
        // Same test as `FableCampaign.applying(to:now:)`.
        guard campaign.expiresAt.timeIntervalSince1970.isFinite, now < campaign.expiresAt else {
            state = .expired(at: campaign.expiresAt)
            evidence = nil
            return
        }
        state = .running(until: campaign.expiresAt)
        let window = picks.filter { pick in startedAt.map { pick.timestamp >= $0 } ?? true }
        let latest = window.max { $0.timestamp < $1.timestamp }
        evidence = Evidence(
            fablePicks: window.filter { Self.model(of: $0.candidate) == FableCampaign.model }.count,
            totalPicks: window.count,
            latestRole: latest?.role,
            latestModel: latest.map { Self.model(of: $0.candidate) },
            sinceStart: startedAt != nil
        )
    }

    /// A pick's candidate id is route-prefixed (`t3/claude-fable-5-2`); the
    /// model is its last component.
    static func model(of candidate: String) -> String {
        candidate.split(separator: "/").last.map(String.init) ?? candidate
    }

    /// 2000-01-01 UTC. A deadline at or before it is a placeholder, not a real expiry.
    static let earliestPrintableDeadline = Date(timeIntervalSince1970: 946_684_800)

    static func dateText(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
        style.timeZone = timeZone
        return date.formatted(style.timeZone())
    }

    var headline: String {
        switch state {
        case .stopped: "Stopped"
        case .running: "Running"
        case .expired: "Expired"
        }
    }

    /// The line under the headline.
    func detail(timeZone: TimeZone, locale: Locale) -> String {
        switch state {
        case .stopped:
            "Start puts Fable 5.2 first in every role until the last reset waiver ends."
        case .running(let until):
            "Until \(Self.dateText(until, timeZone: timeZone, locale: locale))"
        case .expired(let at):
            // `syncFableCampaign` saves `.distantPast` when no account is
            // eligible any more; that is not a date worth printing.
            at > Self.earliestPrintableDeadline
                ? "Ended \(Self.dateText(at, timeZone: timeZone, locale: locale)). Routing is back to the base rules."
                : "No eligible resets remain. Routing is back to the base rules."
        }
    }

    /// Nil unless running.
    var pickCountText: String? {
        guard let evidence else { return nil }
        let since = evidence.sinceStart ? "Start" : "Pinemeter launched"
        guard evidence.totalPicks > 0 else { return "No picks yet since \(since)" }
        let picks = evidence.totalPicks == 1 ? "pick" : "picks"
        return "\(evidence.fablePicks) of \(evidence.totalPicks) recent \(picks) went to Fable 5.2 since \(since)"
    }

    /// Nil unless running with at least one pick.
    var latestPickText: String? {
        guard let role = evidence?.latestRole, let model = evidence?.latestModel else { return nil }
        return "Latest pick: \(role), \(model)"
    }
}
