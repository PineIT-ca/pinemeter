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
    }

    // MARK: - Access

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "Access",
                systemImage: "network",
                subtitle: "Which machines can reach the broker's MCP endpoint."
            )

            Picker("Reachable from", selection: $appModel.settings.broker.networkAccess) {
                Text("This Mac only (loopback)").tag(BrokerNetworkAccess.loopback)
                Text("Local network").tag(BrokerNetworkAccess.network)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel("Broker network access")

            Text(
                networkAccess == .network
                    ? "The server binds every interface (0.0.0.0), so other machines — T3 servers and "
                        + "clients, for instance — can call http://<this-mac>:\(appModel.settings.broker.port)/mcp."
                    : "The server binds 127.0.0.1 only. Agents on this Mac can reach it; nothing on the "
                        + "network can."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if networkAccess == .network && apiKeyMode == .none {
                Label(
                    "Anyone on this network can use the broker. Require an API key below.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.yellow)
                .fixedSize(horizontal: false, vertical: true)
                .brokerInsetRow()
                .accessibilityLabel(
                    "Warning: anyone on this network can use the broker. Require an API key below."
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

            Picker("Required for", selection: $appModel.settings.broker.apiKeyMode) {
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

            Button("Regenerate") {
                Task { await appModel.regenerateBrokerAPIKey() }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Regenerate the API key")
        }
        .brokerInsetRow()
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
}
