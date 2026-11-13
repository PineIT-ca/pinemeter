import SwiftUI

struct FableResetCampaignView: View {
    @Bindable var appModel: AppModel
    var body: some View {
        SettingsSection(footer: "Mac only. Coupons are not quota until redeemed. Stop removes the overlay immediately; base routing edits remain.") {
            if appModel.settings.broker.fableResetLoadWarning {
                Text("Some reset inventory could not be read. Valid accounts were preserved. Check the counts before starting.").foregroundStyle(.orange).settingsRowPadding()
            }
            HStack {
                Text(appModel.settings.broker.fableCampaign == nil ? "Stopped" : "Started (expires automatically)")
                Spacer()
                Button("Start") { Task { await appModel.startFableCampaign() } }
                    .disabled(!appModel.settings.broker.fableResets.values.contains { $0.isEligibleForWaiver && $0.waiverDeadline > Date() })
                Button("Stop") { Task { await appModel.stopFableCampaign() } }
                    .disabled(appModel.settings.broker.fableCampaign == nil)
            }.settingsRowPadding()
            ForEach(appModel.fableResetAccounts, id: \.id) { account in
                FableResetAccountEditor(appModel: appModel, accountID: account.id, label: account.label)
                    .settingsRowPadding()
            }
            Link("Open manual reset steps in Claude usage settings", destination: FableResetInventory.manualStepsURL)
                .settingsRowPadding()
        }
    }
}

private struct FableResetAccountEditor: View {
    @Bindable var appModel: AppModel
    let accountID: String
    let label: String
    @Environment(\.timeZone) private var timeZone
    @State private var count = 0
    @State private var expiry = FableResetInventory.defaultExpiry
    @State private var provenance = FableResetInventory.expirySource
    private var inventory: FableResetInventory { appModel.settings.broker.fableResets[accountID] ?? FableResetInventory() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline)
            Stepper("Manual resets remaining: \(count)", value: $count, in: 0...99)
            DatePicker("Coupon expiry (UTC)", selection: $expiry)
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            TextField("Expiry source and timezone", text: $provenance, axis: .vertical)
            Button("Save inventory correction") {
                Task { await appModel.editFableInventory(accountID: accountID, count: count, expiry: expiry, provenance: provenance) }
            }
            Text("Saved: \(inventory.count) resets. Waiver ends \(inventory.waiverDeadline.formatted(Date.FormatStyle(date: .numeric, time: .complete, timeZone: timeZone))).")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(inventory.notices.filter { $0.kind == .expiry || $0.kind == .confirm || (inventory.lastEvidence?.isFresh(now: Date()) == true && appModel.settings.broker.fableCampaign != nil && (inventory.snoozedUntil ?? .distantPast) <= Date()) }) { notice in
                Text(notice.message).font(.callout).textSelection(.enabled)
                if notice.kind == .redeem || notice.kind == .external {
                    HStack {
                        Button("I redeemed one reset") {
                            Task { await appModel.recordFableRedemption(accountID: accountID, noticeID: notice.id) }
                        }.disabled(inventory.count == 0 || inventory.expiresAt <= Date() || inventory.lastEvidence?.isFresh(now: Date()) != true || appModel.settings.broker.fableCampaign == nil)
                        Button("Snooze 1 hour") { appModel.snoozeFableReminder(accountID: accountID) }
                    }
                }
            }
            if let event = inventory.events.last {
                Text("Before: \(reading(event.before)). After: \(reading(event.after)). Refresh attempts: \(event.attempts)/3.")
                    .font(.caption).textSelection(.enabled)
                HStack {
                    if !event.confirmed && !event.undone && Date().timeIntervalSince(event.createdAt) >= 900 {
                        Button("Confirm unverified redemption") {
                            Task { await appModel.confirmFableRedemption(accountID: accountID, eventID: event.id) }
                        }
                    }
                    Button("Undo last redemption") {
                        Task { await appModel.undoFableRedemption(accountID: accountID, eventID: event.id) }
                    }.disabled(event.undone)
                }
            }
            Text("A redemption refunds only Fable's weekly usage and refills the entire five-hour allowance. Weekly usage from other models remains. Redeem in Claude first, then confirm here.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { load() }
        .onChange(of: inventory.count) { _, _ in count = inventory.count }
    }
    private func load() { count = inventory.count; expiry = inventory.expiresAt; provenance = inventory.expiryProvenance }
    private func reading(_ evidence: FableResetEvidence?) -> String {
        guard let evidence else { return "not verified" }
        return "weekly \(Int(evidence.weekly))%, Fable \(Int(evidence.fable))% at \(evidence.observedAt.formatted(date: .numeric, time: .standard))"
    }
}
