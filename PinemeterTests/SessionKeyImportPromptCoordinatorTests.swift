//
//  SessionKeyImportPromptCoordinatorTests.swift
//  PinemeterTests
//
//  Pins the single-prompt-at-a-time guard that replaced the coordinator's
//  old `NSLock`. The lock was an ABBA deadlock: a background Keychain-
//  context prompt could hold it while blocked inside `DispatchQueue.main
//  .sync` waiting for the main thread, and a reentrant main-thread call
//  (e.g. the degraded-pick alert's "Reconnect" action, triggered while that
//  modal pumps the run loop) blocking on the same lock would mean neither
//  side could ever finish. The guard this suite exercises is what
//  `present(onMainThread:)` actually calls -- no lock, no AppKit, no modal,
//  so it is directly testable (review fix, quick task 261001-ckk).
//

import XCTest
@testable import Pinemeter

@MainActor
final class SessionKeyImportPromptCoordinatorTests: XCTestCase {
    override func tearDown() {
        // Never leave `isPresenting` true for a later test: it is coordinator-
        // wide static state, so a leaked `true` would silently drop every
        // prompt the next test tries to begin.
        SessionKeyImportPromptCoordinator.endPresenting()
        super.tearDown()
    }

    func test_beginPresentingIfIdle_allowsOnlyOneAtATime() {
        XCTAssertTrue(
            SessionKeyImportPromptCoordinator.beginPresentingIfIdle(),
            "nothing is showing yet, so the first attempt must be allowed to begin"
        )
        XCTAssertFalse(
            SessionKeyImportPromptCoordinator.beginPresentingIfIdle(),
            "a second attempt while one is already showing must be dropped, never queued or blocked"
        )
    }

    func test_endPresenting_allowsATrulyNewAttemptAfterward() {
        XCTAssertTrue(SessionKeyImportPromptCoordinator.beginPresentingIfIdle())
        SessionKeyImportPromptCoordinator.endPresenting()

        XCTAssertTrue(
            SessionKeyImportPromptCoordinator.beginPresentingIfIdle(),
            "once the prior presentation ends, a fresh attempt must be allowed to begin"
        )
    }

    func test_endPresenting_isIdempotent() {
        // Calling endPresenting with nothing in flight (or twice in a row)
        // must never leave the guard in a state that blocks a later attempt.
        SessionKeyImportPromptCoordinator.endPresenting()
        SessionKeyImportPromptCoordinator.endPresenting()

        XCTAssertTrue(SessionKeyImportPromptCoordinator.beginPresentingIfIdle())
    }
}
