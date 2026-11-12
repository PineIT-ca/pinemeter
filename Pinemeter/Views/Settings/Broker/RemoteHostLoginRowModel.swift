import Foundation

struct RemoteHostLoginRowModel: Identifiable, Equatable {
    enum Tone { case neutral, good, warning, critical }

    let id: String
    let provider: HostLoginProvider
    let accountID: String
    let providerTitle: String
    let accountLabel: String
    let sourceText: String
    let badgeText: String
    let badgeTone: Tone
    let expiryText: String?
    let canLogIn: Bool

    static func rows(display: RemoteHostLoginDisplay?, labels: [String: String], now: Date) -> [RemoteHostLoginRowModel] {
        guard let display else { return [] }
        return display.rows.map { account in
            let key = HostLoginAlertEvaluator.loginKey(provider: account.provider, accountID: account.id)
            let sourceText: String
            switch account.source {
            case .hostLogin: sourceText = "Host login"
            case .pushedCookie: sourceText = "Pushed cookies"
            case .none: sourceText = "No credential"
            }
            let badgeText: String
            let badgeTone: Tone
            if !display.isCurrent {
                badgeText = "Unknown"
                badgeTone = .neutral
            } else if let login = account.login {
                switch login.state {
                case .fresh:
                    if account.provider == .claude, let expiry = login.refreshExpiresAt,
                       expiry.timeIntervalSince(now) <= HostLoginAlertEvaluator.expiryWarningWindow {
                        badgeText = "Expires soon"
                        badgeTone = .warning
                    } else {
                        badgeText = "Fresh"
                        badgeTone = .good
                    }
                case .refreshFailed:
                    badgeText = "Refresh failing"
                    badgeTone = .warning
                case .expired:
                    badgeText = "Expired"
                    badgeTone = .critical
                case .challenged:
                    badgeText = "Challenged"
                    badgeTone = .warning
                }
            } else {
                badgeText = "No host login"
                badgeTone = .neutral
            }
            let expiryText: String?
            if account.provider == .claude, let expiry = account.login?.refreshExpiresAt {
                expiryText = "Refresh expires \(expiry.formatted(date: .abbreviated, time: .shortened))"
            } else {
                expiryText = nil
            }
            return RemoteHostLoginRowModel(
                id: key, provider: account.provider, accountID: account.id,
                providerTitle: account.provider.displayName, accountLabel: labels[key] ?? account.id,
                sourceText: sourceText, badgeText: badgeText, badgeTone: badgeTone, expiryText: expiryText,
                canLogIn: HostLoginGrammar.remoteCommand(loginWord: account.provider.loginWord, accountID: account.id) != nil
            )
        }.sorted {
            if $0.providerTitle != $1.providerTitle { return $0.providerTitle < $1.providerTitle }
            return $0.accountLabel < $1.accountLabel
        }
    }
}
