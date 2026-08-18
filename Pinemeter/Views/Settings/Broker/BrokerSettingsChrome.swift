//
//  BrokerSettingsChrome.swift
//  Pinemeter
//
//  The Broker tab's shared visual language: one card treatment, one section
//  header, one chip, one status dot. Everything in the tab composes these
//  instead of re-deriving padding, radii and tints per view, which is what
//  kept the pre-redesign tab from reading as a single surface.
//
//  Metrics follow macOS System Settings: 10pt group radius, 7pt inner-row
//  radius, 14pt inside a card, 12pt between cards.
//

import SwiftUI

enum BrokerUI {
    static let sectionRadius: CGFloat = 10
    static let rowRadius: CGFloat = 7
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 12
    static let panePadding: CGFloat = 20

    /// Tint for a broker route, used consistently everywhere a route is named
    /// so the same lane reads the same colour in a chain row, a pick row and a
    /// health chip.
    static func routeTint(_ route: BrokerPolicy.Route) -> Color {
        switch route {
        case .native: return .accentColor
        case .t3: return .purple
        case .codex: return .teal
        }
    }

    static func routeTint(named route: String) -> Color {
        BrokerPolicy.Route(rawValue: route).map(routeTint) ?? .secondary
    }
}

// MARK: - Card

private struct BrokerCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(BrokerUI.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: BrokerUI.sectionRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BrokerUI.sectionRadius)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
    }
}

private struct BrokerInsetRowModifier: ViewModifier {
    let isEmphasized: Bool

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isEmphasized
                    ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                    : AnyShapeStyle(HierarchicalShapeStyle.quaternary.opacity(0.4)),
                in: RoundedRectangle(cornerRadius: BrokerUI.rowRadius)
            )
    }
}

extension View {
    /// The tab's one section-card treatment.
    func brokerCard() -> some View { modifier(BrokerCardModifier()) }

    /// The tab's one nested-row treatment, for rows that live inside a card.
    func brokerInsetRow(isEmphasized: Bool = false) -> some View {
        modifier(BrokerInsetRowModifier(isEmphasized: isEmphasized))
    }
}

// MARK: - Section header

/// Card header: symbol, title, optional explanatory subtitle, and a trailing
/// accessory (add menu, refresh button, …) aligned to the title's baseline row.
struct BrokerSectionHeader<Accessory: View>: View {
    private let title: String
    private let systemImage: String
    private let subtitle: String?
    private let help: BrokerHelpTopic?
    private let accessory: Accessory

    init(
        _ title: String,
        systemImage: String,
        subtitle: String? = nil,
        help: BrokerHelpTopic? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.help = help
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.headline)
                    if let help {
                        BrokerHelpButton(topic: help)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            accessory
        }
        .accessibilityElement(children: .contain)
    }
}

extension BrokerSectionHeader where Accessory == EmptyView {
    init(
        _ title: String,
        systemImage: String,
        subtitle: String? = nil,
        help: BrokerHelpTopic? = nil
    ) {
        self.init(title, systemImage: systemImage, subtitle: subtitle, help: help) { EmptyView() }
    }
}

// MARK: - Chip

/// Small labelled pill. `.solid` is reserved for states the user must not
/// miss (Degraded); everything else is `.subtle` so a row of chips stays
/// scannable rather than becoming a colour chart.
struct BrokerChip: View {
    enum Style { case subtle, solid, outline }

    let text: String
    var systemImage: String?
    var tint: Color = .secondary
    var style: Style = .subtle
    var isMonospaced: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(text)
                .font(isMonospaced ? .caption2.monospaced() : .caption2)
                .lineLimit(1)
        }
        .fontWeight(style == .solid ? .semibold : .regular)
        .foregroundStyle(foreground)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(background, in: Capsule())
        .overlay {
            if style == .outline {
                Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
            }
        }
        .accessibilityLabel(text)
    }

    private var foreground: AnyShapeStyle {
        switch style {
        case .solid: return AnyShapeStyle(Color.white)
        case .subtle, .outline: return AnyShapeStyle(tint)
        }
    }

    private var background: AnyShapeStyle {
        switch style {
        case .solid: return AnyShapeStyle(tint)
        case .subtle: return AnyShapeStyle(tint.opacity(0.14))
        case .outline: return AnyShapeStyle(Color.clear)
        }
    }
}

// MARK: - Status dot

/// Filled dot inside a soft halo of the same colour. The halo is what makes a
/// 7pt dot legible at a glance against both card and material backgrounds.
struct BrokerStatusDot: View {
    let color: Color
    var diameter: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .padding(diameter * 0.45)
            .background(Circle().fill(color.opacity(0.2)))
            .accessibilityHidden(true)
    }
}

// MARK: - Empty state

/// Shared empty state for the tab's lists, so "nothing here yet" always looks
/// deliberate rather than like a rendering failure.
struct BrokerEmptyState: View {
    let title: String
    let systemImage: String
    var hint: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rank badge

/// The candidate's rank in its chain. Rank 1 is tinted because "which one is
/// tried first" is the single most important fact about a chain, and order
/// alone stops communicating it once a row is being dragged.
struct BrokerRankBadge: View {
    /// Published so a row can indent its second line to the control that
    /// follows the badge instead of re-deriving the width.
    static let diameter: CGFloat = 16

    let rank: Int

    var body: some View {
        Text("\(rank)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(rank == 1 ? Color.accentColor : Color.secondary)
            .frame(width: BrokerRankBadge.diameter, height: BrokerRankBadge.diameter)
            .background(
                Circle().fill(
                    rank == 1 ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)
                )
            )
            .accessibilityHidden(true)
    }
}
