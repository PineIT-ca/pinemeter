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

    @State private var query = ""
    @State private var degradedOnly = false

    private var filtered: [RecentPick] {
        Self.filter(picks, query: query, degradedOnly: degradedOnly)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "Recent Picks",
                systemImage: "clock.arrow.circlepath",
                subtitle: "The last decisions the broker handed out, newest first. "
                    + "Kept in memory only, so this list starts empty after a relaunch.",
                help: .activity
            ) {
                Button {
                    Task { await onRefresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload the recent picks")
                .accessibilityLabel("Reload recent picks")
            }

            if !picks.isEmpty {
                filterBar
            }

            if picks.isEmpty {
                BrokerEmptyState(
                    title: isEnabled ? "No picks yet" : "The broker is off",
                    systemImage: "clock.badge.questionmark",
                    hint: isEnabled
                        ? "Decisions appear here as soon as an agent calls the pick tool."
                        : "Turn the broker on above, then point an agent at the endpoint."
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
        .accessibilityLabel(
            "\(pick.role) routed to \(pick.candidate)\(pick.degraded ? ", degraded" : ""). \(pick.reason)"
        )
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
        }
    }
}
