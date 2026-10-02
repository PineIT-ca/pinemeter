//
//  ClaudeOAuthUsageServiceProtocol.swift
//  Pinemeter
//

import Foundation

/// The Claude organization a Claude Code login's OAuth profile belongs to.
/// Only the two fields `ClaudeCodeOrganizationResolver` and Settings need --
/// never the account email or any other profile field (D-08).
struct ClaudeOAuthProfileOrganization: Equatable, Sendable {
    let id: UUID
    let name: String?
}

/// Fetches Claude usage and organization identity using a Claude Code
/// login's own OAuth access token. Calls only `/api/oauth/usage` and
/// `/api/oauth/profile` -- never a token or refresh endpoint (D-06).
protocol ClaudeOAuthUsageServiceProtocol: Sendable {
    func fetchUsage(accessToken: CLIAccessToken) async throws -> UsageData
    func fetchProfileOrganization(accessToken: CLIAccessToken) async throws -> ClaudeOAuthProfileOrganization
}
