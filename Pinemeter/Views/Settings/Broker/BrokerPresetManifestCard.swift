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

    @State private var isRefreshing = false

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
}
