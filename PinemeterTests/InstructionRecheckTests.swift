//
//  InstructionRecheckTests.swift
//  PinemeterTests
//
//  When a recorded instruction check stops counting as evidence. The rule is
//  the one thing the banner and the reminder share, so it is pinned here
//  rather than through either of them.
//

import XCTest
@testable import Pinemeter

final class InstructionRecheckTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_760_000_000)
    private let version = "1.1.0"

    private func check(gradedBy: String?, at date: Date? = nil) -> InstructionCheck {
        InstructionCheck(
            runID: nil,
            caller: "claude-code",
            checkedAt: date ?? checkedAt,
            gradedBy: gradedBy,
            sources: [InstructionCheckSource(path: "a.md", status: .pass, findings: [])]
        )
    }

    func test_noRecordAtAllIsNeverChecked() {
        XCTAssertEqual(
            InstructionRecheck.reason(for: nil, currentVersion: version, now: checkedAt),
            .neverChecked
        )
    }

    func test_aRecentRecordFromThisBuildIsCurrent() {
        XCTAssertNil(
            InstructionRecheck.reason(
                for: check(gradedBy: version),
                currentVersion: version,
                now: checkedAt.addingTimeInterval(3600)
            )
        )
    }

    func test_aRecordFromAnotherBuildIsQuestionedRegardlessOfAge() {
        XCTAssertEqual(
            InstructionRecheck.reason(
                for: check(gradedBy: "1.0.9"),
                currentVersion: version,
                now: checkedAt.addingTimeInterval(60)
            ),
            .contractMayHaveChanged
        )
    }

    /// A record written before the grading version was kept says nothing about
    /// which contract graded it, which is the same position as a mismatch.
    func test_aRecordWithNoGradingVersionIsTreatedAsAnotherBuild() {
        XCTAssertEqual(
            InstructionRecheck.reason(
                for: check(gradedBy: nil),
                currentVersion: version,
                now: checkedAt.addingTimeInterval(60)
            ),
            .contractMayHaveChanged
        )
    }

    func test_aRecordOlderThanTheIntervalIsStale() {
        XCTAssertEqual(
            InstructionRecheck.reason(
                for: check(gradedBy: version),
                currentVersion: version,
                now: checkedAt.addingTimeInterval(InstructionRecheck.interval + 1)
            ),
            .stale
        )
    }

    /// The boundary itself is still current: the interval is how long a check
    /// stands, not the first instant it stops standing.
    func test_aRecordAtExactlyTheIntervalIsStillCurrent() {
        XCTAssertNil(
            InstructionRecheck.reason(
                for: check(gradedBy: version),
                currentVersion: version,
                now: checkedAt.addingTimeInterval(InstructionRecheck.interval)
            )
        )
    }

    /// A build mismatch outranks age: an old record from another build is
    /// questionable because of the build, and saying "14 days old" instead
    /// would send the user to re-run it for the lesser of two reasons.
    func test_aBuildMismatchOutranksStaleness() {
        XCTAssertEqual(
            InstructionRecheck.reason(
                for: check(gradedBy: "1.0.9"),
                currentVersion: version,
                now: checkedAt.addingTimeInterval(InstructionRecheck.interval * 3)
            ),
            .contractMayHaveChanged
        )
    }

    func test_theIntervalIsFourteenDays() {
        XCTAssertEqual(InstructionRecheck.interval, 14 * 24 * 60 * 60)
    }
}
