//
//  BrokerNetworkPane.swift
//  Pinemeter
//
//  Who can reach the broker, and what they have to present to use it.
//
//  Two controls, in the order the decision is actually made: first "can other
//  machines see this at all", then "what do callers have to prove". They are
//  on one pane because they are one decision — turning the first on without
//  reading the second is exactly the mistake the warning row at the bottom
//  exists to catch.
//

import AppKit
import SwiftUI

struct BrokerNetworkPane: View {
    @Bindable var appModel: AppModel

    @State private var didCopyKey = false
    @State private var isKeyRevealed = false
    @State private var isRegenerateConfirmationPresented = false
    @State private var isRegeneratingKey = false
    @State private var pendingUnsafeTransition: UnsafeTransition?

    private enum UnsafeTransition {
        case networkWithoutAPIKey
        case noAPIKeyOnNetwork

        var title: String {
            switch self {
            case .networkWithoutAPIKey: "Allow Access Without a Key?"
            case .noAPIKeyOnNetwork: "Remove the API Key Requirement?"
            }
        }

        var actionTitle: String {
            switch self {
            case .networkWithoutAPIKey: "Allow Unauthenticated Access"
            case .noAPIKeyOnNetwork: "Do Not Require a Key"
            }
        }

        var message: String {
            "The broker will accept unauthenticated requests on every network interface. "
                + "Any client that can reach this Mac can use the broker."
        }
    }

    private var networkAccess: BrokerNetworkAccess {
        appModel.settings.broker.networkAccess
    }

    private var apiKeyMode: BrokerAPIKeyMode {
        appModel.settings.broker.apiKeyMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrokerUI.sectionSpacing) {
            accessSection
            apiKeySection
        }
        // A mode that needs a key can be restored from a previous launch, so
        // the key is provisioned on appearance rather than only on change.
        .task {
            if apiKeyMode != .none, appModel.brokerAPIKey == nil {
                await appModel.ensureBrokerAPIKey()
            }
        }
        .confirmationDialog(
            pendingUnsafeTransition?.title ?? "",
            isPresented: unsafeTransitionPresented,
            titleVisibility: .visible
        ) {
            if let pendingUnsafeTransition {
                Button(pendingUnsafeTransition.actionTitle, role: .destructive) {
                    apply(pendingUnsafeTransition)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingUnsafeTransition = nil
            }
        } message: {
            Text(pendingUnsafeTransition?.message ?? "")
        }
    }

    // MARK: - Access

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "Access",
                systemImage: "network",
                subtitle: "Which machines can reach the broker's MCP endpoint."
            )

            Picker("Reachable from", selection: networkAccessSelection) {
                Text("This Mac only (loopback)").tag(BrokerNetworkAccess.loopback)
                Text("All network interfaces").tag(BrokerNetworkAccess.network)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel("Broker network access")

            Text(
                networkAccess == .network
                    ? "The server binds every network interface (0.0.0.0). Any client that can reach "
                        + "this Mac can call http://<this-mac>:\(appModel.settings.broker.port)/mcp."
                    : "The server binds 127.0.0.1 only. Agents on this Mac can reach it; nothing on the "
                        + "network can."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if networkAccess == .network && apiKeyMode == .none {
                Label(
                    "Anyone who can reach this Mac can use the broker. Require an API key below.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .brokerInsetRow()
                .accessibilityLabel(
                    "Warning: anyone who can reach this Mac can use the broker. Require an API key below."
                )
            }
        }
        .brokerCard()
    }

    // MARK: - API key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "API Key",
                systemImage: "key",
                subtitle: "When a caller has to present the key. It is stored in your Keychain and "
                    + "never written to settings."
            )

            Picker("Required for", selection: apiKeyModeSelection) {
                Text("Not required").tag(BrokerAPIKeyMode.none)
                Text("Non-localhost connections").tag(BrokerAPIKeyMode.nonLoopback)
                Text("All connections").tag(BrokerAPIKeyMode.all)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel("Broker API key requirement")

            if apiKeyMode != .none {
                keyRow



                Text(
                    "Clients send `Authorization: Bearer <key>`, or `X-API-Key: <key>`. Regenerating "
                        + "invalidates the old key for every client still holding it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage = appModel.brokerAPIKeyErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(errorMessage)")
            }
        }
        .brokerCard()
    }

    private var keyRow: some View {
        HStack(spacing: 8) {
            Text(displayedKey)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(
                    appModel.brokerAPIKey == nil ? "No API key yet" : "Broker API key"
                )

            Button {
                isKeyRevealed.toggle()
            } label: {
                Image(systemName: isKeyRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .disabled(appModel.brokerAPIKey == nil)
            .help(isKeyRevealed ? "Hide the key" : "Show the key")
            .accessibilityLabel(isKeyRevealed ? "Hide the API key" : "Show the API key")

            Button {
                copyKey()
            } label: {
                Label(didCopyKey ? "Copied" : "Copy", systemImage: didCopyKey ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(appModel.brokerAPIKey == nil)
            .accessibilityLabel(didCopyKey ? "API key copied" : "Copy the API key")

            Button {
                isRegenerateConfirmationPresented = true
            } label: {
                HStack(spacing: 6) {
                    if isRegeneratingKey {
                        ProgressView()
                            .controlSize(.small)
                        Text("Regenerating…")
                    } else {
                        Text("Regenerate")
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRegeneratingKey)
            .accessibilityLabel(isRegeneratingKey ? "Regenerating the API key" : "Regenerate the API key")
        }
        .brokerInsetRow()
        .confirmationDialog(
            "Regenerate API Key?",
            isPresented: $isRegenerateConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Regenerate API Key", role: .destructive) {
                Task { await regenerateKey() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current key will stop working immediately. Every client must be updated with the new key.")
        }
    }

    /// Redacted until asked for: the pane is opened to change a setting far
    /// more often than to read the key, and a settings window is a screen
    /// other people look at.
    private var displayedKey: String {
        guard let key = appModel.brokerAPIKey else { return "…" }
        return isKeyRevealed ? key : String(repeating: "•", count: 24)
    }

    private func copyKey() {
        guard let key = appModel.brokerAPIKey else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // The concealed marker keeps clipboard managers from persisting the
        // key alongside ordinary copied text.
        pasteboard.setString(key, forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        guard pasteboard.setString(key, forType: .string) else { return }
        didCopyKey = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyKey = false
        }
    }

    private var networkAccessSelection: Binding<BrokerNetworkAccess> {
        Binding(
            get: { networkAccess },
            set: { requestedAccess in
                if requestedAccess == .network, apiKeyMode == .none {
                    pendingUnsafeTransition = .networkWithoutAPIKey
                } else {
                    appModel.settings.broker.networkAccess = requestedAccess
                }
            }
        )
    }

    private var apiKeyModeSelection: Binding<BrokerAPIKeyMode> {
        Binding(
            get: { apiKeyMode },
            set: { requestedMode in
                if requestedMode == .none, networkAccess == .network {
                    pendingUnsafeTransition = .noAPIKeyOnNetwork
                } else {
                    appModel.settings.broker.apiKeyMode = requestedMode
                }
            }
        )
    }

    private var unsafeTransitionPresented: Binding<Bool> {
        Binding(
            get: { pendingUnsafeTransition != nil },
            set: { isPresented in
                if !isPresented {
                    pendingUnsafeTransition = nil
                }
            }
        )
    }

    private func apply(_ transition: UnsafeTransition) {
        switch transition {
        case .networkWithoutAPIKey:
            appModel.settings.broker.networkAccess = .network
        case .noAPIKeyOnNetwork:
            appModel.settings.broker.apiKeyMode = .none
        }
        pendingUnsafeTransition = nil
    }

    private func regenerateKey() async {
        isRegeneratingKey = true
        defer { isRegeneratingKey = false }
        guard await appModel.regenerateBrokerAPIKey() else { return }
        didCopyKey = false
        isKeyRevealed = false
    }
}
