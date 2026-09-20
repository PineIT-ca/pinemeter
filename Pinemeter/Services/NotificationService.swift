//
//  NotificationService.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation
import UserNotifications

/// Main actor-isolated notification service
@MainActor
final class NotificationService: NSObject, NotificationServiceProtocol, UNUserNotificationCenterDelegate {
    private var center: UserNotificationCenterProtocol
    private let settingsRepository: SettingsRepositoryProtocol

    init(
        settingsRepository: SettingsRepositoryProtocol,
        notificationCenter: UserNotificationCenterProtocol = UNUserNotificationCenter.current()
    ) {
        self.settingsRepository = settingsRepository
        self.center = notificationCenter
        super.init()
    }

    /// Setup notification center delegate
    func setupDelegate() {
        let actions = [
            UNNotificationAction(
                identifier: "broker.routingUpdate.apply",
                title: "Apply",
                options: [.foreground]
            ),
            UNNotificationAction(
                identifier: "broker.routingUpdate.review",
                title: "Review",
                options: [.foreground]
            ),
        ]
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "broker.routingUpdate",
                actions: actions,
                intentIdentifiers: []
            ),
        ])
        center.delegate = self
    }

    /// Request notification authorization from the user
    func requestAuthorization() async throws -> Bool {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        return granted
    }

    /// Evaluate usage thresholds and send notifications
    func evaluateThresholds(
        usageData: UsageData,
        settings: AppSettings
    ) async {
        let thresholds = settings.notificationThresholds
        let percentage = usageData.sessionUsage.percentage
        let resetTime = usageData.sessionUsage.resetAt

        var state = await settingsRepository.loadNotificationState()
        // Usage alerts are delivered as center-screen overlays, which don't
        // need macOS notification permission; they only depend on the toggle.
        // The OS banner is still sent as a bonus where permission is granted.
        let alertsEnabled = settings.hasNotificationsEnabled

        let shouldNotifyWarning = state.shouldNotify(
            currentPercentage: percentage,
            threshold: thresholds.warningThreshold,
            isWarning: true
        )
        let shouldNotifyCritical = state.shouldNotify(
            currentPercentage: percentage,
            threshold: thresholds.criticalThreshold,
            isWarning: false
        )
        let didReset = state.shouldNotifyReset(currentPercentage: percentage)
        let shouldNotifyReset = alertsEnabled
            && thresholds.isNotifiedOnReset
            && didReset

        // The center-screen celebration depends only on its own toggle.
        if didReset && settings.isResetCelebrationEnabled {
            NotificationCenter.default.post(name: .usageDidReset, object: nil)
        }

        if alertsEnabled && shouldNotifyWarning {
            postUsageAlert(.warning, percentage: percentage, resetTime: resetTime)
            try? await sendThresholdNotification(
                percentage: percentage,
                threshold: .warning,
                resetTime: resetTime
            )
            state.hasWarningBeenNotified = true
        }

        if alertsEnabled && shouldNotifyCritical {
            postUsageAlert(.critical, percentage: percentage, resetTime: resetTime)
            try? await sendThresholdNotification(
                percentage: percentage,
                threshold: .critical,
                resetTime: resetTime
            )
            state.hasCriticalBeenNotified = true
        }

        if shouldNotifyReset {
            try? await sendResetNotification()
        }

        if percentage < thresholds.warningThreshold {
            state.hasWarningBeenNotified = false
        }
        if percentage < thresholds.criticalThreshold {
            state.hasCriticalBeenNotified = false
        }

        state.lastPercentage = percentage
        try? await settingsRepository.saveNotificationState(state)
    }

    /// Send threshold notification
    func sendThresholdNotification(
        percentage: Double,
        threshold: UsageThresholdType,
        resetTime: Date
    ) async throws {
        // Check if notifications are enabled
        guard await shouldSendNotifications() else { return }

        let content = UNMutableNotificationContent()
        content.title = threshold.title
        content.body = threshold.body(percentage: percentage, resetTime: resetTime)
        content.sound = threshold == .critical ? .defaultCritical : .default
        content.categoryIdentifier = "usage.threshold"
        content.userInfo = ["threshold": threshold.rawValue, "percentage": percentage]

        let request = UNNotificationRequest(
            identifier: "threshold.\(threshold.rawValue).\(UUID())",
            content: content,
            trigger: nil // Deliver immediately
        )

        try await center.add(request)
    }

    /// Send session reset notification
    func sendResetNotification() async throws {
        guard await shouldSendNotifications() else { return }

        let content = UNMutableNotificationContent()
        content.title = UsageThresholdType.reset.title
        content.body = UsageThresholdType.reset.body(percentage: 0, resetTime: Date())
        content.sound = .default
        content.categoryIdentifier = "usage.reset"

        let request = UNNotificationRequest(
            identifier: "reset.\(UUID())",
            content: content,
            trigger: nil
        )

        try await center.add(request)
    }

    func sendUpdateAvailableNotification(version: String) async throws {
        guard await shouldSendNotifications() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Pinemeter \(version) is available"
        content.body = "Open Pinemeter to upgrade now."
        content.sound = .default
        content.categoryIdentifier = "app.update"
        content.userInfo = ["version": version]

        let request = UNNotificationRequest(
            identifier: "update.\(version)",
            content: content,
            trigger: nil
        )

        try await center.add(request)
    }

    func sendRoutingUpdateNotification(_ update: RoutingUpdateNotice) async throws {
        guard await shouldSendNotifications() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Routing update available"
        if let profileName = update.profileName {
            content.body = "\(profileName) has updated routing rules. Review and apply them in Broker settings."
            if update.newPresetCount > 0 {
                content.body += " \(update.newPresetCount) new preset"
                    + (update.newPresetCount == 1 ? "" : "s") + " added."
            }
        } else {
            content.body = "\(update.newPresetCount) new routing preset"
                + (update.newPresetCount == 1 ? "" : "s")
                + " arrived from the manifest. Review them in Broker settings."
        }
        content.sound = .default
        content.categoryIdentifier = "broker.routingUpdate"
        if let profileID = update.profileID {
            content.userInfo = ["profile_id": profileID.uuidString]
        }

        try await center.add(UNNotificationRequest(
            identifier: "routing-update.\(update.fingerprint.prefix(12))",
            content: content,
            trigger: nil
        ))
    }

    func sendInstructionRecheckReminder(
        reason: InstructionRecheck.Reason,
        setupNotice: BrokerAgentSetupNotice?
    ) async throws {
        guard await shouldSendNotifications() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Instruction check is due"
        switch reason {
        case .neverChecked:
            content.body = "No check has run on this Mac yet. Run the broker's configure prompt in an agent."
        case .contractMayHaveChanged:
            content.body = "Pinemeter updated since the last check. Run the broker's configure prompt in an agent."
        case .setupContractChanged:
            let revision = setupNotice?.revision ?? 0
            content.body = "Agent setup instructions changed (revision \(revision)). "
                + "Run the broker's configure prompt in an agent."
            if let summary = setupNotice?.summary {
                content.body += " \(summary)"
            }
        case .stale:
            content.body = "The last check is over two weeks old. Run the broker's configure prompt in an agent."
        }
        content.sound = .default
        content.categoryIdentifier = "broker.instructionRecheck"
        content.userInfo = ["reason": reason.rawValue]

        let request = UNNotificationRequest(
            identifier: "instruction-recheck.\(reason.rawValue)",
            content: content,
            trigger: nil
        )

        try await center.add(request)
    }

    /// Check system notification permissions
    func checkNotificationPermissions() async -> Bool {
        await center.authorizationStatus() == .authorized
    }

    // MARK: - Private Methods

    /// Posts a center-screen usage alert overlay event for the given threshold.
    private func postUsageAlert(
        _ threshold: UsageThresholdType,
        percentage: Double,
        resetTime: Date
    ) {
        let severity: UsageAlertPayload.Severity = threshold == .critical ? .critical : .warning
        let payload = UsageAlertPayload(
            severity: severity,
            title: threshold.title,
            message: threshold.body(percentage: percentage, resetTime: resetTime)
        )
        NotificationCenter.default.post(name: .usageAlert, object: payload)
    }

    private func shouldSendNotifications() async -> Bool {
        let systemPermission = await checkNotificationPermissions()
        let settings = await settingsRepository.load()
        return systemPermission && settings.hasNotificationsEnabled
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present banners even while Pinemeter is the active app; without this,
    /// macOS suppresses notifications delivered in the foreground, which is why
    /// a menu bar app's alerts often never appear.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationResponse(
            categoryIdentifier: response.notification.request.content.categoryIdentifier,
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
        completionHandler()
    }

    func handleNotificationResponse(
        categoryIdentifier: String,
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) {
        guard categoryIdentifier == "broker.routingUpdate" else {
            NotificationCenter.default.post(name: .openUsagePopover, object: nil)
            return
        }

        if actionIdentifier == "broker.routingUpdate.apply",
           let profileID = (userInfo["profile_id"] as? String).flatMap(UUID.init(uuidString:)) {
            NotificationCenter.default.post(name: .applyRoutingUpdate, object: profileID)
        } else {
            NotificationCenter.default.post(name: .openBrokerSettings, object: nil)
        }
    }
}

extension Notification.Name {
    static let openUsagePopover = Notification.Name("openUsagePopover")
    static let openBrokerSettings = Notification.Name("openBrokerSettings")
    static let applyRoutingUpdate = Notification.Name("applyRoutingUpdate")
    /// Posted when a tracked quota resets (usage returns to 0), to trigger the
    /// center-screen celebration.
    static let usageDidReset = Notification.Name("usageDidReset")
    /// Posted when a usage threshold is crossed, carrying a `UsageAlertPayload`
    /// as its object, to trigger the center-screen alert overlay.
    static let usageAlert = Notification.Name("usageAlert")
}

/// Content for a center-screen usage alert overlay.
struct UsageAlertPayload: Equatable, Sendable {
    enum Severity: String, Sendable {
        case warning
        case critical
    }

    let severity: Severity
    let title: String
    let message: String
}
