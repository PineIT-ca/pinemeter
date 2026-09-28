import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    static let selectedTabDefaultsKey = "settingsSelectedTab"

    static func selectTab(_ tab: Tab) {
        TestSafeDefaults.standardOrIsolated.set(tab.rawValue, forKey: selectedTabDefaultsKey)
    }

    @Bindable var appModel: AppModel

    @State private var offersFullDiskAccessSettings: Bool = false
    @State private var isImportingProviderSessions: Bool = false
    @State private var activeCredentialActionProvider: CredentialProvider?
    @State private var activeCredentialActionKind: ProviderCredentialActionKind?
    @State private var accountsFeedback: (message: String, isSuccess: Bool)?
    @State private var browserImportReview: BrowserSessionImportReview?
    @State private var pendingRemoval: AccountRemoval?
    @State private var pendingScanExclusion: ScanExclusion?
    @State private var isRemovingAccount: Bool = false
    @State private var isSavingGemini: Bool = false
    // Gemini is the one provider connected by manual entry: a Google AI Studio
    // API key has no browser cookie to scan, so paste is the only mechanism.
    @State private var geminiAPIKeyDraft: String = ""

    @State private var loginSettingFailed = false
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    /// The account whose name field has keyboard focus. Set by a card's
    /// pencil button and its Rename menu item, so renaming has a visible
    /// entry point instead of an unmarked text field.
    @FocusState private var focusedAccountNameField: String?

    /// The open pane, remembered across launches per the HIG's "restore the
    /// most recently viewed pane".
    // `store:` rather than the implicit `.standard`, defensively: no test
    // renders this view today, but one that did would rewrite the developer's
    // real selected tab, the way `BrokerWindowView`'s pane persistence did
    // before it was routed through the same guard (see `TestSafeDefaults`).
    @AppStorage("settingsSelectedTab", store: TestSafeDefaults.standardOrIsolated)
    private var selectedTab: Tab = .general

    enum Tab: String {
        case general
        case accounts
        case notifications
        case broker
        case about

        /// Doubles as the window title, which the HIG asks to track the
        /// visible pane.
        var title: String {
            switch self {
            case .general: return "General"
            case .accounts: return "Accounts"
            case .notifications: return "Notifications"
            case .broker: return "Broker"
            case .about: return "About"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            accountsTab
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(Tab.accounts)
            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(Tab.notifications)
            BrokerSummaryTab(appModel: appModel)
                .tabItem { Label("Broker", systemImage: "arrow.triangle.branch") }
                .tag(Tab.broker)
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .navigationTitle(selectedTab.title)
        // One fixed width; each tab decides its own height and the window
        // scene (`.windowResizability(.contentSize)`) fits it, so switching
        // tabs resizes the window the way System Settings does. The
        // `fixedSize` matters: without it the tab view accepts any height,
        // the scene only enforces a minimum, and the window never shrinks
        // back when a shorter tab is selected.
        .frame(width: SettingsLayout.windowWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: appModel.settings.hasNotificationsEnabled) { _, newValue in
            // Alerts render as overlays regardless of permission; still ask so
            // the bonus system banner can be delivered where it's granted.
            if newValue {
                Task { await appModel.requestNotificationPermissionIfNeeded() }
            }
        }
        .onChange(of: launchAtLogin) { _, newValue in
            updateLaunchAtLogin(newValue)
        }
        .alert("Couldn’t change Start at Login", isPresented: $loginSettingFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check Pinemeter in System Settings > General > Login Items, then try again.")
        }
        .sheet(item: $browserImportReview) { review in
            BrowserSessionImportReviewView(
                appModel: appModel,
                review: review,
                onConnected: { outcome in
                    applyBrowserScanOutcome(outcome)
                    browserImportReview = nil
                },
                onCancel: { browserImportReview = nil }
            )
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !appModel.isReady {
                ProgressView("Loading settings...")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                menuBarAndPopoverSection
                refreshSection
                systemSection
            }
        }
        .settingsPane()
    }

    private var accountsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if appModel.isReady {
                accountsSection
            } else {
                ProgressView("Loading accounts…")
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .settingsPane()
    }

    // MARK: - Accounts Section

    private enum AccountRemoval: Identifiable {
        case claude(id: String, label: String)
        case chatGPT(id: String, label: String)
        case gemini(id: String, label: String)
        case provider(status: AppProviderCredentialStatus, label: String)

        var id: String {
            switch self {
            case .claude(let id, _):
                return "claude-\(id)"
            case .chatGPT(let id, _):
                return "chatgpt-\(id)"
            case .gemini(let id, _):
                return "gemini-\(id)"
            case .provider(let status, _):
                return "provider-\(status.provider.rawValue)"
            }
        }

        var label: String {
            switch self {
            case .claude(_, let label),
                 .chatGPT(_, let label),
                 .gemini(_, let label),
                 .provider(_, let label):
                return label
            }
        }

        var reconnectHint: String {
            switch self {
            case .claude, .chatGPT:
                return "Rescan your browser to reconnect it."
            case .gemini:
                return "Re-add your Gemini API key to reconnect it."
            case .provider(let status, _):
                return status.provider == .gemini
                    ? "Re-add your Gemini API key to reconnect it."
                    : "Rescan your browser to reconnect it."
            }
        }
    }

    private enum ScanExclusion: Identifiable {
        case claude(id: String, label: String)
        case chatGPT(id: String, label: String)

        var id: String {
            switch self {
            case .claude(let id, _): return "claude-\(id)"
            case .chatGPT(let id, _): return "chatgpt-\(id)"
            }
        }

        var label: String {
            switch self {
            case .claude(_, let label), .chatGPT(_, let label): return label
            }
        }
    }

    private var orderedClaudeAccounts: [ClaudeAccount] {
        appModel.settings.claudeAccounts.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accounts")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Connected accounts appear in the popover and menu bar in this order.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                scanButton
            }

            accountCardsGrid

            geminiKeyRow

            excludedAccountsBox

            accountsFeedbackView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            pendingRemoval.map { "Remove \($0.label)?" } ?? "",
            isPresented: pendingRemovalBinding,
            presenting: pendingRemoval
        ) { removal in
            Button("Remove", role: .destructive) {
                performRemoval(removal)
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.reconnectHint)
        }
        .confirmationDialog(
            pendingScanExclusion.map { "Exclude \($0.label) from scans?" } ?? "",
            isPresented: pendingScanExclusionBinding,
            presenting: pendingScanExclusion
        ) { exclusion in
            Button("Exclude from Scans", role: .destructive) {
                performScanExclusion(exclusion)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The account will be disconnected and future browser scans will ignore it until you re-enable it here.")
        }
    }

    private var scanButton: some View {
        Button(action: {
            Task { await scanOpenBrowsersFromSettings() }
        }) {
            HStack(spacing: 5) {
                if isImportingProviderSessions {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isImportingProviderSessions ? (appModel.importProgress ?? "Scanning\u{2026}") : "Connect Browser Accounts\u{2026}")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isAccountsBusy)
    }

    /// The tallest the card grid grows before it scrolls. Every other part
    /// of the window fits its content; only a long account list scrolls,
    /// and only this grid, so the header and the Gemini row stay put.
    static let accountGridMaxHeight: CGFloat = 460

    @ViewBuilder
    private var accountCardsGrid: some View {
        let claudeAccounts = orderedClaudeAccounts
        let chatGPTAccounts = appModel.orderedChatGPTAccounts
        // A cookie in the legacy slot with no stored account entry still needs
        // a card, so the connected flag is checked alongside the account list.
        let showLegacyChatGPTCard = chatGPTAccounts.isEmpty && appModel.hasChatGPTSessionCookie
        let geminiAccounts = appModel.orderedGeminiAccounts

        ScrollView(.vertical) {
            // Two cards per row at the window's width; `.adaptive` drops to
            // one column only if the width ever shrinks below two minimums.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], alignment: .leading, spacing: 12) {
                if claudeAccounts.isEmpty && chatGPTAccounts.isEmpty && !showLegacyChatGPTCard {
                    emptyAccountsCard
                } else {
                    ForEach(claudeAccounts) { account in
                        claudeAccountCard(account)
                    }
                    ForEach(chatGPTAccounts) { account in
                        chatGPTAccountCard(account)
                    }
                    if showLegacyChatGPTCard {
                        providerCard(for: .chatGPT)
                    }
                }
                ForEach(geminiAccounts) { account in
                    geminiAccountCard(account)
                }
                if geminiAccounts.isEmpty && appModel.hasGeminiAPIKey {
                    providerCard(for: .gemini)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
        }
        .frame(maxHeight: Self.accountGridMaxHeight)
    }

    /// One connected ChatGPT account. Mirrors `claudeAccountCard`: an inline
    /// renameable label, the provider-reported email and plan beneath it, and
    /// per-account exclude/remove actions.
    private func chatGPTAccountCard(_ account: ChatGPTAccount) -> some View {
        let isMultiAccount = appModel.settings.chatGPTAccounts.count > 1
        let primaryStatus = appModel.providerCredentialStatuses.first { $0.provider == .chatGPT }
        let accountError = account.isPrimary
            ? appModel.chatGPTErrorMessage
            : appModel.chatGPTAccountErrors[account.id]
        let showReportedLabel = {
            let trimmed = account.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !trimmed.isEmpty && trimmed != account.label
        }()

        let health = Self.accountHealth(
            credentialHealth: account.isPrimary ? primaryStatus?.state.health : nil,
            hasUsage: account.isPrimary ? appModel.chatGPTUsageData != nil : appModel.chatGPTAccountUsage[account.id] != nil,
            hasError: accountError != nil
        )
        let lastUpdated = account.isPrimary
            ? appModel.chatGPTUsageData?.lastUpdated
            : appModel.chatGPTAccountUsage[account.id]?.lastUpdated
        let status = ConnectionStatus.forAccount(
            health: health,
            usageAge: lastUpdated.map { max(0, Date().timeIntervalSince($0)) },
            monitoringOff: !appModel.settings.isChatGPTUsageShown,
            error: accountError,
            recoverySuggestion: account.isPrimary ? primaryStatus?.recoverySuggestion : nil,
            hasRepairAction: account.isPrimary && primaryStatus?.actions.contains { $0.kind == .repair } == true
        )
        let focusKey = "chatgpt-\(account.id)"

        return AccountCard(
            provider: .chatGPT,
            isPrimary: account.isPrimary && isMultiAccount,
            detail: accountDetailLine([
                account.planType?.capitalized,
                showReportedLabel ? account.label : nil,
                account.profileLabel,
            ]),
            accountName: account.displayLabel,
            onRename: { focusedAccountNameField = focusKey }
        ) {
            TextField(account.label, text: chatGPTAccountLabelBinding(for: account.id))
                .accessibilityLabel("ChatGPT account name")
                .textFieldStyle(.plain)
                .focused($focusedAccountNameField, equals: focusKey)
        } menu: {
            accountActionsMenu(
                label: account.displayLabel,
                renameFocusKey: focusKey,
                exclusion: .chatGPT(id: account.id, label: account.displayLabel),
                removal: .chatGPT(id: account.id, label: account.displayLabel)
            )
        } status: {
            ConnectionStatusStrip(status) {
                connectionStripActions(for: status, primaryStatus: primaryStatus, supportsReconnect: true)
            }
        }
    }

    /// One connected Gemini API key.
    private func geminiAccountCard(_ account: GeminiAccount) -> some View {
        let isMultiAccount = appModel.settings.geminiAccounts.count > 1
        let primaryStatus = appModel.providerCredentialStatuses.first { $0.provider == .gemini }
        let accountError = account.isPrimary
            ? appModel.geminiErrorMessage
            : appModel.geminiAccountErrors[account.id]

        let health = Self.accountHealth(
            credentialHealth: account.isPrimary ? primaryStatus?.state.health : nil,
            hasUsage: account.isPrimary ? appModel.geminiUsageData != nil : appModel.geminiAccountUsage[account.id] != nil,
            hasError: accountError != nil
        )
        let lastUpdated = account.isPrimary
            ? appModel.geminiUsageData?.lastUpdated
            : appModel.geminiAccountUsage[account.id]?.lastUpdated
        let status = ConnectionStatus.forAccount(
            health: health,
            usageAge: lastUpdated.map { max(0, Date().timeIntervalSince($0)) },
            monitoringOff: false,
            error: accountError,
            recoverySuggestion: account.isPrimary ? primaryStatus?.recoverySuggestion : nil,
            hasRepairAction: account.isPrimary && primaryStatus?.actions.contains { $0.kind == .repair } == true
        )
        let focusKey = "gemini-\(account.id)"

        return AccountCard(
            provider: .gemini,
            isPrimary: account.isPrimary && isMultiAccount,
            detail: "API key",
            accountName: account.displayLabel,
            onRename: { focusedAccountNameField = focusKey }
        ) {
            TextField(account.label, text: geminiAccountLabelBinding(for: account.id))
                .accessibilityLabel("Gemini account name")
                .textFieldStyle(.plain)
                .focused($focusedAccountNameField, equals: focusKey)
        } menu: {
            accountActionsMenu(
                label: account.displayLabel,
                renameFocusKey: focusKey,
                exclusion: nil,
                removal: .gemini(id: account.id, label: account.displayLabel)
            )
        } status: {
            ConnectionStatusStrip(status) {
                connectionStripActions(for: status, primaryStatus: primaryStatus, supportsReconnect: false)
            }
        }
    }

    /// Manual entry for a Gemini key, as one slim row under the grid. A
    /// Google AI Studio key has no browser cookie to scan, so paste is the
    /// only route. The field is secure and the key is never echoed back.
    private var geminiKeyRow: some View {
        let hasGemini = !appModel.settings.geminiAccounts.isEmpty || appModel.hasGeminiAPIKey
        return HStack(spacing: 8) {
            Text(hasGemini ? "Add Gemini API key" : "Connect Gemini")
                .layoutPriority(1)

            SecureField("API key", text: $geminiAPIKeyDraft)
                .accessibilityLabel("Gemini API key")
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(minWidth: 140)
                .onSubmit {
                    guard !geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isAccountsBusy else { return }
                    Task { await saveGeminiAPIKey() }
                }

            Button(isSavingGemini ? "Connecting…" : "Connect") {
                Task { await saveGeminiAPIKey() }
            }
            .controlSize(.small)
            .disabled(geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAccountsBusy)

            Link("Get an API key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                .font(.caption)
                .layoutPriority(1)
        }
        .settingsRowPadding()
        .background(
            RoundedRectangle(cornerRadius: SettingsLayout.groupCornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayout.groupCornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        )
    }

    private func chatGPTAccountLabelBinding(for accountId: String) -> Binding<String> {
        Binding(
            get: { appModel.settings.chatGPTAccounts.first(where: { $0.id == accountId })?.customLabel ?? "" },
            set: { appModel.renameChatGPTAccount(id: accountId, customLabel: $0) }
        )
    }

    private func geminiAccountLabelBinding(for accountId: String) -> Binding<String> {
        Binding(
            get: { appModel.settings.geminiAccounts.first(where: { $0.id == accountId })?.customLabel ?? "" },
            set: { appModel.renameGeminiAccount(id: accountId, customLabel: $0) }
        )
    }

    private var emptyAccountsCard: some View {
        Button(action: {
            Task { await scanOpenBrowsersFromSettings() }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect accounts")
                    .font(.callout.weight(.semibold))
                Text("Sign in to Claude or ChatGPT in your browser, then scan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.secondary)
            )
        }
        .buttonStyle(.plain)
        .disabled(isAccountsBusy)
    }

    private func claudeAccountCard(_ account: ClaudeAccount) -> some View {
        let isMultiAccount = appModel.settings.claudeAccounts.count > 1
        let primaryStatus = appModel.providerCredentialStatuses.first { $0.provider == .claude }
        let accountError = account.isPrimary ? appModel.errorMessage : appModel.claudeAccountErrors[account.id]
        let showOrgName = {
            let trimmed = account.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !trimmed.isEmpty && trimmed != account.label
        }()

        let health = Self.accountHealth(
            credentialHealth: account.isPrimary ? primaryStatus?.state.health : nil,
            hasUsage: account.isPrimary ? appModel.usageData != nil : appModel.claudeAccountUsage[account.id] != nil,
            hasError: accountError != nil
        )
        let lastUpdated = account.isPrimary
            ? appModel.usageData?.lastUpdated
            : appModel.claudeAccountUsage[account.id]?.lastUpdated
        let status = ConnectionStatus.forAccount(
            health: health,
            usageAge: lastUpdated.map { max(0, Date().timeIntervalSince($0)) },
            monitoringOff: false,
            error: accountError,
            recoverySuggestion: account.isPrimary ? primaryStatus?.recoverySuggestion : nil,
            hasRepairAction: account.isPrimary && primaryStatus?.actions.contains { $0.kind == .repair } == true
        )
        let focusKey = "claude-\(account.id)"

        return AccountCard(
            provider: .claude,
            isPrimary: account.isPrimary && isMultiAccount,
            detail: accountDetailLine([
                showOrgName ? account.label : nil,
                account.profileLabel,
            ]),
            accountName: account.displayLabel,
            onRename: { focusedAccountNameField = focusKey }
        ) {
            TextField(account.label, text: accountLabelBinding(for: account.id))
                .accessibilityLabel("Claude account name")
                .textFieldStyle(.plain)
                .focused($focusedAccountNameField, equals: focusKey)
        } menu: {
            accountActionsMenu(
                label: account.displayLabel,
                renameFocusKey: focusKey,
                exclusion: .claude(id: account.id, label: account.displayLabel),
                removal: .claude(id: account.id, label: account.displayLabel)
            )
        } status: {
            ConnectionStatusStrip(status) {
                connectionStripActions(for: status, primaryStatus: primaryStatus, supportsReconnect: true)
            }
        }
    }

    /// A card for a credential in the legacy single-account slot with no
    /// stored account entry. It has no name to rename, so no pencil.
    private func providerCard(for provider: CredentialProvider) -> some View {
        let status = appModel.providerCredentialStatuses.first { $0.provider == provider }
        let displayLabel = providerDisplayLabel(for: provider)
        let hasUsage = provider == .gemini ? appModel.geminiUsageData != nil : appModel.chatGPTUsageData != nil
        let error = provider == .gemini ? appModel.geminiErrorMessage : appModel.chatGPTErrorMessage
        let health = Self.accountHealth(credentialHealth: status?.state.health, hasUsage: hasUsage, hasError: error != nil)
        let lastUpdated = provider == .gemini ? appModel.geminiUsageData?.lastUpdated : appModel.chatGPTUsageData?.lastUpdated
        let connectionStatus = ConnectionStatus.forAccount(
            health: health,
            usageAge: lastUpdated.map { max(0, Date().timeIntervalSince($0)) },
            monitoringOff: provider == .chatGPT && !appModel.settings.isChatGPTUsageShown,
            error: error ?? status?.lastFailureTitle,
            recoverySuggestion: status?.recoverySuggestion,
            hasRepairAction: status?.actions.contains { $0.kind == .repair } == true
        )

        return AccountCard(
            provider: provider,
            detail: provider == .gemini ? "API key" : nil
        ) {
            Text(displayLabel)
        } menu: {
            if let status {
                accountActionsMenu(
                    label: displayLabel,
                    renameFocusKey: nil,
                    exclusion: provider == .chatGPT
                        ? .chatGPT(id: ChatGPTAccount.unidentifiedId, label: displayLabel)
                        : nil,
                    removal: .provider(status: status, label: displayLabel)
                )
            }
        } status: {
            if status != nil {
                ConnectionStatusStrip(connectionStatus) {
                    connectionStripActions(for: connectionStatus, primaryStatus: status, supportsReconnect: provider != .gemini)
                }
            }
        }
    }

    private func providerDisplayLabel(for provider: CredentialProvider) -> String {
        switch provider {
        case .chatGPT: return appModel.chatGPTDisplayLabel
        case .gemini: return appModel.geminiDisplayLabel
        case .claude: return provider.displayName
        }
    }

    /// Trailing header menu for rename, exclude and remove. Rename only
    /// moves focus to the card's name field; the field's binding does the
    /// saving as the user types.
    @ViewBuilder
    private func accountActionsMenu(
        label: String,
        renameFocusKey: String?,
        exclusion: ScanExclusion?,
        removal: AccountRemoval
    ) -> some View {
        Menu {
            if let renameFocusKey {
                Button("Rename") {
                    focusedAccountNameField = renameFocusKey
                }
            }
            if let exclusion {
                Button("Exclude from Scans") {
                    pendingScanExclusion = exclusion
                }
            }
            Button("Remove", role: .destructive) {
                pendingRemoval = removal
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isAccountsBusy)
        .accessibilityLabel("Actions for \(label)")
    }

    /// The single action a `ConnectionStatusStrip` offers, mapped to what
    /// each account card can actually do. Gemini has no reconnect flow, so
    /// `supportsReconnect` silently drops that action for Gemini cards.
    @ViewBuilder
    private func connectionStripActions(
        for status: ConnectionStatus,
        primaryStatus: AppProviderCredentialStatus?,
        supportsReconnect: Bool
    ) -> some View {
        switch status.action {
        case .refreshUsage:
            Button("Refresh now") {
                Task { await appModel.refreshConfiguredUsageProviders(forceRefresh: true) }
            }
            .buttonStyle(.bordered)
            .disabled(isAccountsBusy)
        case .reconnect where supportsReconnect:
            Button("Reconnect") {
                Task { await scanOpenBrowsersFromSettings() }
            }
            .buttonStyle(.bordered)
            .disabled(isAccountsBusy)
        case .repair:
            if let primaryStatus {
                Button("Fix") {
                    handleCredentialAction(.repair, for: primaryStatus)
                }
                .buttonStyle(.bordered)
                .disabled(isCredentialActionDisabled(for: primaryStatus))
            }
        case .openGeneralSettings:
            Button("Open General") {
                selectedTab = .general
            }
            .buttonStyle(.bordered)
            .disabled(isAccountsBusy)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var excludedAccountsBox: some View {
        if !appModel.settings.scanExcludedAccounts.isEmpty {
            SettingsSection("Excluded from scans") {
                ForEach(appModel.settings.scanExcludedAccounts) { account in
                    SettingsRow(account.displayLabel, caption: account.provider.displayName) {
                        Button("Re-enable") {
                            appModel.reenableScanAccount(id: account.id)
                            accountsFeedback = ("Re-enabled \(account.displayLabel). Scan to reconnect it.", true)
                        }
                        .controlSize(.small)
                        .disabled(isAccountsBusy)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var accountsFeedbackView: some View {
        if let accountsFeedback {
            CopyableErrorText(accountsFeedback.message,
                              font: .caption,
                              foregroundStyle: accountsFeedback.isSuccess ? Color.green : Color.orange)
        }

        if offersFullDiskAccessSettings {
            Button("Open Privacy & Security Settings") {
                SystemSettingsOpener.openFullDiskAccess()
            }
            .controlSize(.small)
        }
    }

    private var pendingRemovalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }

    private var pendingScanExclusionBinding: Binding<Bool> {
        Binding(
            get: { pendingScanExclusion != nil },
            set: { if !$0 { pendingScanExclusion = nil } }
        )
    }

    private func performRemoval(_ removal: AccountRemoval) {
        switch removal {
        case .claude(let id, let label):
            removeClaudeAccountFromSettings(id: id, label: label)
        case .chatGPT(let id, let label):
            removeAccountFromSettings(label: label) {
                try await appModel.removeChatGPTAccount(id: id)
            }
        case .gemini(let id, let label):
            removeAccountFromSettings(label: label) {
                try await appModel.removeGeminiAccount(id: id)
            }
        case .provider(let status, _):
            handleCredentialAction(.clear, for: status)
        }
    }

    private func performScanExclusion(_ exclusion: ScanExclusion) {
        Task { @MainActor in
            isRemovingAccount = true
            accountsFeedback = nil
            offersFullDiskAccessSettings = false
            do {
                switch exclusion {
                case .claude(let id, _):
                    try await appModel.excludeClaudeAccountFromScans(id: id)
                case .chatGPT(let id, _):
                    try await appModel.excludeChatGPTAccountFromScans(id: id)
                }
                accountsFeedback = ("Excluded \(exclusion.label) from browser scans.", true)
            } catch {
                accountsFeedback = ("Failed to exclude \(exclusion.label): \(error.localizedDescription)", false)
            }
            isRemovingAccount = false
        }
    }

    static func accountHealth(
        credentialHealth: CredentialHealthState?, hasUsage: Bool, hasError: Bool
    ) -> CredentialHealthState {
        if hasError { return .unavailable }
        let health = credentialHealth ?? .unknown
        return health == .unknown && hasUsage ? .valid : health
    }

    static func accountStatusText(_ health: CredentialHealthState) -> String {
        switch health {
        case .valid: return "Connected"
        case .unknown: return "Waiting for usage"
        default: return health.displayTitle
        }
    }

    private func accountLabelBinding(for accountId: String) -> Binding<String> {
        Binding(
            get: {
                appModel.settings.claudeAccounts.first(where: { $0.id == accountId })?.customLabel ?? ""
            },
            set: { newValue in
                appModel.renameClaudeAccount(id: accountId, customLabel: newValue)
            }
        )
    }

    // MARK: - General sections

    private var menuBarAndPopoverSection: some View {
        SettingsSection("Menu bar and popover") {
            SettingsRow(
                "Show ChatGPT usage",
                caption: "Connect ChatGPT in Accounts, then show its plan quota in the popover."
            ) {
                Toggle("Show ChatGPT usage", isOn: $appModel.settings.isChatGPTUsageShown)
                    .settingsSwitch()
                    .disabled(!appModel.hasChatGPTSessionCookie)
                    .onChange(of: appModel.settings.isChatGPTUsageShown) { _, isShown in
                        if isShown {
                            Task { await appModel.refreshChatGPTUsage() }
                        }
                    }
            }

            SettingsRow("Codex Spark", indented: true) {
                Toggle("Show Codex Spark", isOn: $appModel.settings.isChatGPTSparkUsageShown)
                    .settingsSwitch()
            }
            .disabled(!appModel.settings.isChatGPTUsageShown)

            SettingsRow("GPT Reserve", indented: true) {
                Toggle("Show GPT Reserve", isOn: $appModel.settings.isChatGPTReserveUsageShown)
                    .settingsSwitch()
            }
            .disabled(!appModel.settings.isChatGPTUsageShown)

            SettingsRow(
                "Show Fable usage",
                caption: "Show model-scoped Fable usage in the menu bar and popover."
            ) {
                Toggle("Show Fable usage", isOn: $appModel.settings.isFableUsageShown)
                    .settingsSwitch()
            }

            SettingsRow("Bar colors", caption: "Palette for quota meters and reset labels.") {
                Picker("Bar colors", selection: $appModel.settings.menuBarColorScheme) {
                    ForEach(MenuBarColorScheme.allCases) { scheme in
                        HStack(spacing: 5) {
                            ForEach(Array(scheme.colors.enumerated()), id: \.offset) { _, color in
                                Circle()
                                    .fill(color)
                                    .frame(width: 8, height: 8)
                            }
                            Text(scheme.title)
                        }
                        .tag(scheme)
                    }
                }
                .settingsPicker()
            }

            SettingsRow("Reset time shows as", caption: "The reset text under each quota bar.") {
                Picker("Reset time shows as", selection: $appModel.settings.subscriptionResetAnnouncementMode) {
                    ForEach(SubscriptionResetAnnouncementMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .settingsPicker()
            }
        }
    }

    private var refreshSection: some View {
        SettingsSection("Refresh") {
            SettingsRow("Refresh interval", caption: "How often to check your usage.") {
                Picker("Refresh interval", selection: $appModel.settings.refreshInterval) {
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                }
                .settingsPicker()
            }
        }
    }

    private var systemSection: some View {
        SettingsSection("System") {
            SettingsRow("Start at login", caption: "Open Pinemeter when you log in.") {
                Toggle("Start at login", isOn: $launchAtLogin)
                    .settingsSwitch()
            }
        }
    }

    // MARK: - Notifications Tab

    private var notificationsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            usageAlertsSection
            celebrationsSection
        }
        .settingsPane()
    }

    private var usageAlertsSection: some View {
        let alertsOn = appModel.settings.hasNotificationsEnabled
        return SettingsSection("Alerts") {
            SettingsRow(
                "Usage alerts",
                caption: "Show a center-screen alert when session usage crosses a threshold. Works without macOS notification permission; a system banner is also sent when permission is granted."
            ) {
                Toggle("Usage alerts", isOn: $appModel.settings.hasNotificationsEnabled)
                    .settingsSwitch()
            }

            // Dependent rows are disabled, not only faded, while alerts are
            // off, so keyboard and VoiceOver users get the same signal.
            Group {
                thresholdRow(
                    title: "Warning threshold",
                    caption: "Alert when session usage reaches this percentage.",
                    value: warningThresholdBinding,
                    range: Constants.Thresholds.Notification.warningMin...Constants.Thresholds.Notification.warningMax,
                    tint: .orange
                )

                thresholdRow(
                    title: "Critical threshold",
                    caption: "Urgent alert when session usage reaches this percentage.",
                    value: criticalThresholdBinding,
                    range: Constants.Thresholds.Notification.criticalMin...Constants.Thresholds.Notification.criticalMax,
                    tint: .red,
                    validation: criticalThresholdValue <= warningThresholdValue
                        ? "Critical threshold must be higher than warning."
                        : nil
                )

                SettingsRow("Preview", caption: "Show a sample warning alert.") {
                    Button("Preview Alert") {
                        let payload = UsageAlertPayload(
                            severity: .warning,
                            title: "Usage Warning",
                            message: "You've used 80% of your 5-hour session. This is a preview alert."
                        )
                        NotificationCenter.default.post(name: .usageAlert, object: payload)
                    }
                    .controlSize(.small)
                }
            }
            .disabled(!alertsOn)
            .opacity(alertsOn ? 1 : 0.5)
        }
    }

    /// A slider row: title and monospaced value on one line, the slider
    /// beneath, then the caption. No `step:` on the slider, since that draws
    /// a tick per step; the binding rounds to the step instead.
    private func thresholdRow(
        title: String,
        caption: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        tint: Color,
        validation: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue))%")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            UntickedSlider(value: value, range: range, step: Constants.Thresholds.Notification.step, tint: tint)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int(value.wrappedValue)) percent")

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let validation {
                Label(validation, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .settingsRowPadding()
    }

    // Independent of notification permission: a center-screen celebration when
    // a tracked quota resets.
    private var celebrationsSection: some View {
        SettingsSection("Celebrations") {
            SettingsRow(
                "Celebrate resets",
                caption: "Show a center-screen fireworks celebration when a tracked quota resets."
            ) {
                Toggle("Celebrate resets", isOn: $appModel.settings.isResetCelebrationEnabled)
                    .settingsSwitch()
            }

            SettingsRow("Preview", caption: "Show the celebration now.") {
                Button("Preview") {
                    NotificationCenter.default.post(name: .usageDidReset, object: nil)
                }
                .controlSize(.small)
            }
            .disabled(!appModel.settings.isResetCelebrationEnabled)
            .opacity(appModel.settings.isResetCelebrationEnabled ? 1 : 0.5)
        }
    }

    // MARK: - Bindings

    private var warningThresholdBinding: Binding<Double> {
        Binding(
            get: { appModel.settings.notificationThresholds.warningThreshold },
            set: { appModel.settings.notificationThresholds.warningThreshold = $0 }
        )
    }

    private var criticalThresholdBinding: Binding<Double> {
        Binding(
            get: { appModel.settings.notificationThresholds.criticalThreshold },
            set: { appModel.settings.notificationThresholds.criticalThreshold = $0 }
        )
    }

    private var warningThresholdValue: Double {
        appModel.settings.notificationThresholds.warningThreshold
    }

    private var criticalThresholdValue: Double {
        appModel.settings.notificationThresholds.criticalThreshold
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        AboutSettingsView(
            includeBetaUpdates: $appModel.settings.includeBetaUpdates,
            availableUpdateVersion: appModel.availableUpdateVersion,
            installUpdate: { appModel.installAvailableUpdate() }
        )
    }

    // MARK: - Actions

    private var isAccountsBusy: Bool {
        isImportingProviderSessions || activeCredentialActionProvider != nil || isRemovingAccount || isSavingGemini
    }

    @MainActor
    private func scanOpenBrowsersFromSettings() async {
        isImportingProviderSessions = true
        accountsFeedback = nil
        offersFullDiskAccessSettings = false

        let review = await appModel.discoverBrowserSessions()
        offersFullDiskAccessSettings = review.offersFullDiskAccessSettings
        browserImportReview = review
        isImportingProviderSessions = false
    }

    private func applyBrowserScanOutcome(_ outcome: BrowserScanOutcome) {
        offersFullDiskAccessSettings = outcome.offersFullDiskAccessSettings
        if !outcome.sessionFailures.isEmpty {
            accountsFeedback = (outcome.sessionFailures.joined(separator: "\n"), false)
        } else if outcome.totalImported > 0 {
            var imported: [String] = []
            if outcome.claudeImported { imported.append("Claude") }
            if outcome.chatGPTImported { imported.append("ChatGPT") }
            accountsFeedback = ("Imported \(imported.joined(separator: " and ")).", true)
        } else if outcome.results.isEmpty {
            accountsFeedback = ("No open browsers detected. Open Chrome, Safari, or Firefox and try again.", false)
        } else {
            accountsFeedback = ("No sessions found in open browsers. Sign in first, then scan again.", false)
        }

    }

    @MainActor
    private func saveGeminiAPIKey() async {
        isSavingGemini = true
        accountsFeedback = nil
        offersFullDiskAccessSettings = false
        defer { isSavingGemini = false }

        do {
            // NEVER echo the key value into feedback/logs; clear the draft on success.
            let ok = try await appModel.addGeminiAPIKey(geminiAPIKeyDraft)
            if ok {
                geminiAPIKeyDraft = ""
                accountsFeedback = ("Connected Gemini.", true)
            } else {
                accountsFeedback = (
                    "That Gemini API key was rejected or is already connected. Check it and try again.",
                    false
                )
            }
        } catch {
            accountsFeedback = (error.localizedDescription, false)
        }
    }

    private func removeClaudeAccountFromSettings(id: String, label: String) {
        removeAccountFromSettings(label: label) {
            try await appModel.removeClaudeAccount(id: id)
        }
    }

    /// Shared disconnect wrapper: one busy flag, one feedback line, one error
    /// path, whichever provider the account belongs to.
    private func removeAccountFromSettings(
        label: String,
        remove: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor in
            isRemovingAccount = true
            accountsFeedback = nil
            offersFullDiskAccessSettings = false
            do {
                try await remove()
                accountsFeedback = ("Removed \(label).", true)
            } catch {
                accountsFeedback = ("Failed to remove \(label): \(error.localizedDescription)", false)
            }
            isRemovingAccount = false
        }
    }

    private func handleCredentialAction(_ kind: ProviderCredentialActionKind, for status: AppProviderCredentialStatus) {
        Task { @MainActor in
            await performProviderCredentialAction(kind, for: status)
        }
    }

    @MainActor
    private func performProviderCredentialAction(
        _ kind: ProviderCredentialActionKind,
        for status: AppProviderCredentialStatus
    ) async {
        activeCredentialActionProvider = status.provider
        activeCredentialActionKind = kind
        accountsFeedback = ("\(status.providerName): \(progressMessage(for: kind))", false)
        offersFullDiskAccessSettings = false

        do {
            let state = try await appModel.performProviderCredentialAction(kind, for: status.provider)
            if state.isUsable {
                accountsFeedback = ("\(status.providerName): \(successMessage(for: kind, credentialName: status.credentialName))", true)
            } else if kind == .clear {
                accountsFeedback = ("\(status.providerName): Cleared saved \(status.credentialName).", true)
            } else {
                let refreshedStatus = appModel.providerCredentialStatuses.first { $0.provider == status.provider }
                accountsFeedback = ("\(status.providerName): \(refreshedStatus?.recoverySuggestion ?? refreshedStatus?.detailText ?? "Recovery action did not restore access.")", false)
            }
        } catch {
            accountsFeedback = ("\(status.providerName): Failed to \(kind.displayTitle.lowercased()) \(status.credentialName): \(error.localizedDescription)", false)
        }

        activeCredentialActionProvider = nil
        activeCredentialActionKind = nil
    }

    private func progressMessage(for kind: ProviderCredentialActionKind) -> String {
        switch kind {
        case .reconnect:
            return "Reconnecting credentials from the signed-in browser session."
        case .repair:
            return "Repairing saved credential access."
        case .clear:
            return "Clearing saved credential."
        }
    }

    private func successMessage(for kind: ProviderCredentialActionKind, credentialName: String) -> String {
        switch kind {
        case .reconnect:
            return "Reconnected saved \(credentialName)."
        case .repair:
            return "Repaired saved \(credentialName)."
        case .clear:
            return "Cleared saved \(credentialName)."
        }
    }

    private func isCredentialActionDisabled(for status: AppProviderCredentialStatus) -> Bool {
        isAccountsBusy || status.state.health == .validating
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginSettingFailed = true
            // Revert the toggle if it failed
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

}

private struct AboutSettingsView: View {
    @Binding var includeBetaUpdates: Bool
    let availableUpdateVersion: String?
    let installUpdate: () -> Void
    @State private var copyFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pinemeter")
                        .font(.system(size: 26, weight: .semibold))
                    HStack(spacing: 5) {
                        Text("By")
                        Link("Pine IT", destination: URL(string: "https://pineit.ca")!)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if let version = BuildInfo.versionLabel() {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Text("Track AI quotas and choose models with room to work.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline)
                        Spacer(minLength: 12)
                        Button(availableUpdateVersion.map { "Install Version \($0)" } ?? "Check for Updates…", action: installUpdate)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    Toggle("Include beta updates", isOn: $includeBetaUpdates)
                    Text("Beta builds may be less stable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Help & support", systemImage: "questionmark.circle")
                        .font(.headline)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { supportButtons }
                        VStack(alignment: .leading, spacing: 8) { supportButtons }
                    }
                    Text(copyFeedback ?? "App details include only version, build, and macOS version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Your data", systemImage: "lock.shield")
                    .font(.headline)
                Text("Imported credentials are stored in the macOS Keychain and sent to the relevant provider to access your account. Pinemeter also contacts GitHub for updates and your configured preset source for model routing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Credits & licence") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Based on Pinemeter by Edd Mann. Released under the MIT licence, copyright © 2025 Edd Mann.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Link("Original project", destination: URL(string: "https://github.com/eddmann/Pinemeter")!)
                        Link("MIT licence", destination: URL(string: "https://github.com/PineIT-ca/pinemeter/blob/main/LICENSE")!)
                    }
                }
                .font(.caption)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
    }
        .settingsPane()
    }

    @ViewBuilder
    private var supportButtons: some View {
        Link(destination: URL(string: "https://github.com/PineIT-ca/pinemeter#readme")!) {
            Label("Get help", systemImage: "book")
        }
        .buttonStyle(.bordered)
        Link(destination: URL(string: "https://github.com/PineIT-ca/pinemeter/issues")!) {
            Label("Report a problem", systemImage: "bubble.left")
        }
        .buttonStyle(.bordered)
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            copyFeedback = pasteboard.setString(BuildInfo.supportDetails(), forType: .string)
                ? "Copied version, build, and macOS version."
                : "Could not copy app details. Try again."
        } label: {
            Label("Copy app details", systemImage: "doc.on.doc")
        }
        .help("Copy only version, build, and macOS version")
    }
}
