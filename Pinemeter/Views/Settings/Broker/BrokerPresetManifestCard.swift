//
//  BrokerPresetManifestCard.swift
//  Pinemeter
//
//  Settings surface for the remote preset manifest: whether Pinemeter
//  fetches it at all, which URL, and when it last checked. Deliberately
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
                subtitle: "Extra named rule profiles Pinemeter fetches from GitHub. "
                    + "Fetching only downloads them; applying one is always your own click, "
                    + "from the profile menu above."
            )

            Toggle(
                "Fetch presets from manifest",
                isOn: $appModel.settings.broker.presetManifest.isEnabled
            )
            .toggleStyle(.switch)
            .controlSize(.small)

            if config.isEnabled {
                TextField(
                    "https://\u{2026}/broker-presets.json",
                    text: $appModel.settings.broker.presetManifest.urlString
                )
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .disableAutocorrection(true)
                .foregroundStyle(isURLValid ? Color.primary : Color.red)
                .accessibilityLabel("Preset manifest URL")
                .onChange(of: appModel.settings.broker.presetManifest.urlString) { _, _ in
                    // A stale ETag from the URL this replaced must never
                    // answer for the new one — see `AppModel.presetManifestURLChanged()`.
                    appModel.presetManifestURLChanged()
                }

                if !isURLValid {
                    Text("Enter an https URL.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(statusCaption)
                        .font(.caption)
                        .foregroundStyle(config.lastError == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

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
                    .disabled(isRefreshing || !isURLValid)
                }
            }
        }
        .brokerCard()
    }

    private var isURLValid: Bool {
        let trimmed = config.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        return url.scheme?.lowercased() == "https"
    }

    private var statusCaption: String {
        if let lastError = config.lastError, !lastError.isEmpty {
            return lastError
        }
        guard let lastCheckedAt = config.lastCheckedAt else {
            return "Never checked."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: lastCheckedAt, relativeTo: Date()))."
    }
}
