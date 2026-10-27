import Foundation

enum BrokerPresetFreshness {
    static func warning(issuedAt: Date?, now: Date) -> String? {
        guard let issuedAt else { return nil }
        let age = max(0, now.timeIntervalSince(issuedAt))
        let day: TimeInterval = 24 * 60 * 60
        guard age > Double(BrokerPresetDistribution.freezeWarningDays) * day else { return nil }
        let days = Int(age / day)
        return "Official presets were last published \(days) days ago. Updates may be blocked; current presets stay in use."
    }
}
