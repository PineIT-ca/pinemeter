//
//  NetworkHostValidator.swift
//  Pinemeter
//
//  DNS-rebinding protection for a network-bound broker.
//
//  `OriginValidator.localhost(port:)` is the right check while the listener is
//  pinned to 127.0.0.1, but it answers 421 to every LAN request the moment
//  the listener binds 0.0.0.0: a peer on the network reaches this Mac by IP
//  (`Host: 192.168.1.10:43117`) or by Bonjour name (`Host: mymac.local:43117`),
//  neither of which is in that validator's allow-list.
//
//  `OriginValidator.disabled` is not the answer either — dropping Host/Origin
//  validation is exactly what a DNS-rebinding attack needs. This validator
//  keeps the defence and widens it by shape instead of by name: the Host must
//  be `localhost`, an IP literal, or an `.local` mDNS name, on the bound port.
//  An attacker-controlled public DNS name resolving to this Mac's LAN address
//  can be none of those, so rebinding still fails.
//

import Foundation
import MCP
import Network

struct NetworkHostValidator: HTTPRequestValidator {
    /// The bound port. Every accepted Host/Origin must carry it (or no port
    /// at all, in the Host case, which cannot reach a non-default port).
    let port: Int

    init(port: Int) {
        self.port = port
    }

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        // Host is checked whenever present. Origin is checked only when
        // present, matching `OriginValidator`: non-browser MCP clients send
        // no Origin at all and must not be locked out.
        if let host = request.header("Host"), !isAllowedHostHeader(host) {
            return .error(
                statusCode: 421,
                .invalidRequest("Misdirected Request: Host header not allowed"),
                sessionID: context.sessionID
            )
        }

        if let origin = request.header("Origin"), !isAllowedOrigin(origin) {
            return .error(
                statusCode: 403,
                .invalidRequest("Forbidden: Origin not allowed"),
                sessionID: context.sessionID
            )
        }

        return nil
    }

    // MARK: - Host

    /// A `Host` header is allowed when its host part has an accepted shape
    /// and its port, if it carries one, is the bound port.
    func isAllowedHostHeader(_ value: String) -> Bool {
        guard let (host, port) = Self.splitHostPort(value) else { return false }
        if let port, port != self.port { return false }
        return Self.isAllowedHost(host)
    }

    // MARK: - Origin

    /// An `Origin` is allowed when it is an `http`/`https` URL whose host
    /// passes the same shape rules and whose port — explicit, or the scheme's
    /// default — is the bound port.
    func isAllowedOrigin(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // "null" and other opaque origins are not URLs and are never allowed.
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            return false
        }
        let effectivePort = components.port ?? (scheme == "https" ? 443 : 80)
        guard effectivePort == port else { return false }
        return Self.isAllowedHost(host)
    }

    // MARK: - Shape rules

    /// Splits an authority into its host and optional port, handling the
    /// bracketed IPv6 form (`[::1]:43117`). Returns `nil` for anything that
    /// isn't a well-formed authority.
    static func splitHostPort(_ value: String) -> (host: String, port: Int?)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[") {
            guard let closing = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            let remainder = trimmed[trimmed.index(after: closing)...]
            if remainder.isEmpty { return (host, nil) }
            guard remainder.hasPrefix(":"), let port = Int(remainder.dropFirst()) else { return nil }
            return (host, port)
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return (String(parts[0]), nil)
        case 2:
            guard let port = Int(parts[1]) else { return nil }
            return (String(parts[0]), port)
        default:
            // More than one colon and no brackets: an unbracketed IPv6
            // literal, which carries no port.
            return (trimmed, nil)
        }
    }

    /// The accepted host shapes: `localhost`, any IPv4 or IPv6 literal, or an
    /// mDNS `.local` name. Deliberately shape-based rather than a fixed list,
    /// because a LAN peer's view of this Mac's address is not knowable here.
    static func isAllowedHost(_ host: String) -> Bool {
        // A bracketed literal can still arrive here from a URL host.
        var candidate = host
        if candidate.hasPrefix("["), candidate.hasSuffix("]") {
            candidate = String(candidate.dropFirst().dropLast())
        }
        // Strip an IPv6 zone identifier (`fe80::1%en0`) before parsing.
        if let percent = candidate.firstIndex(of: "%") {
            candidate = String(candidate[candidate.startIndex..<percent])
        }
        guard !candidate.isEmpty else { return false }

        let lowered = candidate.lowercased()
        if lowered == "localhost" { return true }
        if IPv4Address(candidate) != nil { return true }
        if IPv6Address(candidate) != nil { return true }
        // `.local` is reserved for mDNS (RFC 6762) and is never resolvable
        // through the public DNS an attacker would have to control.
        if lowered.hasSuffix(".local"), lowered.count > ".local".count { return true }
        return false
    }
}
