import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @Bindable var appModel: AppModel

    @State private var offersFullDiskAccessSettings: Bool = false
    @State private var isImportingProviderSessions: Bool = false
    @State private var activeCredentialActionProvider: CredentialProvider?
    @State private var activeCredentialActionKind: ProviderCredentialActionKind?
    @State private var accountsFeedback: (message: String, isSuccess: Bool)?
    @State private var pendingRemoval: AccountRemoval?
    @State private var pendingScanExclusion: ScanExclusion?
    @State private var isRemovingAccount: Bool = false
    @State private var isSavingGemini: Bool = false
    // Gemini is the one provider connected by manual entry: a Google AI Studio
    // API key has no browser cookie to scan, so paste is the only mechanism.
    @State private var geminiAPIKeyDraft: String = ""

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(
            minWidth: 460,
            maxWidth: .infinity,
            minHeight: 440,
            maxHeight: .infinity
        )
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
    }

    // MARK: - General Tab

    private var generalTab: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                if !appModel.isReady {
                    VStack {
                        Spacer()
                        ProgressView("Loading settings...")
                            .controlSize(.large)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    accountsSection
                    chatGPTUsageSection
                    refreshIntervalSection
                    barColorsSection
                    fableUsageSection
                    launchAtLoginSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    // MARK: - Accounts Section

    private enum AccountRemoval: Identifiable {
        case claude(id: String, label: String)
        case provider(status: AppProviderCredentialStatus, label: String)

        var id: String {
            switch self {
            case .claude(let id, _):
                return "claude-\(id)"
            case .provider(let status, _):
                return "provider-\(status.provider.rawValue)"
            }
        }

        var label: String {
            switch self {
            case .claude(_, let label), .provider(_, let label):
                return label
            }
        }

        var reconnectHint: String {
            switch self {
            case .claude:
                return "Rescan your browser to reconnect it."
            case .provider(let status, _):
                return status.provider == .gemini
                    ? "Re-add your Gemini API key to reconnect it."
                    : "Rescan your browser to reconnect it."
            }
        }
    }

    private enum ScanExclusion: Identifiable {
        case claude(id: String, label: String)
        case chatGPT(label: String)

        var id: String {
            switch self {
            case .claude(let id, _): return "claude-\(id)"
            case .chatGPT: return "chatgpt"
            }
        }

        var label: String {
            switch self {
            case .claude(_, let label), .chatGPT(let label): return label
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
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accounts")
                        .font(.subheadline)
                    Text("Connected accounts appear in the popover and menu bar in this order.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                scanButton
            }

            accountCardsRow

            excludedAccountsBox

            accountsFeedbackView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                Text(isImportingProviderSessions ? (appModel.importProgress ?? "Scanning\u{2026}") : "Scan")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isAccountsBusy)
    }

    @ViewBuilder
    private var accountCardsRow: some View {
        let claudeAccounts = orderedClaudeAccounts
        let showChatGPT = appModel.hasChatGPTSessionCookie

        // Gemini is always shown last (it connects via manual API key, not a
        // browser scan), so this row is always a horizontal ScrollView. The
        // dashed scan empty-state only appears when no cookie-scan providers
        // (Claude/ChatGPT) are connected yet.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                if claudeAccounts.isEmpty && !showChatGPT {
                    emptyAccountsCard
                } else {
                    ForEach(claudeAccounts) { account in
                        claudeAccountCard(account)
                    }
                    if showChatGPT {
                        providerCard(for: .chatGPT)
                    }
                }
                geminiCard
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
        }
    }

    private var geminiCard: some View {
        let status = appModel.providerCredentialStatuses.first { $0.provider == .gemini }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Gemini")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                if let status {
                    Circle()
                        .fill(credentialStatusColor(for: status.state.health))
                        .frame(width: 8, height: 8)
                        .help(status.stateText)
                }
            }

            Text("Gemini")
                .font(.callout.weight(.semibold))

            if appModel.hasGeminiAPIKey, let status {
                Text(status.detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastFailureTitle = status.lastFailureTitle {
                    CopyableErrorText(lastFailureTitle, font: .caption2, foregroundStyle: .orange)
                }

                Spacer(minLength: 4)

                HStack(spacing: 8) {
                    removeButton(.provider(status: status, label: "Gemini"))
                    Spacer()
                }
            } else {
                // Manual entry: a Google AI Studio key has no browser cookie to
                // scan, so paste is the only way to connect Gemini.
                SecureField("API key", text: $geminiAPIKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                Button("Save") {
                    Task { await saveGeminiAPIKey() }
                }
                .controlSize(.small)
                .disabled(geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAccountsBusy)

                Link("Get an API key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.caption2)

                Spacer(minLength: 4)
            }
        }
        .padding(10)
        .frame(width: 180)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
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
        let accountError = account.isPrimary ? nil : appModel.claudeAccountErrors[account.id]
        let showOrgName = {
            let trimmed = account.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !trimmed.isEmpty && trimmed != account.label
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Claude")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if account.isPrimary && isMultiAccount {
                    Text("Primary")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()

                Circle()
                    .fill(claudeStatusColor(for: account, primaryStatus: primaryStatus))
                    .frame(width: 8, height: 8)
                    .help(claudeStatusTooltip(for: account, accountError: accountError, primaryStatus: primaryStatus))
            }

            TextField(account.label, text: accountLabelBinding(for: account.id))
                .textFieldStyle(.plain)
                .font(.callout.weight(.semibold))

            if showOrgName {
                Text(account.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let profileLabel = account.profileLabel {
                Text(profileLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                if account.isPrimary, let primaryStatus {
                    providerCredentialStatusActions(for: primaryStatus)
                }
                excludeButton(.claude(id: account.id, label: account.displayLabel))
                removeButton(.claude(id: account.id, label: account.displayLabel))
                Spacer()
            }
        }
        .padding(10)
        .frame(width: 180)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func providerCard(for provider: CredentialProvider) -> some View {
        let status = appModel.providerCredentialStatuses.first { $0.provider == provider }
        let displayLabel = providerDisplayLabel(for: provider)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(provider.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                if let status {
                    Circle()
                        .fill(credentialStatusColor(for: status.state.health))
                        .frame(width: 8, height: 8)
                        .help(status.stateText)
                }
            }

            Text(displayLabel)
                .font(.callout.weight(.semibold))

            if let status {
                Text(status.detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastFailureTitle = status.lastFailureTitle {
                    CopyableErrorText(lastFailureTitle, font: .caption2, foregroundStyle: .orange)
                }
            }

            Spacer(minLength: 4)

            if let status {
                HStack(spacing: 8) {
                    if provider == .chatGPT {
                        excludeButton(.chatGPT(label: displayLabel))
                    }
                    removeButton(.provider(status: status, label: displayLabel))
                    Spacer()
                }
            }
        }
        .padding(10)
        .frame(width: 180)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func providerDisplayLabel(for provider: CredentialProvider) -> String {
        switch provider {
        case .chatGPT: return appModel.chatGPTDisplayLabel
        case .gemini: return appModel.geminiDisplayLabel
        case .claude: return provider.displayName
        }
    }

    @ViewBuilder
    private func providerCredentialStatusActions(for status: AppProviderCredentialStatus) -> some View {
        let visibleActions = status.actions.filter { $0.kind == .repair }

        ForEach(visibleActions) { action in
            Button("Fix") {
                handleCredentialAction(action.kind, for: status)
            }
            .controlSize(.small)
            .disabled(isCredentialActionDisabled(for: status))
        }
    }

    private func removeButton(_ removal: AccountRemoval) -> some View {
        Button("Remove") {
            pendingRemoval = removal
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .tint(.red)
        .disabled(isAccountsBusy)
    }

    private func excludeButton(_ exclusion: ScanExclusion) -> some View {
        Button("Exclude") {
            pendingScanExclusion = exclusion
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(isAccountsBusy)
        .help("Disconnect and permanently exclude from browser scans")
    }

    @ViewBuilder
    private var excludedAccountsBox: some View {
        if !appModel.settings.scanExcludedAccounts.isEmpty {
            GroupBox("Excluded from scans") {
                VStack(spacing: 8) {
                    ForEach(appModel.settings.scanExcludedAccounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayLabel)
                                    .font(.callout.weight(.medium))
                                Text(account.provider.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Re-enable") {
                                appModel.reenableScanAccount(id: account.id)
                                accountsFeedback = ("Re-enabled \(account.displayLabel). Scan to reconnect it.", true)
                            }
                            .controlSize(.small)
                            .disabled(isAccountsBusy)
                        }
                    }
                }
                .padding(.vertical, 4)
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
                case .chatGPT:
                    try await appModel.excludeChatGPTAccountFromScans()
                }
                accountsFeedback = ("Excluded \(exclusion.label) from browser scans.", true)
            } catch {
                accountsFeedback = ("Failed to exclude \(exclusion.label): \(error.localizedDescription)", false)
            }
            isRemovingAccount = false
        }
    }

    private func claudeStatusColor(for account: ClaudeAccount, primaryStatus: AppProviderCredentialStatus?) -> Color {
        if account.isPrimary {
            return credentialStatusColor(for: primaryStatus?.state.health ?? .unknown)
        }
        return appModel.claudeAccountErrors[account.id] == nil ? .green : .orange
    }

    private func claudeStatusTooltip(
        for account: ClaudeAccount,
        accountError: String?,
        primaryStatus: AppProviderCredentialStatus?
    ) -> String {
        if account.isPrimary {
            return primaryStatus?.stateText ?? "Connected"
        }
        return accountError ?? "Connected"
    }

    private func credentialStatusColor(for health: CredentialHealthState) -> Color {
        switch health {
        case .valid:
            return .green
        case .refreshRecommended:
            return .orange
        case .validating:
            return .blue
        case .invalid, .expired, .unavailable:
            return .red
        case .missing, .unknown:
            return .secondary
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

    // MARK: - ChatGPT Usage Section

    private var chatGPTUsageSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Show ChatGPT Usage")
                    .font(.subheadline)
                Text("Optional. Connect ChatGPT from Accounts above, then show ChatGPT plan quota usage in the popover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $appModel.settings.isChatGPTUsageShown)
                .labelsHidden()
                .disabled(!appModel.hasChatGPTSessionCookie)
                .onChange(of: appModel.settings.isChatGPTUsageShown) { _, isShown in
                    if isShown {
                        Task { await appModel.refreshChatGPTUsage() }
                    }
                }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Refresh Interval Section

    private var refreshIntervalSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Refresh Interval")
                    .font(.subheadline)
                Text("How often to check your usage data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $appModel.settings.refreshInterval) {
                Text("1 minute").tag(60.0)
                Text("5 minutes").tag(300.0)
                Text("10 minutes").tag(600.0)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 120)
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Bar Colors Section

    private var barColorsSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bar Colors")
                    .font(.subheadline)
                Text("Color palette for quota meters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $appModel.settings.menuBarColorScheme) {
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
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 145)
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Fable Usage Section

    private var fableUsageSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Show Fable Usage")
                    .font(.subheadline)
                Text("Display model-scoped Fable usage in the menu bar and popover")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $appModel.settings.isFableUsageShown)
                .labelsHidden()
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Launch at Login Section

    private var launchAtLoginSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start at Login")
                    .font(.subheadline)
                Text("Automatically launch Pinemeter when you log in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $launchAtLogin)
                .labelsHidden()
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Notifications Tab

    private var notificationsTab: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                enableNotificationsSection
                thresholdsSection
                    .opacity(appModel.settings.hasNotificationsEnabled ? 1 : 0.5)
                    .allowsHitTesting(appModel.settings.hasNotificationsEnabled)
                testNotificationSection
                    .opacity(appModel.settings.hasNotificationsEnabled ? 1 : 0.5)
                    .allowsHitTesting(appModel.settings.hasNotificationsEnabled)
                resetCelebrationSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    // Independent of notification permission: a center-screen celebration when
    // a tracked quota resets.
    private var resetCelebrationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Celebrate Resets")
                        .font(.subheadline)
                    Text("Show a center-screen fireworks celebration when a tracked quota resets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Toggle("", isOn: $appModel.settings.isResetCelebrationEnabled)
                    .labelsHidden()
            }

            Button("Preview celebration") {
                NotificationCenter.default.post(name: .usageDidReset, object: nil)
            }
            .controlSize(.small)
            .disabled(!appModel.settings.isResetCelebrationEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var enableNotificationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage Alerts")
                        .font(.subheadline)
                    Text("Show a center-screen alert when session usage crosses your warning or critical threshold. Works without macOS notification permission; a system banner is also sent when permission is granted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Toggle("", isOn: $appModel.settings.hasNotificationsEnabled)
                    .labelsHidden()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var thresholdsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Warning Threshold")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(warningThresholdValue))%")
                        .foregroundStyle(.orange)
                        .font(.subheadline.monospacedDigit())
                }

                Slider(
                    value: warningThresholdBinding,
                    in: Constants.Thresholds.Notification.warningMin...Constants.Thresholds.Notification.warningMax,
                    step: Constants.Thresholds.Notification.step
                )
                .tint(.orange)

                Text("Get notified when session usage reaches this percentage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Critical Threshold")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(criticalThresholdValue))%")
                        .foregroundStyle(.red)
                        .font(.subheadline.monospacedDigit())
                }

                Slider(
                    value: criticalThresholdBinding,
                    in: Constants.Thresholds.Notification.criticalMin...Constants.Thresholds.Notification.criticalMax,
                    step: Constants.Thresholds.Notification.step
                )
                .tint(.red)

                Text("Get urgent notification when session usage reaches this percentage")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if criticalThresholdValue <= warningThresholdValue {
                    Label("Critical threshold must be higher than warning", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var testNotificationSection: some View {
        HStack {
            Button("Preview alert") {
                let payload = UsageAlertPayload(
                    severity: .warning,
                    title: "Usage Warning",
                    message: "You've used 80% of your 5-hour session. This is a preview alert."
                )
                NotificationCenter.default.post(name: .usageAlert, object: payload)
            }
            .controlSize(.small)

            Spacer()
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        ScrollView(.vertical) {
        VStack(spacing: 20) {
            // Pineit logo
            Image("PineitLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                .accessibilityHidden(true)

            // App Name & Version
            VStack(spacing: 6) {
                Text("Pinemeter")
                    .font(.system(size: 28, weight: .semibold))

                Text("by Pineit")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Text("Version \(version) (\(build))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // What it does
            VStack(spacing: 10) {
                Text("All your AI usage. One glance.")
                    .font(.headline)

                Text("Pinemeter lives in your menu bar and watches every quota that can stop you mid-flow: Claude's 5-hour and weekly windows across all your accounts, ChatGPT's plan limits, and Gemini API usage. Live meters, reset countdowns, and threshold alerts before you hit a wall.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Your credentials never leave this Mac. Sessions are imported from your own browsers, stored in the macOS Keychain, and used only to read usage data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 380)

            // Pineit link
            Link(destination: URL(string: "https://pineit.ca")!) {
                HStack {
                    Image(systemName: "link.circle.fill")
                    Text("pineit.ca")
                }
                .frame(maxWidth: 280)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("Visit pineit.ca")

            // Copyright & attribution
            VStack(spacing: 2) {
                Text("© 2026 Pineit · pineit.ca")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Based on Pinemeter by Edd Mann, MIT licensed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        }
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

        let outcome = await appModel.importFromOpenBrowsers()
        offersFullDiskAccessSettings = outcome.offersFullDiskAccessSettings

        if outcome.totalImported > 0 {
            var imported: [String] = []
            if outcome.claudeImported { imported.append("Claude") }
            if outcome.chatGPTImported { imported.append("ChatGPT") }
            accountsFeedback = ("Imported \(imported.joined(separator: " and ")).", true)
        } else if outcome.results.isEmpty {
            accountsFeedback = ("No open browsers detected. Open Chrome, Safari, or Firefox and try again.", false)
        } else {
            accountsFeedback = ("No sessions found in open browsers. Sign in first, then scan again.", false)
        }

        isImportingProviderSessions = false
    }

    @MainActor
    private func saveGeminiAPIKey() async {
        isSavingGemini = true
        accountsFeedback = nil
        offersFullDiskAccessSettings = false
        defer { isSavingGemini = false }

        do {
            // NEVER echo the key value into feedback/logs; clear the draft on success.
            let ok = try await appModel.validateAndSaveGeminiAPIKey(geminiAPIKeyDraft)
            if ok {
                geminiAPIKeyDraft = ""
                accountsFeedback = ("Connected Gemini.", true)
            } else {
                accountsFeedback = ("That Gemini API key was rejected. Check it and try again.", false)
            }
        } catch {
            accountsFeedback = (error.localizedDescription, false)
        }
    }

    private func removeClaudeAccountFromSettings(id: String, label: String) {
        Task { @MainActor in
            isRemovingAccount = true
            accountsFeedback = nil
            offersFullDiskAccessSettings = false
            do {
                try await appModel.removeClaudeAccount(id: id)
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
            // Revert the toggle if it failed
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

}
