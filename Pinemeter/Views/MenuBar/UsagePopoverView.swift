//
//  UsagePopoverView.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import SwiftUI
import AppKit

enum QuotaChartLayout {
    static let columnWidth: CGFloat = 72
    static let barSpacing: CGFloat = 8
    static let groupSpacing: CGFloat = 16
    static let chartPadding: CGFloat = 12
    static let contentPadding: CGFloat = 14

    static func columnWidth(for bar: MenuBarQuotaBar) -> CGFloat {
        columnWidth
    }

    static func popoverWidth(for bars: [MenuBarQuotaBar]) -> CGFloat {
        guard !bars.isEmpty else { return 400 }
        let groups = MenuBarQuotaBar.groupedByOwner(bars)
        let columns = bars.reduce(CGFloat.zero) { $0 + columnWidth(for: $1) }
        let barGaps = CGFloat(groups.reduce(0) { $0 + max($1.count - 1, 0) }) * barSpacing
        let groupGaps = CGFloat(max(groups.count - 1, 0)) * groupSpacing
        let ideal = columns + barGaps + groupGaps + 2 * (chartPadding + contentPadding)
        return min(max(ideal, 240), 764)
    }
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

/// The popover's main content: the menu bar's quota bars blown up into
/// labelled columns, in the same left-to-right order as the icon.
private struct QuotaBarChart: View {
    let bars: [MenuBarQuotaBar]
    @Bindable var appModel: AppModel
    let referenceDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: QuotaChartLayout.groupSpacing) {
                ForEach(Array(MenuBarQuotaBar.groupedByOwner(bars).enumerated()), id: \.offset) { _, group in
                    QuotaBarGroup(bars: group, appModel: appModel, now: referenceDate ?? context.date)
                }
            }
            .padding(QuotaChartLayout.chartPadding)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct QuotaBarGroup: View {
    let bars: [MenuBarQuotaBar]
    @Bindable var appModel: AppModel
    let now: Date

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: QuotaChartLayout.barSpacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    QuotaBarColumn(bar: bar)
                }
            }

            if let ownerBar = bars.first, !ownerBar.owner.isEmpty {
                VStack(spacing: 4) {
                    Rectangle()
                        .fill(Color.popoverSecondary.opacity(0.35))
                        .frame(height: 1)

                    QuotaOwnerLabel(bar: ownerBar, appModel: appModel)
                    if UsageFreshness.isStale(lastUpdated: ownerBar.lastUpdated, now: now) {
                        Label("Saved data", systemImage: "clock.badge.exclamationmark")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("This account has not refreshed within 20 minutes. Refresh to verify its remaining quota.")
                    }
                }
            }
        }
    }
}

private struct QuotaBarColumn: View {
    let bar: MenuBarQuotaBar

    private var clampedPercentage: Double {
        min(max(bar.percentage, 0), 100)
    }

    private var tooltip: String {
        var text = "\(bar.label): \(Int(bar.percentage.rounded()))%"
        if let detail = bar.detail {
            text += " • \(detail)"
        }
        return text
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(bar.heading)
                .font(.caption)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(Int(bar.percentage.rounded()))%")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(bar.meterColor)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.gray.opacity(0.18))

                RoundedRectangle(cornerRadius: 5)
                    .fill(bar.meterColor)
                    .frame(height: 140 * clampedPercentage / 100)
            }
            .frame(width: 24, height: 140)

            if let detail = bar.detail {
                QuotaResetLabel(detail: detail, palette: bar.colorScheme)
            }
        }
        .frame(width: QuotaChartLayout.columnWidth(for: bar), alignment: .top)
        .help(tooltip)
    }
}

/// The leading duration unit is prominent; smaller units and local time sit below it.
struct QuotaResetLabel: View {
    let detail: String
    var palette: MenuBarColorScheme = .spectrum
    @Environment(\.self) private var environment

    private var lines: [String] { detail.components(separatedBy: "\n") }
    private var countdown: String? { lines.first { $0.hasPrefix("in ") } }

    var accessibilityDescription: String {
        let spokenLines = lines.map { line in
            guard line.hasPrefix("in ") else { return line }
            let units = line.dropFirst(3).split(separator: " ").map { token -> String in
                let names = ["d": "day", "h": "hour", "m": "minute"]
                guard let name = names[String(token.suffix(1))] else { return String(token) }
                let count = token.dropLast()
                return "\(count) \(name)\(count == "1" ? "" : "s")"
            }
            return "in \(units.joined(separator: " "))"
        }
        return "Resets \(spokenLines.joined(separator: ", "))"
    }

    /// Reuse the selected meter palette; shade colors for text rather than fills.
    /// Unit suffixes and spoken labels remain available independently of hue.
    private func unitColor(_ unit: Character?) -> Color {
        let index: Int
        switch unit {
        case "d": index = 0
        case "h": index = 1
        case "m": index = 2
        default: return .primary
        }
        let color = palette.colors[index].resolve(in: environment)
        let dark = environment.colorScheme == .dark
        let scale: Float = dark ? 0.75 : 0.55
        let offset: Float = dark ? 0.25 : 0
        return Color(.sRGB,
                     red: Double(color.red * scale + offset),
                     green: Double(color.green * scale + offset),
                     blue: Double(color.blue * scale + offset))
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(countdown == nil ? "Resets" : "Resets in")
                .font(.caption2)
                .foregroundStyle(Color.popoverSecondary)

            if let countdown {
                let units = countdown.dropFirst(3).split(separator: " ")
                Text(units.first.map(String.init) ?? "")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(unitColor(units.first?.last))

                if units.count > 1 {
                    Text(units.dropFirst().joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
            }

            ForEach(Array(lines.filter { $0 != countdown }.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(Color.popoverSecondary)
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
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
            .font(.caption2)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func editableOwner(target: QuotaRenameTarget) -> some View {
        if isEditing {
            TextField("Account name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)
                .frame(width: 64)
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
