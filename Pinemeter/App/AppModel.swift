import AppKit
import CryptoKit
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
            if kind == .accessToken {
                switch provider {
                case .claude:
                    return "Using the Claude Code login."
                case .chatGPT:
                    return "Using the Codex CLI login."
                case .gemini:
                    break
                }
            }
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
    let connected: [ImportedChatGPTSessionCookie]
}

private enum ChatGPTAccountRefreshOutcome: Sendable {
    case success(ChatGPTUsageData, ChatGPTAccountIdentity, UsageCredentialSource)
    case failure(String)
    case cancelled
}

/// Resolves one additional (non-primary) ChatGPT account's usage this poll
/// cycle: the Codex CLI login is tried first when present and unexpired
/// (D-03, D-05); a rejected/invalid-response CLI result falls back to the
/// stored cookie in the same cycle; any other CLI failure, or cancellation,
/// settles the cycle for this account without a cookie call. A free function
/// (not an `AppModel` method) so it can run inside a `withTaskGroup` child
/// task without capturing `self`.
private func fetchAdditionalChatGPTOutcome(
    chatGPTUsageService: any ChatGPTUsageServiceProtocol,
    account: ChatGPTAccount,
    codexLogin: CodexCLILogin?,
    chatgptAccountId: String?,
    isCLIOrigin: Bool,
    now: Date
) async -> ChatGPTAccountRefreshOutcome {
    var cliWasRejected = false
    if let codexLogin, !codexLogin.isExpired(now: now) {
        do {
            let result = try await chatGPTUsageService.fetchUsageAndIdentity(codexCLILogin: codexLogin)
            return .success(result.usage, result.identity, .codexCLI)
        } catch is CancellationError {
            return .cancelled
        } catch let error as CLIUsageFetchError where error.fallsBackToStoredSession {
            // Rejected or an unparsable body: fall through to the cookie
            // path below, in the same cycle (D-03).
            cliWasRejected = true
        } catch let error as CLIUsageFetchError {
            return .failure(error.localizedDescription)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    do {
        let result = try await chatGPTUsageService.fetchUsageAndIdentity(
            account: account.keychainAccount,
            chatgptAccountId: chatgptAccountId
        )
        return .success(result.usage, result.identity, .storedSession)
    } catch is CancellationError {
        return .cancelled
    } catch ChatGPTUsageError.missingSessionCookie where isCLIOrigin {
        let reason: CLISourceUnavailableReason = cliWasRejected ? .rejected : .missingOrExpired
        return .failure(reason.message(for: .chatGPT))
    } catch {
        return .failure(error.localizedDescription)
    }
}

/// Outcome of trying a Claude Code CLI login for one account's usage fetch
/// this poll cycle (D-03, D-05): `.fallBack` means the stored cookie should
/// be tried next, in the same cycle; `.used`/`.failed`/`.cancelled` mean this
/// cycle is settled for this account without a cookie call.
private enum CLISourceAttempt<Value> {
    case used(Value)
    case fallBack(CLISourceUnavailableReason)
    case failed(String)
    case cancelled
}

private struct RoutingUpdateFingerprintPayload: Encodable {
    let activeProfileID: String?
    let activeRules: BrokerRuleSet?
}

enum BrokerManifestHistoryState: Equatable, Sendable {
    case loading
    case loaded([BrokerManifestHistorySnapshot])
    case readError
}

/// Immutable review identity, including the URL namespace and the profile selected at opening.
struct BrokerRevisionSelection: Identifiable, Sendable {
    let namespace: BrokerManifestHistoryNamespace
    let snapshot: BrokerManifestHistorySnapshot
    let profileID: UUID
    var id: UUID { snapshot.id }
    var rules: BrokerRuleSet? { snapshot.profile(id: profileID)?.rules.fillingMissingRoles }
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
            guard !isApplyingRemotePushStatus else { return }
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

    /// The most recent CLI login read, taken once per poll cycle by
    /// `refreshCLILoginSnapshot()`. Runtime-only (D-08): never persisted.
    @ObservationIgnored private var latestCLILoginSnapshot: CLILoginSnapshot = .empty
    /// Which accounts the latest CLI login snapshot covers, independent of
    /// whether a poll has used them yet.
    private(set) var cliLoginPresence: CLILoginPresence = .none
    /// Which credential each ChatGPT account's last successful poll used,
    /// keyed by `ChatGPTAccount.id`. Runtime-only (D-08): never persisted.
    private(set) var chatGPTAccountSources: [String: UsageCredentialSource] = [:]
    /// Which credential each Claude account's last successful poll used,
    /// keyed by `ClaudeAccount.id`. Runtime-only (D-08): never persisted.
    private(set) var claudeAccountSources: [String: UsageCredentialSource] = [:]

    /// Mirror of the broker's UI-facing state (server lifecycle, last pick,
    /// route health, oracle freshness), published for 07-05's popover card
    /// and Broker window.
    var brokerUIState: BrokerUIState?
    private(set) var presetManifestHistory: [
        BrokerManifestHistoryNamespace: BrokerManifestHistoryState
    ] = [:]

    /// The broker's API key, for the Network pane to display and copy. Read
    /// from the Keychain during bootstrap and whenever it is generated or
    /// regenerated; never written to settings or logged.
    private(set) var brokerAPIKey: String?
    private(set) var brokerAPIKeyErrorMessage: String?
    private(set) var remoteHostPushInProgress = Set<UUID>()

    /// The complete last successful T3 discovery scan, including
    /// `installed == false` entries. This is raw scan truth, not a UI-ready
    /// list: it stays complete because an existing settings row for an
    /// uninstalled instance must still be refreshed from it on every scan.
    /// Consumers filter it — most notably `BrokerWindowView`'s add menu,
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

    /// `true` when any connected Claude account was discovered through a
    /// Claude Code CLI login rather than a stored browser cookie (CLI-08).
    var hasCLIClaudeAccount: Bool {
        settings.claudeAccounts.contains(where: \.isCLIOrigin)
    }

    /// `true` when any connected ChatGPT account either was discovered
    /// through a Codex CLI login, or shares its id with the current Codex
    /// CLI login's `chatgpt_user_id` (CLI-08): the latter covers a
    /// browser-connected account the CLI also happens to log into.
    var hasCLIChatGPTSource: Bool {
        settings.chatGPTAccounts.contains { account in
            account.isCLIOrigin
                || (cliLoginPresence.codexChatGPTUserId != nil && account.id == cliLoginPresence.codexChatGPTUserId)
        }
    }

    /// `true` when the "Show ChatGPT usage" toggle should be enabled: a
    /// stored cookie, or any connected ChatGPT account at all (CLI-origin
    /// accounts have no cookie but are still a usable connection, CLI-08).
    var canShowChatGPTUsage: Bool {
        hasChatGPTSessionCookie || !settings.chatGPTAccounts.isEmpty
    }

    var isClaudeUsageConfigured: Bool {
        isSetupComplete || hasCLIClaudeAccount
    }

    var isChatGPTUsageConfigured: Bool {
        (hasChatGPTSessionCookie || hasCLIChatGPTSource) && settings.isChatGPTUsageShown
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
        settings.broker.isEnabled
            || usageData != nil
            || !claudeAccountUsage.isEmpty
            || !claudeAccountErrors.isEmpty
            || (isClaudeUsageConfigured && errorMessage != nil)
            || (settings.isChatGPTUsageShown && (chatGPTUsageData != nil || chatGPTErrorMessage != nil
                || !chatGPTAccountUsage.isEmpty || !chatGPTAccountErrors.isEmpty))
            || (isGeminiUsageConfigured && (geminiUsageData != nil || geminiErrorMessage != nil
                || !geminiAccountUsage.isEmpty || !geminiAccountErrors.isEmpty))
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
                colorScheme: settings.menuBarColorScheme,
                provider: .claude,
                lastUpdated: usageData.lastUpdated
            ))
            bars.append(MenuBarQuotaBar(
                label: "\(section.title) weekly",
                percentage: clampedBarPercentage(usageData.weeklyUsage.percentage),
                status: usageData.weeklyUsage.status,
                detail: resetAnnouncement(for: usageData.weeklyUsage.resetAt),
                heading: "Weekly",
                owner: section.title,
                renameTarget: renameTarget,
                colorScheme: settings.menuBarColorScheme,
                provider: .claude,
                lastUpdated: usageData.lastUpdated
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
                    colorScheme: settings.menuBarColorScheme,
                    provider: .claude,
                    lastUpdated: usageData.lastUpdated
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
                    colorScheme: settings.menuBarColorScheme,
                    provider: .chatGPT,
                    lastUpdated: usageData.lastUpdated
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
                colorScheme: settings.menuBarColorScheme,
                provider: .gemini,
                lastUpdated: usageData.lastUpdated
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
    /// Injectable for tests (pinemeter-private#126/#127); production always
    /// uses the default, which reads Codex CLI's real `auth.json`.
    @ObservationIgnored private let codexWorkspaceResolver: @Sendable () -> CodexCLIWorkspaceResolver.Workspace?
    @ObservationIgnored private let browserLoginPrompt: ([CredentialProvider]) -> Void
    /// The bounded recovery watch's interval and attempt cap (D-04). Shared
    /// by every call to `startBrowserRecoveryWatch`, so the login prompt's
    /// stated recheck window can never drift from what the watch actually
    /// does.
    @ObservationIgnored private let browserRecoveryWatchPolicy: BrowserRecoveryWatchPolicy
    /// Injectable so the watch's timing is deterministic under test -- real
    /// code never sleeps, it awaits `Task.sleep(for:)` through this seam.
    @ObservationIgnored private let browserRecoveryWatchSleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let releaseCheckService: (any ReleaseCheckServiceProtocol)?
    @ObservationIgnored private let presetManifestService: (any PresetManifestServiceProtocol)?
    @ObservationIgnored private let presetManifestHistoryStore: BrokerManifestHistoryStore
    @ObservationIgnored private let appUpdater: AppUpdaterProtocol?
    @ObservationIgnored private let installedVersion: String
    @ObservationIgnored private let brokerService: any BrokerLifecycleProtocol
    @ObservationIgnored private let brokerLifecycleController: BrokerLifecycleController
    @ObservationIgnored let t3Dispatch: T3DispatchController
    @ObservationIgnored private let claudeAccountConnectionController: ClaudeAccountConnectionController
    @ObservationIgnored private let chatGPTAccountConnectionController: ChatGPTAccountConnectionController
    @ObservationIgnored private let t3InstanceDiscovery: any T3InstanceDiscoveryProtocol
    @ObservationIgnored private let t3UsageService: any T3UsageServiceProtocol
    @ObservationIgnored private let remoteHostSecretRepository: RemoteHostSecretRepository
    @ObservationIgnored private var remotePushCoordinator: RemotePushCoordinator?
    @ObservationIgnored private let cliLoginReader: any CLILoginReading
    @ObservationIgnored private let claudeOAuthUsageService: any ClaudeOAuthUsageServiceProtocol

    // MARK: - Private

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var updateCheckTask: Task<Void, Never>?
    @ObservationIgnored private var presetManifestRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var routingUpdateObserver: NSObjectProtocol?
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
    /// The bounded post-prompt recovery watch task (D-04), exposed
    /// internally (not private) so tests can await its completion instead of
    /// racing it with a sleep of their own.
    @ObservationIgnored private(set) var browserRecoveryWatchTask: Task<Void, Never>?
    /// Providers the current (or most recently started) watch is still
    /// retrying. A provider stays here across a watch restart so a second
    /// failure never drops a provider the first watch had not yet recovered.
    @ObservationIgnored private var browserRecoveryWatchProviders = Set<CredentialProvider>()
    @ObservationIgnored private var remotePushInventoryMutationDepth = 0
    @ObservationIgnored private var remotePushInventoryWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var remotePushCredentialReadInProgress = false
    @ObservationIgnored private var pendingProviderMutation = false
    @ObservationIgnored private var pendingSettingsPush = false
    @ObservationIgnored private var remotePushHandlersInstalled = false
    @ObservationIgnored private var isApplyingRemotePushStatus = false

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
        codexWorkspaceResolver: (@Sendable () -> CodexCLIWorkspaceResolver.Workspace?)? = nil,
        browserLoginPrompt: @escaping ([CredentialProvider]) -> Void = SessionKeyImportPromptCoordinator.presentBrowserLoginRequired,
        browserRecoveryWatchPolicy: BrowserRecoveryWatchPolicy = .standard,
        browserRecoveryWatchSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        releaseCheckService: (any ReleaseCheckServiceProtocol)? = nil,
        presetManifestService: (any PresetManifestServiceProtocol)? = nil,
        presetManifestHistoryStore: BrokerManifestHistoryStore? = nil,
        appUpdater: AppUpdaterProtocol? = nil,
        installedVersion: String? = nil,
        brokerService: (any BrokerLifecycleProtocol)? = nil,
        brokerServerFactory: (@Sendable (
            _ broker: any BrokerServiceProtocol, _ port: UInt16, _ accessPolicy: BrokerAccessPolicy
        ) -> any BrokerLoopbackServerProtocol)? = nil,
        t3LivenessChecker: (any T3LivenessCheckerProtocol)? = nil,
        t3DispatchClient: T3DispatchClient = T3DispatchClient(),
        t3DispatchNow: @escaping @Sendable () -> Date = { Date() },
        t3DispatchPointerOrigin: (@Sendable () async -> String?)? = nil,
        t3InstanceDiscovery: (any T3InstanceDiscoveryProtocol)? = nil,
        t3UsageService: (any T3UsageServiceProtocol)? = nil,
        remoteHostSecretRepository: RemoteHostSecretRepository? = nil,
        remoteSSHTransport: RemoteSSHTransport? = nil,
        remotePushCoordinator: RemotePushCoordinator? = nil,
        cliLoginReader: (any CLILoginReading)? = nil,
        claudeOAuthUsageService: (any ClaudeOAuthUsageServiceProtocol)? = nil
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
        self.codexWorkspaceResolver = codexWorkspaceResolver ?? Self.defaultCodexWorkspaceResolver()
        self.browserLoginPrompt = browserLoginPrompt
        self.browserRecoveryWatchPolicy = browserRecoveryWatchPolicy
        self.browserRecoveryWatchSleep = browserRecoveryWatchSleep

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
        self.presetManifestHistoryStore = presetManifestHistoryStore ?? BrokerManifestHistoryStore()
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
        self.t3Dispatch = T3DispatchController(
            client: t3DispatchClient,
            keychainRepository: keychainRepository,
            brokerService: brokerService,
            now: t3DispatchNow,
            pointerOrigin: t3DispatchPointerOrigin
        )
        self.t3InstanceDiscovery = t3InstanceDiscovery ?? Self.defaultT3InstanceDiscovery()
        self.t3UsageService = t3UsageService ?? T3UsageService()
        let remoteHostSecretRepository = remoteHostSecretRepository ?? RemoteHostSecretRepository()
        self.remoteHostSecretRepository = remoteHostSecretRepository
        self.remotePushCoordinator = remotePushCoordinator
        self.cliLoginReader = cliLoginReader ?? Self.defaultCLILoginReader()
        self.claudeOAuthUsageService = claudeOAuthUsageService ?? ClaudeOAuthUsageService()

        self.notificationService.setupDelegate()
        routingUpdateObserver = NotificationCenter.default.addObserver(
            forName: .applyRoutingUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let profileID = notification.object as? UUID else { return }
                self?.applyRoutingUpdate(profileID: profileID)
            }
        }

        if self.remotePushCoordinator == nil {
            let builder = RemotePushBundleBuilder(
                keychainRepository: keychainRepository,
                chatGPTRepository: chatGPTSessionRepository,
                geminiRepository: geminiAPIKeyRepository
            )
            let transport = remoteSSHTransport
                ?? RemoteSSHTransport(secretRepository: remoteHostSecretRepository)
            self.remotePushCoordinator = RemotePushCoordinator(
                loadSource: { [weak self] in
                    await self?.remotePushSourceSnapshot() ?? .empty
                },
                reserveGeneration: {
                    try await settingsRepository.reservePushGeneration()
                },
                buildBundle: { [weak self] generation, pushedAt, source in
                    guard let self else { throw CancellationError() }
                    return try await self.buildRemotePushBundle(
                        generation: generation,
                        pushedAt: pushedAt,
                        source: source,
                        builder: builder
                    )
                },
                send: { bundle, host in
                    _ = try await transport.importBundle(bundle, host: host)
                },
                fetchStatus: { host in
                    try await transport.fetchStatus(host: host)
                },
                recordUpdate: { [weak self] update in
                    await self?.applyRemotePushUpdate(update)
                }
            )
        }
    }

    deinit {
        if let routingUpdateObserver {
            NotificationCenter.default.removeObserver(routingUpdateObserver)
        }
        // Stored-property access in deinit is exclusive by construction (no
        // other code can run concurrently while self is being deallocated),
        // the same reasoning that already lets this deinit touch
        // `routingUpdateObserver` directly. `Task.cancel()` itself is not
        // actor-isolated, so this needs no hop.
        browserRecoveryWatchTask?.cancel()
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

    /// The CLI login reader used when no explicit one is injected. Same
    /// test-safety pattern as `defaultT3InstanceDiscovery()` above (CLI-10):
    /// under XCTest this is `NullCLILoginReader`, so a test that forgets to
    /// inject a fake can never read the developer's real `auth.json` or
    /// Keychain and poll a real provider from the test host.
    private static func defaultCLILoginReader() -> any CLILoginReading {
        if NSClassFromString("XCTestCase") != nil {
            return NullCLILoginReader()
        }
        return CLILoginService.live()
    }

    /// The Codex CLI workspace resolver used when no explicit one is
    /// injected. Same test-safety pattern as `defaultCLILoginReader()` above
    /// (RESEARCH Pitfall 11): under XCTest this answers `nil` ("no
    /// information") instead of reading the developer's real `auth.json`.
    private static func defaultCodexWorkspaceResolver() -> @Sendable () -> CodexCLIWorkspaceResolver.Workspace? {
        if NSClassFromString("XCTestCase") != nil {
            return { nil }
        }
        return { CodexCLIWorkspaceResolver.resolve() }
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
        RemoteSSHTransport.removeStaleOperationDirectories()
        await installRemotePushMutationHandlers()
        settings = await settingsRepository.load()
        appUpdater?.start()
        if let availableVersion = settings.availableUpdateVersion,
           !AvailableUpdate(version: availableVersion).isNewer(than: installedVersion) {
            settings.availableUpdateVersion = nil
        }
        hasLoadedSettings = true

        brokerAPIKey = await loadBrokerAPIKey()
        await t3Dispatch.loadStoredConnection()
        let latestInstructionCheck = await brokerService.latestInstructionCheck()
        t3Dispatch.updateOutstandingRun(
            settings: settings.broker.instructionDispatch,
            latestCheck: latestInstructionCheck
        )
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
        migrateLegacyPresetManifestCacheIfNeeded()
        await loadPresetManifestHistoryIfNeeded()
        isReady = true

        await brokerService.setRefreshHandler { [weak self] in
            await self?.refreshConfiguredUsageProviders(forceRefresh: true)
            await self?.remotePushCoordinator?.retryPending()
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
        await seedBundledPresetManifestIfNeeded()
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

    private func installRemotePushMutationHandlers() async {
        guard !remotePushHandlersInstalled else { return }
        remotePushHandlersInstalled = true

        let handler: @Sendable (ProviderCredentialMutation) -> Void = { [weak self] mutation in
            Task { @MainActor [weak self] in
                self?.providerCredentialDidMutate(mutation)
            }
        }
        if let repository = keychainRepository as? KeychainRepository {
            await repository.setSuccessfulMutationHandler(handler)
        }
        if let repository = chatGPTSessionRepository as? ChatGPTSessionRepository {
            await repository.setSuccessfulMutationHandler(handler)
        }
        if let repository = geminiAPIKeyRepository as? GeminiAPIKeyRepository {
            await repository.setSuccessfulMutationHandler(handler)
        }
        if let brokerService = brokerService as? BrokerService {
            await brokerService.setSuccessfulCooldownMutationHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleRemotePush()
                }
            }
        }
    }

    private func providerCredentialDidMutate(_ mutation: ProviderCredentialMutation) {
        guard !(mutation.provider == .claude && mutation.account == BrokerAccessPolicy.keychainAccount) else {
            return
        }
        if remotePushInventoryMutationDepth > 0 {
            pendingProviderMutation = true
        } else {
            scheduleRemotePush()
        }
    }

    private func beginRemotePushInventoryMutation() async {
        while remotePushCredentialReadInProgress {
            await withCheckedContinuation { remotePushInventoryWaiters.append($0) }
        }
        remotePushInventoryMutationDepth += 1
    }

    private func endRemotePushInventoryMutation() {
        remotePushInventoryMutationDepth -= 1
        guard remotePushInventoryMutationDepth == 0 else { return }
        let waiters = remotePushInventoryWaiters
        remotePushInventoryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard pendingProviderMutation else { return }
        pendingProviderMutation = false
        pendingSettingsPush = false
        scheduleRemotePush()
    }

    private func beginRemotePushCredentialRead() async {
        while remotePushInventoryMutationDepth > 0 || remotePushCredentialReadInProgress {
            await withCheckedContinuation { remotePushInventoryWaiters.append($0) }
        }
        remotePushCredentialReadInProgress = true
    }

    private func endRemotePushCredentialRead() {
        remotePushCredentialReadInProgress = false
        let waiters = remotePushInventoryWaiters
        remotePushInventoryWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func buildRemotePushBundle(
        generation: UInt64,
        pushedAt: Date,
        source: RemotePushSourceSnapshot,
        builder: RemotePushBundleBuilder
    ) async throws -> Data {
        await beginRemotePushCredentialRead()
        defer { endRemotePushCredentialRead() }
        let inventory = RemotePushAccountInventory(
            settings: settings,
            legacyClaudeConnected: isSetupComplete,
            legacyChatGPTConnected: hasChatGPTSessionCookie,
            legacyGeminiConnected: hasGeminiAPIKey
        )
        guard inventory == source.inventory else { throw RemotePushBundleError.inventoryChanged }
        return try await builder.build(
            generation: generation,
            pushedAt: pushedAt,
            inventory: inventory,
            policy: source.policy,
            cooldowns: source.cooldowns,
            oracleSnapshot: source.oracleSnapshot,
            codexWorkspaceAccountIds: source.codexWorkspaceAccountIds
        )
    }

    func scheduleRemotePush() {
        guard let remotePushCoordinator else { return }
        Task { await remotePushCoordinator.scheduleAutomaticPush() }
    }

    private func schedulePendingSettingsPushIfNeeded() async {
        guard pendingSettingsPush else { return }
        if remotePushInventoryMutationDepth > 0 {
            pendingProviderMutation = true
            return
        }
        guard let remotePushCoordinator else { return }
        pendingSettingsPush = false
        await remotePushCoordinator.scheduleAutomaticPush()
    }

    func remotePushSourceSnapshot() async -> RemotePushSourceSnapshot {
        while remotePushInventoryMutationDepth > 0 {
            await withCheckedContinuation { remotePushInventoryWaiters.append($0) }
        }
        let settings = settings
        let generatedAt = Date()
        let rows = buildAggregateQuotaRows(generatedAt: generatedAt)
        let legacyClaudeConnected = isSetupComplete
        let legacyChatGPTConnected = hasChatGPTSessionCookie
        let legacyGeminiConnected = hasGeminiAPIKey
        let brokerStatus = await brokerService.status()
        let codexWorkspace = await resolveCodexWorkspace()
        // Mirrors RemotePushAccountInventory's own legacy-slot synthesis
        // (RemotePushBundle.swift) so the pushed workspace ids are keyed by
        // the same account ids the pushed inventory actually contains --
        // otherwise a not-yet-migrated legacy primary account would be
        // resolved locally (refreshChatGPTUsage uses the identical fallback)
        // but never make it into the push bundle at all.
        var chatGPTAccountsForWorkspaceResolution = settings.chatGPTAccounts
        if legacyChatGPTConnected, !chatGPTAccountsForWorkspaceResolution.contains(where: \.isPrimary) {
            chatGPTAccountsForWorkspaceResolution.append(
                ChatGPTAccount.legacyPrimary(customLabel: settings.chatGPTCustomLabel)
            )
        }
        // uniquingKeysWith over uniqueKeysWithValues: a duplicate account id
        // cannot happen today (applyChatGPTIdentity refuses to let two slots
        // claim one id), but this map is rebuilt on every push cycle, so a
        // future regression there would otherwise crash the push path
        // instead of just losing one entry's freshness.
        let codexWorkspaceAccountIds = Dictionary(
            chatGPTAccountsForWorkspaceResolution.compactMap {
                account -> (String, String)? in
                guard let id = resolvedCodexWorkspaceAccountId(for: account, codexWorkspace: codexWorkspace) else {
                    return nil
                }
                return (account.id, id)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return RemotePushSourceSnapshot(
            hosts: settings.broker.remoteHosts,
            inventory: RemotePushAccountInventory(
                settings: settings,
                legacyClaudeConnected: legacyClaudeConnected,
                legacyChatGPTConnected: legacyChatGPTConnected,
                legacyGeminiConnected: legacyGeminiConnected
            ),
            policy: settings.broker.policy,
            cooldowns: Dictionary(uniqueKeysWithValues: brokerStatus.cooldowns.map {
                ($0.key, $0.availableAt)
            }),
            oracleSnapshot: Self.makeOracleSnapshot(
                generatedAt: generatedAt,
                rows: rows,
                chatGPTConfigured: legacyChatGPTConnected || hasCLIChatGPTSource
            ),
            codexWorkspaceAccountIds: codexWorkspaceAccountIds
        )
    }

    func applyRemotePushUpdate(_ update: RemotePushAttemptUpdate) async {
        switch update {
        case .started(let hostID):
            remoteHostPushInProgress.insert(hostID)
        case .finished(let hostID, let completedAt, let result, let sanitizedError):
            remoteHostPushInProgress.remove(hostID)
            guard let index = settings.broker.remoteHosts.firstIndex(where: { $0.id == hostID }) else {
                return
            }

            settingsSaveTask?.cancel()
            await settingsSaveTask?.value
            isApplyingRemotePushStatus = true
            settings.broker.remoteHosts[index].lastPushAt = completedAt
            settings.broker.remoteHosts[index].lastPushResult = result
            settings.broker.remoteHosts[index].sanitizedError = sanitizedError
            if result == .succeeded {
                settings.broker.remoteHosts[index].credentialStatus = .unknown
            }
            let snapshot = settings
            isApplyingRemotePushStatus = false
            do {
                try await settingsRepository.save(snapshot)
                await schedulePendingSettingsPushIfNeeded()
            } catch {}
        case .status(let hostID, let observation):
            guard let index = settings.broker.remoteHosts.firstIndex(where: { $0.id == hostID }) else {
                return
            }
            settingsSaveTask?.cancel()
            await settingsSaveTask?.value
            isApplyingRemotePushStatus = true
            settings.broker.remoteHosts[index].credentialStatus = observation.status
            if let observedAt = observation.observedAt {
                settings.broker.remoteHosts[index].observedAt = observedAt
            }
            if let observedGeneration = observation.observedGeneration {
                settings.broker.remoteHosts[index].observedGeneration = observedGeneration
            }
            let snapshot = settings
            isApplyingRemotePushStatus = false
            do {
                try await settingsRepository.save(snapshot)
                await schedulePendingSettingsPushIfNeeded()
            } catch {}
        }
    }

    @discardableResult
    func addRemoteHost(
        host: String,
        sshUser: String,
        keyPath: String,
        pinnedHostKey: String
    ) async throws -> RemoteHost {
        await settingsSaveTask?.value
        let remoteHost = try await remoteHostSecretRepository.configureHost(
            host: host,
            sshUser: sshUser,
            keyPath: keyPath,
            pinnedHostKey: pinnedHostKey,
            settingsRepository: settingsRepository
        )
        isApplyingRemotePushStatus = true
        settings = await settingsRepository.load()
        isApplyingRemotePushStatus = false
        return remoteHost
    }

    func removeRemoteHost(id: UUID) async throws {
        guard let host = settings.broker.remoteHosts.first(where: { $0.id == id }) else { return }
        await settingsSaveTask?.value
        var updated = settings
        updated.broker.remoteHosts.removeAll { $0.id == id }
        try await settingsRepository.save(updated)

        isApplyingRemotePushStatus = true
        settings = updated
        isApplyingRemotePushStatus = false
        remoteHostPushInProgress.remove(id)
        await remotePushCoordinator?.hostRemoved(id)
        try await remoteHostSecretRepository.delete(reference: host.secretReference)
    }

    func pushRemoteHostNow(id: UUID) async {
        await remotePushCoordinator?.manualPush(hostID: id)
    }

    // MARK: - Broker lifecycle (07-04)

    /// Reconciles broker settings during bootstrap and after Broker settings
    /// tab changes: pushes the new policy, then stops/starts/restarts the server as
    /// needed so the running server always matches `settings.broker`.
    func applyBrokerSettingsChange() async {
        guard await brokerLifecycleController.apply(settings.broker) else { return }
        startRefreshLoop()
    }

    /// Keep the previous access policy when Keychain cannot provision its replacement.
    func applyBrokerAPIKeyModeChange(from previousMode: BrokerAPIKeyMode) async {
        let requestedMode = settings.broker.apiKeyMode
        if requestedMode == .none {
            await applyBrokerSettingsChange()
            return
        }
        guard await ensureBrokerAPIKey() else {
            if settings.broker.apiKeyMode == requestedMode {
                settings.broker.apiKeyMode = previousMode
            }
            return
        }
        await applyBrokerSettingsChange()
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
    @discardableResult
    func ensureBrokerAPIKey() async -> Bool {
        brokerAPIKeyErrorMessage = nil
        guard settings.broker.apiKeyMode != .none else { return true }
        if let existing = await loadBrokerAPIKey() {
            brokerAPIKey = existing
            return true
        }
        let key = BrokerAccessPolicy.generateAPIKey()
        do {
            try await keychainRepository.save(
                sessionKey: key,
                account: BrokerAccessPolicy.keychainAccount
            )
        } catch {
            // Never surface the key material through the error path either.
            brokerAPIKeyErrorMessage =
                "Could not save the broker API key in Keychain. Check Keychain access and try again."
            return false
        }
        brokerAPIKey = key
        await applyBrokerSettingsChange()
        return true
    }

    /// Replaces the stored key, invalidating every client still holding the
    /// old one, and restarts the server so it starts comparing against the
    /// new value immediately.
    @discardableResult
    func regenerateBrokerAPIKey() async -> Bool {
        brokerAPIKeyErrorMessage = nil
        let key = BrokerAccessPolicy.generateAPIKey()
        let account = BrokerAccessPolicy.keychainAccount
        do {
            if await keychainRepository.exists(account: account) {
                try await keychainRepository.update(sessionKey: key, account: account)
            } else {
                try await keychainRepository.save(sessionKey: key, account: account)
            }
        } catch {
            brokerAPIKeyErrorMessage =
                "Could not save the broker API key in Keychain. Check Keychain access and try again."
            return false
        }
        brokerAPIKey = key
        await applyBrokerSettingsChange()
        return true
    }

    /// The broker's recent-picks ring buffer, newest-first (D-09 debugging
    /// surface for 07-05's Broker window).
    func brokerRecentPicks() async -> [RecentPick] {
        await brokerService.recentPicks()
    }

    /// The last snapshot pushed to the broker, or `nil` before the first
    /// poll of this launch.
    @ObservationIgnored private var lastOracleSnapshot: OracleSnapshot?

    #if DEBUG
    var retainedOracleSnapshotForTesting: OracleSnapshot? { lastOracleSnapshot }
    #endif

    /// Why a degraded decision's candidate has no usable quota reading, when
    /// the cause is a provider that has stopped answering rather than one that
    /// is merely slow or absent.
    ///
    /// Returns `nil` before the first poll: not knowing is never evidence of a
    /// fault, which is the same rule the candidate walk itself follows.
    func brokerProviderFault(for decision: BrokerDecision) -> BrokerProviderFault? {
        guard let candidate = BrokerCandidate(id: decision.model) else { return nil }
        return BrokerEngine.providerFault(
            for: candidate,
            policy: settings.broker.policy,
            oracle: lastOracleSnapshot
        )
    }

    /// Whether any cooldown is still in the future.
    ///
    /// `BrokerCooldownStore.mergedSnapshot` already drops entries that expired
    /// as of its own read, so this predicate is not what makes the common case
    /// correct. It covers the gap between that read and the use of the answer:
    /// the caller picks an alert's button from it, and an entry with a second
    /// left when `status` sampled it gates nothing by the time a user reacts.
    func hasActiveBrokerCooldowns() async -> Bool {
        let now = Date()
        return await brokerService.status().cooldowns.contains { $0.availableAt > now }
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
        let check = await brokerService.latestInstructionCheck()
        t3Dispatch.updateOutstandingRun(
            settings: settings.broker.instructionDispatch,
            latestCheck: check
        )
        return check
    }

    func connectT3(pastedText: String) async {
        await t3Dispatch.connect(pastedText: pastedText)
    }

    func disconnectT3() async {
        await t3Dispatch.disconnect()
    }

    func loadT3Projects() async {
        await t3Dispatch.refreshProjects()
        guard let selectedID = settings.broker.instructionDispatch.t3ProjectID,
              let selected = t3Dispatch.projects.first(where: { $0.id == selectedID }) else { return }
        settings.broker.instructionDispatch.t3ProjectTitle = selected.title
    }

    func selectT3Project(id: String) {
        if id.isEmpty {
            settings.broker.instructionDispatch.t3ProjectID = nil
            settings.broker.instructionDispatch.t3ProjectTitle = nil
            return
        }
        settings.broker.instructionDispatch.t3ProjectID = id
        if let title = t3Dispatch.projects.first(where: { $0.id == id })?.title {
            settings.broker.instructionDispatch.t3ProjectTitle = title
        }
    }

    func dispatchInstructionRecheck(
        trigger: InstructionDispatchTrigger,
        now: Date = Date(),
        fullAccess: Bool = false
    ) async {
        let latestCheck = await brokerService.latestInstructionCheck()
        let requestedProjectID = settings.broker.instructionDispatch.t3ProjectID
        let stamps = await t3Dispatch.dispatchInstructionRecheck(
            brokerEnabled: settings.broker.isEnabled,
            port: settings.broker.port,
            settings: settings.broker.instructionDispatch,
            trigger: trigger,
            now: now,
            latestCheck: latestCheck,
            fullAccess: fullAccess,
            isAutomaticDispatchEnabled: { [weak self] in
                self?.settings.broker.instructionDispatch.isAutomaticDispatchEnabled == true
            },
            isFullAccessForAllRunsEnabled: { [weak self] in
                self?.settings.broker.instructionDispatch.fullAccessForAllRuns == true
            }
        )
        settings.broker.instructionDispatch.lastDispatchedAt = stamps.lastDispatchedAt
        settings.broker.instructionDispatch.lastDispatchThreadID = stamps.lastDispatchThreadID
        settings.broker.instructionDispatch.lastAutomaticDispatchAt = stamps.lastAutomaticDispatchAt
        settings.broker.instructionDispatch.lastDispatchFailure = stamps.lastDispatchFailure
        if settings.broker.instructionDispatch.t3ProjectID == requestedProjectID,
           let requestedProjectID,
           let project = t3Dispatch.projects.first(where: { $0.id == requestedProjectID }) {
            settings.broker.instructionDispatch.t3ProjectTitle = project.title
        }
    }

    /// Re-probes every configured T3 instance now, outside the refresh loop's
    /// schedule. Backs the "Probe again" action on an instance's status strip.
    /// The broker publishes the new reachability through `brokerUIState`.
    func probeT3Instances() async {
        _ = await brokerService.refreshT3Liveness()
    }

    // MARK: - Usage

    /// Per-cycle accumulator for which providers had a successful CLI-sourced
    /// poll (Claude Code or Codex CLI). Deliberately a local reference type
    /// created fresh by each `refreshConfiguredUsageProviders` call, not a
    /// shared `AppModel` property: a plain shared `Set` would let one run's
    /// start-of-cycle clear wipe another overlapping run's already-recorded
    /// successes before either reached `applyCLICredentialStates()` (e.g. a
    /// manual "Refresh now" firing while the scheduled refresh loop's own
    /// cycle is still in flight). Threading this instance through the cycle
    /// instead means two overlapping cycles can never see or clear each
    /// other's results. Runtime-only (D-08): never persisted.
    final class CLISuccessTracker {
        private(set) var successes: Set<CredentialProvider> = []
        // Which providers this run's own CLI-polling functions actually
        // reached past their reentrancy guard (`isRefreshing`,
        // `isRefreshingAdditionalClaudeAccounts`,
        // `isRefreshingAdditionalChatGPTAccounts`), as opposed to bouncing
        // off early because a DIFFERENT overlapping cycle still held that
        // guard. `applyCLICredentialStates` must only reset a provider to
        // `.missing` when this run actually polled it: a run whose own guard
        // bounced it off has no information about whether the other,
        // in-flight cycle's poll succeeded, so treating that bounce as "no
        // success this cycle" and resetting a previously-valid CLI-backed
        // state would be racing the other cycle's own result (re-review #1).
        private(set) var polledProviders: Set<CredentialProvider> = []

        func insert(_ provider: CredentialProvider) {
            successes.insert(provider)
        }
        func contains(_ provider: CredentialProvider) -> Bool {
            successes.contains(provider)
        }

        func markPolled(_ provider: CredentialProvider) {
            polledProviders.insert(provider)
        }
        func polled(_ provider: CredentialProvider) -> Bool {
            polledProviders.contains(provider)
        }
    }

    func refreshConfiguredUsageProviders(forceRefresh: Bool = false) async {
        let cliSuccessTracker = CLISuccessTracker()
        await refreshCLILoginSnapshot()
        reconcileCLILogins(latestCLILoginSnapshot)
        if isClaudeUsageConfigured {
            await refreshUsage(forceRefresh: forceRefresh, cliSuccessTracker: cliSuccessTracker)
        }
        await refreshAdditionalClaudeAccounts(forceRefresh: forceRefresh, cliSuccessTracker: cliSuccessTracker)
        if isChatGPTUsageConfigured {
            await refreshChatGPTUsage(cliSuccessTracker: cliSuccessTracker)
        }
        await refreshAdditionalChatGPTAccounts(cliSuccessTracker: cliSuccessTracker)
        if isGeminiUsageConfigured {
            await refreshGeminiUsage()
        }
        await refreshAdditionalGeminiAccounts()
        applyCLICredentialStates(cliSuccessTracker: cliSuccessTracker)
        await recoverBrowserSessionsIfNeeded()
        await remotePushCoordinator?.refreshStatus()
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

    /// Tries the Claude Code CLI login for one organization's usage, off the
    /// stored cookie entirely (D-03, D-05). No login, or one already expired,
    /// makes zero requests. Never touches `claudeCredentialState`, the
    /// stored session key, or any cookie-path counter -- only the caller's
    /// subsequent cookie fallback (on `.fallBack`) does that (D-04).
    private func claudeUsageFromCLI(organizationId: UUID) async -> CLISourceAttempt<UsageData> {
        guard let login = latestCLILoginSnapshot.claudeLogin(forOrganizationId: organizationId),
              !login.isExpired(now: Date()) else {
            return .fallBack(.missingOrExpired)
        }
        do {
            let data = try await claudeOAuthUsageService.fetchUsage(accessToken: login.accessToken)
            return .used(data)
        } catch let error as CLIUsageFetchError {
            if error.fallsBackToStoredSession {
                return .fallBack(.rejected)
            }
            return .failed(error.localizedDescription)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func refreshUsage(forceRefresh: Bool = false, cliSuccessTracker: CLISuccessTracker? = nil) async {
        guard isSetupComplete else {
            usageData = nil
            await exportAggregateUsageSnapshot()
            return
        }
        guard !isRefreshing else { return }
        cliSuccessTracker?.markPolled(.claude)

        if usageData == nil {
            isLoading = true
        }
        isRefreshing = true
        errorMessage = nil

        defer {
            isLoading = false
            isRefreshing = false
        }

        let primaryOrganizationId = settings.claudeAccounts.first(where: \.isPrimary)?.organizationId
            ?? settings.cachedOrganizationId
        if let primaryOrganizationId {
            switch await claudeUsageFromCLI(organizationId: primaryOrganizationId) {
            case .used(let data):
                usageData = data
                if let primaryAccount = settings.claudeAccounts.first(where: \.isPrimary) {
                    claudeAccountSources[primaryAccount.id] = .claudeCode
                }
                cliSuccessTracker?.insert(.claude)
                await notificationService.evaluateThresholds(
                    usageData: data,
                    settings: settings
                )
                await exportAggregateUsageSnapshot()
                return
            case .failed(let message):
                errorMessage = message
                await exportAggregateUsageSnapshot()
                return
            case .cancelled:
                await exportAggregateUsageSnapshot()
                return
            case .fallBack:
                break
            }
        }

        do {
            let data = try await usageService.fetchUsage(forceRefresh: forceRefresh)
            usageData = data
            claudeCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
                health: .valid,
                checkedAt: Date()
            )
            if let primaryAccount = settings.claudeAccounts.first(where: \.isPrimary) {
                claudeAccountSources[primaryAccount.id] = .storedSession
            }
            await notificationService.evaluateThresholds(
                usageData: data,
                settings: settings
            )
        } catch MappingError.usageUnavailable {
            usageData = nil
            errorMessage = MappingError.usageUnavailable.localizedDescription
            claudeCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
                health: .valid,
                checkedAt: Date()
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
    /// Per account, the Claude Code CLI login is tried first (D-03); only on
    /// a missing/expired/rejected login does the stored cookie run in the
    /// same cycle. Settings may remove an account while this account's CLI
    /// or cookie attempt is suspended (edge CLI-08): every write below is
    /// guarded by a fresh membership check so a removed id is never
    /// resurrected into `claudeAccountUsage`/`claudeAccountErrors`/
    /// `claudeAccountSources`.
    func refreshAdditionalClaudeAccounts(forceRefresh: Bool = false, cliSuccessTracker: CLISuccessTracker? = nil) async {
        guard !isRefreshingAdditionalClaudeAccounts else { return }
        cliSuccessTracker?.markPolled(.claude)
        let additionalAccounts = settings.claudeAccounts.filter { !$0.isPrimary }
        // claudeAccountSources is shared with the primary account
        // (refreshUsage writes claudeAccountSources[primaryId]); pruning it
        // here must keep the primary's own entry, never wipe it just because
        // there are no additional accounts this cycle.
        let primaryAccountId = settings.claudeAccounts.first(where: \.isPrimary)?.id
        guard !additionalAccounts.isEmpty else {
            if !claudeAccountUsage.isEmpty { claudeAccountUsage.removeAll() }
            if !claudeAccountErrors.isEmpty { claudeAccountErrors.removeAll() }
            claudeAccountSources = claudeAccountSources.filter { $0.key == primaryAccountId }
            await exportAggregateUsageSnapshot()
            return
        }
        isRefreshingAdditionalClaudeAccounts = true
        defer { isRefreshingAdditionalClaudeAccounts = false }

        // Drop any cached state for accounts that are no longer connected.
        let connectedIds = Set(additionalAccounts.map { $0.id })
        claudeAccountUsage = claudeAccountUsage.filter { connectedIds.contains($0.key) }
        claudeAccountErrors = claudeAccountErrors.filter { connectedIds.contains($0.key) }
        claudeAccountSources = claudeAccountSources.filter { connectedIds.contains($0.key) || $0.key == primaryAccountId }

        for account in additionalAccounts {
            let attempt = await claudeUsageFromCLI(organizationId: account.organizationId)
            guard settings.claudeAccounts.contains(where: { $0.id == account.id }) else { continue }

            switch attempt {
            case .used(let data):
                claudeAccountUsage[account.id] = data
                claudeAccountErrors[account.id] = nil
                claudeAccountSources[account.id] = .claudeCode
                cliSuccessTracker?.insert(.claude)
            case .failed(let message):
                claudeAccountErrors[account.id] = message
            case .cancelled:
                break
            case .fallBack(let reason):
                do {
                    let data = try await usageService.fetchUsage(
                        account: account.keychainAccount,
                        organizationId: account.organizationId,
                        forceRefresh: forceRefresh
                    )
                    guard settings.claudeAccounts.contains(where: { $0.id == account.id }) else { continue }
                    claudeAccountUsage[account.id] = data
                    claudeAccountErrors[account.id] = nil
                    claudeAccountSources[account.id] = .storedSession
                } catch MappingError.usageUnavailable {
                    guard settings.claudeAccounts.contains(where: { $0.id == account.id }) else { continue }
                    claudeAccountUsage[account.id] = nil
                    claudeAccountErrors[account.id] = MappingError.usageUnavailable.localizedDescription
                } catch AppError.noSessionKey where account.isCLIOrigin {
                    guard settings.claudeAccounts.contains(where: { $0.id == account.id }) else { continue }
                    claudeAccountErrors[account.id] = reason.message(for: .claude)
                } catch {
                    guard settings.claudeAccounts.contains(where: { $0.id == account.id }) else { continue }
                    claudeAccountErrors[account.id] = error.localizedDescription
                }
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
    /// Resolves the `chatgpt-account-id` header to send for one connected
    /// ChatGPT account's `wham/usage` request. pinemeter-private#126/#127:
    /// Codex CLI and Pinemeter can share a ChatGPT login but land on
    /// different workspaces when no header is sent, since the server then
    /// picks whichever workspace it treats as ambient/default for the
    /// cookie -- not necessarily the one Codex CLI uses.
    ///
    /// Precedence: a manual override in Settings always wins. Otherwise,
    /// `CodexCLIWorkspaceResolver` reads Codex CLI's own `auth.json`; its
    /// result is applied only to the account whose already-known identity
    /// (`ChatGPTAccount.id`, the stable user id from a previous successful
    /// poll) matches the `chatgpt_user_id` claim decoded from Codex CLI's
    /// `id_token` -- so a workspace id resolved for one login is never sent
    /// under a different one. When that claim can't be decoded (an older
    /// Codex CLI auth.json shape, for instance), there is no way to verify
    /// which account it belongs to, so it is applied only to the primary
    /// account as a documented, conservative fallback: the common case is
    /// one connected ChatGPT account, where "primary" and "the Codex CLI
    /// login" are the same account. A not-yet-identified account (`id ==
    /// ChatGPTAccount.unidentifiedId`, i.e. no successful poll yet) can never
    /// match by claim, so it also falls through to the primary-only rule.
    private func resolvedCodexWorkspaceAccountId(
        for account: ChatGPTAccount,
        codexWorkspace: CodexCLIWorkspaceResolver.Workspace?
    ) -> String? {
        // The override has no per-account identity of its own to match
        // against (it is a single global Settings value), so it must never
        // apply to a non-primary account: a second connected login would get
        // the first login's workspace id sent with its own cookie, which
        // risks a 401/403 from the server, then invalidSessionCookie, then
        // spurious reconnect UI for an otherwise healthy account.
        if account.isPrimary,
           let override = settings.codexWorkspaceAccountIdOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        guard let codexWorkspace else { return nil }
        if let chatgptUserId = codexWorkspace.chatgptUserId {
            return account.id == chatgptUserId ? codexWorkspace.accountId : nil
        }
        return account.isPrimary ? codexWorkspace.accountId : nil
    }

    /// Reads Codex CLI's `auth.json` off the main actor. It's a synchronous
    /// file read, and every caller needs it at most once per refresh cycle
    /// regardless of how many ChatGPT accounts are connected -- previously
    /// `resolvedCodexWorkspaceAccountId` called `codexWorkspaceResolver()`
    /// once per account, which re-read the file redundantly.
    private func resolveCodexWorkspace() async -> CodexCLIWorkspaceResolver.Workspace? {
        let resolver = codexWorkspaceResolver
        return await Task.detached(priority: .utility) {
            resolver()
        }.value
    }

    /// Reads every CLI login source once per poll cycle (D-01, D-02) and
    /// stores the result for this cycle's per-account polls to consult. The
    /// reader itself runs off the main actor (`CLILoginService` is an
    /// actor); this call just awaits it and publishes the result.
    func refreshCLILoginSnapshot() async {
        let snapshot = await cliLoginReader.snapshot()
        latestCLILoginSnapshot = snapshot
        cliLoginPresence = snapshot.presence
    }

    /// Auto-connects a CLI login for an account Pinemeter does not know about
    /// yet (D-01): a Claude Code login for an unmapped organization, or a
    /// Codex CLI login for an unmapped ChatGPT user id, becomes a new
    /// non-primary account marked `origin: .cliLogin`. Merges into an
    /// existing account by identity instead of creating a duplicate (D-03),
    /// and never re-adds an account the user removed -- its organization or
    /// user id stays recorded in `scanExcludedAccounts`. Never touches a
    /// Keychain or session repository (D-04); only appends non-secret
    /// account metadata, and only assigns `settings.claudeAccounts`/
    /// `settings.chatGPTAccounts` when the snapshot actually changes them, so
    /// a repeated snapshot schedules no settings save (CLI-08 idempotency).
    /// Returns whether any account was added, so the caller can start the
    /// refresh loop on the same cycle that first sees a CLI-only user's
    /// login.
    @discardableResult
    private func reconcileCLILogins(_ snapshot: CLILoginSnapshot) -> Bool {
        var addedAccount = false

        if !snapshot.claude.isEmpty {
            var claudeAccounts = settings.claudeAccounts
            for login in snapshot.claude {
                guard !claudeAccounts.contains(where: { $0.organizationId == login.organizationId }) else {
                    continue
                }
                guard !(
                    claudeAccounts.isEmpty
                        && isSetupComplete
                        && settings.cachedOrganizationId == login.organizationId
                ) else {
                    continue
                }
                guard !isClaudeOrganizationExcluded(login.organizationId) else { continue }

                let orgUUIDString = login.organizationId.uuidString.lowercased()
                let organizationName = login.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines)
                claudeAccounts.append(ClaudeAccount(
                    id: orgUUIDString,
                    label: (organizationName?.isEmpty == false ? organizationName : nil) ?? "Claude",
                    organizationId: login.organizationId,
                    keychainAccount: orgUUIDString,
                    origin: .cliLogin
                ))
                addedAccount = true
            }
            if claudeAccounts != settings.claudeAccounts {
                settings.claudeAccounts = claudeAccounts
            }
        }

        if let codex = snapshot.codex {
            var chatGPTAccounts = settings.chatGPTAccounts
            let wasEmpty = chatGPTAccounts.isEmpty
            let hasUnresolvedPrimary = chatGPTAccounts.contains { $0.id == ChatGPTAccount.unidentifiedId }
            if !hasUnresolvedPrimary,
               !chatGPTAccounts.contains(where: { $0.id == codex.chatgptUserId }),
               !isChatGPTAccountExcluded(codex.chatgptUserId) {
                let email = codex.email?.trimmingCharacters(in: .whitespacesAndNewlines)
                chatGPTAccounts.append(ChatGPTAccount(
                    id: codex.chatgptUserId,
                    label: (email?.isEmpty == false ? email : nil) ?? "ChatGPT",
                    planType: codex.planType,
                    keychainAccount: codex.chatgptUserId,
                    origin: .cliLogin
                ))
                addedAccount = true
                if wasEmpty {
                    settings.isChatGPTUsageShown = true
                }
            }
            if chatGPTAccounts != settings.chatGPTAccounts {
                settings.chatGPTAccounts = chatGPTAccounts
            }
        }

        if addedAccount && refreshTask == nil {
            startRefreshLoop()
        }

        return addedAccount
    }

    /// `true` when a removed Claude organization's `ScanExcludedAccount
    /// .accountId` parses to the same UUID as `id`. Compares as `UUID`
    /// values (never raw strings): the persisted `accountId` and a
    /// Keychain-derived org UUID can differ in letter case.
    private func isClaudeOrganizationExcluded(_ id: UUID) -> Bool {
        settings.scanExcludedAccounts.contains {
            $0.provider == .claude && UUID(uuidString: $0.accountId) == id
        }
    }

    /// `true` when `id` is individually excluded, or a blanket ChatGPT
    /// exclusion is in effect -- an exclusion keyed by the legacy primary
    /// Keychain slot (`ChatGPTAccount.primaryKeychainAccount`) or the
    /// unidentified placeholder (`ChatGPTAccount.unidentifiedId`) means
    /// every ChatGPT account is excluded (same predicate as
    /// `ChatGPTAccountConnectionController.connect`).
    private func isChatGPTAccountExcluded(_ id: String) -> Bool {
        settings.scanExcludedAccounts.contains {
            guard $0.provider == .chatGPT else { return false }
            return $0.accountId == id
                || $0.accountId == ChatGPTAccount.primaryKeychainAccount
                || $0.accountId == ChatGPTAccount.unidentifiedId
        }
    }

    /// The source of a ChatGPT account's last successful poll, for display
    /// next to that account's Settings card.
    func usageSourceDetail(forChatGPTAccountId id: String) -> String? {
        chatGPTAccountSources[id]?.settingsDetail
    }

    /// The source of a Claude account's last successful poll, for display
    /// next to that account's Settings card.
    func usageSourceDetail(forClaudeAccountId id: String) -> String? {
        claudeAccountSources[id]?.settingsDetail
    }

    /// `true` when `id` either is CLI-origin, or names an organization the
    /// current CLI login snapshot still covers (a cookie account the CLI
    /// also happens to log into). Drives Settings' "CLI login" badge and the
    /// CLI-aware removal/re-enable wording (D-01, D-03).
    func isCLIBacked(claudeAccountId id: String) -> Bool {
        guard let account = settings.claudeAccounts.first(where: { $0.id == id }) else { return false }
        return account.isCLIOrigin || cliLoginPresence.claudeOrganizationIds.contains(account.organizationId)
    }

    /// `true` when `id` either is CLI-origin, or equals the current Codex CLI
    /// login's `chatgpt_user_id` (a cookie account the CLI also happens to
    /// log into).
    func isCLIBacked(chatGPTAccountId id: String) -> Bool {
        guard let account = settings.chatGPTAccounts.first(where: { $0.id == id }) else { return false }
        return account.isCLIOrigin || (cliLoginPresence.codexChatGPTUserId != nil && cliLoginPresence.codexChatGPTUserId == id)
    }

    /// Re-enable feedback for an excluded account (D-01, D-09): an account
    /// with a current CLI login reconnects on its own on the next refresh,
    /// so the message must not tell the user to scan a browser for it.
    func reenableFeedback(for excluded: ScanExcludedAccount) -> String {
        let hasCurrentCLILogin: Bool
        switch excluded.provider {
        case .claude:
            hasCurrentCLILogin = UUID(uuidString: excluded.accountId)
                .map { cliLoginPresence.claudeOrganizationIds.contains($0) } ?? false
        case .chatGPT:
            hasCurrentCLILogin = cliLoginPresence.codexChatGPTUserId == excluded.accountId
        case .gemini:
            hasCurrentCLILogin = false
        }
        return hasCurrentCLILogin
            ? "Re-enabled \(excluded.displayLabel). It reconnects from its CLI login on the next refresh."
            : "Re-enabled \(excluded.displayLabel). Scan to reconnect it."
    }

    /// Removal reconnect hint for a CLI-backed account (D-01): removing it
    /// only stops Pinemeter from reading its CLI login this cycle; re-adding
    /// it needs the Excluded-from-scans re-enable action, not a browser scan.
    /// `nil` when the account is not CLI-backed, so the caller falls back to
    /// `AccountRemoval.reconnectHint`.
    func removalReconnectHint(forClaudeAccountId id: String) -> String? {
        isCLIBacked(claudeAccountId: id)
            ? "Pinemeter stops reading its CLI login. Re-enable it under Excluded from scans to reconnect it."
            : nil
    }

    /// Removal reconnect hint for a CLI-backed ChatGPT account. See
    /// `removalReconnectHint(forClaudeAccountId:)`.
    func removalReconnectHint(forChatGPTAccountId id: String) -> String? {
        isCLIBacked(chatGPTAccountId: id)
            ? "Pinemeter stops reading its CLI login. Re-enable it under Excluded from scans to reconnect it."
            : nil
    }

    private func applyChatGPTIdentity(_ identity: ChatGPTAccountIdentity, keychainAccount: String) async {
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
            customLabel: existing.customLabel,
            // A CLI-origin account's first successful poll runs in the same
            // refresh cycle that reconciliation created it (D-01); without
            // this, that same-cycle identity refresh would silently strip
            // the marker the account was just created with.
            origin: existing.origin
        )
        // Two slots must never claim one identity. If the id already exists
        // elsewhere on a CLI-origin entry (a pasted cookie resolves to the
        // same identity a CLI login already auto-connected, D-03), merge:
        // drop the CLI-origin duplicate and let this slot become
        // authoritative for the identity, carrying over its custom label.
        // Any other collision keeps this slot on its previous id instead.
        var mergedCacheAccount: String?
        if let collision = settings.chatGPTAccounts.first(where: { $0.id == resolvedId && $0.keychainAccount != keychainAccount }) {
            guard collision.isCLIOrigin else {
                updated = existing
                guard updated != existing else { return }
                settings.chatGPTAccounts[index] = updated
                return
            }
            updated.customLabel = updated.customLabel ?? collision.customLabel
            settings.chatGPTAccounts.removeAll {
                $0.id == collision.id && $0.keychainAccount == collision.keychainAccount
            }
            mergedCacheAccount = collision.keychainAccount
        }
        if updated != existing,
           let refreshedIndex = settings.chatGPTAccounts.firstIndex(
               where: { $0.keychainAccount == keychainAccount }
           ) {
            settings.chatGPTAccounts[refreshedIndex] = updated
        }
        // The removed row's on-disk usage cache is keyed by its own
        // `keychainAccount`, not by the shared identity `id` the merge just
        // collapsed onto this slot, so it would otherwise survive on disk
        // under a `keychainAccount` no account owns anymore. Cleared last so
        // every `settings` write above lands before this suspension point.
        if let mergedCacheAccount {
            await chatGPTUsageCacheRepository.clear(account: mergedCacheAccount)
        }
    }

    /// Polls every connected ChatGPT account except the primary, which
    /// `refreshChatGPTUsage` already handles. Per account, the Codex CLI
    /// login is tried first (D-03); only on a missing/expired/rejected login
    /// does the stored cookie run in the same cycle. Never touches
    /// `chatGPTConsecutiveInvalidSessionCount`, `hasChatGPTSessionCookie`,
    /// `chatGPTCredentialState`, or the session repository (D-04) -- those
    /// stay exclusively the stored-cookie path's own responsibility.
    func refreshAdditionalChatGPTAccounts(cliSuccessTracker: CLISuccessTracker? = nil) async {
        guard !isRefreshingAdditionalChatGPTAccounts else { return }
        cliSuccessTracker?.markPolled(.chatGPT)
        let additionalAccounts = settings.isChatGPTUsageShown
            ? settings.chatGPTAccounts.filter { !$0.isPrimary }
            : []
        // chatGPTAccountSources is shared with the primary account
        // (refreshPrimaryChatGPTUsageFromCodexCLI writes
        // chatGPTAccountSources[primaryId]); pruning it here must keep the
        // primary's own entry, never wipe it just because there are no
        // additional accounts this cycle.
        let primaryAccountId = settings.chatGPTAccounts.first(where: \.isPrimary)?.id
        guard !additionalAccounts.isEmpty else {
            if !chatGPTAccountUsage.isEmpty { chatGPTAccountUsage.removeAll() }
            if !chatGPTAccountErrors.isEmpty { chatGPTAccountErrors.removeAll() }
            chatGPTAccountSources = chatGPTAccountSources.filter { $0.key == primaryAccountId }
            return
        }

        isRefreshingAdditionalChatGPTAccounts = true
        defer { isRefreshingAdditionalChatGPTAccounts = false }

        // Drop state for accounts that are no longer connected before polling,
        // so a disconnected account cannot leave a stale bar behind.
        let connectedIds = Set(additionalAccounts.map(\.id))
        chatGPTAccountUsage = chatGPTAccountUsage.filter { connectedIds.contains($0.key) }
        chatGPTAccountErrors = chatGPTAccountErrors.filter { connectedIds.contains($0.key) }
        chatGPTAccountSources = chatGPTAccountSources.filter { connectedIds.contains($0.key) || $0.key == primaryAccountId }

        let codexWorkspace = await resolveCodexWorkspace()
        let now = Date()
        let results = await withTaskGroup(
            of: (keychainAccount: String, outcome: ChatGPTAccountRefreshOutcome).self,
            returning: [String: ChatGPTAccountRefreshOutcome].self
        ) { group in
            for account in additionalAccounts {
                let chatgptAccountId = resolvedCodexWorkspaceAccountId(for: account, codexWorkspace: codexWorkspace)
                let codexLogin = latestCLILoginSnapshot.codexLogin(forChatGPTUserId: account.id)
                let isCLIOrigin = account.isCLIOrigin
                group.addTask { [chatGPTUsageService] in
                    let outcome = await fetchAdditionalChatGPTOutcome(
                        chatGPTUsageService: chatGPTUsageService,
                        account: account,
                        codexLogin: codexLogin,
                        chatgptAccountId: chatgptAccountId,
                        isCLIOrigin: isCLIOrigin,
                        now: now
                    )
                    return (account.keychainAccount, outcome)
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
            case .success(let usage, let identity, let source):
                // Resolve the identity before choosing the dictionary key. A
                // changed identity clears the previous account's cached rows,
                // then this poll's fresh rows land under the replacement id.
                await applyChatGPTIdentity(identity, keychainAccount: account.keychainAccount)
                guard let resolvedAccount = settings.chatGPTAccounts.first(
                    where: { $0.keychainAccount == account.keychainAccount }
                ) else { continue }
                chatGPTAccountUsage[resolvedAccount.id] = usage
                chatGPTAccountErrors[resolvedAccount.id] = nil
                chatGPTAccountSources[resolvedAccount.id] = source
                if source == .codexCLI {
                    cliSuccessTracker?.insert(.chatGPT)
                }
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

    /// Polls the primary ChatGPT account. Per D-03, the Codex CLI login is
    /// tried first; only when it is missing, expired, or rejected does the
    /// stored cookie get polled in the same cycle.
    func refreshChatGPTUsage(cliSuccessTracker: CLISuccessTracker? = nil) async {
        if await refreshPrimaryChatGPTUsageFromCodexCLI(cliSuccessTracker: cliSuccessTracker) { return }
        await refreshPrimaryChatGPTUsageFromStoredSession()
    }

    /// Returns `true` when this cycle's primary ChatGPT poll is settled by
    /// the Codex CLI login alone -- a success, an outage, or cancellation --
    /// meaning the stored-cookie path must not also run this cycle. Returns
    /// `false` only when there is no reason to have tried (no login, no
    /// primary account, or an expired token -- D-05, zero requests) or the
    /// attempt was rejected in a way that falls back to the cookie (D-03).
    /// Never touches the ChatGPT session repository, the consecutive-
    /// rejection counter, `hasChatGPTSessionCookie`, or
    /// `chatGPTCredentialState` (D-04): those belong exclusively to the
    /// stored-cookie path below, so a Codex CLI failure can never look like a
    /// cookie rejection.
    private func refreshPrimaryChatGPTUsageFromCodexCLI(cliSuccessTracker: CLISuccessTracker? = nil) async -> Bool {
        guard !isRefreshingChatGPT else { return false }
        guard let primaryAccount = settings.chatGPTAccounts.first(where: \.isPrimary) else { return false }
        guard let login = latestCLILoginSnapshot.codexLogin(forChatGPTUserId: primaryAccount.id) else { return false }
        guard !login.isExpired(now: Date()) else { return false }

        isRefreshingChatGPT = true
        defer { isRefreshingChatGPT = false }

        do {
            let (usage, identity) = try await chatGPTUsageService.fetchUsageAndIdentity(codexCLILogin: login)
            chatGPTUsageData = usage
            await applyChatGPTIdentity(identity, keychainAccount: ChatGPTAccount.primaryKeychainAccount)
            chatGPTErrorMessage = nil
            chatGPTLastFailure = nil
            chatGPTLastFailureStatusCode = nil
            let resolvedId = settings.chatGPTAccounts.first(where: \.isPrimary)?.id ?? primaryAccount.id
            chatGPTAccountSources[resolvedId] = .codexCLI
            cliSuccessTracker?.insert(.chatGPT)
            await chatGPTUsageCacheRepository.save(usage, account: ChatGPTAccount.primaryKeychainAccount)
            await exportAggregateUsageSnapshot()
            return true
        } catch let error as CLIUsageFetchError {
            if error.fallsBackToStoredSession {
                return false
            }
            chatGPTErrorMessage = error.localizedDescription
            await exportAggregateUsageSnapshot()
            return true
        } catch is CancellationError {
            return true
        } catch {
            chatGPTErrorMessage = error.localizedDescription
            await exportAggregateUsageSnapshot()
            return true
        }
    }

    private func refreshPrimaryChatGPTUsageFromStoredSession() async {
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
                // A CLI-backed state belongs to `applyCLICredentialStates`,
                // which resets it only in a cycle that actually polled the
                // CLI login. Overwriting it here would let a cycle that
                // bounced off another cycle's in-flight guard report
                // `.missing` and start an unneeded browser recovery scan. A
                // stored cookie that is now available always takes over.
                if status.state == .available || chatGPTCredentialState.identity.kind != .accessToken {
                    chatGPTCredentialState = Self.credentialState(from: status, checkedAt: Date())
                }
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
            let primaryAccount = settings.chatGPTAccounts.first(where: \.isPrimary)
                ?? ChatGPTAccount.legacyPrimary(customLabel: nil)
            let codexWorkspace = await resolveCodexWorkspace()
            let (usage, identity) = try await chatGPTUsageService.fetchUsageAndIdentity(
                account: ChatGPTAccount.primaryKeychainAccount,
                chatgptAccountId: resolvedCodexWorkspaceAccountId(for: primaryAccount, codexWorkspace: codexWorkspace)
            )
            chatGPTUsageData = usage
            await applyChatGPTIdentity(identity, keychainAccount: ChatGPTAccount.primaryKeychainAccount)
            chatGPTConsecutiveInvalidSessionCount = 0
            chatGPTLastFailure = nil
            chatGPTLastFailureStatusCode = nil
            hasChatGPTSessionCookie = true
            chatGPTCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
                health: .valid,
                checkedAt: Date()
            )
            let resolvedId = settings.chatGPTAccounts.first(where: \.isPrimary)?.id ?? primaryAccount.id
            chatGPTAccountSources[resolvedId] = .storedSession
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
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
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
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
        try await chatGPTSessionRepository.clear(account: ChatGPTAccount.primaryKeychainAccount)
        await chatGPTUsageCacheRepository.clear(account: ChatGPTAccount.primaryKeychainAccount)
        await disconnectAllAdditionalChatGPTAccounts()
        // A CLI-origin account has no stored cookie of its own and must
        // survive clearing the primary one entirely (RESEARCH Pitfall 7) --
        // unless the user has separately excluded it. "Show ChatGPT usage"
        // stays on exactly while one of these remains.
        let retained = settings.chatGPTAccounts.filter { account in
            account.isCLIOrigin && !isChatGPTAccountExcluded(account.id)
        }
        settings.chatGPTAccounts = retained
        hasChatGPTSessionCookie = false
        settings.isChatGPTUsageShown = !retained.isEmpty
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
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
        guard let account = settings.chatGPTAccounts.first(where: { $0.id == id }) else { return }

        // A CLI-backed account must stay removed (D-01, RESEARCH Pitfall 9):
        // captured before removal, since `account` itself is gone from
        // `settings.chatGPTAccounts` by the time either branch below
        // finishes. "CLI-backed" also covers a cookie-backed account the
        // latest CLI snapshot happens to hold a login for.
        let wasCLIBacked = account.isCLIOrigin
            || latestCLILoginSnapshot.codexLogin(forChatGPTUserId: account.id) != nil

        if account.isPrimary {
            // A settings row can outlive a missing or unreadable Keychain
            // entry. Promote the first account whose session actually loads,
            // so one broken row cannot block removal of the primary account.
            // A CLI-origin candidate is never a promotion target -- it has
            // no stored cookie of its own (RESEARCH Pitfall 7).
            var promoted: (account: ChatGPTAccount, session: ChatGPTSession)?
            for candidate in settings.chatGPTAccounts where !candidate.isPrimary && !candidate.isCLIOrigin {
                if let session = try? await chatGPTSessionRepository.load(account: candidate.keychainAccount) {
                    promoted = (candidate, session)
                    break
                }
            }
            guard let successor = promoted?.account, let session = promoted?.session else {
                if wasCLIBacked {
                    upsertScanExclusion(.chatGPT(account))
                }
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
            if wasCLIBacked {
                upsertScanExclusion(.chatGPT(account))
            }
            await refreshChatGPTUsage()
            return
        }

        try? await chatGPTSessionRepository.clear(account: account.keychainAccount)
        await chatGPTUsageCacheRepository.clear(account: account.keychainAccount)
        chatGPTAccountUsage[account.id] = nil
        chatGPTAccountErrors[account.id] = nil
        settings.chatGPTAccounts.removeAll { $0.id == account.id }
        if wasCLIBacked {
            upsertScanExclusion(.chatGPT(account))
        }
        await exportAggregateUsageSnapshot()
    }

    /// Disconnects every non-primary ChatGPT account's stored cookie,
    /// Keychain slot, cached usage, and cached error. A CLI-origin account
    /// has none of those -- it is skipped entirely, so it survives alongside
    /// whatever `clearChatGPTSessionCookie` retains it for (RESEARCH Pitfall 7).
    private func disconnectAllAdditionalChatGPTAccounts() async {
        for account in settings.chatGPTAccounts where !account.isPrimary && !account.isCLIOrigin {
            try? await chatGPTSessionRepository.clear(account: account.keychainAccount)
            await chatGPTUsageCacheRepository.clear(account: account.keychainAccount)
            chatGPTAccountUsage[account.id] = nil
            chatGPTAccountErrors[account.id] = nil
        }
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
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
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
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
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
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
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
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
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
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
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
        // A CLI-origin entry for this same organization can have a
        // differently-cased id than `organization.uuid` (the Keychain-
        // derived id is always lowercased; the browser/cookie-reported one
        // is whatever the API returned) -- compare `organizationId` as a
        // `UUID`, not just the raw `id` string, so that entry merges into
        // the newly-registered primary instead of surviving as a duplicate.
        var accounts = settings.claudeAccounts.filter {
            !$0.isPrimary && $0.id != primary.id && $0.organizationId != organizationId
        }
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
    func connectClaudeAccounts(
        importedKeys: [ImportedSessionKey],
        preserveExistingAccounts: Bool = false,
        allowedAccountIds: Set<String>? = nil
    ) async throws -> ClaudeAccountsImportResult {
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
        // A CLI-origin account is never part of a browser scan: capture it
        // here so a scan that does not rediscover its organization cannot
        // silently drop the row (RESEARCH Pitfall 8). A rediscovered
        // organization keeps the controller's rebuilt, cookie-backed account
        // (origin nil) instead -- that is the D-03 merge.
        let previousCLIAccounts = settings.claudeAccounts.filter(\.isCLIOrigin)
        let connection = try await claudeAccountConnectionController.connect(
            importedKeys: importedKeys,
            preserveExistingAccounts: preserveExistingAccounts,
            allowedAccountIds: allowedAccountIds,
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

        let retainedCLIAccounts = previousCLIAccounts.filter { cli in
            !connection.accounts.contains { $0.organizationId == cli.organizationId }
        }
        let retainedCLIIds = Set(retainedCLIAccounts.map(\.id))

        for staleId in connection.staleAccountIds where !retainedCLIIds.contains(staleId) {
            claudeAccountUsage[staleId] = nil
            claudeAccountErrors[staleId] = nil
        }

        settings.claudeAccounts = connection.accounts + retainedCLIAccounts
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
        importedCookies: [ImportedChatGPTSessionCookie],
        preserveExistingAccounts: Bool = false,
        allowedAccountIds: Set<String>? = nil
    ) async throws -> ChatGPTAccountsImportResult {
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
        // A CLI-origin account is never part of a browser scan: capture it
        // here so a scan that does not rediscover its ChatGPT user id cannot
        // silently drop the row (RESEARCH Pitfall 8). A rediscovered user id
        // keeps the controller's rebuilt, cookie-backed account (origin nil)
        // instead -- that is the D-03 merge.
        let previousCLIAccounts = settings.chatGPTAccounts.filter(\.isCLIOrigin)
        let connection = try await chatGPTAccountConnectionController.connect(
            importedCookies: importedCookies,
            preserveExistingAccounts: preserveExistingAccounts,
            allowedAccountIds: allowedAccountIds,
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

        let retainedCLIAccounts = previousCLIAccounts.filter { cli in
            !connection.accounts.contains { $0.id == cli.id }
        }
        let retainedCLIIds = Set(retainedCLIAccounts.map(\.id))

        for staleId in connection.staleAccountIds where !retainedCLIIds.contains(staleId) {
            chatGPTAccountUsage[staleId] = nil
            chatGPTAccountErrors[staleId] = nil
        }

        settings.chatGPTAccounts = connection.accounts + retainedCLIAccounts
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
            connectedSourceDescriptions: connection.accounts.compactMap(\.profileLabel),
            connected: connection.connected
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

    func discoverBrowserSessions() async -> BrowserSessionImportReview {
        let running = runningBrowserSources()
        guard !running.isEmpty else {
            importProgress = nil
            return BrowserSessionImportReview(
                scannedBrowsers: [],
                sessions: [],
                failures: []
            )
        }

        var sessions: [BrowserSessionImportSession] = []
        var failures: [BrowserSessionImportFailure] = []

        for browser in running {
            importProgress = "Scanning \(browser.displayName)\u{2026}"
            do {
                let keys = try await sessionKeyImportService.importAllSessionKeys(from: browser)
                for key in keys {
                    sessions.append(BrowserSessionImportSession(
                        provider: .claude,
                        source: browser,
                        profileLabel: key.sourceDescription,
                        credential: .claudeSessionKey(key.value)
                    ))
                }
            } catch let error as SessionKeyImportError {
                failures.append(BrowserSessionImportFailure(
                    provider: .claude,
                    source: browser,
                    message: error.localizedDescription,
                    offersFullDiskAccessSettings: error.offersFullDiskAccessSettings
                ))
            } catch {
                failures.append(BrowserSessionImportFailure(
                    provider: .claude,
                    source: browser,
                    message: error.localizedDescription,
                    offersFullDiskAccessSettings: false
                ))
            }
            importProgress = "Scanning ChatGPT sessions (\(browser.displayName))\u{2026}"
            do {
                let cookies = try await sessionKeyImportService.importAllChatGPTSessionCookies(from: browser)
                for cookie in cookies {
                    sessions.append(BrowserSessionImportSession(
                        provider: .chatGPT,
                        source: browser,
                        profileLabel: cookie.sourceDescription,
                        credential: .chatGPTCookie(cookie.cookieHeader)
                    ))
                }
            } catch let error as SessionKeyImportError {
                failures.append(BrowserSessionImportFailure(
                    provider: .chatGPT,
                    source: browser,
                    message: error.localizedDescription,
                    offersFullDiskAccessSettings: error.offersFullDiskAccessSettings
                ))
            } catch {
                failures.append(BrowserSessionImportFailure(
                    provider: .chatGPT,
                    source: browser,
                    message: error.localizedDescription,
                    offersFullDiskAccessSettings: false
                ))
            }
        }

        importProgress = nil
        return BrowserSessionImportReview(
            scannedBrowsers: running,
            sessions: sessions,
            failures: failures
        )
    }

    func connectBrowserSessions(
        _ sessions: [BrowserSessionImportSession],
        allowedAccountIds: [CredentialProvider: Set<String>] = [:],
        discoveryFailures: [BrowserSessionImportFailure] = []
    ) async -> BrowserScanOutcome {
        guard !sessions.isEmpty else {
            return BrowserScanOutcome(scannedBrowsers: [], results: [])
        }

        let sources = BrowserImportSource.scanTargets.filter { source in
            sessions.contains { $0.source == source }
        }
        let selectedKeys = sessions.compactMap { session -> ImportedSessionKey? in
            guard case .claudeSessionKey(let value) = session.credential else { return nil }
            return ImportedSessionKey(value: value, sourceDescription: session.profileLabel)
        }
        let selectedCookies = sessions.compactMap { session -> ImportedChatGPTSessionCookie? in
            guard case .chatGPTCookie(let value) = session.credential else { return nil }
            return ImportedChatGPTSessionCookie(cookieHeader: value, sourceDescription: session.profileLabel)
        }

        var connectedKeyValues = Set<String>()
        var claudeFailure: String?
        if !selectedKeys.isEmpty {
            do {
                let keys = await selectedKeys + retainedClaudeSessionKeys(excluding: Set(selectedKeys.map(\.value)))
                let connection = try await connectClaudeAccounts(
                    importedKeys: keys,
                    preserveExistingAccounts: true,
                    allowedAccountIds: allowedAccountIds[.claude]
                )
                connectedKeyValues = Set(connection.connected.map(\.value))
            } catch {
                importProgress = nil
                claudeFailure = error.localizedDescription
            }
        }

        var connectedCookieValues = Set<String>()
        var chatGPTFailure: String?
        if !selectedCookies.isEmpty {
            do {
                let cookies = await selectedCookies + retainedChatGPTSessionCookies(
                    excluding: Set(selectedCookies.map { ChatGPTUsageService.cookieHeader(from: $0.cookieHeader) })
                )
                let connection = try await connectChatGPTAccounts(
                    importedCookies: cookies,
                    preserveExistingAccounts: true,
                    allowedAccountIds: allowedAccountIds[.chatGPT]
                )
                connectedCookieValues = Set(connection.connected.map {
                    ChatGPTUsageService.cookieHeader(from: $0.cookieHeader)
                })
            } catch {
                importProgress = nil
                chatGPTFailure = error.localizedDescription
            }
        }

        var results: [BrowserScanOutcome.BrowserResult] = []
        for browser in sources {
            results.append(BrowserScanOutcome.BrowserResult(
                source: browser,
                claude: browserImportStatus(
                    for: browser,
                    provider: .claude,
                    sessions: sessions,
                    connectedValues: connectedKeyValues,
                    failure: claudeFailure ?? SessionKeyImportError.invalidImportedSessionKey.localizedDescription
                ),
                chatGPT: browserImportStatus(
                    for: browser,
                    provider: .chatGPT,
                    sessions: sessions,
                    connectedValues: connectedCookieValues,
                    failure: chatGPTFailure ?? SessionKeyImportError.invalidImportedChatGPTSessionCookie.localizedDescription
                )
            ))
        }

        importProgress = nil
        var outcome = BrowserScanOutcome(scannedBrowsers: sources, results: results)
        outcome.discoveryFailures = discoveryFailures
        outcome.sessionFailures = sessions.compactMap { session in
            let connected: Bool
            let failure: String?
            switch session.credential {
            case .claudeSessionKey(let value):
                connected = connectedKeyValues.contains(value)
                failure = claudeFailure
            case .chatGPTCookie(let value):
                connected = connectedCookieValues.contains(ChatGPTUsageService.cookieHeader(from: value))
                failure = chatGPTFailure
            }
            guard !connected else { return nil }
            let message = failure ?? "This session could not connect. Sign in again, or re-enable the account in Accounts settings if it is excluded from scans."
            return "\(session.provider.displayName), \(session.profileLabel): \(message)"
        }
        return outcome
    }

    private func browserImportStatus(
        for source: BrowserImportSource,
        provider: CredentialProvider,
        sessions: [BrowserSessionImportSession],
        connectedValues: Set<String>,
        failure: String
    ) -> ProviderBrowserImportStatus {
        let selected = sessions.filter { $0.source == source && $0.provider == provider }
        guard !selected.isEmpty else { return .notSelected }
        if let connected = selected.first(where: { session in
            switch session.credential {
            case .claudeSessionKey(let value):
                connectedValues.contains(value)
            case .chatGPTCookie(let value):
                connectedValues.contains(ChatGPTUsageService.cookieHeader(from: value))
            }
        }) {
            return .imported(sourceDescription: connected.profileLabel)
        }
        return .failed(message: failure, offersFullDiskAccessSettings: false)
    }

    private func retainedClaudeSessionKeys(excluding selectedValues: Set<String>) async -> [ImportedSessionKey] {
        var retained: [ImportedSessionKey] = []
        for account in settings.claudeAccounts {
            guard let value = try? await keychainRepository.retrieve(account: account.keychainAccount),
                  !selectedValues.contains(value) else { continue }
            retained.append(ImportedSessionKey(
                value: value,
                sourceDescription: account.profileLabel ?? Self.retainedSessionSourceDescription
            ))
        }
        return retained
    }

    private func retainedChatGPTSessionCookies(excluding selectedValues: Set<String>) async -> [ImportedChatGPTSessionCookie] {
        var retained: [ImportedChatGPTSessionCookie] = []
        for account in settings.chatGPTAccounts {
            guard let session = try? await chatGPTSessionRepository.load(account: account.keychainAccount) else { continue }
            let value = ChatGPTUsageService.cookieHeader(from: session.sessionCookie)
            guard !value.isEmpty, !selectedValues.contains(value) else { continue }
            retained.append(ImportedChatGPTSessionCookie(
                cookieHeader: value,
                sourceDescription: account.profileLabel ?? Self.retainedSessionSourceDescription
            ))
        }
        return retained
    }

    /// Reflects this cycle's CLI-sourced successes (`cliSuccessTracker`)
    /// into the provider-level credential state (CLI-08, RESEARCH Pitfall 4):
    /// a provider with no usable stored credential but a successful CLI poll
    /// this cycle reports `.valid` with kind `.accessToken` instead of
    /// `.missing`, so Settings shows the truth and browser recovery does not
    /// fire. Only runs when the provider has no stored credential of its own
    /// (`!isSetupComplete` / `!hasChatGPTSessionCookie`): a stored credential
    /// always keeps driving its own state, exactly as before this plan.
    /// Reverts to the bootstrap `.missing` form the first cycle a previously
    /// CLI-backed provider has no CLI success and no stored credential
    /// (CLI-07's "stale CLI success never outlives its cycle" rule).
    ///
    /// The reset branch additionally requires `cliSuccessTracker.polled(_:)`
    /// (re-review #1): `refreshUsage`, `refreshAdditionalClaudeAccounts`, and
    /// `refreshAdditionalChatGPTAccounts` each return early, without
    /// recording anything in this run's tracker, when another overlapping
    /// refresh cycle still holds their own reentrancy guard. Without the
    /// `polled` check, that early return looked identical to "this run
    /// genuinely polled and found no CLI success," so whichever overlapping
    /// cycle happened to call `applyCLICredentialStates` last could flip an
    /// otherwise-valid CLI-backed provider to `.missing` purely because its
    /// own poll was skipped -- not because the credential actually failed --
    /// which could then make `recoverBrowserSessionsIfNeeded` start an
    /// unneeded browser scan/prompt. A skipped run now leaves the provider's
    /// credential state untouched instead, deferring to whichever cycle
    /// actually owns the in-flight guard this round.
    private func applyCLICredentialStates(cliSuccessTracker: CLISuccessTracker) {
        if !isSetupComplete {
            if cliSuccessTracker.contains(.claude) {
                claudeCredentialState = CredentialState(
                    identity: CredentialIdentity(provider: .claude, kind: .accessToken),
                    health: .valid,
                    checkedAt: Date()
                )
            } else if cliSuccessTracker.polled(.claude), claudeCredentialState.identity.kind == .accessToken {
                claudeCredentialState = CredentialState(
                    identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
                    health: .missing,
                    failureCategory: .missing,
                    checkedAt: Date()
                )
            }
        }
        if !hasChatGPTSessionCookie {
            if cliSuccessTracker.contains(.chatGPT) {
                chatGPTCredentialState = CredentialState(
                    identity: CredentialIdentity(provider: .chatGPT, kind: .accessToken),
                    health: .valid,
                    checkedAt: Date()
                )
            } else if cliSuccessTracker.polled(.chatGPT), chatGPTCredentialState.identity.kind == .accessToken {
                chatGPTCredentialState = CredentialState(
                    identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
                    health: .missing,
                    failureCategory: .missing,
                    checkedAt: Date()
                )
            }
        }
    }

    /// The discover-and-connect half of browser session recovery, shared by
    /// the ordinary polling path (`recoverBrowserSessionsIfNeeded`), the
    /// bounded recovery watch (`startBrowserRecoveryWatch`), and the
    /// explicit Reconnect alert action. Never prompts -- raising the login
    /// prompt is the caller's decision, not this function's.
    private func runBrowserSessionRecovery(for providers: Set<CredentialProvider>) async {
        guard !providers.isEmpty, !isRecoveringBrowserSessions else { return }

        isRecoveringBrowserSessions = true
        let claudeAccounts = settings.claudeAccounts
        let chatGPTAccounts = settings.chatGPTAccounts
        let allowedAccountIds: [CredentialProvider: Set<String>] = [
            .claude: Set(claudeAccounts.map(\.id)),
            .chatGPT: Set(chatGPTAccounts.map(\.id)),
        ]
        let review = await discoverBrowserSessions()
        let approvedSessions = review.sessions.filter { session in
            providers.contains(session.provider)
                && !(allowedAccountIds[session.provider] ?? []).isEmpty
        }
        if !approvedSessions.isEmpty {
            _ = await connectBrowserSessions(approvedSessions, allowedAccountIds: allowedAccountIds)
            // Recovery may refresh credential material only: restore each
            // surviving account's display fields (label/profileLabel/
            // customLabel) to what they were before the scan. Everything
            // identity-bearing (id, organizationId/keychainAccount) is a
            // `let` on these types, so it cannot have drifted; only display
            // fields can.
            //
            // This restores fields on the CURRENT array rather than
            // replacing it wholesale with the pre-await snapshot. A blind
            // `settings.claudeAccounts = claudeAccounts` would silently
            // revert an account the operator added or removed in Settings
            // while `discoverBrowserSessions`/`connectBrowserSessions` were
            // awaiting. A rename made during that window is still restored to
            // the snapshot's label, since recovery cannot tell it apart from a
            // label the provider rewrote. That race existed before, but this function now
            // runs every `browserRecoveryWatchPolicy.interval` for up to
            // `maxAttempts` (D-04) instead of once per poll, so the window
            // recurs far more often (review finding, quick task 261001-ckk).
            let claudeById = Dictionary(claudeAccounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            settings.claudeAccounts = settings.claudeAccounts.map { current in
                guard let original = claudeById[current.id] else { return current }
                var restored = current
                restored.label = original.label
                restored.profileLabel = original.profileLabel
                restored.customLabel = original.customLabel
                return restored
            }
            let chatGPTById = Dictionary(chatGPTAccounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            settings.chatGPTAccounts = settings.chatGPTAccounts.map { current in
                guard let original = chatGPTById[current.id] else { return current }
                var restored = current
                restored.label = original.label
                restored.planType = original.planType
                restored.profileLabel = original.profileLabel
                restored.customLabel = original.customLabel
                return restored
            }
        }
        isRecoveringBrowserSessions = false
    }

    /// Refreshes the one provider's usage after a recovery attempt. Both
    /// paths end in `exportAggregateUsageSnapshot`, which is what updates
    /// the broker oracle the degraded-pick fault logic reads (D-04).
    private func refreshBrowserProviderUsage(_ provider: CredentialProvider) async {
        switch provider {
        case .claude:
            await refreshUsage(forceRefresh: true)
            await refreshAdditionalClaudeAccounts(forceRefresh: true)
        case .chatGPT:
            await refreshChatGPTUsage()
            await refreshAdditionalChatGPTAccounts()
        case .gemini:
            break
        }
    }

    /// True only when the credential is usable AND the most recent poll for
    /// it actually succeeded -- the same inputs `buildAggregateQuotaRows`
    /// uses to decide a row is `.error`. A credential that is still usable
    /// but whose last poll failed must NOT count as recovered: that is
    /// exactly the state a stale-but-not-yet-rejected session is in.
    ///
    /// Claude covers every account, not just the primary. The degraded alert
    /// can name an additional account (`BrokerProviderFault
    /// .claudeAccountDisconnected`), and both Reconnect and the watch it
    /// starts must agree, or the watch announces "Claude reconnected" while
    /// that account is still broken. The cost is that an unrelated failing
    /// additional account withholds the notice and lets the watch run to
    /// `maxAttempts`, which is bounded and loses only a notification
    /// (review finding, quick task 261001-ckk).
    private func browserProviderIsHealthy(_ provider: CredentialProvider) -> Bool {
        switch provider {
        case .claude:
            claudeCredentialState.isUsable && errorMessage == nil && claudeAccountErrors.isEmpty
        case .chatGPT:
            chatGPTCredentialState.isUsable && chatGPTErrorMessage == nil
        case .gemini:
            true
        }
    }

    /// Starts (or restarts) the bounded post-prompt recovery watch (D-04):
    /// rechecks browsers every `browserRecoveryWatchPolicy.interval`, up to
    /// `maxAttempts` times, posts "<Provider> reconnected" and refreshes
    /// usage for anything that recovers, and never raises another login
    /// prompt -- the operator already saw one for this episode.
    ///
    /// Any running watch is cancelled and restarted so there is only ever
    /// one in flight, carrying forward the union of its own pending set and
    /// the newly failing providers, so a provider the previous watch had not
    /// yet recovered is never silently dropped.
    func startBrowserRecoveryWatch(for providers: Set<CredentialProvider>) {
        browserRecoveryWatchTask?.cancel()
        browserRecoveryWatchProviders.formUnion(providers)
        let policy = browserRecoveryWatchPolicy
        let sleep = browserRecoveryWatchSleep

        browserRecoveryWatchTask = Task { [weak self] in
            for _ in 0..<policy.maxAttempts {
                do {
                    try await sleep(policy.interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }

                // Remove from the pending set BEFORE awaiting the
                // notification, and recheck cancellation right before
                // sending it. A provider only stays "pending" while this
                // specific watch iteration owns deciding its fate -- if a
                // concurrent `startBrowserRecoveryWatch` call (a fresh poll,
                // or an explicit Reconnect) cancels this task while the
                // notification send is in flight, that other path is now
                // the one responsible for this provider, and must not also
                // see it as still-pending and notify about it a second time
                // (review finding, quick task 261001-ckk).
                let alreadyHealthy = self.browserRecoveryWatchProviders.filter(self.browserProviderIsHealthy)
                for provider in alreadyHealthy {
                    guard !Task.isCancelled else { return }
                    self.browserRecoveryWatchProviders.remove(provider)
                    await self.postProviderReconnected(provider)
                }
                if self.browserRecoveryWatchProviders.isEmpty { return }
                guard !Task.isCancelled else { return }

                let pending = self.browserRecoveryWatchProviders
                await self.runBrowserSessionRecovery(for: pending)
                guard !Task.isCancelled else { return }
                for provider in pending {
                    await self.refreshBrowserProviderUsage(provider)
                }
                guard !Task.isCancelled else { return }

                let newlyHealthy = self.browserRecoveryWatchProviders.filter(self.browserProviderIsHealthy)
                for provider in newlyHealthy {
                    guard !Task.isCancelled else { return }
                    self.browserRecoveryWatchProviders.remove(provider)
                    await self.postProviderReconnected(provider)
                }
                if self.browserRecoveryWatchProviders.isEmpty { return }
            }
            guard let self, !self.browserRecoveryWatchProviders.isEmpty else { return }
            Self.logger.info(
                "Browser recovery watch exhausted without recovering \(self.browserRecoveryWatchProviders.map(\.rawValue).sorted(), privacy: .public)"
            )
            self.browserRecoveryWatchProviders.removeAll()
        }
    }

    /// Posts the "<Provider> reconnected" notification. Failure is logged,
    /// never thrown -- a dropped notification must not interrupt the watch
    /// loop or the recovery it is reporting on.
    private func postProviderReconnected(_ provider: CredentialProvider) async {
        do {
            try await notificationService.sendProviderReconnectedNotification(provider)
        } catch {
            Self.logger.debug(
                "Reconnected notification failed for \(provider.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func recoverBrowserSessionsIfNeeded() async {
        var failedProviders = Set<CredentialProvider>()
        // A provider whose every connected account is CLI-origin never scans
        // a browser or prompts for one: the CLI login already serves it, and
        // a browser cookie would just be a second, unneeded credential
        // (CLI-08, RESEARCH Pitfall 4).
        if (isSetupComplete || settings.claudeAccounts.contains(where: { !$0.isCLIOrigin })),
           [.missing, .providerRejected].contains(claudeCredentialState.failureCategory) {
            failedProviders.insert(.claude)
        }
        if settings.isChatGPTUsageShown,
           (settings.chatGPTAccounts.isEmpty || settings.chatGPTAccounts.contains(where: { !$0.isCLIOrigin })),
           [.missing, .providerRejected].contains(chatGPTCredentialState.failureCategory) {
            failedProviders.insert(.chatGPT)
        }

        promptedBrowserProviders.formIntersection(failedProviders)
        guard !failedProviders.isEmpty, !isRecoveringBrowserSessions else { return }

        await runBrowserSessionRecovery(for: failedProviders)

        let stillFailed = failedProviders.filter { provider in
            switch provider {
            case .claude: !claudeCredentialState.isUsable
            case .chatGPT: !chatGPTCredentialState.isUsable
            case .gemini: false
            }
        }
        guard !stillFailed.isEmpty else { return }

        let unprompted = stillFailed
            .subtracting(promptedBrowserProviders)
            .subtracting(browserRecoveryWatchProviders)
        guard !unprompted.isEmpty else { return }

        promptedBrowserProviders.formUnion(unprompted)
        browserLoginPrompt(unprompted.sorted { $0.displayName < $1.displayName })
        // Only the providers this call JUST prompted for start a watch.
        // `startBrowserRecoveryWatch` cancels and restarts, resetting the
        // attempt counter -- calling it for every still-failing provider on
        // every poll (refresh ticks, wake, every broker `refresh`) would
        // mean the 10-minute cap never actually applies, and recovery would
        // scan + force-fetch every `interval` forever (review finding,
        // quick task 261001-ckk). A provider already in
        // `browserRecoveryWatchProviders` is excluded from `unprompted` by
        // construction, so its running watch is left alone.
        startBrowserRecoveryWatch(for: unprompted)
    }

    /// The degraded-pick alert's Reconnect action (D-02): runs recovery for
    /// exactly the one provider the operator asked about, right now, rather
    /// than waiting for the next poll cycle to notice.
    ///
    /// Runs regardless of `failureCategory` -- the broker's provider fault
    /// fires after a single failed poll, before the credential has flipped to
    /// `.providerRejected`, so gating this on that category would make the
    /// button silently do nothing for the exact alert that offered it.
    func reconnectBrowserSession(for provider: CredentialProvider) async {
        guard provider != .gemini else { return }

        await runBrowserSessionRecovery(for: [provider])
        await refreshBrowserProviderUsage(provider)

        if browserProviderIsHealthy(provider) {
            // Remove before awaiting the notification (same ordering as the
            // watch loop, and for the same reason): a concurrently running
            // watch for this same provider must see it already claimed, not
            // still pending, or both paths could notify.
            browserRecoveryWatchProviders.remove(provider)
            await postProviderReconnected(provider)
        } else {
            // The user asked explicitly, so prompting again is intended even
            // within an episode that already prompted once automatically.
            promptedBrowserProviders.insert(provider)
            browserLoginPrompt([provider])
            startBrowserRecoveryWatch(for: [provider])
        }
    }

    func repairClaudeSessionKey() async -> CredentialState {
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
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
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
        guard let account = settings.claudeAccounts.first(where: { $0.id == id }) else {
            if settings.claudeAccounts.isEmpty {
                try await clearSessionKey()
            }
            return
        }

        // A CLI-backed account must stay removed (D-01, RESEARCH Pitfall 9):
        // captured before removal, since `account` itself is gone from
        // `settings.claudeAccounts` by the time either branch below finishes.
        // "CLI-backed" also covers a cookie-backed account the latest CLI
        // snapshot happens to hold a login for -- not just one already
        // marked `origin == .cliLogin` -- so reconciliation cannot silently
        // undo this removal on the very next refresh cycle.
        let wasCLIBacked = account.isCLIOrigin
            || latestCLILoginSnapshot.claudeLogin(forOrganizationId: account.organizationId) != nil

        guard account.isPrimary else {
            // Take this branch regardless of the total account count. A lone
            // non-primary account (always true for a CLI-origin account,
            // which reconciliation never makes primary) must never fall into
            // the "last remaining account" branch below -- that calls
            // `clearSessionKey()`, which deletes the unrelated `"default"`
            // Keychain slot and resets `isSetupComplete`/`isFirstLaunch` for
            // an account that was never that slot.
            try? await keychainRepository.delete(account: account.keychainAccount)
            settings.claudeAccounts.removeAll { $0.id == id }
            claudeAccountUsage[id] = nil
            claudeAccountErrors[id] = nil
            if wasCLIBacked {
                upsertScanExclusion(.claude(account))
            }
            await refreshAdditionalClaudeAccounts(forceRefresh: true)
            return
        }

        guard settings.claudeAccounts.count > 1 else {
            if wasCLIBacked {
                upsertScanExclusion(.claude(account))
            }
            try await clearSessionKey()
            return
        }

        let remaining = settings.claudeAccounts.filter { $0.id != id }
        // A CLI-origin account can never be promoted into the "default"
        // Keychain slot -- it has no stored session key to retrieve
        // (RESEARCH Pitfall 7).
        let promoted = remaining.filter { !$0.isCLIOrigin }.sorted { lhs, rhs in
            lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
        }.first

        guard let promoted else {
            if wasCLIBacked {
                upsertScanExclusion(.claude(account))
            }
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

        if wasCLIBacked {
            upsertScanExclusion(.claude(account))
        }
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
        await beginRemotePushInventoryMutation()
        defer { endRemotePushInventoryMutation() }
        try await keychainRepository.delete(account: "default")
        // A CLI-origin account has no Keychain item of its own and must
        // survive clearing the stored Claude credential entirely (RESEARCH
        // Pitfall 7) -- unless the user has separately excluded it.
        let retained = settings.claudeAccounts.filter { account in
            account.isCLIOrigin && !account.isPrimary && !isClaudeOrganizationExcluded(account.organizationId)
        }
        let retainedIds = Set(retained.map(\.id))
        for account in settings.claudeAccounts where !account.isPrimary && !retainedIds.contains(account.id) {
            try? await keychainRepository.delete(account: account.keychainAccount)
        }
        settings.claudeAccounts = retained
        claudeAccountUsage = claudeAccountUsage.filter { retainedIds.contains($0.key) }
        claudeAccountErrors = claudeAccountErrors.filter { retainedIds.contains($0.key) }
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
        await dispatchInstructionRecheckAutomaticallyIfNeeded(now: now)
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
        await dispatchInstructionRecheckAutomaticallyIfNeeded(now: now)
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
        let reason = InstructionRecheck.reason(
            for: check,
            currentVersion: BrokerMCPServer.appVersion,
            currentSetupRevision: settings.broker.effectiveAgentSetup?.revision,
            now: now
        )
        guard InstructionRecheck.shouldFire(
            reason: reason,
            lastFiredAt: settings.lastInstructionRecheckNotifiedAt,
            check: check,
            now: now
        ), let reason else { return }

        do {
            try await notificationService.sendInstructionRecheckReminder(
                reason: reason,
                setupNotice: settings.broker.effectiveAgentSetup
            )
            settings.lastInstructionRecheckNotifiedAt = now
        } catch {
            Self.logger.debug(
                "Instruction re-check reminder failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Starts an unattended re-check only after the user opts in and the
    /// shared reminder rule says it may fire.
    func dispatchInstructionRecheckAutomaticallyIfNeeded(now: Date = Date()) async {
        guard settings.broker.isEnabled,
              settings.broker.instructionDispatch.isAutomaticDispatchEnabled,
              let connectionState = t3Dispatch.connectionState(at: now),
              connectionState != .expired,
              settings.broker.instructionDispatch.t3ProjectID?.isEmpty == false,
              !t3Dispatch.isDispatching else {
            return
        }

        let check = await brokerService.latestInstructionCheck()
        let reason = InstructionRecheck.reason(
            for: check,
            currentVersion: BrokerMCPServer.appVersion,
            currentSetupRevision: settings.broker.effectiveAgentSetup?.revision,
            now: now
        )
        guard InstructionRecheck.shouldFire(
            reason: reason,
            lastFiredAt: settings.broker.instructionDispatch.lastAutomaticDispatchAt,
            check: check,
            now: now
        ) else { return }

        await dispatchInstructionRecheck(trigger: .automatic, now: now)
    }

    // MARK: - Broker preset manifest

    /// How often ``refreshPresetManifest(force:)`` re-checks on its own,
    /// mirroring the update-check loop's throttle idiom but on a much
    /// shorter cadence: the manifest is meant to be cheap to poll (a 304 on
    /// every unchanged check) and the whole point is that a newly published
    /// preset shows up the same day, not after a 24-hour wait.
    private static let presetManifestRefreshInterval: TimeInterval = 6 * 60 * 60

    /// Refreshes remote preset manifests. By default only the cached presets
    /// change. With auto-apply enabled, official updates to an unedited active
    /// built-in also update and push the live policy.
    ///
    /// No-op when the feature is off or the broker is off (unless `force`).
    /// On failure the source's previous presets are kept — stale-but-usable
    /// beats empty — and a short, sanitised error is stored for its UI row.
    func refreshPresetManifest(force: Bool = false) async {
        guard let presetManifestService else { return }
        guard settings.broker.presetManifest.isEnabled else { return }
        guard force || settings.broker.isEnabled else { return }

        let hadEverCheckedManifest = settings.broker.presetManifest.sources.contains {
            $0.lastCheckedAt != nil
        }
        let previousAgentSetup = settings.broker.effectiveAgentSetup

        migrateLegacyPresetManifestCacheIfNeeded()
        await loadPresetManifestHistoryIfNeeded()

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
                    let namespace = BrokerManifestHistoryNamespace(
                        sourceID: sourceID,
                        urlString: source.urlString
                    )
                    let historyState: BrokerManifestHistoryState
                    do {
                        let revisions = try await presetManifestHistoryStore.append(
                            manifest,
                            sourceID: sourceID,
                            urlString: source.urlString,
                            recordedAt: Date()
                        )
                        historyState = .loaded(Array(revisions.reversed()))
                    } catch {
                        historyState = .readError
                    }
                    guard let currentIndex = settings.broker.presetManifest.sources.firstIndex(
                        where: { $0.id == sourceID && $0.urlString == source.urlString }
                    ) else { continue }
                    presetManifestHistory[namespace] = historyState
                    settings.broker.presetManifest.sources[currentIndex].cachedPresets = manifest.presets
                    settings.broker.presetManifest.sources[currentIndex].cachedAgentSetup = manifest.agentSetup
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
        autoApplyPublishedRoutingUpdateIfNeeded()
        let effectiveAgentSetup = settings.broker.effectiveAgentSetup
        await brokerService.updateSetupRevision(effectiveAgentSetup?.revision)
        await sendRoutingUpdateNotificationIfNeeded(
            hadEverCheckedManifest: hadEverCheckedManifest
        )
        if previousAgentSetup != effectiveAgentSetup {
            await sendInstructionRecheckReminderIfNeeded()
            await dispatchInstructionRecheckAutomaticallyIfNeeded()
        }
    }

    private func autoApplyPublishedRoutingUpdateIfNeeded() {
        let broker = settings.broker
        guard broker.autoApplyPublishedRoutingUpdates,
              !broker.hasUnsavedRuleChanges,
              let profileID = broker.activeProfileID,
              BrokerAgentProfile.builtIn(id: profileID) != nil,
              broker.activeProfileHasUpdatedRules,
              let source = broker.presetManifest.sources.first(where: {
                  $0.cachedPresets.contains { $0.id == profileID }
              }),
              source.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                == BrokerPresetManifestConfig.defaultURLString,
              let fingerprint = Self.routingUpdateFingerprint(
                activeProfileID: profileID, activeRules: broker.activeProfile?.rules
              ),
              fingerprint != broker.suppressedAutomaticRoutingUpdateFingerprint else { return }
        applyRoutingUpdate(profileID: profileID)
    }

    var routingUpdateBannerFingerprint: String? {
        Self.routingUpdateFingerprint(
            activeProfileID: settings.broker.activeProfileID,
            activeRules: settings.broker.activeProfile?.rules
        )
    }

    var hasUndismissedRoutingUpdate: Bool {
        settings.broker.activeProfileHasUpdatedRules
            && routingUpdateBannerFingerprint != settings.broker.dismissedRoutingUpdateFingerprint
    }

    /// Adopts the active profile's published rules from the notification's
    /// Apply action, then pushes the resulting policy to the running broker.
    ///
    /// The push matters: the other apply paths use `onChange` hooks in the
    /// Broker window. This action can fire with that window closed, so the
    /// persisted policy must also reach the running broker immediately.
    @discardableResult
    func applyRoutingUpdate(profileID: UUID, discardingEdits: Bool = false) -> Bool {
        guard settings.broker.activeProfileID == profileID,
              settings.broker.activeProfileHasUpdatedRules else { return false }
        guard discardingEdits || !settings.broker.hasUnsavedRuleChanges else {
            NotificationCenter.default.post(name: .openBrokerSettings, object: nil)
            return false
        }
        settings.broker.applyProfile(id: profileID)
        routingUpdateApplyTask = Task { await applyBrokerSettingsChange() }
        return true
    }

    @discardableResult
    func undoRoutingUpdate(discardingEdits: Bool = false) -> Bool {
        let fingerprint = Self.routingUpdateFingerprint(
            activeProfileID: settings.broker.activeProfileID,
            activeRules: settings.broker.activeProfile?.rules
        )
        guard settings.broker.undoRoutingUpdate(discardingEdits: discardingEdits) else { return false }
        settings.broker.suppressedAutomaticRoutingUpdateFingerprint = fingerprint
        routingUpdateApplyTask = Task { await applyBrokerSettingsChange() }
        return true
    }

    func revisionRestoreError(selection: BrokerRevisionSelection) -> String? {
        guard settings.broker.presetManifest.sources.contains(where: {
            BrokerManifestHistoryNamespace(sourceID: $0.id, urlString: $0.urlString) == selection.namespace
        }), let state = presetManifestHistory[selection.namespace],
              case .loaded(let revisions) = state,
              revisions.contains(where: {
                  $0.contentDigest == selection.snapshot.contentDigest && $0 == selection.snapshot
              }) else { return "The saved revision or its source has changed. Reopen History" }
        guard let rules = selection.rules else { return "This revision does not contain the active profile" }
        return settings.broker.revisionRestoreError(id: selection.profileID, rules: rules)
    }

    @discardableResult
    func restoreProfileRules(selection: BrokerRevisionSelection, discardingEdits: Bool = false) -> Bool {
        let fingerprint = Self.routingUpdateFingerprint(
            activeProfileID: settings.broker.activeProfileID,
            activeRules: settings.broker.activeProfile?.rules
        )
        guard revisionRestoreError(selection: selection) == nil,
              discardingEdits || !settings.broker.hasUnsavedRuleChanges,
              let rules = selection.rules,
              settings.broker.restoreProfileRules(id: selection.profileID, rules: rules) else { return false }
        settings.broker.suppressedAutomaticRoutingUpdateFingerprint = fingerprint
        settings.broker.routingRecovery?.source = selection.namespace
        settings.broker.routingRecovery?.revisionFingerprint = selection.snapshot.contentDigest
        routingUpdateApplyTask = Task { await applyBrokerSettingsChange() }
        return true
    }

    /// The in-flight broker push from ``applyRoutingUpdate(profileID:)``,
    /// exposed so a test can await it instead of polling.
    @ObservationIgnored private(set) var routingUpdateApplyTask: Task<Void, Never>?

    private func sendRoutingUpdateNotificationIfNeeded(
        hadEverCheckedManifest: Bool
    ) async {
        let remoteIDs = Set(settings.broker.remotePresets.map(\.id))
        if settings.broker.seenRemotePresetIDs.isEmpty,
           !remoteIDs.isEmpty,
           !hadEverCheckedManifest {
            settings.broker.seenRemotePresetIDs = remoteIDs
            return
        }

        let newPresetIDs = remoteIDs.subtracting(settings.broker.seenRemotePresetIDs)
        // Keep only ids the manifests still publish. Ids are untrusted remote
        // input, and a source that rotates them would otherwise grow this set
        // without bound inside the settings blob.
        settings.broker.seenRemotePresetIDs = remoteIDs

        let activeID = settings.broker.activeProfileID
        let activeProfileCanBeUpdated = activeID.map {
            BrokerAgentProfile.builtIn(id: $0) != nil || settings.broker.isRemotePreset(id: $0)
        } ?? false
        let activeProfileUpdated = activeProfileCanBeUpdated
            && settings.broker.activeProfileHasUpdatedRules
        // New preset ids are deduped by the seen-set, so they stay out of the
        // fingerprint: otherwise a refresh that carried both an updated active
        // profile and new presets would notify again on the next refresh, when
        // the same update arrives with the new-preset list now empty.
        guard activeProfileUpdated || !newPresetIDs.isEmpty,
              let fingerprint = Self.routingUpdateFingerprint(
                activeProfileID: activeID,
                activeRules: settings.broker.activeProfile?.rules
              ),
              fingerprint != settings.broker.lastRoutingUpdateNotifiedFingerprint
                || !newPresetIDs.isEmpty,
              settings.broker.isEnabled,
              settings.broker.routingUpdateNotificationsEnabled,
              settings.hasNotificationsEnabled,
              await notificationService.checkNotificationPermissions() else {
            return
        }

        let notice = RoutingUpdateNotice(
            profileName: activeProfileUpdated ? settings.broker.activeProfile?.name : nil,
            newPresetCount: newPresetIDs.count,
            profileID: activeProfileUpdated ? activeID : nil,
            fingerprint: fingerprint
        )
        do {
            try await notificationService.sendRoutingUpdateNotification(notice)
            settings.broker.lastRoutingUpdateNotifiedFingerprint = fingerprint
        } catch {
            Self.logger.debug(
                "Routing update notification failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func routingUpdateFingerprint(
        activeProfileID: UUID?,
        activeRules: BrokerRuleSet?
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = RoutingUpdateFingerprintPayload(
            activeProfileID: activeProfileID?.uuidString.lowercased(),
            activeRules: activeRules
        )
        guard let data = try? encoder.encode(payload) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        settings.broker.presetManifest.sources[index].cachedAgentSetup = nil
        let source = settings.broker.presetManifest.sources[index]
        presetManifestHistory = presetManifestHistory.filter { $0.key.sourceID != source.id }
        let namespace = BrokerManifestHistoryNamespace(
            sourceID: source.id,
            urlString: source.urlString
        )
        presetManifestHistory[namespace] = .loading
        // Publish the clearing straight away. Leaving the old URL's presets in
        // `remotePresets` would satisfy the pre-migration attribution block in
        // `refreshPresetManifest` on the next run, which would copy them back
        // into this source and persist them under the NEW URL — the exact
        // cross-attribution the clearing above exists to prevent.
        mergePresetManifestSources()
        Task {
            await loadPresetManifestHistory(for: source, seedIfMissing: false)
            await brokerService.updateSetupRevision(settings.broker.effectiveAgentSetup?.revision)
        }
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
        presetManifestHistory = presetManifestHistory.filter { $0.key.sourceID != id }
        mergePresetManifestSources()
        Task {
            await brokerService.updateSetupRevision(settings.broker.effectiveAgentSetup?.revision)
        }
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

    private func migrateLegacyPresetManifestCacheIfNeeded() {
        // A pre-migration save has one aggregate cache but no per-source
        // cache. Attribute it once before history seeding, so a later bundled
        // fallback can never be mistaken for a successful fetch.
        guard let firstSourceIndex = settings.broker.presetManifest.sources.indices.first,
              settings.broker.presetManifest.sources.allSatisfy({ $0.cachedPresets.isEmpty }),
              !settings.broker.remotePresets.isEmpty else { return }
        settings.broker.presetManifest.sources[firstSourceIndex].cachedPresets =
            settings.broker.remotePresets
    }

    func manifestHistoryState(
        for source: BrokerPresetManifestSource
    ) -> BrokerManifestHistoryState {
        presetManifestHistory[
            BrokerManifestHistoryNamespace(sourceID: source.id, urlString: source.urlString)
        ] ?? .loading
    }

    private func loadPresetManifestHistoryIfNeeded() async {
        for source in settings.broker.presetManifest.sources {
            let namespace = BrokerManifestHistoryNamespace(
                sourceID: source.id,
                urlString: source.urlString
            )
            guard presetManifestHistory[namespace] == nil else { continue }
            presetManifestHistory[namespace] = .loading
            await loadPresetManifestHistory(for: source, seedIfMissing: true)
        }
    }

    private func loadPresetManifestHistory(
        for source: BrokerPresetManifestSource,
        seedIfMissing: Bool
    ) async {
        let namespace = BrokerManifestHistoryNamespace(
            sourceID: source.id,
            urlString: source.urlString
        )
        let state: BrokerManifestHistoryState
        if seedIfMissing {
            do {
                let revisions = try await presetManifestHistoryStore.seedIfNeeded(
                    sourceID: source.id,
                    urlString: source.urlString,
                    presets: source.cachedPresets,
                    agentSetup: source.cachedAgentSetup,
                    recordedAt: source.lastCheckedAt ?? Date()
                )
                state = .loaded(Array(revisions.reversed()))
            } catch {
                state = .readError
            }
        } else {
            switch await presetManifestHistoryStore.load(
                sourceID: source.id,
                urlString: source.urlString
            ) {
            case .loaded(let revisions):
                state = .loaded(Array(revisions.reversed()))
            case .readError:
                state = .readError
            }
        }

        guard settings.broker.presetManifest.sources.contains(where: {
            $0.id == source.id && $0.urlString == source.urlString
        }) else { return }
        presetManifestHistory[namespace] = state
    }

    /// First-run / offline seeding: when no successful fetch has ever landed
    /// and no presets are stored yet, load the copy bundled with the app so
    /// the "From manifest" section is not empty before the network answers.
    /// Goes through the identical validating decode a remote payload gets —
    /// a bundled file earns no more trust than a fetched one.
    private func seedBundledPresetManifestIfNeeded() async {
        guard settings.broker.remotePresets.isEmpty,
              let sourceIndex = settings.broker.presetManifest.sources.indices.first,
              settings.broker.presetManifest.sources.allSatisfy({ $0.lastCheckedAt == nil }),
              let url = Bundle.main.url(forResource: "broker-presets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? BrokerPresetManifest.decode(from: data)
        else { return }
        settings.broker.presetManifest.sources[sourceIndex].cachedPresets = manifest.presets
        settings.broker.presetManifest.sources[sourceIndex].cachedAgentSetup = manifest.agentSetup
        mergePresetManifestSources()
        await brokerService.updateSetupRevision(settings.broker.effectiveAgentSetup?.revision)
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
        // With a primary account, its own data/error keeps deciding the
        // aggregate state (unchanged rule). With no primary account at all --
        // the CLI-only shape, since reconciliation never creates a primary
        // account -- every connected (non-primary) account decides it
        // instead: freshest successful update, and an error only when every
        // account has one (CLI-08, RESEARCH Pitfall 3).
        let chatGPTLastUpdated: Date?
        let chatGPTHasError: Bool
        if settings.chatGPTAccounts.isEmpty || settings.chatGPTAccounts.contains(where: \.isPrimary) {
            chatGPTLastUpdated = chatGPTUsageData?.lastUpdated
            chatGPTHasError = chatGPTErrorMessage != nil
        } else {
            let nonPrimaryAccounts = settings.chatGPTAccounts
            chatGPTLastUpdated = nonPrimaryAccounts.compactMap { chatGPTAccountUsage[$0.id]?.lastUpdated }.max()
            chatGPTHasError = nonPrimaryAccounts.allSatisfy { chatGPTAccountErrors[$0.id] != nil }
        }
        let chatGPT = ChatGPTQuotaSnapshot(
            label: chatGPTDisplayLabel,
            state: Self.aggregateQuotaState(generatedAt: generatedAt, lastUpdated: chatGPTLastUpdated, hasError: chatGPTHasError),
            lastUpdated: chatGPTLastUpdated,
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

        let snapshot = Self.makeOracleSnapshot(
            generatedAt: generatedAt,
            rows: rows,
            chatGPTConfigured: hasChatGPTSessionCookie || hasCLIChatGPTSource
        )
        // Retained so the degraded-pick modal can name a cause from the very
        // reading the broker judged the pick with. Deriving it from anything
        // else lets the title contradict the reason printed beneath it.
        lastOracleSnapshot = snapshot
        await brokerService.updateOracleSnapshot(snapshot)
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
        if state.identity.kind == .accessToken {
            switch state.health {
            case .valid, .refreshRecommended:
                kinds = []
            case .unknown, .missing, .validating, .invalid, .expired, .unavailable:
                kinds = [.reconnect]
            }
        } else if state.identity.kind == .apiKey {
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
        let snapshot = settings
        pendingSettingsPush = pendingSettingsPush
            || Self.remotePushPayloadChanged(from: previous, to: snapshot)
        settingsSaveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await settingsRepository.save(snapshot)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await schedulePendingSettingsPushIfNeeded()
        }

        if previous.refreshInterval != settings.refreshInterval {
            startRefreshLoop()
        }
    }

    static func remotePushPayloadChanged(from previous: AppSettings, to current: AppSettings) -> Bool {
        previous.broker.policy != current.broker.policy
            || previous.claudeAccounts != current.claudeAccounts
            || previous.chatGPTAccounts != current.chatGPTAccounts
            || previous.geminiAccounts != current.geminiAccounts
            || previous.cachedOrganizationId != current.cachedOrganizationId
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
        await remotePushCoordinator?.retryPending()
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
        guard isSetupComplete
            || hasChatGPTSessionCookie
            || hasGeminiAPIKey
            || settings.broker.isEnabled
            || hasCLIClaudeAccount
            || settings.chatGPTAccounts.contains(where: \.isCLIOrigin)
        else { return }

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
        await remotePushCoordinator?.retryPending()
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
