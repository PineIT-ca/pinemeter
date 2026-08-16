import AppKit
import SwiftUI

struct InstructionsSettingsTab: View {
    @Bindable var appModel: AppModel

    @State private var report: InstructionAuditReport?
    @State private var didCopySetupPrompt = false
    @State private var isRefreshing = false

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

                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(report.sources, id: \.path) { source in
                        sourceRow(source)
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

    private func sourceRow(_ source: InstructionAuditSourceReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(source.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Label(label(for: source.status), systemImage: icon(for: source.status))
                    .font(.caption2)
                    .foregroundStyle(color(for: source.status))
                    .accessibilityLabel("\(source.path): \(label(for: source.status))")
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

    private func label(for status: InstructionAuditStatus) -> String {
        switch status {
        case .pass: "Pass"
        case .warning: "Warning"
        case .conflict: "Conflict"
        case .unavailable: "Unavailable"
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
