import SwiftUI

/// Persistent entry point shared by the popover and every Broker settings pane.
struct BrokerRoutingUpdateBanner: View {
    @Bindable var appModel: AppModel
    @State private var isReviewPresented = false
    @State private var didUndo = false
    @State private var confirmsUndo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appModel.settings.broker.activeProfileHasUpdatedRules {
                VStack(alignment: .leading, spacing: 10) {
                    Label(didUndo ? "Previous routing restored" : "Routing update available", systemImage: didUndo ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.headline)
                    Text("New model recommendations for \(appModel.settings.broker.activeProfile?.name ?? "your profile") are ready. Apply them to update your routing.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Review Update") { isReviewPresented = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.accentColor.opacity(0.12))
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 4) }
                .accessibilityElement(children: .contain)
            }
            if appModel.settings.broker.canUndoRoutingUpdate {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Your previous routing is safe", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Restore your previous \(appModel.settings.broker.routingRecovery?.profileName ?? "profile") rules, including local edits. Your accounts stay connected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Undo Update", systemImage: "arrow.uturn.backward") {
                        if appModel.settings.broker.hasUnsavedRuleChanges {
                            confirmsUndo = true
                        } else {
                            undo()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.green.opacity(0.08))
                .overlay(alignment: .leading) { Rectangle().fill(Color.green).frame(width: 4) }
                .accessibilityElement(children: .contain)
            }
        }
        .confirmationDialog("Replace edits made after updating?", isPresented: $confirmsUndo, titleVisibility: .visible) {
            Button("Replace Edits and Undo", role: .destructive) { undo(discardingEdits: true) }
            Button("Keep Current Routing", role: .cancel) {}
        } message: {
            Text("Undo restores your pre-update rules. Edits made since the update will be lost. Cancel and duplicate your current profile first to keep them.")
        }
        .sheet(isPresented: $isReviewPresented) {
            BrokerRoutingUpdateReview(appModel: appModel) {
                didUndo = false
                isReviewPresented = false
            }
        }
    }

    private func undo(discardingEdits: Bool = false) {
        didUndo = appModel.undoRoutingUpdate(discardingEdits: discardingEdits)
    }
}

struct BrokerRoutingUpdateReview: View {
    @Bindable var appModel: AppModel
    var onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsReplacement = false

    private var settings: BrokerSettings { appModel.settings.broker }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review routing update")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(settings.activeProfile?.name ?? "Routing profile")
                .font(.headline)
            Text("Changes take effect for new routing requests. Your accounts and connections stay in place. No app restart is needed. Models are listed in priority order.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(settings.routingUpdateChanges, id: \.self) { change in
                        let lines = change.split(separator: "\n", omittingEmptySubsequences: false)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(lines[0])).font(.headline)
                            ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { index, line in
                                Text(String(line))
                                    .font(.callout)
                                    .foregroundStyle(index == 0 ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .frame(maxHeight: 280)

            Label("Try it with confidence. Undo Update restores your previous rules, even after restarting Pinemeter.", systemImage: "arrow.uturn.backward.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            if settings.hasUnsavedRuleChanges {
                Label("This update replaces your local edits. They will be saved with your previous rules and restored by Undo Update.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply Update") {
                    if settings.hasUnsavedRuleChanges {
                        confirmsReplacement = true
                    } else {
                        apply()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!settings.activeProfileHasUpdatedRules)
            }
        }
        .padding(24)
        .frame(width: 480)
        .confirmationDialog("Replace your local edits?", isPresented: $confirmsReplacement, titleVisibility: .visible) {
            Button("Replace Edits and Apply", role: .destructive) { apply(discardingEdits: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your unsaved routing changes will be replaced by the published update.")
        }
    }

    private func apply(discardingEdits: Bool = false) {
        guard let id = settings.activeProfileID,
              appModel.applyRoutingUpdate(profileID: id, discardingEdits: discardingEdits) else { return }
        onApplied()
    }
}
