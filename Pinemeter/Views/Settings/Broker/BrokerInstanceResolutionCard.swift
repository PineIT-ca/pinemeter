//
//  BrokerInstanceResolutionCard.swift
//  Pinemeter
//
//  Where a `t3` candidate that names no instance actually lands: the model
//  mappings, then the fallback instance.
//
//  This card sits in the Routing pane, not the Instances pane, because both
//  of its controls are routing RULES — `BrokerRuleSet` carries
//  `instanceByModel` and `defaultInstance`, so a profile load rewrites them
//  and an edit here is what makes the profile bar read "Edited". Filing them
//  next to the instance rows would split a profile's contents across two
//  panes and make that badge light up with no visible cause.
//
//  The instance rows themselves stay in the Instances pane, because they are
//  the opposite kind of data: this Mac's hardware and account bindings, which
//  no profile may touch.
//

import SwiftUI

struct BrokerInstanceResolutionCard: View {
    @Bindable var appModel: AppModel

    private var policy: BrokerPolicy { appModel.settings.broker.policy }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "Instance Resolution",
                systemImage: "arrow.triangle.branch",
                subtitle: "A t3 candidate reaches the instance it names directly. "
                    + "An \u{201C}Any\u{201D} candidate reaches whichever instance serving its model "
                    + "has the most headroom. If it names none, the model's mapping below decides. "
                    + "If there is no mapping, the fallback instance does.",
                help: .instanceResolution
            )

            HStack(alignment: .firstTextBaseline) {
                Text("Model mappings")
                    .font(.callout)
                Spacer()
                addMappingMenu
            }

            if policy.t3.instanceByModel.isEmpty {
                Text("No model mappings. Every unqualified t3 candidate uses the fallback instance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    ForEach(policy.t3.instanceByModel.keys.sorted(), id: \.self) { model in
                        mappingRow(model: model)
                    }
                }
            }

            Divider()
                .padding(.vertical, 2)

            HStack(spacing: 8) {
                Text("Fallback instance")
                    .font(.callout)
                Spacer(minLength: 8)
                Picker("", selection: $appModel.settings.broker.policy.t3.defaultInstance) {
                    ForEach(policy.t3Instances) { instance in
                        Text(instance.name).tag(instance.id)
                    }
                    if !policy.t3Instances.contains(where: { $0.id == policy.t3.defaultInstance }) {
                        // The stored fallback names no configured row — keep
                        // showing it rather than silently re-pointing routing
                        // at whatever happens to sort first.
                        Text("\(policy.t3.defaultInstance) (missing)").tag(policy.t3.defaultInstance)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200)
                .help("Where a t3 candidate goes when it names no instance and its model has no mapping.")
                .accessibilityLabel("Fallback T3 instance")
            }
        }
        .brokerCard()
    }

    private var addMappingMenu: some View {
        let unmapped = BrokerPolicyEditorView.knownModelIDs(in: policy)
            .filter { policy.t3.instanceByModel[$0] == nil }

        return Menu {
            if unmapped.isEmpty {
                Text("Every known model is mapped")
            } else {
                ForEach(unmapped, id: \.self) { model in
                    Button(model) {
                        appModel.settings.broker.policy.t3.instanceByModel[model] =
                            policy.t3.defaultInstance
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Map a model to a specific T3 instance")
        .accessibilityLabel("Add model mapping")
    }

    private func mappingRow(model: String) -> some View {
        HStack(spacing: 8) {
            Text(model)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Picker(
                "",
                selection: Binding(
                    get: { appModel.settings.broker.policy.t3.instanceByModel[model] ?? "" },
                    set: { appModel.settings.broker.policy.t3.instanceByModel[model] = $0 }
                )
            ) {
                ForEach(policy.t3Instances) { instance in
                    Text(instance.name).tag(instance.id)
                }
                let mapped = policy.t3.instanceByModel[model] ?? ""
                if !policy.t3Instances.contains(where: { $0.id == mapped }) {
                    Text("\(mapped) (missing)").tag(mapped)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 180)
            .accessibilityLabel("Instance for \(model)")

            Button {
                appModel.settings.broker.policy.t3.instanceByModel.removeValue(forKey: model)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this mapping")
            .accessibilityLabel("Remove mapping for \(model)")
        }
        .padding(.vertical, 1)
    }
}
