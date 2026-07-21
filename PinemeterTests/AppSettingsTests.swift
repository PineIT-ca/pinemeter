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

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.chatGPTCustomLabel, "Work GPT")
        XCTAssertEqual(decoded.geminiCustomLabel, "Personal Gemini")
        XCTAssertFalse(decoded.isFableUsageShown)
        XCTAssertFalse(decoded.isResetCelebrationEnabled)
        XCTAssertEqual(decoded.scanExcludedAccounts, settings.scanExcludedAccounts)
    }
}
