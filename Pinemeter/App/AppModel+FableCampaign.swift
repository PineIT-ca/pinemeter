import Foundation

extension AppModel {
    var fableResetAccounts: [(id: String, label: String)] {
        let accounts = settings.claudeAccounts.map { (id: $0.id, label: $0.displayLabel) }
        return accounts.isEmpty ? [(id: ClaudeAccount.primaryKeychainAccount, label: "Primary account")] : accounts
    }

    func editFableInventory(accountID: String, count: Int, expiry: Date, provenance: String) async {
        var inventory = settings.broker.fableResets[accountID] ?? FableResetInventory()
        inventory.correct(count: count, expiry: expiry, provenance: provenance, now: Date())
        settings.broker.fableResets[accountID] = inventory
        await syncFableCampaign()
    }

    func startFableCampaign() async {
        let now = Date()
        let deadlines = settings.broker.fableResets.filter { $0.value.isEligibleForWaiver }.mapValues(\.waiverDeadline).filter { $0.value > now }
        guard let expiry = deadlines.values.max() else { return }
        settings.broker.fableCampaign = FableCampaign(expiresAt: expiry, accountDeadlines: deadlines)
        await updateLocalFableCampaign()
    }

    func stopFableCampaign() async {
        settings.broker.fableCampaign = nil
        await updateLocalFableCampaign()
    }

    func syncFableCampaign() async {
        guard settings.broker.fableCampaign != nil else { return }
        let deadlines = settings.broker.fableResets.filter { $0.value.isEligibleForWaiver }.mapValues(\.waiverDeadline)
        let campaign = FableCampaign(expiresAt: deadlines.values.max() ?? .distantPast, accountDeadlines: deadlines)
        guard settings.broker.fableCampaign != campaign else { return }
        settings.broker.fableCampaign = campaign
        await updateLocalFableCampaign()
    }

    func recordFableRedemption(accountID: String, noticeID: String) async {
        guard settings.broker.fableCampaign != nil,
              settings.broker.fableResets[accountID]?.redeemed(id: noticeID, now: Date()) == true else { return }
        await refreshPendingFableRedemptions()
    }

    func confirmFableRedemption(accountID: String, eventID: String) async {
        guard settings.broker.fableResets[accountID]?.confirmUnverified(id: eventID) == true else { return }
        await syncFableCampaign()
    }

    func undoFableRedemption(accountID: String, eventID: String) async {
        guard settings.broker.fableResets[accountID]?.undo(id: eventID) == true else { return }
        await syncFableCampaign()
    }

    func snoozeFableReminder(accountID: String) {
        settings.broker.fableResets[accountID]?.snooze(until: Date().addingTimeInterval(3600))
    }

    /// The existing refresh loop owns retries. No campaign timer or polling in pick.
    func takePendingFableRefreshAttempts(now: Date) -> Bool {
        guard settings.broker.fableCampaign != nil else { return false }
        var requested = false
        for id in Array(settings.broker.fableResets.keys) {
            if settings.broker.fableResets[id]?.takeRefreshAttempt(now: now) == true { requested = true }
        }
        return requested
    }

    func refreshPendingFableRedemptions() async {
        guard takePendingFableRefreshAttempts(now: Date()) else { return }
        await refreshUsage(forceRefresh: true)
        await refreshAdditionalClaudeAccounts(forceRefresh: true)
    }
}
