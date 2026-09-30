//
//  BrokerAccessPolicyTests.swift
//  PinemeterTests
//
//  The broker's authorization rules and the network-mode Host/Origin
//  validator. Both are pure values, so every case here is a direct call —
//  no socket, no server.
//

import MCP
import XCTest
@testable import Pinemeter

final class BrokerAccessPolicyTests: XCTestCase {
    private let key = "pm_testkey_0123456789"

    private func policy(
        _ mode: BrokerAPIKeyMode,
        key: String?,
        access: BrokerNetworkAccess = .network
    ) -> BrokerAccessPolicy {
        BrokerAccessPolicy(networkAccess: access, apiKeyMode: mode, apiKey: key)
    }

    // MARK: - The default is today's behaviour

    func test_loopbackDefault_authorizesEverythingWithNoKey() {
        let policy = BrokerAccessPolicy.loopbackDefault

        XCTAssertEqual(policy.networkAccess, .loopback)
        XCTAssertEqual(policy.apiKeyMode, .none)
        XCTAssertNil(policy.apiKey)
        XCTAssertTrue(policy.authorizes(headers: [:], isLoopbackPeer: true))
        XCTAssertTrue(policy.authorizes(headers: [:], isLoopbackPeer: false))
    }

    // MARK: - The full matrix

    func test_authorizeMatrix_acrossModesPeersAndPresentedKeys() {
        let right = ["Authorization": "Bearer \(key)"]
        let wrong = ["Authorization": "Bearer pm_not_the_key"]
        let absent: [String: String] = [:]

        // .none never asks, whoever is calling.
        for isLoopback in [true, false] {
            for headers in [absent, wrong, right] {
                XCTAssertTrue(
                    policy(.none, key: key).authorizes(headers: headers, isLoopbackPeer: isLoopback),
                    "mode .none must never demand a key (loopback: \(isLoopback))"
                )
            }
        }

        // .nonLoopback: local callers walk in, remote callers must present it.
        let nonLoopback = policy(.nonLoopback, key: key)
        XCTAssertTrue(nonLoopback.authorizes(headers: absent, isLoopbackPeer: true))
        XCTAssertTrue(nonLoopback.authorizes(headers: wrong, isLoopbackPeer: true))
        XCTAssertFalse(nonLoopback.authorizes(headers: absent, isLoopbackPeer: false))
        XCTAssertFalse(nonLoopback.authorizes(headers: wrong, isLoopbackPeer: false))
        XCTAssertTrue(nonLoopback.authorizes(headers: right, isLoopbackPeer: false))

        // .all: everyone presents it, including this Mac.
        let all = policy(.all, key: key)
        XCTAssertFalse(all.authorizes(headers: absent, isLoopbackPeer: true))
        XCTAssertFalse(all.authorizes(headers: wrong, isLoopbackPeer: true))
        XCTAssertTrue(all.authorizes(headers: right, isLoopbackPeer: true))
        XCTAssertFalse(all.authorizes(headers: absent, isLoopbackPeer: false))
        XCTAssertTrue(all.authorizes(headers: right, isLoopbackPeer: false))
    }

    func test_authorize_withNoProvisionedKey_failsClosed() {
        // Half-configured — a mode that demands a key with no key stored —
        // must reject rather than serve the request unauthenticated.
        for stored in [nil, ""] as [String?] {
            let all = policy(.all, key: stored)
            XCTAssertFalse(all.authorizes(headers: ["Authorization": "Bearer anything"], isLoopbackPeer: true))
            XCTAssertFalse(all.authorizes(headers: [:], isLoopbackPeer: true))

            let nonLoopback = policy(.nonLoopback, key: stored)
            XCTAssertFalse(nonLoopback.authorizes(headers: [:], isLoopbackPeer: false))
            XCTAssertTrue(
                nonLoopback.authorizes(headers: [:], isLoopbackPeer: true),
                "a missing key must not lock out the local callers the mode never asked to authenticate"
            )
        }
    }

    // MARK: - How the key is presented

    func test_authorize_acceptsBearerRegardlessOfCase() {
        let all = policy(.all, key: key)

        for headerName in ["Authorization", "authorization", "AUTHORIZATION"] {
            for scheme in ["Bearer", "bearer", "BEARER", "BeArEr"] {
                XCTAssertTrue(
                    all.authorizes(headers: [headerName: "\(scheme) \(key)"], isLoopbackPeer: false),
                    "\(headerName): \(scheme) must be accepted (RFC 9110 is case-insensitive)"
                )
            }
        }
    }

    func test_authorize_acceptsXAPIKeyHeader() {
        let all = policy(.all, key: key)

        XCTAssertTrue(all.authorizes(headers: ["X-API-Key": key], isLoopbackPeer: false))
        XCTAssertTrue(all.authorizes(headers: ["x-api-key": key], isLoopbackPeer: false))
        XCTAssertTrue(all.authorizes(headers: ["X-API-Key": "  \(key)  "], isLoopbackPeer: false))
        XCTAssertFalse(all.authorizes(headers: ["X-API-Key": "pm_wrong"], isLoopbackPeer: false))
    }

    func test_authorize_rejectsBearerWithNoToken() {
        let all = policy(.all, key: key)

        XCTAssertFalse(all.authorizes(headers: ["Authorization": "Bearer"], isLoopbackPeer: false))
        XCTAssertFalse(all.authorizes(headers: ["Authorization": "Bearer "], isLoopbackPeer: false))
        XCTAssertFalse(all.authorizes(headers: ["Authorization": "Basic \(key)"], isLoopbackPeer: false))
    }

    func test_authorize_rejectsAPrefixOfTheKey() {
        let all = policy(.all, key: key)

        XCTAssertFalse(
            all.authorizes(headers: ["Authorization": "Bearer \(key.dropLast())"], isLoopbackPeer: false)
        )
        XCTAssertFalse(
            all.authorizes(headers: ["Authorization": "Bearer \(key)x"], isLoopbackPeer: false)
        )
    }

    func test_constantTimeEquals_matchesOnlyIdenticalStrings() {
        XCTAssertTrue(BrokerAccessPolicy.constantTimeEquals(key, key))
        XCTAssertTrue(BrokerAccessPolicy.constantTimeEquals("", ""))
        XCTAssertFalse(BrokerAccessPolicy.constantTimeEquals("", key))
        XCTAssertFalse(BrokerAccessPolicy.constantTimeEquals(key, ""))
        XCTAssertFalse(BrokerAccessPolicy.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(BrokerAccessPolicy.constantTimeEquals("abc", "abcabc"))
    }

    // MARK: - Key generation

    func test_generateAPIKey_isPrefixedURLSafeAndUnique() {
        let first = BrokerAccessPolicy.generateAPIKey()
        let second = BrokerAccessPolicy.generateAPIKey()

        XCTAssertTrue(first.hasPrefix("pm_"), "got \(first)")
        // 32 bytes base64url without padding is 43 characters.
        XCTAssertEqual(first.count, 3 + 43)
        XCTAssertNotEqual(first, second, "two calls must not produce the same key")

        let body = first.dropFirst(3)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(
            body.unicodeScalars.allSatisfy(allowed.contains),
            "the key must be URL- and header-safe, got \(body)"
        )
    }
}

// MARK: - Network-mode Host/Origin validation

final class NetworkHostValidatorTests: XCTestCase {
    private let port = 43117
    private var validator: NetworkHostValidator { NetworkHostValidator(port: port) }

    private func validate(host: String? = nil, origin: String? = nil) -> HTTPResponse? {
        var headers: [String: String] = [:]
        if let host { headers["Host"] = host }
        if let origin { headers["Origin"] = origin }
        return validator.validate(
            HTTPRequest(method: "POST", headers: headers, body: nil, path: "/mcp"),
            context: HTTPValidationContext(httpMethod: "POST")
        )
    }

    // MARK: - Host

    func test_allowsLANIPLocalhostAndBonjourHosts() {
        for host in [
            "192.168.1.10:43117",
            "10.0.0.4:43117",
            "[::1]:43117",
            "[fe80::1]:43117",
            "localhost:43117",
            "LocalHost:43117",
            "mymac.local:43117",
            "MyMac.LOCAL:43117",
        ] {
            XCTAssertNil(validate(host: host), "\(host) must be allowed")
        }
    }

    func test_allowsAnAbsentHostHeader() {
        // Matches OriginValidator: a client that sends no Host is not
        // rebinding anything, and HTTP/1.0 callers exist.
        XCTAssertNil(validate())
    }

    func test_rejectsAPublicDNSNameWith421() {
        // The DNS-rebinding case: a name an attacker controls, pointed at
        // this Mac's LAN address.
        let response = validate(host: "evil.example.com:43117")
        XCTAssertEqual(response?.statusCode, 421)
    }

    func test_rejectsAllowedHostOnTheWrongPortWith421() {
        XCTAssertEqual(validate(host: "192.168.1.10:1234")?.statusCode, 421)
        XCTAssertEqual(validate(host: "localhost:1234")?.statusCode, 421)
        XCTAssertEqual(validate(host: "[::1]:1234")?.statusCode, 421)
    }

    func test_rejectsANameThatMerelyContainsLocal() {
        XCTAssertEqual(validate(host: "local:43117")?.statusCode, 421)
        XCTAssertEqual(validate(host: "notlocal.example.com:43117")?.statusCode, 421)
        XCTAssertEqual(validate(host: ".local:43117")?.statusCode, 421)
    }

    // MARK: - Origin

    func test_allowsALANOrigin() {
        XCTAssertNil(validate(origin: "http://192.168.1.10:43117"))
        XCTAssertNil(validate(origin: "http://localhost:43117"))
        XCTAssertNil(validate(origin: "http://[::1]:43117"))
        XCTAssertNil(validate(origin: "https://mymac.local:43117"))
    }

    func test_rejectsAPublicOriginWith403() {
        XCTAssertEqual(validate(origin: "http://evil.example.com:43117")?.statusCode, 403)
    }

    func test_rejectsAnOriginOnTheWrongPortOrScheme() {
        XCTAssertEqual(validate(origin: "http://192.168.1.10:9999")?.statusCode, 403)
        XCTAssertEqual(validate(origin: "http://192.168.1.10")?.statusCode, 403)
        XCTAssertEqual(validate(origin: "file://192.168.1.10:43117")?.statusCode, 403)
        XCTAssertEqual(validate(origin: "null")?.statusCode, 403)
    }

    func test_hostRejectionPrecedesOriginRejection() {
        // Both wrong: the Host answer is the one that comes back, matching
        // OriginValidator's ordering.
        XCTAssertEqual(
            validate(host: "evil.example.com:43117", origin: "http://evil.example.com:43117")?.statusCode,
            421
        )
    }
}
