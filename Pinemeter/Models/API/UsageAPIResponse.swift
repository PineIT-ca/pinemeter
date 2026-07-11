//
//  UsageAPIResponse.swift
//  Pinemeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

/// API response for usage data
struct UsageAPIResponse: Codable {
    let fiveHour: UsageLimitResponse
    let sevenDay: UsageLimitResponse
    let sevenDaySonnet: UsageLimitResponse?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
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
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let sessionResetDate = try parseResetDate(
            from: fiveHour.resetsAt,
            field: "fiveHour.resetsAt",
            formatter: iso8601Formatter,
            fallback: Constants.Pacing.sessionWindow
        )
        let weeklyResetDate = try parseResetDate(
            from: sevenDay.resetsAt,
            field: "sevenDay.resetsAt",
            formatter: iso8601Formatter,
            fallback: Constants.Pacing.weeklyWindow
        )

        // Handle optional sonnet usage
        let sonnetLimit: UsageLimit? = try sevenDaySonnet.flatMap { sonnet -> UsageLimit? in
            let sonnetResetDate = try parseResetDate(
                from: sonnet.resetsAt,
                field: "sevenDaySonnet.resetsAt",
                formatter: iso8601Formatter,
                fallback: Constants.Pacing.weeklyWindow
            )
            return UsageLimit(
                utilization: sonnet.utilization,
                resetAt: sonnetResetDate
            )
        }

        return UsageData(
            sessionUsage: UsageLimit(
                utilization: fiveHour.utilization,
                resetAt: sessionResetDate
            ),
            weeklyUsage: UsageLimit(
                utilization: sevenDay.utilization,
                resetAt: weeklyResetDate
            ),
            sonnetUsage: sonnetLimit,
            lastUpdated: Date()
        )
    }

    private func parseResetDate(
        from rawValue: String?,
        field: String,
        formatter: ISO8601DateFormatter,
        fallback: TimeInterval
    ) throws -> Date {
        guard let rawValue else {
            return Date().addingTimeInterval(fallback)
        }
        guard let date = formatter.date(from: rawValue) else {
            throw MappingError.missingCriticalField(field: field)
        }
        return date
    }
}
