//
//  BrokerPresetManifestCard.swift
//  Pinemeter
//
//  Settings surface for the remote preset manifest: whether Pinemeter
//  fetches them at all, their URLs, and when each last checked. Deliberately
//  separate from the profile bar above it — this card only controls whether
//  new presets show up there to be picked. Fetching never applies one; that
//  stays an explicit click in the profile menu (`BrokerProfileBar`).
//

import SwiftUI

struct BrokerPresetManifestCard: View {
    @Bindable var appModel: AppModel
    var historyStateOverride: ((BrokerPresetManifestSource) -> BrokerManifestHistoryState)? = nil

    @State private var isRefreshing = false
    @State private var reviewedRevision: BrokerRevisionSelection?

    private var config: BrokerPresetManifestConfig { appModel.settings.broker.presetManifest }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "Preset Manifest",
                systemImage: "arrow.down.doc",
                subtitle: "Rule profiles Pinemeter fetches from one or more URLs. A manifest "
                    + "adds named profiles and can publish new rules for a built-in, which is "
                    + "how routing is corrected between app versions. Fetching only downloads "
                    + "them; applying one is always your own click, from the profile menu above."
            )

            Toggle(
                "Fetch presets from manifest",
                isOn: $appModel.settings.broker.presetManifest.isEnabled
            )
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(
                "Notify me when routing updates arrive",
                isOn: $appModel.settings.broker.routingUpdateNotificationsEnabled
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!config.isEnabled)

            if config.isEnabled {
                ForEach($appModel.settings.broker.presetManifest.sources) { $source in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            TextField(
                                "https://\u{2026}/broker-presets.json",
                                text: $source.urlString
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)
                            .disableAutocorrection(true)
                            .foregroundStyle(isURLValid(source) ? Color.primary : Color.red)
                            .accessibilityLabel("Preset manifest URL")
                            .onChange(of: source.urlString) { _, _ in
                                // A stale ETag from the URL this replaced must never
                                // answer for the new one — see `AppModel.presetManifestURLChanged()`.
                                appModel.presetManifestURLChanged(sourceID: source.id)
                            }

                            Button(role: .destructive) {
                                appModel.removePresetManifestSource(id: source.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove preset manifest URL")
                            .disabled(isRefreshing)
                        }

                        if !isURLValid(source) {
                            Text("Enter an https URL.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Text(statusCaption(for: source))
                            .font(.caption)
                            .foregroundStyle(source.lastError == nil ? Color.secondary : Color.red)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        DisclosureGroup {
                            historyContent(for: source)
                                .padding(.top, 4)
                        } label: {
                            Text("History")
                                .font(.caption)
                        }
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        appModel.addPresetManifestSource()
                    } label: {
                        Label("Add URL", systemImage: "plus")
                    }
                    .controlSize(.small)
                    .disabled(isRefreshing)

                    Spacer(minLength: 8)

                    Button {
                        Task {
                            isRefreshing = true
                            await appModel.refreshPresetManifest(force: true)
                            isRefreshing = false
                        }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Check Now")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isRefreshing || !config.sources.contains(where: isURLValid))
                }
            }
        }
        .brokerCard()
        .sheet(item: $reviewedRevision) { selection in
            BrokerRoutingUpdateReview(appModel: appModel, revision: selection) {
                reviewedRevision = nil
            }
        }
    }

    private func isURLValid(_ source: BrokerPresetManifestSource) -> Bool {
        let trimmed = source.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        return url.scheme?.lowercased() == "https"
    }

    private func statusCaption(for source: BrokerPresetManifestSource) -> String {
        if let lastError = source.lastError, !lastError.isEmpty {
            return lastError
        }
        guard let lastCheckedAt = source.lastCheckedAt else {
            return "Never checked."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: lastCheckedAt, relativeTo: Date()))."
    }

    @ViewBuilder
    private func historyContent(for source: BrokerPresetManifestSource) -> some View {
        switch historyStateOverride?(source) ?? appModel.manifestHistoryState(for: source) {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading history…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .readError:
            Text("Couldn't read saved revisions. Your routing is unaffected. "
                + "Check Now will save the next revision.")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded(let revisions) where revisions.isEmpty:
            BrokerEmptyState(
                title: "No saved revisions yet",
                systemImage: "clock.arrow.circlepath",
                hint: "Pinemeter keeps the last 10 changed revisions from this URL after each "
                    + "successful check. Click Check Now to fetch one."
            )
        case .loaded(let revisions):
            let revisions = Array(revisions.reversed())
            let liveRevisionID = liveRevisionID(for: source, revisions: revisions)
            VStack(spacing: 8) {
                ForEach(Array(revisions.enumerated()), id: \.element.id) { index, revision in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(historyTitle(revision))
                                .font(.callout)
                            Text(historyDetail(revision))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 4) {
                            if index == 0 {
                                BrokerChip(text: "Latest", tint: .secondary)
                            }
                            if revision.id == liveRevisionID {
                                BrokerChip(text: "Live", tint: .accentColor)
                            }
                            Button("Use Revision…") {
                                guard let profileID = appModel.settings.broker.activeProfileID else { return }
                                reviewedRevision = BrokerRevisionSelection(
                                    namespace: BrokerManifestHistoryNamespace(sourceID: source.id, urlString: source.urlString),
                                    snapshot: revision, profileID: profileID
                                )
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .disabled(isRefreshing || revision.id == liveRevisionID
                                || appModel.settings.broker.activeProfileID.flatMap { revision.profile(id: $0) } == nil)
                            .help(historyActionHelp(revision, liveRevisionID: liveRevisionID))
                            .accessibilityLabel("Use \(historyTitle(revision).lowercased())")
                        }
                        .layoutPriority(1)
                    }
                    .brokerInsetRow()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(historyAccessibilityLabel(
                        revision,
                        isLatest: index == 0,
                        isLive: revision.id == liveRevisionID
                    ))
                }
            }
        }
    }

    private func historyTitle(_ revision: BrokerManifestHistorySnapshot) -> String {
        if let manifestRevision = revision.manifestRevision {
            return "Revision \(manifestRevision)"
        }
        return "Published \(historyDate(revision).formatted(date: .abbreviated, time: .omitted))"
    }

    private func historyDetail(_ revision: BrokerManifestHistorySnapshot) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let published = formatter.localizedString(for: historyDate(revision), relativeTo: Date())
        guard let summary = revision.summary else { return published }
        return "\(published) · \(summary)"
    }

    private func historyAccessibilityLabel(
        _ revision: BrokerManifestHistorySnapshot,
        isLatest: Bool,
        isLive: Bool
    ) -> String {
        let published = historyDate(revision).formatted(date: .long, time: .omitted)
        return [
            historyTitle(revision),
            published,
            isLatest ? "Latest" : nil,
            isLive ? "Live" : nil,
        ]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func liveRevisionID(
        for source: BrokerPresetManifestSource,
        revisions: [BrokerManifestHistorySnapshot]
    ) -> UUID? {
        guard let activeProfileID = appModel.settings.broker.activeProfileID,
              let activeRules = appModel.settings.broker.activeProfileRules else { return nil }
        let namespace = BrokerManifestHistoryNamespace(sourceID: source.id, urlString: source.urlString)
        let matchesRules: (BrokerManifestHistorySnapshot) -> Bool = {
            $0.profile(id: activeProfileID)?.rules.fillingMissingRoles == activeRules
        }

        if let recovery = appModel.settings.broker.routingRecovery,
           recovery.origin == "revision",
           recovery.profileID == activeProfileID,
           let recoverySource = recovery.source,
           let fingerprint = recovery.revisionFingerprint {
            guard recoverySource == namespace, recovery.appliedRules == activeRules else {
                return nil
            }
            return revisions.first(where: {
                $0.contentDigest == fingerprint && matchesRules($0)
            })?.id
        }

        if !source.cachedPresets.isEmpty || source.cachedAgentSetup != nil {
            guard let currentFingerprint = try? BrokerManifestHistoryStore.contentDigest(
                presets: source.cachedPresets,
                agentSetup: source.cachedAgentSetup
            ) else { return nil }
            return revisions.first(where: {
                $0.contentDigest == currentFingerprint && matchesRules($0)
            })?.id
        }

        // Legacy baselines lack revision identity. Newest-first ordering makes
        // the one rule-equality fallback deterministic.
        return revisions.first(where: matchesRules)?.id
    }

    private func historyActionHelp(
        _ revision: BrokerManifestHistorySnapshot,
        liveRevisionID: UUID?
    ) -> String {
        if revision.id == liveRevisionID { return "These rules are already live." }
        guard let activeProfileID = appModel.settings.broker.activeProfileID,
              revision.profile(id: activeProfileID) != nil else {
            return "This revision does not contain the active profile."
        }
        if isRefreshing { return "Wait for the current check to finish." }
        return "Review this revision for the active profile."
    }

    private func historyDate(_ revision: BrokerManifestHistorySnapshot) -> Date {
        revision.publishedAt ?? revision.recordedAt
    }
}
