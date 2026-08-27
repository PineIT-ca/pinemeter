//
//  BrokerProfileBar.swift
//  Pinemeter
//
//  Agent rule profiles: load, save, duplicate, rename, delete, export, import.
//
//  The bar sits above the role editor because it frames everything below it —
//  the same reason a document app puts the document name in the title bar and
//  not in a menu. Two states have to be unmistakable at a glance: which
//  profile is loaded, and whether what is on screen still matches it. That is
//  the entire job of the "Edited" pill; without it, "Revert" and "Save" are
//  guesses.
//
//  Profiles deliberately carry rules only (see `BrokerRuleSet`). Loading one
//  never touches this Mac's T3 instances or account bindings.
//

import SwiftUI
import UniformTypeIdentifiers

struct BrokerProfileBar: View {
    @Bindable var appModel: AppModel

    /// A profile the user asked to load while the current one has unsaved
    /// edits — held until the confirmation dialog resolves.
    @State private var pendingProfileID: UUID?
    @State private var isNamingNewProfile = false
    @State private var isRenamingProfile = false
    @State private var isConfirmingDelete = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var draftName = ""
    @State private var feedback: Feedback?

    private struct Feedback: Equatable {
        let message: String
        let isError: Bool
    }

    private var settings: BrokerSettings { appModel.settings.broker }
    private var activeProfile: BrokerAgentProfile? { settings.activeProfile }
    private var isEdited: Bool { settings.hasUnsavedProfileEdits }
    /// A user profile only — built-ins AND remote presets both refuse an
    /// in-place save, rename, or delete. A remote preset is not flagged
    /// `isBuiltIn` (that identity is reserved for the compiled list), so this
    /// checks manifest membership directly rather than relying on the flag.
    private var canSaveInPlace: Bool {
        guard let activeProfile else { return false }
        return !activeProfile.isBuiltIn && !settings.isRemotePreset(id: activeProfile.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "Rule Profile",
                systemImage: "square.stack.3d.up",
                subtitle: "Named sets of routing rules you can switch between. "
                    + "A profile carries roles, chains, thresholds and caller rules — "
                    + "your T3 instances and account bindings always stay on this Mac.",
                help: .profiles
            )

            HStack(spacing: 8) {
                profileMenu

                // The description lives beside the menu rather than inside its
                // label: `.borderlessButton` renders only the label's first
                // text run, so a two-line label silently loses its second line.
                Text(activeProfile?.detail ?? "Rules that belong to no saved profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)

                // Distinct from "Edited" on purpose: this is the profile
                // moving under the user (an app update improving a built-in),
                // not the user changing anything. Saving or reverting is the
                // wrong response; re-picking the profile is the right one.
                if settings.activeProfileHasUpdatedRules {
                    BrokerChip(
                        text: "Updated",
                        systemImage: "arrow.down.circle",
                        tint: .accentColor,
                        style: .outline
                    )
                    .help(
                        "This profile's saved rules changed since you loaded it. "
                            + "Pick it again to take the new rules."
                    )
                }

                if isEdited {
                    BrokerChip(text: "Edited", systemImage: "pencil", tint: .orange, style: .outline)
                        .help(
                            canSaveInPlace
                                ? "The rules below no longer match this profile. Save or revert."
                                : "The rules below no longer match this profile, and it cannot be "
                                    + "edited in place. Duplicate it to keep the changes."
                        )
                }

                Spacer(minLength: 4)

                if isEdited {
                    if canSaveInPlace {
                        Button("Save") { saveActiveProfile() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("Write the current rules back into this profile")
                    } else {
                        Button("Duplicate\u{2026}") { beginNamingNewProfile() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("This profile cannot be edited in place. Save these rules as your own.")
                    }
                    Button("Revert") { revertActiveProfile() }
                        .controlSize(.small)
                        .help("Discard the local edits and reload this profile")
                }

                actionsMenu
            }

            if let unknownInstances = unknownInstanceCaption {
                Label(unknownInstances, systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let feedback {
                Label(
                    feedback.message,
                    systemImage: feedback.isError ? "exclamationmark.triangle" : "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(feedback.isError ? .red : .green)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .brokerCard()
        .confirmationDialog(
            activeProfile == nil
                ? "These rules are not saved in any profile"
                : "Unsaved changes to \u{201C}\(activeProfile?.name ?? "this profile")\u{201D}",
            isPresented: pendingProfilePresented,
            titleVisibility: .visible
        ) {
            if canSaveInPlace {
                Button("Save and Switch") {
                    appModel.settings.broker.saveActiveProfile()
                    applyPending()
                }
            } else {
                // Built-in and Custom both refuse an in-place save, so the
                // only way to keep what is on screen is to name it. Doing so
                // cancels the switch: the user re-picks the target once their
                // work is safe.
                Button("Save as New Profile\u{2026}") {
                    pendingProfileID = nil
                    beginNamingNewProfile()
                }
            }
            Button("Discard and Switch", role: .destructive) { applyPending() }
            Button("Cancel", role: .cancel) { pendingProfileID = nil }
        } message: {
            Text(pendingSwitchMessage)
        }
        .alert("New Profile", isPresented: $isNamingNewProfile) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { draftName = "" }
            Button("Create") { createProfile() }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Saves the rules currently on screen as a profile you can switch back to.")
        }
        .alert("Rename Profile", isPresented: $isRenamingProfile) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { draftName = "" }
            Button("Rename") { renameProfile() }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "Delete \u{201C}\(activeProfile?.name ?? "")\u{201D}?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) { deleteProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The rules stay loaded and keep routing; only the saved profile is removed.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: BrokerProfileDocument(
                profile: settings.exportableProfile(named: activeProfile?.name ?? "Broker Rules")
            ),
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                feedback = Feedback(message: "Exported the rules on screen.", isError: false)
            case .failure(let error):
                feedback = Feedback(message: "Export failed: \(error.localizedDescription)", isError: true)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json]
        ) { result in
            importProfile(from: result)
        }
    }

    // MARK: - Profile menu

    private var profileMenu: some View {
        Menu {
            Section("Built-in") {
                ForEach(BrokerAgentProfile.builtIns) { profile in
                    profileMenuItem(profile)
                }
            }
            // Extra presets fetched from the manifest. Same apply flow as a
            // built-in (`profileMenuItem` doesn't distinguish), but they sit
            // in their own section so it stays visible that these came from
            // outside the app rather than shipping with it.
            if !settings.remotePresets.isEmpty {
                Section("From Manifest") {
                    ForEach(settings.remotePresets) { profile in
                        profileMenuItem(profile)
                    }
                }
            }
            if !settings.profiles.isEmpty {
                Section("My Profiles") {
                    ForEach(settings.profiles.sorted(by: byName)) { profile in
                        profileMenuItem(profile)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: activeProfile?.symbolName ?? "questionmark.square.dashed")
                    .foregroundStyle(Color.accentColor)
                Text(activeProfile?.name ?? "Custom")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Rule profile")
        .accessibilityValue(activeProfile?.name ?? "Custom")
    }

    private func profileMenuItem(_ profile: BrokerAgentProfile) -> some View {
        Button {
            requestApply(profile.id)
        } label: {
            // A checkmark rather than a selection binding: the menu has to be
            // able to re-pick the active profile (that is how you reload it
            // after edits), which a Picker's selection would swallow.
            Label(
                profile.id == settings.activeProfileID ? "\u{2713} \(profile.name)" : profile.name,
                systemImage: profile.symbolName
            )
        }
        .help(profile.detail)
    }

    private func byName(_ lhs: BrokerAgentProfile, _ rhs: BrokerAgentProfile) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // MARK: - Actions menu

    private var actionsMenu: some View {
        Menu {
            Button("Save Changes") { saveActiveProfile() }
                .disabled(!canSaveInPlace || !isEdited)
            Button("Revert to Loaded Rules") { revertActiveProfile() }
                .disabled(activeProfile == nil || !isEdited)
            Button("Load Updated Rules") {
                if let id = activeProfile?.id { requestApply(id) }
            }
            .disabled(!settings.activeProfileHasUpdatedRules)

            Divider()

            Button("Save as New Profile\u{2026}") { beginNamingNewProfile() }
            Button("Rename\u{2026}") { beginRenamingProfile() }
                .disabled(!canSaveInPlace)
            Button("Delete\u{2026}", role: .destructive) { isConfirmingDelete = true }
                .disabled(!canSaveInPlace)

            Divider()

            Button("Export\u{2026}") { isExporting = true }
            Button("Import\u{2026}") { isImporting = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Profile actions")
        .accessibilityLabel("Profile actions")
    }

    // MARK: - Captions

    /// Instances the loaded rules route to that this Mac has no row for. A
    /// warning, never a block — the broker still ranks those candidates, they
    /// just cannot dispatch, and saying so beats a silent dead lane.
    private var unknownInstanceCaption: String? {
        let unknown = settings.unknownInstanceReferences(in: settings.policy.ruleSet)
        guard !unknown.isEmpty else { return nil }
        let names = unknown.joined(separator: ", ")
        return unknown.count == 1
            ? "These rules route to a T3 instance this Mac has no row for: \(names). "
                + "Add it under Instances, or point those candidates elsewhere."
            : "These rules route to T3 instances this Mac has no rows for: \(names). "
                + "Add them under Instances, or point those candidates elsewhere."
    }

    private var exportFilename: String {
        let name = activeProfile?.name ?? "Broker Rules"
        let slug = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return slug.isEmpty ? "broker-rules" : slug
    }

    // MARK: - Mutations

    private var pendingSwitchMessage: String {
        if activeProfile == nil {
            return "The rules currently on screen belong to no profile. "
                + "Loading one replaces them and they cannot be recovered."
        }
        return canSaveInPlace
            ? "Loading a profile replaces the rules currently on screen."
            : "This profile cannot be overwritten, so these edits will be lost."
    }

    private var pendingProfilePresented: Binding<Bool> {
        Binding(
            get: { pendingProfileID != nil },
            set: { if !$0 { pendingProfileID = nil } }
        )
    }

    /// Loading a profile overwrites whatever is on screen, so it confirms
    /// first whenever those rules are stored nowhere else. That includes the
    /// "Custom" state (no active profile), which is the case with no revert
    /// path at all, and the case where the chosen profile is the active one,
    /// since re-picking it is a reload and discards the same edits.
    private func requestApply(_ id: UUID) {
        feedback = nil
        guard settings.hasUnsavedRuleChanges else {
            apply(id)
            return
        }
        pendingProfileID = id
    }

    private func applyPending() {
        guard let pendingProfileID else { return }
        apply(pendingProfileID)
        self.pendingProfileID = nil
    }

    private func apply(_ id: UUID) {
        appModel.settings.broker.applyProfile(id: id)
        if let name = appModel.settings.broker.activeProfile?.name {
            feedback = Feedback(message: "Loaded \u{201C}\(name)\u{201D}.", isError: false)
        }
    }

    private func saveActiveProfile() {
        guard appModel.settings.broker.saveActiveProfile() else { return }
        feedback = Feedback(
            message: "Saved to \u{201C}\(activeProfile?.name ?? "profile")\u{201D}.",
            isError: false
        )
    }

    private func revertActiveProfile() {
        appModel.settings.broker.revertToActiveProfile()
        feedback = Feedback(
            message: "Reloaded \u{201C}\(activeProfile?.name ?? "profile")\u{201D}.",
            isError: false
        )
    }

    private func beginNamingNewProfile() {
        draftName = appModel.settings.broker.uniqueProfileName(activeProfile?.name ?? "My Rules")
        isNamingNewProfile = true
    }

    private func createProfile() {
        appModel.settings.broker.createProfile(named: draftName)
        feedback = Feedback(
            message: "Created \u{201C}\(appModel.settings.broker.activeProfile?.name ?? draftName)\u{201D}.",
            isError: false
        )
        draftName = ""
    }

    private func beginRenamingProfile() {
        draftName = activeProfile?.name ?? ""
        isRenamingProfile = true
    }

    private func renameProfile() {
        guard let id = activeProfile?.id else { return }
        appModel.settings.broker.renameProfile(id: id, to: draftName)
        draftName = ""
    }

    private func deleteProfile() {
        guard let profile = activeProfile, !profile.isBuiltIn else { return }
        appModel.settings.broker.deleteProfile(id: profile.id)
        feedback = Feedback(
            message: "Deleted \u{201C}\(profile.name)\u{201D}. Its rules are still loaded.",
            isError: false
        )
    }

    private func importProfile(from result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let data = try Data(contentsOf: url)
                let imported = try BrokerAgentProfile.decodeExported(from: data)
                let id = appModel.settings.broker.importProfile(imported)
                let storedName = appModel.settings.broker.profiles.first { $0.id == id }?.name
                    ?? imported.name
                feedback = Feedback(
                    message: "Imported \u{201C}\(storedName)\u{201D}. Pick it above to load its rules.",
                    isError: false
                )
            } catch {
                feedback = Feedback(
                    message: (error as? BrokerProfileImportError)?.localizedDescription
                        ?? "That file could not be read as a rule profile.",
                    isError: true
                )
            }
        case .failure(let error):
            feedback = Feedback(message: "Import failed: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Document

/// Plain JSON on disk, so an exported profile stays readable, diffable and
/// checkable into a repo alongside the agent instructions it belongs with.
struct BrokerProfileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var profile: BrokerAgentProfile

    init(profile: BrokerAgentProfile) {
        self.profile = profile
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        profile = try JSONDecoder().decode(BrokerAgentProfile.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(profile))
    }
}
