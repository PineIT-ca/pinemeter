import Darwin
import Foundation
import XCTest
@testable import Pinemeter

final class RemotePushSSHIntegrationTests: XCTestCase {
    func testRealSSHImportsAllAccountsAndHotReloadsNextPickOnSameDaemon() async throws {
        let fixture = try integrationFixture()
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.transportConfiguration)
        let template = try fixtureData("all-accounts")

        let first = try makeBundle(template, generation: 41, candidate: "native/model-old")
        let firstAck = try await transport.importBundle(first, host: fixture.host, secret: fixture.secret)
        XCTAssertEqual(firstAck.acceptedGeneration, 41)
        let firstPick = try await fixture.pick()
        XCTAssertEqual(firstPick["model"] as? String, "native/model-old")

        let status = try await transport.fetchStatus(host: fixture.host, secret: fixture.secret)
        XCTAssertEqual(status.acceptedGeneration, 41)
        XCTAssertEqual(status.accounts.count, 6)
        XCTAssertTrue(status.accounts.allSatisfy { $0.verdict == .unpolled })

        let second = try makeBundle(template, generation: 42, candidate: "native/model-new")
        async let secondImport = transport.importBundle(second, host: fixture.host, secret: fixture.secret)
        let models = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let pick = try await fixture.pick()
                    return pick["model"] as! String
                }
            }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        _ = try await secondImport
        XCTAssertTrue(models.allSatisfy { $0 == "native/model-old" || $0 == "native/model-new" })
        let adoptedPick = try await fixture.pick()
        XCTAssertEqual(adoptedPick["model"] as? String, "native/model-new")
        XCTAssertEqual(kill(fixture.daemonPID, 0), 0)

        let daemonStatus = try await fixture.callTool("status") as! [String: Any]
        let host = daemonStatus["host"] as! [String: Any]
        let providers = host["providers"] as! [String: Any]
        let oracle = daemonStatus["oracle"] as! [String: Any]
        XCTAssertEqual((providers["acceptedGeneration"] as? NSNumber)?.uint64Value, 42)
        XCTAssertEqual(providers["pushedTimeZone"] as? String, "America/Vancouver")
        XCTAssertEqual(oracle["present"] as? Bool, false)

        let empty = try makeBundle(
            fixtureData("empty-accounts"),
            generation: 43,
            candidate: "native/model-empty"
        )
        _ = try await transport.importBundle(empty, host: fixture.host, secret: fixture.secret)
        let emptyStatus = try await transport.fetchStatus(host: fixture.host, secret: fixture.secret)
        XCTAssertEqual(emptyStatus.acceptedGeneration, 43)
        XCTAssertTrue(emptyStatus.accounts.isEmpty)
        let emptyPick = try await fixture.pick()
        XCTAssertEqual(emptyPick["model"] as? String, "native/model-empty")
    }

    func testRealSSHRejectsPinKeyInjectionReplayVersionSizeAndPartialInput() async throws {
        let fixture = try integrationFixture()
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.transportConfiguration)
        let template = try fixtureData("all-accounts")
        let accepted = try makeBundle(template, generation: 50, candidate: "native/model-safe")
        _ = try await transport.importBundle(accepted, host: fixture.host, secret: fixture.secret)

        await assertTransportError(.hostKeyMismatch) {
            let wrongPin = RemoteHostSecret(
                identity: fixture.secret.identity,
                pinnedHostKey: self.syntheticHostKey(byte: 9)
            )
            _ = try await transport.fetchStatus(host: fixture.host, secret: wrongPin)
        }
        await assertTransportError(.transportFailed) {
            let wrongClient = RemoteHostSecret(
                identity: Data("not-a-private-key".utf8),
                pinnedHostKey: fixture.secret.pinnedHostKey
            )
            _ = try await transport.fetchStatus(host: fixture.host, secret: wrongClient)
        }

        var hostileHost = fixture.host
        hostileHost.host = "-oProxyCommand=never"
        await assertTransportError(.invalidConfiguration) {
            _ = try await transport.fetchStatus(host: hostileHost, secret: fixture.secret)
        }
        var hostileUser = fixture.host
        hostileUser.sshUser = "-bad"
        await assertTransportError(.invalidConfiguration) {
            _ = try await transport.fetchStatus(host: hostileUser, secret: fixture.secret)
        }

        await assertTransportError(.transportFailed) {
            _ = try await transport.importBundle(accepted, host: fixture.host, secret: fixture.secret)
        }
        let newMajor = try mutate(accepted) { $0["schemaVersion"] = ["major": 2, "minor": 0] }
        await assertTransportError(.transportFailed) {
            _ = try await transport.importBundle(newMajor, host: fixture.host, secret: fixture.secret)
        }
        await assertTransportError(.invalidBundle) {
            _ = try await transport.importBundle(Data(accepted.prefix(accepted.count / 2)), host: fixture.host, secret: fixture.secret)
        }
        await assertTransportError(.bundleTooLarge) {
            _ = try await transport.importBundle(
                Data(repeating: 1, count: 4 * 1_024 * 1_024 + 1),
                host: fixture.host,
                secret: fixture.secret
            )
        }

        let status = try await transport.fetchStatus(host: fixture.host, secret: fixture.secret)
        XCTAssertEqual(status.acceptedGeneration, 50)
        let safePick = try await fixture.pick()
        XCTAssertEqual(safePick["model"] as? String, "native/model-safe")

        try fixture.armFault("import-before")
        let before = try makeBundle(template, generation: 51, candidate: "native/model-before")
        await assertTransportError(.transportFailed) {
            _ = try await transport.importBundle(before, host: fixture.host, secret: fixture.secret)
        }
        let statusAfterKilledBefore = try await transport.fetchStatus(host: fixture.host, secret: fixture.secret)
        XCTAssertEqual(statusAfterKilledBefore.acceptedGeneration, 50)

        try fixture.armFault("import-after")
        let after = try makeBundle(template, generation: 52, candidate: "native/model-after")
        await assertTransportError(.transportFailed) {
            _ = try await transport.importBundle(after, host: fixture.host, secret: fixture.secret)
        }
        let statusAfterKilledAfter = try await transport.fetchStatus(host: fixture.host, secret: fixture.secret)
        XCTAssertEqual(statusAfterKilledAfter.acceptedGeneration, 52)

        for fault in ["malicious-stdout", "malicious-stderr"] {
            try fixture.armFault(fault)
            await assertTransportError(fault == "malicious-stdout" ? .invalidResponse : .transportFailed) {
                _ = try await transport.fetchStatus(host: fixture.host, secret: fixture.secret)
            }
        }
    }

    func testPushedTimezoneAndCooldownSourcesStayIndependent() async throws {
        let fixture = try integrationFixture()
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.transportConfiguration)
        let template = try fixtureData("empty-accounts")
        let pushedUntil = Date().addingTimeInterval(2 * 60 * 60)
        let first = try makeBundle(
            template,
            generation: 70,
            candidate: "native/model-cooldown",
            cooldowns: ["native": ISO8601DateFormatter().string(from: pushedUntil)]
        )
        _ = try await transport.importBundle(first, host: fixture.host, secret: fixture.secret)
        _ = try await fixture.callTool("down", arguments: ["target": "native", "minutes": 180])

        let hostExpiry = try await cooldown("native", in: fixture)
        XCTAssertGreaterThan(hostExpiry.timeIntervalSince(pushedUntil), 30 * 60)

        let clearedOnMac = try makeBundle(template, generation: 71, candidate: "native/model-cooldown")
        _ = try await transport.importBundle(clearedOnMac, host: fixture.host, secret: fixture.secret)
        let expiryAfterMacClear = try await cooldown("native", in: fixture)
        XCTAssertEqual(expiryAfterMacClear, hostExpiry)

        _ = try await fixture.callTool("up", arguments: ["target": "native"])
        let status = try await fixture.callTool("status") as! [String: Any]
        XCTAssertTrue((status["cooldowns"] as? [Any])?.isEmpty == true)
    }

    func testAutomaticAndManualCoordinatorPathsUseProductionSSHTransport() async throws {
        let fixture = try integrationFixture()
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.transportConfiguration)
        let template = try fixtureData("removed-account")
        let generations = IntegrationGenerations(startingAt: 59)
        let recorder = IntegrationRecorder()
        let inventory = RemotePushAccountInventory(
            claude: [.init(id: "claude-primary", label: "Claude", isPrimary: true, keychainAccount: "fixture")],
            chatGPT: [.init(id: "chatgpt-primary", label: "ChatGPT", isPrimary: true, keychainAccount: "fixture")],
            gemini: [.init(id: "gemini-primary", label: "Gemini", isPrimary: true, keychainAccount: "fixture")]
        )
        let source = RemotePushSourceSnapshot(
            hosts: [fixture.host],
            inventory: inventory,
            policy: .default,
            cooldowns: [:],
            oracleSnapshot: nil
        )
        let coordinator = RemotePushCoordinator(
            loadSource: { source },
            reserveGeneration: { await generations.next() },
            buildBundle: { generation, _, _ in
                try Self.makeBundle(template, generation: generation, candidate: "native/model-\(generation)")
            },
            send: { bundle, host in
                _ = try await transport.importBundle(bundle, host: host, secret: fixture.secret)
            },
            fetchStatus: { host in
                try await transport.fetchStatus(host: host, secret: fixture.secret)
            },
            recordUpdate: { update in await recorder.record(update) },
            sleep: { _ in }
        )

        await coordinator.scheduleAutomaticPush()
        try await eventually { await recorder.finishedCount == 1 }
        await coordinator.manualPush(hostID: fixture.host.id)
        try await eventually { await recorder.finishedCount == 2 }

        let results = await recorder.finishedResults
        XCTAssertEqual(results, [.succeeded, .succeeded])
        let finalPick = try await fixture.pick()
        let finalStatus = try await transport.fetchStatus(host: fixture.host, secret: fixture.secret)
        XCTAssertEqual(finalPick["model"] as? String, "native/model-61")
        XCTAssertEqual(finalStatus.acceptedGeneration, 61)
    }

    private func integrationFixture() throws -> SSHFixture.Integration {
        guard let path = ProcessInfo.processInfo.environment["PINEMETER_SSH_INTEGRATION_DAEMON"] else {
            throw XCTSkip("BLOCKED: PINEMETER_SSH_INTEGRATION_DAEMON is not set; use scripts/test-mac-ssh-push.sh --integration")
        }
        do {
            return try SSHFixture.makeIntegration(daemon: URL(fileURLWithPath: path))
        } catch let error as SSHFixture.IntegrationError {
            if case .blocked = error { throw XCTSkip(error.localizedDescription) }
            throw error
        }
    }

    private func fixtureData(_ name: String) throws -> Data {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: repository
            .appendingPathComponent("pinemeterd/internal/importbundle/testdata")
            .appendingPathComponent("\(name).json"))
    }

    private static func makeBundle(
        _ template: Data,
        generation: UInt64,
        candidate: String,
        cooldowns: [String: String] = [:]
    ) throws -> Data {
        try mutate(template) { document in
            document["generation"] = generation
            document["pushedAt"] = ISO8601DateFormatter().string(from: Date())
            document["cooldowns"] = cooldowns
            document.removeValue(forKey: "oracleSnapshot")
            var policy = document["policy"] as! [String: Any]
            policy["roles"] = ["execution": [candidate]]
            policy["callers"] = [
                "codex": ["routes": ["native"], "deny_candidates": [], "deny_instances": []],
            ]
            policy["t3_instances"] = []
            policy["t3"] = ["default_instance": "", "ignored_instances": [], "instance_by_model": [:]]
            document["policy"] = policy
        }
    }

    private func makeBundle(
        _ template: Data,
        generation: UInt64,
        candidate: String,
        cooldowns: [String: String] = [:]
    ) throws -> Data {
        try Self.makeBundle(template, generation: generation, candidate: candidate, cooldowns: cooldowns)
    }

    private func cooldown(_ key: String, in fixture: SSHFixture.Integration) async throws -> Date {
        let status = try await fixture.callTool("status") as! [String: Any]
        let entries = status["cooldowns"] as! [[String: Any]]
        let value = try XCTUnwrap(entries.first { $0["key"] as? String == key }?["availableAt"] as? String)
        return try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private static func mutate(
        _ data: Data,
        change: (inout [String: Any]) -> Void
    ) throws -> Data {
        var document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        change(&document)
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    private func mutate(
        _ data: Data,
        change: (inout [String: Any]) -> Void
    ) throws -> Data {
        try Self.mutate(data, change: change)
    }

    private func syntheticHostKey(byte: UInt8) -> String {
        func sshString(_ data: Data) -> Data {
            var length = UInt32(data.count).bigEndian
            return withUnsafeBytes(of: &length) { Data($0) } + data
        }
        let blob = sshString(Data("ssh-ed25519".utf8)) + sshString(Data(repeating: byte, count: 32))
        return "ssh-ed25519 \(blob.base64EncodedString())"
    }

    private func assertTransportError(
        _ expected: RemoteSSHTransportError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RemoteSSHTransportError, expected, file: file, line: line)
        }
    }

    private func eventually(
        _ condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met", file: file, line: line)
    }
}

private actor IntegrationGenerations {
    private var value: UInt64
    init(startingAt value: UInt64) { self.value = value }
    func next() -> UInt64 { value += 1; return value }
}

private actor IntegrationRecorder {
    private(set) var finishedResults: [RemotePushResult] = []
    var finishedCount: Int { finishedResults.count }

    func record(_ update: RemotePushAttemptUpdate) {
        guard case .finished(_, _, let result, _) = update else { return }
        finishedResults.append(result)
    }
}
