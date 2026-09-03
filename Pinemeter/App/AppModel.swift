import AppKit
import Foundation
import Observation
import os

/// Recovery action that can be shown for a provider credential without exposing credential material.
enum ProviderCredentialActionKind: String, Equatable, Hashable, Sendable {
    case reconnect
    case repair
    case clear

    var displayTitle: String {
        switch self {
        case .reconnect:
            return "Reconnect"
        case .repair:
            return "Repair"
        case .clear:
            return "Clear"
        }
    }
}

/// Sanitized provider credential action failure that never includes credential material.
enum AppProviderCredentialActionError: LocalizedError, Equatable, Sendable {
    case unsupportedAction(provider: CredentialProvider, action: ProviderCredentialActionKind)

    var errorDescription: String? {
        switch self {
        case .unsupportedAction(let provider, let action):
            return "\(action.displayTitle) is not available for \(provider.displayName) credentials."
        }
    }
}

struct AppProviderCredentialStatus: Identifiable, Equatable, Sendable {
    struct Action: Identifiable, Equatable, Sendable {
        let kind: ProviderCredentialActionKind

        var id: String { kind.rawValue }
        var displayTitle: String { kind.displayTitle }
    }

    let state: CredentialState
    let actions: [Action]

    var id: String { state.identity.id }
    var provider: CredentialProvider { state.identity.provider }
    var kind: CredentialKind { state.identity.kind }
    var providerName: String { provider.displayName }
    var credentialName: String { state.identity.displayName }

    /// Surface-neutral state text shared by setup and settings.
    var stateText: String { state.health.displayTitle }

    /// Surface-neutral sanitized detail text shared by setup and settings.
    var detailText: String {
        switch state.health {
        case .valid, .refreshRecommended:
            return "Saved \(credentialName) is ready."
        case .missing, .unknown:
            if kind == .apiKey {
                return "Add a \(credentialName) in Settings."
            }
            return "Sign in to \(providerName) in your browser, then import the browser session into Pinemeter."
        case .validating:
            return "Pinemeter is checking your saved \(credentialName)."
        case .invalid, .expired, .unavailable:
            return recoverySuggestion ?? state.displayDescription
        }
    }

    var statusTitle: String { stateText }
    var statusDescription: String { detailText }
    var lastFailureTitle: String? { state.failureCategory?.displayTitle }
    var recoverySuggestion: String? { state.recoverySuggestion }

    var setupPromptTitle: String {
        switch state.health {
        case .valid, .refreshRecommended:
            return "Saved \(credentialName) is ready"
        case .missing, .unknown:
            return "Connect \(providerName)"
        case .validating:
            return "Checking \(credentialName)"
        case .invalid, .expired, .unavailable:
            return "Recover \(credentialName)"
        }
    }

    var setupPromptDescription: String { detailText }

    var setupAccessibilityLabel: String {
        "\(credentialName) status: \(stateText). \(detailText)"
    }

    var shouldPromptForSetupCredential: Bool {
        false
    }

    var isRepairableInSetup: Bool {
        actions.contains { $0.kind == .repair }
    }

    var searchableText: String {
        [
            providerName,
            credentialName,
            statusTitle,
            statusDescription,
            lastFailureTitle,
            recoverySuggestion,
            actions.map(\.displayTitle).joined(separator: " ")
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

/// A single Claude account's usage as rendered in the popover.
struct ClaudeUsageSection: Identifiable, Equatable, Sendable {
    /// `ClaudeAccount.id` (organization UUID string), or `"default"` for the
    /// legacy single-account fallback.
    let id: String
    /// Section heading: the account label when more than one account is
    /// connected, otherwise plain "Claude".
    let title: String
    let usageData: UsageData?
    let errorMessage: String?
}

/// A single ChatGPT account's usage as rendered in the popover.
struct ChatGPTUsageSection: Identifiable, Equatable, Sendable {
    /// `ChatGPTAccount.id`, or the legacy keychain slot name for installs that
    /// predate `settings.chatGPTAccounts`.
    let id: String
    /// Section heading: the account label when more than one account is
    /// connected, otherwise plain "ChatGPT".
    let title: String
    /// Whether `title` is a user-renameable account label rather than the
    /// fixed provider name.
    let isRenameable: Bool
    let usageData: ChatGPTUsageData?
    let errorMessage: String?
}

/// A single Gemini API key's usage as rendered in the popover.
struct GeminiUsageSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let isRenameable: Bool
    let usageData: GeminiUsageData?
    let errorMessage: String?
}

/// Result of connecting ChatGPT accounts from a browser import.
struct ChatGPTAccountsImportResult: Equatable, Sendable {
    let importedCount: Int
    let accountLabels: [String]
    /// Cookie-store labels the connected accounts came from, so a multi-browser
    /// scan can report which browser contributed which account.
    let connectedSourceDescriptions: [String]
}

private enum ChatGPTAccountRefreshOutcome: Sendable {
    case success(ChatGPTUsageData, ChatGPTAccountIdentity)
    case failure(String)
    case cancelled
}

/// Result of connecting Claude accounts from a browser import.
struct ClaudeAccountsImportResult: Equatable, Sendable {
    /// The primary account's imported key (value + source), returned so single
    /// -account callers keep their existing behavior.
    let primary: ImportedSessionKey
    /// Total number of connected accounts after the import.
    let importedCount: Int
    /// Display labels for every connected account (primary first).
    let accountLabels: [String]
    /// Every connected account's imported key (primary first), so scan flows
    /// can attribute connected accounts back to the browser they came from.
    let connected: [ImportedSessionKey]
}

private extension AggregateQuotaState {
    /// `AggregateQuotaState` and `BrokerQuotaState` share the exact same raw
    /// value set (fresh/stale/error/unavailable) by design, so the export
    /// freshness classification and the broker's oracle freshness never
    /// diverge (D-03).
    var brokerQuotaState: BrokerQuotaState {
        BrokerQuotaState(rawValue: rawValue) ?? .unavailable
    }
}

/// Main application model for SwiftUI-first architecture.
@MainActor
@Observable
final class AppModel {
    private static let logger = Logger(subsystem: "com.pinemeter", category: "AppModel")

    // MARK: - Published State

    var settings: AppSettings = .default {
        didSet {
            if settings.includeBetaUpdates != oldValue.includeBetaUpdates {
                appUpdater?.setBetaUpdatesEnabled(settings.includeBetaUpdates)
            }
            guard hasLoadedSettings else { return }
            scheduleSettingsSave(previous: oldValue)
        }
    }

    var usageData: UsageData?
    /// Usage for additional (non-primary) connected Claude accounts, keyed by
    /// `ClaudeAccount.id`. The primary account's usage stays in `usageData`.
    var claudeAccountUsage: [String: UsageData] = [:]
    /// Sanitized per-account error messages for additional Claude accounts,
    /// keyed by `ClaudeAccount.id`.
    var claudeAccountErrors: [String: String] = [:]

    /// Usage for ChatGPT accounts other than the primary, keyed by
    /// `ChatGPTAccount.id`. The primary account's usage stays in
    /// `chatGPTUsageData`.
    var chatGPTAccountUsage: [String: ChatGPTUsageData] = [:]

    /// Last poll failure per additional ChatGPT account, keyed by
    /// `ChatGPTAccount.id`.
    var chatGPTAccountErrors: [String: String] = [:]

    /// Usage for Gemini keys other than the primary, keyed by
    /// `GeminiAccount.id`. The primary key's usage stays in `geminiUsageData`.
    var geminiAccountUsage: [String: GeminiUsageData] = [:]

    /// Last poll failure per additional Gemini key, keyed by `GeminiAccount.id`.
    var geminiAccountErrors: [String: String] = [:]
    var chatGPTUsageData: ChatGPTUsageData?
    var geminiUsageData: GeminiUsageData?
    var isLoading: Bool = false
    var isRefreshing: Bool = false
    var isRefreshingAdditionalClaudeAccounts: Bool = false
    var isRefreshingAdditionalChatGPTAccounts: Bool = false
    var isRefreshingAdditionalGeminiAccounts: Bool = false
    var isRefreshingChatGPT: Bool = false
    var isRefreshingGemini: Bool = false
    var importProgress: String?
    var errorMessage: String?
    var chatGPTErrorMessage: String?
    var geminiErrorMessage: String?
    var isSetupComplete: Bool = false
    var hasChatGPTSessionCookie: Bool = false
    var hasGeminiAPIKey: Bool = false
    var isReady: Bool = false
    var claudeCredentialState: CredentialState = CredentialState(
        identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
        health: .unknown
    )
    var chatGPTCredentialState: CredentialState = CredentialState(
        identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
        health: .unknown
    )
    var geminiCredentialState: CredentialState = CredentialState(
        identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
        health: .unknown
    )

    /// Mirror of the broker's UI-facing state (server lifecycle, last pick,
    /// route health, oracle freshness), published for 07-05's popover card
    /// and settings tab.
    var brokerUIState: BrokerUIState?

    /// The broker's API key, for the Network pane to display and copy. Read
    /// from the Keychain during bootstrap and whenever it is generated or
    /// regenerated; never written to settings or logged.
    private(set) var brokerAPIKey: String?

    /// The complete last successful T3 discovery scan, including
    /// `installed == false` entries. This is raw scan truth, not a UI-ready
    /// list: it stays complete because an existing settings row for an
    /// uninstalled instance must still be refreshed from it on every scan.
    /// Consumers filter it — most notably `BrokerSettingsTab`'s add menu,
    /// which is required to filter on `installed` (RESEARCH Q-2). Do not
    /// move that filter into this property; doing so would silently break
    /// row refresh for uninstalled instances.
    private(set) var discoveredT3Instances: [DiscoveredT3Instance] = []

    var availableUpdateVersion: String? {
        settings.availableUpdateVersion
    }

    var providerCredentialStatuses: [AppProviderCredentialStatus] {
        [
            AppProviderCredentialStatus(
                state: claudeCredentialState,
                actions: credentialActions(for: claudeCredentialState)
            ),
            AppProviderCredentialStatus(
                state: chatGPTCredentialState,
                actions: credentialActions(for: chatGPTCredentialState)
            ),
            AppProviderCredentialStatus(
                state: geminiCredentialState,
                actions: credentialActions(for: geminiCredentialState)
            )
        ]
    }

    var isClaudeUsageConfigured: Bool {
        isSetupComplete
    }

    var isChatGPTUsageConfigured: Bool {
        hasChatGPTSessionCookie && settings.isChatGPTUsageShown
    }

    var isGeminiUsageConfigured: Bool {
        hasGeminiAPIKey
    }

    var hasConfiguredUsageProvider: Bool {
        isClaudeUsageConfigured || isChatGPTUsageConfigured || isGeminiUsageConfigured
    }

    var configuredUsageProviderNames: [String] {
        var names: [String] = []
        if isClaudeUsageConfigured {
            names.append(CredentialProvider.claude.displayName)
        }
        if isChatGPTUsageConfigured {
            names.append(CredentialProvider.chatGPT.displayName)
        }
        if isGeminiUsageConfigured {
            names.append(CredentialProvider.gemini.displayName)
        }
        return names
    }

    var usageDashboardTitle: String {
        let names = configuredUsageProviderNames
        if names == [CredentialProvider.claude.displayName] {
            return "Claude Usage"
        }
        if names == [CredentialProvider.chatGPT.displayName] {
            return "ChatGPT Usage"
        }
        if names == [CredentialProvider.gemini.displayName] {
            return "Gemini Usage"
        }
        return "Usage Dashboard"
    }

    var usageLoadingMessage: String {
        let names = configuredUsageProviderNames
        guard !names.isEmpty else {
            return "Connect Claude, ChatGPT, or Gemini to see usage data."
        }
        return "Loading \(Self.joinedProviderNames(names)) usage data..."
    }

    var isRefreshingConfiguredUsage: Bool {
        (isClaudeUsageConfigured && isRefreshing)
            || isRefreshingAdditionalClaudeAccounts
            || (isChatGPTUsageConfigured && isRefreshingChatGPT)
            || (isGeminiUsageConfigured && isRefreshingGemini)
    }

    var hasUsagePopoverContent: Bool {
        usageData != nil
            || !claudeAccountUsage.isEmpty
            || !claudeAccountErrors.isEmpty
            || (settings.isChatGPTUsageShown && (chatGPTUsageData != nil || chatGPTErrorMessage != nil))
            || (isGeminiUsageConfigured && (geminiUsageData != nil || geminiErrorMessage != nil))
    }

    /// One popover section per connected Claude account, primary first. Falls
    /// back to a single unlabeled "Claude" section for legacy single-account
    /// installs that predate `settings.claudeAccounts`.
    var claudeUsageSections: [ClaudeUsageSection] {
        guard isClaudeUsageConfigured else { return [] }
        let accounts = settings.claudeAccounts
        guard !accounts.isEmpty else {
            return [ClaudeUsageSection(
                id: ClaudeAccount.primaryKeychainAccount,
                title: "Claude",
                usageData: usageData,
                errorMessage: nil
            )]
        }

        let ordered = accounts.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
        }
        let showLabels = ordered.count > 1

        return ordered.map { account in
            ClaudeUsageSection(
                id: account.id,
                title: showLabels ? account.displayLabel : "Claude",
                usageData: account.isPrimary ? usageData : claudeAccountUsage[account.id],
                errorMessage: account.isPrimary ? nil : claudeAccountErrors[account.id]
            )
        }
    }

    /// One popover section per connected ChatGPT account, primary first. Falls
    /// back to a single unlabeled "ChatGPT" section for legacy single-account
    /// installs that predate `settings.chatGPTAccounts`.
    var chatGPTUsageSections: [ChatGPTUsageSection] {
        // Gated on the display toggle rather than `isChatGPTUsageConfigured`
        // so a connected-then-rejected account still surfaces its error row
        // instead of vanishing from the popover.
        guard settings.isChatGPTUsageShown else { return [] }
        let accounts = orderedChatGPTAccounts
        guard !accounts.isEmpty else {
            return [ChatGPTUsageSection(
                id: ChatGPTAccount.primaryKeychainAccount,
                title: "ChatGPT",
                isRenameable: false,
                usageData: chatGPTUsageData,
                errorMessage: chatGPTErrorMessage
            )]
        }

        let showLabels = accounts.count > 1
        return accounts.map { account in
            ChatGPTUsageSection(
                id: account.id,
                title: showLabels ? account.displayLabel : "ChatGPT",
                isRenameable: showLabels,
                usageData: account.isPrimary ? chatGPTUsageData : chatGPTAccountUsage[account.id],
                errorMessage: account.isPrimary ? chatGPTErrorMessage : chatGPTAccountErrors[account.id]
            )
        }
    }

    /// One popover section per connected Gemini key, primary first.
    var geminiUsageSections: [GeminiUsageSection] {
        guard isGeminiUsageConfigured || !settings.geminiAccounts.isEmpty else { return [] }
        let accounts = orderedGeminiAccounts
        guard !accounts.isEmpty else {
            return [GeminiUsageSection(
                id: GeminiAccount.legacyPrimaryId,
                title: "Gemini",
                isRenameable: false,
                usageData: geminiUsageData,
                errorMessage: geminiErrorMessage
            )]
        }

        let showLabels = accounts.count > 1
        return accounts.map { account in
            GeminiUsageSection(
                id: account.id,
                title: showLabels ? account.displayLabel : "Gemini",
                isRenameable: showLabels,
                usageData: account.isPrimary ? geminiUsageData : geminiAccountUsage[account.id],
                errorMessage: account.isPrimary ? geminiErrorMessage : geminiAccountErrors[account.id]
            )
        }
    }

    /// Connected ChatGPT accounts, primary first then alphabetical.
    var orderedChatGPTAccounts: [ChatGPTAccount] {
        settings.chatGPTAccounts.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
        }
    }

    /// Connected Gemini keys, primary first then alphabetical.
    var orderedGeminiAccounts: [GeminiAccount] {
        settings.geminiAccounts.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
        }
    }

    /// Ordered quota bars for the menu bar icon: one mini bar per usage bar
    /// shown in the popover, in the same order (each Claude account's 5h,
    /// weekly, and optional Fable bar; then each ChatGPT account's rows; then
    /// each Gemini key), so the popover doubles as the legend for the menu bar
    /// meters.
    var usageQuotaBars: [MenuBarQuotaBar] {
        var bars: [MenuBarQuotaBar] = []

        // Only disambiguated multi-account labels are renameable; a single
        // Claude account shows the fixed "Claude" title, not an editable label.
        let claudeSections = claudeUsageSections
        let renameableClaude = claudeSections.count > 1
        for section in claudeSections {
            guard let usageData = section.usageData else { continue }
            let renameTarget: QuotaRenameTarget? = renameableClaude ? .claudeAccount(id: section.id) : nil
            bars.append(MenuBarQuotaBar(
                label: "\(section.title) 5h",
                percentage: clampedBarPercentage(usageData.sessionUsage.percentage),
                status: usageData.sessionUsage.status,
                detail: resetAnnouncement(for: usageData.sessionUsage.resetAt),
                heading: "5h",
                owner: section.title,
                renameTarget: renameTarget,
                colorScheme: settings.menuBarColorScheme
            ))
            bars.append(MenuBarQuotaBar(
                label: "\(section.title) weekly",
                percentage: clampedBarPercentage(usageData.weeklyUsage.percentage),
                status: usageData.weeklyUsage.status,
                detail: resetAnnouncement(for: usageData.weeklyUsage.resetAt),
                heading: "Weekly",
                owner: section.title,
                renameTarget: renameTarget,
                colorScheme: settings.menuBarColorScheme
            ))
            if settings.isFableUsageShown, let fableUsage = usageData.fableUsage {
                bars.append(MenuBarQuotaBar(
                    label: "\(section.title) Fable",
                    percentage: clampedBarPercentage(fableUsage.percentage),
                    status: fableUsage.status,
                    detail: resetAnnouncement(for: fableUsage.resetAt),
                    heading: "Fable",
                    owner: section.title,
                    renameTarget: renameTarget,
                    colorScheme: settings.menuBarColorScheme
                ))
            }
        }

        for section in chatGPTUsageSections {
            guard let usageData = section.usageData else { continue }
            let renameTarget: QuotaRenameTarget = section.isRenameable
                ? .chatGPTAccount(id: section.id)
                : .provider(.chatGPT)
            for row in usageData.displayRows where settings.isChatGPTRowShown(row) {
                bars.append(MenuBarQuotaBar(
                    label: section.isRenameable ? "\(section.title) \(row.label)" : row.label,
                    percentage: clampedBarPercentage(row.usedPercent),
                    status: row.status,
                    detail: resetAnnouncement(for: row.resetAt),
                    heading: row.menuBarHeading ?? row.menuBarRole?.columnHeading ?? row.label,
                    owner: section.isRenameable ? section.title : chatGPTDisplayLabel,
                    renameTarget: renameTarget,
                    colorScheme: settings.menuBarColorScheme
                ))
            }
        }

        for section in geminiUsageSections {
            guard let usageData = section.usageData else { continue }
            bars.append(MenuBarQuotaBar(
                label: section.isRenameable ? section.title : "Gemini",
                percentage: clampedBarPercentage(usageData.percentage),
                status: usageData.status,
                detail: resetAnnouncement(for: usageData.resetAt),
                heading: "API",
                owner: section.isRenameable ? section.title : geminiDisplayLabel,
                renameTarget: section.isRenameable
                    ? .geminiAccount(id: section.id)
                    : .provider(.gemini),
                colorScheme: settings.menuBarColorScheme
            ))
        }

        return bars
    }

    private func resetAnnouncement(for resetAt: Date?) -> String? {
        resetAt.map { settings.subscriptionResetAnnouncementMode.resetAnnouncement(for: $0) }
    }

    /// Display name for the single-account ChatGPT case: the primary account's
    /// custom label when set, otherwise "ChatGPT".
    var chatGPTDisplayLabel: String {
        let primary = settings.chatGPTAccounts.first { $0.isPrimary } ?? settings.chatGPTAccounts.first
        let custom = primary?.customLabel ?? settings.chatGPTCustomLabel
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "ChatGPT" : trimmed
    }

    /// Display name for the single-key Gemini case.
    var geminiDisplayLabel: String {
        let primary = settings.geminiAccounts.first { $0.isPrimary } ?? settings.geminiAccounts.first
        let custom = primary?.customLabel ?? settings.geminiCustomLabel
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Gemini" : trimmed
    }

    /// Sets one ChatGPT account's display label; a blank label reverts to the
    /// provider-reported one.
    func renameChatGPTAccount(id: String, customLabel: String) {
        let isBlank = customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let index = settings.chatGPTAccounts.firstIndex(where: { $0.id == id }) else {
            // Legacy single-account install with no stored account entry yet.
            settings.chatGPTCustomLabel = isBlank ? nil : customLabel
            return
        }
        settings.chatGPTAccounts[index].customLabel = isBlank ? nil : customLabel
    }

    /// Sets one Gemini key's display label; a blank label reverts to "Gemini".
    func renameGeminiAccount(id: String, customLabel: String) {
        let isBlank = customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let index = settings.geminiAccounts.firstIndex(where: { $0.id == id }) else {
            settings.geminiCustomLabel = isBlank ? nil : customLabel
            return
        }
        settings.geminiAccounts[index].customLabel = isBlank ? nil : customLabel
    }

    /// Current custom label backing a popover owner rename (empty when unset).
    func customLabel(for target: QuotaRenameTarget) -> String {
        switch target {
        case .claudeAccount(let id):
            return settings.claudeAccounts.first { $0.id == id }?.customLabel ?? ""
        case .chatGPTAccount(let id):
            return settings.chatGPTAccounts.first { $0.id == id }?.customLabel ?? ""
        case .geminiAccount(let id):
            return settings.geminiAccounts.first { $0.id == id }?.customLabel ?? ""
        case .provider(.chatGPT):
            return primaryChatGPTCustomLabel ?? ""
        case .provider(.gemini):
            return primaryGeminiCustomLabel ?? ""
        case .provider(.claude):
            return ""
        }
    }

    /// Commits a popover owner rename to the right backing store.
    func renameUsageOwner(_ target: QuotaRenameTarget, customLabel: String) {
        switch target {
        case .claudeAccount(let id):
            renameClaudeAccount(id: id, customLabel: customLabel)
        case .chatGPTAccount(let id):
            renameChatGPTAccount(id: id, customLabel: customLabel)
        case .geminiAccount(let id):
            renameGeminiAccount(id: id, customLabel: customLabel)
        case .provider(.chatGPT):
            renamePrimaryChatGPTAccount(customLabel: customLabel)
        case .provider(.gemini):
            renamePrimaryGeminiAccount(customLabel: customLabel)
        case .provider(.claude):
            break
        }
    }

    private var primaryChatGPTCustomLabel: String? {
        (settings.chatGPTAccounts.first { $0.isPrimary })?.customLabel ?? settings.chatGPTCustomLabel
    }

    private var primaryGeminiCustomLabel: String? {
        (settings.geminiAccounts.first { $0.isPrimary })?.customLabel ?? settings.geminiCustomLabel
    }

    private func renamePrimaryChatGPTAccount(customLabel: String) {
        guard let primary = settings.chatGPTAccounts.first(where: { $0.isPrimary }) else {
            let isBlank = customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            settings.chatGPTCustomLabel = isBlank ? nil : customLabel
            return
        }
        renameChatGPTAccount(id: primary.id, customLabel: customLabel)
    }

    private func renamePrimaryGeminiAccount(customLabel: String) {
        guard let primary = settings.geminiAccounts.first(where: { $0.isPrimary }) else {
            let isBlank = customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            settings.geminiCustomLabel = isBlank ? nil : customLabel
            return
        }
        renameGeminiAccount(id: primary.id, customLabel: customLabel)
    }

    private func clampedBarPercentage(_ value: Double) -> Double {
        max(0, min(value, 100))
    }

    // MARK: - Dependencies

    @ObservationIgnored private let settingsRepository: SettingsRepositoryProtocol
    @ObservationIgnored private let keychainRepository: KeychainRepositoryProtocol
    @ObservationIgnored let cacheRepository: CacheRepository?
    @ObservationIgnored private let usageService: UsageServiceProtocol
    @ObservationIgnored private let chatGPTUsageService: ChatGPTUsageServiceProtocol
    @ObservationIgnored private let chatGPTSessionRepository: any ChatGPTSessionRepositoryProtocol
    @ObservationIgnored private let chatGPTUsageCacheRepository: any ChatGPTUsageCacheRepositoryProtocol
    @ObservationIgnored private let geminiUsageService: GeminiUsageServiceProtocol
    @ObservationIgnored private let geminiAPIKeyRepository: any GeminiAPIKeyRepositoryProtocol
    @ObservationIgnored private let notificationService: NotificationServiceProtocol
    @ObservationIgnored private let sessionKeyImportService: SessionKeyImportServiceProtocol
    @ObservationIgnored private let runningBrowserSources: () -> [BrowserImportSource]
    @ObservationIgnored private let browserLoginPrompt: ([String]) -> Void
    @ObservationIgnored private let releaseCheckService: (any ReleaseCheckServiceProtocol)?
    @ObservationIgnored private let presetManifestService: (any PresetManifestServiceProtocol)?
    @ObservationIgnored private let appUpdater: AppUpdaterProtocol?
    @ObservationIgnored private let installedVersion: String
    @ObservationIgnored private let brokerService: any BrokerLifecycleProtocol
    @ObservationIgnored private let brokerLifecycleController: BrokerLifecycleController
    @ObservationIgnored private let claudeAccountConnectionController: ClaudeAccountConnectionController
    @ObservationIgnored private let chatGPTAccountConnectionController: ChatGPTAccountConnectionController
    @ObservationIgnored private let t3InstanceDiscovery: any T3InstanceDiscoveryProtocol
    @ObservationIgnored private let t3UsageService: any T3UsageServiceProtocol

    // MARK: - Private

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var updateCheckTask: Task<Void, Never>?
    @ObservationIgnored private var presetManifestRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var isCheckingForUpdates = false
    @ObservationIgnored private var hasLoadedSettings: Bool = false
    @ObservationIgnored private let refreshClock = ContinuousClock()
    /// Consecutive-poll `invalidSessionCookie` counter (target invariant D):
    /// a single transient auth rejection keeps the credential
    /// valid-with-error and the last-good `chatGPTUsageData` intact; only two
    /// consecutive rejections flip the credential to `.invalid` and surface
    /// reconnect UI. Any success, or a non-auth failure, resets this to 0.
    @ObservationIgnored private var chatGPTConsecutiveInvalidSessionCount = 0
    /// Failure kind and HTTP status behind the current `chatGPTErrorMessage`,
    /// carried into usage telemetry. `chatGPTErrorMessage` alone records only
    /// that *something* failed, which cannot separate an expired session from
    /// a transport fault when reading a run of errors back later.
    @ObservationIgnored private var chatGPTLastFailure: UsageTelemetryChatGPTFailure?
    @ObservationIgnored private var chatGPTLastFailureStatusCode: Int?
    @ObservationIgnored private var isRecoveringBrowserSessions = false
    @ObservationIgnored private var promptedBrowserProviders = Set<CredentialProvider>()

    // MARK: - Initialization

    init(
        settingsRepository: SettingsRepositoryProtocol = SettingsRepository(),
        keychainRepository: KeychainRepositoryProtocol = KeychainRepository(),
        cacheRepository: CacheRepository? = nil,
        usageService: UsageServiceProtocol? = nil,
        chatGPTUsageService: ChatGPTUsageServiceProtocol? = nil,
        chatGPTSessionRepository: (any ChatGPTSessionRepositoryProtocol)? = nil,
        chatGPTUsageCacheRepository: (any ChatGPTUsageCacheRepositoryProtocol)? = nil,
        geminiUsageService: GeminiUsageServiceProtocol? = nil,
        geminiAPIKeyRepository: (any GeminiAPIKeyRepositoryProtocol)? = nil,
        notificationService: NotificationServiceProtocol? = nil,
        sessionKeyImportService: SessionKeyImportServiceProtocol? = nil,
        runningBrowserSources: @escaping () -> [BrowserImportSource] = { BrowserImportSource.runningBrowsers() },
        browserLoginPrompt: @escaping ([String]) -> Void = SessionKeyImportPromptCoordinator.presentBrowserLoginRequired,
        releaseCheckService: (any ReleaseCheckServiceProtocol)? = nil,
        presetManifestService: (any PresetManifestServiceProtocol)? = nil,
        appUpdater: AppUpdaterProtocol? = nil,
        installedVersion: String? = nil,
        brokerService: (any BrokerLifecycleProtocol)? = nil,
        brokerServerFactory: (@Sendable (
            _ broker: any BrokerServiceProtocol, _ port: UInt16, _ accessPolicy: BrokerAccessPolicy
        ) -> any BrokerLoopbackServerProtocol)? = nil,
        t3LivenessChecker: (any T3LivenessCheckerProtocol)? = nil,
        t3InstanceDiscovery: (any T3InstanceDiscoveryProtocol)? = nil,
        t3UsageService: (any T3UsageServiceProtocol)? = nil
    ) {
        self.settingsRepository = settingsRepository
        self.keychainRepository = keychainRepository
        let chatGPTSessionRepository = chatGPTSessionRepository ?? ChatGPTSessionRepository()
        self.chatGPTSessionRepository = chatGPTSessionRepository
        let geminiAPIKeyRepository = geminiAPIKeyRepository ?? GeminiAPIKeyRepository()
        self.geminiAPIKeyRepository = geminiAPIKeyRepository
        self.sessionKeyImportService = sessionKeyImportService ?? SessionKeyImportService(
            keychainRepository: keychainRepository
        )
        self.runningBrowserSources = runningBrowserSources
        self.browserLoginPrompt = browserLoginPrompt

        let networkService = WebViewNetworkService()
        let aggregateCacheRepository = cacheRepository ?? (usageService == nil ? CacheRepository() : nil)
        self.cacheRepository = aggregateCacheRepository
        let usageService = usageService ?? UsageService(
            networkService: networkService,
            cacheRepository: aggregateCacheRepository!,
            keychainRepository: keychainRepository,
            settingsRepository: settingsRepository
        )
        self.usageService = usageService
        self.claudeAccountConnectionController = ClaudeAccountConnectionController(
            usageService: usageService,
            keychainRepository: keychainRepository
        )
        let resolvedChatGPTUsageService = chatGPTUsageService
            ?? ChatGPTUsageService(sessionRepository: chatGPTSessionRepository)
        self.chatGPTUsageService = resolvedChatGPTUsageService
        self.chatGPTAccountConnectionController = ChatGPTAccountConnectionController(
            usageService: resolvedChatGPTUsageService,
            sessionRepository: chatGPTSessionRepository
        )
        self.chatGPTUsageCacheRepository = chatGPTUsageCacheRepository ?? Self.defaultChatGPTUsageCacheRepository()
        self.geminiUsageService = geminiUsageService ?? GeminiUsageService(apiKeyRepository: geminiAPIKeyRepository)
        self.notificationService = notificationService ?? NotificationService(
            settingsRepository: settingsRepository
        )
        self.releaseCheckService = releaseCheckService
        self.presetManifestService = presetManifestService
        self.appUpdater = appUpdater
        self.installedVersion = installedVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
        let brokerService = brokerService
            ?? BrokerService(livenessChecker: t3LivenessChecker ?? T3LivenessChecker())
        self.brokerService = brokerService
        let brokerServerFactory = brokerServerFactory ?? { broker, port, accessPolicy in
            BrokerMCPServer.makeLoopbackServer(broker: broker, port: port, accessPolicy: accessPolicy)
        }
        self.brokerLifecycleController = BrokerLifecycleController(
            brokerService: brokerService,
            keychainRepository: keychainRepository,
            serverFactory: brokerServerFactory
        )
        self.t3InstanceDiscovery = t3InstanceDiscovery ?? Self.defaultT3InstanceDiscovery()
        self.t3UsageService = t3UsageService ?? T3UsageService()

        self.notificationService.setupDelegate()
    }

    /// The discovery used when no explicit one is injected. Under XCTest this
    /// is a scanner that always returns `nil` ("no information"), so a test
    /// that forgets to inject `T3InstanceDiscoveryFake` can never read the
    /// developer's real `~/.t3/caches` and mutate its policy from whatever
    /// that machine has installed (review WR-08). Production builds get the
    /// real service.
    private static func defaultT3InstanceDiscovery() -> any T3InstanceDiscoveryProtocol {
        if NSClassFromString("XCTestCase") != nil {
            return T3NullInstanceDiscovery()
        }
        return T3InstanceDiscoveryService()
    }

    /// Source description for a connected account's stored session when it
    /// carries no browser profile label. A constant rather than the account's
    /// own label, because that label is the provider-reported email.
    static let retainedSessionSourceDescription = "Saved session"

    /// The ChatGPT usage cache used when no explicit one is injected. Under
    /// XCTest this is a no-op store (same test-safety pattern as
    /// `defaultT3InstanceDiscovery()` above) so a test that forgets to
    /// inject `ChatGPTUsageCacheRepositoryFake` can never read or write the
    /// developer's real on-disk cache file. Production builds get the real
    /// disk-backed store.
    private static func defaultChatGPTUsageCacheRepository() -> any ChatGPTUsageCacheRepositoryProtocol {
        if NSClassFromString("XCTestCase") != nil {
            return ChatGPTUsageNullCacheRepository()
        }
        return ChatGPTUsageCacheRepository()
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !isReady else { return }
        settings = await settingsRepository.load()
        appUpdater?.start()
        if let availableVersion = settings.availableUpdateVersion,
           !AvailableUpdate(version: availableVersion).isNewer(than: installedVersion) {
            settings.availableUpdateVersion = nil
        }
        hasLoadedSettings = true

        brokerAPIKey = await loadBrokerAPIKey()
        isSetupComplete = await keychainRepository.exists(account: "default")
        claudeCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: isSetupComplete ? .valid : .missing,
            failureCategory: isSetupComplete ? nil : .missing,
            checkedAt: Date()
        )
        let chatGPTStatus = await chatGPTSessionRepository.validate(account: ChatGPTAccount.primaryKeychainAccount)
        hasChatGPTSessionCookie = chatGPTStatus.state == .available
        chatGPTCredentialState = Self.credentialState(from: chatGPTStatus, checkedAt: Date())
        migrateLegacyChatGPTAccountIfNeeded()
        // Target invariant E: `chatGPTUsageData` is otherwise memory-only, so
        // seed it from the last-good persisted snapshot before the first
        // poll of this launch runs. `lastUpdated` stays the original fetch
        // time -- the broker's own staleness gate decides how long a loaded
        // snapshot is still trusted.
        if let persistedChatGPTUsage = await chatGPTUsageCacheRepository.load(
            account: ChatGPTAccount.primaryKeychainAccount
        ) {
            chatGPTUsageData = persistedChatGPTUsage
        }
        for account in settings.chatGPTAccounts where !account.isPrimary {
            if let persisted = await chatGPTUsageCacheRepository.load(account: account.keychainAccount) {
                chatGPTAccountUsage[account.id] = persisted
            }
        }
        let geminiStatus = await geminiAPIKeyRepository.validate(account: GeminiAccount.primaryKeychainAccount)
        hasGeminiAPIKey = geminiStatus.state == .available
        geminiCredentialState = Self.credentialState(from: geminiStatus, checkedAt: Date())
        migrateLegacyGeminiAccountIfNeeded()
        isReady = true

        await brokerService.setRefreshHandler { [weak self] in
            await self?.refreshConfiguredUsageProviders(forceRefresh: true)
        }
        _ = await reconcileDiscoveredT3Instances()
        await applyBrokerSettingsChange()
        brokerLifecycleController.startUIStateObserver { [weak self] state in
            self?.brokerUIState = state
        }

        await refreshConfiguredUsageProviders(forceRefresh: true)

        // Offline-first: a fresh install (or one that has never had a
        // successful manifest fetch) gets the bundled presets immediately,
        // rather than showing an empty "From manifest" section until the
        // network answers.
        seedBundledPresetManifestIfNeeded()
        // Fire-and-forget: awaiting this inline would delay
        // startWakeObserver()/startUpdateCheckLoop() below by up to the
        // fetch's own timeout for a manifest refresh that already has
        // stale-but-usable presets to fall back on. Not stored to a task
        // property -- nothing here needs to cancel it, and an unstored
        // `Task` keeps running regardless (it is not tied to holding a
        // reference the way e.g. a `DispatchWorkItem` would be).
        Task { [weak self] in
            await self?.refreshPresetManifest()
        }

        startWakeObserver()
        startUpdateCheckLoop()
        startPresetManifestRefreshLoop()
    }

    // MARK: - Broker lifecycle (07-04)

    /// Reconciles broker settings during bootstrap and after Broker settings
    /// tab changes: pushes the new policy, then stops/starts/restarts the server as
    /// needed so the running server always matches `settings.broker`.
    func applyBrokerSettingsChange() async {
        guard await brokerLifecycleController.apply(settings.broker) else { return }
        startRefreshLoop()
    }

    /// The stored key, or `nil` when none has been provisioned. A missing
    /// Keychain item is the normal first-run state, not an error.
    private func loadBrokerAPIKey() async -> String? {
        do {
            return try await keychainRepository.retrieve(
                account: BrokerAccessPolicy.keychainAccount
            )
        } catch {
            return nil
        }
    }

    /// Provisions a key if the current mode needs one and none exists yet.
    /// A no-op when the mode is `none` or a key is already stored.
    func ensureBrokerAPIKey() async {
        guard settings.broker.apiKeyMode != .none else { return }
        if let existing = await loadBrokerAPIKey() {
            brokerAPIKey = existing
            return
        }
        let key = BrokerAccessPolicy.generateAPIKey()
        do {
            try await keychainRepository.save(
                sessionKey: key,
                account: BrokerAccessPolicy.keychainAccount
            )
        } catch {
            // Never surface the key material through the error path either.
            return
        }
        brokerAPIKey = key
        await applyBrokerSettingsChange()
    }

    /// Replaces the stored key, invalidating every client still holding the
    /// old one, and restarts the server so it starts comparing against the
    /// new value immediately.
    func regenerateBrokerAPIKey() async {
        let key = BrokerAccessPolicy.generateAPIKey()
        let account = BrokerAccessPolicy.keychainAccount
        do {
            if await keychainRepository.exists(account: account) {
                try await keychainRepository.update(sessionKey: key, account: account)
            } else {
                try await keychainRepository.save(sessionKey: key, account: account)
            }
        } catch {
            return
        }
        brokerAPIKey = key
        await applyBrokerSettingsChange()
    }

    /// The broker's recent-picks ring buffer, newest-first (D-09 debugging
    /// surface for 07-05's Broker settings tab).
    func brokerRecentPicks() async -> [RecentPick] {
        await brokerService.recentPicks()
    }

    func resetBrokerDegradedPaths() async -> Bool {
        do {
            try await brokerService.resetCooldowns()
            try await brokerService.refresh()
            return true
        } catch {
            return false
        }
    }

    func brokerLatestInstructionCheck() async -> InstructionCheck? {
        await brokerService.latestInstructionCheck()
    }

    // MARK: - Usage

    func refreshConfiguredUsageProviders(forceRefresh: Bool = false) async {
        if isClaudeUsageConfigured {
            await refreshUsage(forceRefresh: forceRefresh)
        }
        await refreshAdditionalClaudeAccounts(forceRefresh: forceRefresh)
        if isChatGPTUsageConfigured {
            await refreshChatGPTUsage()
        }
        await refreshAdditionalChatGPTAccounts()
        if isGeminiUsageConfigured {
            await refreshGeminiUsage()
        }
        await refreshAdditionalGeminiAccounts()
        await recoverBrowserSessionsIfNeeded()
        let generatedAt = Date()
        let liveness = await brokerService.t3LivenessSnapshot()
        _ = await t3UsageService.refresh(
            instanceAvailability: t3UsageInstanceAvailability(from: liveness),
            request: .trailingWeek(endingAt: generatedAt),
            quota: usageTelemetryQuotaSnapshot(generatedAt: generatedAt)
        )
    }

    func flushUsageTelemetry() async {
        do {
            try await t3UsageService.flushTelemetry()
        } catch {
            Self.logger.error("Usage telemetry termination flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    var isRefreshLoopRunning: Bool {
        refreshTask != nil
    }

    func refreshUsage(forceRefresh: Bool = false) async {
        guard isSetupComplete else {
            usageData = nil
            await exportAggregateUsageSnapshot()
            return
        }
        guard !isRefreshing else { return }

        if usageData == nil {
            isLoading = true
        }
        isRefreshing = true
        errorMessage = nil

        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            let data = try await usageService.fetchUsage(forceRefresh: forceRefresh)
            usageData = data
            claudeCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
                health: .valid,
                checkedAt: Date()
            )
            await notificationService.evaluateThresholds(
                usageData: data,
                settings: settings
            )
        } catch {
            errorMessage = error.localizedDescription
            if let appError = error as? AppError {
                switch appError {
                case .noSessionKey:
                    claudeCredentialState = CredentialState(
                        identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
                        health: .missing,
                        failureCategory: .missing,
                        checkedAt: Date()
                    )
                case .sessionKeyInvalid:
                    claudeCredentialState = CredentialState(
                        identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
                        health: .invalid,
                        failureCategory: .providerRejected,
                        checkedAt: Date()
                    )
                default:
                    break
                }
            }
        }
        await exportAggregateUsageSnapshot()
    }

    /// Refresh usage for every connected additional (non-primary) Claude
    /// account. The primary account is refreshed separately by `refreshUsage`.
    func refreshAdditionalClaudeAccounts(forceRefresh: Bool = false) async {
        guard !isRefreshingAdditionalClaudeAccounts else { return }
        let additionalAccounts = settings.claudeAccounts.filter { !$0.isPrimary }
        guard !additionalAccounts.isEmpty else {
            if !claudeAccountUsage.isEmpty { claudeAccountUsage.removeAll() }
            if !claudeAccountErrors.isEmpty { claudeAccountErrors.removeAll() }
            await exportAggregateUsageSnapshot()
            return
        }
        isRefreshingAdditionalClaudeAccounts = true
        defer { isRefreshingAdditionalClaudeAccounts = false }

        // Drop any cached state for accounts that are no longer connected.
        let connectedIds = Set(additionalAccounts.map { $0.id })
        claudeAccountUsage = claudeAccountUsage.filter { connectedIds.contains($0.key) }
        claudeAccountErrors = claudeAccountErrors.filter { connectedIds.contains($0.key) }

        for account in additionalAccounts {
            do {
                let data = try await usageService.fetchUsage(
                    account: account.keychainAccount,
                    organizationId: account.organizationId,
                    forceRefresh: forceRefresh
                )
                claudeAccountUsage[account.id] = data
                claudeAccountErrors[account.id] = nil
            } catch {
                claudeAccountErrors[account.id] = error.localizedDescription
            }
        }
        await exportAggregateUsageSnapshot()
    }

    // MARK: - ChatGPT Usage

    /// Gives a legacy single-account install an entry in
    /// `settings.chatGPTAccounts` so every later code path can treat it as one
    /// account among several. The real account id is unknown until the next
    /// successful poll fills it in via `applyChatGPTIdentity`.
    private func migrateLegacyChatGPTAccountIfNeeded() {
        guard settings.chatGPTAccounts.isEmpty, hasChatGPTSessionCookie else { return }
        settings.chatGPTAccounts = [.legacyPrimary(customLabel: settings.chatGPTCustomLabel)]
    }

    private func migrateLegacyGeminiAccountIfNeeded() {
        guard settings.geminiAccounts.isEmpty, hasGeminiAPIKey else { return }
        settings.geminiAccounts = [.legacyPrimary(customLabel: settings.geminiCustomLabel)]
    }

    /// Folds the identity a poll reported back into the stored account, so a
    /// migrated legacy account gains its real id and every account's label and
    /// plan stay current. Cached rows from a replaced identity are discarded.
    private func applyChatGPTIdentity(_ identity: ChatGPTAccountIdentity, keychainAccount: String) {
        guard let index = settings.chatGPTAccounts.firstIndex(
            where: { $0.keychainAccount == keychainAccount }
        ) else { return }

        let existing = settings.chatGPTAccounts[index]
        let resolvedId = identity.stableId ?? existing.id
        // A different account now answers for this slot (the user signed out
        // and back in as someone else): drop the previous account's cached
        // rows rather than showing them under the new identity.
        if resolvedId != existing.id {
            chatGPTAccountUsage[existing.id] = nil
            chatGPTAccountErrors[existing.id] = nil
        }

        var updated = ChatGPTAccount(
            id: resolvedId,
            label: identity.email?.isEmpty == false ? identity.displayLabel : existing.label,
            planType: identity.planType ?? existing.planType,
            keychainAccount: existing.keychainAccount,
            profileLabel: existing.profileLabel,
            customLabel: existing.customLabel
        )
        // Two slots must never claim one identity; if the id already exists
        // elsewhere, keep this slot on its previous id instead of colliding.
        if settings.chatGPTAccounts.contains(where: { $0.id == resolvedId && $0.keychainAccount != keychainAccount }) {
            updated = existing
        }
        guard updated != existing else { return }
        settings.chatGPTAccounts[index] = updated
    }

    /// Polls every connected ChatGPT account except the primary, which
    /// `refreshChatGPTUsage` already handles.
    func refreshAdditionalChatGPTAccounts() async {
        guard !isRefreshingAdditionalChatGPTAccounts else { return }
        let additionalAccounts = settings.isChatGPTUsageShown
            ? settings.chatGPTAccounts.filter { !$0.isPrimary }
            : []
        guard !additionalAccounts.isEmpty else {
            if !chatGPTAccountUsage.isEmpty { chatGPTAccountUsage.removeAll() }
            if !chatGPTAccountErrors.isEmpty { chatGPTAccountErrors.removeAll() }
            return
        }

        isRefreshingAdditionalChatGPTAccounts = true
        defer { isRefreshingAdditionalChatGPTAccounts = false }

        // Drop state for accounts that are no longer connected before polling,
        // so a disconnected account cannot leave a stale bar behind.
        let connectedIds = Set(additionalAccounts.map(\.id))
        chatGPTAccountUsage = chatGPTAccountUsage.filter { connectedIds.contains($0.key) }
        chatGPTAccountErrors = chatGPTAccountErrors.filter { connectedIds.contains($0.key) }

        let results = await withTaskGroup(
            of: (keychainAccount: String, outcome: ChatGPTAccountRefreshOutcome).self,
            returning: [String: ChatGPTAccountRefreshOutcome].self
        ) { group in
            for account in additionalAccounts {
                group.addTask { [chatGPTUsageService] in
                    do {
                        let result = try await chatGPTUsageService.fetchUsageAndIdentity(
                            account: account.keychainAccount
                        )
                        return (account.keychainAccount, .success(result.usage, result.identity))
                    } catch is CancellationError {
                        return (account.keychainAccount, .cancelled)
                    } catch {
                        return (account.keychainAccount, .failure(error.localizedDescription))
                    }
                }
            }

            var results: [String: ChatGPTAccountRefreshOutcome] = [:]
            for await result in group {
                results[result.keychainAccount] = result.outcome
            }
            return results
        }

        // Fetches finish in network order. Apply them in settings order so UI
        // state changes remain deterministic and no partial completion can
        // reorder account rows.
        for account in additionalAccounts {
            guard let outcome = results[account.keychainAccount] else { continue }
            switch outcome {
            case .success(let usage, let identity):
                // Resolve the identity before choosing the dictionary key. A
                // changed identity clears the previous account's cached rows,
                // then this poll's fresh rows land under the replacement id.
                applyChatGPTIdentity(identity, keychainAccount: account.keychainAccount)
                guard let resolvedAccount = settings.chatGPTAccounts.first(
                    where: { $0.keychainAccount == account.keychainAccount }
                ) else { continue }
                chatGPTAccountUsage[resolvedAccount.id] = usage
                chatGPTAccountErrors[resolvedAccount.id] = nil
                await chatGPTUsageCacheRepository.save(usage, account: account.keychainAccount)
            case .failure(let message):
                // Last-good usage survives a failed poll, matching the primary
                // account's behavior; only the error text is updated.
                guard let currentAccount = settings.chatGPTAccounts.first(
                    where: { $0.keychainAccount == account.keychainAccount }
                ) else { continue }
                chatGPTAccountErrors[currentAccount.id] = message
            case .cancelled:
                break
            }
        }

        // The primary account's own refresh exported before these rows landed,
        // so the broker would otherwise trail one poll behind on every account
        // but the first.
        await exportAggregateUsageSnapshot()
    }

    /// Polls every connected Gemini key except the primary.
    func refreshAdditionalGeminiAccounts() async {
        guard !isRefreshingAdditionalGeminiAccounts else { return }
        let additionalAccounts = settings.geminiAccounts.filter { !$0.isPrimary }
        guard !additionalAccounts.isEmpty else {
            if !geminiAccountUsage.isEmpty { geminiAccountUsage.removeAll() }
            if !geminiAccountErrors.isEmpty { geminiAccountErrors.removeAll() }
            return
        }

        isRefreshingAdditionalGeminiAccounts = true
        defer { isRefreshingAdditionalGeminiAccounts = false }

        let connectedIds = Set(additionalAccounts.map(\.id))
        geminiAccountUsage = geminiAccountUsage.filter { connectedIds.contains($0.key) }
        geminiAccountErrors = geminiAccountErrors.filter { connectedIds.contains($0.key) }

        for account in additionalAccounts {
            do {
                geminiAccountUsage[account.id] = try await geminiUsageService.fetchUsage(
                    account: account.keychainAccount
                )
                geminiAccountErrors[account.id] = nil
            } catch {
                geminiAccountErrors[account.id] = error.localizedDescription
            }
        }

        await exportAggregateUsageSnapshot()
    }

    func refreshChatGPTUsage() async {
        if !hasChatGPTSessionCookie {
            // Once a provider rejection has flipped health to `.invalid`
            // (`.providerRejected`), keychain presence alone must not reset
            // it back to `.valid`: `validate()` below only proves the cookie
            // is still THERE, not that the provider accepts it again, and a
            // dead-but-present cookie would otherwise flap `.valid` here and
            // `.invalid` at the bottom of this function on every single poll.
            // The fetch attempt still runs either way -- recovery is only
            // ever confirmed by an actual successful fetch, which resets
            // everything below as it always has.
            let wasProviderRejected = chatGPTCredentialState.failureCategory == .providerRejected
            let status = await chatGPTSessionRepository.validate(account: ChatGPTAccount.primaryKeychainAccount)
            if wasProviderRejected {
                if status.state == .available {
                    hasChatGPTSessionCookie = true
                } else {
                    // The keychain check itself now disagrees -- the cookie
                    // really is gone, so this is new information worth
                    // recording, not the same stale rejection.
                    hasChatGPTSessionCookie = false
                    chatGPTCredentialState = Self.credentialState(from: status, checkedAt: Date())
                }
            } else {
                hasChatGPTSessionCookie = status.state == .available
                chatGPTCredentialState = Self.credentialState(from: status, checkedAt: Date())
            }
        }
        guard hasChatGPTSessionCookie else {
            // Target invariant A/D: last-good chatGPTUsageData survives this
            // path too. A `validate()` failure here (missing/invalid/
            // storageUnavailable) doesn't mean the stored keychain cookie is
            // actually gone forever -- e.g. storageUnavailable is transient
            // and a later poll can still recover -- so previously fetched
            // data is not the thing that's wrong; only clear it via explicit
            // disconnect (`clearChatGPTSessionCookie`).
            await exportAggregateUsageSnapshot()
            return
        }
        guard !isRefreshingChatGPT else { return }

        isRefreshingChatGPT = true
        chatGPTErrorMessage = nil
        chatGPTLastFailure = nil
        chatGPTLastFailureStatusCode = nil

        defer {
            isRefreshingChatGPT = false
        }

        do {
            let (usage, identity) = try await chatGPTUsageService.fetchUsageAndIdentity(
                account: ChatGPTAccount.primaryKeychainAccount
            )
            chatGPTUsageData = usage
            applyChatGPTIdentity(identity, keychainAccount: ChatGPTAccount.primaryKeychainAccount)
            chatGPTConsecutiveInvalidSessionCount = 0
            chatGPTLastFailure = nil
            chatGPTLastFailureStatusCode = nil
            hasChatGPTSessionCookie = true
            chatGPTCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
                health: .valid,
                checkedAt: Date()
            )
            await chatGPTUsageCacheRepository.save(usage, account: ChatGPTAccount.primaryKeychainAccount)
        } catch ChatGPTUsageError.missingSessionCookie {
            // The keychain session itself is gone. Unlike invalidSessionCookie
            // below there is nothing to retry towards on a later poll without
            // the user reconnecting, so this always surfaces reconnect UI.
            chatGPTConsecutiveInvalidSessionCount = 0
            hasChatGPTSessionCookie = false
            chatGPTErrorMessage = ChatGPTUsageError.missingSessionCookie.localizedDescription
            recordChatGPTFailure(ChatGPTUsageError.missingSessionCookie)
            chatGPTCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
                health: .missing,
                failureCategory: .missing,
                checkedAt: Date()
            )
        } catch ChatGPTUsageError.invalidSessionCookie {
            // Target invariant D: distinguish a transient auth rejection from
            // a persistent one. `fetchUsage()` already retried once
            // internally, so this is the second (post-retry) failure of this
            // poll -- only after 2 *consecutive polls* land here does the
            // credential flip to invalid; a single one keeps chatGPTUsageData
            // and shows valid-with-error instead.
            chatGPTConsecutiveInvalidSessionCount += 1
            chatGPTErrorMessage = ChatGPTUsageError.invalidSessionCookie.localizedDescription
            recordChatGPTFailure(ChatGPTUsageError.invalidSessionCookie)
            if chatGPTConsecutiveInvalidSessionCount >= 2 {
                hasChatGPTSessionCookie = false
                chatGPTCredentialState = CredentialState(
                    identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
                    health: .invalid,
                    failureCategory: .providerRejected,
                    checkedAt: Date()
                )
            }
        } catch is CancellationError {
            // A cancelled refresh is control flow, not a provider failure.
        } catch {
            // Transient httpError/network/secureStorageUnavailable/etc
            // failure (target invariant A): last-good chatGPTUsageData is
            // untouched, only the error message surfaces. A Keychain read
            // failure (`ChatGPTUsageError.secureStorageUnavailable`) belongs
            // here rather than with `invalidSessionCookie` above -- it says
            // nothing about whether the provider still accepts the session,
            // so it must not count towards, or trip, the consecutive-
            // rejection counter that decides whether to surface reconnect UI.
            chatGPTConsecutiveInvalidSessionCount = 0
            chatGPTErrorMessage = error.localizedDescription
            recordChatGPTFailure(error)
        }
        await exportAggregateUsageSnapshot()
    }

    /// Stores the failure kind for telemetry and logs it, so a ChatGPT error
    /// run is attributable from `usage-telemetry.json` (which survives
    /// restarts) as well as from the unified log (which does not survive
    /// long).
    private func recordChatGPTFailure(_ error: Error) {
        let (failure, statusCode) = Self.chatGPTTelemetryFailure(for: error)
        chatGPTLastFailure = failure
        chatGPTLastFailureStatusCode = statusCode
        Self.logger.warning(
            """
            ChatGPT poll failed: failure=\(failure.rawValue, privacy: .public) \
            http=\(statusCode.map(String.init) ?? "none", privacy: .public) \
            version=\(BuildInfo.diagnosticVersion() ?? "unknown", privacy: .public)
            """
        )
    }

    static func chatGPTTelemetryFailure(
        for error: Error
    ) -> (UsageTelemetryChatGPTFailure, Int?) {
        guard let chatGPTError = error as? ChatGPTUsageError else { return (.unknown, nil) }
        switch chatGPTError {
        case .missingSessionCookie:
            return (.missingSession, nil)
        case .invalidSessionCookie:
            return (.invalidSession, nil)
        case .invalidResponse:
            return (.invalidResponse, nil)
        case .httpError(let statusCode):
            return (.httpError, statusCode)
        case .networkUnavailable:
            return (.transport, nil)
        case .secureStorageUnavailable:
            return (.secureStorage, nil)
        }
    }

    func loadChatGPTSessionCookie() async -> String? {
        do {
            return try await chatGPTSessionRepository.load(account: ChatGPTAccount.primaryKeychainAccount).sessionCookie
        } catch {
            return nil
        }
    }

    func validateAndSaveChatGPTSessionCookie(_ rawValue: String) async throws -> Bool {
        let trimmedCookie = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCookie.isEmpty else { return false }

        let isValid = try await chatGPTUsageService.validateSessionCookie(trimmedCookie)
        guard isValid else {
            hasChatGPTSessionCookie = false
            chatGPTCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
                health: .invalid,
                failureCategory: .providerRejected,
                checkedAt: Date()
            )
            return false
        }

        try await chatGPTSessionRepository.save(
            ChatGPTSession(sessionCookie: trimmedCookie),
            account: ChatGPTAccount.primaryKeychainAccount
        )
        hasChatGPTSessionCookie = true
        registerPrimaryChatGPTAccountIfNeeded()
        chatGPTCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
            health: .valid,
            checkedAt: Date()
        )
        settings.isChatGPTUsageShown = true
        await refreshChatGPTUsage()
        return true
    }

    func clearChatGPTSessionCookie() async throws {
        try await chatGPTSessionRepository.clear(account: ChatGPTAccount.primaryKeychainAccount)
        await chatGPTUsageCacheRepository.clear(account: ChatGPTAccount.primaryKeychainAccount)
        await disconnectAllAdditionalChatGPTAccounts()
        settings.chatGPTAccounts = []
        hasChatGPTSessionCookie = false
        settings.isChatGPTUsageShown = false
        chatGPTUsageData = nil
        chatGPTErrorMessage = nil
        chatGPTConsecutiveInvalidSessionCount = 0
        chatGPTCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
            health: .missing,
            failureCategory: .missing,
            checkedAt: Date()
        )
        await exportAggregateUsageSnapshot()
    }

    /// Disconnects one ChatGPT account. Removing the primary falls back to
    /// promoting another connected account into the primary Keychain slot, so
    /// the remaining accounts keep polling.
    func removeChatGPTAccount(id: String) async throws {
        guard let account = settings.chatGPTAccounts.first(where: { $0.id == id }) else { return }

        if account.isPrimary {
            // A settings row can outlive a missing or unreadable Keychain
            // entry. Promote the first account whose session actually loads,
            // so one broken row cannot block removal of the primary account.
            var promoted: (account: ChatGPTAccount, session: ChatGPTSession)?
            for candidate in settings.chatGPTAccounts where !candidate.isPrimary {
                if let session = try? await chatGPTSessionRepository.load(account: candidate.keychainAccount) {
                    promoted = (candidate, session)
                    break
                }
            }
            guard let successor = promoted?.account, let session = promoted?.session else {
                try await clearChatGPTSessionCookie()
                return
            }
            try await chatGPTSessionRepository.save(session, account: ChatGPTAccount.primaryKeychainAccount)
            try? await chatGPTSessionRepository.clear(account: successor.keychainAccount)
            await chatGPTUsageCacheRepository.clear(account: successor.keychainAccount)

            // The primary cache file still holds the REMOVED account's rows.
            // The refresh below only overwrites it on a successful poll, so
            // removing an account while offline would otherwise leave the next
            // launch loading the removed account's quota under the promoted
            // account's label, and exporting it to the broker as theirs.
            let promotedUsage = chatGPTAccountUsage[successor.id]
            if let promotedUsage {
                await chatGPTUsageCacheRepository.save(
                    promotedUsage,
                    account: ChatGPTAccount.primaryKeychainAccount
                )
            } else {
                await chatGPTUsageCacheRepository.clear(account: ChatGPTAccount.primaryKeychainAccount)
            }

            chatGPTUsageData = promotedUsage
            chatGPTErrorMessage = chatGPTAccountErrors[successor.id]
            chatGPTAccountUsage[successor.id] = nil
            chatGPTAccountErrors[successor.id] = nil
            settings.chatGPTAccounts = settings.chatGPTAccounts
                .filter { $0.id != account.id && $0.id != successor.id }
                + [ChatGPTAccount(
                    id: successor.id,
                    label: successor.label,
                    planType: successor.planType,
                    keychainAccount: ChatGPTAccount.primaryKeychainAccount,
                    profileLabel: successor.profileLabel,
                    customLabel: successor.customLabel
                )]
            await refreshChatGPTUsage()
            return
        }

        try? await chatGPTSessionRepository.clear(account: account.keychainAccount)
        await chatGPTUsageCacheRepository.clear(account: account.keychainAccount)
        chatGPTAccountUsage[account.id] = nil
        chatGPTAccountErrors[account.id] = nil
        settings.chatGPTAccounts.removeAll { $0.id == account.id }
        await exportAggregateUsageSnapshot()
    }

    private func disconnectAllAdditionalChatGPTAccounts() async {
        for account in settings.chatGPTAccounts where !account.isPrimary {
            try? await chatGPTSessionRepository.clear(account: account.keychainAccount)
            await chatGPTUsageCacheRepository.clear(account: account.keychainAccount)
        }
        chatGPTAccountUsage.removeAll()
        chatGPTAccountErrors.removeAll()
    }

    /// Records a manually pasted primary cookie in `settings.chatGPTAccounts`
    /// so it participates in the multi-account surfaces before its first poll
    /// resolves its real identity.
    private func registerPrimaryChatGPTAccountIfNeeded() {
        guard !settings.chatGPTAccounts.contains(where: { $0.isPrimary }) else { return }
        settings.chatGPTAccounts.append(.legacyPrimary(customLabel: settings.chatGPTCustomLabel))
    }

    func excludeChatGPTAccountFromScans() async throws {
        for account in settings.chatGPTAccounts {
            upsertScanExclusion(.chatGPT(account))
        }
        try await clearChatGPTSessionCookie()
    }

    /// Excludes one ChatGPT account from future browser scans and disconnects it.
    func excludeChatGPTAccountFromScans(id: String) async throws {
        guard let account = settings.chatGPTAccounts.first(where: { $0.id == id }) else { return }
        let excluded = ScanExcludedAccount.chatGPT(account)
        try await removeChatGPTAccount(id: id)
        upsertScanExclusion(excluded)
    }

    // MARK: - Gemini Usage

    func refreshGeminiUsage() async {
        if !hasGeminiAPIKey {
            let status = await geminiAPIKeyRepository.validate(account: GeminiAccount.primaryKeychainAccount)
            hasGeminiAPIKey = status.state == .available
            geminiCredentialState = Self.credentialState(from: status, checkedAt: Date())
        }
        guard hasGeminiAPIKey else {
            geminiUsageData = nil
            await exportAggregateUsageSnapshot()
            return
        }
        guard !isRefreshingGemini else { return }

        isRefreshingGemini = true
        geminiErrorMessage = nil

        defer {
            isRefreshingGemini = false
        }

        do {
            geminiUsageData = try await geminiUsageService.fetchUsage()
            hasGeminiAPIKey = true
            geminiCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
                health: .valid,
                checkedAt: Date()
            )
        } catch GeminiUsageError.missingAPIKey {
            hasGeminiAPIKey = false
            geminiUsageData = nil
            geminiErrorMessage = GeminiUsageError.missingAPIKey.localizedDescription
            geminiCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
                health: .missing,
                failureCategory: .missing,
                checkedAt: Date()
            )
        } catch GeminiUsageError.invalidAPIKey {
            hasGeminiAPIKey = false
            geminiUsageData = nil
            geminiErrorMessage = GeminiUsageError.invalidAPIKey.localizedDescription
            geminiCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
                health: .invalid,
                failureCategory: .providerRejected,
                checkedAt: Date()
            )
        } catch GeminiUsageError.networkUnavailable {
            geminiUsageData = nil
            geminiErrorMessage = GeminiUsageError.networkUnavailable.localizedDescription
            geminiCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
                health: .unavailable,
                failureCategory: .networkUnavailable,
                checkedAt: Date()
            )
        } catch {
            geminiUsageData = nil
            geminiErrorMessage = error.localizedDescription
        }
        await exportAggregateUsageSnapshot()
    }

    func loadGeminiAPIKey() async -> String? {
        await loadGeminiAPIKey(account: GeminiAccount.primaryKeychainAccount)
    }

    func loadGeminiAPIKey(account: String) async -> String? {
        do {
            return try await geminiAPIKeyRepository.load(account: account).value
        } catch {
            return nil
        }
    }

    /// Saves a key into the primary slot, replacing whatever was there. Use
    /// `addGeminiAPIKey` to connect an additional key alongside it.
    func validateAndSaveGeminiAPIKey(_ rawValue: String) async throws -> Bool {
        let apiKey = try GeminiAPIKey(rawValue)
        let isValid = try await geminiUsageService.validateAPIKey(apiKey)
        guard isValid else {
            hasGeminiAPIKey = false
            geminiCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
                health: .invalid,
                failureCategory: .providerRejected,
                checkedAt: Date()
            )
            return false
        }

        try await geminiAPIKeyRepository.save(apiKey, account: GeminiAccount.primaryKeychainAccount)
        hasGeminiAPIKey = true
        registerPrimaryGeminiAccountIfNeeded()
        geminiCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
            health: .valid,
            checkedAt: Date()
        )
        await refreshGeminiUsage()
        startRefreshLoop()
        return true
    }

    /// Connects one more Gemini key alongside the ones already connected. The
    /// first key added takes the primary slot so a single-key install keeps its
    /// existing Keychain entry and behavior.
    ///
    /// Returns false when the provider rejects the key or the same key is
    /// already connected, so callers can report both without a second error path.
    @discardableResult
    func addGeminiAPIKey(_ rawValue: String, label: String? = nil) async throws -> Bool {
        guard settings.geminiAccounts.contains(where: { $0.isPrimary }) else {
            return try await validateAndSaveGeminiAPIKey(rawValue)
        }

        let apiKey = try GeminiAPIKey(rawValue)
        // Dedupe against the stored keys themselves rather than persisting any
        // derived fingerprint of credential material outside the Keychain.
        for account in settings.geminiAccounts {
            if await loadGeminiAPIKey(account: account.keychainAccount) == apiKey.value {
                return false
            }
        }

        guard try await geminiUsageService.validateAPIKey(apiKey) else { return false }

        let id = "gemini." + UUID().uuidString
        try await geminiAPIKeyRepository.save(apiKey, account: id)
        settings.geminiAccounts.append(GeminiAccount(
            id: id,
            label: label?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty ?? "Gemini key",
            keychainAccount: id,
            customLabel: label?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
        ))
        await refreshAdditionalGeminiAccounts()
        startRefreshLoop()
        return true
    }

    /// Disconnects one Gemini key. Removing the primary promotes another
    /// connected key into the primary slot.
    func removeGeminiAccount(id: String) async throws {
        guard let account = settings.geminiAccounts.first(where: { $0.id == id }) else { return }

        if account.isPrimary {
            // Promote the first successor whose key actually loads. A rejected
            // key is purged from the Keychain by `GeminiUsageService`, while its
            // settings entry survives; taking that entry as the successor and
            // failing to load it would fall through to `clearGeminiAPIKey()`,
            // which deletes EVERY remaining key. Removing one key must never
            // destroy an unrelated one.
            var promoted: (account: GeminiAccount, key: String)?
            for candidate in settings.geminiAccounts where !candidate.isPrimary {
                if let key = await loadGeminiAPIKey(account: candidate.keychainAccount) {
                    promoted = (candidate, key)
                    break
                }
            }
            guard let successor = promoted?.account, let successorKey = promoted?.key else {
                try await clearGeminiAPIKey()
                return
            }
            try await geminiAPIKeyRepository.save(
                try GeminiAPIKey(successorKey),
                account: GeminiAccount.primaryKeychainAccount
            )
            try? await geminiAPIKeyRepository.clear(account: successor.keychainAccount)
            geminiUsageData = geminiAccountUsage[successor.id]
            geminiErrorMessage = geminiAccountErrors[successor.id]
            geminiAccountUsage[successor.id] = nil
            geminiAccountErrors[successor.id] = nil
            settings.geminiAccounts = settings.geminiAccounts
                .filter { $0.id != account.id && $0.id != successor.id }
                + [GeminiAccount(
                    id: successor.id,
                    label: successor.label,
                    keychainAccount: GeminiAccount.primaryKeychainAccount,
                    customLabel: successor.customLabel
                )]
            await refreshGeminiUsage()
            return
        }

        try? await geminiAPIKeyRepository.clear(account: account.keychainAccount)
        geminiAccountUsage[account.id] = nil
        geminiAccountErrors[account.id] = nil
        settings.geminiAccounts.removeAll { $0.id == account.id }
        await exportAggregateUsageSnapshot()
    }

    private func registerPrimaryGeminiAccountIfNeeded() {
        guard !settings.geminiAccounts.contains(where: { $0.isPrimary }) else { return }
        settings.geminiAccounts.append(.legacyPrimary(customLabel: settings.geminiCustomLabel))
    }

    func clearGeminiAPIKey() async throws {
        try await geminiAPIKeyRepository.clear(account: GeminiAccount.primaryKeychainAccount)
        for account in settings.geminiAccounts where !account.isPrimary {
            try? await geminiAPIKeyRepository.clear(account: account.keychainAccount)
        }
        settings.geminiAccounts = []
        geminiAccountUsage.removeAll()
        geminiAccountErrors.removeAll()
        hasGeminiAPIKey = false
        geminiUsageData = nil
        geminiErrorMessage = nil
        geminiCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
            health: .missing,
            failureCategory: .missing,
            checkedAt: Date()
        )
        await exportAggregateUsageSnapshot()
    }

    // MARK: - Session Key

    func loadSessionKey() async -> String? {
        do {
            return try await keychainRepository.retrieve(account: "default")
        } catch KeychainError.notFound {
            return nil
        } catch {
            return nil
        }
    }

    func validateAndSaveSessionKey(_ rawValue: String) async throws -> Bool {
        let sessionKey = try SessionKey(rawValue)
        let isValid = try await usageService.validateSessionKey(sessionKey)

        guard isValid else {
            claudeCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
                health: .invalid,
                failureCategory: .providerRejected,
                checkedAt: Date()
            )
            return false
        }

        let organizations = try await usageService.fetchOrganizations(sessionKey: sessionKey)
        // Prefer organization with chat capability (Claude.ai usage), fall back to first
        guard let chatOrg = organizations.first(where: { $0.hasChatCapability }) ?? organizations.first,
              let orgUUID = chatOrg.organizationUUID else {
            throw AppError.organizationNotFound
        }

        try await keychainRepository.save(sessionKey: sessionKey.value, account: "default")
        claudeCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: .valid,
            checkedAt: Date()
        )

        settings.cachedOrganizationId = orgUUID
        settings.isFirstLaunch = false
        isSetupComplete = true
        registerPrimaryClaudeAccount(chatOrg, organizationId: orgUUID)

        await refreshUsage(forceRefresh: true)
        startRefreshLoop()

        return true
    }

    /// Records the primary Claude account in `settings.claudeAccounts` while
    /// preserving any connected additional accounts. Used by both the single
    /// -account save path and multi-account import.
    private func registerPrimaryClaudeAccount(_ organization: Organization, organizationId: UUID) {
        let primary = ClaudeAccount(
            id: organization.uuid,
            label: organization.name,
            organizationId: organizationId,
            keychainAccount: ClaudeAccount.primaryKeychainAccount,
            profileLabel: settings.claudeAccounts.first(where: { $0.isPrimary })?.profileLabel,
            customLabel: settings.claudeAccounts.first(where: { $0.id == organization.uuid })?.customLabel
        )
        var accounts = settings.claudeAccounts.filter { !$0.isPrimary && $0.id != primary.id }
        accounts.insert(primary, at: 0)
        settings.claudeAccounts = accounts
    }

    /// Sets a user-chosen display label for a connected Claude account. An
    /// empty label reverts to the imported organization name.
    func renameClaudeAccount(id: String, customLabel: String) {
        guard let index = settings.claudeAccounts.firstIndex(where: { $0.id == id }) else { return }
        let isBlank = customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        settings.claudeAccounts[index].customLabel = isBlank ? nil : customLabel
    }

    func importAndSaveSessionKey() async throws -> ImportedSessionKey {
        try await importAndSaveSessionKey(from: .defaultBrowser)
    }

    func importAndSaveSessionKey(from source: BrowserImportSource) async throws -> ImportedSessionKey {
        try await importClaudeAccounts(from: source).primary
    }

    /// Connect one or more Claude subscriptions discovered across signed-in
    /// browser profiles. The first (or previously-primary) account keeps the
    /// legacy `"default"` Keychain slot; additional accounts are stored under
    /// their organization UUID. Deduplicates by organization so the same
    /// subscription imported from two profiles connects once.
    @discardableResult
    func importClaudeAccounts(from source: BrowserImportSource) async throws -> ClaudeAccountsImportResult {
        importProgress = "Scanning browser profiles\u{2026}"
        let importedKeys = try await sessionKeyImportService.importAllSessionKeys(from: source)
        return try await connectClaudeAccounts(importedKeys: importedKeys)
    }

    /// Validates the given imported session keys and connects every distinct
    /// organization among them. Callers that gather keys from multiple
    /// browsers must aggregate first and call this once: connecting replaces
    /// `settings.claudeAccounts`, so per-browser calls would drop the
    /// previous browser's accounts.
    @discardableResult
    func connectClaudeAccounts(importedKeys: [ImportedSessionKey]) async throws -> ClaudeAccountsImportResult {
        let connection = try await claudeAccountConnectionController.connect(
            importedKeys: importedKeys,
            excludedAccountIds: { [weak self] in
                Set(
                    self?.settings.scanExcludedAccounts
                        .filter { $0.provider == .claude }
                        .map(\.accountId) ?? []
                )
            },
            currentAccounts: { [weak self] in self?.settings.claudeAccounts ?? [] },
            progress: { [weak self] progress in self?.importProgress = progress },
            connectPrimary: { [weak self] key in
                guard let self else { return false }
                return try await self.validateAndSaveSessionKey(key)
            }
        )

        for staleId in connection.staleAccountIds {
            claudeAccountUsage[staleId] = nil
            claudeAccountErrors[staleId] = nil
        }

        settings.claudeAccounts = connection.accounts
        importProgress = nil
        await refreshAdditionalClaudeAccounts(forceRefresh: true)
        return connection.result
    }

    func importAndSaveChatGPTSessionCookie() async throws -> ImportedChatGPTSessionCookie {
        try await importAndSaveChatGPTSessionCookie(from: .defaultBrowser)
    }

    /// Connects every distinct ChatGPT account signed in across the source's
    /// browser profiles without disconnecting accounts from other sources,
    /// and returns the primary one's cookie so single-account callers keep
    /// their existing behavior.
    @discardableResult
    func importAndSaveChatGPTSessionCookie(from source: BrowserImportSource) async throws -> ImportedChatGPTSessionCookie {
        importProgress = "Scanning browser profiles\u{2026}"
        let imported = try await sessionKeyImportService.importAllChatGPTSessionCookies(from: source)
        var combined: [ImportedChatGPTSessionCookie] = []
        var seenCookieHeaders = Set<String>()

        // This entry point scans one browser source. Retain every connected
        // account it cannot see, while allowing a newly discovered copy of the
        // same normalized cookie to refresh that account's source label.
        for cookie in imported {
            let normalized = ChatGPTUsageService.cookieHeader(from: cookie.cookieHeader)
            guard !normalized.isEmpty, seenCookieHeaders.insert(normalized).inserted else { continue }
            combined.append(ImportedChatGPTSessionCookie(
                cookieHeader: normalized,
                sourceDescription: cookie.sourceDescription
            ))
        }
        for account in settings.chatGPTAccounts {
            guard let session = try? await chatGPTSessionRepository.load(account: account.keychainAccount) else {
                continue
            }
            let normalized = ChatGPTUsageService.cookieHeader(from: session.sessionCookie)
            guard !normalized.isEmpty, seenCookieHeaders.insert(normalized).inserted else { continue }
            // Never `displayLabel` here: it falls back to the provider-reported
            // account email, and this description is logged and persisted as the
            // account's `profileLabel`. A retained session keeps whatever browser
            // profile it already carried, or a constant.
            combined.append(ImportedChatGPTSessionCookie(
                cookieHeader: normalized,
                sourceDescription: account.profileLabel ?? Self.retainedSessionSourceDescription
            ))
        }

        do {
            _ = try await connectChatGPTAccounts(importedCookies: combined)
        } catch SessionKeyImportError.invalidImportedChatGPTSessionCookie
            where combined.count > imported.count && settings.chatGPTAccounts.count <= 1 {
            // Nothing validated, and retaining pushed the cookie count past the
            // one-cookie limit on the unvalidated fallback (see
            // ChatGPTAccountConnectionController.connect). That fallback is what
            // lets a reconnect succeed while offline, so retry with only the
            // discovered cookies and let it fire. Safe because the fallback
            // requires at most one already-connected account, so there is no
            // second account whose credential could be overwritten. The same
            // bound is asserted here rather than relied on inside the
            // controller: if the outage ends between the two calls the retry
            // takes the normal path, which prunes, and only this guard makes
            // the retry provably incapable of dropping an account.
            _ = try await connectChatGPTAccounts(importedCookies: imported)
        }

        let primaryCookie = try await chatGPTSessionRepository
            .load(account: ChatGPTAccount.primaryKeychainAccount)
            .sessionCookie
        let primaryAccount = settings.chatGPTAccounts.first { $0.isPrimary }
        return ImportedChatGPTSessionCookie(
            cookieHeader: primaryCookie,
            sourceDescription: primaryAccount?.profileLabel ?? imported.first?.sourceDescription ?? "browser"
        )
    }

    /// Validates the given imported cookies and connects every distinct
    /// ChatGPT account among them. The input is the complete desired account
    /// set because connecting replaces `settings.chatGPTAccounts`. The
    /// single-source import above includes existing Keychain sessions;
    /// multi-browser scans aggregate every browser before calling this once.
    @discardableResult
    func connectChatGPTAccounts(
        importedCookies: [ImportedChatGPTSessionCookie]
    ) async throws -> ChatGPTAccountsImportResult {
        let connection = try await chatGPTAccountConnectionController.connect(
            importedCookies: importedCookies,
            excludedAccountIds: { [weak self] in
                Set(
                    self?.settings.scanExcludedAccounts
                        .filter { $0.provider == .chatGPT }
                        .map(\.accountId) ?? []
                )
            },
            currentAccounts: { [weak self] in self?.settings.chatGPTAccounts ?? [] },
            progress: { [weak self] progress in self?.importProgress = progress }
        )

        for staleId in connection.staleAccountIds {
            chatGPTAccountUsage[staleId] = nil
            chatGPTAccountErrors[staleId] = nil
        }

        settings.chatGPTAccounts = connection.accounts
        hasChatGPTSessionCookie = true
        chatGPTCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
            health: .valid,
            checkedAt: Date()
        )
        settings.isChatGPTUsageShown = true
        importProgress = nil

        await refreshChatGPTUsage()
        await refreshAdditionalChatGPTAccounts()
        return ChatGPTAccountsImportResult(
            importedCount: connection.accounts.count,
            accountLabels: connection.connectedLabels,
            connectedSourceDescriptions: connection.accounts.compactMap(\.profileLabel)
        )
    }

    func performProviderCredentialAction(
        _ action: ProviderCredentialActionKind,
        for provider: CredentialProvider
    ) async throws -> CredentialState {
        switch (provider, action) {
        case (.claude, .reconnect):
            _ = try await importAndSaveSessionKey()
            return claudeCredentialState
        case (.claude, .repair):
            return await repairClaudeSessionKey()
        case (.claude, .clear):
            try await clearSessionKey()
            return claudeCredentialState
        case (.chatGPT, .reconnect):
            _ = try await importAndSaveChatGPTSessionCookie()
            return chatGPTCredentialState
        case (.chatGPT, .clear):
            try await clearChatGPTSessionCookie()
            return chatGPTCredentialState
        case (.gemini, .clear):
            try await clearGeminiAPIKey()
            return geminiCredentialState
        case (.chatGPT, .repair), (.gemini, .reconnect), (.gemini, .repair):
            throw AppProviderCredentialActionError.unsupportedAction(provider: provider, action: action)
        }
    }

    func importProviderSessions(from source: BrowserImportSource) async -> ProviderBrowserImportOutcome {
        let claudeStatus: ProviderBrowserImportStatus
        do {
            let imported = try await importAndSaveSessionKey(from: source)
            claudeStatus = .imported(sourceDescription: imported.sourceDescription)
        } catch let error as SessionKeyImportError {
            importProgress = nil
            claudeStatus = .failed(
                message: error.localizedDescription,
                offersFullDiskAccessSettings: error.offersFullDiskAccessSettings
            )
        } catch {
            importProgress = nil
            claudeStatus = .failed(message: error.localizedDescription, offersFullDiskAccessSettings: false)
        }

        importProgress = "Importing ChatGPT session\u{2026}"
        let chatGPTStatus: ProviderBrowserImportStatus
        do {
            let imported = try await importAndSaveChatGPTSessionCookie(from: source)
            chatGPTStatus = .imported(sourceDescription: imported.sourceDescription)
        } catch let error as SessionKeyImportError {
            chatGPTStatus = .failed(
                message: error.localizedDescription,
                offersFullDiskAccessSettings: error.offersFullDiskAccessSettings
            )
        } catch {
            chatGPTStatus = .failed(message: error.localizedDescription, offersFullDiskAccessSettings: false)
        }

        importProgress = nil
        return ProviderBrowserImportOutcome(
            source: source,
            claude: claudeStatus,
            chatGPT: chatGPTStatus
        )
    }

    func importFromOpenBrowsers() async -> BrowserScanOutcome {
        let running = runningBrowserSources()
        guard !running.isEmpty else {
            importProgress = nil
            return BrowserScanOutcome(scannedBrowsers: BrowserImportSource.scanTargets, results: [])
        }

        // Gather Claude session keys from every running browser before
        // connecting: connectClaudeAccounts replaces settings.claudeAccounts,
        // so importing browser-by-browser would drop earlier browsers' accounts.
        var gatheredKeys: [ImportedSessionKey] = []
        var seenKeyValues = Set<String>()
        var keyValuesByBrowser: [BrowserImportSource: Set<String>] = [:]
        var claudeScanFailures: [BrowserImportSource: ProviderBrowserImportStatus] = [:]

        for browser in running {
            importProgress = "Scanning \(browser.displayName)\u{2026}"
            do {
                let keys = try await sessionKeyImportService.importAllSessionKeys(from: browser)
                keyValuesByBrowser[browser] = Set(keys.map(\.value))
                for key in keys where seenKeyValues.insert(key.value).inserted {
                    gatheredKeys.append(key)
                }
            } catch let error as SessionKeyImportError {
                claudeScanFailures[browser] = .failed(
                    message: error.localizedDescription,
                    offersFullDiskAccessSettings: error.offersFullDiskAccessSettings
                )
            } catch {
                claudeScanFailures[browser] = .failed(message: error.localizedDescription, offersFullDiskAccessSettings: false)
            }
        }

        var connectedKeyValues = Set<String>()
        var connectionFailureMessage: String?
        if !gatheredKeys.isEmpty {
            do {
                let result = try await connectClaudeAccounts(importedKeys: gatheredKeys)
                connectedKeyValues = Set(result.connected.map(\.value))
            } catch {
                importProgress = nil
                connectionFailureMessage = error.localizedDescription
            }
        }

        // Same gather-then-connect-once rule as Claude above: connecting
        // replaces settings.chatGPTAccounts, so importing browser-by-browser
        // would drop the earlier browsers' ChatGPT accounts.
        var gatheredCookies: [ImportedChatGPTSessionCookie] = []
        var seenCookieHeaders = Set<String>()
        var cookieSourcesByBrowser: [BrowserImportSource: Set<String>] = [:]
        var chatGPTScanFailures: [BrowserImportSource: ProviderBrowserImportStatus] = [:]

        for browser in running {
            importProgress = "Scanning ChatGPT sessions (\(browser.displayName))\u{2026}"
            do {
                let cookies = try await sessionKeyImportService.importAllChatGPTSessionCookies(from: browser)
                cookieSourcesByBrowser[browser] = Set(cookies.map(\.sourceDescription))
                for cookie in cookies where seenCookieHeaders.insert(cookie.cookieHeader).inserted {
                    gatheredCookies.append(cookie)
                }
            } catch let error as SessionKeyImportError {
                chatGPTScanFailures[browser] = .failed(
                    message: error.localizedDescription,
                    offersFullDiskAccessSettings: error.offersFullDiskAccessSettings
                )
            } catch {
                chatGPTScanFailures[browser] = .failed(
                    message: error.localizedDescription,
                    offersFullDiskAccessSettings: false
                )
            }
        }

        var connectedChatGPTSources = Set<String>()
        var chatGPTConnectionFailureMessage: String?
        if !gatheredCookies.isEmpty {
            importProgress = "Connecting ChatGPT accounts\u{2026}"
            do {
                let result = try await connectChatGPTAccounts(importedCookies: gatheredCookies)
                connectedChatGPTSources = Set(result.connectedSourceDescriptions)
            } catch {
                importProgress = nil
                chatGPTConnectionFailureMessage = error.localizedDescription
            }
        }

        var results: [BrowserScanOutcome.BrowserResult] = []
        for browser in running {
            let claudeStatus: ProviderBrowserImportStatus
            let browserKeyValues = keyValuesByBrowser[browser] ?? []
            if let connectedKey = gatheredKeys.first(where: {
                browserKeyValues.contains($0.value) && connectedKeyValues.contains($0.value)
            }) {
                claudeStatus = .imported(sourceDescription: connectedKey.sourceDescription)
            } else if let failure = claudeScanFailures[browser] {
                claudeStatus = failure
            } else {
                claudeStatus = .failed(
                    message: connectionFailureMessage ?? SessionKeyImportError.invalidImportedSessionKey.localizedDescription,
                    offersFullDiskAccessSettings: false
                )
            }

            let chatGPTStatus: ProviderBrowserImportStatus
            let browserCookieSources = cookieSourcesByBrowser[browser] ?? []
            if let connectedSource = browserCookieSources.first(where: { connectedChatGPTSources.contains($0) }) {
                chatGPTStatus = .imported(sourceDescription: connectedSource)
            } else if let failure = chatGPTScanFailures[browser] {
                chatGPTStatus = failure
            } else {
                chatGPTStatus = .failed(
                    message: chatGPTConnectionFailureMessage
                        ?? SessionKeyImportError.invalidImportedChatGPTSessionCookie.localizedDescription,
                    offersFullDiskAccessSettings: false
                )
            }

            results.append(BrowserScanOutcome.BrowserResult(
                source: browser,
                claude: claudeStatus,
                chatGPT: chatGPTStatus
            ))
        }

        importProgress = nil
        return BrowserScanOutcome(scannedBrowsers: BrowserImportSource.scanTargets, results: results)
    }

    private func recoverBrowserSessionsIfNeeded() async {
        var failedProviders = Set<CredentialProvider>()
        if (isSetupComplete || !settings.claudeAccounts.isEmpty),
           [.missing, .providerRejected].contains(claudeCredentialState.failureCategory) {
            failedProviders.insert(.claude)
        }
        if settings.isChatGPTUsageShown,
           [.missing, .providerRejected].contains(chatGPTCredentialState.failureCategory) {
            failedProviders.insert(.chatGPT)
        }

        promptedBrowserProviders.formIntersection(failedProviders)
        guard !failedProviders.isEmpty, !isRecoveringBrowserSessions else { return }

        isRecoveringBrowserSessions = true
        _ = await importFromOpenBrowsers()
        isRecoveringBrowserSessions = false

        let stillFailed = failedProviders.filter { provider in
            switch provider {
            case .claude: !claudeCredentialState.isUsable
            case .chatGPT: !chatGPTCredentialState.isUsable
            case .gemini: false
            }
        }
        let unprompted = stillFailed.subtracting(promptedBrowserProviders)
        guard !unprompted.isEmpty else { return }

        promptedBrowserProviders.formUnion(unprompted)
        browserLoginPrompt(unprompted.map(\.displayName).sorted())
    }

    func repairClaudeSessionKey() async -> CredentialState {
        claudeCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: .validating,
            checkedAt: Date()
        )

        let repairedState = await sessionKeyImportService.repairSavedSessionKey(account: "default")
        claudeCredentialState = repairedState

        if repairedState.isUsable {
            isSetupComplete = true
            await refreshUsage(forceRefresh: true)
        }

        return claudeCredentialState
    }

    /// Disconnects a single connected Claude account.
    ///
    /// - Non-primary account: deletes its per-org Keychain item and drops its
    ///   cached usage/errors.
    /// - Primary account with other accounts connected: promotes the next
    ///   account in popover order (alphabetical by `displayLabel`) into the
    ///   primary `"default"` slot via the tested save path, then removes the
    ///   old primary and the promoted account's stale per-org Keychain item.
    ///   If promotion fails, state is left unchanged and the error is surfaced.
    /// - Last remaining account (or a legacy single-account install): clears
    ///   the Claude credential entirely via `clearSessionKey()`.
    func removeClaudeAccount(id: String) async throws {
        guard let account = settings.claudeAccounts.first(where: { $0.id == id }) else {
            if settings.claudeAccounts.isEmpty {
                try await clearSessionKey()
            }
            return
        }

        guard settings.claudeAccounts.count > 1 else {
            try await clearSessionKey()
            return
        }

        if account.isPrimary {
            let remaining = settings.claudeAccounts.filter { $0.id != id }
            let promoted = remaining.sorted { lhs, rhs in
                lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
            }.first

            guard let promoted else {
                try await clearSessionKey()
                return
            }

            let promotedKey = try await keychainRepository.retrieve(account: promoted.keychainAccount)

            // `validateAndSaveSessionKey` mutates `claudeCredentialState` on a
            // failed validation. If promotion fails, the old primary's key is
            // still the valid `"default"` credential, so restore the prior
            // state to avoid falsely flagging it as invalid.
            let previousCredentialState = claudeCredentialState
            let promotedValid: Bool
            do {
                promotedValid = try await validateAndSaveSessionKey(promotedKey)
            } catch {
                claudeCredentialState = previousCredentialState
                throw error
            }
            guard promotedValid else {
                claudeCredentialState = previousCredentialState
                throw SessionKeyImportError.invalidImportedSessionKey
            }

            // `validateAndSaveSessionKey` re-registers the promoted org as the
            // primary account under "default" and preserves its custom label.
            // The old primary was primary, so it is already dropped from
            // `settings.claudeAccounts`; the "default" Keychain slot now holds
            // the promoted key. Clear the removed account's cached state.
            claudeAccountUsage[id] = nil
            claudeAccountErrors[id] = nil

            // Normally the new primary is the promoted org. Guard against org
            // drift: if the promoted key now resolves to a different org (its
            // capabilities or org list changed since import), the promoted
            // account survives as a non-primary entry, so its per-org Keychain
            // item must stay and the profile-label restore must not target the
            // wrong account.
            if settings.claudeAccounts.first(where: { $0.isPrimary })?.id == promoted.id {
                // The promoted org is now the "default" primary; its old per-org
                // Keychain item is redundant. `registerPrimaryClaudeAccount`
                // carried the *previous* primary's profile label, so restore the
                // promoted account's own.
                try? await keychainRepository.delete(account: promoted.keychainAccount)
                claudeAccountUsage[promoted.id] = nil
                claudeAccountErrors[promoted.id] = nil
                if let promotedIndex = settings.claudeAccounts.firstIndex(where: { $0.isPrimary }) {
                    settings.claudeAccounts[promotedIndex].profileLabel = promoted.profileLabel
                }
            }

            await refreshAdditionalClaudeAccounts(forceRefresh: true)
            return
        }

        try? await keychainRepository.delete(account: account.keychainAccount)
        settings.claudeAccounts.removeAll { $0.id == id }
        claudeAccountUsage[id] = nil
        claudeAccountErrors[id] = nil
        await refreshAdditionalClaudeAccounts(forceRefresh: true)
    }

    func excludeClaudeAccountFromScans(id: String) async throws {
        guard let account = settings.claudeAccounts.first(where: { $0.id == id }) else { return }
        let excluded = ScanExcludedAccount.claude(account)
        try await removeClaudeAccount(id: id)
        upsertScanExclusion(excluded)
    }

    func reenableScanAccount(id: String) {
        settings.scanExcludedAccounts.removeAll { $0.id == id }
    }

    private func upsertScanExclusion(_ excluded: ScanExcludedAccount) {
        settings.scanExcludedAccounts.removeAll { $0.id == excluded.id }
        settings.scanExcludedAccounts.append(excluded)
    }

    func clearSessionKey() async throws {
        try await keychainRepository.delete(account: "default")
        for account in settings.claudeAccounts where !account.isPrimary {
            try? await keychainRepository.delete(account: account.keychainAccount)
        }
        settings.claudeAccounts = []
        claudeAccountUsage.removeAll()
        claudeAccountErrors.removeAll()
        settings.cachedOrganizationId = nil
        settings.isFirstLaunch = true
        isSetupComplete = false
        claudeCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: .missing,
            failureCategory: .missing,
            checkedAt: Date()
        )
        usageData = nil
        errorMessage = nil
        startRefreshLoop()
        await exportAggregateUsageSnapshot()
    }

    // MARK: - Notifications

    func requestNotificationPermissionIfNeeded() async {
        let hasPermission = await notificationService.checkNotificationPermissions()
        if !hasPermission {
            _ = try? await notificationService.requestAuthorization()
        }
    }

    func checkNotificationPermissions() async -> Bool {
        await notificationService.checkNotificationPermissions()
    }

    func sendTestNotification() async throws {
        try await notificationService.sendThresholdNotification(
            percentage: 85.0,
            threshold: .warning,
            resetTime: Date().addingTimeInterval(3600)
        )
    }

    func installAvailableUpdate() {
        appUpdater?.installAvailableUpdate()
    }

    func checkForUpdatesIfNeeded(now: Date = Date()) async {
        guard let releaseCheckService, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        await sendAvailableUpdateNotificationIfNeeded()
        await sendInstructionRecheckReminderIfNeeded(now: now)
        if let lastCheck = settings.lastUpdateCheckAt,
           now.timeIntervalSince(lastCheck) < 24 * 60 * 60 {
            return
        }

        settings.lastUpdateCheckAt = now

        do {
            let update = try await releaseCheckService.latestRelease()
            if update.isNewer(than: installedVersion) {
                settings.availableUpdateVersion = update.version
            } else {
                settings.availableUpdateVersion = nil
            }
        } catch {
            Self.logger.debug("Update check failed: \(error.localizedDescription, privacy: .public)")
        }

        await sendAvailableUpdateNotificationIfNeeded()
        await sendInstructionRecheckReminderIfNeeded(now: now)
    }

    /// Nudges the user when the recorded instruction check has stopped being
    /// evidence about this machine (`InstructionRecheck`).
    ///
    /// Internal rather than private so the throttle can be exercised without
    /// driving the update-check loop it rides on.
    func sendInstructionRecheckReminderIfNeeded(now: Date = Date()) async {
        guard settings.broker.isEnabled,
              settings.broker.recheckReminderEnabled,
              settings.hasNotificationsEnabled,
              await notificationService.checkNotificationPermissions() else {
            return
        }

        let check = await brokerService.latestInstructionCheck()
        guard let reason = InstructionRecheck.reason(
            for: check,
            currentVersion: BrokerMCPServer.appVersion,
            now: now
        ), reason != .neverChecked else {
            // A machine that has never run a check is not drifting, it is
            // unconfigured. The setup prompt is the answer there, and the
            // Instructions pane already asks for it.
            return
        }

        if let notifiedAt = settings.lastInstructionRecheckNotifiedAt {
            // A check recorded since the last reminder re-arms it: the user
            // acted, and whatever they ran is now the record being judged.
            let reArmedByNewerCheck = check.map { notifiedAt < $0.checkedAt } ?? false
            guard reArmedByNewerCheck
                    || now.timeIntervalSince(notifiedAt) >= InstructionRecheck.interval else {
                return
            }
        }

        do {
            try await notificationService.sendInstructionRecheckReminder(reason: reason)
            settings.lastInstructionRecheckNotifiedAt = now
        } catch {
            Self.logger.debug(
                "Instruction re-check reminder failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Broker preset manifest

    /// How often ``refreshPresetManifest(force:)`` re-checks on its own,
    /// mirroring the update-check loop's throttle idiom but on a much
    /// shorter cadence: the manifest is meant to be cheap to poll (a 304 on
    /// every unchanged check) and the whole point is that a newly published
    /// preset shows up the same day, not after a 24-hour wait.
    private static let presetManifestRefreshInterval: TimeInterval = 6 * 60 * 60

    /// Refreshes the remote preset manifests — extra named rule profiles the
    /// user may explicitly apply from the profile bar. Never routes anything
    /// by itself: only ``BrokerSettings/remotePresets`` changes here, never
    /// `policy` or the active-profile pin (``BrokerSettings/updateRemotePresets(_:)``).
    ///
    /// No-op when the feature is off or the broker is off (unless `force`).
    /// On failure the source's previous presets are kept — stale-but-usable
    /// beats empty — and a short, sanitised error is stored for its UI row.
    func refreshPresetManifest(force: Bool = false) async {
        guard let presetManifestService else { return }
        guard settings.broker.presetManifest.isEnabled else { return }
        guard force || settings.broker.isEnabled else { return }

        // A pre-migration save has one aggregate cache but no per-source
        // cache. Attribute it to the first source so adding another URL before
        // the first refresh cannot make a 304 discard the presets already saved.
        if let firstSourceIndex = settings.broker.presetManifest.sources.indices.first,
           settings.broker.presetManifest.sources.allSatisfy({ $0.cachedPresets.isEmpty }),
           !settings.broker.remotePresets.isEmpty {
            settings.broker.presetManifest.sources[firstSourceIndex].cachedPresets =
                settings.broker.remotePresets
        }

        for sourceID in settings.broker.presetManifest.sources.map(\.id) {
            guard !Task.isCancelled,
                  let sourceIndex = settings.broker.presetManifest.sources.firstIndex(
                    where: { $0.id == sourceID }
                  )
            else { break }
            let source = settings.broker.presetManifest.sources[sourceIndex]
            if !force, let lastCheckedAt = source.lastCheckedAt,
               Date().timeIntervalSince(lastCheckedAt) < Self.presetManifestRefreshInterval {
                continue
            }

            // Trimmed exactly like `BrokerPresetManifestCard.isURLValid`: a
            // pasted URL routinely carries leading/trailing whitespace.
            let trimmedURLString = source.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            // A row the user has just added and not typed into yet is not a
            // failure: the field already says what it wants, and stamping an
            // error under an empty box reads as something having gone wrong.
            if trimmedURLString.isEmpty { continue }
            guard let url = URL(string: trimmedURLString),
                  url.scheme?.lowercased() == "https" else {
                settings.broker.presetManifest.sources[sourceIndex].lastCheckedAt = Date()
                settings.broker.presetManifest.sources[sourceIndex].lastError =
                    "The manifest URL must use https."
                continue
            }

            do {
                let outcome = try await presetManifestService.fetch(from: url, etag: source.etag)
                guard let currentIndex = settings.broker.presetManifest.sources.firstIndex(
                    where: { $0.id == sourceID && $0.urlString == source.urlString }
                ) else { continue }
                switch outcome {
                case .notModified:
                    settings.broker.presetManifest.sources[currentIndex].lastCheckedAt = Date()
                    settings.broker.presetManifest.sources[currentIndex].lastError = nil
                case .updated(let manifest, let etag):
                    settings.broker.presetManifest.sources[currentIndex].cachedPresets = manifest.presets
                    settings.broker.presetManifest.sources[currentIndex].etag = etag
                    settings.broker.presetManifest.sources[currentIndex].lastCheckedAt = Date()
                    settings.broker.presetManifest.sources[currentIndex].lastError = nil
                }
            } catch is CancellationError {
                break
            } catch {
                guard let currentIndex = settings.broker.presetManifest.sources.firstIndex(
                    where: { $0.id == sourceID && $0.urlString == source.urlString }
                ) else { continue }
                settings.broker.presetManifest.sources[currentIndex].lastCheckedAt = Date()
                settings.broker.presetManifest.sources[currentIndex].lastError =
                    Self.sanitizedManifestError(error)
            }
        }

        mergePresetManifestSources()
    }

    /// Clears state belonging to the URL a source replaced.
    ///
    /// Without this, editing the URL keeps the OLD URL's ETag around: the
    /// first fetch against the new URL would send `If-None-Match` for a
    /// document the new server never served, which can land a coincidental
    /// 304 and leave `remotePresets` silently holding the previous URL's
    /// presets under the new URL's name. Clearing `lastCheckedAt` alongside
    /// it also means the next refresh is not skipped by the freshness
    /// throttle.
    func presetManifestURLChanged(sourceID: UUID? = nil) {
        guard let index = settings.broker.presetManifest.sources.firstIndex(
            where: { sourceID == nil || $0.id == sourceID }
        ) else { return }
        settings.broker.presetManifest.sources[index].etag = nil
        settings.broker.presetManifest.sources[index].lastCheckedAt = nil
        settings.broker.presetManifest.sources[index].lastError = nil
        settings.broker.presetManifest.sources[index].cachedPresets = []
        // Publish the clearing straight away. Leaving the old URL's presets in
        // `remotePresets` would satisfy the pre-migration attribution block in
        // `refreshPresetManifest` on the next run, which would copy them back
        // into this source and persist them under the NEW URL — the exact
        // cross-attribution the clearing above exists to prevent.
        mergePresetManifestSources()
    }

    /// Appends an empty manifest row for the user to paste a URL into.
    /// Empty on purpose: pre-filling it with the default URL would create a
    /// duplicate of the row above in the common case.
    func addPresetManifestSource() {
        settings.broker.presetManifest.sources.append(
            BrokerPresetManifestSource(urlString: "")
        )
    }

    /// Drops a manifest row and re-merges, so the presets that source
    /// contributed stop being offered as soon as it is removed rather than
    /// lingering until the next fetch.
    func removePresetManifestSource(id: UUID) {
        settings.broker.presetManifest.sources.removeAll { $0.id == id }
        mergePresetManifestSources()
    }

    private func mergePresetManifestSources() {
        var merged: [BrokerAgentProfile] = []
        var seen = Set<UUID>()
        for source in settings.broker.presetManifest.sources {
            for preset in source.cachedPresets where seen.insert(preset.id).inserted {
                merged.append(preset)
                if merged.count == BrokerPresetManifest.maxPresets {
                    settings.broker.updateRemotePresets(merged)
                    return
                }
            }
        }
        settings.broker.updateRemotePresets(merged)
    }

    /// First-run / offline seeding: when no successful fetch has ever landed
    /// and no presets are stored yet, load the copy bundled with the app so
    /// the "From manifest" section is not empty before the network answers.
    /// Goes through the identical validating decode a remote payload gets —
    /// a bundled file earns no more trust than a fetched one.
    private func seedBundledPresetManifestIfNeeded() {
        guard settings.broker.remotePresets.isEmpty,
              let sourceIndex = settings.broker.presetManifest.sources.indices.first,
              settings.broker.presetManifest.sources.allSatisfy({ $0.lastCheckedAt == nil }),
              let url = Bundle.main.url(forResource: "broker-presets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? BrokerPresetManifest.decode(from: data)
        else { return }
        settings.broker.presetManifest.sources[sourceIndex].cachedPresets = manifest.presets
        mergePresetManifestSources()
    }

    /// A fetch failure's description, made safe to store and render in the
    /// settings UI: control characters, newlines and default-ignorable
    /// scalars become `?`, and the result is capped. Mirrors
    /// `BrokerPolicy.redactedCaller`'s reasoning — the error text ultimately
    /// comes from a server response (or `URLError`/`DecodingError` built from
    /// one), so it gets the same treatment as any other untrusted string that
    /// reaches the UI.
    private static func sanitizedManifestError(_ error: Error) -> String {
        let maxScalars = 200
        let scalars = error.localizedDescription.unicodeScalars.prefix(maxScalars).map { scalar -> Character in
            let unsafe = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || scalar.properties.isDefaultIgnorableCodePoint
            return unsafe ? "?" : Character(scalar)
        }
        return String(scalars)
    }

    // MARK: - Private

    /// Row set shared by the CLI export file and the broker's first-party
    /// oracle (D-03, D-10): both are built from this one assembly so they
    /// can never drift apart.
    private struct AggregateQuotaRows {
        let claudeAccounts: [ClaudeAccountQuotaSnapshot]
        let chatGPT: ChatGPTQuotaSnapshot
        let gemini: GeminiQuotaSnapshot
        let oracleChatGPTRows: [OracleSnapshot.ChatGPTRow]
    }

    private func t3UsageInstanceAvailability(
        from liveness: [String: T3Liveness]
    ) -> T3UsageInstanceAvailability {
        guard settings.broker.isEnabled,
              !settings.broker.policy.t3Instances.isEmpty else {
            return .absent
        }
        let configuredIDs = Set(settings.broker.policy.t3Instances.map(\.id))
        return liveness.contains { configuredIDs.contains($0.key) && $0.value.reachable }
            ? .reachable
            : .unreachable
    }

    private func usageTelemetryQuotaSnapshot(generatedAt: Date) -> UsageTelemetryQuotaSnapshot {
        let rows = buildAggregateQuotaRows(generatedAt: generatedAt)
        let claude = rows.claudeAccounts.map { account in
            UsageTelemetryQuotaSnapshot.ClaudeAccount(
                id: account.id,
                isPrimary: account.isPrimary,
                freshness: UsageTelemetryFreshness(rawValue: account.state.rawValue) ?? .unavailable,
                lastUpdated: account.usage?.lastUpdated,
                session: .init(
                    utilization: account.usage?.sessionUsage.percentage,
                    resetAt: account.usage?.sessionUsage.resetAt
                ),
                weekly: .init(
                    utilization: account.usage?.weeklyUsage.percentage,
                    resetAt: account.usage?.weeklyUsage.resetAt
                ),
                sonnet: .init(
                    utilization: account.usage?.sonnetUsage?.percentage,
                    resetAt: account.usage?.sonnetUsage?.resetAt
                ),
                fable: .init(
                    utilization: account.usage?.fableUsage?.percentage,
                    resetAt: account.usage?.fableUsage?.resetAt
                )
            )
        }
        let chatGPT = UsageTelemetryQuotaSnapshot.ChatGPT(
            freshness: UsageTelemetryFreshness(rawValue: rows.chatGPT.state.rawValue) ?? .unavailable,
            lastUpdated: rows.chatGPT.lastUpdated,
            rows: chatGPTQuotaSources.flatMap { source in
                source.usage.rows.map {
                    UsageTelemetryQuotaSnapshot.ChatGPTRow(
                        label: source.isPrimary ? $0.label : "\(source.label) \($0.label)",
                        role: $0.menuBarRole,
                        utilization: $0.usedPercent,
                        resetAt: $0.resetAt
                    )
                }
            },
            failure: chatGPTErrorMessage == nil ? nil : (chatGPTLastFailure ?? .unknown),
            httpStatusCode: chatGPTErrorMessage == nil ? nil : chatGPTLastFailureStatusCode
        )
        return UsageTelemetryQuotaSnapshot(claudeAccounts: claude, chatGPT: chatGPT)
    }

    /// Every connected ChatGPT account that has usage, primary first, paired
    /// with the label its rows are attributed to.
    ///
    /// The label is `brokerLabel`, not `displayLabel`: these rows are served
    /// over the broker's loopback MCP port and persisted in the audit log, and
    /// the provider-reported label is the account's email address.
    private var chatGPTQuotaSources: [(label: String, isPrimary: Bool, usage: ChatGPTUsageData)] {
        let accounts = orderedChatGPTAccounts
        guard !accounts.isEmpty else {
            return chatGPTUsageData.map { [(chatGPTDisplayLabel, true, $0)] } ?? []
        }
        return accounts.compactMap { account in
            let usage = account.isPrimary ? chatGPTUsageData : chatGPTAccountUsage[account.id]
            return usage.map { (account.brokerLabel, account.isPrimary, $0) }
        }
    }

    private func buildAggregateQuotaRows(generatedAt: Date) -> AggregateQuotaRows {
        let primaryAccounts = settings.claudeAccounts.filter(\.isPrimary)
        let additionalAccounts = settings.claudeAccounts.filter { !$0.isPrimary }
        let accounts = primaryAccounts + additionalAccounts
        var claudeAccounts = accounts.map { account in
            let usage = account.isPrimary ? usageData : claudeAccountUsage[account.id]
            let hasError = account.isPrimary ? errorMessage != nil : claudeAccountErrors[account.id] != nil
            return ClaudeAccountQuotaSnapshot(
                id: account.id,
                label: account.displayLabel,
                isPrimary: account.isPrimary,
                state: Self.aggregateQuotaState(generatedAt: generatedAt, lastUpdated: usage?.lastUpdated, hasError: hasError),
                usage: usage
            )
        }
        if claudeAccounts.isEmpty, usageData != nil || isSetupComplete {
            claudeAccounts = [ClaudeAccountQuotaSnapshot(
                id: ClaudeAccount.primaryKeychainAccount,
                label: "Claude",
                isPrimary: true,
                state: Self.aggregateQuotaState(generatedAt: generatedAt, lastUpdated: usageData?.lastUpdated, hasError: errorMessage != nil),
                usage: usageData
            )]
        }

        // Every connected ChatGPT account contributes its rows, each tagged
        // with the account it came from so a broker lane can gate on one
        // account rather than on whichever account happened to report first.
        let allChatGPTRows: [(account: String, row: ChatGPTUsageData.LimitRow)] = chatGPTQuotaSources
            .flatMap { source in source.usage.rows.map { (source.label, $0) } }
        let chatGPTRows = allChatGPTRows.map {
            ChatGPTQuotaRowSnapshot(label: $0.row.label, usedPercent: $0.row.usedPercent, resetAt: $0.row.resetAt)
        }
        let chatGPT = ChatGPTQuotaSnapshot(
            label: chatGPTDisplayLabel,
            state: Self.aggregateQuotaState(generatedAt: generatedAt, lastUpdated: chatGPTUsageData?.lastUpdated, hasError: chatGPTErrorMessage != nil),
            lastUpdated: chatGPTUsageData?.lastUpdated,
            rows: chatGPTRows
        )
        let oracleChatGPTRows = Array(allChatGPTRows.prefix(OracleSnapshot.maxChatGPTRows)).map {
            OracleSnapshot.ChatGPTRow(
                label: $0.row.label,
                usedPercent: $0.row.usedPercent,
                resetAt: $0.row.resetAt,
                windowRole: $0.row.menuBarRole,
                windowSeconds: $0.row.windowSeconds,
                account: $0.account
            )
        }
        let gemini = GeminiQuotaSnapshot(
            label: geminiDisplayLabel,
            state: Self.aggregateQuotaState(generatedAt: generatedAt, lastUpdated: geminiUsageData?.lastUpdated, hasError: geminiErrorMessage != nil),
            quota: geminiUsageData.map {
                GeminiQuotaSnapshot.Quota(label: $0.label, usedPercent: $0.usedPercent, resetAt: $0.resetAt, lastUpdated: $0.lastUpdated)
            }
        )

        return AggregateQuotaRows(
            claudeAccounts: claudeAccounts,
            chatGPT: chatGPT,
            gemini: gemini,
            oracleChatGPTRows: oracleChatGPTRows
        )
    }

    /// Writes the CLI-consumed export file (unchanged schema, D-10) and
    /// pushes a fresh `OracleSnapshot` to the broker (D-03) from the same
    /// assembly, on every refresh path. The broker push does not depend on
    /// `cacheRepository` being configured — the broker must see live state
    /// even when the export file is disabled (e.g. under test).
    // Internal rather than private so a test can assert on what the broker is
    // actually handed, without driving a full bootstrap.
    func exportAggregateUsageSnapshot(generatedAt: Date = Date()) async {
        let rows = buildAggregateQuotaRows(generatedAt: generatedAt)

        if let cacheRepository {
            await cacheRepository.writeAggregateSnapshot(AggregateQuotaSnapshot(
                generatedAt: generatedAt,
                primaryUsage: usageData,
                claudeAccounts: rows.claudeAccounts,
                chatGPT: rows.chatGPT,
                gemini: rows.gemini
            ))
        }

        await brokerService.updateOracleSnapshot(
            Self.makeOracleSnapshot(
                generatedAt: generatedAt,
                rows: rows,
                chatGPTConfigured: hasChatGPTSessionCookie
            )
        )
    }

    /// - Parameter chatGPTConfigured: Whether a ChatGPT credential exists,
    ///   passed in rather than derived from `rows` because every state in
    ///   `rows` is derived from fetched *data*, which is nil until the first
    ///   poll of each launch.
    private static func makeOracleSnapshot(
        generatedAt: Date,
        rows: AggregateQuotaRows,
        chatGPTConfigured: Bool
    ) -> OracleSnapshot {
        let accounts = rows.claudeAccounts.map { snapshot in
            OracleSnapshot.AccountRow(
                id: snapshot.id,
                label: snapshot.label,
                isPrimary: snapshot.isPrimary,
                lastUpdated: snapshot.usage?.lastUpdated,
                state: snapshot.state.brokerQuotaState,
                session: snapshot.usage?.sessionUsage.percentage,
                weekly: snapshot.usage?.weeklyUsage.percentage,
                sonnet: snapshot.usage?.sonnetUsage?.percentage,
                fable: snapshot.usage?.fableUsage?.percentage,
                sessionResetAt: snapshot.usage?.sessionUsage.resetAt,
                weeklyResetAt: snapshot.usage?.weeklyUsage.resetAt,
                sonnetResetAt: snapshot.usage?.sonnetUsage?.resetAt,
                fableResetAt: snapshot.usage?.fableUsage?.resetAt
            )
        }
        return OracleSnapshot(
            generatedAt: generatedAt,
            accounts: accounts,
            chatGPTState: rows.chatGPT.state.brokerQuotaState,
            chatGPTRows: rows.oracleChatGPTRows,
            chatGPTLastUpdated: rows.chatGPT.lastUpdated,
            // Credential presence, not data presence: the broker uses this to
            // tell "no ChatGPT on this machine" apart from "not polled yet".
            // `chatGPTUsageData` is seeded from an on-disk cache at bootstrap
            // now, but only when a previous successful poll wrote one --
            // a fresh install, a cleared cache, or a machine that has never
            // fetched successfully still starts this launch with it nil.
            chatGPTConfigured: chatGPTConfigured
        )
    }

    static func aggregateQuotaState(
        generatedAt: Date,
        lastUpdated: Date?,
        hasError: Bool
    ) -> AggregateQuotaState {
        if hasError { return .error }
        guard let lastUpdated else { return .unavailable }
        return BrokerFreshness.isFresh(
            lastUpdated,
            now: generatedAt,
            threshold: Constants.Refresh.stalenessThreshold
        ) ? .fresh : .stale
    }

    private func credentialActions(for state: CredentialState) -> [AppProviderCredentialStatus.Action] {
        let kinds: [ProviderCredentialActionKind]
        if state.identity.kind == .apiKey {
            switch state.health {
            case .unknown, .missing, .validating:
                kinds = []
            case .valid, .refreshRecommended, .invalid, .expired, .unavailable:
                kinds = [.clear]
            }
        } else {
            switch state.health {
            case .unknown, .missing:
                kinds = [.reconnect]
            case .validating:
                kinds = []
            case .valid, .refreshRecommended:
                kinds = [.reconnect, .clear]
            case .invalid, .expired, .unavailable:
                kinds = state.identity.provider == .claude ? [.reconnect, .repair, .clear] : [.reconnect, .clear]
            }
        }
        return kinds.map(AppProviderCredentialStatus.Action.init(kind:))
    }

    private func sendAvailableUpdateNotificationIfNeeded() async {
        guard let version = settings.availableUpdateVersion,
              settings.lastNotifiedUpdateVersion != version,
              settings.hasNotificationsEnabled,
              await notificationService.checkNotificationPermissions() else {
            return
        }

        do {
            try await notificationService.sendUpdateAvailableNotification(version: version)
            settings.lastNotifiedUpdateVersion = version
        } catch {
            Self.logger.debug("Update notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func credentialState(
        from status: ChatGPTSessionAcquisitionStatus,
        checkedAt: Date
    ) -> CredentialState {
        CredentialState(
            identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
            health: status.state.credentialHealth,
            failureCategory: status.lastErrorCategory?.credentialFailureCategory ?? status.state.defaultFailureCategory,
            checkedAt: checkedAt
        )
    }

    private static func credentialState(
        from status: GeminiAPIKeyAcquisitionStatus,
        checkedAt: Date
    ) -> CredentialState {
        CredentialState(
            identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
            health: status.state.credentialHealth,
            failureCategory: status.lastErrorCategory?.credentialFailureCategory ?? status.state.defaultFailureCategory,
            checkedAt: checkedAt
        )
    }

    private static func joinedProviderNames(_ names: [String]) -> String {
        switch names.count {
        case 0:
            return ""
        case 1:
            return names[0]
        case 2:
            return "\(names[0]) and \(names[1])"
        default:
            return "\(names.dropLast().joined(separator: ", ")), and \(names[names.count - 1])"
        }
    }

    private func scheduleSettingsSave(previous: AppSettings) {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task {
            try? await settingsRepository.save(settings)
        }

        if previous.refreshInterval != settings.refreshInterval {
            startRefreshLoop()
        }
    }

    /// One iteration of the periodic refresh loop's provider refreshes plus
    /// the T3 liveness piggyback (RESEARCH Open Question 4 — no dedicated
    /// timer). Internal rather than private so `BrokerAppModelTests` can
    /// exercise the liveness piggyback directly instead of waiting out the
    /// loop's own `Constants.Refresh.minimum` (60s) interval.
    func performScheduledRefreshTick() async {
        if await reconcileDiscoveredT3Instances() {
            await brokerService.updatePolicy(settings.broker.policy)
        }
        _ = await brokerService.refreshT3Liveness()
        await refreshConfiguredUsageProviders()
    }

    /// Runs a T3 discovery scan and reconciles it into `settings.broker.policy`.
    /// A `nil` scan (unreadable source) is a no-op — `settings`'s `didSet`
    /// handles persistence for any change, so no explicit save is added here.
    /// `discoveredT3Instances` deliberately keeps its previous value on a
    /// `nil` scan: a transient unreadable state must not empty the add menu
    /// (review IN-03, accepted behavior). Returns whether the policy changed.
    ///
    /// Discovery runs only while the broker is enabled (review WR-06): a
    /// disabled broker must cause no `~/.t3` file access and no settings
    /// rewrites.
    @discardableResult
    private func reconcileDiscoveredT3Instances() async -> Bool {
        guard settings.broker.isEnabled else { return false }
        guard let discovered = await t3InstanceDiscovery.scan() else { return false }
        discoveredT3Instances = discovered
        return settings.broker.policy.reconcileDiscoveredT3Instances(discovered)
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = nil
        guard isSetupComplete || hasChatGPTSessionCookie || hasGeminiAPIKey || settings.broker.isEnabled else { return }

        let interval = Duration.seconds(Int(settings.refreshInterval))
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.refreshClock.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.performScheduledRefreshTick()
            }
        }
    }

    func performWakeRefresh() async {
        await refreshConfiguredUsageProviders(forceRefresh: true)
        await checkForUpdatesIfNeeded()
    }

    private func startWakeObserver() {
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            guard let self else { return }
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                await self.performWakeRefresh()
            }
        }
    }

    private func startUpdateCheckLoop() {
        updateCheckTask?.cancel()
        guard releaseCheckService != nil else { return }

        updateCheckTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.checkForUpdatesIfNeeded()
                try? await self.refreshClock.sleep(for: .seconds(3_600))
            }
        }
    }

    /// Periodic preset-manifest refresh. `bootstrap()` already kicks off one
    /// check (fire-and-forget) before this starts, so the loop sleeps first
    /// — a second immediate check right after the bootstrap one would just
    /// spend a round-trip confirming nothing changed.
    private func startPresetManifestRefreshLoop() {
        presetManifestRefreshTask?.cancel()
        guard presetManifestService != nil else { return }

        presetManifestRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await self.refreshClock.sleep(for: .seconds(Int(Self.presetManifestRefreshInterval)))
                guard !Task.isCancelled else { return }
                await self.refreshPresetManifest()
            }
        }
    }

    // MARK: - Demo Mode

    #if DEBUG
    /// Applies demo state for App Store screenshots.
    /// Skips normal bootstrap and sets state directly.
    func applyDemoState(
        usageData: UsageData?,
        isSetupComplete: Bool,
        errorMessage: String?,
        isLoading: Bool
    ) {
        self.usageData = usageData
        self.isSetupComplete = isSetupComplete
        self.errorMessage = errorMessage
        self.isLoading = isLoading
        self.isReady = true
        // Leave hasLoadedSettings false so demo-mode settings mutations are
        // never persisted to the real UserDefaults domain.
        self.hasLoadedSettings = false
        // Don't start refresh loop or wake observer in demo mode
    }
    #endif

}

private extension String {
    /// `nil` for an empty string, so a blank user-entered label falls through
    /// to the provider default rather than rendering as an empty row title.
    var nilWhenEmpty: String? {
        isEmpty ? nil : self
    }
}
