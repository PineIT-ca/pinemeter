//
//  BrokerSettingsTab.swift
//  Pinemeter
//
//  D-05/D-09 Broker settings tab: server controls, T3 instances, recent
//  picks, and (Task 3) the structured policy editor. Follows the sibling
//  tabs' `.padding()/.background(.quaternary.opacity(0.3))/clipShape` card
//  section chrome (see SettingsView's General tab).
//

import SwiftUI

struct BrokerSettingsTab: View {
    @Bindable var appModel: AppModel

    @State private var recentPicks: [RecentPick]
    @State private var t3InstanceRemovalError: String?

    /// `initialRecentPicks` is a test seam: production call sites always use
    /// the default `[]` and let `.task(id:)` populate the real ring buffer
    /// asynchronously. Snapshot tests inject a canned array directly so the
    /// rendered image doesn't race an off-screen `NSHostingView`'s SwiftUI
    /// lifecycle, which never reliably pumps `.task` before capture.
    init(appModel: AppModel, initialRecentPicks: [RecentPick] = []) {
        self.appModel = appModel
        self._recentPicks = State(initialValue: initialRecentPicks)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                serverSection
                t3InstancesSection
                recentPicksSection
                BrokerPolicyEditorView(appModel: appModel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .task(id: appModel.brokerUIState?.lastPickSummary) {
            recentPicks = await appModel.brokerRecentPicks()
        }
        .onChange(of: appModel.settings.broker.isEnabled) { _, _ in
            Task { await appModel.applyBrokerSettingsChange() }
        }
        .onChange(of: appModel.settings.broker.port) { _, _ in
            Task { await appModel.applyBrokerSettingsChange() }
        }
        .onChange(of: appModel.settings.broker.policy) { _, _ in
            Task { await appModel.applyBrokerSettingsChange() }
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server")
                        .font(.subheadline)
                    Text("Runs a local MCP server so coding agents can pick a model/route through it (D-08).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $appModel.settings.broker.isEnabled)
                    .labelsHidden()
            }

            HStack {
                Text("Port")
                    .font(.subheadline)
                Spacer()
                TextField("", value: $appModel.settings.broker.port, formatter: Self.portFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .disabled(!appModel.settings.broker.isEnabled)
                    .accessibilityLabel("Broker port")
            }

            statusLine
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private static let portFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1024
        formatter.maximum = 65535
        formatter.hasThousandSeparators = false
        return formatter
    }()

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        guard appModel.settings.broker.isEnabled else { return .gray }
        switch appModel.brokerUIState?.serverState {
        case .none, .stopped, .starting:
            return .gray
        case .running:
            return .green
        case .failed:
            return .red
        }
    }

    private var statusText: String {
        guard appModel.settings.broker.isEnabled else { return "Disabled" }
        switch appModel.brokerUIState?.serverState {
        case .none:
            return "Starting\u{2026}"
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting\u{2026}"
        case .running(let port):
            return "Running on port \(port)"
        case .failed(let message):
            return message
        }
    }

    // MARK: - T3 Instances

    private var t3InstancesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("T3 Instances")
                        .font(.subheadline)
                    Text("Provider instances the broker's t3 route can dispatch to.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: addT3Instance) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("Add a T3 instance")
                .accessibilityLabel("Add T3 instance")
            }

            if appModel.settings.broker.policy.t3Instances.isEmpty {
                Text("No T3 instances configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($appModel.settings.broker.policy.t3Instances) { $instance in
                    t3InstanceRow(instance: $instance)
                }
            }

            if let t3InstanceRemovalError {
                Label(t3InstanceRemovalError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func t3InstanceRow(instance: Binding<T3InstanceConfig>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: instance.name)
                    .textFieldStyle(.roundedBorder)

                Button(role: .destructive) {
                    removeT3Instance(id: instance.wrappedValue.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Remove instance")
                .accessibilityLabel("Remove \(instance.wrappedValue.name)")
            }

            TextField(
                "Base URL (default: pointer-file origin)",
                text: Binding(
                    get: { instance.wrappedValue.baseURLOverride ?? "" },
                    set: { instance.wrappedValue.baseURLOverride = $0.isEmpty ? nil : $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)

            Picker(
                "Account",
                selection: Binding(
                    get: { instance.wrappedValue.boundAccountId },
                    set: { instance.wrappedValue.boundAccountId = $0 }
                )
            ) {
                Text("None").tag(String?.none)
                ForEach(appModel.settings.claudeAccounts) { account in
                    Text(account.displayLabel).tag(String?.some(account.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func addT3Instance() {
        appModel.settings.broker.policy.t3Instances.append(
            T3InstanceConfig(id: UUID().uuidString, name: "New Instance")
        )
    }

    private func removeT3Instance(id: String) {
        t3InstanceRemovalError = appModel.settings.broker.policy.removeT3Instance(id: id)
    }

    // MARK: - Recent Picks

    private var recentPicksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent Picks")
                    .font(.subheadline)
                Text("The last routing decisions the broker made (D-09).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if recentPicks.isEmpty {
                Text("No picks yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(recentPicks.enumerated()), id: \.offset) { _, pick in
                        recentPickRow(pick)
                    }
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func recentPickRow(_ pick: RecentPick) -> some View {
        HStack(spacing: 8) {
            Text(pick.timestamp, style: .relative)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(pick.role)
                .font(.caption)
                .fontWeight(.medium)

            Text(pick.candidate)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(pick.route)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(6)

            if pick.degraded {
                Text("Degraded")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .cornerRadius(6)
            }
        }
    }
}
