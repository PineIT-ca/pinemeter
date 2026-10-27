import Foundation

enum HostLoginAlertCause: Equatable, Sendable {
    case expired
    case challenged
    case refreshFailed
    case expiryWarning(expiresAt: Date)
}

struct HostLoginAlert: Equatable, Sendable {
    let key: String
    let provider: HostLoginProvider
    let accountID: String
    let accountLabel: String
    let cause: HostLoginAlertCause

    static func notificationIdentifier(hostID: UUID, key: String) -> String {
        "host-login.\(hostID.uuidString.lowercased()).\(key)"
    }
}

enum HostLoginAlertEvaluator {
    static let refreshFailedThreshold: TimeInterval = 86_400
    static let expiryWarningWindow: TimeInterval = 259_200

    static func loginKey(provider: HostLoginProvider, accountID: String) -> String {
        "\(provider.rawValue)|\(accountID)"
    }

    static func accountLabels(from inventory: RemotePushAccountInventory) -> [String: String] {
        Dictionary(
            inventory.claude.map { (loginKey(provider: .claude, accountID: $0.id), $0.label) }
                + inventory.chatGPT.map { (loginKey(provider: .chatgpt, accountID: $0.id), $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func evaluate(
        previous: RemoteHostLoginAlertState,
        rows: [HostSourcesAccountDTO],
        labels: [String: String],
        now: Date
    ) -> (alerts: [HostLoginAlert], next: RemoteHostLoginAlertState) {
        var next = RemoteHostLoginAlertState()
        var alerts: [HostLoginAlert] = []
        let liveLogins = Set(rows.compactMap { row in
            row.login == nil ? nil : loginKey(provider: row.provider, accountID: row.id)
        })
        // ponytail: scan at most 256 live rows per saved key; index if alert state grows.
        next.deliveredKeys = previous.deliveredKeys.filter { key in
            liveLogins.contains { key.hasPrefix("\($0)|") }
        }
        next.refreshFailedSince = previous.refreshFailedSince.filter { liveLogins.contains($0.key) }
        for row in rows {
            guard let login = row.login else { continue }
            let loginKey = Self.loginKey(provider: row.provider, accountID: row.id)
            func emit(_ cause: HostLoginAlertCause, token: String) {
                let key = "\(loginKey)|\(token)"
                if !next.deliveredKeys.contains(key) {
                    alerts.append(HostLoginAlert(
                        key: key, provider: row.provider, accountID: row.id,
                        accountLabel: labels[loginKey] ?? row.id, cause: cause
                    ))
                }
            }
            if login.state != .refreshFailed {
                next.refreshFailedSince[loginKey] = nil
            }
            switch login.state {
            case .expired:
                emit(.expired, token: "expired")
            case .challenged:
                emit(.challenged, token: "challenged")
            case .refreshFailed:
                let since = next.refreshFailedSince[loginKey] ?? now
                next.refreshFailedSince[loginKey] = since
                if now.timeIntervalSince(since) >= refreshFailedThreshold {
                    emit(.refreshFailed, token: "refresh_failed")
                }
            case .fresh:
                for token in ["expired", "challenged", "refresh_failed"] {
                    next.deliveredKeys.remove("\(loginKey)|\(token)")
                }
                let expiryPrefix = "\(loginKey)|expiry|"
                if row.provider == .claude, let expiresAt = login.refreshExpiresAt,
                   expiresAt.timeIntervalSince(now) <= expiryWarningWindow {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.calendar = Calendar(identifier: .gregorian)
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "yyyy-MM-dd"
                    let token = "expiry|\(formatter.string(from: expiresAt))"
                    next.deliveredKeys = next.deliveredKeys.filter {
                        !$0.hasPrefix(expiryPrefix) || $0 == "\(loginKey)|\(token)"
                    }
                    emit(.expiryWarning(expiresAt: expiresAt), token: token)
                } else {
                    next.deliveredKeys = next.deliveredKeys.filter { !$0.hasPrefix(expiryPrefix) }
                }
            }
        }
        return (alerts.sorted { $0.key < $1.key }, next)
    }
}
