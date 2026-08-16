//
//  BrokerPolicyEditorView.swift
//  Pinemeter
//
//  D-05 structured policy editor: role list, ordered route+model candidate
//  chains (drag-to-reorder), and per-role degraded-rule controls. Valid by
//  construction — routes and T3 instances are picker-only, chains cannot be
//  emptied, and thresholds are bounded steppers. No free-form policy text
//  anywhere in this view.
//

import SwiftUI

struct BrokerPolicyEditorView: View {
    @Bindable var appModel: AppModel
    @State private var selectedRole: String?
    @State private var customModelRole: String?
    @State private var customModelIndex: Int?
    @State private var pendingCustomModel = ""
    @State private var isCustomModelAlertPresented = false

    /// `initialSelectedRole` is a test seam: production call sites always use
    /// the default `nil` (falls back to the first role alphabetically).
    /// Snapshot tests pin a specific role so the recorded image is
    /// deterministic regardless of dictionary key ordering.
    init(appModel: AppModel, initialSelectedRole: String? = nil) {
        self.appModel = appModel
        self._selectedRole = State(initialValue: initialSelectedRole)
    }

    private var sortedRoleNames: [String] {
        appModel.settings.broker.policy.roles.keys.sorted()
    }

    private var effectiveSelectedRole: String? {
        if let selectedRole, sortedRoleNames.contains(selectedRole) {
            return selectedRole
        }
        return sortedRoleNames.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if sortedRoleNames.isEmpty {
                Text("No roles configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    roleList
                    if let role = effectiveSelectedRole {
                        roleDetail(role: role)
                    }
                }
            }

            Divider()

            thresholdsGroup
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Policy")
                .font(.subheadline)
            Text("Ordered routing chains per role — structural editing only, no free-form policy text (D-05).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Role list

    private var roleList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sortedRoleNames, id: \.self) { role in
                Button {
                    selectedRole = role
                } label: {
                    Text(role)
                        .font(.caption)
                        .fontWeight(role == effectiveSelectedRole ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            role == effectiveSelectedRole
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Role: \(role)")
                .accessibilityAddTraits(role == effectiveSelectedRole ? [.isSelected] : [])
            }
        }
        // 92 fits the longest shipped role name ("architecture") and hands the
        // 38pt back to the candidate rows, which are the part of this editor
        // that runs out of width first — the second line spends 19pt of it on
        // the indent that groups the two lines.
        .frame(width: 92, alignment: .leading)
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
    /// remove and drag-reorder alike. Deliberately non-destructive: the D-03
    /// clamp is applied where a candidate is edited (`updateCandidate`) or
    /// created (`addCandidate`), the only places an invalid (model, effort)
    /// pair can be introduced. Remove and drag-reorder change no candidate's
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(role)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { addCandidate(role: role) }) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("Add a candidate")
                .accessibilityLabel("Add candidate to \(role)")
            }

            chainList(role: role)

            degradedToggle(role: role)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chainList(role: String) -> some View {
        let chain = roleChainBinding(role: role)
        return List {
            ForEach(Array(chain.wrappedValue.enumerated()), id: \.offset) { index, _ in
                candidateRow(role: role, index: index)
                    .listRowSeparator(.hidden)
                    // A candidate is two lines with no gap between them, so
                    // the gap BETWEEN candidates has to be clearly larger than
                    // the gap inside one or the rows read as eight unrelated
                    // controls instead of four pairs.
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            .onMove { indices, newOffset in
                chain.wrappedValue.move(fromOffsets: indices, toOffset: newOffset)
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        // Two-line candidate rows (see `candidateRow`): two ~24pt lines plus
        // the 8pt row insets above and below, so neither line is cropped and
        // the List needs no scrolling.
        .frame(height: CGFloat(max(chain.wrappedValue.count, 1)) * 66 + 8)
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
    // Two lines, not one. The editor is only as wide as the Settings window
    // allows: `SettingsView` sets `minWidth: 460`, `BrokerSettingsTab` pads 24
    // each side and this view pads again, and the 92pt role list takes its
    // share — so a t3 row's content width bottoms out near 272pt at the 412pt
    // snapshot gate. Five side-by-side controls cannot fit there, and the
    // control that overflowed was the Remove button. Identity (route, model)
    // and Remove stay on the first line; the qualifiers (t3 instance, effort)
    // sit on the second, where the widest effort label still fits whole.
    //
    // The two lines are flush (spacing 0) and the second is indented to the
    // first line's leading control, so a candidate reads as one block; the
    // 8pt row insets in `chainList` supply the larger gap between candidates.

    /// Width of the row's drag affordance, and (plus the row's 6pt spacing)
    /// the second line's indent, so both lines start at the same control.
    private static let dragHandleWidth: CGFloat = 13
    private static let rowControlSpacing: CGFloat = 6

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

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Self.rowControlSpacing) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    // Fixed so the second line's indent below is exact.
                    .frame(width: Self.dragHandleWidth)
                    .accessibilityHidden(true)

                Picker("", selection: routeBinding) {
                    ForEach(BrokerPolicy.Route.allCases, id: \.self) { route in
                        Text(route.rawValue).tag(route)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 72)

                Menu {
                    ForEach(Self.knownModelIDs(in: appModel.settings.broker.policy), id: \.self) { model in
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
                .help(modelBinding.wrappedValue)
                .accessibilityLabel("Model")
                .accessibilityValue(modelBinding.wrappedValue)

                Button(role: .destructive) {
                    removeCandidate(role: role, index: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .disabled(chain.wrappedValue.count <= 1)
                .help(
                    chain.wrappedValue.count <= 1
                        ? "A role must keep at least one candidate"
                        : "Remove candidate"
                )
                .accessibilityLabel("Remove candidate")
            }

            HStack(spacing: Self.rowControlSpacing) {
                if routeBinding.wrappedValue == .t3 {
                    let instanceName = Self.instanceDisplayName(
                        instanceBinding.wrappedValue,
                        in: appModel.settings.broker.policy
                    )
                    Picker("", selection: instanceBinding) {
                        Text("Default").tag(String?.none)
                        ForEach(appModel.settings.broker.policy.t3Instances) { instance in
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
            .padding(.leading, Self.dragHandleWidth + Self.rowControlSpacing)
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
    /// known id sorts first, which is a Haiku id in the shipped policy, so the
    /// appended candidate is clamped like every edited one.
    func addCandidate(role: String) {
        let defaultModel = Self.knownModelIDs(in: appModel.settings.broker.policy).first ?? "claude-sonnet-5"
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

    // MARK: - Degraded-rule toggle

    private func degradedToggle(role: String) -> some View {
        let binding = Binding<Bool>(
            get: { appModel.settings.broker.policy.allowsForcedDegraded(role: role) },
            set: { appModel.settings.broker.policy.allowForcedDegraded[role] = $0 }
        )
        return Toggle(isOn: binding) {
            Text("Allow degraded fallback when nothing has headroom")
                .font(.caption)
                // Wrap instead of truncating: the Settings window's 460pt
                // minimum leaves this label narrower than one line.
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
    }

    // MARK: - Thresholds (global, not per-role)

    private var thresholdsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thresholds")
                .font(.subheadline)

            thresholdStepper(title: "Session", value: $appModel.settings.broker.policy.thresholds.sessionPct)
            thresholdStepper(title: "Weekly", value: $appModel.settings.broker.policy.thresholds.weeklyPct)
            thresholdStepper(
                title: "Sonnet Weekly", value: $appModel.settings.broker.policy.thresholds.sonnetWeeklyPct
            )
            thresholdStepper(
                title: "Fable Weekly", value: $appModel.settings.broker.policy.thresholds.fableWeeklyPct
            )
            thresholdStepper(
                title: "ChatGPT Weekly", value: $appModel.settings.broker.policy.thresholds.chatgptWeeklyPct
            )
            stalenessStepper
        }
    }

    private func thresholdStepper(title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            Stepper("\(Int(value.wrappedValue))%", value: value, in: 50...100, step: 1)
                .frame(width: 130)
        }
    }

    private var stalenessStepper: some View {
        HStack {
            Text("Staleness")
                .font(.caption)
            Spacer()
            Stepper(
                "\(Int(appModel.settings.broker.policy.thresholds.stalenessSeconds))s",
                value: $appModel.settings.broker.policy.thresholds.stalenessSeconds,
                in: 60...7200, step: 60
            )
            .frame(width: 130)
        }
    }
}
