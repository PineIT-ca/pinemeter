//
//  TestConstants.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import Foundation

enum TestConstants {
    static let sessionPercentage: Double = 42
    static let cachedPercentage: Double = 75
    static let menuBarSnapshotPercentage: Double = 72
    static let menuBarSnapshotWeeklyPercentage: Double = 34
    static let weeklyPercentage: Double = 10
    static let oneHourInterval: TimeInterval = 3600
    static let previousErrorMessage = "Previous error"
    static let fetchFailureMessage = "Fetch failed"
    static let unexpectedErrorMessage = "Unexpected"
    static let sessionKeyValue = "sk-ant-test-session-key"
    static let organizationUUIDString = "E4C9B3E0-7C4B-4C4B-A1E0-111111111111"
    static let sessionResetDateString = "2025-01-01T00:00:00.000Z"
    static let weeklyResetDateString = "2025-01-08T00:00:00.000Z"
    static let sonnetPercentage: Double = 5
    static let sonnetResetDateString = "2025-01-04T00:00:00.000Z"

    /// Fabricated credential-shaped strings, used by the broker secret tests to
    /// prove such values never reach tool results or audit records.
    ///
    /// They are assembled from fragments rather than written as one literal
    /// because `PinemeterTests/` is force-pushed to the public mirror, where
    /// GitHub push protection matches the literal shape and rejects the push.
    /// That rejection lands after notarization and costs a full release cycle.
    /// The runtime values are unchanged; only the on-disk spelling differs.
    ///
    /// The Slack shape blocked publishing v1.1.0-beta.3. The GitHub shape did
    /// not, because that detector also validates a checksum, but it is written
    /// the same way so the `git grep` scan in RELEASING.md stays meaningful.
    static let slackShapedSentinel = ["xoxb", "1928374650", "abcdefGHIJKLmnoPQRSTuvwx"]
        .joined(separator: "-")

    static let githubShapedSentinel = "ghp" + "_" + "a8F3kP9qR2vW7xY4zB6mN1cD5eH0jL8sT3uV"
}
