//
//  CodexCLILoginReader.swift
//  Pinemeter
//

import Foundation

/// Reads Codex CLI's own `auth.json` (`$CODEX_HOME/auth.json`, default
/// `~/.codex/auth.json`) to recover the access token Codex CLI itself is
/// currently using, so Pinemeter can poll `wham/usage` the same way Codex CLI
/// does (CLI-01, CLI-05). Pinemeter's app sandbox is off, so this is a plain
/// file read; see `BoundedLocalFileReader` for the safety checks applied to
/// it (T-19-01).
///
/// Only these fields are ever decoded: `auth_mode`, `tokens.access_token`,
/// `tokens.account_id`, and from the access token's own JWT payload (never
/// the id token): exp, chatgpt_user_id, chatgpt_account_id,
/// chatgpt_plan_type, and the profile email. The refresh token, the id
/// token, and the OPENAI_API_KEY value are never decoded into a property --
/// the decode structs below have no fields for them, so Decodable synthesis
/// simply ignores those JSON keys (D-06, D-08).
///
/// This reader never refreshes, writes, or deletes anything in `auth.json`
/// (D-02, D-07), and it never runs the `codex` executable.
enum CodexCLILoginReader {
    /// Real `auth.json` files are a few hundred bytes to a few KB; this cap
    /// exists because the path is derived from environment variables
    /// (`CODEX_HOME`/`HOME`) and a misconfigured or adversarial environment
    /// could point it at an arbitrarily large file (T-19-01).
    static let maxAuthFileBytes = 1_000_000

    /// At most 64 KB of JWT payload is decoded, independent of the file-size
    /// cap above, to bound the cost of a malformed or oversized token
    /// payload segment (T-19-06).
    private static let maxPayloadBytes = 64 * 1024

    static func read(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        expectedOwnerId: uid_t = getuid()
    ) -> CodexCLILogin? {
        guard let url = CodexCLIAuthFileLocation.authFileURL(environment: environment) else { return nil }
        guard let data = BoundedLocalFileReader.read(
            url,
            maxBytes: maxAuthFileBytes,
            expectedOwnerId: expectedOwnerId
        ) else { return nil }
        return decode(data, now: now)
    }

    static func decode(_ data: Data, now: Date) -> CodexCLILogin? {
        guard let file = try? JSONDecoder().decode(AuthPayload.self, from: data) else { return nil }
        guard file.authMode == "chatgpt" else { return nil }

        let accessTokenString = file.tokens?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountId = file.tokens?.accountId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accessTokenString, !accessTokenString.isEmpty,
              let accountId, !accountId.isEmpty else { return nil }

        guard let claims = decodeClaims(fromAccessToken: accessTokenString) else { return nil }
        guard let exp = claims.exp else { return nil }
        let expiresAt = Date(timeIntervalSince1970: exp)
        guard expiresAt > now.addingTimeInterval(CLILoginExpiry.skew) else { return nil }

        guard let chatgptUserId = claims.auth?.chatgptUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !chatgptUserId.isEmpty else { return nil }

        let chatgptAccountId = claims.auth?.chatgptAccountId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chatgptAccountId == accountId else { return nil }

        return CodexCLILogin(
            accessToken: CLIAccessToken(accessTokenString),
            accountId: accountId,
            chatgptUserId: chatgptUserId,
            planType: claims.auth?.chatgptPlanType,
            email: claims.profile?.email,
            expiresAt: expiresAt
        )
    }

    /// Decodes the JWT payload segment (second dot-separated segment) of the
    /// access token, bounded to `maxPayloadBytes`. The token itself is a
    /// parameter, never a stored property, and this function never logs it.
    private static func decodeClaims(fromAccessToken accessToken: String) -> AccessTokenClaims? {
        let segments = accessToken.split(separator: ".")
        guard segments.count == 3 else { return nil }

        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        guard let payloadData = Data(base64Encoded: base64), payloadData.count <= maxPayloadBytes else { return nil }
        return try? JSONDecoder().decode(AccessTokenClaims.self, from: payloadData)
    }

    /// Minimal decode target for `auth.json`. No field exists for
    /// `OPENAI_API_KEY`, `refresh_token`, or `id_token` -- Decodable
    /// synthesis ignores JSON keys with no matching property, so those
    /// values never reach memory through this type.
    struct AuthPayload: Decodable {
        struct Tokens: Decodable {
            let accessToken: String?
            let accountId: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
            }
        }

        let authMode: String?
        let tokens: Tokens?

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case tokens
        }
    }

    /// Minimal decode target for the access token's JWT payload. No field
    /// exists for any other claim.
    struct AccessTokenClaims: Decodable {
        struct AuthClaims: Decodable {
            let chatgptUserId: String?
            let chatgptAccountId: String?
            let chatgptPlanType: String?

            enum CodingKeys: String, CodingKey {
                case chatgptUserId = "chatgpt_user_id"
                case chatgptAccountId = "chatgpt_account_id"
                case chatgptPlanType = "chatgpt_plan_type"
            }
        }

        struct ProfileClaims: Decodable {
            let email: String?
        }

        let exp: Double?
        let auth: AuthClaims?
        let profile: ProfileClaims?

        enum CodingKeys: String, CodingKey {
            case exp
            case auth = "https://api.openai.com/auth"
            case profile = "https://api.openai.com/profile"
        }
    }
}
