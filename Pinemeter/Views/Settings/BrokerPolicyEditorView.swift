//
//  BrokerPolicyEditorView.swift
//  Pinemeter
//
//  D-05 structured policy editor: role list, ordered route+model candidate
//  chains, and per-role degraded-rule controls. Valid by construction —
//  routes and T3 instances are picker-only, chains cannot be emptied, and no
//  free-form policy text exists anywhere in this view.
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
                    + "and hands back the first candidate with quota headroom.",
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
            Text("Enter the model ID used by this routing candidate.")
        }
        .alert("New Role", isPresented: $isAddRoleAlertPresented) {
            TextField("Role name", text: $pendingRoleName)
            Button("Cancel", role: .cancel) { pendingRoleName = "" }
            Button("Add") { addRole() }
                .disabled(!isPendingRoleNameValid)
        } message: {
            Text("Agents ask for a role by name. A new role starts with one candidate you can then rank.")
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
        // caption ("t3:claude_secondary/…" truncated), which is what makes the
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
        guard let first = policy.roles[role]?.first else { return "No candidates" }
        return first.id
    }

    // MARK: - Role detail

    private func roleChainBinding(role: String) -> Binding<[BrokerCandidate]> {
        Binding(
            get: { appModel.settings.broker.policy.roles[role] ?? [] },
            set: { writeChain(role: role, $0) }
        )
    }

    /// Test seam (same style as `initialSelectedRole`): the single chokepoint
    /// every candidate write in this view goes through — row edits, add,
    /// remove and reorder alike. Deliberately non-destructive: the D-03
    /// clamp is applied where a candidate is edited (`updateCandidate`) or
    /// created (`addCandidate`, `duplicateCandidate`), the only places an
    /// invalid (model, effort) pair can be introduced. Remove and reorder
    /// change no candidate's
    /// model, and a stale pair that arrived from disk is dropped at the
    /// dispatch boundary instead — an unrelated edit must not silently
    /// rewrite rows the user never touched (T-pzh-01).
    func writeChain(role: String, _ chain: [BrokerCandidate]) {
        appModel.settings.broker.policy.roles[role] = chain
    }

    /// Test seam: the sole write path for editing an existing candidate.
    /// Applies `transform`, clamps the result to its model's effort
    /// capability (D-03), and hands the chain to `writeChain`.
    func updateCandidate(role: String, index: Int, transform: (BrokerCandidate) -> BrokerCandidate) {
        var chain = appModel.settings.broker.policy.roles[role] ?? []
        guard chain.indices.contains(index) else { return }
        chain[index] = transform(chain[index]).clampingEffortToModelSupport()
        writeChain(role: role, chain)
    }

    private func roleDetail(role: String) -> some View {
        let chain = policy.roles[role] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(role)
                    .font(.title3.weight(.semibold))
                Text(chain.count == 1 ? "1 candidate" : "\(chain.count) candidates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addCandidate(role: role)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .controlSize(.small)
                .help("Append a candidate to this chain")
                .accessibilityLabel("Add candidate to \(role)")
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
    // Each field's binding is a named function rather than a closure inlined
    // into `candidateRow`, so a test can drive the exact binding the control
    // is wired to and prove it routes through `updateCandidate` (and therefore
    // through the clamp). An inline write reintroduced in the row would make
    // those tests fail.

    func candidateRouteBinding(role: String, index: Int) -> Binding<BrokerPolicy.Route> {
        let chain = roleChainBinding(role: role)
        return Binding(
            get: {
                chain.wrappedValue.indices.contains(index) ? chain.wrappedValue[index].route : .native
            },
            set: { newRoute in
                // `instance` is a T3-only qualifier — clear it whenever the
                // route changes away from `.t3` so a stale instance can't
                // ride along and corrupt the candidate id wire contract.
                updateCandidate(role: role, index: index) { current in
                    BrokerCandidate(
                        route: newRoute,
                        instance: newRoute == .t3 ? current.instance : nil,
                        model: current.model,
                        effort: current.effort
                    )
                }
            }
        )
    }

    func candidateInstanceBinding(role: String, index: Int) -> Binding<String?> {
        let chain = roleChainBinding(role: role)
        return Binding(
            get: {
                chain.wrappedValue.indices.contains(index) ? chain.wrappedValue[index].instance : nil
            },
            set: { newValue in
                updateCandidate(role: role, index: index) { current in
                    BrokerCandidate(
                        route: current.route,
                        instance: newValue,
                        model: current.model,
                        effort: current.effort
                    )
                }
            }
        )
    }

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

    // MARK: - Candidate row
    //
    // Two lines, not one. Line one is the candidate's identity — rank, route,
    // model — and its actions; line two carries the qualifiers that only some
    // routes have (T3 instance) or some models accept (effort). Keeping the
    // identity line's control positions identical across every row is what
    // lets a chain be read as a ranked list rather than a grid of pickers.

    private static let dragHandleWidth: CGFloat = 13
    private static let rankBadgeWidth: CGFloat = BrokerRankBadge.diameter
    private static let rowControlSpacing: CGFloat = 6
    /// Indent that puts line two's first control directly under line one's
    /// route picker, so the row reads as one block rather than two lists.
    private static var qualifierIndent: CGFloat {
        dragHandleWidth + rowControlSpacing + rankBadgeWidth + rowControlSpacing
    }
    /// Width reserved for the T3 reachability dot on every t3 row, whether or
    /// not the broker has reported health for that instance yet. Without the
    /// reservation the instance pickers in one chain start at different x
    /// positions depending on which instances happen to have been probed.
    private static let reachabilityDotWidth: CGFloat = 12

    private func candidateRow(role: String, index: Int) -> some View {
        let chain = roleChainBinding(role: role)
        let routeBinding = candidateRouteBinding(role: role, index: index)
        let modelBinding = candidateModelBinding(role: role, index: index)
        let instanceBinding = candidateInstanceBinding(role: role, index: index)
        let effortBinding = candidateEffortBinding(role: role, index: index)

        let currentCandidate = chain.wrappedValue.indices.contains(index) ? chain.wrappedValue[index] : nil
        let effortSupport = BrokerEffort.support(forModel: modelBinding.wrappedValue)
        let effortValueForAccessibility = currentCandidate.map(Self.effortAccessibilityValue(for:))
            ?? effortSupport.nilLabel

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Self.rowControlSpacing) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.dragHandleWidth)
                    .draggable(Self.dragPayload(role: role, index: index))
                    .help("Drag to re-rank")
                    .accessibilityHidden(true)

                BrokerRankBadge(rank: index + 1)
                    .help(BrokerHelpText.rank(index + 1, of: chain.wrappedValue.count))

                // `native`, `t3` and `codex` are the tab's densest jargon and
                // carried no explanation at all. The tooltip describes the
                // selected value, so hovering answers "what does this row
                // actually do" rather than listing the vocabulary again.
                Picker("", selection: routeBinding) {
                    ForEach(BrokerPolicy.Route.allCases, id: \.self) { route in
                        Text(route.rawValue).tag(route)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 78)
                .help(BrokerHelpText.route(routeBinding.wrappedValue))
                .accessibilityLabel("Route")
                .accessibilityValue(routeBinding.wrappedValue.rawValue)

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
                    Text(modelBinding.wrappedValue)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(minWidth: 92, maxWidth: .infinity, alignment: .leading)
                // Was the model id repeated back verbatim, which told a
                // hovering user nothing they could not already read.
                .help(BrokerHelpText.model(modelBinding.wrappedValue))
                .accessibilityLabel("Model")
                .accessibilityValue(modelBinding.wrappedValue)

                candidateActionsMenu(role: role, index: index, count: chain.wrappedValue.count)
            }

            HStack(spacing: Self.rowControlSpacing) {
                if routeBinding.wrappedValue == .t3 {
                    let instanceName = Self.instanceDisplayName(instanceBinding.wrappedValue, in: policy)

                    let reachable = currentCandidate.flatMap(reachability(for:))
                    Group {
                        if let reachable {
                            BrokerStatusDot(color: reachable ? .green : .red, diameter: 6)
                                .help(reachable ? "Instance is reachable" : "Instance is not reachable right now")
                        }
                    }
                    .frame(width: Self.reachabilityDotWidth)

                    Picker("", selection: instanceBinding) {
                        Text("Default").tag(String?.none)
                        ForEach(policy.t3Instances) { instance in
                            Text(instance.name).tag(String?.some(instance.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    // Flexible within a deliberate cap: the capability label
                    // is the point of this control pair, so the instance gives
                    // up width first and never grows past 130pt even in a wide
                    // window. A long instance name truncates — the full name
                    // stays in the popup, the tooltip and the accessibility
                    // value.
                    .frame(minWidth: 64, maxWidth: 130)
                    .help("T3 instance: \(instanceName)")
                    .accessibilityLabel("T3 instance")
                    .accessibilityValue(instanceName)
                }

                // One control for both capability states: the nil row is
                // tagged with this model's own label (D-02) instead of a fixed
                // "Default", the level rows come from the same lookup (empty
                // for a model with no effort parameter), and the same lookup
                // drives the accessibility value — so the visible label, the
                // offered choices and VoiceOver can never disagree.
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
                // Sized for the widest nil labels the lookup can return
                // ("Provider default" and "Default (medium)"), so no
                // capability label truncates.
                .frame(width: 140)
                .disabled(!effortSupport.supportsEffort)
                .help(
                    effortSupport.supportsEffort
                        ? "Recommended reasoning effort. \(effortSupport.nilLabel) sends no effort; the provider decides."
                        : "Recommended reasoning effort. This model has no effort parameter; the provider decides."
                )
                .accessibilityLabel("Effort")
                .accessibilityValue(effortValueForAccessibility)

                Spacer(minLength: 0)
            }
            .padding(.leading, Self.qualifierIndent)
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
        // The two-line split grouped the controls visually; this groups them
        // for assistive tech the same way. Without a container the element
        // order is a flat repetition of identically-labelled controls, and
        // nothing tells VoiceOver which candidate a control belongs to.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Candidate \(index + 1) of \(chain.wrappedValue.count), \(modelBinding.wrappedValue)"
        )
    }

    private func candidateActionsMenu(role: String, index: Int, count: Int) -> some View {
        Menu {
            Button("Move Up") { moveCandidate(role: role, from: index, to: index - 1) }
                .disabled(index == 0)
            Button("Move Down") { moveCandidate(role: role, from: index, to: index + 1) }
                .disabled(index >= count - 1)
            Divider()
            Button("Duplicate") { duplicateCandidate(role: role, index: index) }
            Button("Remove", role: .destructive) { removeCandidate(role: role, index: index) }
                .disabled(count <= 1)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(count <= 1 ? "A role must keep at least one candidate" : "Re-rank, duplicate or remove")
        .accessibilityLabel("Candidate actions")
    }

    /// Live reachability of the T3 instance a candidate resolves to, or `nil`
    /// when the candidate isn't T3-routed or the broker has reported nothing
    /// yet. Read-only signal: it never changes what is stored.
    private func reachability(for candidate: BrokerCandidate) -> Bool? {
        guard candidate.route == .t3 else { return nil }
        let resolved = policy.resolvedInstance(for: candidate)
        return appModel.brokerUIState?.routeHealth.first { $0.instanceId == resolved }?.reachable
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

    /// The name shown for a candidate's T3 instance qualifier: the configured
    /// instance's name, or "Default" when the candidate carries no qualifier
    /// (or names an instance the policy no longer configures).
    static func instanceDisplayName(_ instanceID: String?, in policy: BrokerPolicy) -> String {
        guard let instanceID else { return "Default" }
        return policy.t3Instances.first { $0.id == instanceID }?.name ?? "Default"
    }

    static func knownModelIDs(in policy: BrokerPolicy) -> [String] {
        var models = Set(policy.agentModelAliases.keys)
        for chain in policy.roles.values {
            for candidate in chain { models.insert(candidate.model) }
        }
        return models.sorted()
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

    /// Appends a candidate through `writeChain`. The seeded model is whichever
    /// known id sorts first — `claude-fable-5` in the shipped policy. The
    /// appended candidate is clamped like every edited one regardless, since
    /// the sort winner depends entirely on the user's own model ids.
    func addCandidate(role: String) {
        let defaultModel = Self.knownModelIDs(in: policy).first ?? "claude-sonnet-5"
        var chain = appModel.settings.broker.policy.roles[role] ?? []
        chain.append(BrokerCandidate(route: .native, model: defaultModel).clampingEffortToModelSupport())
        writeChain(role: role, chain)
    }

    func removeCandidate(role: String, index: Int) {
        guard var chain = appModel.settings.broker.policy.roles[role], chain.count > 1 else { return }
        guard chain.indices.contains(index) else { return }
        chain.remove(at: index)
        writeChain(role: role, chain)
    }

    /// Copies a candidate directly below itself, the fastest way to build a
    /// "same model, different instance/effort" fallback rank.
    func duplicateCandidate(role: String, index: Int) {
        guard var chain = appModel.settings.broker.policy.roles[role],
              chain.indices.contains(index)
        else { return }
        // Clamped like every other candidate this editor CREATES (D-03):
        // the source row may carry a stale (effort-free model, stored effort)
        // pair from disk, and copying it would mint a second invalid row.
        chain.insert(chain[index].clampingEffortToModelSupport(), at: index + 1)
        writeChain(role: role, chain)
    }

    /// Re-ranks one candidate. Rank IS the routing order, so this is the most
    /// consequential edit in the view — it goes through `writeChain` like
    /// every other, and rewrites no candidate's contents.
    func moveCandidate(role: String, from source: Int, to destination: Int) {
        guard var chain = appModel.settings.broker.policy.roles[role],
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
            BrokerCandidate(route: .native, model: defaultModel).clampingEffortToModelSupport()
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
                        ? "When every candidate is capped, route anyway and mark the pick degraded."
                        : "When every candidate is capped, return no pick so the agent stops instead of downgrading."
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
