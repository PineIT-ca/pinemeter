//
//  AppSettings.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

enum SubscriptionResetAnnouncementMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case localResetTime = "local_reset_time"
    case timeRemaining = "time_remaining"
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localResetTime:
            return "Local Reset Time"
        case .timeRemaining:
            return "Time Remaining"
        case .both:
            return "Both"
        }
    }

    func resetAnnouncement(
        for resetAt: Date,
        now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if self == .both {
            formatter.setLocalizedDateFormatFromTemplate("Mdjm")
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }

        let localResetTime = formatter.string(from: resetAt)
        let timeRemaining = UsageLimit.resetDescription(for: resetAt.timeIntervalSince(now))

        switch self {
        case .localResetTime:
            return "Resets \(localResetTime)"
        case .timeRemaining:
            return "Resets \(timeRemaining)"
        case .both:
            return "\(localResetTime)\n\(timeRemaining)"
        }
    }
}

/// User preferences and app configuration
struct AppSettings: Codable, Equatable, Sendable {
    /// Refresh interval in seconds, clamped to Constants.Refresh bounds.
    var refreshInterval: TimeInterval

    /// Whether notifications are enabled
    var hasNotificationsEnabled: Bool

    /// Notification thresholds
    var notificationThresholds: NotificationThresholds

    /// Whether this is first launch
    var isFirstLaunch: Bool

    /// Last known organization ID (cached)
    var cachedOrganizationId: UUID?

    /// Whether to show Fable usage in the menu bar and popover
    var isFableUsageShown: Bool

    /// Whether to show ChatGPT quota usage in the popover
    var isChatGPTUsageShown: Bool

    /// Whether to show Codex Spark quota bars.
    var isChatGPTSparkUsageShown: Bool = true

    /// Whether to show GPT Reserve quota bars.
    var isChatGPTReserveUsageShown: Bool = true

    /// Menu bar icon display style
    var iconStyle: IconStyle

    /// Whether menu bar icons are shown in color instead of monochrome.
    var isColoredIcon: Bool

    /// Color palette used by quota meters in the menu bar and popover.
    var menuBarColorScheme: MenuBarColorScheme = .spectrum

    /// How reset timestamps are announced below quota bars.
    var subscriptionResetAnnouncementMode: SubscriptionResetAnnouncementMode = .timeRemaining

    /// Connected Claude subscriptions (session keys held in Keychain).
    /// Empty on legacy installs; the primary account is the entry whose
    /// `keychainAccount` is `"default"`.
    var claudeAccounts: [ClaudeAccount] = []

    /// Connected ChatGPT accounts (session cookies held in Keychain). Empty on
    /// legacy installs; the primary account is the entry whose
    /// `keychainAccount` is `"chatgpt.com"`.
    var chatGPTAccounts: [ChatGPTAccount] = []

    /// Connected Gemini API keys (keys held in Keychain). Empty on legacy
    /// installs; the primary account is the entry whose `keychainAccount` is
    /// `"generativelanguage.googleapis.com"`.
    var geminiAccounts: [GeminiAccount] = []

    /// Legacy single-account display label for ChatGPT. Migrated into the
    /// primary entry of `chatGPTAccounts` on first launch after upgrading, and
    /// kept only so an older saved settings file still decodes.
    var chatGPTCustomLabel: String? = nil

    /// Legacy single-account display label for Gemini. Migrated into the
    /// primary entry of `geminiAccounts`, kept for the same reason.
    var geminiCustomLabel: String? = nil

    /// Whether to show the center-screen celebration when a quota resets.
    var isResetCelebrationEnabled: Bool = true

    /// Whether Sparkle may select prerelease items tagged with the beta channel.
    var includeBetaUpdates: Bool = false

    /// Accounts that browser scans must not reconnect until the user re-enables them.
    var scanExcludedAccounts: [ScanExcludedAccount] = []

    /// Internal update-check state. These are persisted so the daily check and
    /// once-per-release notification survive app relaunches.
    var lastUpdateCheckAt: Date? = nil
    var lastNotifiedUpdateVersion: String? = nil
    var availableUpdateVersion: String? = nil

    /// When the instruction re-check reminder last fired. Persisted for the
    /// same reason the update notification's stamp is: the reminder is
    /// periodic, and a relaunch must not re-arm it.
    var lastInstructionRecheckNotifiedAt: Date? = nil

    /// Broker MCP server configuration (enable toggle, port, routing policy).
    var broker: BrokerSettings = .default

    static let `default` = AppSettings(
        refreshInterval: 600,
        hasNotificationsEnabled: true,
        notificationThresholds: .default,
        isFirstLaunch: true,
        cachedOrganizationId: nil,
        isFableUsageShown: true,
        isChatGPTUsageShown: false,
        iconStyle: .dualBar,
        isColoredIcon: true
    )

    enum CodingKeys: String, CodingKey {
        case refreshInterval = "refresh_interval"
        case hasNotificationsEnabled = "notifications_enabled"
        case notificationThresholds = "notification_thresholds"
        case isFirstLaunch = "is_first_launch"
        case cachedOrganizationId = "cached_organization_id"
        case isFableUsageShown = "show_fable_usage"
        case isChatGPTUsageShown = "show_chatgpt_usage"
        case isChatGPTSparkUsageShown = "show_chatgpt_spark_usage"
        case isChatGPTReserveUsageShown = "show_chatgpt_reserve_usage"
        case legacyOpenAIUsageShown = "show_openai_usage"
        case iconStyle = "icon_style"
        case isColoredIcon = "is_colored_icon"
        case menuBarColorScheme = "menu_bar_color_scheme"
        case subscriptionResetAnnouncementMode = "subscription_reset_announcement_mode"
        case claudeAccounts = "claude_accounts"
        case chatGPTAccounts = "chatgpt_accounts"
        case geminiAccounts = "gemini_accounts"
        case chatGPTCustomLabel = "chatgpt_custom_label"
        case geminiCustomLabel = "gemini_custom_label"
        case isResetCelebrationEnabled = "reset_celebration_enabled"
        case includeBetaUpdates = "include_beta_updates"
        case scanExcludedAccounts = "scan_excluded_accounts"
        case lastUpdateCheckAt = "last_update_check_at"
        case lastNotifiedUpdateVersion = "last_notified_update_version"
        case availableUpdateVersion = "available_update_version"
        case lastInstructionRecheckNotifiedAt = "last_instruction_recheck_notified_at"
        case broker = "broker"
    }
}

extension AppSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.default

        refreshInterval = Self.clampedRefreshInterval(
            try container.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? defaults.refreshInterval
        )
        hasNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hasNotificationsEnabled) ?? defaults.hasNotificationsEnabled
        notificationThresholds = try container.decodeIfPresent(NotificationThresholds.self, forKey: .notificationThresholds) ?? defaults.notificationThresholds
        isFirstLaunch = try container.decodeIfPresent(Bool.self, forKey: .isFirstLaunch) ?? defaults.isFirstLaunch
        cachedOrganizationId = try container.decodeIfPresent(UUID.self, forKey: .cachedOrganizationId)
        isFableUsageShown = try container.decodeIfPresent(Bool.self, forKey: .isFableUsageShown) ?? defaults.isFableUsageShown
        isChatGPTUsageShown = try container.decodeIfPresent(Bool.self, forKey: .isChatGPTUsageShown)
            ?? container.decodeIfPresent(Bool.self, forKey: .legacyOpenAIUsageShown)
            ?? defaults.isChatGPTUsageShown
        isChatGPTSparkUsageShown = try container.decodeIfPresent(Bool.self, forKey: .isChatGPTSparkUsageShown)
            ?? defaults.isChatGPTSparkUsageShown
        isChatGPTReserveUsageShown = try container.decodeIfPresent(Bool.self, forKey: .isChatGPTReserveUsageShown)
            ?? defaults.isChatGPTReserveUsageShown
        iconStyle = try container.decodeIfPresent(IconStyle.self, forKey: .iconStyle) ?? defaults.iconStyle
        isColoredIcon = try container.decodeIfPresent(Bool.self, forKey: .isColoredIcon) ?? defaults.isColoredIcon
        menuBarColorScheme = try container.decodeIfPresent(MenuBarColorScheme.self, forKey: .menuBarColorScheme)
            ?? defaults.menuBarColorScheme
        let resetAnnouncementRawValue = try container.decodeIfPresent(
            String.self,
            forKey: .subscriptionResetAnnouncementMode
        )
        subscriptionResetAnnouncementMode = resetAnnouncementRawValue
            .flatMap(SubscriptionResetAnnouncementMode.init(rawValue:))
            ?? defaults.subscriptionResetAnnouncementMode
        claudeAccounts = try container.decodeIfPresent([ClaudeAccount].self, forKey: .claudeAccounts) ?? defaults.claudeAccounts
        chatGPTAccounts = try container.decodeIfPresent([ChatGPTAccount].self, forKey: .chatGPTAccounts) ?? defaults.chatGPTAccounts
        geminiAccounts = try container.decodeIfPresent([GeminiAccount].self, forKey: .geminiAccounts) ?? defaults.geminiAccounts
        chatGPTCustomLabel = try container.decodeIfPresent(String.self, forKey: .chatGPTCustomLabel)
        geminiCustomLabel = try container.decodeIfPresent(String.self, forKey: .geminiCustomLabel)
        isResetCelebrationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isResetCelebrationEnabled) ?? true
        includeBetaUpdates = try container.decodeIfPresent(Bool.self, forKey: .includeBetaUpdates) ?? false
        scanExcludedAccounts = try container.decodeIfPresent([ScanExcludedAccount].self, forKey: .scanExcludedAccounts) ?? []
        lastUpdateCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdateCheckAt)
        lastNotifiedUpdateVersion = try container.decodeIfPresent(String.self, forKey: .lastNotifiedUpdateVersion)
        availableUpdateVersion = try container.decodeIfPresent(String.self, forKey: .availableUpdateVersion)
        lastInstructionRecheckNotifiedAt = try container.decodeIfPresent(
            Date.self, forKey: .lastInstructionRecheckNotifiedAt
        )
        broker = try container.decodeIfPresent(BrokerSettings.self, forKey: .broker) ?? defaults.broker
    }

    init(
        refreshInterval: TimeInterval,
        hasNotificationsEnabled: Bool,
        notificationThresholds: NotificationThresholds,
        isFirstLaunch: Bool,
        cachedOrganizationId: UUID?,
        isFableUsageShown: Bool,
        isChatGPTUsageShown: Bool,
        iconStyle: IconStyle
    ) {
        self.refreshInterval = refreshInterval
        self.hasNotificationsEnabled = hasNotificationsEnabled
        self.notificationThresholds = notificationThresholds
        self.isFirstLaunch = isFirstLaunch
        self.cachedOrganizationId = cachedOrganizationId
        self.isFableUsageShown = isFableUsageShown
        self.isChatGPTUsageShown = isChatGPTUsageShown
        self.iconStyle = iconStyle
        self.isColoredIcon = AppSettings.default.isColoredIcon
        self.menuBarColorScheme = AppSettings.default.menuBarColorScheme
        self.includeBetaUpdates = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(refreshInterval, forKey: .refreshInterval)
        try container.encode(hasNotificationsEnabled, forKey: .hasNotificationsEnabled)
        try container.encode(notificationThresholds, forKey: .notificationThresholds)
        try container.encode(isFirstLaunch, forKey: .isFirstLaunch)
        try container.encodeIfPresent(cachedOrganizationId, forKey: .cachedOrganizationId)
        try container.encode(isFableUsageShown, forKey: .isFableUsageShown)
        try container.encode(isChatGPTUsageShown, forKey: .isChatGPTUsageShown)
        try container.encode(isChatGPTSparkUsageShown, forKey: .isChatGPTSparkUsageShown)
        try container.encode(isChatGPTReserveUsageShown, forKey: .isChatGPTReserveUsageShown)
        try container.encode(iconStyle, forKey: .iconStyle)
        try container.encode(isColoredIcon, forKey: .isColoredIcon)
        try container.encode(menuBarColorScheme, forKey: .menuBarColorScheme)
        try container.encode(subscriptionResetAnnouncementMode, forKey: .subscriptionResetAnnouncementMode)
        try container.encode(claudeAccounts, forKey: .claudeAccounts)
        try container.encode(chatGPTAccounts, forKey: .chatGPTAccounts)
        try container.encode(geminiAccounts, forKey: .geminiAccounts)
        try container.encodeIfPresent(chatGPTCustomLabel, forKey: .chatGPTCustomLabel)
        try container.encodeIfPresent(geminiCustomLabel, forKey: .geminiCustomLabel)
        try container.encode(isResetCelebrationEnabled, forKey: .isResetCelebrationEnabled)
        try container.encode(includeBetaUpdates, forKey: .includeBetaUpdates)
        try container.encode(scanExcludedAccounts, forKey: .scanExcludedAccounts)
        try container.encodeIfPresent(lastUpdateCheckAt, forKey: .lastUpdateCheckAt)
        try container.encodeIfPresent(lastNotifiedUpdateVersion, forKey: .lastNotifiedUpdateVersion)
        try container.encodeIfPresent(availableUpdateVersion, forKey: .availableUpdateVersion)
        try container.encodeIfPresent(
            lastInstructionRecheckNotifiedAt, forKey: .lastInstructionRecheckNotifiedAt
        )
        try container.encode(broker, forKey: .broker)
    }
}

extension AppSettings {
    func isChatGPTRowShown(_ row: ChatGPTUsageData.LimitRow) -> Bool {
        let source = row.sourceLabel.lowercased()
        let isSpark = row.menuBarRole == .chatGPTCodexSpark || source.contains("spark")
        let isReserve = source.contains("gpt-reserve") || source.contains("base_model_inference")
        return (isChatGPTSparkUsageShown || !isSpark) && (isChatGPTReserveUsageShown || !isReserve)
    }

    /// Validate refresh interval is within Constants.Refresh bounds.
    mutating func setRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = Self.clampedRefreshInterval(interval)
    }

    private static func clampedRefreshInterval(_ interval: TimeInterval) -> TimeInterval {
        guard !interval.isNaN else { return Constants.Refresh.minimum }
        return max(Constants.Refresh.minimum, min(Constants.Refresh.maximum, interval))
    }
}
