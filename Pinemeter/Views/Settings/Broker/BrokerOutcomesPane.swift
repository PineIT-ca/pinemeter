//
//  BrokerOutcomesPane.swift
//  Pinemeter
//
//  Per-role, per-model outcome trend (OUTC-03, SC4): how each model did in
//  one role over the last 7 days against its own previous 28 days. Every
//  group compares a model only with its own history — never against another
//  model, never a chart, never a ranking (25-UI-SPEC.md Assumption U1,
//  threat T-25-21a).
//
//  Data arrives through `loadTrend`, which the window wires to
//  `AppModel.brokerOutcomeTrend(role:includeAllReasons:)`. This view owns no
//  file access: every number on screen comes from the injected closure.
//

import SwiftUI

/// `ForEach` identity, keyed on the pair the UI-SPEC groups by. Group order
/// comes only from `BrokerOutcomeTrend.make` (model name, then effort); this
/// never influences it.
extension BrokerOutcomeTrend.Group {
    var identity: String { "\(model)|\(effort)" }
}

struct BrokerOutcomesPane: View {
    let isEnabled: Bool
    /// Changes whenever the broker hands out a new pick, so an open pane
    /// follows new data without the user doing anything (matches
    /// `BrokerActivityPane`'s own `.task(id:)` trigger).
    let pickSignal: String?
    let loadTrend: (String?, Bool) async -> BrokerOutcomeView

    @State private var role: String?
    @State private var includeAllReasons = false
    @State private var view: BrokerOutcomeView?
    @State private var hasLoaded: Bool

    init(
        isEnabled: Bool,
        initialTrend: BrokerOutcomeView? = nil,
        pickSignal: String?,
        loadTrend: @escaping (String?, Bool) async -> BrokerOutcomeView
    ) {
        self.isEnabled = isEnabled
        self.pickSignal = pickSignal
        self.loadTrend = loadTrend
        _view = State(initialValue: initialTrend)
        _hasLoaded = State(initialValue: initialTrend != nil)
        _role = State(initialValue: initialTrend?.trend.role)
    }

    private struct ReloadKey: Equatable {
        let role: String?
        let includeAllReasons: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrokerUI.sectionSpacing) {
            BrokerPaneHeader(
                "Outcomes",
                purpose: "How each model did in one role over the last 7 days, "
                    + "compared with its own previous 28 days.",
                help: .outcomes
            ) {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload outcomes")
                .accessibilityLabel("Reload outcomes")
            }

            card
        }
        // `.task(id:)` never reliably pumps before an off-screen snapshot
        // capture (see BrokerWindowView's own seam comment), so the seeded
        // `initialTrend` is what a snapshot test actually renders; these
        // only drive the real, running window.
        .task(id: ReloadKey(role: role, includeAllReasons: includeAllReasons)) {
            await reload()
        }
        .task(id: pickSignal) {
            await reload()
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let note = Self.noteText(isEnabled: isEnabled, hasData: hasData) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showFilterBar {
                filterBar
            }

            stateBody
        }
        .brokerCard()
    }

    // MARK: - Filter bar

    private var sortedRoles: [BrokerOutcomeTrend.Role] {
        (view?.trend.roles ?? []).sorted { $0.role < $1.role }
    }

    private var effectiveRole: String? { role ?? view?.trend.role }

    private var roleBinding: Binding<String> {
        Binding(get: { effectiveRole ?? "" }, set: { role = $0 })
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("Role", selection: roleBinding) {
                ForEach(sortedRoles, id: \.role) { entry in
                    Text(entry.role).tag(entry.role)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Toggle(isOn: $includeAllReasons) {
                Text("Include quota and override picks")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .fixedSize()

            Spacer()
        }
    }

    // MARK: - State machine

    enum PaneState: Equatable {
        case brokerOff
        case loading
        case readFailed
        case noData
        case filteredEmpty
        case populated
    }

    static func paneState(view: BrokerOutcomeView?, isEnabled: Bool, hasLoaded: Bool) -> PaneState {
        guard hasLoaded, let view else { return .loading }
        if view.loadFailed { return .readFailed }
        switch view.trend.state {
        case "no-data": return isEnabled ? .noData : .brokerOff
        case "filtered-empty": return .filteredEmpty
        default: return .populated
        }
    }

    private var paneState: PaneState {
        Self.paneState(view: view, isEnabled: isEnabled, hasLoaded: hasLoaded)
    }

    private var hasData: Bool { !(view?.trend.roles.isEmpty ?? true) }

    private var showFilterBar: Bool { paneState == .populated || paneState == .filteredEmpty }

    @ViewBuilder
    private var stateBody: some View {
        switch paneState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading outcomes\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .brokerOff:
            BrokerEmptyState(
                title: "The broker is off",
                systemImage: "chart.line.uptrend.xyaxis",
                hint: "Turn the broker on with the switch above. Outcomes are recorded from picks and reports."
            )
        case .readFailed:
            BrokerEmptyState(
                title: "Outcome history could not be read",
                systemImage: "exclamationmark.triangle",
                hint: "Pinemeter started a new history file. Picks and reports from now on are counted."
            )
        case .noData:
            BrokerEmptyState(
                title: "No outcomes yet",
                systemImage: "chart.line.uptrend.xyaxis",
                hint: "Outcomes appear after agents report finished work through the report tool. "
                    + "Trends need 5 reports per model in this role."
            )
        case .filteredEmpty:
            BrokerEmptyState(
                title: "No quality picks for this role",
                systemImage: "line.3.horizontal.decrease.circle",
                hint: "Turn on \u{201C}Include quota and override picks\u{201D} to see the other picks."
            )
        case .populated:
            groupsList
        }
    }

    // MARK: - Populated body

    private var groupsList: some View {
        VStack(spacing: 4) {
            ForEach(view?.trend.groups ?? [], id: \.identity) { group in
                groupRow(group)
            }
        }
    }

    private func groupRow(_ group: BrokerOutcomeTrend.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(group.model)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                BrokerChip(text: group.effort, tint: .secondary)

                Spacer(minLength: 4)

                Text(Self.taskCountText(group.recentTasks))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.groupAccessibilityLabel(group))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    columnHeader("Last 7 days")
                    columnHeader("Previous 28 days")
                    columnHeader("Change")
                }

                ForEach(group.rows, id: \.label) { row in
                    GridRow {
                        Text(row.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        valueCell(row.recent)
                        valueCell(row.baseline)
                        changeCell(row)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Self.rowAccessibilityLabel(row))
                }
            }
        }
        .brokerInsetRow()
    }

    private func columnHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 96, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func valueCell(_ value: String) -> some View {
        Group {
            if value == "\u{2014}" {
                Text(value)
                    .foregroundStyle(.tertiary)
                    .help("Fewer than 5 samples in this window.")
            } else {
                Text(value)
            }
        }
        .font(.caption.monospacedDigit())
        .frame(minWidth: 96, alignment: .trailing)
    }

    @ViewBuilder
    private func changeCell(_ row: BrokerOutcomeTrend.Row) -> some View {
        if row.modelChanged {
            BrokerChip(text: "Model changed", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                .help("The provider reported a different model most often than in the previous 28 days.")
                .frame(minWidth: 96, alignment: .trailing)
        } else if row.change == "\u{2014}" {
            Text(row.change)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .help("Fewer than 5 samples in this window.")
                .frame(minWidth: 96, alignment: .trailing)
        } else {
            Text(row.change)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 96, alignment: .trailing)
        }
    }

    // MARK: - Reload

    private func reload() async {
        let requested = role
        let result = await loadTrend(requested, includeAllReasons)
        if let requested, !result.trend.roles.contains(where: { $0.role == requested }) {
            role = result.trend.role
        }
        view = result
        hasLoaded = true
    }

    // MARK: - Pure copy and accessibility helpers (unit-tested without rendering)

    static func taskCountText(_ count: Int) -> String {
        count == 1 ? "1 task in 7 days" : "\(count) tasks in 7 days"
    }

    /// `nil` means "show no note line": the broker-off, no-data case covers
    /// itself entirely through the empty state's own heading and body.
    static func noteText(isEnabled: Bool, hasData: Bool) -> String? {
        if isEnabled {
            return "Each model is compared only with its own history in this role. "
                + "Kept across restarts for 180 days."
        }
        if hasData {
            return "The broker is off. This is the history recorded while it was on."
        }
        return nil
    }

    private static func spoken(_ value: String) -> String {
        if value == "\u{2014}" { return "not enough data" }
        return value
            .replacingOccurrences(of: "\u{2212}", with: "minus ")
            .replacingOccurrences(of: "pts", with: "points")
    }

    static func rowAccessibilityLabel(_ row: BrokerOutcomeTrend.Row) -> String {
        "\(row.label), last 7 days \(spoken(row.recent)), "
            + "previous 28 days \(spoken(row.baseline)), change \(spoken(row.change))"
    }

    static func groupAccessibilityLabel(_ group: BrokerOutcomeTrend.Group) -> String {
        "\(group.model), effort \(group.effort), \(taskCountText(group.recentTasks))"
    }
}
