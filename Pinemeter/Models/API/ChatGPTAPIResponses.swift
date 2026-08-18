//
//  ChatGPTAPIResponses.swift
//  Pinemeter
//

import Foundation

/// Response from https://chatgpt.com/api/auth/session.
struct ChatGPTAuthSessionResponse: Decodable, Equatable, Sendable {
    let accessToken: String?
}

/// Response from https://chatgpt.com/backend-api/wham/usage.
struct ChatGPTWHAMUsageResponse: Decodable, Equatable, Sendable {
    let rateLimit: ChatGPTWHAMRateLimit?
    let codeReviewRateLimit: ChatGPTWHAMRateLimit?
    let additionalRateLimits: [ChatGPTWHAMAdditionalRateLimit]?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }
}

/// Additional per-feature meters. The endpoint originally emitted flat
/// entries ({name/type, primary_window}); mid-2026 it moved to
/// {limit_name, metered_feature, rate_limit: {primary_window}} (this is how
/// the Codex meter arrives now). Both shapes must map.
struct ChatGPTWHAMAdditionalRateLimit: Decodable, Equatable, Sendable {
    let name: String?
    let limitName: String?
    let meteredFeature: String?
    let type: String?
    let primaryWindow: ChatGPTWHAMWindow?
    let rateLimit: ChatGPTWHAMRateLimit?

    enum CodingKeys: String, CodingKey {
        case name
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case type
        case primaryWindow = "primary_window"
        case rateLimit = "rate_limit"
    }

    var resolvedLabel: String? {
        limitName ?? name ?? meteredFeature ?? type
    }

    var resolvedPrimaryWindow: ChatGPTWHAMWindow? {
        primaryWindow ?? rateLimit?.primaryWindow
    }
}

struct ChatGPTWHAMRateLimit: Decodable, Equatable, Sendable {
    let primaryWindow: ChatGPTWHAMWindow?
    let secondaryWindow: ChatGPTWHAMWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct ChatGPTWHAMWindow: Decodable, Equatable, Sendable {
    let usedPercent: Double?
    let resetAt: Date?
    var limitWindowSeconds: Double? = nil

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }

    /// Role implied by the window duration; nil when the server omits it.
    /// Anything from a day up reads as a weekly-style window.
    var durationRole: ChatGPTUsageData.MenuBarQuotaRole? {
        guard let limitWindowSeconds else { return nil }
        return limitWindowSeconds >= 86_400 ? .chatGPTWeekly : .chatGPT5h
    }
}

extension ChatGPTWHAMUsageResponse {
    func toDomain(lastUpdated: Date = Date()) throws -> ChatGPTUsageData {
        var rows: [ChatGPTUsageData.LimitRow] = []

        // Historically primary was the 5h window and secondary the weekly
        // one; newer responses drop the 5h window and serve weekly as
        // primary, so trust the window's own duration when it's present.
        let primaryRole = rateLimit?.primaryWindow?.durationRole ?? .chatGPT5h
        if let row = Self.row(
            from: rateLimit,
            sourceLabel: "rate_limit",
            displayLabel: primaryRole.menuBarLabel,
            subtitle: "Primary WHAM window",
            menuBarRole: primaryRole
        ) {
            rows.append(row)
        }

        let secondaryRole = rateLimit?.secondaryWindow?.durationRole ?? .chatGPTWeekly
        if let row = Self.row(
            from: rateLimit?.secondaryWindow,
            sourceLabel: "rate_limit.secondary_window",
            displayLabel: secondaryRole.menuBarLabel,
            subtitle: "Secondary WHAM window",
            menuBarRole: secondaryRole
        ) {
            rows.append(row)
        }

        if let row = Self.row(
            from: codeReviewRateLimit,
            sourceLabel: "code_review_rate_limit",
            displayLabel: "Code Review",
            subtitle: "WHAM code review window",
            menuBarRole: nil
        ) {
            rows.append(row)
        }

        for additionalLimit in additionalRateLimits ?? [] {
            let rawLabel = additionalLimit.resolvedLabel ?? "additional_rate_limit"
            let menuBarRole = Self.menuBarRole(for: rawLabel)
            if let row = Self.row(
                from: additionalLimit.resolvedPrimaryWindow,
                sourceLabel: rawLabel,
                displayLabel: menuBarRole?.menuBarLabel ?? Self.displayLabel(for: rawLabel),
                subtitle: menuBarRole == nil ? "WHAM: \(rawLabel)" : "WHAM additional limit",
                menuBarRole: menuBarRole
            ) {
                rows.append(row)
            }
        }

        guard !rows.isEmpty else {
            throw ChatGPTUsageError.invalidResponse
        }

        return ChatGPTUsageData(rows: rows, lastUpdated: lastUpdated)
    }

    private static func row(
        from rateLimit: ChatGPTWHAMRateLimit?,
        sourceLabel: String,
        displayLabel: String,
        subtitle: String?,
        menuBarRole: ChatGPTUsageData.MenuBarQuotaRole?
    ) -> ChatGPTUsageData.LimitRow? {
        row(
            from: rateLimit?.primaryWindow,
            sourceLabel: sourceLabel,
            displayLabel: displayLabel,
            subtitle: subtitle,
            menuBarRole: menuBarRole
        )
    }

    private static func row(
        from window: ChatGPTWHAMWindow?,
        sourceLabel: String,
        displayLabel: String,
        subtitle: String?,
        menuBarRole: ChatGPTUsageData.MenuBarQuotaRole?
    ) -> ChatGPTUsageData.LimitRow? {
        guard let window else { return nil }
        let usedPercent = min(100, max(0, window.usedPercent ?? 0))
        return ChatGPTUsageData.LimitRow(
            label: displayLabel,
            usedPercent: usedPercent,
            resetAt: window.resetAt,
            sourceLabel: sourceLabel,
            subtitle: subtitle,
            menuBarRole: menuBarRole
        )
    }

    private static func menuBarRole(for rawLabel: String) -> ChatGPTUsageData.MenuBarQuotaRole? {
        let normalized = rawLabel
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        // Model-specific labels win over period words so "Codex-Spark weekly"
        // style labels never collide with the main weekly window's role.
        if normalized.contains("spark") {
            return .chatGPTCodexSpark
        }

        if normalized.contains("weekly") || normalized.contains("week") {
            return .chatGPTWeekly
        }

        if normalized.contains("pro") {
            return .chatGPTPro
        }

        if normalized.contains("5h") || normalized.contains("5 h") || normalized.contains("5 hour") {
            return .chatGPT5h
        }

        return nil
    }

    private static func displayLabel(for rawLabel: String) -> String {
        rawLabel
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
