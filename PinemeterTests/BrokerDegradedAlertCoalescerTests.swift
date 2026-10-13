//
//  BrokerDegradedAlertCoalescerTests.swift
//  PinemeterTests
//
//  One modal per cause. The reported symptom was ten identical modals waiting
//  after an absence, because every degraded pick posted `.brokerDegradedPick`
//  and `AppDelegate` answered each with its own blocking `runModal()`.
//

import XCTest
@testable import Pinemeter

@MainActor
final class BrokerDegradedAlertCoalescerTests: XCTestCase {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func decision(
        candidate: String = "codex/gpt-6-astra",
        role: String = "heavy",
        caller: String = "codex"
    ) -> BrokerDecision {
        BrokerDecision(
            role: role,
            caller: caller,
            model: candidate,
            route: .codex,
            agentModel: nil,
            invocation: .codexExec(model: "gpt-6-astra"),
            reason: "\(candidate) ChatGPT usage poll is failing (account disconnected); failing open",
            source: .policy,
            oracle: .absent,
            degraded: true,
            degradedReason: "\(candidate) ChatGPT usage poll is failing (account disconnected); failing open",
            retryable: true,
            candidatesTried: []
        )
    }

    // MARK: - Coalescing

    func test_firstPickOfACause_isPresented() {
        let coalescer = BrokerDegradedAlertCoalescer()

        let presentation = coalescer.record(decision(), at: Self.start)

        XCTAssertEqual(presentation?.count, 1)
        XCTAssertEqual(presentation?.candidate, "codex/gpt-6-astra")
    }

    func test_repeatOfTheSameCauseWithinTheWindow_isSwallowed() {
        let coalescer = BrokerDegradedAlertCoalescer()
        _ = coalescer.record(decision(), at: Self.start)
        _ = coalescer.didFinishPresenting(at: Self.start)

        XCTAssertNil(
            coalescer.record(decision(), at: Self.start.addingTimeInterval(30)),
            "the operator already knows; a second identical modal only adds a dismissal"
        )
    }

    func test_aDifferentCandidate_getsItsOwnPresentation() {
        let coalescer = BrokerDegradedAlertCoalescer()
        _ = coalescer.record(decision(), at: Self.start)
        _ = coalescer.didFinishPresenting(at: Self.start)

        let other = coalescer.record(
            decision(candidate: "t3:claudeAgent/claude-opus-5"),
            at: Self.start.addingTimeInterval(30)
        )

        XCTAssertEqual(
            other?.candidate, "t3:claudeAgent/claude-opus-5",
            "a second route failing is new information, not a repeat"
        )
    }

    func test_afterTheWindowElapses_theCauseIsPresentedAgain() {
        let coalescer = BrokerDegradedAlertCoalescer(window: 600)
        _ = coalescer.record(decision(), at: Self.start)
        _ = coalescer.didFinishPresenting(at: Self.start)

        let later = coalescer.record(decision(), at: Self.start.addingTimeInterval(601))

        XCTAssertNotNil(
            later,
            "a still-broken provider must resurface eventually, or a long outage goes silent forever"
        )
    }

    func test_swallowedPicksAreCountedIntoTheNextPresentation() {
        let coalescer = BrokerDegradedAlertCoalescer(window: 600)
        _ = coalescer.record(decision(), at: Self.start)
        _ = coalescer.didFinishPresenting(at: Self.start)
        for offset in stride(from: 30.0, through: 240.0, by: 30.0) {
            _ = coalescer.record(decision(), at: Self.start.addingTimeInterval(offset))
        }

        let later = coalescer.record(decision(), at: Self.start.addingTimeInterval(601))

        XCTAssertEqual(
            later?.count, 9,
            "the summary has to carry the scale of the outage, not just its latest instance"
        )
        XCTAssertEqual(later?.firstSeen, Self.start.addingTimeInterval(30))
    }

    // MARK: - Aggregation

    func test_presentationAggregatesDistinctRolesAndCallers() {
        let coalescer = BrokerDegradedAlertCoalescer(window: 600)
        _ = coalescer.record(decision(role: "heavy", caller: "codex"), at: Self.start)
        _ = coalescer.didFinishPresenting(at: Self.start)
        _ = coalescer.record(decision(role: "review", caller: "claude-code"), at: Self.start.addingTimeInterval(10))
        _ = coalescer.record(decision(role: "heavy", caller: "codex"), at: Self.start.addingTimeInterval(20))

        let later = coalescer.record(decision(role: "heavy", caller: "codex"), at: Self.start.addingTimeInterval(601))

        XCTAssertEqual(later?.roles, ["heavy", "review"], "sorted, so the modal text is stable between runs")
        XCTAssertEqual(later?.callers, ["claude-code", "codex"])
    }

    // MARK: - Presenting guard

    func test_whileAModalIsOpen_nothingElseIsPresented() {
        let coalescer = BrokerDegradedAlertCoalescer()
        _ = coalescer.record(decision(), at: Self.start)

        XCTAssertNil(
            coalescer.record(decision(candidate: "t3:claudeAgent/claude-opus-5"), at: Self.start.addingTimeInterval(5)),
            "runModal blocks the main actor; a second alert would queue behind the first, which is the reported bug"
        )
    }

    func test_aCauseFirstSeenWhileAModalIsOpen_isPresentedOnDismissal() {
        // The regression this guards: before coalescing, a second distinct
        // cause queued its own modal behind the first, so it was always seen.
        // Suppressing it without draining would lose it entirely whenever no
        // agent happens to request that role again.
        let coalescer = BrokerDegradedAlertCoalescer()
        _ = coalescer.record(decision(), at: Self.start)
        for offset in stride(from: 10.0, through: 90.0, by: 10.0) {
            _ = coalescer.record(
                decision(candidate: "t3:claudeAgent/claude-opus-5", role: "review", caller: "claude-code"),
                at: Self.start.addingTimeInterval(offset)
            )
        }

        let drained = coalescer.didFinishPresenting(at: Self.start.addingTimeInterval(3600))

        XCTAssertEqual(drained?.candidate, "t3:claudeAgent/claude-opus-5")
        XCTAssertEqual(drained?.count, 9, "every suppressed pick of that cause still counts")
        XCTAssertEqual(drained?.firstSeen, Self.start.addingTimeInterval(10))
    }

    func test_drainingStopsWhenNoCauseIsWaiting() {
        let coalescer = BrokerDegradedAlertCoalescer()
        _ = coalescer.record(decision(), at: Self.start)

        XCTAssertNil(
            coalescer.didFinishPresenting(at: Self.start.addingTimeInterval(5)),
            "the burst just shown must not immediately re-present itself"
        )
    }

    func test_drainPrefersTheOldestWaitingCause() {
        let coalescer = BrokerDegradedAlertCoalescer()
        _ = coalescer.record(decision(), at: Self.start)
        _ = coalescer.record(decision(candidate: "b/second"), at: Self.start.addingTimeInterval(20))
        _ = coalescer.record(decision(candidate: "a/first"), at: Self.start.addingTimeInterval(10))

        XCTAssertEqual(
            coalescer.didFinishPresenting(at: Self.start.addingTimeInterval(60))?.candidate,
            "a/first",
            "oldest first, so ordering is the outage's, not the dictionary's"
        )
    }

    // MARK: - The suppression window starts at dismissal

    func test_theWindowIsMeasuredFromDismissalNotFromOpening() {
        // A modal sitting unanswered all night must not spend its own
        // suppression window while it is on screen, or dismissing it lets the
        // very next pick open an identical one.
        let coalescer = BrokerDegradedAlertCoalescer(window: 600)
        _ = coalescer.record(decision(), at: Self.start)
        _ = coalescer.didFinishPresenting(at: Self.start.addingTimeInterval(8 * 3600))

        XCTAssertNil(
            coalescer.record(decision(), at: Self.start.addingTimeInterval(8 * 3600 + 3)),
            "three seconds after dismissal is inside the window, however long the modal was open"
        )
    }

    func test_afterDismissal_queuedThenNewCausesAllReachTheOperator() {
        // The guard covers a modal's lifetime only. Everything suppressed
        // during it is drained in order, and once drained a fresh cause
        // presents immediately.
        let coalescer = BrokerDegradedAlertCoalescer()
        _ = coalescer.record(decision(), at: Self.start)
        _ = coalescer.record(decision(candidate: "t3:claudeAgent/claude-opus-5"), at: Self.start.addingTimeInterval(5))

        let drained = coalescer.didFinishPresenting(at: Self.start.addingTimeInterval(8))
        XCTAssertEqual(
            drained?.candidate, "t3:claudeAgent/claude-opus-5",
            "the cause suppressed behind the first modal is shown, not dropped"
        )

        XCTAssertNil(
            coalescer.record(decision(candidate: "native/claude-opus-5"), at: Self.start.addingTimeInterval(9)),
            "the drained modal is itself on screen now, so it holds the slot like any other"
        )

        XCTAssertEqual(
            coalescer.didFinishPresenting(at: Self.start.addingTimeInterval(10))?.candidate,
            "native/claude-opus-5",
            "and the cause that arrived during it is drained in turn; nothing is stranded"
        )
    }
}
