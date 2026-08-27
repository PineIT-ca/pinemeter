//
//  BrokerInstancesPane.swift
//  Pinemeter
//
//  This Mac's T3 provider instances: what exists, whether it answers, and
//  whose quota gates it.
//
//  Everything in this pane is machine state that no profile may carry, which
//  is exactly the line that decides what belongs here. The two settings that
//  decide WHERE a t3 candidate lands (`default_instance`, `instance_by_model`)
//  are routing rules a profile does carry, so they live in the Routing pane —
//  see `BrokerInstanceResolutionCard`.
//
//  The account picker is the reason this is a pane and not a hidden advanced
//  screen: discovery can never infer which Pinemeter account a T3 lane belongs
//  to (D-02), the shipped seed ships unbound, and an unbound Claude lane has
//  no quota to gate on. Every user has to come here at least once.
//

import SwiftUI

struct BrokerInstancesPane: View {
    @Bindable var appModel: AppModel

    @State private var removalError: String?
    /// Last rejected id text per row (keyed by `rowKey`), so the validation
    /// caption can explain *why* typing appears not to stick — the binding
    /// setter refuses invalid/duplicate ids, and without this the committed
    /// id is always valid and the caption could never fire (review W-04).
    @State private var rejectedIdEdits: [UUID: String] = [:]
    @State private var expandedAdvancedRows: Set<UUID> = []

    private var policy: BrokerPolicy { appModel.settings.broker.policy }

    var body: some View {
        instancesCard
    }

    // MARK: - Instances

    private var instancesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "T3 Instances",
                systemImage: "server.rack",
                subtitle: "The provider instances the broker's t3 route can dispatch to. "
                    + "Detection refreshes what an instance is; it never changes where anything routes.",
                help: .instances
            ) {
                addInstanceMenu
            }

            if let ambiguityCaption = claudeAccountAmbiguityCaption {
                Label(ambiguityCaption, systemImage: "person.crop.circle.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if policy.t3Instances.isEmpty {
                BrokerEmptyState(
                    title: "No T3 instances",
                    systemImage: "server.rack",
                    hint: "Add one with the + button. Installed instances Pinemeter has detected "
                        + "appear in that menu."
                )
            } else {
                // Identity keys on the session-stable `rowKey`, not the array
                // index and not `id`: the id is user-editable (index re-keying
                // on every keystroke would destroy the TextField's focus), and
                // index identity makes a retained binding edit a *different*
                // row after a deletion (review WR-02/W-03). Bindings resolve
                // the row's current index by `rowKey` at access time, so they
                // track the row wherever it moves.
                VStack(spacing: 6) {
                    ForEach(policy.t3Instances, id: \.rowKey) { row in
                        instanceRow(rowKey: row.rowKey)
                    }
                }
            }

            if let removalError {
                Label(removalError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .brokerCard()
    }

    private var addInstanceMenu: some View {
        Menu {
            if addableDiscoveredInstances.isEmpty {
                Text("No undetected instances available")
            } else {
                Section("Detected") {
                    ForEach(addableDiscoveredInstances, id: \.instanceId) { discovered in
                        Button {
                            addDetectedInstance(discovered)
                        } label: {
                            Text("\(discovered.displayName ?? discovered.instanceId) (\(discovered.driver))")
                        }
                    }
                }
            }
            Divider()
            Button("Manual Entry\u{2026}") { addManualInstance() }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a T3 instance")
        .accessibilityLabel("Add T3 instance")
    }

    /// Discovered instances offered by the add menu: `installed == true` and
    /// no existing row yet (RESEARCH Q-2). `appModel.discoveredT3Instances`
    /// itself must stay unfiltered — this filter is applied here only, never
    /// on the row list, so an already-configured row for an uninstalled
    /// instance stays visible and keeps refreshing (R-02).
    private var addableDiscoveredInstances: [DiscoveredT3Instance] {
        BrokerSettingsTab.addableDiscoveredInstances(
            discovered: appModel.discoveredT3Instances,
            existing: policy.t3Instances
        )
    }

    /// Two or more detected Claude instances with no bound account cannot be
    /// told apart automatically (D-02, no email/account join key exists app-wide).
    private var claudeAccountAmbiguityCaption: String? {
        let ambiguous = policy.t3Instances.filter {
            $0.origin == .detected
                && $0.driver == T3InstanceConfig.claudeAgentDriver
                && $0.boundAccountId == nil
        }
        guard ambiguous.count >= 2 else { return nil }
        let names = ambiguous.map(\.name).joined(separator: ", ")
        return "Pinemeter cannot tell these Claude accounts apart automatically: \(names). "
            + "Pick an account for each row below."
    }

    // MARK: - Instance row

    @ViewBuilder
    private func instanceRow(rowKey: UUID) -> some View {
        if let index = instanceIndex(for: rowKey) {
            instanceRowBody(rowKey: rowKey, instance: policy.t3Instances[index])
        }
    }

    private func instanceRowBody(rowKey: UUID, instance: T3InstanceConfig) -> some View {
        let candidateId = rejectedIdEdits[rowKey] ?? instance.id
        let idError = Self.validateInstanceId(
            candidateId,
            existing: policy.t3Instances,
            ownRowKey: rowKey
        )
        let reachable = appModel.brokerUIState?.routeHealth
            .first { $0.instanceId == instance.id }?.reachable

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusBadge(for: instance)

                TextField("Name", text: instanceBinding(rowKey, \.name, fallback: ""))
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.medium))
                    .help("Your label for this lane. Editing it changes nothing about routing.")
                    .accessibilityLabel("Instance name")

                Spacer(minLength: 4)

                if let reachable {
                    BrokerChip(
                        text: reachable ? "Reachable" : "Unreachable",
                        systemImage: reachable ? "circle.fill" : "xmark",
                        tint: reachable ? .green : .red
                    )
                }

                Menu {
                    Button("Remove Instance", role: .destructive) {
                        rejectedIdEdits[rowKey] = nil
                        removeInstance(id: instance.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(instance.name)")
            }

            // Identity on the left, account binding on the right: the row is
            // one line of "what this instance is" and one control for "whose
            // quota gates it", instead of a stack of half-empty lines.
            HStack(spacing: 6) {
                if instance.origin == .detected {
                    Text(instance.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .help("The id T3 uses for this lane. Detected rows are not editable.")
                } else {
                    TextField("Instance ID", text: instanceIdBinding(rowKey))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .frame(width: 150)
                        .help("Must match the id T3 uses for this lane exactly, or nothing can dispatch to it.")
                }

                if let driver = instance.driver {
                    BrokerChip(text: driver, tint: .secondary, isMonospaced: true)
                }
                if !instance.detectedModels.isEmpty {
                    BrokerChip(
                        text: instance.detectedModels.count == 1
                            ? "1 model" : "\(instance.detectedModels.count) models",
                        tint: .secondary
                    )
                    .help(instance.detectedModels.joined(separator: "\n"))
                }

                Spacer(minLength: 8)

                // Hidden on lanes the binding cannot gate — see
                // `T3InstanceConfig.supportsAccountBinding`. A row that already
                // carries a binding keeps the control whatever its driver, so a
                // value set before the driver was known stays clearable.
                if Self.showsAccountPicker(for: instance) {
                    Text("Account")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: instanceBinding(rowKey, \.boundAccountId, fallback: nil)) {
                        Text("None").tag(String?.none)
                        ForEach(appModel.settings.claudeAccounts) { account in
                            Text(account.displayLabel).tag(String?.some(account.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 150)
                    .help("Which Pinemeter account's quota gates this instance.")
                    .accessibilityLabel("Bound account for \(instance.name)")
                }
            }

            if let idError {
                Text(idError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            // Named for what it does, not for the field it writes. The
            // override has exactly one consumer, `T3LivenessChecker`, so it
            // only moves the health probe. Calling it "Base URL" invited the
            // reading that it redirects dispatch, which Pinemeter does not
            // perform at all: the broker returns a decision and the agent
            // harness runs t3-dispatch itself.
            DisclosureGroup(isExpanded: advancedExpansion(rowKey)) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        "Detected from ~/.t3/userdata/server-runtime.json",
                        text: baseURLBinding(rowKey)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                    Text(
                        "Set this only when the status above stays Unreachable because T3 listens "
                            + "somewhere Pinemeter cannot find. It changes nothing about where work "
                            + "is sent."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if let baseURLCaption = Self.nonLoopbackBaseURLCaption(for: instance.baseURLOverride) {
                        Text(baseURLCaption)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Health check address")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                // Open it in the two states where it is the answer: an
                // override is already set, or the probe is failing and this
                // is the only control that can change that.
                if instance.baseURLOverride?.isEmpty == false || reachable == false {
                    expandedAdvancedRows.insert(rowKey)
                }
            }
        }
        .brokerInsetRow()
        .overlay(
            RoundedRectangle(cornerRadius: BrokerUI.rowRadius)
                .strokeBorder(idError == nil ? Color.clear : Color.red, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("T3 instance \(instance.name)")
    }

    /// The badge re-evaluates on a timeline rather than freezing at whatever
    /// `Date()` the body last read, so a row flips to "Stale" while the
    /// settings window stays open (review IN-05). 30 s granularity is far
    /// finer than the staleness threshold it drives.
    private func statusBadge(for instance: T3InstanceConfig) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let status = instance.status(
                now: context.date,
                stalenessSeconds: policy.thresholds.stalenessSeconds
            )
            let (label, symbol, color): (String, String, Color) = {
                switch status {
                case .detected: return ("Detected", "checkmark.circle.fill", .green)
                case .manual: return ("Manual", "pencil.circle.fill", .blue)
                case .stale: return ("Stale", "exclamationmark.triangle.fill", .orange)
                }
            }()
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(color)
                .help("\(label) instance")
                .accessibilityLabel("\(label) instance")
        }
    }

    // MARK: - Row bindings

    private func instanceIndex(for rowKey: UUID) -> Int? {
        appModel.settings.broker.policy.t3Instances.firstIndex { $0.rowKey == rowKey }
    }

    /// Resolve bindings by session-stable row identity on every access. A
    /// retained binding therefore follows its row across deletions instead
    /// of editing whichever row later occupies the same array index.
    private func instanceBinding<Value>(
        _ rowKey: UUID,
        _ keyPath: WritableKeyPath<T3InstanceConfig, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let index = instanceIndex(for: rowKey) else { return fallback }
                return appModel.settings.broker.policy.t3Instances[index][keyPath: keyPath]
            },
            set: { newValue in
                guard let index = instanceIndex(for: rowKey) else { return }
                appModel.settings.broker.policy.t3Instances[index][keyPath: keyPath] = newValue
            }
        )
    }

    private func baseURLBinding(_ rowKey: UUID) -> Binding<String> {
        Binding(
            get: {
                guard let index = instanceIndex(for: rowKey) else { return "" }
                return appModel.settings.broker.policy.t3Instances[index].baseURLOverride ?? ""
            },
            set: { newValue in
                guard let index = instanceIndex(for: rowKey) else { return }
                appModel.settings.broker.policy.t3Instances[index].baseURLOverride =
                    newValue.isEmpty ? nil : newValue
            }
        )
    }

    private func advancedExpansion(_ rowKey: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedAdvancedRows.contains(rowKey) },
            set: { isExpanded in
                if isExpanded {
                    expandedAdvancedRows.insert(rowKey)
                } else {
                    expandedAdvancedRows.remove(rowKey)
                }
            }
        )
    }

    /// The id field's binding enforces the id invariant at the mutation
    /// boundary (review WR-03/WR-04): an id outside `T3InstanceConfig`'s
    /// charset/length rule, or one that duplicates another row, is never
    /// written into settings — `:` or `/` would corrupt candidate-id
    /// parsing, cooldown keys, and `deny_instances` matching, and a
    /// duplicate id would make delete/reconcile/quota-gating pick rows
    /// ambiguously. `validateInstanceId`'s caption stays as the user-facing
    /// explanation of why typing appears to be rejected.
    private func instanceIdBinding(_ rowKey: UUID) -> Binding<String> {
        Binding(
            get: {
                if let rejected = rejectedIdEdits[rowKey] { return rejected }
                guard let index = instanceIndex(for: rowKey) else { return "" }
                return appModel.settings.broker.policy.t3Instances[index].id
            },
            set: { proposed in
                let error = appModel.settings.broker.policy.renameT3Instance(
                    rowKey: rowKey,
                    to: proposed
                )
                if let error {
                    rejectedIdEdits[rowKey] = proposed
                    removalError = error
                } else {
                    rejectedIdEdits[rowKey] = nil
                    removalError = nil
                }
            }
        )
    }

    // MARK: - Mutations

    private func addDetectedInstance(_ discovered: DiscoveredT3Instance) {
        // The policy method is the mutation boundary: it re-checks id
        // validity and duplicates against current state, because this menu's
        // snapshot of `discoveredT3Instances` can be one reconcile tick
        // stale (review IN-10).
        removalError = nil
        appModel.settings.broker.policy.addDetectedT3Instance(discovered)
    }

    /// Fixes the R-07 bug: manual rows used to be seeded with a generated
    /// UUID, which can never equal a real T3 instance id, and exposed no id
    /// field — so every manually added row was permanently undispatchable.
    /// This seeds a placeholder id inside the accepted charset and renders it
    /// as an editable field.
    private func addManualInstance() {
        removalError = nil
        let existingIds = Set(policy.t3Instances.map(\.id))
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

    private func removeInstance(id: String) {
        removalError = appModel.settings.broker.policy.removeT3Instance(id: id)
    }

    // MARK: - Validation

    /// The id validity rule is exposed via `T3InstanceConfig.isValidId` so
    /// this view and `T3InstanceDiscoveryService`'s id validation cannot
    /// drift apart (R-07 / T-pz4-01).
    static func validateInstanceId(
        _ id: String, existing: [T3InstanceConfig], ownRowKey: UUID
    ) -> String? {
        guard T3InstanceConfig.isValidId(id) else {
            return "Instance ID must be 1-64 characters: letters, numbers, underscore, period, or hyphen."
        }
        let isDuplicate = existing.contains { $0.rowKey != ownRowKey && $0.id == id }
        return isDuplicate ? "Another instance already uses this ID." : nil
    }

    /// Whether a row renders the Account control. Driver applicability is the
    /// model's rule; the escape hatch for an already-bound row is this view's,
    /// because it exists only so a stale value cannot become unreachable.
    static func showsAccountPicker(for instance: T3InstanceConfig) -> Bool {
        instance.supportsAccountBinding || instance.boundAccountId != nil
    }

    /// Delegates to the checker's own origin validator so the caption and the
    /// probe gate can never disagree about what will be probed (review IN-01).
    static func nonLoopbackBaseURLCaption(for baseURLOverride: String?) -> String? {
        guard let baseURLOverride, !baseURLOverride.isEmpty else { return nil }
        guard T3LivenessChecker.isValidLoopbackOrigin(baseURLOverride) else {
            return "This instance will not be probed: its base URL is not a plain loopback http origin."
        }
        return nil
    }
}
