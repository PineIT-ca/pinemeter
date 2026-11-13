import Foundation

struct HostLoginRequest: Equatable, Sendable {
    let hostID: UUID
    let provider: HostLoginProvider
    let accountID: String

    init(hostID: UUID, provider: HostLoginProvider, accountID: String) {
        self.hostID = hostID
        self.provider = provider
        self.accountID = accountID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard Set(userInfo.keys) == Set<AnyHashable>(["host_id", "provider", "account_id"]),
              let host = userInfo["host_id"] as? String, let hostID = UUID(uuidString: host),
              let word = userInfo["provider"] as? String, let provider = HostLoginProvider(rawValue: word),
              let accountID = userInfo["account_id"] as? String,
              HostLoginGrammar.remoteCommand(loginWord: provider.loginWord, accountID: accountID) != nil
        else { return nil }
        self.init(hostID: hostID, provider: provider, accountID: accountID)
    }
}

extension Notification.Name {
    static let startHostLogin = Notification.Name("startHostLogin")
}

@MainActor
enum HostLoginNavigation {
    static func openRemoteHostsPane() {
        TestSafeDefaults.standardOrIsolated.set("remoteHosts", forKey: BrokerWindowView.paneDefaultsKey)
        NotificationCenter.default.post(name: .openBrokerSettings, object: nil)
        NotificationCenter.default.post(
            name: .showBrokerPane, object: nil,
            userInfo: BrokerWindowView.showPaneUserInfo(pane: .remoteHosts, instanceId: nil)
        )
    }
}
