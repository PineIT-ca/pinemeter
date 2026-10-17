import SwiftUI

struct BrokerInstructionDispatchCard: View {
    private enum AccessMode: Hashable {
        case none, thisRun, allRuns
    }

    struct InitialDispatchState {
        var projects: [T3Project] = []
        var projectListState: T3DispatchProjectListState = .notLoaded
        var isDispatching = false
        var failure: T3DispatchFailure?
        var modelSource: T3DispatchModelSource?
        var outstandingRunState: T3DispatchOutstandingRunState = .none
        var lastDispatchedAt: Date?
        var lastDispatchThreadID: String?
    }

    @Bindable var appModel: AppModel
    @State private var pairingCredential = ""
    @State private var fullAccessForNextRun = false

    /// Snapshot seams for values loaded by `.task`. Off-screen hosting does not
    /// reliably finish that task before capture; production call sites pass nil.
    private let initialConnection: T3DispatchConnection?
    private let initialDispatchState: InitialDispatchState?
    private let now: Date?

    init(
        appModel: AppModel,
        initialConnection: T3DispatchConnection? = nil,
        initialDispatchState: InitialDispatchState? = nil,
        now: Date? = nil
    ) {
        self.appModel = appModel
        self.initialConnection = initialConnection
        self.initialDispatchState = initialDispatchState
        self.now = now
    }

    var body: some View {
        Group {
            if let now {
                card(at: now)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    card(at: context.date)
                }
            }
        }
        .task(id: connection) {
            guard initialConnection == nil, isConnected else { return }
            await appModel.loadT3Projects()
        }
    }

    private func card(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "Run the check",
                systemImage: "paperplane",
                subtitle: "Connect this Mac to T3 with a pairing credential. The exchanged token stays in Keychain."
            )

            Picker("Harness", selection: $appModel.settings.broker.instructionDispatch.harness) {
                Text("T3").tag(InstructionDispatchHarness.t3)
            }
            .pickerStyle(.menu)

            connectionContent(at: date)
            automaticDispatchToggle
        }
        .brokerCard()
    }

    @ViewBuilder
    private func connectionContent(at date: Date) -> some View {
        if needsReconnect(at: date) {
            reconnectContent(at: date)
        } else {
            switch connection {
            case .notConnected:
                BrokerEmptyState(
                    title: "Connect T3",
                    systemImage: "link",
                    hint: "In T3, open \(T3AppLauncher.pairingLocation) and create a pairing link. Paste the link or its token below."
                )
                pairingControls(buttonTitle: "Connect")
            case .expired:
                reconnectContent(at: date)
            case .connected(let expiresAt, _):
                connectedContent(expiresAt: expiresAt, date: date)
            }
        }

        if let failure, !needsReconnect(at: date) {
            Label(failure.message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reconnectContent(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("T3 needs to be reconnected.", systemImage: "link.badge.plus")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)

            if let expiredAt = connectionExpiry, expiredAt <= date {
                Text("The connection expired \(expiredAt.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let failure {
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            pairingControls(buttonTitle: "Reconnect")
        }
        .brokerInsetRow()
    }

    @ViewBuilder
    private func connectedContent(expiresAt: Date, date: Date) -> some View {
        HStack {
            Label(
                "Connected to T3 on this Mac as “\(T3DispatchController.clientLabel)” until "
                    + "\(expiresAt.formatted(date: .abbreviated, time: .omitted)).",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)
            Spacer()
            Button("Disconnect") {
                Task { await appModel.disconnectT3() }
            }
            .controlSize(.small)
            .disabled(isDispatching)
        }
        .brokerInsetRow()

        if connectionState(at: date) == .expiringSoon {
            Label(
                "Renew the T3 connection by \(expiresAt.formatted(date: .abbreviated, time: .omitted)) to avoid a lapse.",
                systemImage: "clock.badge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }

        projectContent(at: date)

        if appModel.settings.broker.apiKeyMode == .all {
            Label(
                "The broker requires a key from every caller. The T3 agent will be unable to report its check without that key.",
                systemImage: "key.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func projectContent(at date: Date) -> some View {
        switch projectListState {
        case .notLoaded, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading T3 projects…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loadFailed:
            HStack {
                Label("Could not load T3 projects.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") {
                    Task { await appModel.loadT3Projects() }
                }
                .controlSize(.small)
            }
        case .empty:
            BrokerEmptyState(
                title: "No T3 projects",
                systemImage: "folder.badge.plus",
                hint: "Create a project in T3, then return here and refresh."
            )
            HStack {
                Button("Open T3") { T3AppLauncher.open() }
                Button("Refresh") {
                    Task { await appModel.loadT3Projects() }
                }
                .disabled(appModel.t3Dispatch.isLoadingProjects)
            }
            .controlSize(.small)
        case .available:
            HStack {
                Picker("Project", selection: selectedProjectID) {
                    Text("Choose a project").tag("")
                    if let id = appModel.settings.broker.instructionDispatch.t3ProjectID,
                       let title = appModel.settings.broker.instructionDispatch.t3ProjectTitle,
                       !projects.contains(where: { $0.id == id }) {
                        Text(title).tag(id)
                    }
                    ForEach(projects) { project in
                        Text(project.title).tag(project.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isDispatching)

                Button("Refresh") {
                    Task { await appModel.loadT3Projects() }
                }
                .controlSize(.small)
                .disabled(isDispatching || appModel.t3Dispatch.isLoadingProjects)
            }

            Picker("Command access", selection: accessMode) {
                Text("No full access").tag(AccessMode.none)
                Text("Full access for this run").tag(AccessMode.thisRun)
                Text("Full access for all runs").tag(AccessMode.allRuns)
            }
            .pickerStyle(.menu)
            .disabled(isDispatching)
            Text(accessModeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                let fullAccess = fullAccessForNextRun
                fullAccessForNextRun = false
                Task { await appModel.dispatchInstructionRecheck(trigger: .manual, fullAccess: fullAccess) }
            } label: {
                if isDispatching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Starting…")
                    }
                } else {
                    Text("Re-check now")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canDispatch)

            Text(runDestinationCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            outstandingRunRow(at: date)
        }
    }

    @ViewBuilder
    private func outstandingRunRow(at date: Date) -> some View {
        switch outstandingRunState(at: date) {
        case .none:
            EmptyView()
        case .waiting:
            runStatusRow(
                "\(dispatchStartText(relativeTo: date)) Waiting for the agent to report its check. "
                    + "Open the thread in T3 to answer questions and review the check.",
                systemImage: "clock",
                color: .secondary
            )
        case .stalled:
            runStatusRow(
                "\(dispatchStartText(relativeTo: date)) No check was reported. Open the thread in T3 to review it.",
                systemImage: "clock.badge.exclamationmark",
                color: .orange
            )
        }
    }

    private func runStatusRow(_ message: String, systemImage: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(message, systemImage: systemImage)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let threadID = lastDispatchThreadID {
                Text(threadID)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(color)
        .brokerInsetRow()
    }

    private var automaticDispatchToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                "Start instruction checks automatically",
                isOn: $appModel.settings.broker.instructionDispatch.isAutomaticDispatchEnabled
            )
            .disabled(!appModel.settings.broker.isEnabled)

            Text(automaticDispatchDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pairingControls(buttonTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SecureField("Pairing link or token", text: $pairingCredential)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("T3 pairing link or token")
                Button(buttonTitle) {
                    let pastedText = pairingCredential
                    pairingCredential = ""
                    Task { await appModel.connectT3(pastedText: pastedText) }
                }
                .disabled(pairingCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || appModel.t3Dispatch.isConnecting)
                Button("Open T3") { T3AppLauncher.open() }
            }
            Text("Paste either the pairing link from T3 or the token inside it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connection: T3DispatchConnection {
        initialConnection ?? appModel.t3Dispatch.connection
    }

    private var projects: [T3Project] {
        initialDispatchState?.projects ?? appModel.t3Dispatch.projects
    }

    private var projectListState: T3DispatchProjectListState {
        initialDispatchState?.projectListState ?? appModel.t3Dispatch.projectListState
    }

    private var isDispatching: Bool {
        initialDispatchState?.isDispatching ?? appModel.t3Dispatch.isDispatching
    }

    private var failure: T3DispatchFailure? {
        initialDispatchState?.failure ?? appModel.t3Dispatch.lastFailure
    }

    private var modelSource: T3DispatchModelSource? {
        initialDispatchState?.modelSource ?? appModel.t3Dispatch.lastModelSource
    }

    private var lastDispatchedAt: Date? {
        initialDispatchState?.lastDispatchedAt
            ?? appModel.t3Dispatch.lastDispatchedAt
            ?? appModel.settings.broker.instructionDispatch.lastDispatchedAt
    }

    private var lastDispatchThreadID: String? {
        initialDispatchState?.lastDispatchThreadID
            ?? appModel.t3Dispatch.lastDispatchThreadID
            ?? appModel.settings.broker.instructionDispatch.lastDispatchThreadID
    }

    private var connectionExpiry: Date? {
        switch connection {
        case .notConnected:
            nil
        case .connected(let expiresAt, _):
            expiresAt
        case .expired(let expiredAt):
            expiredAt
        }
    }

    private var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    private var canDispatch: Bool {
        appModel.settings.broker.isEnabled
            && isConnected
            && appModel.settings.broker.instructionDispatch.t3ProjectID != nil
            && !isDispatching
    }

    private var selectedProjectID: Binding<String> {
        Binding(
            get: { appModel.settings.broker.instructionDispatch.t3ProjectID ?? "" },
            set: { appModel.selectT3Project(id: $0) }
        )
    }

    private var accessMode: Binding<AccessMode> {
        Binding(
            get: {
                if fullAccessForNextRun { return .thisRun }
                return appModel.settings.broker.instructionDispatch.fullAccessForAllRuns ? .allRuns : .none
            },
            set: { mode in
                fullAccessForNextRun = mode == .thisRun
                appModel.settings.broker.instructionDispatch.fullAccessForAllRuns = mode == .allRuns
            }
        )
    }

    private var accessModeDescription: String {
        switch accessMode.wrappedValue {
        case .none:
            "T3 asks before commands. The agent also asks before changing instruction files."
        case .thisRun:
            "This run can execute commands without T3 approval. The agent still asks before changing instruction files."
        case .allRuns:
            "Manual and automatic runs can execute commands without T3 approval. The agent still asks before changing instruction files."
        }
    }

    private var automaticDispatchDescription: String {
        let access = appModel.settings.broker.instructionDispatch.fullAccessForAllRuns
            ? "Full access applies to automatic runs."
            : "Each run waits in T3 until you approve its commands."
        return "Pinemeter starts a run in T3 when a check is due. \(access) "
            + "Runs use tokens from the connected account. The first run may start shortly after launch."
    }

    private var runDestinationCaption: String {
        let project = appModel.settings.broker.instructionDispatch.t3ProjectTitle ?? "No project selected"
        let source: String
        switch modelSource {
        case .broker:
            source = "broker pick"
        case .projectDefault:
            source = "project default"
        case nil where failure == .noModelResolvable:
            source = "no model resolved"
        case nil:
            source = "resolved when the run starts"
        }
        return "Harness: T3 · Project: \(project) · Model: \(source)"
    }

    private func connectionState(at date: Date) -> T3DispatchConnectionState? {
        connection.state(at: date)
    }

    private func needsReconnect(at date: Date) -> Bool {
        if connectionState(at: date) == .expired { return true }
        guard connection == .notConnected else { return false }
        return failure == .credentialLapsed
            || failure == .credentialRejected
            || failure == .notConnected
    }

    private func outstandingRunState(at date: Date) -> T3DispatchOutstandingRunState {
        initialDispatchState?.outstandingRunState
            ?? appModel.t3Dispatch.outstandingRunState(at: date)
    }

    private func dispatchStartText(relativeTo date: Date) -> String {
        guard let lastDispatchedAt else { return "Started in T3." }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_CA")
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: lastDispatchedAt, relativeTo: date)
        return "Started in T3 \(relative)."
    }
}
