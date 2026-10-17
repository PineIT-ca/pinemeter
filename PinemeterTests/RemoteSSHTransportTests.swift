import Foundation
import Security
import XCTest
@testable import Pinemeter

final class RemoteSSHTransportTests: XCTestCase {
    func testCapabilitiesUsesPinnedCommandNoInputAndClosedJSON() async throws {
        for (supported, expected) in [(true, HostCapabilities.supported), (false, .unsupported)] {
            let response = "{\"residency\":{\"supported\":\(supported)},\"schemaVersion\":1}"
            let fixture = try SSHProcessFixture(response: response)
            defer { fixture.cleanup() }
            let capabilities = try await RemoteSSHTransport(testing: fixture.configuration())
                .fetchCapabilities(host: host(), secret: secret())
            XCTAssertEqual(capabilities, expected)
            try assertSharedPinnedArguments(fixture.capturedArguments(), command: "pinemeterd status --capabilities")
            XCTAssertEqual(try fixture.inputByteCount(), 0)
            XCTAssertTrue(fixture.operationDirectories().isEmpty)
        }
    }

    func testCapabilitiesRejectsUnknownMissingAndWrongTypedKeys() async throws {
        for response in [
            #"{"residency":{"supported":true},"schemaVersion":1,"extra":true}"#,
            #"{"residency":{"supported":true,"extra":true},"schemaVersion":1}"#,
            #"{"residency":{"supported":true},"schemaVersion":2}"#,
            #"{"residency":{"supported":1},"schemaVersion":1}"#,
            #"{"residency":{"supported":"true"},"schemaVersion":1}"#,
            #"{"residency":{},"schemaVersion":1}"#,
            #"{"residency":{"supported":true}}"#,
            #"{"residency":null,"schemaVersion":1}"#,
        ] {
            let fixture = try SSHProcessFixture(response: response)
            defer { fixture.cleanup() }
            await assertTransportError(.invalidResponse) {
                _ = try await RemoteSSHTransport(testing: fixture.configuration())
                    .fetchCapabilities(host: self.host(), secret: self.secret())
            }
        }
    }

    func testCapabilitiesOnlyExactFailedRefusalMapsToUnsupported() async throws {
        let refusalURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ssh-command-refusal.txt")
        let refusal = try String(contentsOf: refusalURL, encoding: .utf8)
        let accepted = try SSHProcessFixture(body: """
        printf 'attempt\\n' >> "$(dirname "$0")/attempts"
        printf '%s' '\(refusal)' >&2
        exit 126
        """)
        defer { accepted.cleanup() }
        let capabilities = try await RemoteSSHTransport(testing: accepted.configuration())
            .fetchCapabilities(host: host(), secret: secret())
        XCTAssertEqual(capabilities, .unsupported)
        XCTAssertEqual(try String(contentsOf: accepted.root.appendingPathComponent("attempts"), encoding: .utf8), "attempt\n")
        XCTAssertTrue(accepted.operationDirectories().isEmpty)
        for body in [
            "exit 126",
            "printf 'command not permitted\\n' >&2; exit 126",
            "printf 'pinemeterd: command not permitted' >&2; exit 126",
            "printf 'pinemeterd: command not permitted\\nextra' >&2; exit 126",
            "printf 'pinemeterd: command not permitted\\n' >&2; printf 'extra'; exit 126",
            "printf 'pinemeterd: command not permitted\\n'; exit 126",
            "printf 'pinemeterd: command not permitted\\n' >&2; exit 1",
        ] {
            let fixture = try SSHProcessFixture(body: body)
            defer { fixture.cleanup() }
            await assertTransportError(.transportFailed) {
                _ = try await RemoteSSHTransport(testing: fixture.configuration())
                    .fetchCapabilities(host: self.host(), secret: self.secret())
            }
        }
        let fixture = try SSHProcessFixture(response: "pinemeterd: command not permitted")
        defer { fixture.cleanup() }
        await assertTransportError(.invalidResponse) {
            _ = try await RemoteSSHTransport(testing: fixture.configuration())
                .fetchCapabilities(host: self.host(), secret: self.secret())
        }
    }

    func testPushArgumentsUseSharedPinnedOptions() async throws {
        let fixture = try SSHProcessFixture(response: #"{"schemaVersion":1,"acceptedGeneration":7}"#)
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.configuration())

        _ = try await transport.importBundle(bundle(generation: 7), host: host(), secret: secret())

        try assertSharedPinnedArguments(fixture.capturedArguments(), command: "pinemeterd import --stdin")
    }

    func testSourcesUsesSamePinnedArgumentsAsPush() async throws {
        let fixture = try SSHProcessFixture(response: #"{"schemaVersion":2,"acceptedGeneration":7,"accounts":[]}"#)
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.configuration())

        _ = try await transport.fetchSources(host: host(), secret: secret())

        try assertSharedPinnedArguments(fixture.capturedArguments(), command: "pinemeterd status --sources")
    }

    func testFetchSourcesSendsNoInputUsesExactCommandAndDecodes() async throws {
        var claude = sourcesAccount()
        claude["observedAt"] = "2026-10-30T12:00:00Z"
        claude["login"] = [
            "state": "refresh_failed", "reason": "transport",
            "refreshExpiresAt": "2026-10-30T12:00:00.123456789Z",
            "lastRefreshAt": "2026-10-30T12:00:00Z",
        ]
        var chatGPT = sourcesAccount()
        chatGPT["provider"] = "chatgpt"
        chatGPT["id"] = "user-fixture"
        chatGPT["verdict"] = "unpolled"
        chatGPT["source"] = "pushed_cookie"
        chatGPT["hostLogin"] = false
        chatGPT["login"] = NSNull()
        let fixture = try sourcesFixture(sourcesResponse(accounts: [claude, chatGPT]))
        defer { fixture.cleanup() }

        let sources = try await RemoteSSHTransport(testing: fixture.configuration())
            .fetchSources(host: host(), secret: secret())

        XCTAssertEqual(sources.schemaVersion, 2)
        XCTAssertEqual(sources.acceptedGeneration, 7)
        XCTAssertEqual(sources.accounts.count, 2)
        let first = try XCTUnwrap(sources.accounts.first)
        XCTAssertEqual(first.provider, .claude)
        XCTAssertEqual(first.id, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(first.verdict, .ok)
        XCTAssertEqual(first.observedAt, Date(timeIntervalSince1970: 1_793_361_600))
        XCTAssertEqual(first.source, .hostLogin)
        XCTAssertTrue(first.hostLogin)
        let login = try XCTUnwrap(first.login)
        XCTAssertEqual(login.state, .refreshFailed)
        XCTAssertEqual(login.reason, "transport")
        XCTAssertEqual(try XCTUnwrap(login.refreshExpiresAt).timeIntervalSince1970, 1_793_361_600.123, accuracy: 0.001)
        XCTAssertEqual(login.lastRefreshAt, Date(timeIntervalSince1970: 1_793_361_600))
        XCTAssertEqual(sources.accounts[1], HostSourcesAccountDTO(
            provider: .chatgpt, id: "user-fixture", verdict: .unpolled, observedAt: nil,
            source: .pushedCookie, hostLogin: false, login: nil
        ))
        XCTAssertEqual(try fixture.capturedArguments().last, "pinemeterd status --sources")
        XCTAssertEqual(try fixture.inputByteCount(), 0)
        XCTAssertTrue(fixture.operationDirectories().isEmpty)
    }

    func testFetchSourcesDecodesNanoMilliAndWholeSecondDates() async throws {
        for (text, fraction) in [
            ("2026-10-30T12:00:00.123456789Z", 0.123456789),
            ("2026-10-30T12:00:00.123Z", 0.123),
            ("2026-10-30T12:00:00Z", 0.0),
        ] {
            var account = sourcesAccount()
            var login = sourcesLogin()
            login["refreshExpiresAt"] = text
            account["login"] = login
            let sources = try await fetchSourcesResponse(sourcesResponse(accounts: [account]))
            let date = try XCTUnwrap(sources.accounts.first?.login?.refreshExpiresAt)
            XCTAssertEqual(date.timeIntervalSince1970, 1_793_361_600 + fraction, accuracy: 0.001, text)
        }
    }

    func testFetchSourcesRejectsSchemaAndKeySetViolations() async throws {
        var wrongSchema = sourcesResponse()
        wrongSchema["schemaVersion"] = 1
        var extraTopKey = sourcesResponse()
        extraTopKey["credential"] = "FAKE-credential"
        var missingTopKey = sourcesResponse()
        missingTopKey.removeValue(forKey: "acceptedGeneration")
        var missingAccountKey = sourcesAccount()
        missingAccountKey.removeValue(forKey: "hostLogin")
        var extraAccountKey = sourcesAccount()
        extraAccountKey["credential"] = "FAKE-credential"
        var extraLoginKey = sourcesLogin()
        extraLoginKey["token"] = "FAKE-token"
        var missingLoginKey = sourcesLogin()
        missingLoginKey.removeValue(forKey: "lastRefreshAt")
        var extraLoginAccount = sourcesAccount()
        extraLoginAccount["login"] = extraLoginKey
        var missingLoginAccount = sourcesAccount()
        missingLoginAccount["login"] = missingLoginKey

        for response in [wrongSchema, extraTopKey, missingTopKey,
                         sourcesResponse(accounts: [missingAccountKey]), sourcesResponse(accounts: [extraAccountKey]),
                         sourcesResponse(accounts: [extraLoginAccount]), sourcesResponse(accounts: [missingLoginAccount])] {
            await assertTransportError(.invalidResponse) { _ = try await self.fetchSourcesResponse(response) }
        }
    }

    func testFetchSourcesRejectsUnknownEnumsAndReasons() async throws {
        for (key, value) in [("provider", "gemini"), ("verdict", "fresh"), ("source", "browser")] {
            var account = sourcesAccount()
            account[key] = value
            let response = sourcesResponse(accounts: [account])
            await assertTransportError(.invalidResponse) { _ = try await self.fetchSourcesResponse(response) }
        }
        for (key, value) in [("state", "unknown"), ("reason", "stolen")] {
            var login = sourcesLogin()
            login[key] = value
            var account = sourcesAccount()
            account["login"] = login
            let response = sourcesResponse(accounts: [account])
            await assertTransportError(.invalidResponse) { _ = try await self.fetchSourcesResponse(response) }
        }
        let sources = try await fetchSourcesResponse(sourcesResponse())
        XCTAssertEqual(sources.accounts.first?.login, HostLoginHealthDTO(
            state: .fresh, reason: "", refreshExpiresAt: nil, lastRefreshAt: nil
        ))
    }

    func testFetchSourcesRejectsBadIdsAndRowCount() async throws {
        for id in ["", String(repeating: "x", count: 257), "user-fixture\n"] {
            var account = sourcesAccount()
            account["id"] = id
            let response = sourcesResponse(accounts: [account])
            await assertTransportError(.invalidResponse) { _ = try await self.fetchSourcesResponse(response) }
        }
        let accounts = (0..<257).map { index in
            var account = sourcesAccount()
            account["id"] = "user-fixture-\(index)"
            account["login"] = NSNull()
            return account
        }
        await assertTransportError(.invalidResponse) {
            _ = try await self.fetchSourcesResponse(self.sourcesResponse(accounts: accounts))
        }
        let sources = try await fetchSourcesResponse(sourcesResponse(accounts: Array(accounts.prefix(256))))
        XCTAssertEqual(sources.accounts.count, 256)
        var boundary = sourcesAccount()
        boundary["id"] = String(repeating: "x", count: 256)
        let boundarySources = try await fetchSourcesResponse(sourcesResponse(accounts: [boundary]))
        XCTAssertEqual(boundarySources.accounts.first?.id.utf8.count, 256)
    }

    func testFetchSourcesRejectsMalformedDate() async throws {
        var login = sourcesLogin()
        login["lastRefreshAt"] = "not-a-date"
        var account = sourcesAccount()
        account["login"] = login
        let response = sourcesResponse(accounts: [account])
        await assertTransportError(.invalidResponse) { _ = try await self.fetchSourcesResponse(response) }
    }

    func testFetchSourcesRefusalExit126IsTransportFailure() async throws {
        let fixture = try SSHProcessFixture(body: "exit 126")
        defer { fixture.cleanup() }
        await assertTransportError(.transportFailed) {
            _ = try await RemoteSSHTransport(testing: fixture.configuration())
                .fetchSources(host: self.host(), secret: self.secret())
        }
        XCTAssertTrue(fixture.operationDirectories().isEmpty)
    }

    func testStartupSweepRemovesOnlyStaleOperationDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-ssh-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent("pinemeter-ssh-\(UUID().uuidString)")
        let unrelated = root.appendingPathComponent("pinemeter-ssh-not-a-uuid")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try Data("stale-key-material".utf8).write(to: stale.appendingPathComponent("identity"))

        RemoteSSHTransport.removeStaleOperationDirectories(at: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testImportUsesPinnedHardenedArgumentsAndCleansTemporaryFiles() async throws {
        let fixture = try SSHProcessFixture(response: #"{"schemaVersion":1,"acceptedGeneration":7}"#)
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.configuration())

        let acknowledgement = try await transport.importBundle(bundle(generation: 7), host: host(), secret: secret())

        XCTAssertEqual(acknowledgement, ImportAck(schemaVersion: 1, acceptedGeneration: 7))
        let arguments = try fixture.capturedArguments()
        assertHardening(arguments)
        XCTAssertEqual(arguments.last, "pinemeterd import --stdin")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-l")! + 1], "pinemeter")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--")! + 1], "host.example.com")
        XCTAssertFalse(arguments.joined(separator: " ").contains("identity-secret-sentinel"))
        XCTAssertFalse(arguments.joined(separator: " ").contains(validPinnedKey()))
        XCTAssertEqual(try fixture.inputByteCount(), bundle(generation: 7).count)
        XCTAssertEqual(try fixture.recordedModes(), ["700", "600", "600"])
        XCTAssertTrue(fixture.operationDirectories().isEmpty)
        XCTAssertFalse(try fixture.environmentNames().contains("SSH_AUTH_SOCK"))
        XCTAssertFalse(try fixture.environmentNames().contains("SSH_ASKPASS"))
        XCTAssertFalse(try fixture.environmentNames().contains("DISPLAY"))
    }

    func testFetchStatusSendsNoInputAndDecodesOnlyAllowListedMetadata() async throws {
        let response = #"{"schemaVersion":1,"acceptedGeneration":7,"observedGeneration":7,"accounts":[{"provider":"claude","id":"account-a","verdict":"ok"}]}"#
        let fixture = try SSHProcessFixture(response: response)
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.configuration())

        let status = try await transport.fetchStatus(host: host(), secret: secret())

        XCTAssertEqual(status.schemaVersion, 1)
        XCTAssertEqual(status.acceptedGeneration, 7)
        XCTAssertEqual(status.observedGeneration, 7)
        XCTAssertEqual(status.accounts.first?.provider, .claude)
        XCTAssertEqual(status.accounts.first?.verdict, .ok)
        XCTAssertEqual(try fixture.inputByteCount(), 0)
        XCTAssertEqual(try fixture.capturedArguments().last, "pinemeterd status")
        XCTAssertTrue(fixture.operationDirectories().isEmpty)
    }

    func testInvalidHostUserAndPinNeverLaunchProcess() async throws {
        for invalidHost in ["-oProxyCommand=bad", "host.example.com:22", "host example.com"] {
            let fixture = try SSHProcessFixture(response: "{}")
            defer { fixture.cleanup() }
            let transport = RemoteSSHTransport(testing: fixture.configuration())
            var target = host()
            target.host = invalidHost
            await assertTransportError(.invalidConfiguration) {
                _ = try await transport.fetchStatus(host: target, secret: self.secret())
            }
            XCTAssertFalse(fixture.didLaunch)
        }

        let fixture = try SSHProcessFixture(response: "{}")
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.configuration())
        var target = host()
        target.sshUser = "-bad"
        await assertTransportError(.invalidConfiguration) {
            _ = try await transport.fetchStatus(host: target, secret: self.secret())
        }
        await assertTransportError(.invalidConfiguration) {
            _ = try await transport.fetchStatus(
                host: self.host(),
                secret: RemoteHostSecret(identity: Data("identity".utf8), pinnedHostKey: "ssh-ed25519 AAAA")
            )
        }
        XCTAssertFalse(fixture.didLaunch)
    }

    func testKeyPathMetadataNeverReachesArgumentsAndOnlyOneIdentityIsSelected() async throws {
        let fixture = try SSHProcessFixture(response: #"{"schemaVersion":1,"acceptedGeneration":9}"#)
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.configuration())
        var target = host()
        target.keyPath = "$(touch /tmp/never-run); -o IdentityFile=/wrong/key"

        _ = try await transport.importBundle(bundle(generation: 9), host: target, secret: secret())

        let arguments = try fixture.capturedArguments()
        XCTAssertEqual(arguments.filter { $0 == "-i" }.count, 1)
        XCTAssertTrue(arguments.contains("IdentityAgent=none"))
        XCTAssertTrue(arguments.contains("IdentitiesOnly=yes"))
        XCTAssertFalse(arguments.joined(separator: " ").contains("never-run"))
        XCTAssertFalse(arguments.joined(separator: " ").contains("/wrong/key"))
    }

    func testMaliciousResponseCannotWriteKeychain() async throws {
        let fixture = try SSHProcessFixture(
            response: #"{"schemaVersion":1,"acceptedGeneration":7,"credential":"synthetic-remote-credential"}"#
        )
        defer { fixture.cleanup() }
        let operations = ReadOnlySecretOperations(identity: secret().identity, pin: secret().pinnedHostKey)
        let repository = RemoteHostSecretRepository(operations: operations)
        let transport = RemoteSSHTransport(secretRepository: repository, testing: fixture.configuration())

        await assertTransportError(.invalidResponse) {
            _ = try await transport.importBundle(self.bundle(generation: 7), host: self.host())
        }

        XCTAssertEqual(operations.writeCount, 0)
    }

    func testGenerationMismatchAndUnknownEnumsAreRejected() async throws {
        let mismatch = try SSHProcessFixture(response: #"{"schemaVersion":1,"acceptedGeneration":8}"#)
        defer { mismatch.cleanup() }
        await assertTransportError(.generationMismatch) {
            _ = try await RemoteSSHTransport(testing: mismatch.configuration())
                .importBundle(self.bundle(generation: 7), host: self.host(), secret: self.secret())
        }

        let unknown = try SSHProcessFixture(
            response: #"{"schemaVersion":1,"acceptedGeneration":7,"observedGeneration":7,"accounts":[{"provider":"claude","id":"a","verdict":"future"}]}"#
        )
        defer { unknown.cleanup() }
        await assertTransportError(.invalidResponse) {
            _ = try await RemoteSSHTransport(testing: unknown.configuration())
                .fetchStatus(host: self.host(), secret: self.secret())
        }
    }

    func testTimeoutTerminatesOnlyChildAndCleansFiles() async throws {
        let fixture = try SSHProcessFixture(body: "exec /bin/sleep 5")
        defer { fixture.cleanup() }
        var configuration = fixture.configuration()
        configuration.timeoutNanoseconds = 50_000_000
        configuration.terminationGraceNanoseconds = 20_000_000
        let started = Date()

        await assertTransportError(.timedOut) {
            _ = try await RemoteSSHTransport(testing: configuration)
                .fetchStatus(host: self.host(), secret: self.secret())
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertTrue(fixture.operationDirectories().isEmpty)
    }

    func testCancellationTerminatesChildAndCleansFiles() async throws {
        let fixture = try SSHProcessFixture(body: "exec /bin/sleep 5")
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.configuration())
        let task = Task { try await transport.fetchStatus(host: host(), secret: secret()) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? RemoteSSHTransportError, .cancelled)
        }
        XCTAssertTrue(fixture.operationDirectories().isEmpty)
    }

    func testFloodedOutputAndEarlyExitAreBoundedAndCleaned() async throws {
        let flood = try SSHProcessFixture(body: "/usr/bin/yes x | /usr/bin/head -c 10000")
        defer { flood.cleanup() }
        var floodConfiguration = flood.configuration()
        floodConfiguration.maxOutputBytes = 128
        await assertTransportError(.outputTooLarge) {
            _ = try await RemoteSSHTransport(testing: floodConfiguration)
                .fetchStatus(host: self.host(), secret: self.secret())
        }
        XCTAssertTrue(flood.operationDirectories().isEmpty)

        let stderrFlood = try SSHProcessFixture(body: "/usr/bin/yes x | /usr/bin/head -c 10000 >&2")
        defer { stderrFlood.cleanup() }
        var stderrConfiguration = stderrFlood.configuration()
        stderrConfiguration.maxOutputBytes = 128
        await assertTransportError(.outputTooLarge) {
            _ = try await RemoteSSHTransport(testing: stderrConfiguration)
                .fetchStatus(host: self.host(), secret: self.secret())
        }
        XCTAssertTrue(stderrFlood.operationDirectories().isEmpty)

        let earlyExit = try SSHProcessFixture(
            body: "exec 0<&-\n/bin/sleep 0.05\nexit 1",
            consumeInput: false
        )
        defer { earlyExit.cleanup() }
        let largeBundle = Data(#"{"generation":1,"padding":""#.utf8)
            + Data(repeating: 120, count: 1_000_000)
            + Data(#""}"#.utf8)
        // The child must start a shell, sleep and exit before the transport
        // gives up; the default 2 s budget is too tight on a loaded CI runner,
        // where it surfaced as `.timedOut` instead of the early exit (#115).
        var earlyExitConfiguration = earlyExit.configuration()
        earlyExitConfiguration.timeoutNanoseconds = 10_000_000_000
        await assertTransportError(.transportFailed) {
            _ = try await RemoteSSHTransport(testing: earlyExitConfiguration)
                .importBundle(largeBundle, host: self.host(), secret: self.secret())
        }
        XCTAssertTrue(earlyExit.operationDirectories().isEmpty)
    }

    func testLaunchFailureCleansTemporaryFiles() async throws {
        let fixture = try SSHProcessFixture(response: "{}")
        defer { fixture.cleanup() }
        var configuration = fixture.configuration()
        configuration.executableURL = fixture.root.appendingPathComponent("missing-executable")

        await assertTransportError(.launchFailed) {
            _ = try await RemoteSSHTransport(testing: configuration)
                .fetchStatus(host: self.host(), secret: self.secret())
        }

        XCTAssertTrue(fixture.operationDirectories().isEmpty)
    }

    func testOversizedBundleIsRejectedBeforeLaunch() async throws {
        let fixture = try SSHProcessFixture(response: "{}")
        defer { fixture.cleanup() }
        let oversized = Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1)

        await assertTransportError(.bundleTooLarge) {
            _ = try await RemoteSSHTransport(testing: fixture.configuration())
                .importBundle(oversized, host: self.host(), secret: self.secret())
        }

        XCTAssertFalse(fixture.didLaunch)
    }

    @MainActor
    func testTransportDoesNotBlockMainActor() async throws {
        let response = #"{"schemaVersion":1,"acceptedGeneration":7,"observedGeneration":7,"accounts":[]}"#
        let fixture = try SSHProcessFixture(body: "/bin/sleep 0.2\n/bin/echo '\(response)'")
        defer { fixture.cleanup() }
        let transport = RemoteSSHTransport(testing: fixture.configuration())
        var ticked = false
        let request = Task { try await transport.fetchStatus(host: host(), secret: secret()) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            ticked = true
        }
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertTrue(ticked)
        _ = try await request.value
    }

    private func host() -> RemoteHost {
        RemoteHost(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            host: "host.example.com",
            sshUser: "pinemeter",
            keyPath: "/display-only/key",
            secretReference: "secret-reference",
            pinnedHostKeyFingerprint: "SHA256:display"
        )
    }

    private func sourcesLogin() -> [String: Any] {
        ["state": "fresh", "reason": "", "refreshExpiresAt": NSNull(), "lastRefreshAt": NSNull()]
    }

    private func sourcesAccount() -> [String: Any] {
        ["provider": "claude", "id": "11111111-1111-1111-1111-111111111111", "verdict": "ok",
         "observedAt": NSNull(), "source": "host_login", "hostLogin": true, "login": sourcesLogin()]
    }

    private func sourcesResponse(accounts: [[String: Any]]? = nil) -> [String: Any] {
        ["schemaVersion": 2, "acceptedGeneration": 7, "accounts": accounts ?? [sourcesAccount()]]
    }

    private func sourcesFixture(_ response: [String: Any]) throws -> SSHProcessFixture {
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        return try SSHProcessFixture(body: "/usr/bin/printf '%s\\n' '\(json)'")
    }

    private func fetchSourcesResponse(_ response: [String: Any]) async throws -> HostSourcesDTO {
        let fixture = try sourcesFixture(response)
        defer {
            XCTAssertTrue(fixture.operationDirectories().isEmpty)
            fixture.cleanup()
        }
        return try await RemoteSSHTransport(testing: fixture.configuration())
            .fetchSources(host: host(), secret: secret())
    }

    private func secret() -> RemoteHostSecret {
        RemoteHostSecret(identity: Data("identity-secret-sentinel".utf8), pinnedHostKey: validPinnedKey())
    }

    private func bundle(generation: UInt64) -> Data {
        Data("{\"generation\":\(generation)}".utf8)
    }

    private func validPinnedKey() -> String {
        let blob = sshString("ssh-ed25519") + sshString(Data(repeating: 4, count: 32))
        return "ssh-ed25519 \(blob.base64EncodedString())"
    }

    private func assertHardening(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) {
        let required = [
            "-F", "/dev/null", "-T", "BatchMode=yes", "StrictHostKeyChecking=yes",
            "GlobalKnownHostsFile=/dev/null", "KnownHostsCommand=none", "VerifyHostKeyDNS=no",
            "UpdateHostKeys=no", "CheckHostIP=no", "IdentitiesOnly=yes", "IdentityAgent=none",
            "PreferredAuthentications=publickey", "PasswordAuthentication=no",
            "KbdInteractiveAuthentication=no", "ForwardAgent=no", "ClearAllForwardings=yes",
            "ControlMaster=no", "ControlPath=none", "ConnectTimeout=10", "ConnectionAttempts=1",
            "ServerAliveInterval=5", "ServerAliveCountMax=2", "-i", "-l", "--",
        ]
        for value in required {
            XCTAssertTrue(arguments.contains(value), "Missing \(value)", file: file, line: line)
        }
        XCTAssertTrue(arguments.contains { $0.hasPrefix("UserKnownHostsFile=") }, file: file, line: line)
        XCTAssertTrue(arguments.contains { $0.hasPrefix("HostKeyAlias=pinemeter-") }, file: file, line: line)
    }

    private func assertSharedPinnedArguments(
        _ arguments: [String],
        command: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let knownHosts = try XCTUnwrap(arguments.first { $0.hasPrefix("UserKnownHostsFile=") })
        let identityIndex = try XCTUnwrap(arguments.firstIndex(of: "-i"))
        let prefix = RemoteSSHPinnedOptions.arguments(
            knownHostsPath: String(knownHosts.dropFirst("UserKnownHostsFile=".count)),
            alias: "pinemeter-11111111-1111-1111-1111-111111111111"
        )
        XCTAssertEqual(prefix.count, 47, file: file, line: line)
        XCTAssertEqual(Array(arguments.prefix(47)), prefix, file: file, line: line)
        XCTAssertEqual(Array(arguments.dropFirst(47)), [
            "-i", arguments[identityIndex + 1], "-l", "pinemeter", "--", "host.example.com", command,
        ], file: file, line: line)
    }
}

private final class SSHProcessFixture {
    let root: URL
    private let executable: URL
    private let argumentsURL: URL
    private let inputCountURL: URL
    private let modesURL: URL
    private let environmentURL: URL

    var didLaunch: Bool { FileManager.default.fileExists(atPath: argumentsURL.path) }

    convenience init(response: String) throws {
        try self.init(body: "/bin/echo '\(response)'")
    }

    init(body: String, consumeInput: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteSSHTransportTests-\(UUID())")
        executable = root.appendingPathComponent("fixture-ssh")
        argumentsURL = root.appendingPathComponent("arguments")
        inputCountURL = root.appendingPathComponent("input-count")
        modesURL = root.appendingPathComponent("modes")
        environmentURL = root.appendingPathComponent("environment")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let inputStep = consumeInput
            ? "bytes=$(/bin/cat | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
            : "bytes=0"
        let script = """
        #!/bin/sh
        /usr/bin/printf '%s\\n' "$@" > '\(argumentsURL.path)'
        /usr/bin/env | /usr/bin/sed 's/=.*//' > '\(environmentURL.path)'
        identity=''
        known_hosts=''
        previous=''
        for argument in "$@"; do
          if [ "$previous" = '-i' ]; then identity="$argument"; fi
          case "$argument" in UserKnownHostsFile=*) known_hosts="${argument#UserKnownHostsFile=}" ;; esac
          previous="$argument"
        done
        /usr/bin/stat -f '%Lp' "$(/usr/bin/dirname "$identity")" > '\(modesURL.path)'
        /usr/bin/stat -f '%Lp' "$identity" >> '\(modesURL.path)'
        /usr/bin/stat -f '%Lp' "$known_hosts" >> '\(modesURL.path)'
        \(inputStep)
        /usr/bin/printf '%s' "$bytes" > '\(inputCountURL.path)'
        \(body)
        """
        try Data(script.utf8).write(to: executable, options: .withoutOverwriting)
        guard chmod(executable.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }

    func configuration() -> RemoteSSHTransportTestConfiguration {
        // Decode and command-contract tests must not race shell startup on a loaded runner.
        // Deadline tests override this budget explicitly.
        RemoteSSHTransportTestConfiguration(
            executableURL: executable, operationRoot: root, timeoutNanoseconds: 30_000_000_000
        )
    }

    func capturedArguments() throws -> [String] {
        try String(contentsOf: argumentsURL, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
    }

    func inputByteCount() throws -> Int {
        try XCTUnwrap(Int(String(contentsOf: inputCountURL, encoding: .utf8)))
    }

    func recordedModes() throws -> [String] {
        try String(contentsOf: modesURL, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
    }

    func environmentNames() throws -> [String] {
        try String(contentsOf: environmentURL, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
    }

    func operationDirectories() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("pinemeter-ssh-") } ?? []
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class ReadOnlySecretOperations: RemoteHostKeychainOperations, @unchecked Sendable {
    let identity: Data
    let pin: String
    private(set) var writeCount = 0

    init(identity: Data, pin: String) {
        self.identity = identity
        self.pin = pin
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        writeCount += 1
        return errSecSuccess
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        writeCount += 1
        return errSecSuccess
    }

    func copy(service: String, account: String) -> (OSStatus, Data?) {
        (errSecSuccess, service.hasSuffix(".identity") ? identity : Data(pin.utf8))
    }

    func delete(service: String, account: String) -> OSStatus {
        writeCount += 1
        return errSecSuccess
    }
}

private func assertTransportError(
    _ expected: RemoteSSHTransportError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? RemoteSSHTransportError, expected, file: file, line: line)
    }
}

private func sshString(_ value: String) -> Data { sshString(Data(value.utf8)) }

private func sshString(_ value: Data) -> Data {
    var length = UInt32(value.count).bigEndian
    var data = withUnsafeBytes(of: &length) { Data($0) }
    data.append(value)
    return data
}
