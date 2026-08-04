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

    static func popoverWidth(for bars: [MenuBarQuotaBar]) -> CGFloat {
        let groups = MenuBarQuotaBar.groupedByOwner(bars)
        let columns = CGFloat(bars.count) * columnWidth
        let barGaps = CGFloat(groups.reduce(0) { $0 + max($1.count - 1, 0) }) * barSpacing
        let groupGaps = CGFloat(max(groups.count - 1, 0)) * groupSpacing
        let ideal = columns + barGaps + groupGaps + 2 * (chartPadding + contentPadding)
        return min(max(ideal, 240), 700)
    }
}

/// Usage popover view with detailed metrics
struct UsagePopoverView: View {
    @Bindable var appModel: AppModel
    let onRequestClose: (() -> Void)?
    @Environment(\.openWindow) private var openWindow
    @State private var isRescanningBrowsers = false
    @State private var rescanMessage: String?

    private var popoverWidth: CGFloat {
        QuotaChartLayout.popoverWidth(for: appModel.usageQuotaBars)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(appModel.usageDashboardTitle)
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                // Refresh button
                Button(action: {
                    Task {
                        await appModel.refreshConfiguredUsageProviders(forceRefresh: true)
                    }
                }) {
                    if appModel.isRefreshingConfiguredUsage {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(appModel.isRefreshingConfiguredUsage)
                .help("Refresh usage data")
                .keyboardShortcut("r", modifiers: .command)
            }
            .padding()

            Divider()

            // Error banner
            if let errorMessage = appModel.errorMessage {
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
                                openSettingsFront()
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
                        QuotaBarChart(bars: quotaBars, appModel: appModel)
                    }

                    ForEach(appModel.claudeUsageSections) { section in
                        if section.usageData == nil, let sectionError = section.errorMessage {
                            providerErrorRow(provider: section.title, message: sectionError)
                        }
                    }

                    if appModel.settings.isChatGPTUsageShown, let chatGPTErrorMessage = appModel.chatGPTErrorMessage {
                        providerErrorRow(provider: "ChatGPT", message: chatGPTErrorMessage)
                    }

                    if appModel.isGeminiUsageConfigured, let geminiErrorMessage = appModel.geminiErrorMessage {
                        providerErrorRow(provider: "Gemini", message: geminiErrorMessage)
                    }
                }
                .padding(QuotaChartLayout.contentPadding)
            } else {
                // Loading state
                VStack(spacing: 16) {
                    ProgressView()
                    Text(appModel.usageLoadingMessage)
                        .font(.callout)
                        .foregroundStyle(Color.popoverSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .padding()
            }

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

        let outcome = await appModel.importFromOpenBrowsers()

        if outcome.results.isEmpty {
            rescanMessage = "No open browsers"
        } else if outcome.totalImported == 0 {
            rescanMessage = "No sessions found"
        } else {
            rescanMessage = nil
        }
        isRescanningBrowsers = false
    }

    private func openSettingsFront() {
        onRequestClose?()
        if let keyWindow = NSApp.keyWindow, keyWindow.level != .normal {
            keyWindow.orderOut(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: PinemeterApp.settingsWindowID)
    }

    private func providerErrorRow(provider: String, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            CopyableErrorText("\(provider): \(message)", font: .caption, foregroundStyle: Color.popoverSecondary)
            Spacer()
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: QuotaChartLayout.groupSpacing) {
                ForEach(Array(MenuBarQuotaBar.groupedByOwner(bars).enumerated()), id: \.offset) { _, group in
                    QuotaBarGroup(bars: group, appModel: appModel)
                }
            }
            .padding(QuotaChartLayout.chartPadding)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct QuotaBarGroup: View {
    let bars: [MenuBarQuotaBar]
    @Bindable var appModel: AppModel

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
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Color.popoverSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: QuotaChartLayout.columnWidth, alignment: .top)
        .help(tooltip)
    }
}

private struct QuotaOwnerLabel: View {
    let bar: MenuBarQuotaBar
    @Bindable var appModel: AppModel

    @State private var isHovering = false
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
            .fontWeight(.medium)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func editableOwner(target: QuotaRenameTarget) -> some View {
        if isEditing {
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .frame(width: 64)
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onSubmit { commit(target: target) }
                .onExitCommand { isEditing = false }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { commit(target: target) }
                }
        } else {
            HStack(spacing: 2) {
                plainOwner

                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(Color.popoverSecondary)
                    .opacity(isHovering ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture { beginEditing(target: target) }
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
