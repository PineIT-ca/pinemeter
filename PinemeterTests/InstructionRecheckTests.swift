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

    private func check(
        gradedBy: String?,
        setupRevision: Int? = nil,
        at date: Date? = nil
    ) -> InstructionCheck {
        InstructionCheck(
            runID: nil,
            caller: "claude-code",
            checkedAt: date ?? checkedAt,
            gradedBy: gradedBy,
            setupRevision: setupRevision,
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

    func test_newSetupRevisionMakesARecentCheckDue() {
        XCTAssertEqual(
            InstructionRecheck.reason(
                for: check(gradedBy: version, setupRevision: nil),
                currentVersion: version,
                currentSetupRevision: 1,
                now: checkedAt.addingTimeInterval(60)
            ),
            .setupContractChanged
        )
        XCTAssertNil(
            InstructionRecheck.reason(
                for: check(gradedBy: version, setupRevision: 1),
                currentVersion: version,
                currentSetupRevision: 1,
                now: checkedAt.addingTimeInterval(60)
            )
        )
    }

    func test_buildMismatchOutranksSetupRevisionAndSetupOutranksAge() {
        XCTAssertEqual(
            InstructionRecheck.reason(
                for: check(gradedBy: "1.0.9", setupRevision: 0),
                currentVersion: version,
                currentSetupRevision: 1,
                now: checkedAt.addingTimeInterval(InstructionRecheck.interval * 3)
            ),
            .contractMayHaveChanged
        )
        XCTAssertEqual(
            InstructionRecheck.reason(
                for: check(gradedBy: version, setupRevision: 0),
                currentVersion: version,
                currentSetupRevision: 1,
                now: checkedAt.addingTimeInterval(InstructionRecheck.interval * 3)
            ),
            .setupContractChanged
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

    func test_shouldFire_returnsTrueWithoutPriorFiringForDueReason() {
        XCTAssertTrue(
            InstructionRecheck.shouldFire(
                reason: .contractMayHaveChanged,
                lastFiredAt: nil,
                check: check(gradedBy: version),
                now: checkedAt
            )
        )
    }

    func test_shouldFire_returnsFalseWithinTheInterval() {
        XCTAssertFalse(
            InstructionRecheck.shouldFire(
                reason: .contractMayHaveChanged,
                lastFiredAt: checkedAt,
                check: check(gradedBy: version),
                now: checkedAt.addingTimeInterval(InstructionRecheck.interval - 1)
            )
        )
    }

    func test_shouldFire_returnsTrueAtOrPastTheInterval() {
        XCTAssertTrue(
            InstructionRecheck.shouldFire(
                reason: .contractMayHaveChanged,
                lastFiredAt: checkedAt,
                check: check(gradedBy: version),
                now: checkedAt.addingTimeInterval(InstructionRecheck.interval)
            )
        )
        XCTAssertTrue(
            InstructionRecheck.shouldFire(
                reason: .contractMayHaveChanged,
                lastFiredAt: checkedAt,
                check: check(gradedBy: version),
                now: checkedAt.addingTimeInterval(InstructionRecheck.interval + 1)
            )
        )
    }

    func test_shouldFire_reArmsOnACheckRecordedAfterTheLastFiring() {
        XCTAssertTrue(
            InstructionRecheck.shouldFire(
                reason: .contractMayHaveChanged,
                lastFiredAt: checkedAt,
                check: check(
                    gradedBy: "1.0.9",
                    at: checkedAt.addingTimeInterval(60)
                ),
                now: checkedAt.addingTimeInterval(120)
            )
        )
    }

    func test_automaticDispatch_newerAuditDoesNotResetCooldown() {
        let provenance = InstructionDispatchProvenance(version: version, setupRevision: 0)
        let settings = BrokerInstructionDispatchSettings(
            lastAutomaticDispatchAt: checkedAt,
            lastAutomaticDispatchProvenance: provenance
        )
        XCTAssertFalse(InstructionRecheck.shouldDispatchAutomatically(
            check: check(gradedBy: "older-version", at: checkedAt.addingTimeInterval(60)),
            settings: settings, provenance: provenance, now: checkedAt.addingTimeInterval(120)
        ))
    }

    func test_automaticDispatch_missingAuditRecoversAfterBoundAndCooldown() {
        let provenance = InstructionDispatchProvenance(version: version, setupRevision: 0)
        let settings = BrokerInstructionDispatchSettings(
            lastDispatchedAt: checkedAt,
            lastDispatchThreadID: "unfinished-thread",
            lastAutomaticDispatchAt: checkedAt,
            lastDispatchProvenance: provenance,
            lastAutomaticDispatchProvenance: provenance
        )
        XCTAssertTrue(InstructionRecheck.shouldDispatchAutomatically(
            check: check(gradedBy: version, at: checkedAt.addingTimeInterval(60)),
            settings: settings, provenance: provenance,
            now: checkedAt.addingTimeInterval(InstructionRecheck.interval + 61)
        ))
    }

    func test_automaticDispatch_missingAuditHoldsManualRunForOnlyTwentyFourHours() {
        let provenance = InstructionDispatchProvenance(version: version, setupRevision: 0)
        let settings = BrokerInstructionDispatchSettings(
            lastDispatchedAt: checkedAt, lastDispatchThreadID: "missing-audit",
            lastDispatchProvenance: provenance
        )
        let stale = check(gradedBy: "older-version")
        XCTAssertFalse(InstructionRecheck.shouldDispatchAutomatically(
            check: stale, settings: settings, provenance: provenance,
            now: checkedAt.addingTimeInterval(86_399)
        ))
        XCTAssertTrue(InstructionRecheck.shouldDispatchAutomatically(
            check: stale, settings: settings, provenance: provenance,
            now: checkedAt.addingTimeInterval(86_400)
        ))
    }

    func test_automaticDispatch_completionSurvivesUnrelatedAuditBeforeRecoveryTimeout() {
        let provenance = InstructionDispatchProvenance(version: version, setupRevision: 0)
        let settings = BrokerInstructionDispatchSettings(
            lastDispatchedAt: checkedAt, lastDispatchThreadID: "run-A",
            lastDispatchProvenance: provenance
        )
        let completed = InstructionDispatchRun(
            runID: "run-A", provenance: provenance, dispatchedAt: checkedAt,
            completedAt: checkedAt.addingTimeInterval(30)
        )
        let unrelated = check(gradedBy: "older-version", at: checkedAt.addingTimeInterval(60))
        XCTAssertTrue(InstructionRecheck.shouldDispatchAutomatically(
            check: unrelated, settings: settings, provenance: provenance,
            run: completed, now: checkedAt.addingTimeInterval(120)
        ))
        let wrongRun = InstructionDispatchRun(
            runID: "other", provenance: provenance, dispatchedAt: checkedAt,
            completedAt: checkedAt.addingTimeInterval(30)
        )
        XCTAssertFalse(InstructionRecheck.shouldDispatchAutomatically(
            check: unrelated, settings: settings, provenance: provenance,
            run: wrongRun, now: checkedAt.addingTimeInterval(120)
        ))
    }

    func test_automaticDispatch_changedProvenanceBypassesCooldown() {
        let settings = BrokerInstructionDispatchSettings(
            lastAutomaticDispatchAt: checkedAt,
            lastAutomaticDispatchProvenance: .init(version: version, setupRevision: 0)
        )
        for provenance in [
            InstructionDispatchProvenance(version: "new-version", setupRevision: 0),
            InstructionDispatchProvenance(version: version, setupRevision: 1)
        ] {
            XCTAssertTrue(InstructionRecheck.shouldDispatchAutomatically(
                check: check(gradedBy: version), settings: settings,
                provenance: provenance, now: checkedAt.addingTimeInterval(60)
            ))
        }
    }

    func test_shouldFire_returnsFalseForNeverChecked() {
        XCTAssertFalse(
            InstructionRecheck.shouldFire(
                reason: .neverChecked,
                lastFiredAt: nil,
                check: nil,
                now: checkedAt
            )
        )
    }

    func test_shouldFire_returnsFalseWithoutADueReason() {
        XCTAssertFalse(
            InstructionRecheck.shouldFire(
                reason: nil,
                lastFiredAt: nil,
                check: check(gradedBy: version),
                now: checkedAt
            )
        )
    }
}
