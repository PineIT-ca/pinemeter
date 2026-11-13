//
//  BrokerQualityOrderSection.swift
//  Pinemeter
//
//  Read-only "Quality and order" disclosure (SCORE-04, SC5, OD-10): shows the
//  selected role's quality table and its current effective order, loaded
//  through `BrokerLifecycleProtocol.scoreSnapshot(role:)`. This view ranks
//  nothing itself — every number and every row order comes from the
//  injected snapshot.
//

import SwiftUI

struct BrokerQualityOrderSection: View {
    let role: String
    let visibleChainModels: [String]
    let policy: BrokerPolicy
    let isEnabled: Bool
    let pickSignal: String?
    let loadSnapshot: (String) async -> BrokerRoleScoreSnapshot?

    @Binding var isExpanded: Bool
    @State private var model: BrokerQualityOrderModel
    @State private var reloadNonce = 0
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    init(
        role: String,
        visibleChainModels: [String],
        policy: BrokerPolicy,
        isEnabled: Bool,
        pickSignal: String?,
        isExpanded: Binding<Bool>,
        initialSnapshot: BrokerRoleScoreSnapshot? = nil,
        loadSnapshot: @escaping (String) async -> BrokerRoleScoreSnapshot?
    ) {
        self.role = role
        self.visibleChainModels = visibleChainModels
        self.policy = policy
        self.isEnabled = isEnabled
        self.pickSignal = pickSignal
        self.loadSnapshot = loadSnapshot
        self._isExpanded = isExpanded
        self._model = State(initialValue: BrokerQualityOrderModel(initialSnapshot: initialSnapshot))
    }

    private struct ReloadKey: Equatable {
        let role: String
        let chain: [String]
        let pickSignal: String?
        let nonce: Int
        let expanded: Bool
        /// The opt-out changes the partition the order is scored with.
        let useModelHealth: Bool
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            sectionBody
                .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text("Quality and order")
                    .font(.callout)
                BrokerHelpButton(topic: .qualityAndOrder)
                Spacer()
                if isExpanded {
                    Button {
                        reloadNonce += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reload order")
                    .accessibilityLabel("Reload order")
                }
            }
        }
        .task(id: ReloadKey(
            role: role, chain: visibleChainModels, pickSignal: pickSignal,
            nonce: reloadNonce, expanded: isExpanded,
            useModelHealth: policy.thresholds.useModelHealth
        )) {
            guard isExpanded else { return }
            if model.snapshot?.role != role { model.reset() }
            await model.load(role: role, using: loadSnapshot)
        }
    }

    // MARK: - State machine (UI-SPEC "State machine")

    @ViewBuilder
    private var sectionBody: some View {
        if !isEnabled {
            BrokerEmptyState(
                title: BrokerQualityOrderPresentation.brokerOffTitle,
                systemImage: "power",
                hint: BrokerQualityOrderPresentation.brokerOffHint
            )
        } else if model.isLoadingFirstTime {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(BrokerQualityOrderPresentation.loadingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if model.loadFailed || model.snapshot == nil {
            BrokerEmptyState(
                title: BrokerQualityOrderPresentation.loadFailedTitle,
                systemImage: "exclamationmark.triangle",
                hint: BrokerQualityOrderPresentation.loadFailedHint
            )
        } else if let snapshot = model.snapshot {
            populated(snapshot)
        }
    }

    @ViewBuilder
    private func populated(_ snapshot: BrokerRoleScoreSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if snapshot.isDerived {
                HStack(spacing: 6) {
                    BrokerChip(text: BrokerQualityOrderPresentation.derivedChip.text, tint: .secondary)
                        .help(BrokerQualityOrderPresentation.derivedChip.tooltip)
                    Text(BrokerQualityOrderPresentation.derivedNoteText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                limitsLine(snapshot)
                qualityTableBlock(snapshot)
            }

            Divider()

            currentOrderBlock(snapshot)

            Divider()

            modelHealthBlock(snapshot.health)
        }
    }

    // MARK: - Limits line

    private func limitsLine(_ snapshot: BrokerRoleScoreSnapshot) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Text("Floor").foregroundStyle(.secondary)
                Text(BrokerQualityOrderPresentation.oneDecimal(snapshot.floor))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 4) {
                Text("Latency limit").foregroundStyle(.secondary)
                Text(BrokerQualityOrderPresentation.latencyLimitText(snapshot.latencyLimit))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .font(.caption)
    }

    // MARK: - Quality table block

    private func qualityTableBlock(_ snapshot: BrokerRoleScoreSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quality table")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Effort").gridColumnHeader()
                    Text("Quality").gridColumnHeader().gridColumnAlignment(.trailing)
                    Text("Effective").gridColumnHeader().gridColumnAlignment(.trailing)
                    Text("Latency").gridColumnHeader().gridColumnAlignment(.trailing)
                    Text("")
                }

                ForEach(snapshot.modelTables, id: \.model) { table in
                    modelHeaderRow(table)
                    ForEach(table.rows, id: \.effortKey) { row in
                        qualityRow(row, model: table.model)
                    }
                }
            }
        }
    }

    private func modelHeaderRow(_ table: BrokerRoleScoreSnapshot.ModelTable) -> some View {
        GridRow {
            HStack(spacing: 4) {
                BrokerRankBadge(rank: table.chainRank)
                Text(table.model)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if !table.hasBaseEstimate, let noEstimate = BrokerQualityOrderPresentation.ineligibleChip("noEstimate") {
                    BrokerChip(text: noEstimate.text, tint: .secondary)
                        .help(noEstimate.tooltip)
                }
            }
            .gridCellColumns(5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            BrokerQualityOrderPresentation.modelHeaderAccessibilityLabel(
                model: table.model, chainRank: table.chainRank, hasBaseEstimate: table.hasBaseEstimate
            )
        )
    }

    private func qualityRow(_ row: BrokerRoleScoreSnapshot.QualityRow, model: String) -> some View {
        let capped = row.isBase && BrokerQualityOrderPresentation.isCapped(
            quality: row.quality, effective: row.effective
        )
        let effortText = BrokerQualityOrderPresentation.effortLabel(row.effortKey, model: model, policy: policy)
        return GridRow {
            Text(effortText)
                .font(.caption)
                .lineLimit(1)
                .frame(minWidth: 56, alignment: .leading)
            Text(BrokerQualityOrderPresentation.oneDecimal(row.quality))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 40, alignment: .trailing)
            Group {
                if row.isBase {
                    Text(BrokerQualityOrderPresentation.oneDecimal(row.effective))
                        .foregroundStyle(capped ? Color.secondary : Color.primary)
                        .help(capped ? BrokerQualityOrderPresentation.cappedTooltip : "")
                } else {
                    Text("")
                }
            }
            .font(.caption.monospacedDigit())
            .frame(minWidth: 40, alignment: .trailing)
            Text(BrokerQualityOrderPresentation.latencySeconds(row.latency))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 40, alignment: .trailing)
            Group {
                if row.isBase {
                    BrokerChip(text: BrokerQualityOrderPresentation.baseChip.text, tint: .secondary)
                        .help(BrokerQualityOrderPresentation.baseChip.tooltip)
                } else {
                    BrokerChip(text: BrokerQualityOrderPresentation.raiseChip.text, tint: .secondary)
                        .help(BrokerQualityOrderPresentation.raiseChip.tooltip)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            BrokerQualityOrderPresentation.qualityRowAccessibilityLabel(
                effortLabel: effortText, quality: row.quality, effective: row.isBase ? row.effective : nil,
                latency: row.latency, isBase: row.isBase, capped: capped
            )
        )
    }

    // MARK: - Current order block

    @ViewBuilder
    private func currentOrderBlock(_ snapshot: BrokerRoleScoreSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Current order")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(BrokerQualityOrderPresentation.summary(pricing: snapshot.pricing, moved: snapshot.moved))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if BrokerQualityOrderPresentation.isStale(snapshot: snapshot, visibleChainModels: visibleChainModels) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(BrokerQualityOrderPresentation.updatingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if snapshot.orderRows.isEmpty {
                Text(BrokerQualityOrderPresentation.noRoutesText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                orderGrid(snapshot)
                Text(BrokerQualityOrderPresentation.gatesNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func orderGrid(_ snapshot: BrokerRoleScoreSnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow {
                Text("")
                Text("Route").gridColumnHeader()
                Text("Price").gridColumnHeader().gridColumnAlignment(.trailing)
                Text("Score").gridColumnHeader().gridColumnAlignment(.trailing)
                Text("")
            }
            ForEach(snapshot.orderRows, id: \.candidate) { row in
                orderRow(row, isDerived: snapshot.isDerived)
            }
        }
    }

    /// A derived role has no quality table, so its rows carry no real score
    /// — `isDerived` forces the Score cell (and its spoken form) to "—" /
    /// "unknown" so no synthetic tier number is ever rendered (UI-SPEC U3,
    /// extended to the order block).
    private func orderRow(_ row: BrokerRoleScoreSnapshot.OrderRow, isDerived: Bool) -> some View {
        let chip = BrokerQualityOrderPresentation.orderRowChip(
            isDemoted: row.isDemoted, reason: row.ineligibleReason
        )
        let displayedScore = BrokerQualityOrderPresentation.orderRowScore(row.score, isDerived: isDerived)
        return GridRow {
            BrokerRankBadge(rank: row.position)
            Text(row.candidate)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(minWidth: 120, alignment: .leading)
            Text(BrokerQualityOrderPresentation.priceLevel(row.level))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 40, alignment: .trailing)
            Text(BrokerQualityOrderPresentation.oneDecimal(displayedScore))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 40, alignment: .trailing)
            Group {
                if let chip {
                    BrokerChip(text: chip.text, tint: .secondary)
                        .help(chip.tooltip)
                } else {
                    Text("")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            BrokerQualityOrderPresentation.orderRowAccessibilityLabel(
                position: row.position, candidate: row.candidate, level: row.level,
                score: displayedScore, chipText: chip?.text, isDemoted: row.isDemoted
            )
        )
    }

    // MARK: - Model health block (29-06)

    private func modelHealthBlock(_ health: BrokerRoleHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(BrokerQualityOrderPresentation.modelHealthTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            Text(BrokerQualityOrderPresentation.modelHealthStatusLine(health, locale: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if BrokerQualityOrderPresentation.showsDemotionsGrid(health) {
                demotionsGrid(health)
            }

            if BrokerQualityOrderPresentation.showsSources(health) {
                sourcesBlock(health)
            }
        }
    }

    private func demotionsGrid(_ health: BrokerRoleHealthSnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow {
                Text("Model").gridColumnHeader()
                Text("Until").gridColumnHeader()
                Text("Methods").gridColumnHeader()
            }
            ForEach(Array(health.demotions.enumerated()), id: \.offset) { _, demotion in
                GridRow {
                    Text(demotion.model)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(minWidth: 120, alignment: .leading)
                    Text(BrokerQualityOrderPresentation.untilText(
                        demotion.expiresAt, timeZone: timeZone, locale: locale
                    ))
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 88, alignment: .leading)
                    Text(BrokerQualityOrderPresentation.methodLabels(demotion.methods))
                        .font(.caption)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(BrokerQualityOrderPresentation.demotionAccessibilityLabel(
                    demotion, timeZone: timeZone, locale: locale
                ))
            }
        }
    }

    private func sourcesBlock(_ health: BrokerRoleHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(BrokerQualityOrderPresentation.sourcesTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Source").gridColumnHeader()
                    Text("State").gridColumnHeader()
                    Text("Newest data").gridColumnHeader().gridColumnAlignment(.trailing)
                }
                ForEach(Array(health.sources.enumerated()), id: \.offset) { _, source in
                    sourceRow(source)
                }
            }

            Text(BrokerQualityOrderPresentation.sourcesFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Verbatim from the signed document; plain text, never a link.
            ForEach(Array(health.attribution.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sourceRow(_ source: BrokerRoleHealthSnapshot.Source) -> some View {
        let label = BrokerQualityOrderPresentation.sourceLabel(source.id)
        let chip = BrokerQualityOrderPresentation.sourceStateChip(source.state, staleLimitDays: source.staleLimitDays)
        return GridRow {
            Group {
                if label.isVerbatim {
                    Text(verbatim: label.text)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(label.text)
                        .font(.caption)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            if let chip {
                BrokerChip(text: chip.text, tint: .secondary, style: .subtle)
                    .help(chip.tooltip)
            } else {
                Text("\u{2014}")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            let hasDate = source.newestDataDate != nil
            Text(BrokerQualityOrderPresentation.newestDataText(source.newestDataDate, locale: locale))
                .font(hasDate ? .caption.monospacedDigit() : .caption)
                .foregroundStyle(hasDate ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(minWidth: 56, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(BrokerQualityOrderPresentation.sourceAccessibilityLabel(source, locale: locale))
    }
}

private extension Text {
    /// The grids' shared column-header treatment (UI-SPEC "Typography").
    func gridColumnHeader() -> some View {
        self.font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
}
