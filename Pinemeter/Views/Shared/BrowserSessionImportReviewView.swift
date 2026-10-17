import SwiftUI

struct BrowserSessionImportReviewView: View {
    @Bindable var appModel: AppModel
    @State private var review: BrowserSessionImportReview
    @State private var selectedSessionIds: Set<UUID>
    @State private var isScanning = false
    @State private var isConnecting = false
    @State private var connectionOutcome: BrowserScanOutcome?

    let onConnected: (BrowserScanOutcome) -> Void
    let onCancel: () -> Void

    init(
        appModel: AppModel,
        review: BrowserSessionImportReview,
        onConnected: @escaping (BrowserScanOutcome) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}
    ) {
        self.appModel = appModel
        self._review = State(initialValue: review)
        self._selectedSessionIds = State(initialValue: Set(review.sessions.map(\.id)))
        self.onConnected = onConnected
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Review browser sessions")
                    .font(.title2.weight(.semibold))
                Text("These browser sessions have not been verified as provider accounts. Select the sessions to connect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if review.sessions.isEmpty {
                        ContentUnavailableView(
                            "No sessions found",
                            systemImage: "person.crop.circle.badge.questionmark",
                            description: Text(emptyDescription)
                        )
                        .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ForEach(review.sessions) { session in
                            Toggle(isOn: selectionBinding(for: session.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(session.provider.displayName) in \(session.source.displayName)")
                                        .font(.callout.weight(.medium))
                                    Text(session.profileLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(isScanning || isConnecting)
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    if let outcome = connectionOutcome, !outcome.sessionFailures.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(outcome.totalImported > 0 ? "Some sessions need attention" : "Sessions could not connect", systemImage: "exclamationmark.triangle")
                                .font(.callout.weight(.medium))
                            ForEach(Array(outcome.sessionFailures.enumerated()), id: \.offset) { _, message in
                                CopyableErrorText(message, font: .caption)
                            }
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if !review.failures.isEmpty {
                        DisclosureGroup("Scan details") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(review.failures) { failure in
                                    CopyableErrorText(
                                        "\(failure.source.displayName), \(failure.provider.displayName): \(failure.message)",
                                        font: .caption,
                                        foregroundStyle: .orange
                                    )
                                }
                            }
                            .padding(.top, 6)
                        }
                    }

                    if review.offersFullDiskAccessSettings {
                        Button("Open Full Disk Access\u{2026}") {
                            SystemSettingsOpener.openFullDiskAccess()
                        }
                    }
                }
            }
            .frame(maxHeight: 360)

            Divider()

            HStack {
                Button(connectionOutcome == nil ? "Cancel" : "Done") { cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isConnecting)
                Spacer()
                Button("Scan Again") {
                    Task { await rescan() }
                }
                .disabled(isScanning || isConnecting)
                Button {
                    Task { await connectSelected() }
                } label: {
                    HStack(spacing: 6) {
                        if isConnecting { ProgressView().controlSize(.small) }
                        Text(isConnecting ? (appModel.importProgress ?? "Connecting\u{2026}") : "Connect Selected")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSessionIds.isEmpty || isScanning || isConnecting)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onExitCommand(perform: cancel)
        .interactiveDismissDisabled(isConnecting)
    }

    private var emptyDescription: String {
        review.scannedBrowsers.isEmpty
            ? "Open Chrome, Safari, or Firefox, then scan again."
            : "Sign in to Claude or ChatGPT in a scanned browser, then scan again."
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedSessionIds.contains(id) },
            set: { selected in
                if selected { selectedSessionIds.insert(id) }
                else { selectedSessionIds.remove(id) }
            }
        )
    }

    private func cancel() {
        guard !isConnecting else { return }
        if let connectionOutcome { onConnected(connectionOutcome) }
        else { onCancel() }
    }

    @MainActor
    private func rescan() async {
        isScanning = true
        review = await appModel.discoverBrowserSessions()
        selectedSessionIds = Set(review.sessions.map(\.id))
        isScanning = false
    }

    @MainActor
    private func connectSelected() async {
        isConnecting = true
        connectionOutcome = nil
        let selected = review.sessions.filter { selectedSessionIds.contains($0.id) }
        let outcome = await appModel.connectBrowserSessions(selected, discoveryFailures: review.failures)
        isConnecting = false
        if outcome.sessionFailures.isEmpty && outcome.discoveryFailures.isEmpty { onConnected(outcome) }
        else { connectionOutcome = outcome }
    }
}
