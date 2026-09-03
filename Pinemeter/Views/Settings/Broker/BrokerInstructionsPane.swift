//
//  BrokerInstructionsPane.swift
//  Pinemeter
//
//  Setup and last-checked state for the model broker's instruction contract.
//
//  This was a top-level settings tab until it moved in here. Everything on it
//  serves the broker and nothing on it touches the menu bar meters, so at the
//  top level it had to open with a paragraph explaining why it existed at all.
//  As a broker pane, under the broker's own status header, the tab around it
//  carries that framing, and the header already prints the endpoint and the
//  server state the setup card used to repeat.
//
//  The pane once ran its own scan over a fixed list of user-level paths and
//  printed a verdict from it. That verdict was structurally a subset — no
//  project files, no skills, no second harness profile, nothing a session hook
//  injects — and a green tick over a subset says "your setup is clean" when it
//  means "the files I knew to look for are clean". The scan is gone. What the
//  pane shows now is the verdict from the last `audit` the broker actually
//  graded, which an agent produces over its own effective instruction stack.
//

import AppKit
import SwiftUI

struct BrokerInstructionsPane: View {
    @Bindable var appModel: AppModel

    @State private var didCopySetupPrompt = false
    @State private var check: InstructionCheck?
    @State private var hasLoadedCheck: Bool

    /// The clock the "checked N ago" line reads. A parameter only so snapshots
    /// can pin it: a reference image rendered against the wall clock silently
    /// rots as its relative phrasing crosses each unit boundary.
    private let now: Date?

    /// The build the recorded check is judged against. A parameter for the
    /// same reason `now` is: the re-check banner is a comparison against the
    /// running app, and a reference image cannot be pinned to whichever
    /// version the recording machine happened to build.
    private let currentVersion: String

    /// `initialCheck` is a snapshot-test seam: production call sites let
    /// `.task` load the real record, which an off-screen `NSHostingView` never
    /// reliably pumps before capture. `hasLoadedCheck` is the same seam for the
    /// one state the check itself cannot express — loaded, and there is no
    /// record — which otherwise renders as the still-loading spinner.
    init(
        appModel: AppModel,
        initialCheck: InstructionCheck? = nil,
        hasLoadedCheck: Bool? = nil,
        now: Date? = nil,
        currentVersion: String = BrokerMCPServer.appVersion
    ) {
        self.appModel = appModel
        self._check = State(initialValue: initialCheck)
        self._hasLoadedCheck = State(initialValue: hasLoadedCheck ?? (initialCheck != nil))
        self.now = now
        self.currentVersion = currentVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrokerUI.sectionSpacing) {
            setupSection
            lastCheckSection
        }
        // Runs on appearance (the initial load) and again whenever the
        // broker's last-check stamp changes, so an audit that lands while the
        // pane is visible reloads the record in place. A nil result keeps the
        // current record: the store never goes from a record to none, so nil
        // here means either "no check yet" (check is already nil) or a
        // snapshot seam whose injected record must survive.
        .task(id: appModel.brokerUIState?.lastInstructionCheckAt) {
            if let latest = await appModel.brokerLatestInstructionCheck() {
                check = latest
            }
            hasLoadedCheck = true
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "Agent Setup",
                systemImage: "sparkles",
                subtitle: "An agent asks the broker only when its own instruction files tell it to. "
                    + "This prompt registers Pinemeter with Claude Code or Codex the first time."
            )

            Button {
                copySetupPrompt()
            } label: {
                Label(
                    didCopySetupPrompt ? "Setup Prompt Copied" : "Copy Setup Prompt",
                    systemImage: didCopySetupPrompt ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(didCopySetupPrompt ? "Setup prompt copied" : "Copy setup prompt")

            // Registration has to happen once before an agent can reach the
            // server at all, which is what the button above is for. After that
            // the server serves the same prompt itself.
            Text(
                "Paste it into an agent to register `pinemeter-broker` and run the first check. After "
                    + "that, run the server's `configure` prompt in any registered agent to re-check and "
                    + "fix this machine. The agent reads your instruction files, Pinemeter grades them, "
                    + "and the agent proposes the edits and waits for your approval. Pinemeter never "
                    + "writes them."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .brokerCard()
    }

    private var lastCheckSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "Last Check",
                systemImage: "doc.text.magnifyingglass",
                subtitle: "The verdict from the last audit an agent ran through the broker. Pinemeter "
                    + "grades what the agent sends it and keeps the findings only, never the file contents."
            )

            if let check {
                Label(Self.summary(for: check), systemImage: icon(for: check.status))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(color(for: check.status))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Last instruction check: \(Self.summary(for: check))")

                Text(Self.provenance(for: check, now: now ?? Date()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let reason = recheckReason(for: check), let message = Self.recheckMessage(for: reason) {
                    Label {
                        // `LocalizedStringKey` so the inline code spans render
                        // as code, as they do in the literals around them.
                        Text(.init(message))
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Re-check due: \(message)")
                }

                let issues = check.issues
                if issues.isEmpty {
                    Text("Every source the agent sent passes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(issues, id: \.path) { source in
                            sourceRow(source)
                        }
                    }
                }
            } else if hasLoadedCheck {
                Text(
                    "No check has run on this machine yet. Run the `configure` prompt in a registered agent, "
                        + "or ask it to call the broker's `audit` tool."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            // Saved by `AppModel.settings`'s own didSet, like every other
            // control on this tab; the toggle changes nothing the running
            // server serves, so it needs no lifecycle reconciliation.
            Toggle(isOn: $appModel.settings.broker.recheckReminderEnabled) {
                Text("Remind me when a re-check is due")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .disabled(!appModel.settings.broker.isEnabled)
        }
        .brokerCard()
    }

    /// Why this record is due to be re-checked, or nothing when it is current.
    /// Suppressed with the broker off: nothing is routing through the
    /// contract, so nothing is drifting away from it.
    private func recheckReason(for check: InstructionCheck) -> InstructionRecheck.Reason? {
        guard appModel.settings.broker.isEnabled else { return nil }
        return InstructionRecheck.reason(
            for: check,
            currentVersion: currentVersion,
            now: now ?? Date()
        )
    }

    /// The banner copy, or nothing for a reason the card already states in its
    /// own empty state. Pure and tested directly, like `summary`.
    static func recheckMessage(for reason: InstructionRecheck.Reason) -> String? {
        let rerun = "Re-run the check: run the server's `configure` prompt in a registered agent."
        switch reason {
        case .neverChecked:
            return nil
        case .contractMayHaveChanged:
            return "Pinemeter has updated since this check ran, so the contract may have changed. \(rerun)"
        case .stale:
            return "This check is more than 14 days old, and instruction files drift. \(rerun)"
        }
    }

    private func sourceRow(_ source: InstructionCheckSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(source.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Label(source.status.label, systemImage: icon(for: source.status))
                    .font(.caption2)
                    .foregroundStyle(color(for: source.status))
                    .accessibilityLabel("\(source.path): \(source.status.label)")
            }

            ForEach(Array(source.findings.enumerated()), id: \.offset) { _, message in
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(source.status == .conflict ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .brokerInsetRow()
    }

    /// The headline verdict. Pure and tested directly: a snapshot cannot prove
    /// which counts a summary line drew from.
    static func summary(for check: InstructionCheck) -> String {
        let total = check.sources.count
        let sources = total == 1 ? "1 source" : "\(total) sources"
        switch check.status {
        case .pass:
            return "\(sources) checked, all pass."
        case .warning:
            return "\(sources) checked, \(check.count(of: .warning)) with gaps."
        case .conflict:
            let conflicts = check.count(of: .conflict)
            let noun = conflicts == 1 ? "conflict" : "conflicts"
            return "\(sources) checked, \(conflicts) \(noun) with the broker's contract."
        case .unavailable:
            return "\(sources) checked, none could be read."
        }
    }

    /// Who ran it and when. Kept separate from the verdict so the verdict line
    /// never has to hedge about its own provenance.
    static func provenance(for check: InstructionCheck, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: check.checkedAt, relativeTo: now)
        guard let caller = check.caller else { return "Checked \(when)." }
        return "Checked \(when) by \(caller)."
    }

    private func copySetupPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(
            BrokerSettingsTab.setupPrompt(port: appModel.settings.broker.port),
            forType: .string
        ) {
            didCopySetupPrompt = true
        }
    }

    private func icon(for status: InstructionAuditStatus) -> String {
        switch status {
        case .pass: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .conflict: "xmark.octagon.fill"
        case .unavailable: "questionmark.circle"
        }
    }

    private func color(for status: InstructionAuditStatus) -> Color {
        switch status {
        case .pass: .green
        case .warning: .orange
        case .conflict: .red
        case .unavailable: .secondary
        }
    }
}
