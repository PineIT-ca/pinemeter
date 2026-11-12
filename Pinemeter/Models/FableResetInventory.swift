import Foundation

struct FableResetEvidence: Codable, Equatable, Sendable {
    var observedAt: Date
    var weekly: Double
    var fable: Double
    var resetAt: Date

    func isFresh(now: Date) -> Bool {
        (0...100).contains(weekly) && (0...100).contains(fable)
            && (0...600).contains(now.timeIntervalSince(observedAt))
            && resetAt > now && resetAt <= now.addingTimeInterval(7 * 86400)
    }

    init(observedAt: Date, weekly: Double, fable: Double, resetAt: Date) {
        self.observedAt = observedAt; self.weekly = weekly; self.fable = fable; self.resetAt = resetAt
    }

    init?(row: OracleSnapshot.AccountRow, now: Date) {
        guard row.state == .fresh, let at = row.lastUpdated, let weekly = row.weekly,
              let fable = row.fable, let reset = row.fableResetAt else { return nil }
        self.init(observedAt: at, weekly: weekly, fable: fable, resetAt: reset)
        guard isFresh(now: now) else { return nil }
    }
}

struct FableResetNotice: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable { case redeem, expiry, confirm, external }
    var id: String
    var kind: Kind
    var message: String
}

/// Local manual inventory, never a quota/headroom source.
struct FableResetInventory: Codable, Equatable, Sendable {
    static let defaultExpiry = Date(timeIntervalSince1970: 1804579140)
    static let expirySource = "March 8, 2027 23:59 America/Los_Angeles (PST, UTC-08:00); March 9 00:59 PDT is the same instant."
    static let manualStepsURL = URL(string: "https://claude.ai/settings/usage")!
    struct Event: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var createdAt: Date
        var before: FableResetEvidence?
        var after: FableResetEvidence?
        var attempts = 0
        var lastAttemptAt: Date?
        var confirmed = false
        var undone = false
        var extensionAt: Date?
    }
    var count: Int
    var expiresAt: Date
    var expiryProvenance = Self.expirySource
    private(set) var generation = 0
    private(set) var events: [Event] = []
    private(set) var delivered: [String] = []
    private(set) var notices: [FableResetNotice] = []
    private(set) var lastEvidence: FableResetEvidence?
    private var externalBefore: FableResetEvidence?
    var snoozedUntil: Date?
    private(set) var corrections: [String] = []

    init(count: Int = 0, expiresAt: Date = Self.defaultExpiry) {
        self.count = min(99, max(0, count)); self.expiresAt = expiresAt
    }
    var isEligibleForWaiver: Bool { count > 0 || events.contains { !$0.undone } }
    var waiverDeadline: Date {
        events.filter { !$0.undone }.compactMap(\.extensionAt).reduce(expiresAt, max)
    }
    var pending: Event? { events.last { !$0.undone && !$0.confirmed } }
    static func weeklyOpportunities(resetAt: Date, expiry: Date) -> Int {
        max(0, Int(floor(expiry.timeIntervalSince(resetAt) / (7 * 86400))))
    }
    private func key(_ prefix: String, reset: Date) -> String {
        "\(prefix):\(generation):\(Int(reset.timeIntervalSince1970))"
    }
    private mutating func deliver(_ notice: FableResetNotice, into output: inout [FableResetNotice]) {
        if delivered.contains(notice.id) {
            if !notices.contains(where: { $0.id == notice.id }) { notices = Array((notices + [notice]).suffix(8)) }
            return
        }
        delivered = Array((delivered + [notice.id]).suffix(128))
        notices = Array((notices + [notice]).suffix(8))
        output.append(notice)
    }

    /// Called only for refreshed observations. Repeated exports are inert.
    mutating func observe(_ evidence: FableResetEvidence?, now: Date, active: Bool) -> [FableResetNotice] {
        var output: [FableResetNotice] = []
        let fresh = evidence.flatMap { $0.isFresh(now: now) ? $0 : nil }
        var verifiedRefill = false
        if let fresh {
            // Pending and explicitly confirmed events can verify later; stale data cannot extend a waiver.
            if let i = events.lastIndex(where: { !$0.undone && $0.after == nil }),
               let before = events[i].before, fresh.observedAt > events[i].createdAt,
               fresh.fable <= before.fable - 5 {
                verifiedRefill = true
                events[i].after = fresh
                events[i].extensionAt = min(fresh.resetAt, events[i].createdAt.addingTimeInterval(7 * 86400))
                if !events[i].confirmed { generation += 1 }
                events[i].confirmed = true
                notices.removeAll { $0.kind == .confirm || $0.kind == .redeem || $0.kind == .external }
            }
        }
        if let fresh, let i = events.lastIndex(where: { !$0.undone }),
           let after = events[i].after, let before = events[i].before,
           fresh.observedAt > after.observedAt, fresh.fable <= before.fable - 5 {
            events[i].after = fresh
            events[i].extensionAt = min(fresh.resetAt, events[i].createdAt.addingTimeInterval(7 * 86400))
        }
        // A fresh row invalidates advice from an old window or spent opportunity.
        let actionable = active && count > 0 && now < expiresAt && pending == nil
            && !events.contains { !$0.undone && $0.confirmed && $0.after == nil }
        let urgent = fresh.map { expiresAt.timeIntervalSince(now) <= 2 * 86400 || count >= Self.weeklyOpportunities(resetAt: $0.resetAt, expiry: expiresAt) } ?? false
        var retainedNotices = notices
        retainedNotices.removeAll { notice in
            if notice.kind == .redeem {
                guard actionable, let fresh else { return true }
                return notice.id != key("redeem", reset: fresh.resetAt)
                    || fresh.fable < (urgent ? 50 : 90) || (!urgent && fresh.resetAt.timeIntervalSince(now) < 86400)
            }
            if notice.kind == .external {
                guard actionable, let fresh, let before = externalBefore else { return true }
                return notice.id != key("external", reset: fresh.resetAt) || now >= before.resetAt
                    || !(fresh.fable <= before.fable - 5 || fresh.resetAt.timeIntervalSince(before.resetAt) <= -300)
            }
            return false
        }
        notices = retainedNotices
        defer { if let fresh { lastEvidence = fresh } }
        guard active else { return output }
        if let pending, now.timeIntervalSince(pending.createdAt) >= 900 {
            deliver(.init(id: "confirm:\(pending.id)", kind: .confirm,
                message: "Refresh could not verify the refill. Confirm the manual redemption once, or undo it. No waiver extension until a fresh refill is observed."), into: &output)
        }
        if let snoozedUntil, now >= snoozedUntil {
            self.snoozedUntil = nil
            delivered.removeAll { $0.hasPrefix("redeem:\(generation):") }
        }
        guard count > 0, now < expiresAt, (snoozedUntil ?? .distantPast) <= now else { return output }
        let band = expiresAt.timeIntervalSince(now) <= 2 * 86400 ? 2 : 14
        if expiresAt.timeIntervalSince(now) <= 14 * 86400 {
            let days = band
            deliver(.init(id: "expiry:\(days):\(Int(expiresAt.timeIntervalSince1970))", kind: .expiry,
                message: "\(count) manual resets expire at \(expiresAt.formatted(date: .numeric, time: .complete))."), into: &output)
        }
        guard let fresh, pending == nil,
              !events.contains(where: { !$0.undone && $0.confirmed && $0.after == nil }) else { return output }
        let prior = externalBefore.flatMap { now < $0.resetAt ? $0 : nil } ?? lastEvidence
        if !verifiedRefill, let prior, fresh.observedAt > prior.observedAt, now < prior.resetAt,
           fresh.fable <= prior.fable - 5 || fresh.resetAt.timeIntervalSince(prior.resetAt) <= -300 {
            externalBefore = prior
            deliver(.init(id: key("external", reset: fresh.resetAt), kind: .external,
                message: "Fable usage dropped before its natural reset. Did you redeem a reset outside Pinemeter? Confirm manually; inventory has not changed."), into: &output)
        }
        guard fresh.fable >= (urgent ? 50 : 90), urgent || fresh.resetAt.timeIntervalSince(now) >= 86400 else { return output }
        deliver(.init(id: key("redeem", reset: fresh.resetAt), kind: .redeem,
            message: "Fable \(Int(fresh.fable))%, weekly \(Int(fresh.weekly))%. \(urgent ? "Use remaining resets before" : "Consider a manual reset before") \(expiresAt.formatted(date: .numeric, time: .complete)). Only Fable's weekly consumption is refunded; the entire five-hour allowance refills. Other models' weekly consumption remains."), into: &output)
        return output
    }

    mutating func redeemed(id: String, now: Date) -> Bool {
        guard count > 0, now < expiresAt, pending == nil, !events.contains(where: { $0.id == id }),
              lastEvidence?.isFresh(now: now) == true,
              notices.contains(where: { $0.id == id && ($0.kind == .redeem || $0.kind == .external) }) else { return false }
        count -= 1
        let before = id.hasPrefix("external:") ? externalBefore : lastEvidence
        externalBefore = nil
        events = Array((events + [Event(id: id, createdAt: now, before: before)]).suffix(32))
        notices.removeAll { $0.kind == .redeem || $0.kind == .external }
        return true
    }
    mutating func takeRefreshAttempt(now: Date) -> Bool {
        guard let i = events.lastIndex(where: { !$0.undone && !$0.confirmed }),
              events[i].attempts < 3, now.timeIntervalSince(events[i].createdAt) < 900,
              now.timeIntervalSince(events[i].lastAttemptAt ?? .distantPast) >= 300 else { return false }
        events[i].attempts += 1; events[i].lastAttemptAt = now
        return true
    }
    mutating func confirmUnverified(id: String) -> Bool {
        guard let i = events.firstIndex(where: { $0.id == id && !$0.confirmed && !$0.undone }) else { return false }
        events[i].confirmed = true; generation += 1
        notices.removeAll { $0.id == "confirm:\(id)" }
        return true
    }
    mutating func undo(id: String) -> Bool {
        guard let i = events.firstIndex(where: { $0.id == id && !$0.undone }) else { return false }
        events[i].undone = true; count = min(99, count + 1)
        generation += 1
        notices.removeAll { $0.kind == .confirm || $0.kind == .redeem || $0.kind == .external }
        return true
    }
    mutating func snooze(until: Date) {
        snoozedUntil = until
        notices.removeAll { $0.kind == .redeem || $0.kind == .external }
    }
    mutating func correct(count: Int, expiry: Date, provenance: String, now: Date) {
        self.count = min(99, max(0, count)); expiresAt = expiry; expiryProvenance = String(provenance.prefix(512))
        generation += 1
        notices.removeAll { $0.kind == .redeem || $0.kind == .external }
        corrections = Array((corrections + ["\(now.formatted(.iso8601)): count=\(self.count), expiry=\(expiry.formatted(.iso8601))"]).suffix(32))
    }
}

// Additive fields default independently, so older inventory does not disappear.
extension FableResetInventory {
    private enum CodingKeys: String, CodingKey {
        case count, expiresAt, expiryProvenance, generation, events, delivered, notices
        case lastEvidence, externalBefore, snoozedUntil, corrections
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = min(99, max(0, try c.decode(Int.self, forKey: .count)))
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        expiryProvenance = try c.decodeIfPresent(String.self, forKey: .expiryProvenance) ?? Self.expirySource
        generation = max(0, try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0)
        events = Array((try c.decodeIfPresent([Event].self, forKey: .events) ?? []).suffix(32))
        delivered = Array((try c.decodeIfPresent([String].self, forKey: .delivered) ?? []).suffix(128))
        notices = Array((try c.decodeIfPresent([FableResetNotice].self, forKey: .notices) ?? []).suffix(8))
        lastEvidence = try c.decodeIfPresent(FableResetEvidence.self, forKey: .lastEvidence)
        externalBefore = try c.decodeIfPresent(FableResetEvidence.self, forKey: .externalBefore)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        corrections = Array((try c.decodeIfPresent([String].self, forKey: .corrections) ?? []).suffix(32))
    }
}

struct FableResetDecodedEntry: Decodable {
    let value: FableResetInventory?
    init(from decoder: Decoder) throws { value = try? FableResetInventory(from: decoder) }
}
