//
//  BrokerPolicyEditorView.swift
//  Pinemeter
//
//  Structured role editor: users rank models and choose effort; the broker
//  resolves routes, instances and quota-bearing accounts at pick time.
//
//  The editor is a master/detail pair rather than a stack of every role's
//  chain: a chain is an ordered, drag-reorderable list, and stacking eight of
//  them turns "which candidate is tried first for review" — the only question
//  this screen exists to answer — into a scrolling exercise. The role list
//  carries each role's current first choice for exactly that reason, so the
//  answer for every role is readable without selecting them one by one.
//
//  Reordering is available three ways on purpose: drag for speed, the row
//  menu's Move Up/Move Down for discoverability and for anyone who cannot
//  drag, and the rank badge to read the result back.
//

import SwiftUI

struct BrokerPolicyEditorView: View {
    @Bindable var appModel: AppModel
    @State private var selectedRole: String?
    @State private var customModelRole: String?
    @State private var customModelIndex: Int?
    @State private var pendingCustomModel = ""
    @State private var isCustomModelAlertPresented = false
    @State private var isAddRoleAlertPresented = false
    @State private var isRemoveRoleConfirmationPresented = false
    @State private var pendingRoleName = ""
    @State private var dropTargetIndex: Int?

    /// `initialSelectedRole` is a test seam: production call sites always use
    /// the default `nil` (falls back to the first role alphabetically).
    /// Snapshot tests pin a specific role so the recorded image is
    /// deterministic regardless of dictionary key ordering.
    init(appModel: AppModel, initialSelectedRole: String? = nil) {
        self.appModel = appModel
        self._selectedRole = State(initialValue: initialSelectedRole)
    }

    private var policy: BrokerPolicy { appModel.settings.broker.policy }

    private var sortedRoleNames: [String] {
        policy.roles.keys.sorted()
    }

    private var effectiveSelectedRole: String? {
        if let selectedRole, sortedRoleNames.contains(selectedRole) {
            return selectedRole
        }
        return sortedRoleNames.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrokerSectionHeader(
                "Roles & Chains",
                systemImage: "list.number",
                subtitle: "An agent asks for a role; the broker walks that role's chain top to bottom "
                    + "and runs the first model with quota on any available account.",
                help: .rolesAndChains
            )

            if sortedRoleNames.isEmpty {
                BrokerEmptyState(
                    title: "No roles configured",
                    systemImage: "list.bullet.rectangle",
                    hint: "Add a role to start routing. Roles are the names your agents ask for, "
                        + "such as review or execution."
                )
                HStack {
                    Spacer()
                    Button("Add Role\u{2026}") { beginAddingRole() }
                        .controlSize(.small)
                    Spacer()
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    roleSidebar
                    Divider()
                    if let role = effectiveSelectedRole {
                        roleDetail(role: role)
                    }
                }
            }
        }
        .brokerCard()
        .alert("Custom Model", isPresented: $isCustomModelAlertPresented) {
            TextField("Model ID", text: $pendingCustomModel)
            Button("Cancel", role: .cancel) {
                clearCustomModelTarget()
            }
            Button("Save") {
                saveCustomModel()
            }
            .disabled(pendingCustomModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter the model ID to add to this chain.")
        }
        .alert("New Role", isPresented: $isAddRoleAlertPresented) {
            TextField("Role name", text: $pendingRoleName)
            Button("Cancel", role: .cancel) { pendingRoleName = "" }
            Button("Add") { addRole() }
                .disabled(!isPendingRoleNameValid)
        } message: {
            Text("Agents ask for a role by name. A new role starts with one model you can then rank.")
        }
        .confirmationDialog(
            "Remove the \u{201C}\(effectiveSelectedRole ?? "")\u{201D} role?",
            isPresented: $isRemoveRoleConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove Role", role: .destructive) { removeSelectedRole() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An agent that asks for a role with no chain gets no pick at all, and stops instead of routing.")
        }
    }

    // MARK: - Role sidebar

    private var roleSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sortedRoleNames, id: \.self) { role in
                    roleSidebarRow(role)
                }
            }

            HStack(spacing: 2) {
                Button {
                    beginAddingRole()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Add a role")
                .accessibilityLabel("Add role")

                Button {
                    isRemoveRoleConfirmationPresented = true
                } label: {
                    Image(systemName: "minus")
                        .font(.caption)
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(effectiveSelectedRole == nil)
                .help("Remove the selected role")
                .accessibilityLabel("Remove selected role")

                Spacer()
            }
        }
        // Wide enough for the longest shipped role name plus its first-choice
        // caption ("native/claude-fable-5-1" truncated), which is what makes the
        // list scannable without selecting each row.
        .frame(width: 168, alignment: .leading)
    }

    private func roleSidebarRow(_ role: String) -> some View {
        let isSelected = role == effectiveSelectedRole
        return Button {
            selectedRole = role
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(role)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(.primary)
                Text(firstChoiceCaption(for: role))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: BrokerUI.rowRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: BrokerUI.rowRadius))
        }
        .buttonStyle(.plain)
        .help(BrokerHelpText.role(role, firstChoice: firstChoiceCaption(for: role)))
        .accessibilityLabel("Role: \(role)")
        .accessibilityValue(firstChoiceCaption(for: role))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// What this role routes to first — the fact the sidebar exists to expose.
    private func firstChoiceCaption(for role: String) -> String {
        guard let first = Self.modelChoices(in: policy.roles[role] ?? []).first else {
            return "No models"
        }
        return first.model
    }

    // MARK: - Role detail

    private func roleChainBinding(role: String) -> Binding<[BrokerCandidate]> {
        Binding(
            get: { Self.modelChoices(in: appModel.settings.broker.policy.roles[role] ?? []) },
            set: { writeChain(role: role, $0) }
        )
    }

    static func modelChoices(in chain: [BrokerCandidate]) -> [BrokerCandidate] {
        BrokerPolicy.automaticModelChoices(in: chain)
    }

    /// Test seam (same style as `initialSelectedRole`): the single chokepoint
    /// every candidate write in this view goes through — row edits, add,
    /// remove and reorder alike. Deliberately non-destructive: the D-03
    /// clamp is applied where a candidate is edited (`updateCandidate`) or
    /// created (`addCandidate`), the only places an
    /// invalid (model, effort) pair can be introduced. Remove and reorder
    /// change no candidate's
    /// model, and a stale pair that arrived from disk is dropped at the
    /// dispatch boundary instead — an unrelated edit must not silently
    /// rewrite rows the user never touched (T-pzh-01).
    func writeChain(role: String, _ chain: [BrokerCandidate]) {
        appModel.settings.broker.policy.roles[role] = Self.modelChoices(in: chain)
    }

    /// Test seam: the sole write path for editing an existing candidate.
    /// Applies `transform`, clamps the result to its model's effort
    /// capability (D-03), and hands the chain to `writeChain`.
    func updateCandidate(role: String, index: Int, transform: (BrokerCandidate) -> BrokerCandidate) {
        var chain = Self.modelChoices(in: appModel.settings.broker.policy.roles[role] ?? [])
        guard chain.indices.contains(index) else { return }
        chain[index] = transform(chain[index]).clampingEffortToModelSupport()
        writeChain(role: role, chain)
    }

    private func roleDetail(role: String) -> some View {
        let chain = Self.modelChoices(in: policy.roles[role] ?? [])
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(role)
                    .font(.title3.weight(.semibold))
                Text(chain.count == 1 ? "1 model" : "\(chain.count) models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addCandidate(role: role)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .controlSize(.small)
                .help("Append a model to this chain")
                .accessibilityLabel("Add model to \(role)")
            }

            VStack(spacing: 6) {
                ForEach(Array(chain.enumerated()), id: \.offset) { index, _ in
                    candidateRow(role: role, index: index)
                }
            }

            degradedToggle(role: role)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Candidate row bindings
    //
    // Each visible field's binding is a named function rather than a closure inlined
    // into `candidateRow`, so a test can drive the exact binding the control
    // is wired to and prove it routes through `updateCandidate` (and therefore
    // through the clamp). An inline write reintroduced in the row would make
    // those tests fail.

    /// `nil` is a first-class choice here, not an empty state: it means the
    /// decision carries no effort at all, so the provider default applies.
    func candidateEffortBinding(role: String, index: Int) -> Binding<BrokerEffort?> {
        let chain = roleChainBinding(role: role)
        return Binding(
            get: {
                chain.wrappedValue.indices.contains(index) ? chain.wrappedValue[index].effort : nil
            },
            set: { newValue in
                updateCandidate(role: role, index: index) { current in
                    BrokerCandidate(
                        route: current.route,
                        instance: current.instance,
                        model: current.model,
                        effort: newValue
                    )
                }
            }
        )
    }

    func candidateModelBinding(role: String, index: Int) -> Binding<String> {
        let chain = roleChainBinding(role: role)
        return Binding(
            get: {
                chain.wrappedValue.indices.contains(index) ? chain.wrappedValue[index].model : ""
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                updateCandidate(role: role, index: index) { current in
                    BrokerCandidate(
                        route: current.route,
                        instance: current.instance,
                        model: trimmed,
                        effort: current.effort
                    )
                }
            }
        )
    }

    // MARK: - Model row
    //
    // Route and instance are deliberately absent. They are live broker
    // outputs, not configuration the user should maintain.

    private static let dragHandleWidth: CGFloat = 13
    private static let rowControlSpacing: CGFloat = 6

    private func candidateRow(role: String, index: Int) -> some View {
        let chain = roleChainBinding(role: role)
        let modelBinding = candidateModelBinding(role: role, index: index)
        let effortBinding = candidateEffortBinding(role: role, index: index)

        let currentCandidate = chain.wrappedValue.indices.contains(index) ? chain.wrappedValue[index] : nil
        let effortSupport = BrokerEffort.support(forModel: modelBinding.wrappedValue)
        let effortValueForAccessibility = currentCandidate.map(Self.effortAccessibilityValue(for:))
            ?? effortSupport.nilLabel

        return HStack(spacing: Self.rowControlSpacing) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: Self.dragHandleWidth)
                .draggable(Self.dragPayload(role: role, index: index))
                .help("Drag to re-rank")
                .accessibilityHidden(true)

            BrokerRankBadge(rank: index + 1)
                .help(BrokerHelpText.rank(index + 1, of: chain.wrappedValue.count))

            Menu {
                ForEach(Self.knownModelIDs(in: policy), id: \.self) { model in
                    Button(model) { modelBinding.wrappedValue = model }
                }
                Divider()
                Button("Custom\u{2026}") {
                    pendingCustomModel = modelBinding.wrappedValue
                    customModelRole = role
                    customModelIndex = index
                    isCustomModelAlertPresented = true
                }
            } label: {
                Text(modelBinding.wrappedValue).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 92, maxWidth: .infinity, alignment: .leading)
            .help(BrokerHelpText.model(modelBinding.wrappedValue))
            .accessibilityLabel("Model")
            .accessibilityValue(modelBinding.wrappedValue)

            Picker(
                "",
                selection: effortSupport.supportsEffort ? effortBinding : .constant(BrokerEffort?.none)
            ) {
                Text(effortSupport.nilLabel).tag(BrokerEffort?.none)
                ForEach(effortSupport.selectableLevels, id: \.self) { effort in
                    Text(Self.effortLabel(effort)).tag(BrokerEffort?.some(effort))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 140)
            .disabled(!effortSupport.supportsEffort)
            .help(
                effortSupport.supportsEffort
                    ? "Recommended reasoning effort. \(effortSupport.nilLabel) sends no effort; the provider decides."
                    : "Recommended reasoning effort. This model has no effort parameter; the provider decides."
            )
            .accessibilityLabel("Effort")
            .accessibilityValue(effortValueForAccessibility)

            candidateActionsMenu(role: role, index: index, count: chain.wrappedValue.count)
        }
        .brokerInsetRow(isEmphasized: index == 0)
        .overlay(alignment: .top) {
            if dropTargetIndex == index {
                RoundedRectangle(cornerRadius: BrokerUI.rowRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .dropDestination(for: String.self) { payload, _ in
            dropTargetIndex = nil
            guard let source = Self.dragSourceIndex(payload.first, role: role) else { return false }
            moveCandidate(role: role, from: source, to: index)
            return true
        } isTargeted: { isTargeted in
            dropTargetIndex = isTargeted ? index : (dropTargetIndex == index ? nil : dropTargetIndex)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Model \(index + 1) of \(chain.wrappedValue.count), \(modelBinding.wrappedValue)"
        )
    }

    private func candidateActionsMenu(role: String, index: Int, count: Int) -> some View {
        Menu {
            Button("Move Up") { moveCandidate(role: role, from: index, to: index - 1) }
                .disabled(index == 0)
            Button("Move Down") { moveCandidate(role: role, from: index, to: index + 1) }
                .disabled(index >= count - 1)
            Divider()
            Button("Remove", role: .destructive) { removeCandidate(role: role, index: index) }
                .disabled(count <= 1)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(count <= 1 ? "A role must keep at least one model" : "Re-rank or remove")
        .accessibilityLabel("Model actions")
    }

    // MARK: - Drag payload
    //
    // Reorder drags carry a plain string rather than a custom UTType, so no
    // Info.plist type declaration is needed. The role is part of the payload
    // so a string dragged in from anywhere else — or from another role's
    // chain — is rejected instead of silently reordering the wrong list.

    private static let dragSeparator = "\u{1F}"

    static func dragPayload(role: String, index: Int) -> String {
        "pinemeter-broker-candidate\(dragSeparator)\(role)\(dragSeparator)\(index)"
    }

    static func dragSourceIndex(_ payload: String?, role: String) -> Int? {
        guard let payload else { return nil }
        let parts = payload.components(separatedBy: dragSeparator)
        guard parts.count == 3,
              parts[0] == "pinemeter-broker-candidate",
              parts[1] == role,
              let index = Int(parts[2])
        else { return nil }
        return index
    }

    private static func effortLabel(_ effort: BrokerEffort) -> String {
        switch effort {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        }
    }

    /// Chain models lead, alias-only ids trail: `addRole`/`addCandidate` seed
    /// from `.first`, and a legacy alias key kept only for saved policies
    /// (e.g. `claude-fable-5`) must never win that seed over a shipped
    /// candidate it sorts ahead of.
    static func knownModelIDs(in policy: BrokerPolicy) -> [String] {
        var chainModels = Set<String>()
        for chain in policy.roles.values {
            for candidate in chain { chainModels.insert(candidate.model) }
        }
        let aliasOnly = Set(policy.agentModelAliases.keys).subtracting(chainModels)
        return chainModels.sorted() + aliasOnly.sorted()
    }

    /// The effort control's accessibility value: the model's `nilLabel` when
    /// the model has no effort parameter or the candidate carries no effort,
    /// the level's display label otherwise. Driven off the same capability
    /// lookup as the visible nil-row label (D-02, D-05).
    ///
    /// Capability is checked before the stored effort on purpose. A policy
    /// this editor never wrote can carry an effort on a model with no effort
    /// parameter; the control shows "Unsupported" and the engine drops the
    /// value at dispatch, so VoiceOver must not announce a level that is
    /// neither shown nor sent.
    static func effortAccessibilityValue(for candidate: BrokerCandidate) -> String {
        let support = BrokerEffort.support(forModel: candidate.model)
        guard support.supportsEffort, let effort = candidate.effort else {
            return support.nilLabel
        }
        return effortLabel(effort)
    }

    private func saveCustomModel() {
        guard let customModelRole, let customModelIndex else { return }
        candidateModelBinding(role: customModelRole, index: customModelIndex).wrappedValue = pendingCustomModel
        clearCustomModelTarget()
    }

    private func clearCustomModelTarget() {
        customModelRole = nil
        customModelIndex = nil
        pendingCustomModel = ""
    }

    /// Appends a model through `writeChain`. The seeded model is the first
    /// known id not already present. The broker expands its automatic route at
    /// pick time. The appended model is clamped like every edited one, since
    /// the sort winner depends entirely on the user's own model ids.
    func addCandidate(role: String) {
        var chain = Self.modelChoices(in: appModel.settings.broker.policy.roles[role] ?? [])
        let used = Set(chain.map(\.model))
        let defaultModel = Self.knownModelIDs(in: policy).first { !used.contains($0) }
            ?? "claude-sonnet-5"
        chain.append(BrokerCandidate(
            route: .auto,
            model: defaultModel
        ).clampingEffortToModelSupport())
        writeChain(role: role, chain)
    }

    func removeCandidate(role: String, index: Int) {
        var chain = Self.modelChoices(in: appModel.settings.broker.policy.roles[role] ?? [])
        guard chain.count > 1 else { return }
        guard chain.indices.contains(index) else { return }
        chain.remove(at: index)
        writeChain(role: role, chain)
    }

    /// Re-ranks one model. Rank IS the routing order, so this is the most
    /// consequential edit in the view — it goes through `writeChain` like
    /// every other, and rewrites no candidate's contents.
    func moveCandidate(role: String, from source: Int, to destination: Int) {
        var chain = Self.modelChoices(in: appModel.settings.broker.policy.roles[role] ?? [])
        guard
              chain.indices.contains(source),
              destination >= 0, destination < chain.count,
              source != destination
        else { return }
        let candidate = chain.remove(at: source)
        chain.insert(candidate, at: destination)
        writeChain(role: role, chain)
    }

    // MARK: - Role management

    private var isPendingRoleNameValid: Bool {
        let trimmed = pendingRoleName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !policy.roles.keys.contains(trimmed)
    }

    private func beginAddingRole() {
        pendingRoleName = ""
        isAddRoleAlertPresented = true
    }

    private func addRole() {
        let trimmed = pendingRoleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !policy.roles.keys.contains(trimmed) else { return }
        let defaultModel = Self.knownModelIDs(in: policy).first ?? "claude-sonnet-5"
        appModel.settings.broker.policy.roles[trimmed] = [
            BrokerCandidate(
                route: .auto,
                model: defaultModel
            ).clampingEffortToModelSupport()
        ]
        selectedRole = trimmed
        pendingRoleName = ""
    }

    private func removeSelectedRole() {
        guard let role = effectiveSelectedRole else { return }
        appModel.settings.broker.policy.roles.removeValue(forKey: role)
        appModel.settings.broker.policy.allowForcedDegraded.removeValue(forKey: role)
        selectedRole = appModel.settings.broker.policy.roles.keys.sorted().first
    }

    // MARK: - Degraded-rule toggle

    private func degradedToggle(role: String) -> some View {
        let binding = Binding<Bool>(
            get: { appModel.settings.broker.policy.allowsForcedDegraded(role: role) },
            set: { appModel.settings.broker.policy.allowForcedDegraded[role] = $0 }
        )
        return Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Allow degraded fallback")
                    .font(.callout)
                Text(
                    binding.wrappedValue
                        ? "When every model is capped, route anyway and mark the pick degraded."
                        : "When every model is capped, return no pick so the agent stops instead of downgrading."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(.top, 2)
    }
}
