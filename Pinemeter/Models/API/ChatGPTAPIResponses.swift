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

struct ChatGPTWHAMAdditionalRateLimit: Decodable, Equatable, Sendable {
    let name: String?
    let type: String?
    let primaryWindow: ChatGPTWHAMWindow?

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case primaryWindow = "primary_window"
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

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
    }
}

extension ChatGPTWHAMUsageResponse {
    func toDomain(lastUpdated: Date = Date()) throws -> ChatGPTUsageData {
        var rows: [ChatGPTUsageData.LimitRow] = []

        if let row = Self.row(
            from: rateLimit,
            sourceLabel: "rate_limit",
            displayLabel: "ChatGPT 5h",
            subtitle: "Primary WHAM window",
            menuBarRole: .chatGPT5h
        ) {
            rows.append(row)
        }

        if let row = Self.row(
            from: rateLimit?.secondaryWindow,
            sourceLabel: "rate_limit.secondary_window",
            displayLabel: ChatGPTUsageData.MenuBarQuotaRole.chatGPTWeekly.menuBarLabel,
            subtitle: "Secondary WHAM window",
            menuBarRole: .chatGPTWeekly
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
            let rawLabel = additionalLimit.name ?? additionalLimit.type ?? "additional_rate_limit"
            let menuBarRole = Self.menuBarRole(for: rawLabel)
            if let row = Self.row(
                from: additionalLimit.primaryWindow,
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
