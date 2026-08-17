import AppKit
import SwiftUI

struct InstructionsSettingsTab: View {
    @Bindable var appModel: AppModel

    /// Which rows the audit list shows. Issues lead, because a passing source
    /// needs no action and the summary line already counts them.
    enum Filter: String, CaseIterable, Identifiable {
        case issues
        case all

        var id: String { rawValue }

        var label: String {
            switch self {
            case .issues: "Issues"
            case .all: "All"
            }
        }
    }

    @State private var report: InstructionAuditReport?
    @State private var didCopySetupPrompt = false
    @State private var isRefreshing = false
    @State private var filter: Filter = .issues
    @State private var copiedStyle: InstructionAuditCopyStyle?

    private let auditService: InstructionAuditService

    init(
        appModel: AppModel,
        initialReport: InstructionAuditReport? = nil,
        auditService: InstructionAuditService = InstructionAuditService()
    ) {
        self.appModel = appModel
        self._report = State(initialValue: initialReport)
        self.auditService = auditService
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                setupSection
                auditSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .task {
            guard report == nil else { return }
            await refreshAudit()
        }
    }

    private var endpoint: String {
        "http://127.0.0.1:\(appModel.settings.broker.port)\(BrokerMCPServer.endpointPath)"
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent Setup")
                    .font(.subheadline)
                Text("Connect Claude Code and Codex to Pinemeter's model broker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Endpoint") {
                Text(endpoint)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            BrokerServerStatusLine(
                isEnabled: appModel.settings.broker.isEnabled,
                serverState: appModel.brokerUIState?.serverState
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
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Installed Instructions")
                        .font(.subheadline)
                    Text("Checks known Claude Code and Codex instruction sources without storing their contents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    Task { await refreshAudit() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh installed instruction audit")
            }

            if let report {
                Label(summary(for: report), systemImage: icon(for: report.status))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(color(for: report.status))
                    .accessibilityLabel("Instruction audit: \(summary(for: report))")

                HStack(spacing: 8) {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                    .accessibilityLabel("Filter instruction audit rows")

                    Text(visibleCountCaption(for: report))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    copyMenu(for: report)
                }

                let visible = visibleSources(of: report)
                if visible.isEmpty {
                    Text("No conflicts or warnings. All \(report.sources.count) sources pass.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visible, id: \.path) { source in
                            sourceRow(source)
                        }
                    }
                }
            } else {
                ProgressView("Checking installed instructions\u{2026}")
                    .controlSize(.small)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copyMenu(for report: InstructionAuditReport) -> some View {
        Menu {
            ForEach(InstructionAuditCopyStyle.allCases) { style in
                Button(style.menuLabel) { copy(style: style, from: report) }
            }
        } label: {
            Label(
                copiedStyle.map(\.copiedLabel) ?? "Copy",
                systemImage: copiedStyle == nil ? "doc.on.doc" : "checkmark"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Copy instruction audit report or prompt")
    }

    /// The rows the list is showing, and so the rows a copy covers. Pure, and
    /// tested directly: a snapshot cannot prove which rows a copy picked up.
    static func visibleSources(
        of report: InstructionAuditReport,
        filter: Filter
    ) -> [InstructionAuditSourceReport] {
        switch filter {
        case .all: report.sources
        case .issues: report.sources.filter { $0.status != .pass }
        }
    }

    private func visibleSources(of report: InstructionAuditReport) -> [InstructionAuditSourceReport] {
        Self.visibleSources(of: report, filter: filter)
    }

    private func visibleCountCaption(for report: InstructionAuditReport) -> String {
        let visible = visibleSources(of: report).count
        return visible == report.sources.count
            ? "\(report.sources.count) sources"
            : "\(visible) of \(report.sources.count) sources"
    }

    private func copy(style: InstructionAuditCopyStyle, from report: InstructionAuditReport) {
        let text = report.copyText(
            style: style,
            showing: visibleSources(of: report),
            endpoint: endpoint,
            appVersion: BuildInfo.versionLabel()
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            copiedStyle = style
        }
    }

    private func sourceRow(_ source: InstructionAuditSourceReport) -> some View {
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

            ForEach(Array(source.findings.enumerated()), id: \.offset) { _, finding in
                Text(finding.message)
                    .font(.caption2)
                    .foregroundStyle(finding.kind == .conflict ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func refreshAudit() async {
        isRefreshing = true
        copiedStyle = nil
        report = await auditService.audit(endpoint: endpoint)
        isRefreshing = false
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

    private func summary(for report: InstructionAuditReport) -> String {
        switch report.status {
        case .pass:
            return "All \(report.sources.count) instruction sources pass."
        case .warning:
            return "Instruction coverage has gaps."
        case .conflict:
            return "Conflicting routing instructions found."
        case .unavailable:
            return "Instruction sources are unavailable."
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
