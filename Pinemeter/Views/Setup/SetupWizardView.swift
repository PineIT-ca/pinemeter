import SwiftUI
import AppKit

struct SetupWizardView: View {
    @Bindable var appModel: AppModel

    @State private var isValidating: Bool = false
    @State private var isImporting: Bool = false
    @State private var errorMessage: String?
    @State private var offersFullDiskAccessSettings: Bool = false
    @State private var hasValidationSucceeded: Bool = false
    @State private var successMessage: String?
    @State private var activeCredentialActionProvider: CredentialProvider?
    @State private var activeCredentialActionKind: ProviderCredentialActionKind?
    @State private var scanOutcome: BrowserScanOutcome?

    var body: some View {
        let statuses = appModel.providerCredentialStatuses

        VStack(spacing: 18) {
            VStack(spacing: 8) {
                if let appIcon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)
                }

                Text("Welcome to Pinemeter")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Connect your Claude session key and provider credentials to monitor LLM plan usage.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 30)

            VStack(spacing: 12) {
                ForEach(statuses) { status in
                    credentialStatusCard(status)
                }
            }
            .padding(.horizontal, 32)

            if let errorMessage = errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .frame(width: 20)
                        CopyableErrorText(errorMessage, font: .callout, foregroundStyle: .orange, lineLimit: 3)
                    }

                    if offersFullDiskAccessSettings {
                        Button("Open Full Disk Access") {
                            SystemSettingsOpener.openFullDiskAccess()
                        }
                        .controlSize(.small)
                        .padding(.leading, 28)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 32)
                .accessibilityLabel("Error: \(errorMessage)")
            }

            if hasValidationSucceeded, let successMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(successMessage)
                        .font(.callout)
                        .foregroundColor(.green)
                }
                .padding(12)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 32)
            }

            browserImportActions
        }
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func credentialStatusCard(_ status: AppProviderCredentialStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: credentialStatusIcon(for: status.state.health))
                .foregroundStyle(credentialStatusColor(for: status.state.health))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(status.setupPromptTitle)
                        .font(.headline)
                    Spacer()
                    Text(status.stateText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(credentialStatusColor(for: status.state.health))
                }

                Text(status.detailText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastFailureTitle = status.lastFailureTitle {
                    CopyableErrorText(lastFailureTitle, font: .caption2, foregroundStyle: .orange)
                }

                providerCredentialStatusActions(for: status)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func providerCredentialStatusActions(for status: AppProviderCredentialStatus) -> some View {
        let visibleActions = status.actions.filter { $0.kind != .reconnect }

        if !visibleActions.isEmpty {
            HStack(spacing: 8) {
                ForEach(visibleActions) { action in
                    Button(credentialActionTitle(action.kind, for: status)) {
                        handleCredentialAction(action.kind, for: status)
                    }
                    .controlSize(.small)
                    .disabled(isCredentialActionDisabled(for: status))
                }

                Spacer()
            }
        }
    }

    private func credentialStatusIcon(for health: CredentialHealthState) -> String {
        switch health {
        case .valid:
            return "checkmark.circle.fill"
        case .refreshRecommended:
            return "clock.badge.exclamationmark"
        case .validating:
            return "arrow.triangle.2.circlepath.circle"
        case .invalid, .expired, .unavailable:
            return "exclamationmark.triangle.fill"
        case .missing, .unknown:
            return "questionmark.circle"
        }
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

    private var browserImportActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import browser sessions")
                .font(.subheadline.weight(.semibold))

            Text("Open Chrome, Safari, or Firefox and sign in to the services you want to track, then scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: {
                Task { await scanOpenBrowsers() }
            }) {
                HStack {
                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isImporting ? (appModel.importProgress ?? "Scanning\u{2026}") : "Scan open browsers")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
            .accessibilityLabel("Scan open browsers")
            .accessibilityHint("Checks Claude and ChatGPT sessions in all open browsers")

            if let scanOutcome, !isImporting {
                scanResultsView(scanOutcome)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
    }

    @ViewBuilder
    private func scanResultsView(_ outcome: BrowserScanOutcome) -> some View {
        if outcome.results.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "safari")
                    .foregroundStyle(.secondary)
                Text("No open browsers detected. Open Chrome, Safari, or Firefox and try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(outcome.results, id: \.source) { result in
                    HStack(spacing: 6) {
                        Image(systemName: result.importedCount > 0 ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(result.importedCount > 0 ? .green : .secondary)
                            .font(.caption)
                        Text(scanResultLabel(for: result))
                            .font(.caption)
                            .foregroundStyle(result.importedCount > 0 ? .primary : .secondary)
                    }
                }
            }
        }
    }

    private func scanResultLabel(for result: BrowserScanOutcome.BrowserResult) -> String {
        var imported: [String] = []
        if case .imported = result.claude { imported.append("Claude") }
        if case .imported = result.chatGPT { imported.append("ChatGPT") }
        if imported.isEmpty {
            return "\(result.source.displayName): no sessions found"
        }
        return "\(result.source.displayName): \(imported.joined(separator: ", "))"
    }

    private var isBusy: Bool {
        isValidating || isImporting || activeCredentialActionProvider != nil
    }

    @MainActor
    private func scanOpenBrowsers() async {
        isImporting = true
        scanOutcome = nil
        activeCredentialActionProvider = nil
        activeCredentialActionKind = nil
        errorMessage = nil
        offersFullDiskAccessSettings = false
        hasValidationSucceeded = false
        successMessage = nil

        let outcome = await appModel.importFromOpenBrowsers()
        scanOutcome = outcome
        offersFullDiskAccessSettings = outcome.offersFullDiskAccessSettings

        if outcome.totalImported > 0 {
            var imported: [String] = []
            if outcome.claudeImported { imported.append("Claude") }
            if outcome.chatGPTImported { imported.append("ChatGPT") }
            successMessage = "Imported \(imported.joined(separator: " and "))."
            hasValidationSucceeded = true
        }

        if outcome.results.isEmpty {
            errorMessage = nil
        } else if outcome.totalImported == 0 {
            errorMessage = "No sessions found in open browsers. Sign in to Claude or ChatGPT in your browser, then scan again."
        }

        isImporting = false
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
        isValidating = true
        activeCredentialActionProvider = status.provider
        activeCredentialActionKind = kind
        errorMessage = nil
        offersFullDiskAccessSettings = false
        hasValidationSucceeded = false
        successMessage = "\(status.providerName): \(progressMessage(for: kind))"

        do {
            let state = try await appModel.performProviderCredentialAction(kind, for: status.provider)
            if state.isUsable {
                successMessage = "\(status.providerName): \(successDetailMessage(for: kind, credentialName: status.credentialName))"
                hasValidationSucceeded = true
            } else if kind == .clear {
                successMessage = "\(status.providerName): Cleared saved \(status.credentialName)."
                hasValidationSucceeded = true
            } else {
                let refreshedStatus = appModel.providerCredentialStatuses.first { $0.provider == status.provider }
                successMessage = nil
                errorMessage = "\(status.providerName): \(refreshedStatus?.recoverySuggestion ?? refreshedStatus?.detailText ?? "Recovery action did not restore access.")"
            }
        } catch {
            successMessage = nil
            errorMessage = "\(status.providerName): Failed to \(kind.displayTitle.lowercased()) \(status.credentialName): \(error.localizedDescription)"
        }

        activeCredentialActionProvider = nil
        activeCredentialActionKind = nil
        isValidating = false
    }

    private func credentialActionTitle(_ kind: ProviderCredentialActionKind, for status: AppProviderCredentialStatus) -> String {
        guard activeCredentialActionProvider == status.provider && activeCredentialActionKind == kind else {
            return kind.displayTitle
        }

        switch kind {
        case .reconnect:
            return "Reconnecting \(status.providerName)..."
        case .repair:
            return "Repairing \(status.providerName)..."
        case .clear:
            return "Clearing \(status.providerName)..."
        }
    }

    private func isCredentialActionDisabled(for status: AppProviderCredentialStatus) -> Bool {
        isBusy || status.state.health == .validating
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

    private func successDetailMessage(for kind: ProviderCredentialActionKind, credentialName: String) -> String {
        switch kind {
        case .reconnect:
            return "Reconnected saved \(credentialName)."
        case .repair:
            return "Repaired saved \(credentialName)."
        case .clear:
            return "Cleared saved \(credentialName)."
        }
    }
}
