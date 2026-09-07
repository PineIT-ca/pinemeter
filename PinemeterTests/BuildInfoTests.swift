//
//  BuildInfoTests.swift
//  PinemeterTests
//
//  Created by Edd on 2026-08-16.
//

import XCTest
@testable import Pinemeter

final class BuildInfoTests: XCTestCase {
    /// A release build carries the internal HEAD, which is the only value in
    /// the bundle that says which source produced the app.
    func test_versionLabel_withSourceRevision_showsRevisionNotBuildNumber() {
        let label = BuildInfo.versionLabel(
            shortVersion: "1.1.0-beta.3",
            build: "1010003",
            sourceRevision: "4b00217"
        )

        XCTAssertEqual(label, "Version 1.1.0-beta.3 (4b00217)")
    }

    /// Locally built apps ship the project's `dev` placeholder. They keep the
    /// previous `CFBundleVersion` label rather than displaying "dev".
    func test_versionLabel_withPlaceholderRevision_fallsBackToBuildNumber() {
        let label = BuildInfo.versionLabel(
            shortVersion: "1.1.0-beta.3",
            build: "1",
            sourceRevision: BuildInfo.localRevisionPlaceholder
        )

        XCTAssertEqual(label, "Version 1.1.0-beta.3 (1)")
    }

    /// An app built before this key existed has no `PMSourceRevision` at all.
    func test_versionLabel_withMissingRevision_fallsBackToBuildNumber() {
        let label = BuildInfo.versionLabel(
            shortVersion: "1.0.16",
            build: "10016",
            sourceRevision: nil
        )

        XCTAssertEqual(label, "Version 1.0.16 (10016)")
    }

    /// If `PM_SOURCE_REVISION` is ever unset at build time, Info.plist
    /// substitution leaves the raw build setting behind. That must never
    /// surface in the About tab.
    func test_versionLabel_withUnsubstitutedBuildSetting_fallsBackToBuildNumber() {
        let label = BuildInfo.versionLabel(
            shortVersion: "1.1.0-beta.3",
            build: "1010003",
            sourceRevision: "$(PM_SOURCE_REVISION)"
        )

        XCTAssertEqual(label, "Version 1.1.0-beta.3 (1010003)")
    }

    func test_versionLabel_withNoBuildDetail_showsVersionAlone() {
        let label = BuildInfo.versionLabel(
            shortVersion: "1.1.0-beta.3",
            build: "   ",
            sourceRevision: ""
        )

        XCTAssertEqual(label, "Version 1.1.0-beta.3")
    }

    func test_versionLabel_withoutShortVersion_isNil() {
        XCTAssertNil(
            BuildInfo.versionLabel(shortVersion: nil, build: "1010003", sourceRevision: "4b00217")
        )
    }

    /// The shipped bundle must expose the key, otherwise every release would
    /// silently fall back to the uninformative build number.
    ///
    /// Only meaningful when the tests are app-hosted. The Woodpecker lane runs
    /// the xctest bundle outside `Pinemeter.app`, so `Bundle.main` is the
    /// runner and carries none of the app's Info.plist keys — the same reason
    /// `BrokerViewSnapshotTests` skips itself there.
    func test_mainBundle_declaresSourceRevisionKey() throws {
        try XCTSkipUnless(
            Bundle.main.bundleURL.pathExtension == "app",
            "Info.plist keys require the app-hosted runner."
        )

        XCTAssertNotNil(Bundle.main.infoDictionary?["PMSourceRevision"])
    }
}
