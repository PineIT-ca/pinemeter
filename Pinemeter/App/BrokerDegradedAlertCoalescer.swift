//
//  BrokerDegradedAlertCoalescer.swift
//  Pinemeter
//

import Foundation

/// Collapses a burst of degraded picks into one modal per cause.
///
/// `BrokerService.pick` posts `.brokerDegradedPick` once per degraded
/// decision, and a blocking `NSAlert.runModal()` per post means an outage
/// lasting an hour leaves a stack of identical modals waiting for whoever
/// comes back to the machine. Each one has to be dismissed separately, and
/// none of them says how many there are or what they have in common.
///
/// What it must NOT do is lose a cause. Queuing a modal per pick was noisy,
/// but it did guarantee that a second route failing was eventually seen.
/// Suppressing during a modal without draining afterwards would trade noise
/// for silence, which is the worse failure: nothing reports that the alert
/// never came.
///
/// Kept free of AppKit so the policy is testable: `NSAlert` is only observable
/// through `runModal()`, which no unit test can drive.
@MainActor
final class BrokerDegradedAlertCoalescer {
    struct Presentation: Equatable {
        /// The canonical candidate id this burst is about.
        let candidate: String
        /// The decision that triggered this presentation, for its reason text.
        let decision: BrokerDecision
        /// Picks in this burst, including the ones never shown.
        let count: Int
        /// When the burst started, so the modal can say "since 02:14".
        let firstSeen: Date
        /// Distinct roles and callers affected, sorted for stable text.
        let roles: [String]
        let callers: [String]
    }

    /// How long a cause stays suppressed after its modal is dismissed.
    ///
    /// Not infinite: a provider that is still broken later should say so
    /// again, or an outage that outlives one dismissal goes silent for the
    /// rest of the session.
    private let window: TimeInterval
    private var bursts: [String: Burst] = [:]
    /// The cause whose modal is on screen, `nil` when none is.
    private var presentingKey: String?

    init(window: TimeInterval = 600) {
        self.window = window
    }

    private struct Burst {
        var count: Int
        /// The first pick of THIS burst, `nil` until one arrives. Deliberately
        /// not stamped when a burst is reset: the reset instant is when the
        /// operator was last told, which is not when the next outage started,
        /// and a summary reading "since" the wrong time is worse than none.
        var firstSeen: Date?
        /// When this cause's last modal was DISMISSED, not when it opened.
        ///
        /// Measuring from the opening spends the window while the modal sits
        /// unanswered, so a modal left up overnight has zero suppression left
        /// at dismissal and the very next pick opens an identical one.
        var lastDismissedAt: Date?
        var roles: Set<String>
        var callers: Set<String>
        /// The most recent decision, for the reason text the modal shows.
        var latest: BrokerDecision?
    }

    /// Folds `decision` into its burst and returns what to show, or `nil` when
    /// the operator has already been told or a modal is already up.
    ///
    /// Keyed on the candidate id rather than the reason string on purpose:
    /// reasons embed utilization percentages and timestamps that move between
    /// picks, so string keying would fail to coalesce in exactly the case that
    /// motivated this, the same lane failing over and over.
    func record(_ decision: BrokerDecision, at now: Date) -> Presentation? {
        let key = decision.model
        var burst = bursts[key] ?? Burst(
            count: 0,
            firstSeen: nil,
            lastDismissedAt: nil,
            roles: [],
            callers: [],
            latest: nil
        )
        burst.count += 1
        if burst.firstSeen == nil { burst.firstSeen = now }
        burst.roles.insert(decision.role)
        burst.callers.insert(decision.caller)
        burst.latest = decision
        bursts[key] = burst

        // A modal already owns the screen. Keep counting behind it; whatever
        // accumulates is drained by `didFinishPresenting`, never dropped.
        guard presentingKey == nil else { return nil }
        guard isDue(burst, at: now) else { return nil }
        return beginPresenting(key: key, at: now)
    }

    /// Clears the on-screen modal and returns the next cause waiting to be
    /// shown, or `nil` when nothing is. Call it in a loop until it returns
    /// `nil` so no cause is stranded.
    @discardableResult
    func didFinishPresenting(at now: Date) -> Presentation? {
        if let key = presentingKey, var burst = bursts[key] {
            burst.lastDismissedAt = now
            bursts[key] = burst
        }
        presentingKey = nil

        // Oldest waiting cause first, so the order the operator sees matches
        // the order things broke. Sorting by key breaks ties, because
        // `Dictionary` iteration order is not stable between runs and an
        // arbitrary order would make this untestable.
        let waiting = bursts
            .filter { $0.value.count > 0 && isDue($0.value, at: now) }
            .sorted { lhs, rhs in
                let left = lhs.value.firstSeen ?? now
                let right = rhs.value.firstSeen ?? now
                return left == right ? lhs.key < rhs.key : left < right
            }
        guard let next = waiting.first else { return nil }
        return beginPresenting(key: next.key, at: now)
    }

    /// Releases the modal slot without presenting anything, for the caller's
    /// early-exit paths. Without it, one added `guard` between reserving the
    /// slot and showing the alert would mute every future alert for the life
    /// of the process, silently.
    func abandonPresentingIfNeeded(at now: Date) {
        guard presentingKey != nil else { return }
        didFinishPresenting(at: now)
    }

    /// Whether this cause's suppression window has elapsed.
    private func isDue(_ burst: Burst, at now: Date) -> Bool {
        guard let dismissedAt = burst.lastDismissedAt else { return true }
        return now.timeIntervalSince(dismissedAt) >= window
    }

    /// Reserves the modal slot for `key` and resets its burst.
    ///
    /// The reset keeps `lastDismissedAt` so the window survives, but clears
    /// the count: the next summary reports the next window's scale rather
    /// than a running session total.
    private func beginPresenting(key: String, at now: Date) -> Presentation? {
        guard let burst = bursts[key], let decision = burst.latest else { return nil }
        let presentation = Presentation(
            candidate: key,
            decision: decision,
            count: burst.count,
            firstSeen: burst.firstSeen ?? now,
            roles: burst.roles.sorted(),
            callers: burst.callers.sorted()
        )
        presentingKey = key
        bursts[key] = Burst(
            count: 0,
            firstSeen: nil,
            lastDismissedAt: burst.lastDismissedAt,
            roles: [],
            callers: [],
            latest: decision
        )
        return presentation
    }
}
