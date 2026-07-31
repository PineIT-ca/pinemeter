//
//  UsageAPIResponse.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

/// API response for usage data.
///
/// Anthropic is migrating accounts from the flat top-level keys
/// (`five_hour`, `seven_day`, `seven_day_*`) to the `limits` array; on
/// migrated accounts the flat keys return null. Both shapes must decode and
/// map, so every flat key is optional and `toDomain()` falls back to the
/// matching `limits` entry (`kind`: "session" / "weekly_all" /
/// "weekly_scoped").
struct UsageAPIResponse: Codable {
    let fiveHour: UsageLimitResponse?
    let sevenDay: UsageLimitResponse?
    let sevenDaySonnet: UsageLimitResponse?
    var sevenDayFable: UsageLimitResponse? = nil
    var limits: [ScopedUsageLimitResponse]? = nil

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayFable = "seven_day_fable"
        case limits
    }
}

/// Newer Claude usage responses expose per-window meters in `limits`.
struct ScopedUsageLimitResponse: Codable {
    struct Scope: Codable {
        struct Model: Codable {
            let id: String?
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }

            init(id: String? = nil, displayName: String?) {
                self.id = id
                self.displayName = displayName
            }
        }

        let model: Model?
    }

    var kind: String? = nil
    var group: String? = nil
    let percent: Double?
    let resetsAt: String?
    let scope: Scope?

    enum CodingKeys: String, CodingKey {
        case kind
        case group
        case percent
        case resetsAt = "resets_at"
        case scope
    }

    init(
        kind: String? = nil,
        group: String? = nil,
        percent: Double?,
        resetsAt: String?,
        scope: Scope?
    ) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.resetsAt = resetsAt
        self.scope = scope
    }

    /// True when this entry is scoped to the Fable model. Matches the
    /// rename-prone `display_name` and the stable model id, either of which
    /// may be null on live responses.
    var isFableScoped: Bool {
        guard let model = scope?.model else { return false }
        if model.displayName?.localizedCaseInsensitiveContains("fable") == true { return true }
        if let id = model.id?.lowercased(), id.contains("fable") || id.contains("mythos") { return true }
        return false
    }
}

/// Individual usage limit response from API
struct UsageLimitResponse: Codable {
    let utilization: Double // Percentage 0-100
    let resetsAt: String? // ISO8601 string, can be null

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Mapping error for API response conversion
enum MappingError: LocalizedError {
    case invalidDateFormat
    case missingCriticalField(field: String)

    var errorDescription: String? {
        switch self {
        case .invalidDateFormat:
            return "Server returned invalid date format"
        case .missingCriticalField(let field):
            return "Server response missing critical field: \(field)"
        }
    }
}

/// Extension to map API response to domain model
extension UsageAPIResponse {
    func toDomain() throws -> UsageData {
        // The flat keys win when present; migrated accounts only populate
        // the matching `limits` entries.
        let sessionEntry = limitEntry(kind: "session", group: "session")
        let weeklyEntry = limitEntry(kind: "weekly_all", group: "weekly")

        guard let sessionUtilization = fiveHour?.utilization ?? sessionEntry?.percent else {
            throw MappingError.missingCriticalField(field: "five_hour")
        }
        guard let weeklyUtilization = sevenDay?.utilization ?? weeklyEntry?.percent else {
            throw MappingError.missingCriticalField(field: "seven_day")
        }

        let sessionResetDate = try parseResetDate(
            from: fiveHour?.resetsAt ?? sessionEntry?.resetsAt,
            field: "fiveHour.resetsAt",
            fallback: Constants.Pacing.sessionWindow
        )
        let weeklyResetDate = try parseResetDate(
            from: sevenDay?.resetsAt ?? weeklyEntry?.resetsAt,
            field: "sevenDay.resetsAt",
            fallback: Constants.Pacing.weeklyWindow
        )

        // Handle optional sonnet usage. Flat key only, deliberately: nothing
        // renders sonnetUsage today, so it gets no limits[] fallback until a
        // UI consumer exists.
        let sonnetLimit: UsageLimit? = try sevenDaySonnet.flatMap { sonnet -> UsageLimit? in
            let sonnetResetDate = try parseResetDate(
                from: sonnet.resetsAt,
                field: "sevenDaySonnet.resetsAt",
                fallback: Constants.Pacing.weeklyWindow
            )
            return UsageLimit(
                utilization: sonnet.utilization,
                resetAt: sonnetResetDate
            )
        }

        return UsageData(
            sessionUsage: UsageLimit(
                utilization: sessionUtilization,
                resetAt: sessionResetDate
            ),
            weeklyUsage: UsageLimit(
                utilization: weeklyUtilization,
                resetAt: weeklyResetDate
            ),
            sonnetUsage: sonnetLimit,
            fableUsage: fableLimit(),
            lastUpdated: Date()
        )
    }

    /// The first `limits` entry matching `kind`, falling back to an unscoped
    /// entry in `group` for forward compatibility with new kind values.
    private func limitEntry(kind: String, group: String) -> ScopedUsageLimitResponse? {
        guard let limits else { return nil }
        if let match = limits.first(where: { $0.kind == kind && $0.percent != nil }) {
            return match
        }
        return limits.first { $0.group == group && $0.scope == nil && $0.percent != nil }
    }

    /// Model-scoped Fable usage from the flat `seven_day_fable` key or the
    /// scoped `limits` entry. A malformed reset date degrades to the pacing
    /// fallback instead of failing the whole response; the model-scoped bar
    /// is not worth losing every meter over.
    private func fableLimit() -> UsageLimit? {
        if let flat = sevenDayFable {
            return UsageLimit(
                utilization: flat.utilization,
                resetAt: lenientResetDate(from: flat.resetsAt, fallback: Constants.Pacing.weeklyWindow)
            )
        }

        guard let fable = limits?.first(where: { $0.isFableScoped && $0.percent != nil }),
              let percent = fable.percent else {
            return nil
        }
        return UsageLimit(
            utilization: percent,
            resetAt: lenientResetDate(from: fable.resetsAt, fallback: Constants.Pacing.weeklyWindow)
        )
    }

    private func parseResetDate(
        from rawValue: String?,
        field: String,
        fallback: TimeInterval
    ) throws -> Date {
        guard let rawValue else {
            return Date().addingTimeInterval(fallback)
        }
        guard let date = Self.parseISO8601(rawValue) else {
            throw MappingError.missingCriticalField(field: field)
        }
        return date
    }

    private func lenientResetDate(from rawValue: String?, fallback: TimeInterval) -> Date {
        rawValue.flatMap(Self.parseISO8601) ?? Date().addingTimeInterval(fallback)
    }

    /// The server emits fractional seconds today but has not always; accept
    /// both rather than failing the fetch on a formatting change.
    private static func parseISO8601(_ rawValue: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: rawValue) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: rawValue)
    }
}
