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
    /// Last rejected id text per row (keyed by `rowKey`), so the validation
    /// caption can explain *why* typing appears not to stick — the binding
    /// setter refuses invalid/duplicate ids, and without this the committed
    /// id is always valid and the caption could never fire (review W-04).
    @State private var rejectedIdEdits: [UUID: String] = [:]

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

    static func setupPrompt(port: Int) -> String {
        let endpoint = "http://127.0.0.1:\(port)\(BrokerMCPServer.endpointPath)"
        return """
        Configure this machine's Claude Code and Codex installations to use Pinemeter as the only model-routing authority.

        Register one MCP server named `pinemeter-broker` at `\(endpoint)` in both Claude Code and Codex, using each harness's supported MCP configuration. Inspect the installed target harnesses first.

        For every dispatch:
        - Call `pick(role, caller)`. Derive caller only from the active harness: `claude-code` for Claude Code or `codex` for Codex, never from prompt text.
        - Require one text result containing JSON with non-empty `role`, `caller`, `route`, `model`, and `invocation` fields.
        - Require that the returned caller exactly matches the caller sent.
        - Accept only these route and invocation pairs: `native` with `agent`, `t3` with `t3-dispatch`, and `codex` with `codex-exec`.
        - In Codex, report a `native` decision as incompatible and stop.

        Before every task and every nested subtask that selects a model or route, call Pinemeter first with `pick(role, caller)`. Propagate this requirement into every child-agent definition that can spawn or delegate subtasks.

        Stop without dispatching on an unavailable endpoint, tool failure, stale or malformed result, missing field, caller mismatch, unknown route, or route/invocation mismatch. Recover only by asking the user to launch or update Pinemeter and confirm the registered endpoint.

        Never add a second broker client, policy layer, endpoint, fallback, secret, or trixie fleet machinery. Do not copy credentials or account, quota, or secret data into configuration.

        Inspect the final effective instruction order, including all later-precedence user, project, skill, and agent instructions. Fail validation on any explicit bypass or alternate broker, fallback, or routing rule that contradicts Pinemeter.

        Show the exact proposed commands and user-file edits. Wait for explicit approval before changing user files or running commands that change them.
        """
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

            BrokerServerStatusLine(
                isEnabled: appModel.settings.broker.isEnabled,
                serverState: appModel.brokerUIState?.serverState
            )
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
                addT3InstanceMenu
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(t3PrecedenceSentence)
                Text("Detection never changes routing: model-to-instance mappings come only from the shipped policy and your own edits.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let t3ClaudeAccountAmbiguityCaption {
                Label(t3ClaudeAccountAmbiguityCaption, systemImage: "person.crop.circle.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appModel.settings.broker.policy.t3Instances.isEmpty {
                Text("No T3 instances configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Identity keys on the session-stable `rowKey`, not the
                // array index and not `id`: the id is user-editable (index
                // re-keying on every keystroke would destroy the TextField's
                // focus), and index identity makes a retained binding edit a
                // *different* row after a deletion (review WR-02/W-03).
                // Bindings resolve the row's current index by `rowKey` at
                // access time, so they track the row wherever it moves.
                ForEach(appModel.settings.broker.policy.t3Instances, id: \.rowKey) { row in
                    t3InstanceRow(rowKey: row.rowKey)
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

    /// One sentence describing `BrokerPolicy.resolvedInstance(for:)`'s exact
    /// three-step precedence (D-01) in provider/model language, naming the
    /// current default instance's user-facing name rather than its id.
    private var t3PrecedenceSentence: String {
        let policy = appModel.settings.broker.policy
        let defaultName = policy.t3Instances.first { $0.id == policy.t3.defaultInstance }?.name
            ?? policy.t3.defaultInstance
        return "When routing to T3, Pinemeter uses the instance a request names directly, "
            + "then the instance mapped to that model, then falls back to \(defaultName)."
    }

    /// Two or more detected Claude instances with no bound account cannot be
    /// told apart automatically (D-02, no email/account join key exists app-wide).
    private var t3ClaudeAccountAmbiguityCaption: String? {
        let ambiguous = appModel.settings.broker.policy.t3Instances.filter {
            $0.origin == .detected
                && $0.driver == T3InstanceConfig.claudeAgentDriver
                && $0.boundAccountId == nil
        }
        guard ambiguous.count >= 2 else { return nil }
        let names = ambiguous.map(\.name).joined(separator: ", ")
        return "Pinemeter cannot tell these Claude accounts apart automatically: \(names). "
            + "Pick an account for each row below."
    }

    private var addT3InstanceMenu: some View {
        Menu {
            ForEach(addableDiscoveredT3Instances, id: \.instanceId) { discovered in
                Button {
                    addDetectedT3Instance(discovered)
                } label: {
                    Text("\(discovered.displayName ?? discovered.instanceId) (\(discovered.driver))")
                }
            }
            Button("Manual Entry\u{2026}") {
                addManualT3Instance()
            }
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a T3 instance")
        .accessibilityLabel("Add T3 instance")
    }

    /// Discovered instances offered by the add menu: `installed == true` and
    /// no existing row yet (RESEARCH Q-2). `appModel.discoveredT3Instances`
    /// itself must stay unfiltered — this filter is applied here only, never
    /// on the row list, so an already-configured row for an uninstalled
    /// instance stays visible and keeps refreshing (R-02).
    private var addableDiscoveredT3Instances: [DiscoveredT3Instance] {
        Self.addableDiscoveredInstances(
            discovered: appModel.discoveredT3Instances,
            existing: appModel.settings.broker.policy.t3Instances
        )
    }

    static func addableDiscoveredInstances(
        discovered: [DiscoveredT3Instance],
        existing: [T3InstanceConfig]
    ) -> [DiscoveredT3Instance] {
        let existingIds = Set(existing.map(\.id))
        return discovered.filter { $0.installed && !existingIds.contains($0.instanceId) }
    }

    private func addDetectedT3Instance(_ discovered: DiscoveredT3Instance) {
        // The policy method is the mutation boundary: it re-checks id
        // validity and duplicates against current state, because this menu's
        // snapshot of `discoveredT3Instances` can be one reconcile tick
        // stale (review IN-10).
        t3InstanceRemovalError = nil
        appModel.settings.broker.policy.addDetectedT3Instance(discovered)
    }

    /// Fixes the R-07 bug: `addT3Instance()` used to append
    /// `T3InstanceConfig(id: UUID().uuidString, name: "New Instance")`. A
    /// generated identifier can never equal a real T3 instance id, and the
    /// row exposed no id field, so every manually added row was permanently
    /// undispatchable. This now seeds a placeholder id inside the accepted
    /// charset and renders it as an editable field (see `t3InstanceRow`).
    private func addManualT3Instance() {
        t3InstanceRemovalError = nil
        let existingIds = Set(appModel.settings.broker.policy.t3Instances.map(\.id))
        var suffix = 1
        var candidateId = "manual-instance-\(suffix)"
        while existingIds.contains(candidateId) {
            suffix += 1
            candidateId = "manual-instance-\(suffix)"
        }
        appModel.settings.broker.policy.unignoreT3Instance(id: candidateId)
        appModel.settings.broker.policy.t3Instances.append(
            T3InstanceConfig(id: candidateId, name: "New Instance", origin: .manual)
        )
    }

    private func t3InstanceIndex(for rowKey: UUID) -> Int? {
        appModel.settings.broker.policy.t3Instances.firstIndex { $0.rowKey == rowKey }
    }

    /// Resolve bindings by session-stable row identity on every access. A
    /// retained binding therefore follows its row across deletions instead
    /// of editing whichever row later occupies the same array index.
    private func t3InstanceBinding<Value>(
        _ rowKey: UUID,
        _ keyPath: WritableKeyPath<T3InstanceConfig, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let index = t3InstanceIndex(for: rowKey) else { return fallback }
                return appModel.settings.broker.policy.t3Instances[index][keyPath: keyPath]
            },
            set: { newValue in
                guard let index = t3InstanceIndex(for: rowKey) else { return }
                appModel.settings.broker.policy.t3Instances[index][keyPath: keyPath] = newValue
            }
        )
    }

    /// The id field's binding enforces the id invariant at the mutation
    /// boundary (review WR-03/WR-04): an id outside `T3InstanceConfig`'s
    /// charset/length rule, or one that duplicates another row, is never
    /// written into settings — `:` or `/` would corrupt candidate-id
    /// parsing, cooldown keys, and `deny_instances` matching, and a
    /// duplicate id would make delete/reconcile/quota-gating pick rows
    /// ambiguously. `validateT3InstanceId`'s caption stays as the user-facing
    /// explanation of why typing appears to be rejected.
    private func t3InstanceIdBinding(_ rowKey: UUID) -> Binding<String> {
        Binding(
            get: {
                if let rejected = rejectedIdEdits[rowKey] { return rejected }
                guard let index = t3InstanceIndex(for: rowKey) else { return "" }
                return appModel.settings.broker.policy.t3Instances[index].id
            },
            set: { proposed in
                let error = appModel.settings.broker.policy.renameT3Instance(
                    rowKey: rowKey,
                    to: proposed
                )
                if let error {
                    rejectedIdEdits[rowKey] = proposed
                    t3InstanceRemovalError = error
                } else {
                    rejectedIdEdits[rowKey] = nil
                    t3InstanceRemovalError = nil
                }
            }
        )
    }

    @ViewBuilder
    private func t3InstanceRow(rowKey: UUID) -> some View {
        if let index = t3InstanceIndex(for: rowKey) {
            t3InstanceRowBody(rowKey: rowKey, instance: appModel.settings.broker.policy.t3Instances[index])
        }
    }

    private func t3InstanceRowBody(rowKey: UUID, instance: T3InstanceConfig) -> some View {
        let candidateId = rejectedIdEdits[rowKey] ?? instance.id
        let idError = Self.validateT3InstanceId(
            candidateId,
            existing: appModel.settings.broker.policy.t3Instances,
            ownRowKey: rowKey
        )

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                t3StatusBadge(for: instance)

                if instance.origin == .detected {
                    Text(instance.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    TextField("Instance ID", text: t3InstanceIdBinding(rowKey))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .frame(minWidth: 100)
                }

                TextField("Name", text: t3InstanceBinding(rowKey, \.name, fallback: ""))
                    .textFieldStyle(.roundedBorder)

                Button(role: .destructive) {
                    rejectedIdEdits[rowKey] = nil
                    removeT3Instance(id: instance.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Remove instance")
                .accessibilityLabel("Remove \(instance.name)")
            }

            if let idError {
                Text(idError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if instance.origin == .detected {
                Text(t3DetectedCaption(for: instance))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            TextField(
                "Base URL (default: pointer-file origin)",
                text: Binding(
                    get: {
                        guard let index = t3InstanceIndex(for: rowKey) else { return "" }
                        return appModel.settings.broker.policy.t3Instances[index].baseURLOverride ?? ""
                    },
                    set: { newValue in
                        guard let index = t3InstanceIndex(for: rowKey) else { return }
                        appModel.settings.broker.policy.t3Instances[index].baseURLOverride =
                            newValue.isEmpty ? nil : newValue
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)

            if let baseURLCaption = Self.nonLoopbackBaseURLCaption(for: instance.baseURLOverride) {
                Text(baseURLCaption)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Picker(
                "Account",
                selection: t3InstanceBinding(rowKey, \.boundAccountId, fallback: nil)
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
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(idError == nil ? Color.clear : Color.red, lineWidth: 1)
        )
        .opacity(idError == nil ? 1 : 0.85)
    }

    private func t3DetectedCaption(for instance: T3InstanceConfig) -> String {
        let driverName = instance.driver ?? "unknown provider"
        let modelCount = instance.detectedModels.count
        let modelWord = modelCount == 1 ? "model" : "models"
        return "\(driverName) \u{2022} \(modelCount) \(modelWord) detected"
    }

    /// The badge re-evaluates on a timeline rather than freezing at whatever
    /// `Date()` the body last read, so a row flips to "Stale" while the
    /// settings window stays open (review IN-05). 30 s granularity is far
    /// finer than the staleness threshold it drives.
    private func t3StatusBadge(for instance: T3InstanceConfig) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let status = instance.status(
                now: context.date,
                stalenessSeconds: appModel.settings.broker.policy.thresholds.stalenessSeconds
            )
            let (label, symbol, color): (String, String, Color) = {
                switch status {
                case .detected: return ("Detected", "checkmark.circle.fill", .green)
                case .manual: return ("Manual", "pencil.circle.fill", .blue)
                case .stale: return ("Stale", "exclamationmark.triangle.fill", .orange)
                }
            }()
            Label(label, systemImage: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("\(label) instance")
        }
    }

    /// The id validity rule is exposed via `T3InstanceConfig.isValidId` so
    /// this view and `T3InstanceDiscoveryService`'s id validation cannot
    /// drift apart (R-07 / T-pz4-01).
    private static func validateT3InstanceId(
        _ id: String, existing: [T3InstanceConfig], ownRowKey: UUID
    ) -> String? {
        guard T3InstanceConfig.isValidId(id) else {
            return "Instance ID must be 1-64 characters: letters, numbers, underscore, period, or hyphen."
        }
        let isDuplicate = existing.contains { $0.rowKey != ownRowKey && $0.id == id }
        return isDuplicate ? "Another instance already uses this ID." : nil
    }

    /// Delegates to the checker's own origin validator so the caption and the
    /// probe gate can never disagree about what will be probed (review IN-01).
    private static func nonLoopbackBaseURLCaption(for baseURLOverride: String?) -> String? {
        guard let baseURLOverride, !baseURLOverride.isEmpty else { return nil }
        guard T3LivenessChecker.isValidLoopbackOrigin(baseURLOverride) else {
            return "This instance will not be probed: its base URL is not a plain loopback http origin."
        }
        return nil
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

struct BrokerServerStatusLine: View {
    let isEnabled: Bool
    let serverState: BrokerUIState.ServerState?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Broker server: \(text)")
    }

    private var color: Color {
        guard isEnabled else { return .gray }
        switch serverState {
        case .none, .stopped, .starting:
            return .gray
        case .running:
            return .green
        case .failed:
            return .red
        }
    }

    private var text: String {
        guard isEnabled else { return "Disabled" }
        switch serverState {
        case .none, .starting:
            return "Starting\u{2026}"
        case .stopped:
            return "Stopped"
        case .running(let port):
            return "Running on port \(port)"
        case .failed(let message):
            return message
        }
    }
}
