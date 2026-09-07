//
//  UsagePopoverView.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import SwiftUI
import AppKit

enum QuotaChartLayout {
    static let contentPadding: CGFloat = 14

    static func popoverWidth(for _: [MenuBarQuotaBar]) -> CGFloat { 400 }
}

/// Usage popover view with detailed metrics
struct UsagePopoverView: View {
    @Bindable var appModel: AppModel
    let onRequestClose: (() -> Void)?
    var referenceDate: Date? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var isRescanningBrowsers = false
    @State private var isRefreshing = false
    @State private var rescanMessage: String?
    @State private var browserImportReview: BrowserSessionImportReview?

    private var popoverWidth: CGFloat {
        QuotaChartLayout.popoverWidth(for: appModel.usageQuotaBars)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(appModel.hasConfiguredUsageProvider ? appModel.usageDashboardTitle : "Model Broker")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                // Refresh button
                Button(action: {
                    Task {
                        isRefreshing = true
                        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
                        isRefreshing = false
                    }
                }) {
                    if isRefreshing || appModel.isRefreshingConfiguredUsage {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing || appModel.isRefreshingConfiguredUsage)
                .help("Refresh usage data")
                .accessibilityLabel("Refresh usage data")
                .keyboardShortcut("r", modifiers: .command)
            }
            .padding()

            Divider()

            ViewThatFits(in: .vertical) {
                dashboardContent.fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical) { dashboardContent }
            }
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Footer with settings button
            HStack {
                Button("Settings") {
                    openSettingsFront()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityLabel("Open settings window")

                Spacer()

                Button {
                    Task { await rescanBrowsers() }
                } label: {
                    HStack(spacing: 5) {
                        if isRescanningBrowsers {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(rescanButtonTitle)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRescanningBrowsers)
                .help("Scan open browsers for provider sessions and reconnect accounts")
                .accessibilityLabel("Rescan browsers")

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
                .accessibilityLabel("Quit application")
            }
            .padding()
        }
        .frame(width: popoverWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appModel.usageDashboardTitle)
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

    private var dashboardContent: some View {
        VStack(spacing: 0) {
            // Error banner
            if let primaryErrorMessage = appModel.errorMessage {
                let errorMessage = "\(appModel.claudeUsageSections.first?.title ?? "Claude"): \(primaryErrorMessage)"
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        CopyableErrorText(errorMessage)

                        Spacer()
                    }

                    HStack(spacing: 8) {
                        // Retry button for recoverable errors
                        Button("Retry") {
                            Task {
                                await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
                            }
                        }
                        .buttonStyle(.bordered)

                        // Update Key button for Claude credential authentication errors
                        if ClaudeCredentialRecoveryCopy.shouldShowUpdateButton(for: errorMessage) {
                            Button(ClaudeCredentialRecoveryCopy.updateButtonTitle) {
                                openSettingsFront(tab: .accounts)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding()
                .background(Color.orange.opacity(0.1))

                Divider()
            }

            // Content
            if appModel.hasUsagePopoverContent {
                VStack(alignment: .leading, spacing: 14) {
                    // Same bars as the menu bar icon, same order, annotated.
                    let quotaBars = appModel.usageQuotaBars
                    if !quotaBars.isEmpty {
                        QuotaBarChart(bars: quotaBars, appModel: appModel, referenceDate: referenceDate)
                    }

                    ForEach(appModel.claudeUsageSections) { section in
                        if let sectionError = section.errorMessage {
                            providerErrorRow(provider: section.title, message: sectionError)
                        }
                    }

                    ForEach(appModel.chatGPTUsageSections) { section in
                        if let sectionError = section.errorMessage {
                            providerErrorRow(provider: section.title, message: sectionError)
                        }
                    }

                    ForEach(appModel.geminiUsageSections) { section in
                        if let sectionError = section.errorMessage {
                            providerErrorRow(provider: section.title, message: sectionError)
                        }
                    }

                    if appModel.settings.broker.isEnabled {
                        brokerCardOrPlaceholder
                        if !appModel.hasConfiguredUsageProvider {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Add usage monitoring")
                                    .font(.headline)
                                Text("Connect your accounts to see remaining capacity and give the broker fresh quota data.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Button("Connect accounts…") { openSettingsFront(tab: .accounts) }
                            }
                            .brokerCard()
                        }
                    }
                }
                .padding(QuotaChartLayout.contentPadding)
            } else {
                VStack(spacing: 12) {
                    if appModel.isRefreshingConfiguredUsage {
                        ProgressView()
                        Text(appModel.usageLoadingMessage)
                    } else {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No usage data yet")
                            .font(.headline)
                        Text("Refresh to try again, or check your account connections.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Manage accounts…") { openSettingsFront(tab: .accounts) }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 220)
                .padding()
            }
        }
    }

    private var rescanButtonTitle: String {
        if isRescanningBrowsers {
            return appModel.importProgress ?? "Scanning\u{2026}"
        }
        return rescanMessage ?? "Rescan browsers"
    }

    private func rescanBrowsers() async {
        isRescanningBrowsers = true
        rescanMessage = nil

        let review = await appModel.discoverBrowserSessions()
        browserImportReview = review
        isRescanningBrowsers = false
    }

    private func applyBrowserScanOutcome(_ outcome: BrowserScanOutcome) {
        if !outcome.sessionFailures.isEmpty {
            rescanMessage = "Some sessions need attention. Open Accounts settings."
        } else if outcome.results.isEmpty {
            rescanMessage = "No open browsers"
        } else if outcome.totalImported == 0 {
            rescanMessage = "No sessions found"
        } else {
            rescanMessage = nil
        }
    }

    private func openSettingsFront(tab: SettingsView.Tab? = nil) {
        if let tab { SettingsView.selectTab(tab) }
        onRequestClose?()
        if let keyWindow = NSApp.keyWindow, keyWindow.level != .normal {
            keyWindow.orderOut(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: PinemeterApp.settingsWindowID)
    }

    /// D-09: the broker card once `brokerUIState` arrives, or a compact
    /// "starting" placeholder in the brief window between the server toggle
    /// being enabled and the first `BrokerUIState` publish.
    @ViewBuilder
    private var brokerCardOrPlaceholder: some View {
        if let brokerUIState = appModel.brokerUIState {
            BrokerCardView(
                uiState: brokerUIState,
                isEnabled: true,
                hasRoutingUpdate: appModel.settings.broker.activeProfileHasUpdatedRules
            )
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Broker starting\u{2026}")
                    .font(.caption)
                    .foregroundStyle(Color.popoverSecondary)
                Spacer()
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
        }
    }

    private func providerErrorRow(provider: String, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            CopyableErrorText("\(provider): \(message)", font: .caption, foregroundStyle: Color.popoverSecondary)
            Spacer()
            Button("Accounts…") { openSettingsFront(tab: .accounts) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Manage \(provider) account")
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

}

enum ClaudeCredentialRecoveryCopy {
    static let updateButtonTitle = "Update Claude Session Key"

    static func shouldShowUpdateButton(for errorMessage: String) -> Bool {
        let normalized = errorMessage.lowercased()
        guard normalized.contains("claude") else { return false }

        return normalized.contains("session key")
            || normalized.contains("authentication")
            || normalized.contains("invalid")
            || normalized.contains("expired")
    }
}

extension Color {
    /// Higher-contrast replacement for `.secondary` on the popover's solid
    /// control-background surfaces. SwiftUI's `.secondary` (~55% label opacity)
    /// falls below the WCAG AA 4.5:1 ratio for small text. These solid,
    /// appearance-specific grays measure ~8:1 in light and ~9:1 in dark while
    /// staying visibly de-emphasized against the full-strength label text.
    static let popoverSecondary = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(calibratedWhite: 0.86, alpha: 1)
            : NSColor(calibratedWhite: 0.26, alpha: 1)
    })
}

/// Account cards keep identity, quota and reset information together.
private struct QuotaBarChart: View {
    let bars: [MenuBarQuotaBar]
    @Bindable var appModel: AppModel
    let referenceDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 12) {
                ForEach(Array(MenuBarQuotaBar.groupedByOwner(bars).enumerated()), id: \.offset) { _, group in
                    accountCard(group, now: referenceDate ?? context.date)
                }
            }
        }
    }

    private func accountCard(_ bars: [MenuBarQuotaBar], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let owner = bars.first {
                let stale = UsageFreshness.isStale(lastUpdated: owner.lastUpdated, now: now)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let provider = owner.provider, owner.owner != provider.displayName {
                            Text(provider.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        QuotaOwnerLabel(bar: owner, appModel: appModel)
                        Text(owner.lastUpdated.map { "Updated " + UsageFreshness.ageDescription(lastUpdated: $0, now: now) }
                             ?? "Update time unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if stale {
                        Label("Saved data", systemImage: "clock.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("This account has not refreshed within 20 minutes. Refresh to verify its remaining quota.")
                    }
                }
            }
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(bar.heading == "5h" ? "5-hour usage" : bar.heading)
                            .font(.callout)
                        Spacer()
                        Text("\(Int(bar.percentage.rounded()))% used")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(bar.isNearLimit ? .red : .primary)
                    }
                    GeometryReader { geometry in
                        Capsule().fill(Color.secondary.opacity(0.12))
                            .overlay(alignment: .leading) {
                                Capsule().fill(bar.meterColor)
                                    .frame(width: geometry.size.width * min(max(bar.percentage, 0), 100) / 100)
                            }
                    }
                    .frame(height: 6)
                    .accessibilityHidden(true)
                    if let detail = bar.detail {
                        Label("Resets " + detail.replacingOccurrences(of: "\n", with: " · "), systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(bar.owner), \(bar.label)")
                .accessibilityValue("\(Int(bar.percentage.rounded())) percent used" + (bar.detail.map { ", resets \($0.replacingOccurrences(of: "\n", with: ", "))" } ?? ""))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1) }
    }
}

private struct QuotaOwnerLabel: View {
    let bar: MenuBarQuotaBar
    @Bindable var appModel: AppModel

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    @ViewBuilder
    var body: some View {
        if let target = bar.renameTarget {
            editableOwner(target: target)
        } else {
            plainOwner
        }
    }

    private var plainOwner: some View {
        Text(bar.owner)
            .font(.headline)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func editableOwner(target: QuotaRenameTarget) -> some View {
        if isEditing {
            TextField("Account name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .frame(minWidth: 120, maxWidth: .infinity)
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onSubmit { commit(target: target) }
                .onExitCommand { isEditing = false }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { commit(target: target) }
                }
        } else {
            Button { beginEditing(target: target) } label: {
                HStack(spacing: 6) {
                    plainOwner
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename account")
            .accessibilityLabel("Rename \(bar.owner)")
            .accessibilityAddTraits(.isButton)
        }
    }

    private func beginEditing(target: QuotaRenameTarget) {
        draft = appModel.customLabel(for: target)
        isEditing = true
    }

    private func commit(target: QuotaRenameTarget) {
        guard isEditing else { return }
        appModel.renameUsageOwner(target, customLabel: draft)
        isEditing = false
    }
}
