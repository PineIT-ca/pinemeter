import SwiftUI
import AppKit

/// Two independent entry points: monitor accounts or configure model routing.
struct SetupWizardView: View {
    @Bindable var appModel: AppModel
    var onRequestClose: () -> Void = {}
    var onScanStarted: () -> Void = {}
    var onContinue: () -> Void = {}
    @Environment(\.openWindow) private var openWindow
    @State private var isImporting = false
    @State private var scanOutcome: BrowserScanOutcome?
    @State private var browserImportReview: BrowserSessionImportReview?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                            .resizable()
                            .frame(width: 56, height: 56)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Welcome to Pinemeter")
                                .font(.title2.weight(.semibold))
                            Text("Know your limits. Choose your next model.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("See what you have left. Choose the right model for your next task. Start with either, or use both.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Monitor your accounts", systemImage: "chart.bar.xaxis")
                            .font(.headline)
                        Text("Track Claude and ChatGPT usage and reset times. Sign in to the accounts you want to connect in Chrome, Safari, or Firefox.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task { await scanOpenBrowsers() }
                        } label: {
                            HStack(spacing: 8) {
                                if isImporting { ProgressView().controlSize(.small) }
                                Text(isImporting ? (appModel.importProgress ?? "Scanning…") : "Connect browser accounts")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isImporting)
                        Text("Pinemeter reads signed-in browser sessions to retrieve usage. macOS may ask for permission. Saved credentials stay in your Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Connect Gemini with an API key…") { openSettings(.accounts) }
                            .buttonStyle(.link)
                            .disabled(isImporting)
                        if let scanOutcome { scanResults(scanOutcome) }
                    }
                    .brokerCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Set up model routing", systemImage: "arrow.triangle.branch")
                            .font(.headline)
                        Text("Connect Claude Code or Codex to Pinemeter. Your agent can then choose a model using your preferences and available capacity.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { openSettings(.broker) } label: {
                            Text("Set up the broker…").frame(maxWidth: .infinity)
                        }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(isImporting)
                        Text("Routing can work without usage accounts. Connect them to check remaining quota and avoid routing without verified capacity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .brokerCard()
                }
                .padding(24)
            }
            .frame(maxHeight: 580)

            if appModel.hasConfiguredUsageProvider && !isImporting {
                Button("Continue to dashboard", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.bottom, 16)
            }

            Divider()
            HStack {
                Button("Settings…") { openSettings(.accounts) }
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit Pinemeter") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.borderless)
            .padding(16)
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $browserImportReview) { review in
            BrowserSessionImportReviewView(
                appModel: appModel,
                review: review,
                onConnected: { outcome in
                    scanOutcome = outcome
                    browserImportReview = nil
                },
                onCancel: { browserImportReview = nil }
            )
        }
    }

    @ViewBuilder
    private func scanResults(_ outcome: BrowserScanOutcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if outcome.totalImported > 0 {
                Label("Accounts connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(outcome.results.isEmpty ? "Open a browser to connect" : "No accounts connected", systemImage: "info.circle")
                Text("Sign in to Claude or ChatGPT in your browser, then try again. You can also manage connections in Accounts settings.")
                    .foregroundStyle(.secondary)
            }
            if !outcome.results.isEmpty {
                DisclosureGroup("Connection details") {
                    ForEach(outcome.results, id: \.source) { result in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(result.source.displayName).fontWeight(.medium)
                            importResult(result.claude, provider: "Claude")
                            importResult(result.chatGPT, provider: "ChatGPT")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            if outcome.offersFullDiskAccessSettings {
                Text("Safari access was blocked. Allow Full Disk Access for Pinemeter, then scan again.")
                    .foregroundStyle(.secondary)
                Button("Open Full Disk Access…") { SystemSettingsOpener.openFullDiskAccess() }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func importResult(_ result: ProviderBrowserImportStatus, provider: String) -> some View {
        switch result {
        case .imported:
            Label("\(provider) connected", systemImage: "checkmark.circle")
        case .failed(let message, _):
            let errorMessage = "\(provider): \(message)"
            CopyableErrorText(errorMessage, font: .caption)
        case .notSelected:
            EmptyView()
        }
    }

    private func scanOpenBrowsers() async {
        onScanStarted()
        isImporting = true
        scanOutcome = nil
        browserImportReview = await appModel.discoverBrowserSessions()
        isImporting = false
    }

    private func openSettings(_ tab: SettingsView.Tab) {
        SettingsView.selectTab(tab)
        onRequestClose()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: PinemeterApp.settingsWindowID)
    }
}
