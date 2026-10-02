//
//  CodexCLIWorkspaceResolver.swift
//  Pinemeter
//

import Foundation

/// Discovers which ChatGPT workspace a locally installed Codex CLI is bound
/// to, by reading Codex CLI's own auth file. Pinemeter's app sandbox is off
/// (see the app's entitlements), so this is a plain file read.
///
/// Root cause for pinemeter-private#126/#127: Codex CLI and Pinemeter's
/// `wham/usage` request can share the same ChatGPT login but land on
/// different *workspaces* -- a personal plan plus one or more business orgs,
/// each metering Codex independently. A `wham/usage` request with no
/// `chatgpt-account-id` header queries whichever workspace the server treats
/// as ambient/default for the cookie, which is not necessarily the one Codex
/// CLI uses. Codex CLI's own `auth.json` records which workspace it is
/// bound to (`tokens.account_id`), so reading that file directly resolves
/// the ambiguity deterministically instead of guessing.
///
/// Only two pieces of information are ever decoded out of `auth.json`:
/// `tokens.account_id`, and (transiently, to verify which connected ChatGPT
/// account this applies to) the `chatgpt_user_id` claim inside
/// `tokens.id_token`'s JWT payload. `OPENAI_API_KEY`, `access_token`, and
/// `refresh_token` are never decoded, read into a property, logged, or
/// persisted -- the decode struct has no fields for them, so `Decodable`
/// synthesis simply ignores them. `id_token` itself is decoded only long
/// enough to extract the one claim; it is never retained, logged, or stored
/// beyond the scope of `resolve`.
enum CodexCLIWorkspaceResolver {
    struct Workspace: Equatable, Sendable {
        /// The ChatGPT workspace id Codex CLI is bound to
        /// (`tokens.account_id`). Sent as the `chatgpt-account-id` header.
        let accountId: String
        /// The `chatgpt_user_id` claim from `tokens.id_token`, when it could
        /// be decoded. Used only to verify which connected ChatGPT account
        /// (by its own known user id) this workspace belongs to -- never
        /// sent anywhere, never persisted.
        let chatgptUserId: String?
    }

    /// Reads `$CODEX_HOME/auth.json`, falling back to `~/.codex/auth.json`
    /// (Codex CLI's own default), and resolves the workspace it names.
    /// Returns nil on any failure (missing file, not a regular file, over
    /// `maxAuthFileBytes`, malformed JSON, absent or blank `account_id`) --
    /// callers must treat that exactly like "Codex CLI is not installed or
    /// not logged in," never as an error.
    ///
    /// The size and regular-file checks exist because this path is derived
    /// from environment variables (`CODEX_HOME`/`HOME`), not a fixed
    /// location: without them, a misconfigured or adversarial environment
    /// could point `CODEX_HOME` at an arbitrarily large file, a device node,
    /// or a named pipe, and `Data(contentsOf:)` would attempt to read all of
    /// it. Real `auth.json` files are a few hundred bytes.
    static let maxAuthFileBytes = 1_000_000

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Workspace? {
        guard let url = authFileURL(environment: environment)?.resolvingSymlinksInPath() else { return nil }

        guard let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              resourceValues.isRegularFile == true,
              let fileSize = resourceValues.fileSize,
              fileSize <= maxAuthFileBytes else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return resolve(data: data)
    }

    static func resolve(data: Data) -> Workspace? {
        guard let file = try? JSONDecoder().decode(AuthFile.self, from: data) else { return nil }
        let accountId = file.tokens?.accountId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accountId, !accountId.isEmpty else { return nil }
        let chatgptUserId = file.tokens?.idToken.flatMap(chatgptUserIdClaim(fromIdToken:))
        return Workspace(accountId: accountId, chatgptUserId: chatgptUserId)
    }

    private static func authFileURL(environment: [String: String]) -> URL? {
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        }
        let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let home, !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home).appendingPathComponent(".codex").appendingPathComponent("auth.json")
    }

    /// Decodes only the `https://api.openai.com/auth.chatgpt_user_id` claim
    /// out of a JWT's payload (second dot-separated segment). The token
    /// itself is a parameter, never a stored property, and this function
    /// never logs it.
    private static func chatgptUserIdClaim(fromIdToken idToken: String) -> String? {
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        guard let payloadData = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let chatgptUserId = auth["chatgpt_user_id"] as? String,
              !chatgptUserId.isEmpty else {
            return nil
        }
        return chatgptUserId
    }

    /// Minimal decode target for `auth.json`. Deliberately has no fields for
    /// `OPENAI_API_KEY`, `access_token`, or `refresh_token`: `Decodable`
    /// synthesis ignores JSON keys with no matching property, so those
    /// values never reach memory through this type.
    struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let accountId: String?
            let idToken: String?

            enum CodingKeys: String, CodingKey {
                case accountId = "account_id"
                case idToken = "id_token"
            }
        }

        let tokens: Tokens?
    }
}
