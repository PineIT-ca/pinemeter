import SwiftUI

struct RemoteHostDraft {
    var host = "" {
        didSet { if host != oldValue { isFingerprintConfirmed = false } }
    }
    var sshUser = ""
    var keyPath = "" {
        didSet { if keyPath != oldValue { isFingerprintConfirmed = false } }
    }
    var pinnedHostKey = "" {
        didSet { if pinnedHostKey != oldValue { isFingerprintConfirmed = false } }
    }
    var isFingerprintConfirmed = false

    var hasAllRequiredValues: Bool {
        !host.isEmpty && !sshUser.isEmpty && !keyPath.isEmpty && !pinnedHostKey.isEmpty
    }

    var fingerprint: String? {
        try? RemoteHostValidator.parsePinnedHostKey(pinnedHostKey).fingerprint
    }

    func validationError(existing: [RemoteHost]) -> String? {
        guard hasAllRequiredValues else { return nil }
        do {
            _ = try RemoteHostValidator.normalizedHost(host)
            _ = try RemoteHostValidator.normalizedSSHUser(sshUser)
            _ = try RemoteHostValidator.readPrivateKey(at: keyPath)
            _ = try RemoteHostValidator.parsePinnedHostKey(pinnedHostKey)
            if try RemoteHostValidator.isDuplicate(host: host, sshUser: sshUser, among: existing) {
                throw RemoteHostValidationError.duplicateHost
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func isValid(existing: [RemoteHost]) -> Bool {
        hasAllRequiredValues
            && isFingerprintConfirmed
            && validationError(existing: existing) == nil
    }
}

struct BrokerRemoteHostsPane: View {
    @Bindable var appModel: AppModel

    @State private var isAdding = false
    @State private var isSaving = false
    @State private var draft = RemoteHostDraft()
    @State private var saveError: String?
    @State private var removalError: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case addButton
        case host
        case sshUser
        case keyPath
        case pinnedHostKey
    }

    private var hosts: [RemoteHost] { appModel.settings.broker.remoteHosts }
    private var validationError: String? { draft.validationError(existing: hosts) }

    var body: some View {
        VStack(alignment: .leading, spacing: BrokerUI.sectionSpacing) {
            BrokerPaneHeader(
                "Remote hosts",
                purpose: "Hosts running Pinemeter Server that keep routing with this Mac's accounts while the Mac is asleep."
            ) {
                // The empty state carries its own, more prominent copy of
                // this button, next to the text that explains what it adds.
                if !showsEmptyState {
                    addHostButton
                        .focused($focusedField, equals: .addButton)
                }
            }

            if showsEmptyState {
                emptyState
            } else {
                hostsCard
            }
        }
    }

    private var showsEmptyState: Bool { hosts.isEmpty && !isAdding }

    private var addHostButton: some View {
        Button("Add Host\u{2026}") {
            isAdding = true
            saveError = nil
            focusedField = .host
        }
        .disabled(isAdding)
        .accessibilityLabel("Add remote host")
    }

    private var hostsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isAdding {
                addHostForm
            }

            if !hosts.isEmpty {
                VStack(spacing: 6) {
                    ForEach(hosts) { host in
                        hostRow(host)
                    }
                }
            }

            if let removalError {
                Text(removalError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .brokerCard()
    }

    // MARK: - Empty state

    /// What a remote host is and what adding one takes, in the card the list
    /// will occupy. The bare "No remote hosts configured." line said nothing
    /// about why anyone would want one, and this is the one pane whose
    /// feature is invisible until it is set up.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("No remote hosts yet")
                        .font(.headline)
                    Text(
                        "A remote host runs Pinemeter Server, a licensed broker service for Linux, "
                            + "macOS, and Windows. This Mac pushes "
                            + "its provider credentials and usage state to the host over SSH, so agents "
                            + "on that host can keep asking for model picks while the Mac is asleep or "
                            + "off the network."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("To add one you need")
                    .font(.callout.weight(.medium))
                requirementRow(
                    "SSH access to the host",
                    detail: "An address, a user, and a private key on this Mac that the host accepts.",
                    systemImage: "key"
                )
                requirementRow(
                    "The host's public key",
                    detail: "Pinned here and verified with the host's administrator, so a push never goes to an impostor.",
                    systemImage: "checkmark.shield"
                )
                requirementRow(
                    "Pinemeter Server installed and licensed on the host",
                    detail: "The push channel is one-way: the host cannot run anything on this Mac over it.",
                    systemImage: "server.rack"
                )
            }
            .padding(.leading, 40)

            addHostButton
                .buttonStyle(.borderedProminent)
                .focused($focusedField, equals: .addButton)
                .padding(.leading, 40)
        }
        .brokerCard()
        .accessibilityElement(children: .contain)
    }

    private func requirementRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var addHostForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Form {
                TextField("Host address", text: $draft.host, prompt: Text("host.example.com"))
                    .focused($focusedField, equals: .host)
                    .accessibilityLabel("Host address")

                TextField("SSH user", text: $draft.sshUser)
                    .focused($focusedField, equals: .sshUser)
                    .accessibilityLabel("SSH user")

                TextField(
                    "SSH key path",
                    text: $draft.keyPath,
                    prompt: Text("/Users/name/.ssh/id_ed25519")
                )
                    .focused($focusedField, equals: .keyPath)
                    .accessibilityLabel("SSH key path")

                TextField(
                    "Pinned host key",
                    text: $draft.pinnedHostKey,
                    prompt: Text("ssh-ed25519 base64-key"),
                    axis: .vertical
                )
                    .lineLimit(2...4)
                    .focused($focusedField, equals: .pinnedHostKey)
                    .accessibilityLabel("Pinned host key")
            }
            .formStyle(.columns)

            if let fingerprint = draft.fingerprint {
                LabeledContent("Fingerprint") {
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(
                "I verified this fingerprint with the host administrator.",
                isOn: $draft.isFingerprintConfirmed
            )
            .disabled(draft.fingerprint == nil)

            Text("Obtain the host key and verify its fingerprint through a trusted channel.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { cancelAdd() }
                    .disabled(isSaving)
                Button {
                    Task { await addHost() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Add Host")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isSaving || !draft.isValid(existing: hosts))
            }
        }
        .padding(.vertical, 2)
    }

    private func hostRow(_ host: RemoteHost) -> some View {
        let isBusy = appModel.remoteHostPushInProgress.contains(host.id)
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    hostIdentity(host, singleLine: true)
                    Spacer(minLength: 8)
                    hostActions(host, isBusy: isBusy)
                }
                VStack(alignment: .leading, spacing: 6) {
                    hostIdentity(host, singleLine: false)
                    hostActions(host, isBusy: isBusy)
                }
            }

            Text(host.keyPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("SSH key path, \(host.keyPath)")

            Text(host.pinnedHostKeyFingerprint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Pinned host key fingerprint, \(host.pinnedHostKeyFingerprint)")

            lastPushView(host)

            credentialView(host)

            if let error = host.sanitizedError, host.lastPushResult == .failed {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .brokerInsetRow()
        .onChange(of: host.lastPushAt) { previous, completedAt in
            guard previous != completedAt, let completedAt, let result = host.lastPushResult else { return }
            let outcome = result == .succeeded ? "succeeded" : "failed"
            AccessibilityNotification.Announcement(
                "Push to \(host.host) \(outcome) at \(formatted(completedAt))."
            ).post()
        }
    }

    private func hostIdentity(_ host: RemoteHost, singleLine: Bool) -> some View {
        Text("\(host.sshUser)@\(host.host)")
            .font(.callout.weight(.medium))
            .textSelection(.enabled)
            .lineLimit(singleLine ? 1 : nil)
            .fixedSize(horizontal: singleLine, vertical: !singleLine)
    }

    private func hostActions(_ host: RemoteHost, isBusy: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await appModel.pushRemoteHostNow(id: host.id) }
            } label: {
                if isBusy {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Pushing…")
                    }
                } else {
                    Text("Push now")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
            .accessibilityLabel(isBusy ? "Pushing to \(host.host)" : "Push now to \(host.host)")

            Menu {
                Button("Remove host", role: .destructive) {
                    Task { await removeHost(host) }
                }
                .disabled(isBusy)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isBusy)
            .accessibilityLabel("Actions for \(host.host)")
        }
    }

    @ViewBuilder
    private func lastPushView(_ host: RemoteHost) -> some View {
        if let completedAt = host.lastPushAt, let result = host.lastPushResult {
            let outcome = result == .succeeded ? "Succeeded" : "Failed"
            Text("Last push: \(outcome) · \(formatted(completedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(host.host), last push \(outcome.lowercased()), \(formatted(completedAt))")
        } else {
            Text("Not pushed yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(host.host), not pushed yet")
        }
    }

    private func credentialView(_ host: RemoteHost) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                BrokerChip(
                    text: "Credentials: \(credentialTitle(host.credentialStatus))",
                    tint: credentialTint(host.credentialStatus)
                )
                .accessibilityLabel(
                    "\(host.host), credentials \(credentialTitle(host.credentialStatus).lowercased())"
                )

                if let observedAt = host.observedAt {
                    Text("Observed \(formatted(observedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Both remedies live in Accounts, so the row links there rather
            // than leaving the user to find the pane from the instruction.
            if host.credentialStatus == .expired || host.credentialStatus == .challenged {
                HStack(spacing: 8) {
                    if host.credentialStatus == .expired {
                        Text("Reconnect the affected account in Settings > Accounts, then push again.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Complete the provider's sign-in check, then push again.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("Open Accounts") {
                        NotificationCenter.default.post(name: .openAccountsSettings, object: nil)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens Accounts settings")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cancelAdd() {
        draft = RemoteHostDraft()
        saveError = nil
        isAdding = false
        focusedField = .addButton
    }

    @MainActor
    private func addHost() async {
        guard draft.isValid(existing: hosts) else { return }
        isSaving = true
        saveError = nil
        do {
            try await appModel.addRemoteHost(
                host: draft.host,
                sshUser: draft.sshUser,
                keyPath: draft.keyPath,
                pinnedHostKey: draft.pinnedHostKey
            )
            draft = RemoteHostDraft()
            isAdding = false
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }

    @MainActor
    private func removeHost(_ host: RemoteHost) async {
        removalError = nil
        do {
            try await appModel.removeRemoteHost(id: host.id)
        } catch {
            removalError = "Could not remove \(host.sshUser)@\(host.host): \(error.localizedDescription)"
        }
    }

    private func credentialTitle(_ status: RemoteCredentialStatus) -> String {
        switch status {
        case .unknown: "Unknown"
        case .fresh: "Fresh"
        case .expired: "Expired"
        case .challenged: "Challenged"
        }
    }

    private func credentialTint(_ status: RemoteCredentialStatus) -> Color {
        switch status {
        case .unknown: .secondary
        case .fresh: .green
        case .expired: .red
        case .challenged: .orange
        }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .shortened)
    }
}
