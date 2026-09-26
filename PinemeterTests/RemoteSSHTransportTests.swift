import Foundation
import Security
import XCTest
@testable import Pinemeter

final class RemoteSSHTransportTests: XCTestCase {
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
        await assertTransportError(.transportFailed) {
            _ = try await RemoteSSHTransport(testing: earlyExit.configuration())
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
        RemoteSSHTransportTestConfiguration(executableURL: executable, operationRoot: root)
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
