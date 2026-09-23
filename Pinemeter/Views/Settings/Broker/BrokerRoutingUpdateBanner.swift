import SwiftUI

/// Persistent entry point shared by the popover and every Broker settings pane.
struct BrokerRoutingUpdateBanner: View {
    /// Where the banner is shown. The popover is a glanceable surface, so the
    /// undo offer can be dismissed there; Broker settings is the durable place
    /// to find Undo Update, so it never hides the offer.
    enum Placement {
        case popover
        case settings
    }

    @Bindable var appModel: AppModel
    var placement: Placement = .settings
    @State private var isReviewPresented = false
    @State private var didUndo = false
    @State private var confirmsUndo = false

    private var isRevisionUndo: Bool { appModel.settings.broker.routingRecovery?.origin == "revision" }

    private var undoBody: String {
        let name = appModel.settings.broker.routingRecovery?.profileName ?? "profile"
        if isRevisionUndo {
            return "Restore the \(name) rules that were live before you used a saved revision, including local edits. Your accounts stay connected."
        }
        return "Restore your previous \(name) rules, including local edits. Your accounts stay connected.\(placement == .popover ? " Dismissing keeps Undo Update in Broker settings." : "")"
    }

    private var showsUndoBanner: Bool {
        guard appModel.settings.broker.canUndoRoutingUpdate else { return false }
        guard placement == .popover else { return true }
        return !appModel.settings.broker.isRoutingRecoveryDismissedInPopover
    }

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
            if showsUndoBanner {
                VStack(alignment: .leading, spacing: 10) {
                    if placement == .popover {
                        HStack(alignment: .firstTextBaseline) {
                            undoHeadline
                            Spacer()
                            Button {
                                appModel.settings.broker.isRoutingRecoveryDismissedInPopover = true
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Dismiss. Undo Update stays in Broker settings.")
                            .accessibilityLabel("Dismiss routing undo banner")
                        }
                    } else {
                        undoHeadline
                    }
                    Text(undoBody)
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
        .confirmationDialog(isRevisionUndo ? "Replace edits made after restoring?" : "Replace edits made after updating?", isPresented: $confirmsUndo, titleVisibility: .visible) {
            Button("Replace Edits and Undo", role: .destructive) { undo(discardingEdits: true) }
            Button("Keep Current Routing", role: .cancel) {}
        } message: {
            Text(isRevisionUndo ? "Undo restores the rules and local edits from before you used this revision." : "Undo restores your pre-update rules. Edits made since the update will be lost. Cancel and duplicate your current profile first to keep them.")
        }
        .sheet(isPresented: $isReviewPresented) {
            BrokerRoutingUpdateReview(appModel: appModel) {
                didUndo = false
                isReviewPresented = false
            }
        }
    }

    private var undoHeadline: some View {
        Label("Your previous routing is safe", systemImage: "arrow.uturn.backward.circle.fill")
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private func undo(discardingEdits: Bool = false) {
        didUndo = appModel.undoRoutingUpdate(discardingEdits: discardingEdits)
    }
}

struct BrokerRoutingUpdateReview: View {
    @Bindable var appModel: AppModel
    var revision: BrokerRevisionSelection? = nil
    var revisionValidation: ((BrokerRevisionSelection) -> String?)? = nil
    var onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsReplacement = false

    private var settings: BrokerSettings { appModel.settings.broker }
    private var restoreError: String? {
        guard let revision else { return nil }
        if let revisionValidation { return revisionValidation(revision) }
        return appModel.revisionRestoreError(selection: revision)
    }
    private var changes: [BrokerRoutingChange] {
        guard let revision else { return settings.routingUpdateSemanticChanges }
        guard let old = settings.activeProfileRules, let new = revision.rules else { return [] }
        let storedRoles = Set(
            revision.snapshot.profile(id: revision.profileID)?.rules.roles.keys.map { $0 } ?? []
        )
        let defaultedRoles = Set(BrokerPolicy.bundledDefault.roles.keys).subtracting(storedRoles)
        return settings.routingChanges(from: old, to: new, defaultedRoles: defaultedRoles)
    }
    private var canApply: Bool {
        guard let revision else { return settings.activeProfileHasUpdatedRules }
        return restoreError == nil && !changes.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(revision == nil ? "Review routing update" : "Review revision")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(settings.activeProfile?.name ?? "Routing profile")
                .font(.headline)
            if let revision {
                Text(revisionSubtitle(revision.snapshot))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(revision == nil ? "Changes take effect for new routing requests. Your accounts and connections stay in place. No app restart is needed. Models are listed in priority order." : "Using this revision changes only the routing rules for \(settings.activeProfile?.name ?? "your profile"). Your accounts, connections, instances, and usage tracking stay as they are. Models are listed in priority order.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if revision != nil && changes.isEmpty {
                        BrokerEmptyState(title: "No differences", systemImage: "equal.circle")
                    }
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                        changeBlock(change)
                    }
                }
            }
            .frame(maxHeight: 280)

            Label(revision == nil ? "Try it with confidence. Undo Update restores your previous rules, even after restarting Pinemeter." : "Use This Revision replaces your current Undo Update point. Undo Update then returns to the rules that are live right now.", systemImage: "arrow.uturn.backward.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            if settings.hasUnsavedRuleChanges {
                Label(revision == nil ? "This update replaces your local edits. They will be saved with your previous rules and restored by Undo Update." : "You have unsaved routing edits. Using this revision replaces them. They are kept with your current rules and come back with Undo Update.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(revision == nil ? Color.primary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let restoreError {
                Label("This revision can't be used. \(restoreError). Nothing was changed.", systemImage: "xmark.octagon")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(revision == nil ? "Apply Update" : "Use This Revision") {
                    if settings.hasUnsavedRuleChanges {
                        confirmsReplacement = true
                    } else {
                        apply()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
                .help(disabledActionHelp)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .confirmationDialog(revision == nil ? "Replace your local edits?" : "Replace your unsaved edits?", isPresented: $confirmsReplacement, titleVisibility: .visible) {
            Button(revision == nil ? "Replace Edits and Apply" : "Replace Edits and Use Revision", role: .destructive) { apply(discardingEdits: true) }
            Button(revision == nil ? "Cancel" : "Keep Current Routing", role: .cancel) {}
        } message: {
            Text(revision == nil ? "Your unsaved routing changes will be replaced by the published update." : "Your unsaved routing changes will be replaced by this revision. Undo Update brings them back.")
        }
    }

    @ViewBuilder
    private func changeBlock(_ change: BrokerRoutingChange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch change {
            case .role(let role):
                Text(role.role.capitalized).font(.headline)
                Text("\(revision == nil ? "Last applied" : "Now"): \(BrokerRoutingChange.describe(role.previous, includesRoute: revision == nil))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(role.proposedUsesDefaultRules
                    ? "This revision: default rules"
                    : "\(revision == nil ? "New" : "This revision"): \(BrokerRoutingChange.describe(role.proposed, includesRoute: revision == nil))")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            case .thresholds(let thresholds):
                if revision == nil {
                    Text("Quota limits updated.").font(.headline)
                } else {
                    Text("Quota limits").font(.headline)
                    ForEach(Array(thresholds.enumerated()), id: \.offset) { _, threshold in
                        Text("Now: \(threshold.field.label.lowercased()) \(threshold.previousValue)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("This revision: \(threshold.field.label.lowercased()) \(threshold.proposedValue)")
                            .font(.callout)
                    }
                }
            case .modelCapabilities:
                Text("Model availability, quota tracking, or reasoning options updated.")
                    .font(.headline)
            case .callerPolicy:
                Text("Agent access or fallback permissions updated.")
                    .font(.headline)
            case .connections:
                Text("Model connection preferences updated.")
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private var disabledActionHelp: String {
        if changes.isEmpty { return "These rules are already live." }
        return restoreError ?? ""
    }

    private func apply(discardingEdits: Bool = false) {
        if let revision {
            guard appModel.restoreProfileRules(selection: revision, discardingEdits: discardingEdits) else { return }
            onApplied()
            return
        }
        guard let id = settings.activeProfileID,
              appModel.applyRoutingUpdate(profileID: id, discardingEdits: discardingEdits) else { return }
        onApplied()
    }

    private func revisionSubtitle(_ snapshot: BrokerManifestHistorySnapshot) -> String {
        let date = snapshot.publishedAt ?? snapshot.recordedAt
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let title = snapshot.manifestRevision.map { "Revision \($0), published \(formatter.localizedString(for: date, relativeTo: Date()))" }
            ?? "Published \(date.formatted(date: .abbreviated, time: .omitted))"
        return snapshot.summary.map { "\(title) · \($0)" } ?? title
    }
}
