//
//  AccountCardChrome.swift
//  Pinemeter
//
//  The parts of an account card in Settings > Accounts that do not touch
//  `AppModel`: the provider mark, the card frame, and the header, name and
//  detail rows. `SettingsView` supplies the rename field, the actions menu
//  and the status strip, since those carry bindings and confirmations.
//

import SwiftUI

/// A small tinted badge that names the provider. Every card carries one so
/// a row of cards reads as "Claude, Claude, ChatGPT, Gemini" before any
/// account name is read. The tint is a system colour, so it adapts to dark
/// mode and increased contrast; the name beside it carries the meaning for
/// anyone who cannot rely on the tint.
struct ProviderMark: View {
    let provider: CredentialProvider

    private var systemImage: String {
        switch provider {
        case .claude: return "sparkle"
        case .chatGPT: return "text.bubble.fill"
        case .gemini: return "diamond.fill"
        }
    }

    private var tint: Color {
        switch provider {
        case .claude: return .orange
        case .chatGPT: return .green
        case .gemini: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(provider.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.displayName)
    }
}

/// The card: provider header with an optional Primary badge and a trailing
/// menu, the account name row, one detail line, and the status strip.
struct AccountCard<Name: View, Menu: View, Status: View>: View {
    let provider: CredentialProvider
    let isPrimary: Bool
    /// `true` when this account exists only because of a CLI login (Codex
    /// CLI or Claude Code), never a stored browser cookie (CLI-08, D-01).
    let isCLILogin: Bool
    /// Plan, email or organisation, and browser profile, already joined.
    let detail: String?
    /// Called when the pencil button is pressed; focuses the name field.
    let onRename: (() -> Void)?
    /// Names the account in the rename button's spoken label, so VoiceOver
    /// can tell one card's rename button from the next.
    let accountName: String
    private let name: Name
    private let menu: Menu
    private let status: Status

    init(
        provider: CredentialProvider,
        isPrimary: Bool = false,
        isCLILogin: Bool = false,
        detail: String? = nil,
        accountName: String = "",
        onRename: (() -> Void)? = nil,
        @ViewBuilder name: () -> Name,
        @ViewBuilder menu: () -> Menu,
        @ViewBuilder status: () -> Status
    ) {
        self.provider = provider
        self.isPrimary = isPrimary
        self.isCLILogin = isCLILogin
        self.detail = detail
        self.accountName = accountName
        self.onRename = onRename
        self.name = name()
        self.menu = menu()
        self.status = status()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderMark(provider: provider)

                if isPrimary {
                    Text("Primary")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                if isCLILogin {
                    Text("CLI login")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("CLI login")
                }

                Spacer(minLength: 4)

                menu
            }

            HStack(spacing: 4) {
                name
                    .font(.callout.weight(.semibold))
                if let onRename {
                    Button(action: onRename) {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Rename")
                    .accessibilityLabel(accountName.isEmpty ? "Rename account" : "Rename \(accountName)")
                }
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            status
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        )
    }
}

/// Joins the parts of a card's detail line, dropping blanks, with the
/// middle dot System Settings uses between facts.
func accountDetailLine(_ parts: [String?]) -> String? {
    let kept = parts.compactMap { part -> String? in
        guard let part else { return nil }
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    return kept.isEmpty ? nil : kept.joined(separator: " · ")
}
