//
//  ConnectionStatusStrip.swift
//  Pinemeter
//
//  One status treatment for every connected thing Pinemeter shows: a usage
//  account in Settings, a T3 instance in the Broker window. Each card used to
//  carry an 8pt coloured dot whose only explanation was a hover tooltip, and
//  whose remedy lived somewhere else on the card, or nowhere.
//
//  The strip puts the three things a user needs on one line: what state the
//  connection is in, why, and the one action that changes it. Colour is
//  reinforced by an icon and a title, so the state is legible without
//  colour vision and at a glance from across the window.
//

import SwiftUI

/// The state of one connection, reduced to what the strip renders. The
/// `forAccount` and `forInstance` factories hold the mapping from model state
/// to user-facing words, so unit tests can cover the wording without a
/// snapshot and both windows stay in agreement.
struct ConnectionStatus: Equatable {
    enum Tone: Equatable {
        case healthy
        case waiting
        case warning
        case failure
        case checking
        case off

        var color: Color {
            switch self {
            case .healthy: return .green
            case .waiting: return .secondary
            case .warning: return .orange
            case .failure: return .red
            case .checking: return .blue
            case .off: return .secondary
            }
        }

        var systemImage: String {
            switch self {
            case .healthy: return "checkmark.circle.fill"
            case .waiting: return "clock"
            case .warning: return "exclamationmark.triangle.fill"
            case .failure: return "xmark.octagon.fill"
            case .checking: return "hourglass"
            case .off: return "moon.zzz.fill"
            }
        }

        var accessibilityName: String {
            switch self {
            case .healthy: return "Healthy"
            case .waiting: return "Waiting"
            case .warning: return "Needs attention"
            case .failure: return "Failed"
            case .checking: return "Checking"
            case .off: return "Off"
            }
        }
    }

    /// What the primary action should do, when the state has one. The view
    /// that owns the strip decides how each action is performed.
    enum Action: Equatable {
        case refreshUsage
        case reconnect
        case repair
        case openGeneralSettings
        case probeInstance
        case setHealthCheckAddress
    }

    var tone: Tone
    var title: String
    var detail: String?
    var action: Action?

    // MARK: - Accounts

    /// Maps a usage account's credential health to a strip.
    ///
    /// - Parameters:
    ///   - health: The card's derived credential health.
    ///   - usageAge: Seconds since the last successful usage fetch, when known.
    ///   - monitoringOff: True when the provider's usage display is switched
    ///     off in General settings; the account is connected but idle.
    ///   - error: The account's current error text, when any.
    ///   - recoverySuggestion: Provider-supplied remedy text for failed states.
    ///   - hasRepairAction: True when the provider exposes a repair action.
    static func forAccount(
        health: CredentialHealthState,
        usageAge: TimeInterval?,
        monitoringOff: Bool,
        error: String?,
        recoverySuggestion: String?,
        hasRepairAction: Bool
    ) -> ConnectionStatus {
        if monitoringOff {
            return ConnectionStatus(
                tone: .off,
                title: "Monitoring off",
                detail: "Usage for this account is turned off in General settings.",
                action: .openGeneralSettings
            )
        }
        switch health {
        case .valid:
            let detail = usageAge.map { "Usage updated \(ageText($0)) ago." }
            return ConnectionStatus(tone: .healthy, title: "Connected", detail: detail, action: nil)
        case .missing:
            return ConnectionStatus(
                tone: .failure,
                title: "Not connected",
                detail: recoverySuggestion
                    ?? "No saved session for this account. Sign in to the provider in your browser, then reconnect.",
                action: .reconnect
            )
        case .unknown:
            return ConnectionStatus(
                tone: .waiting,
                title: "Waiting for usage",
                detail: "No usage has been fetched for this account yet.",
                action: .refreshUsage
            )
        case .validating:
            return ConnectionStatus(
                tone: .checking,
                title: "Checking",
                detail: "Pinemeter is checking the saved session.",
                action: nil
            )
        case .refreshRecommended:
            return ConnectionStatus(
                tone: .warning,
                title: "Session expires soon",
                detail: recoverySuggestion ?? "Reconnect from your signed-in browser before it stops working.",
                action: .reconnect
            )
        case .invalid, .expired, .unavailable:
            let detail = error ?? recoverySuggestion
                ?? "Sign in to the provider in your browser, then reconnect."
            return ConnectionStatus(
                tone: .failure,
                title: health == .expired ? "Session expired" : "Not connected",
                detail: detail,
                action: hasRepairAction ? .repair : .reconnect
            )
        }
    }

    // MARK: - T3 instances

    /// Maps a T3 instance's probe result and detection status to a strip.
    ///
    /// - Parameters:
    ///   - reachable: The last liveness probe result, or nil if never probed.
    ///   - why: The probe's reason text, for example `http 200` or
    ///     `connect failed`.
    ///   - instanceStatus: Detected, manual, or stale per the discovery scan.
    ///   - staleAge: Seconds since the scan last reported the instance, when
    ///     the status is stale and the time is known.
    static func forInstance(
        reachable: Bool?,
        why: String?,
        instanceStatus: T3InstanceStatus,
        staleAge: TimeInterval?
    ) -> ConnectionStatus {
        switch reachable {
        case .some(true):
            if instanceStatus == .stale {
                return ConnectionStatus(
                    tone: .warning,
                    title: "Reachable, detection stale",
                    detail: staleDetail(staleAge),
                    action: .probeInstance
                )
            }
            return ConnectionStatus(
                tone: .healthy,
                title: "Reachable",
                detail: why.map { "Health check answered: \($0)." },
                action: nil
            )
        case .some(false):
            return ConnectionStatus(
                tone: .failure,
                title: "Unreachable",
                detail: "T3 is not running for this instance, or it listens at an address "
                    + "Pinemeter cannot find. Start T3, or set the health check address below."
                    + (why.map { " Last probe: \($0)." } ?? ""),
                action: .probeInstance
            )
        case .none:
            if instanceStatus == .stale {
                return ConnectionStatus(
                    tone: .warning,
                    title: "Detection stale",
                    detail: staleDetail(staleAge),
                    action: .probeInstance
                )
            }
            return ConnectionStatus(
                tone: .waiting,
                title: "Not checked yet",
                detail: "The broker probes this instance on its next refresh.",
                action: .probeInstance
            )
        }
    }

    private static func staleDetail(_ age: TimeInterval?) -> String {
        guard let age else {
            return "T3 has not reported this instance recently. Start T3 for this instance, then probe again."
        }
        return "T3 has not reported this instance for \(ageText(age)). "
            + "Start T3 for this instance, then probe again."
    }

    static func ageText(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return "\(whole / 60)m" }
        if whole < 86_400 { return "\(whole / 3600)h" }
        return "\(whole / 86_400)d"
    }
}

/// The strip itself. The owning view supplies the buttons, so the strip
/// stays free of any knowledge about AppModel.
struct ConnectionStatusStrip<Actions: View>: View {
    let status: ConnectionStatus
    private let actions: Actions

    init(_ status: ConnectionStatus, @ViewBuilder actions: () -> Actions) {
        self.status = status
        self.actions = actions()
    }

    /// Healthy and off are the quiet states: one line, no tinted box, so
    /// that a card with a problem is the one that stands out. Every other
    /// tone keeps the full strip with its icon halo and action.
    private var isCompact: Bool {
        status.tone == .healthy || status.tone == .off
    }

    var body: some View {
        Group {
            if isCompact {
                compactBody
            } else {
                fullBody
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.tone.accessibilityName): \(status.title). \(status.detail ?? "")")
    }

    private var compactBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: status.tone.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(status.tone.color)
                .accessibilityHidden(true)

            Text(status.title)
                .font(.caption.weight(.semibold))

            if let detail = status.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                actions
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fullBody: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(status.tone.color.opacity(0.15))
                    .frame(width: 24, height: 24)
                if status.tone == .checking {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: status.tone.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(status.tone.color)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(status.tone.color)
                if let detail = status.detail {
                    // Failure and warning details carry provider error text
                    // the user may need to paste into a bug report, so they
                    // keep the explicit copy affordance every other
                    // user-facing error surface has.
                    if status.tone == .failure || status.tone == .warning {
                        CopyableErrorText(detail, font: .caption, foregroundStyle: .secondary)
                    } else {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                actions
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(status.tone.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
    }
}

extension ConnectionStatusStrip where Actions == EmptyView {
    init(_ status: ConnectionStatus) {
        self.init(status) { EmptyView() }
    }
}

#Preview {
    VStack(spacing: 8) {
        ConnectionStatusStrip(.forAccount(
            health: .valid, usageAge: 12, monitoringOff: false,
            error: nil, recoverySuggestion: nil, hasRepairAction: false
        ))
        ConnectionStatusStrip(.forAccount(
            health: .expired, usageAge: nil, monitoringOff: false,
            error: nil, recoverySuggestion: "Sign in to Claude in Chrome, then reconnect.",
            hasRepairAction: false
        )) {
            Button("Reconnect") {}
        }
        ConnectionStatusStrip(.forInstance(
            reachable: false, why: "connect failed", instanceStatus: .detected, staleAge: nil
        )) {
            Button("Probe again") {}
            Button("Set address") {}
        }
    }
    .padding()
    .frame(width: 420)
}
