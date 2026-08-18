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

// MARK: - Broker seams (07-04)

/// The lifecycle and intake seams AppModel needs from the broker beyond the
/// MCP tool surface (`BrokerServiceProtocol`). Kept separate from that
/// protocol because the MCP layer (`BrokerMCPServer`) only ever sees the
/// tool surface; only AppModel pushes policy/oracle/liveness/server-state
/// and observes the UI stream, so those seams live on this composed
/// protocol instead. `BrokerService`'s actor-isolated methods satisfy the
/// `async` requirements here without any extra wrapping.
protocol BrokerLifecycleProtocol: BrokerServiceProtocol {
    func updatePolicy(_ policy: BrokerPolicy) async
    func updateOracleSnapshot(_ oracle: OracleSnapshot?) async
    func updateT3Liveness(_ liveness: [String: T3Liveness]) async
    func refreshT3Liveness() async -> [String: T3Liveness]
    func t3LivenessSnapshot() async -> [String: T3Liveness]
    func updateServerState(_ state: BrokerUIState.ServerState) async
    func setRefreshHandler(_ handler: @escaping @Sendable () async throws -> Void) async
    func uiStateUpdates() async -> AsyncStream<BrokerUIState>
    /// The recent-picks ring buffer (07-05's Broker settings tab debugging
    /// surface, D-09). Defaulted to `[]` below so existing fakes don't need
    /// updating; `BrokerService` overrides it to forward its own snapshot.
    func recentPicks() async -> [RecentPick]
    /// The last instruction check an agent ran through the `audit` tool, for
    /// the Instructions tab. `nil` until one has run on this machine.
    func latestInstructionCheck() async -> InstructionCheck?
}

extension BrokerLifecycleProtocol {
    func recentPicks() async -> [RecentPick] { [] }
    func latestInstructionCheck() async -> InstructionCheck? { nil }
    func refreshT3Liveness() async -> [String: T3Liveness] { [:] }
    func t3LivenessSnapshot() async -> [String: T3Liveness] { [:] }
}

extension BrokerService: BrokerLifecycleProtocol {
    func recentPicks() async -> [RecentPick] { recentPicksSnapshot }
}

/// Minimal lifecycle seam for the loopback listener, so AppModel's tests can
/// inject a fake without binding a real socket. `LoopbackHTTPServer` already
/// has this exact shape (07-01/07-03); this just names it as a protocol.
protocol BrokerLoopbackServerProtocol: Sendable {
    @discardableResult
    func start() async throws -> UInt16
    func stop() async
}

extension LoopbackHTTPServer: BrokerLoopbackServerProtocol {}

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
    var chatGPTUsageData: ChatGPTUsageData?
    var geminiUsageData: GeminiUsageData?
    var isLoading: Bool = false
    var isRefreshing: Bool = false
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

    /// Ordered quota bars for the menu bar icon: one mini bar per usage bar
    /// shown in the popover, in the same order (each Claude account's 5h,
    /// weekly, and optional Fable bar; then ChatGPT rows; then Gemini), so
    /// the popover doubles as the legend for the menu bar meters.
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

        if settings.isChatGPTUsageShown, let chatGPTUsageData {
            for row in chatGPTUsageData.displayRows {
                bars.append(MenuBarQuotaBar(
                    label: row.menuBarRole?.menuBarLabel ?? "ChatGPT \(row.label)",
                    percentage: clampedBarPercentage(row.usedPercent),
                    status: row.status,
                    detail: resetAnnouncement(for: row.resetAt),
                    heading: row.menuBarRole?.columnHeading ?? row.label,
                    owner: chatGPTDisplayLabel,
                    renameTarget: .provider(.chatGPT),
                    colorScheme: settings.menuBarColorScheme
                ))
            }
        }

        if isGeminiUsageConfigured, let geminiUsageData {
            bars.append(MenuBarQuotaBar(
                label: "Gemini",
                percentage: clampedBarPercentage(geminiUsageData.percentage),
                status: geminiUsageData.status,
                detail: resetAnnouncement(for: geminiUsageData.resetAt),
                heading: "API",
                owner: geminiDisplayLabel,
                renameTarget: .provider(.gemini),
                colorScheme: settings.menuBarColorScheme
            ))
        }

        return bars
    }

    private func resetAnnouncement(for resetAt: Date?) -> String? {
        resetAt.map { settings.subscriptionResetAnnouncementMode.resetAnnouncement(for: $0) }
    }

    /// Display name for the ChatGPT account: the user's custom label when set,
    /// otherwise "ChatGPT".
    var chatGPTDisplayLabel: String {
        let trimmed = settings.chatGPTCustomLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "ChatGPT" : trimmed
    }

    /// Display name for the Gemini account: the user's custom label when set,
    /// otherwise "Gemini".
    var geminiDisplayLabel: String {
        let trimmed = settings.geminiCustomLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Gemini" : trimmed
    }

    /// Sets the ChatGPT display label; a blank label reverts to "ChatGPT".
    func renameChatGPTAccount(customLabel: String) {
        let isBlank = customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        settings.chatGPTCustomLabel = isBlank ? nil : customLabel
    }

    /// Sets the Gemini display label; a blank label reverts to "Gemini".
    func renameGeminiAccount(customLabel: String) {
        let isBlank = customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        settings.geminiCustomLabel = isBlank ? nil : customLabel
    }

    /// Current custom label backing a popover owner rename (empty when unset).
    func customLabel(for target: QuotaRenameTarget) -> String {
        switch target {
        case .claudeAccount(let id):
            return settings.claudeAccounts.first { $0.id == id }?.customLabel ?? ""
        case .provider(.chatGPT):
            return settings.chatGPTCustomLabel ?? ""
        case .provider(.gemini):
            return settings.geminiCustomLabel ?? ""
        case .provider(.claude):
            return ""
        }
    }

    /// Commits a popover owner rename to the right backing store.
    func renameUsageOwner(_ target: QuotaRenameTarget, customLabel: String) {
        switch target {
        case .claudeAccount(let id):
            renameClaudeAccount(id: id, customLabel: customLabel)
        case .provider(.chatGPT):
            renameChatGPTAccount(customLabel: customLabel)
        case .provider(.gemini):
            renameGeminiAccount(customLabel: customLabel)
        case .provider(.claude):
            break
        }
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
    @ObservationIgnored private let geminiUsageService: GeminiUsageServiceProtocol
    @ObservationIgnored private let geminiAPIKeyRepository: any GeminiAPIKeyRepositoryProtocol
    @ObservationIgnored private let notificationService: NotificationServiceProtocol
    @ObservationIgnored private let sessionKeyImportService: SessionKeyImportServiceProtocol
    @ObservationIgnored private let releaseCheckService: (any ReleaseCheckServiceProtocol)?
    @ObservationIgnored private let appUpdater: AppUpdaterProtocol?
    @ObservationIgnored private let installedVersion: String
    @ObservationIgnored private let brokerService: any BrokerLifecycleProtocol
    @ObservationIgnored private let brokerServerFactory: @Sendable (
        _ broker: any BrokerServiceProtocol, _ port: UInt16
    ) -> any BrokerLoopbackServerProtocol
    @ObservationIgnored private let t3InstanceDiscovery: any T3InstanceDiscoveryProtocol
    @ObservationIgnored private let t3UsageService: any T3UsageServiceProtocol

    // MARK: - Private

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var updateCheckTask: Task<Void, Never>?
    @ObservationIgnored private var brokerUIStateTask: Task<Void, Never>?
    @ObservationIgnored private var isCheckingForUpdates = false
    @ObservationIgnored private var hasLoadedSettings: Bool = false
    @ObservationIgnored private let refreshClock = ContinuousClock()
    @ObservationIgnored private var brokerLoopbackServer: (any BrokerLoopbackServerProtocol)?
    @ObservationIgnored private var brokerBoundPort: UInt16?
    /// Reentrancy guard for the broker lifecycle (review WR-01): bumped at
    /// the top of every `applyBrokerSettingsChange()` call. A completion
    /// whose captured generation no longer matches the current one has been
    /// superseded by a later settings change and no-ops instead of
    /// clobbering (or leaking a socket past) the newer call's state.
    @ObservationIgnored private var brokerLifecycleGeneration = 0

    // MARK: - Initialization

    init(
        settingsRepository: SettingsRepositoryProtocol = SettingsRepository(),
        keychainRepository: KeychainRepositoryProtocol = KeychainRepository(),
        cacheRepository: CacheRepository? = nil,
        usageService: UsageServiceProtocol? = nil,
        chatGPTUsageService: ChatGPTUsageServiceProtocol? = nil,
        chatGPTSessionRepository: (any ChatGPTSessionRepositoryProtocol)? = nil,
        geminiUsageService: GeminiUsageServiceProtocol? = nil,
        geminiAPIKeyRepository: (any GeminiAPIKeyRepositoryProtocol)? = nil,
        notificationService: NotificationServiceProtocol? = nil,
        sessionKeyImportService: SessionKeyImportServiceProtocol? = nil,
        releaseCheckService: (any ReleaseCheckServiceProtocol)? = nil,
        appUpdater: AppUpdaterProtocol? = nil,
        installedVersion: String? = nil,
        brokerService: (any BrokerLifecycleProtocol)? = nil,
        brokerServerFactory: (@Sendable (
            _ broker: any BrokerServiceProtocol, _ port: UInt16
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
        self.chatGPTUsageService = chatGPTUsageService ?? ChatGPTUsageService(sessionRepository: chatGPTSessionRepository)
        self.geminiUsageService = geminiUsageService ?? GeminiUsageService(apiKeyRepository: geminiAPIKeyRepository)
        self.notificationService = notificationService ?? NotificationService(
            settingsRepository: settingsRepository
        )
        self.releaseCheckService = releaseCheckService
        self.appUpdater = appUpdater
        self.installedVersion = installedVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
        self.brokerService = brokerService
            ?? BrokerService(livenessChecker: t3LivenessChecker ?? T3LivenessChecker())
        self.brokerServerFactory = brokerServerFactory ?? { broker, port in
            BrokerMCPServer.makeLoopbackServer(broker: broker, port: port)
        }
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

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !isReady else { return }
        settings = await settingsRepository.load()
        if let availableVersion = settings.availableUpdateVersion,
           !AvailableUpdate(version: availableVersion).isNewer(than: installedVersion) {
            settings.availableUpdateVersion = nil
        }
        hasLoadedSettings = true

        isSetupComplete = await keychainRepository.exists(account: "default")
        claudeCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: isSetupComplete ? .valid : .missing,
            failureCategory: isSetupComplete ? nil : .missing,
            checkedAt: Date()
        )
        let chatGPTStatus = await chatGPTSessionRepository.validate(account: ChatGPTUsageService.defaultSessionAccount)
        hasChatGPTSessionCookie = chatGPTStatus.state == .available
        chatGPTCredentialState = Self.credentialState(from: chatGPTStatus, checkedAt: Date())
        let geminiStatus = await geminiAPIKeyRepository.validate(account: GeminiUsageService.defaultAPIKeyAccount)
        hasGeminiAPIKey = geminiStatus.state == .available
        geminiCredentialState = Self.credentialState(from: geminiStatus, checkedAt: Date())
        isReady = true

        await brokerService.setRefreshHandler { [weak self] in
            await self?.refreshConfiguredUsageProviders(forceRefresh: true)
        }
        _ = await reconcileDiscoveredT3Instances()
        await applyBrokerSettingsChange()
        startBrokerUIStateObserver()

        await refreshConfiguredUsageProviders(forceRefresh: true)

        startWakeObserver()
        startUpdateCheckLoop()
    }

    // MARK: - Broker lifecycle (07-04)

    /// Reconciles broker settings during bootstrap and after Broker settings
    /// tab changes: pushes the new policy, then stops/starts/restarts the server as
    /// needed so the running server always matches `settings.broker`.
    func applyBrokerSettingsChange() async {
        brokerLifecycleGeneration += 1
        let generation = brokerLifecycleGeneration

        await brokerService.updatePolicy(settings.broker.policy)
        guard generation == brokerLifecycleGeneration else { return }

        guard settings.broker.isEnabled else {
            await stopBrokerServer(generation: generation)
            guard generation == brokerLifecycleGeneration else { return }
            startRefreshLoop()
            return
        }

        let desiredPort = UInt16(clamping: settings.broker.port)
        if brokerLoopbackServer == nil {
            await brokerService.updateT3Liveness([:])
            _ = await brokerService.refreshT3Liveness()
            guard generation == brokerLifecycleGeneration else { return }
            await startBrokerServer(port: desiredPort, generation: generation)
            guard generation == brokerLifecycleGeneration else { return }
            startRefreshLoop()
            return
        }

        if brokerBoundPort != desiredPort {
            await stopBrokerServer(generation: generation)
            guard generation == brokerLifecycleGeneration else { return }
            await startBrokerServer(port: desiredPort, generation: generation)
        }
        // Policy-only change: already pushed above, no restart needed.
        guard generation == brokerLifecycleGeneration else { return }
        startRefreshLoop()
    }

    /// Starts the loopback MCP server on `port`. A bind failure (most
    /// commonly `EADDRINUSE`) surfaces as a visible `BrokerUIState.serverState
    /// .failed` instead of a silent crash or hang (orchestrator handoff:
    /// `LoopbackHTTPServerError.addressInUse` previously had no call site).
    ///
    /// `generation` is the caller's `brokerLifecycleGeneration` snapshot
    /// (WR-01): if a later `applyBrokerSettingsChange()` call has already
    /// bumped the counter by the time the listener finishes binding, this
    /// call has been superseded — stop the now-orphaned listener instead of
    /// publishing stale state over whatever the newer call already set up.
    private func startBrokerServer(port: UInt16, generation: Int) async {
        let server = brokerServerFactory(brokerService, port)
        brokerLoopbackServer = server
        brokerBoundPort = nil
        await brokerService.updateServerState(.starting)
        guard generation == brokerLifecycleGeneration else { return }
        do {
            let boundPort = try await server.start()
            guard generation == brokerLifecycleGeneration else {
                await server.stop()
                return
            }
            brokerBoundPort = boundPort
            await brokerService.updateServerState(.running(port: boundPort))
        } catch {
            guard generation == brokerLifecycleGeneration else { return }
            brokerLoopbackServer = nil
            brokerBoundPort = nil
            if let loopbackError = error as? LoopbackHTTPServerError,
               case .addressInUse(let usedPort) = loopbackError {
                await brokerService.updateServerState(
                    .failed(message: "Port \(usedPort) is already in use.")
                )
            } else {
                await brokerService.updateServerState(
                    .failed(message: error.localizedDescription)
                )
            }
        }
    }

    /// Stops the running broker server. `generation`, when supplied, is the
    /// caller's `brokerLifecycleGeneration` snapshot (WR-01): if a later
    /// settings change has already superseded this call by the time `stop()`
    /// returns, skip clearing state that the newer call now owns.
    private func stopBrokerServer(generation: Int? = nil) async {
        if let server = brokerLoopbackServer {
            await server.stop()
        }
        if let generation, generation != brokerLifecycleGeneration { return }
        brokerLoopbackServer = nil
        brokerBoundPort = nil
        await brokerService.updateServerState(.stopped)
    }

    /// The broker's recent-picks ring buffer, newest-first (D-09 debugging
    /// surface for 07-05's Broker settings tab).
    func brokerRecentPicks() async -> [RecentPick] {
        await brokerService.recentPicks()
    }

    func brokerLatestInstructionCheck() async -> InstructionCheck? {
        await brokerService.latestInstructionCheck()
    }

    /// Mirrors the broker's `BrokerUIState` stream into `brokerUIState`.
    /// Captures `brokerService` itself (not `self`) so the subscription
    /// doesn't need `self` to keep running, and re-checks `self` weakly on
    /// every element rather than promoting it to a strong reference for the
    /// whole stream's lifetime, since this stream is long-lived and would
    /// otherwise pin this object in memory indefinitely.
    private func startBrokerUIStateObserver() {
        brokerUIStateTask?.cancel()
        let brokerService = self.brokerService
        brokerUIStateTask = Task { [weak self] in
            for await state in await brokerService.uiStateUpdates() {
                guard let self else { return }
                self.brokerUIState = state
            }
        }
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
        if isGeminiUsageConfigured {
            await refreshGeminiUsage()
        }
        let generatedAt = Date()
        let liveness = await brokerService.t3LivenessSnapshot()
        _ = await t3UsageService.refresh(
            instanceAvailability: t3UsageInstanceAvailability(from: liveness),
            request: .trailingWeek(endingAt: generatedAt),
            quota: usageTelemetryQuotaSnapshot(generatedAt: generatedAt)
        )
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
            await notificationService.evaluateThresholds(
                usageData: data,
                settings: settings
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        await exportAggregateUsageSnapshot()
    }

    /// Refresh usage for every connected additional (non-primary) Claude
    /// account. The primary account is refreshed separately by `refreshUsage`.
    func refreshAdditionalClaudeAccounts(forceRefresh: Bool = false) async {
        let additionalAccounts = settings.claudeAccounts.filter { !$0.isPrimary }
        guard !additionalAccounts.isEmpty else {
            if !claudeAccountUsage.isEmpty { claudeAccountUsage.removeAll() }
            if !claudeAccountErrors.isEmpty { claudeAccountErrors.removeAll() }
            await exportAggregateUsageSnapshot()
            return
        }

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

    func refreshChatGPTUsage() async {
        if !hasChatGPTSessionCookie {
            let status = await chatGPTSessionRepository.validate(account: ChatGPTUsageService.defaultSessionAccount)
            hasChatGPTSessionCookie = status.state == .available
            chatGPTCredentialState = Self.credentialState(from: status, checkedAt: Date())
        }
        guard hasChatGPTSessionCookie else {
            chatGPTUsageData = nil
            await exportAggregateUsageSnapshot()
            return
        }
        guard !isRefreshingChatGPT else { return }

        isRefreshingChatGPT = true
        chatGPTErrorMessage = nil

        defer {
            isRefreshingChatGPT = false
        }

        do {
            chatGPTUsageData = try await chatGPTUsageService.fetchUsage()
            hasChatGPTSessionCookie = true
            chatGPTCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
                health: .valid,
                checkedAt: Date()
            )
        } catch ChatGPTUsageError.missingSessionCookie {
            hasChatGPTSessionCookie = false
            chatGPTUsageData = nil
            chatGPTErrorMessage = ChatGPTUsageError.missingSessionCookie.localizedDescription
            chatGPTCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
                health: .missing,
                failureCategory: .missing,
                checkedAt: Date()
            )
        } catch ChatGPTUsageError.invalidSessionCookie {
            hasChatGPTSessionCookie = false
            chatGPTUsageData = nil
            chatGPTErrorMessage = ChatGPTUsageError.invalidSessionCookie.localizedDescription
            chatGPTCredentialState = CredentialState(
                identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
                health: .invalid,
                failureCategory: .providerRejected,
                checkedAt: Date()
            )
        } catch {
            chatGPTUsageData = nil
            chatGPTErrorMessage = error.localizedDescription
        }
        await exportAggregateUsageSnapshot()
    }

    func loadChatGPTSessionCookie() async -> String? {
        do {
            return try await chatGPTSessionRepository.load(account: ChatGPTUsageService.defaultSessionAccount).sessionCookie
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
            account: ChatGPTUsageService.defaultSessionAccount
        )
        hasChatGPTSessionCookie = true
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
        try await chatGPTSessionRepository.clear(account: ChatGPTUsageService.defaultSessionAccount)
        hasChatGPTSessionCookie = false
        settings.isChatGPTUsageShown = false
        chatGPTUsageData = nil
        chatGPTErrorMessage = nil
        chatGPTCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
            health: .missing,
            failureCategory: .missing,
            checkedAt: Date()
        )
        await exportAggregateUsageSnapshot()
    }

    func excludeChatGPTAccountFromScans() async throws {
        let excluded = ScanExcludedAccount.chatGPT(displayLabel: chatGPTDisplayLabel)
        try await clearChatGPTSessionCookie()
        upsertScanExclusion(excluded)
    }

    // MARK: - Gemini Usage

    func refreshGeminiUsage() async {
        if !hasGeminiAPIKey {
            let status = await geminiAPIKeyRepository.validate(account: GeminiUsageService.defaultAPIKeyAccount)
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
        do {
            return try await geminiAPIKeyRepository.load(account: GeminiUsageService.defaultAPIKeyAccount).value
        } catch {
            return nil
        }
    }

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

        try await geminiAPIKeyRepository.save(apiKey, account: GeminiUsageService.defaultAPIKeyAccount)
        hasGeminiAPIKey = true
        geminiCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .gemini, kind: .apiKey),
            health: .valid,
            checkedAt: Date()
        )
        await refreshGeminiUsage()
        startRefreshLoop()
        return true
    }

    func clearGeminiAPIKey() async throws {
        try await geminiAPIKeyRepository.clear(account: GeminiUsageService.defaultAPIKeyAccount)
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
        struct Candidate: Sendable {
            let index: Int
            let value: String
            let organization: Organization
            let sourceDescription: String
        }

        let total = importedKeys.count
        importProgress = "Validating \(total) session\(total == 1 ? "" : "s")\u{2026}"

        Self.logger.info("Connecting Claude accounts from \(importedKeys.count) imported key(s): \(importedKeys.map(\.sourceDescription).joined(separator: ", "), privacy: .public)")

        let validated: [Candidate] = await withTaskGroup(of: Candidate?.self) { group in
            for (index, imported) in importedKeys.enumerated() {
                group.addTask { [usageService] in
                    guard let sessionKey = try? SessionKey(imported.value) else {
                        Self.logger.warning("Key \(index) (\(imported.sourceDescription, privacy: .public)): malformed session key")
                        return nil
                    }
                    let organizations: [Organization]
                    do {
                        organizations = try await usageService.fetchOrganizations(sessionKey: sessionKey)
                    } catch {
                        Self.logger.warning("Key \(index) (\(imported.sourceDescription, privacy: .public)): fetchOrganizations failed: \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                    guard let organization = organizations.first(where: { $0.hasChatCapability }) ?? organizations.first,
                          organization.organizationUUID != nil else {
                        Self.logger.warning("Key \(index) (\(imported.sourceDescription, privacy: .public)): no usable organization in response")
                        return nil
                    }
                    Self.logger.info("Key \(index) (\(imported.sourceDescription, privacy: .public)): validated as org \(organization.uuid, privacy: .public) \(organization.name, privacy: .public)")
                    return Candidate(
                        index: index,
                        value: sessionKey.value,
                        organization: organization,
                        sourceDescription: imported.sourceDescription
                    )
                }
            }

            var results: [Candidate] = []
            var checked = 0
            for await result in group {
                checked += 1
                if let candidate = result {
                    results.append(candidate)
                }
                importProgress = "Checked \(checked) of \(total) sessions\u{2026}"
            }
            return results.sorted { $0.index < $1.index }
        }

        var candidates: [Candidate] = []
        var seenOrganizations = Set<String>()
        let excludedOrganizationIds = Set(
            settings.scanExcludedAccounts
                .filter { $0.provider == .claude }
                .map(\.accountId)
        )
        var excludedCandidateCount = 0
        for candidate in validated {
            if excludedOrganizationIds.contains(candidate.organization.uuid) {
                excludedCandidateCount += 1
                Self.logger.info("Skipping scan-excluded Claude organization \(candidate.organization.uuid, privacy: .public)")
            } else if seenOrganizations.insert(candidate.organization.uuid).inserted {
                candidates.append(candidate)
            } else {
                Self.logger.info("Key \(candidate.index) (\(candidate.sourceDescription, privacy: .public)): duplicate of already-connected org \(candidate.organization.uuid, privacy: .public), skipping")
            }
        }

        guard !candidates.isEmpty else {
            importProgress = nil
            throw excludedCandidateCount > 0
                ? SessionKeyImportError.allDiscoveredAccountsExcluded
                : SessionKeyImportError.invalidImportedSessionKey
        }

        importProgress = "Saving \(candidates.count) account\(candidates.count == 1 ? "" : "s")\u{2026}"

        // Keep the existing primary organization primary when it is still
        // present; otherwise promote the first discovered account.
        let existingPrimaryOrganizationId = settings.claudeAccounts.first(where: { $0.isPrimary })?.organizationId
        let primaryIndex = candidates.firstIndex(where: {
            $0.organization.organizationUUID == existingPrimaryOrganizationId
        }) ?? 0
        let primaryCandidate = candidates[primaryIndex]
        let additionalCandidates = candidates.enumerated()
            .filter { $0.offset != primaryIndex }
            .map { $0.element }

        // Carry user-chosen labels over to the rebuilt account list so a
        // re-import doesn't discard renames. Captured before the primary save
        // path mutates `settings.claudeAccounts`.
        let customLabelsByAccountId = Dictionary(
            settings.claudeAccounts.compactMap { account in
                account.customLabel.map { (account.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Save the primary through the tested single-account path (Keychain
        // "default", cached org id, setup flag, primary usage refresh).
        let primaryValid = try await validateAndSaveSessionKey(primaryCandidate.value)
        guard primaryValid else {
            throw SessionKeyImportError.invalidImportedSessionKey
        }

        var accounts: [ClaudeAccount] = [
            ClaudeAccount(
                id: primaryCandidate.organization.uuid,
                label: primaryCandidate.organization.name,
                organizationId: primaryCandidate.organization.organizationUUID!,
                keychainAccount: ClaudeAccount.primaryKeychainAccount,
                profileLabel: primaryCandidate.sourceDescription,
                customLabel: customLabelsByAccountId[primaryCandidate.organization.uuid]
            )
        ]

        // Remove Keychain entries for previously-connected additional accounts
        // that are no longer present so a re-import leaves no orphaned keys.
        var staleAccountIds = Set(settings.claudeAccounts.filter { !$0.isPrimary }.map { $0.id })

        for candidate in additionalCandidates {
            let organizationUUID = candidate.organization.organizationUUID!
            try await keychainRepository.save(
                sessionKey: candidate.value,
                account: candidate.organization.uuid
            )
            accounts.append(ClaudeAccount(
                id: candidate.organization.uuid,
                label: candidate.organization.name,
                organizationId: organizationUUID,
                keychainAccount: candidate.organization.uuid,
                profileLabel: candidate.sourceDescription,
                customLabel: customLabelsByAccountId[candidate.organization.uuid]
            ))
            staleAccountIds.remove(candidate.organization.uuid)
        }

        for staleId in staleAccountIds {
            try? await keychainRepository.delete(account: staleId)
            claudeAccountUsage[staleId] = nil
            claudeAccountErrors[staleId] = nil
        }

        settings.claudeAccounts = accounts
        importProgress = nil
        await refreshAdditionalClaudeAccounts(forceRefresh: true)

        return ClaudeAccountsImportResult(
            primary: ImportedSessionKey(
                value: primaryCandidate.value,
                sourceDescription: primaryCandidate.sourceDescription
            ),
            importedCount: accounts.count,
            accountLabels: accounts.map(\.displayLabel),
            connected: ([primaryCandidate] + additionalCandidates).map {
                ImportedSessionKey(value: $0.value, sourceDescription: $0.sourceDescription)
            }
        )
    }

    func importAndSaveChatGPTSessionCookie() async throws -> ImportedChatGPTSessionCookie {
        try await importAndSaveChatGPTSessionCookie(from: .defaultBrowser)
    }

    func importAndSaveChatGPTSessionCookie(from source: BrowserImportSource) async throws -> ImportedChatGPTSessionCookie {
        guard !isScanExcluded(
            provider: .chatGPT,
            accountId: ChatGPTUsageService.defaultSessionAccount
        ) else {
            throw SessionKeyImportError.allDiscoveredAccountsExcluded
        }

        let imported = try await sessionKeyImportService.importChatGPTSessionCookie(from: source)
        let normalizedCookie = ChatGPTUsageService.cookieHeader(from: imported.cookieHeader)

        guard !normalizedCookie.isEmpty else {
            throw SessionKeyImportError.invalidImportedChatGPTSessionCookie
        }

        try await chatGPTSessionRepository.save(
            ChatGPTSession(sessionCookie: normalizedCookie),
            account: ChatGPTUsageService.defaultSessionAccount
        )
        hasChatGPTSessionCookie = true
        chatGPTCredentialState = CredentialState(
            identity: CredentialIdentity(provider: .chatGPT, kind: .sessionCookie),
            health: .valid,
            checkedAt: Date()
        )
        settings.isChatGPTUsageShown = true
        await refreshChatGPTUsage()

        return ImportedChatGPTSessionCookie(
            cookieHeader: normalizedCookie,
            sourceDescription: imported.sourceDescription
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
        let running = BrowserImportSource.runningBrowsers()
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

            importProgress = "Importing ChatGPT session (\(browser.displayName))\u{2026}"
            let chatGPTStatus: ProviderBrowserImportStatus
            do {
                let imported = try await importAndSaveChatGPTSessionCookie(from: browser)
                chatGPTStatus = .imported(sourceDescription: imported.sourceDescription)
            } catch let error as SessionKeyImportError {
                chatGPTStatus = .failed(
                    message: error.localizedDescription,
                    offersFullDiskAccessSettings: error.offersFullDiskAccessSettings
                )
            } catch {
                chatGPTStatus = .failed(message: error.localizedDescription, offersFullDiskAccessSettings: false)
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

        return repairedState
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

    private func isScanExcluded(provider: CredentialProvider, accountId: String) -> Bool {
        settings.scanExcludedAccounts.contains {
            $0.provider == provider && $0.accountId == accountId
        }
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
            rows: chatGPTUsageData?.rows.map {
                .init(label: $0.label, role: $0.menuBarRole, utilization: $0.usedPercent, resetAt: $0.resetAt)
            } ?? []
        )
        return UsageTelemetryQuotaSnapshot(claudeAccounts: claude, chatGPT: chatGPT)
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

        let chatGPTRows = chatGPTUsageData?.rows.map {
            ChatGPTQuotaRowSnapshot(label: $0.label, usedPercent: $0.usedPercent, resetAt: $0.resetAt)
        } ?? []
        let chatGPT = ChatGPTQuotaSnapshot(
            label: chatGPTDisplayLabel,
            state: Self.aggregateQuotaState(generatedAt: generatedAt, lastUpdated: chatGPTUsageData?.lastUpdated, hasError: chatGPTErrorMessage != nil),
            lastUpdated: chatGPTUsageData?.lastUpdated,
            rows: chatGPTRows
        )
        let oracleChatGPTRows = Array((chatGPTUsageData?.rows ?? []).prefix(OracleSnapshot.maxChatGPTRows)).map {
            OracleSnapshot.ChatGPTRow(
                label: $0.label,
                usedPercent: $0.usedPercent,
                resetAt: $0.resetAt,
                windowRole: $0.menuBarRole
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
    private func exportAggregateUsageSnapshot(generatedAt: Date = Date()) async {
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
            // Credential presence, not data presence: the broker uses this to
            // tell "no ChatGPT on this machine" apart from "not polled yet",
            // and `chatGPTUsageData` starts nil on every launch.
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
