import XCTest
@testable import Pinemeter

final class AppSettingsTests: XCTestCase {
    func test_setRefreshInterval_clampsBelowMinimumToRefreshMinimum() {
        var settings = AppSettings.default

        settings.setRefreshInterval(Constants.Refresh.minimum - 1)

        XCTAssertEqual(settings.refreshInterval, Constants.Refresh.minimum)
    }

    func test_setRefreshInterval_clampsAboveMaximumToRefreshMaximum() {
        var settings = AppSettings.default

        settings.setRefreshInterval(Constants.Refresh.maximum + 1)

        XCTAssertEqual(settings.refreshInterval, Constants.Refresh.maximum)
    }

    func test_setRefreshInterval_keepsInRangeValue() {
        var settings = AppSettings.default
        let inRangeInterval = (Constants.Refresh.minimum + Constants.Refresh.maximum) / 2

        settings.setRefreshInterval(inRangeInterval)

        XCTAssertEqual(settings.refreshInterval, inRangeInterval)
    }

    func test_decodingLegacySettingsWithoutNewKeys_usesSafeDefaults() throws {
        // A settings blob saved before the provider-label and reset-celebration
        // keys existed must still decode, defaulting the new fields.
        let legacyJSON = """
        {
            "refresh_interval": 300,
            "notifications_enabled": true,
            "is_first_launch": false,
            "show_sonnet_usage": false,
            "show_chatgpt_usage": false
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(settings.chatGPTCustomLabel)
        XCTAssertNil(settings.geminiCustomLabel)
        XCTAssertTrue(settings.isFableUsageShown)
        XCTAssertTrue(settings.isResetCelebrationEnabled)
        XCTAssertTrue(settings.scanExcludedAccounts.isEmpty)
        XCTAssertNil(settings.lastUpdateCheckAt)
        XCTAssertNil(settings.lastNotifiedUpdateVersion)
        XCTAssertNil(settings.availableUpdateVersion)
        XCTAssertEqual(settings.subscriptionResetAnnouncementMode, .timeRemaining)
    }

    func test_decodingUnknownSubscriptionResetAnnouncementMode_preservesOtherSettings() throws {
        let json = """
        {
            "refresh_interval": 600,
            "notifications_enabled": false,
            "is_first_launch": false,
            "show_chatgpt_usage": true,
            "subscription_reset_announcement_mode": "future_mode"
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.refreshInterval, 600)
        XCTAssertFalse(settings.hasNotificationsEnabled)
        XCTAssertFalse(settings.isFirstLaunch)
        XCTAssertTrue(settings.isChatGPTUsageShown)
        XCTAssertEqual(settings.subscriptionResetAnnouncementMode, .timeRemaining)
    }

    func test_subscriptionResetAnnouncementModes_roundTripAndFormatResetText() throws {
        let now = Date(timeIntervalSince1970: 1_786_384_800)
        let resetAt = now.addingTimeInterval(90 * 60)
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let localReset = formatter.string(from: resetAt)

        XCTAssertEqual(
            SubscriptionResetAnnouncementMode.allCases.map(\.rawValue),
            ["local_reset_time", "time_remaining", "both"]
        )
        XCTAssertEqual(
            SubscriptionResetAnnouncementMode.allCases.map(\.title),
            ["Local Reset Time", "Time Remaining", "Both"]
        )
        XCTAssertEqual(
            SubscriptionResetAnnouncementMode.localResetTime.resetAnnouncement(
                for: resetAt,
                now: now,
                locale: locale,
                timeZone: timeZone
            ),
            "Resets \(localReset)"
        )
        XCTAssertEqual(
            SubscriptionResetAnnouncementMode.timeRemaining.resetAnnouncement(
                for: resetAt,
                now: now,
                locale: locale,
                timeZone: timeZone
            ),
            "Resets in 2 hours"
        )
        XCTAssertEqual(
            SubscriptionResetAnnouncementMode.both.resetAnnouncement(
                for: resetAt,
                now: now,
                locale: locale,
                timeZone: timeZone
            ),
            "Resets \(localReset) (in 2 hours)"
        )

        for mode in SubscriptionResetAnnouncementMode.allCases {
            var settings = AppSettings.default
            settings.subscriptionResetAnnouncementMode = mode

            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

            XCTAssertEqual(decoded.subscriptionResetAnnouncementMode, mode)
        }
    }

    func test_encodeDecodeRoundTrip_preservesNewLabelAndCelebrationFields() throws {
        var settings = AppSettings.default
        settings.chatGPTCustomLabel = "Work GPT"
        settings.geminiCustomLabel = "Personal Gemini"
        settings.isFableUsageShown = false
        settings.isResetCelebrationEnabled = false
        settings.scanExcludedAccounts = [
            ScanExcludedAccount(provider: .claude, accountId: "org-1", displayLabel: "Old account")
        ]
        settings.lastUpdateCheckAt = Date(timeIntervalSince1970: 1_700_000_000)
        settings.lastNotifiedUpdateVersion = "1.2.3"
        settings.availableUpdateVersion = "1.3.0"
        settings.subscriptionResetAnnouncementMode = .both

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.chatGPTCustomLabel, "Work GPT")
        XCTAssertEqual(decoded.geminiCustomLabel, "Personal Gemini")
        XCTAssertFalse(decoded.isFableUsageShown)
        XCTAssertFalse(decoded.isResetCelebrationEnabled)
        XCTAssertEqual(decoded.scanExcludedAccounts, settings.scanExcludedAccounts)
        XCTAssertEqual(decoded.lastUpdateCheckAt, settings.lastUpdateCheckAt)
        XCTAssertEqual(decoded.lastNotifiedUpdateVersion, "1.2.3")
        XCTAssertEqual(decoded.availableUpdateVersion, "1.3.0")
        XCTAssertEqual(decoded.subscriptionResetAnnouncementMode, .both)
    }
}
