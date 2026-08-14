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
        .frame(width: 130, alignment: .leading)
    }

    // MARK: - Role detail

    private func roleChainBinding(role: String) -> Binding<[BrokerCandidate]> {
        Binding(
            get: { appModel.settings.broker.policy.roles[role] ?? [] },
            set: { appModel.settings.broker.policy.roles[role] = $0 }
        )
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
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            }
            .onMove { indices, newOffset in
                chain.wrappedValue.move(fromOffsets: indices, toOffset: newOffset)
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .frame(height: CGFloat(max(chain.wrappedValue.count, 1)) * 44 + 8)
    }

    private func candidateRow(role: String, index: Int) -> some View {
        let chain = roleChainBinding(role: role)

        let routeBinding = Binding<BrokerPolicy.Route>(
            get: {
                chain.wrappedValue.indices.contains(index) ? chain.wrappedValue[index].route : .native
            },
            set: { newRoute in
                guard chain.wrappedValue.indices.contains(index) else { return }
                let current = chain.wrappedValue[index]
                // `instance` is a T3-only qualifier — clear it whenever the
                // route changes away from `.t3` so a stale instance can't
                // ride along and corrupt the candidate id wire contract.
                chain.wrappedValue[index] = BrokerCandidate(
                    route: newRoute,
                    instance: newRoute == .t3 ? current.instance : nil,
                    model: current.model
                )
            }
        )

        let modelBinding = Binding<String>(
            get: {
                chain.wrappedValue.indices.contains(index) ? chain.wrappedValue[index].model : ""
            },
            set: { newValue in
                guard chain.wrappedValue.indices.contains(index) else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let current = chain.wrappedValue[index]
                chain.wrappedValue[index] = BrokerCandidate(
                    route: current.route, instance: current.instance, model: trimmed
                )
            }
        )

        let instanceBinding = Binding<String?>(
            get: {
                chain.wrappedValue.indices.contains(index) ? chain.wrappedValue[index].instance : nil
            },
            set: { newValue in
                guard chain.wrappedValue.indices.contains(index) else { return }
                let current = chain.wrappedValue[index]
                chain.wrappedValue[index] = BrokerCandidate(
                    route: current.route, instance: newValue, model: current.model
                )
            }
        )

        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Picker("", selection: routeBinding) {
                ForEach(BrokerPolicy.Route.allCases, id: \.self) { route in
                    Text(route.rawValue).tag(route)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 90)

            TextField("Model", text: modelBinding)
                .textFieldStyle(.roundedBorder)

            Menu {
                ForEach(modelSuggestions(), id: \.self) { suggestion in
                    Button(suggestion) { modelBinding.wrappedValue = suggestion }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .help("Known models")
            .accessibilityLabel("Model suggestions")

            if routeBinding.wrappedValue == .t3 {
                Picker("", selection: instanceBinding) {
                    Text("Default").tag(String?.none)
                    ForEach(appModel.settings.broker.policy.t3Instances) { instance in
                        Text(instance.name).tag(String?.some(instance.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 110)
            }

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
    }

    private func modelSuggestions() -> [String] {
        var models = Set(appModel.settings.broker.policy.agentModelAliases.keys)
        for chain in appModel.settings.broker.policy.roles.values {
            for candidate in chain { models.insert(candidate.model) }
        }
        return models.sorted()
    }

    private func addCandidate(role: String) {
        let defaultModel = modelSuggestions().first ?? "claude-sonnet-5"
        appModel.settings.broker.policy.roles[role, default: []].append(
            BrokerCandidate(route: .native, model: defaultModel)
        )
    }

    private func removeCandidate(role: String, index: Int) {
        guard var chain = appModel.settings.broker.policy.roles[role], chain.count > 1 else { return }
        guard chain.indices.contains(index) else { return }
        chain.remove(at: index)
        appModel.settings.broker.policy.roles[role] = chain
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
