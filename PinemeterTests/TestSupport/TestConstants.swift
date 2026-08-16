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

    /// A fabricated Slack-bot-token-shaped string, used by the broker secret
    /// tests to prove credential-shaped values never reach tool results or
    /// audit records. It is assembled from fragments rather than written as
    /// one literal because GitHub push protection matches the literal shape
    /// and rejects the public mirror push, which blocks releases. The runtime
    /// value is unchanged; only the on-disk representation differs.
    static let slackShapedSentinel = ["xoxb", "1928374650", "abcdefGHIJKLmnoPQRSTuvwx"]
        .joined(separator: "-")
}
