//
//  BrokerSetupProgressTests.swift
//  PinemeterTests
//
//  The Setup pane and the Broker window's sidebar badge grade the same four
//  steps through `BrokerSetupProgress`, so the badge can never count a
//  different number of open steps than the pane shows. Also pins the slider
//  snapping that replaced `step:` on the unticked threshold sliders.
//

import XCTest
import SwiftUI
@testable import Pinemeter

final class BrokerSetupProgressTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_760_000_000)
    private let version = "1.1.0"

    private func check(status: InstructionAuditStatus) -> InstructionCheck {
        InstructionCheck(
            runID: nil,
            caller: "claude-code",
            checkedAt: checkedAt,
            gradedBy: version,
            setupRevision: nil,
            sources: [InstructionCheckSource(path: "a.md", status: status, findings: [])]
        )
    }

    private func progress(
        serverRunning: Bool = true,
        check: InstructionCheck?,
        lastPickSummary: String? = nil,
        lastPickDegraded: Bool = false
    ) -> BrokerSetupProgress {
        BrokerSetupProgress(
            serverRunning: serverRunning,
            check: check,
            lastPickSummary: lastPickSummary,
            lastPickDegraded: lastPickDegraded,
            currentVersion: version,
            currentSetupRevision: nil,
            now: checkedAt.addingTimeInterval(3600)
        )
    }

    /// After a relaunch the in-memory pick and check stamps are nil, but the
    /// saved passing check still completes steps 2 and 3.
    func test_savedPassingCheckAfterRelaunchLeavesOnlyThePickOpen() {
        let result = progress(check: check(status: .pass))
        XCTAssertTrue(result.hasAgentContact)
        XCTAssertTrue(result.instructionsCurrent)
        XCTAssertFalse(result.hasSuccessfulPick)
        XCTAssertEqual(result.remainingSteps, 1)
    }

    func test_savedCheckThatDidNotPassKeepsInstructionsOpen() {
        let result = progress(check: check(status: .warning))
        XCTAssertTrue(result.hasAgentContact)
        XCTAssertFalse(result.instructionsCurrent)
        XCTAssertEqual(result.remainingSteps, 2)
    }

    func test_nothingRecordedAndServerOffLeavesEveryStepOpen() {
        XCTAssertEqual(progress(serverRunning: false, check: nil).remainingSteps, 4)
    }

    func test_degradedPickCountsAsContactButNotASuccessfulPick() {
        let result = progress(check: nil, lastPickSummary: "execution -> native/model", lastPickDegraded: true)
        XCTAssertTrue(result.hasAgentContact)
        XCTAssertFalse(result.hasSuccessfulPick)
    }

    func test_everyStepCompleteLeavesNoneOpen() {
        let result = progress(check: check(status: .pass), lastPickSummary: "execution -> native/model")
        XCTAssertEqual(result.remainingSteps, 0)
    }

    // MARK: - Slider snapping

    func test_snappingRoundsToTheNearestStep() {
        XCTAssertEqual(82.9.snapped(toStep: 5, in: 50...95), 85)
        XCTAssertEqual(80.4.snapped(toStep: 1, in: 50...100), 80)
    }

    /// A slow drag feeds raw values between two steps; each must land on the
    /// same step so the thumb and label do not flicker.
    func test_aSlowDragBetweenStepsStaysOnOneStep() {
        var value = 90.0
        for raw in [90.4, 90.6, 90.8, 91.2, 92.4] {
            value = raw.snapped(toStep: 5, in: 75...100)
            XCTAssertEqual(value, 90, "raw \(raw)")
        }
    }

    func test_snappingStaysInsideTheRange() {
        XCTAssertEqual(100.5.snapped(toStep: 5, in: 75...100), 100)
        XCTAssertEqual(73.0.snapped(toStep: 5, in: 75...100), 75)
    }

    /// Arrow keys and VoiceOver move one whole step and store it through the
    /// binding; a sub-step drag value rounds to the nearest step.
    @MainActor
    func test_untickedSliderMovesWholeStepsFromKeysAndVoiceOver() {
        var stored = 90.0
        let slider = UntickedSlider(
            value: Binding(get: { stored }, set: { stored = $0 }),
            range: 75...100,
            step: 5
        )
        let host = NSHostingView(rootView: slider.frame(width: 300))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
        host.layoutSubtreeIfNeeded()
        guard let nsSlider = Self.firstSlider(in: host) as? SteppedSlider else {
            return XCTFail("UntickedSlider did not produce a SteppedSlider")
        }
        XCTAssertEqual(nsSlider.numberOfTickMarks, 0)

        nsSlider.moveRight(nil)
        XCTAssertEqual(stored, 95)
        nsSlider.moveLeft(nil)
        nsSlider.moveDown(nil)
        XCTAssertEqual(stored, 85)
        XCTAssertTrue(nsSlider.accessibilityPerformIncrement())
        XCTAssertEqual(stored, 90)
        XCTAssertTrue(nsSlider.accessibilityPerformDecrement())
        XCTAssertEqual(stored, 85)

        nsSlider.doubleValue = 86.4
        nsSlider.sendAction(nsSlider.action, to: nsSlider.target)
        XCTAssertEqual(stored, 85)

        nsSlider.doubleValue = 100
        nsSlider.moveRight(nil)
        XCTAssertEqual(stored, 100)
    }

    private static func firstSlider(in view: NSView) -> NSSlider? {
        if let slider = view as? NSSlider { return slider }
        for subview in view.subviews {
            if let found = firstSlider(in: subview) { return found }
        }
        return nil
    }
}
