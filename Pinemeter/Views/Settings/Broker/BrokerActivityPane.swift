//
//  BrokerActivityPane.swift
//  Pinemeter
//
//  The broker's recent routing decisions (D-09 debugging aid).
//
//  The pre-redesign list showed time, role, candidate and route but dropped
//  `RecentPick.reason` — the one field that answers the question anybody
//  opening this list actually has, which is "why did it pick *that*". It is
//  the second line of every row now. Filtering exists for the same reason:
//  the ring buffer is most useful when you are chasing one role or one
//  degraded pick, not reading all of it.
//

import SwiftUI

struct BrokerActivityPane: View {
    let picks: [RecentPick]
    let isEnabled: Bool
    let onRefresh: () async -> Void
    let onResetDegradedPaths: () async -> Bool

    @State private var query = ""
    @State private var degradedOnly = false
    @State private var isResettingPaths = false
    @State private var pathsResetResult: Bool?

    private var filtered: [RecentPick] {
        Self.filter(picks, query: query, degradedOnly: degradedOnly)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrokerUI.sectionSpacing) {
            BrokerPaneHeader(
                "Activity",
                purpose: "The last decisions the broker handed out, newest first, and why it made each one.",
                help: .activity
            ) {
                HStack(spacing: 8) {
                    Button(pathsResetLabel) {
                        Task {
                            isResettingPaths = true
                            pathsResetResult = await onResetDegradedPaths()
                            isResettingPaths = false
                        }
                    }
                    .disabled(isResettingPaths)
                    .help("Clear all path cooldowns and refresh broker health.")

                    Button {
                        Task { await onRefresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reload the recent picks")
                    .accessibilityLabel("Reload recent picks")
                }
            }

            picksCard
        }
    }

    private var picksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kept in memory only, so this list starts empty after a relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !picks.isEmpty {
                filterBar
            }

            if picks.isEmpty {
                BrokerEmptyState(
                    title: isEnabled ? "No picks yet" : "The broker is off",
                    systemImage: "clock.badge.questionmark",
                    hint: isEnabled
                        ? "Decisions appear here as soon as an agent calls the pick tool."
                        : "Turn the broker on with the switch above, then point an agent at the endpoint."
                )
            } else if filtered.isEmpty {
                BrokerEmptyState(
                    title: "No matching picks",
                    systemImage: "line.3.horizontal.decrease.circle",
                    hint: "Clear the filter to see all \(picks.count) recorded picks."
                )
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { _, pick in
                        pickRow(pick)
                    }
                }
            }
        }
        .brokerCard()
    }

    private var pathsResetLabel: String {
        if isResettingPaths { return "Resetting\u{2026}" }
        if let pathsResetResult { return pathsResetResult ? "Paths Reset" : "Reset Failed" }
        return "Reset Degraded Paths"
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filter by role, model or route", text: $query)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                HierarchicalShapeStyle.quaternary.opacity(0.5),
                in: RoundedRectangle(cornerRadius: 6)
            )

            Toggle(isOn: $degradedOnly) {
                Text("Degraded only")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .fixedSize()
        }
    }

    // MARK: - Row

    private func pickRow(_ pick: RecentPick) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    BrokerChip(text: pick.role, tint: .accentColor)
                        .help("The role the agent asked for.")

                    Text(pick.candidate)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help("The candidate that won: route, optional T3 instance, then model.")

                    BrokerChip(
                        text: pick.route,
                        tint: BrokerUI.routeTint(named: pick.route),
                        style: .outline
                    )
                    .help(
                        BrokerPolicy.Route(rawValue: pick.route).map(BrokerHelpText.route)
                            ?? "How the work was run."
                    )

                    if let label = Self.pickBasisLabel(pick.pickBasis) {
                        BrokerChip(text: label, tint: .secondary)
                            .help(Self.pickBasisTooltip(pick.pickBasis) ?? "")
                    }

                    if let label = Self.residencyLabel(pick) {
                        BrokerChip(text: label, systemImage: pick.residency == "controlled" ? "lock.fill" : nil, tint: .secondary)
                            .help(Self.residencyTooltip(pick) ?? "")
                    }

                    if pick.degraded {
                        BrokerChip(
                            text: "Degraded",
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .orange,
                            style: .solid
                        )
                        .help("Every candidate was out of quota. Pinemeter routed anyway and flagged it.")
                    }
                }

                Text("\(pick.caller) \u{2022} \(pick.reason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            // Live relative text rather than a stamped string, so a window
            // left open doesn't claim every pick happened "1 min" ago. Sized
            // for the widest thing that text becomes ("12 hrs, 34 mins").
            Text(pick.timestamp, style: .relative)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 86, alignment: .trailing)
        }
        .brokerInsetRow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.rowAccessibilityLabel(pick))
    }

    // MARK: - Filtering

    /// Substring match across the fields a pick is actually searched by, plus
    /// the degraded flag. Static and pure so the behaviour is testable without
    /// rendering the view.
    static func filter(_ picks: [RecentPick], query: String, degradedOnly: Bool) -> [RecentPick] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return picks.filter { pick in
            if degradedOnly && !pick.degraded { return false }
            guard !needle.isEmpty else { return true }
            return pick.role.lowercased().contains(needle)
                || pick.candidate.lowercased().contains(needle)
                || pick.route.lowercased().contains(needle)
                || pick.caller.lowercased().contains(needle)
                || pick.reason.lowercased().contains(needle)
                || (Self.pickBasisLabel(pick.pickBasis)?.lowercased().contains(needle) ?? false)
                || (Self.residencyLabel(pick)?.lowercased().contains(needle) ?? false)
        }
    }

    /// The row's combined accessibility label. Appends ", " + the chip label
    /// only when the chip shows (`.quality` and `nil` append nothing).
    static func rowAccessibilityLabel(_ pick: RecentPick) -> String {
        "\(pick.role) routed to \(pick.candidate)\(pick.degraded ? ", degraded" : ""). \(pick.reason)"
            + (pickBasisLabel(pick.pickBasis).map { ", \($0)" } ?? "")
            + (residencyLabel(pick).map { ", \($0.lowercased())" } ?? "")
    }

    static func residencyLabel(_ pick: RecentPick) -> String? {
        if pick.residency == "controlled" { return "Controlled only" }
        if pick.residency == nil && pick.routeClass == "controlled" { return "Controlled" }
        return nil
    }

    static func residencyTooltip(_ pick: RecentPick) -> String? {
        switch residencyLabel(pick) {
        case "Controlled only": return "This pick required controlled infrastructure. Prompts and code stayed on hosts you control."
        case "Controlled": return "This model runs on a host you control. The pick did not require it."
        default: return nil
        }
    }

    // MARK: - Pick reason chip

    /// `nil` for `.quality` and for a pick with no classified basis (U5): the
    /// common case adds no chip. Only `quota`, `drift` and `human-override`
    /// show one.
    static func pickBasisLabel(_ basis: BrokerPickBasis?) -> String? {
        switch basis {
        case .quota: return "Quota"
        case .drift: return "Drift"
        case .humanOverride: return "Override"
        case .quality, nil: return nil
        }
    }

    static func pickBasisTooltip(_ basis: BrokerPickBasis?) -> String? {
        switch basis {
        case .quota:
            return "A higher-ranked model was held back by quota pacing or because its quota could not be verified, or quota price picked a model of nearly the same quality or raised the effort to spend quota that would otherwise expire."
        case .humanOverride:
            return "You asked for this model by name for this one dispatch."
        case .drift:
            return "A higher-ranked model was moved behind the others because model health reports a quality drop for it."
        case .quality, nil:
            return nil
        }
    }
}
