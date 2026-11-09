import Darwin
import Foundation
import XCTest
@testable import Pinemeter

final class HostLoginLauncherTests: XCTestCase {
    func testPinnedOptionsMatchPushListInOrder() {
        XCTAssertEqual(RemoteSSHPinnedOptions.arguments(knownHostsPath: "/tmp/k", alias: "pinemeter-x"), [
            "-F", "/dev/null", "-T",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=/tmp/k",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "KnownHostsCommand=none",
            "-o", "VerifyHostKeyDNS=no",
            "-o", "UpdateHostKeys=no",
            "-o", "HostKeyAlias=pinemeter-x",
            "-o", "CheckHostIP=no",
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
        ])
        XCTAssertEqual(RemoteSSHPinnedOptions.arguments(knownHostsPath: "/tmp/k", alias: "a").count, 47)
        XCTAssertEqual(RemoteSSHPinnedOptions.alias(for: hostID), "pinemeter-11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(RemoteSSHPinnedOptions.knownHostsLine(alias: "a", record: "ssh-ed25519 AAAA"), "a ssh-ed25519 AAAA\n")
    }

    func testGrammarAcceptsOnlyReceiverForms() {
        let uuid = "abcdefab-abcd-abcd-abcd-abcdefabcdef"
        let accepted = [
            ("claude", uuid), ("claude", uuid.uppercased()), ("codex", uuid),
            ("codex", "user-fixture"), ("codex", "user-" + String(repeating: "a_-9", count: 16)),
        ]
        for (word, id) in accepted {
            XCTAssertEqual(HostLoginGrammar.remoteCommand(loginWord: word, accountID: id),
                           "pinemeterd login \(word) --account \(id)", "\(word): \(id)")
        }
        let refused = [
            ("claude", "user-fixture"), ("claude", "legacy-chatgpt"), ("codex", "legacy-chatgpt"),
            ("claude", "claude.default"), ("codex", "chatgpt.legacy"), ("codex", "user-"),
            ("codex", "user-" + String(repeating: "a", count: 65)), ("claude", String(uuid.dropLast())),
            ("codex", "x'; rm -rf ~; '"), ("codex", "$(id)"), ("codex", "`id`"), ("codex", "a b"),
            ("claude", uuid + "\n"), ("claude", " " + uuid), ("chatgpt", uuid), ("Claude", uuid),
            ("claude ", uuid), ("", uuid), ("codex", ""), ("codex", "user-é"),
            ("codex", "user-a\0"), ("codex", String(repeating: "a", count: 257)),
        ]
        for (word, id) in refused {
            XCTAssertNil(HostLoginGrammar.remoteCommand(loginWord: word, accountID: id), "\(word): \(id)")
        }
    }

    func testScriptPassesExactArgvUnderShell() throws {
        let fixture = try LoginShellFixture()
        defer { fixture.cleanup() }
        let key = fixture.root.appendingPathComponent("key").path
        let options = RemoteSSHPinnedOptions.arguments(knownHostsPath: fixture.operation.appendingPathComponent("known_hosts").path, alias: "pinemeter-x")
        let script = fixture.script(options: options, keyPath: key)
        try fixture.run(script)
        XCTAssertEqual(try fixture.arguments(), options + [
            "-i", key, "-l", "pinemeter", "--", "host.example.com",
            "pinemeterd login codex --account user-fixture",
        ])
    }

    func testHostileValuesStayLiteral() throws {
        let fixture = try LoginShellFixture()
        defer { fixture.cleanup() }
        let key = "/tmp/a'b $(touch PWNED) %h"
        let banner = "Fixture 'banner' $(touch PWNED) $HOME"
        try fixture.run(fixture.script(options: [], keyPath: key, banner: banner))
        XCTAssertEqual(try fixture.arguments(), [
            "-i", key, "-l", "pinemeter", "--", "host.example.com",
            "pinemeterd login codex --account user-fixture",
        ])
        XCTAssertTrue(try fixture.output().hasPrefix(banner + "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("PWNED").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operation.appendingPathComponent("PWNED").path))
    }

    func testScriptRemovesItsDirectoryAndKeepsStdin() throws {
        let fixture = try LoginShellFixture(readInput: true)
        defer { fixture.cleanup() }
        let script = fixture.script(options: [], keyPath: "/tmp/key")
        XCTAssertFalse(script.contains("<"))
        XCTAssertTrue(script.contains("trap '/bin/rm -rf -- \"$dir\"' EXIT"))
        XCTAssertTrue(script.contains("trap 'exit 130' HUP INT TERM"))
        XCTAssertTrue(script.contains("read -r _ || true"))
        XCTAssertTrue(script.hasSuffix("\n"))
        try fixture.run(script, input: "fixture-terminal-input\n\n")
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("input"), encoding: .utf8), "fixture-terminal-input\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operation.path))
    }

    func testLaunchWritesPrivateFilesAndOpensOnce() async throws {
        let fixture = try LoginLaunchFixture()
        defer { fixture.cleanup() }
        let opener = RecordingLoginOpener()
        try await HostLoginLauncher(opener: opener, operationRoot: fixture.root).launch(fixture.request)
        let captured = await opener.captured()
        let files = try XCTUnwrap(captured.first)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(files.url.lastPathComponent, "login.command")
        let directory = files.url.deletingLastPathComponent()
        XCTAssertEqual(directory.deletingLastPathComponent().path, fixture.root.path)
        XCTAssertTrue(directory.lastPathComponent.hasPrefix("pinemeter-login-"))
        XCTAssertNotNil(UUID(uuidString: String(directory.lastPathComponent.dropFirst("pinemeter-login-".count))))
        XCTAssertEqual(files.directoryMode, 0o700)
        XCTAssertEqual(files.knownHostsMode, 0o600)
        XCTAssertEqual(files.scriptMode, 0o700)
        let alias = "pinemeter-\(hostID.uuidString.lowercased())"
        XCTAssertEqual(files.knownHosts, "\(alias) \(fixture.request.pinnedHostKeyRecord)\n")
        XCTAssertTrue(files.script.contains("HostKeyAlias=\(alias)"))
        XCTAssertTrue(files.script.contains("UserKnownHostsFile=\(directory.path)/known_hosts"))
        XCTAssertTrue(files.script.contains(HostLoginScript.shellQuote(fixture.request.keyPath)))
        XCTAssertTrue(files.script.contains("Pinemeter: logging in Codex account user-fixture on host.example.com."))
        XCTAssertFalse(files.script.contains("PRIVATE KEY"))
        XCTAssertFalse(files.script.contains("FAKE-KEY-CONTENT"))
        XCTAssertFalse(files.knownHosts.contains("FAKE-KEY-CONTENT"))
        XCTAssertEqual(getxattr(files.url.path, "com.apple.quarantine", nil, 0, 0, 0), -1)
        XCTAssertEqual(errno, ENOATTR)
    }

    func testInvalidInputsNeverWriteOrOpen() async throws {
        let fixture = try LoginLaunchFixture()
        defer { fixture.cleanup() }
        let opener = RecordingLoginOpener()
        let launcher = HostLoginLauncher(opener: opener, operationRoot: fixture.root)
        let invalid: [(HostLoginLaunchRequest, HostLoginLaunchError)] = [
            (fixture.request(host: "-oProxyCommand=x"), .invalidHost),
            (fixture.request(host: "host.example.com:22"), .invalidHost),
            (fixture.request(user: "-root"), .invalidUser),
            (fixture.request(account: "legacy-chatgpt"), .invalidAccount),
            (fixture.request(word: "claude", account: "claude.default"), .invalidAccount),
            (fixture.request(account: "x'; id; '"), .invalidAccount),
            (fixture.request(word: "chatgpt"), .invalidAccount),
            (fixture.request(pin: "ssh-ed25519 AAAA"), .invalidPinnedHostKey),
            (fixture.request(key: fixture.root.appendingPathComponent("missing").path), .keyUnreadable(path: fixture.root.appendingPathComponent("missing").path)),
            (fixture.request(key: fixture.root.path), .keyUnreadable(path: fixture.root.path)),
            (fixture.request(key: fixture.request.keyPath + "%h"), .invalidKeyPath),
            (fixture.request(key: fixture.request.keyPath + "$HOME"), .invalidKeyPath),
            (fixture.request(key: fixture.request.keyPath + "\n"), .invalidKeyPath),
            (fixture.request(key: "relative/key"), .invalidKeyPath),
        ]
        for (request, expected) in invalid {
            do {
                try await launcher.launch(request)
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? HostLoginLaunchError, expected)
            }
            XCTAssertEqual(try fixture.loginDirectories(), [])
        }
        let captured = await opener.captured()
        XCTAssertTrue(captured.isEmpty)
        XCTAssertEqual(chmod(fixture.request.keyPath, 0), 0)
        do {
            try await launcher.launch(fixture.request)
            XCTFail("Expected unreadable key")
        } catch {
            XCTAssertEqual(error as? HostLoginLaunchError, .keyUnreadable(path: fixture.request.keyPath))
        }
        XCTAssertEqual(chmod(fixture.request.keyPath, 0o600), 0)
        XCTAssertEqual(try fixture.loginDirectories(), [])
        let afterUnreadable = await opener.captured()
        XCTAssertTrue(afterUnreadable.isEmpty)
    }

    func testTildeKeyPathExpands() throws {
        let fixture = try LoginLaunchFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(HostLoginLauncher.expandedKeyPath("~/keys/id", home: fixture.root), fixture.root.appendingPathComponent("keys/id").path)
        XCTAssertEqual(HostLoginLauncher.expandedKeyPath(fixture.root.path + "/keys/../id", home: fixture.root), fixture.root.appendingPathComponent("id").path)
        for path in ["relative/key", "~user/x", "/tmp/%h", "/tmp/$HOME", "/tmp/key\n", "/tmp/key\0", "/tmp/key\u{7f}"] {
            XCTAssertNil(HostLoginLauncher.expandedKeyPath(path, home: fixture.root), path)
        }
    }

    func testOpenerFailureRemovesDirectory() async throws {
        let fixture = try LoginLaunchFixture()
        defer { fixture.cleanup() }
        let opener = RecordingLoginOpener(shouldThrow: true)
        do {
            try await HostLoginLauncher(opener: opener, operationRoot: fixture.root).launch(fixture.request)
            XCTFail("Expected open failure")
        } catch {
            XCTAssertEqual(error as? HostLoginLaunchError, .openFailed)
        }
        XCTAssertEqual(try fixture.loginDirectories(), [])
        let captured = await opener.captured()
        XCTAssertEqual(captured.count, 1)
    }

    func testUnsafeOperationRootIsRefused() async throws {
        let fixture = try LoginLaunchFixture()
        defer { fixture.cleanup() }
        let opener = RecordingLoginOpener()
        for name in ["root space", "root%h", "root$HOME", "root\ncontrol"] {
            let unsafe = fixture.root.appendingPathComponent(name)
            do {
                try await HostLoginLauncher(opener: opener, operationRoot: unsafe).launch(fixture.request)
                XCTFail("Expected unsafe root")
            } catch {
                XCTAssertEqual(error as? HostLoginLaunchError, .unsafeTemporaryDirectory)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: unsafe.path))
        }
        let captured = await opener.captured()
        XCTAssertTrue(captured.isEmpty)
    }

    func testStaleSweepRemovesOnlyOldLoginDirectories() throws {
        let fixture = try LoginLaunchFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = fixture.root.appendingPathComponent("pinemeter-login-\(UUID())")
        let fresh = fixture.root.appendingPathComponent("pinemeter-login-\(UUID())")
        let boundary = fixture.root.appendingPathComponent("pinemeter-login-\(UUID())")
        let invalid = fixture.root.appendingPathComponent("pinemeter-login-not-a-uuid")
        let push = fixture.root.appendingPathComponent("pinemeter-ssh-\(UUID())")
        let symlink = fixture.root.appendingPathComponent("pinemeter-login-\(UUID())")
        let regular = fixture.root.appendingPathComponent("pinemeter-login-\(UUID())")
        for directory in [old, fresh, boundary, invalid, push] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: directory.path)
        }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: fresh.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: boundary.path)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: push)
        try Data("FAKE".utf8).write(to: regular)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: regular.path)
        HostLoginLauncher.removeStaleLoginDirectories(at: fixture.root, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for remaining in [fresh, boundary, invalid, push, symlink, regular] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: remaining.path), remaining.lastPathComponent)
        }
        XCTAssertEqual(try symlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
    }

    func testNullLauncherDoesNothing() async throws {
        let fixture = try LoginLaunchFixture()
        defer { fixture.cleanup() }
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        try await NullHostLoginLauncher().launch(fixture.request)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), before)
    }

    func testTerminalOpenerDoesNothingUnderXCTest() async throws {
        let fixture = try LoginLaunchFixture()
        defer { fixture.cleanup() }
        XCTAssertNotNil(NSClassFromString("XCTestCase"))
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        try await TerminalAppOpener().open(script: fixture.root.appendingPathComponent("never-created.command"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), before)
    }

    func testTemporaryDirectoryFailureNeverOpens() async throws {
        let fixture = try LoginLaunchFixture()
        defer { fixture.cleanup() }
        let opener = RecordingLoginOpener()
        let missingRoot = fixture.root.appendingPathComponent("missing-root")
        do {
            try await HostLoginLauncher(opener: opener, operationRoot: missingRoot).launch(fixture.request)
            XCTFail("Expected temporary directory failure")
        } catch {
            XCTAssertEqual(error as? HostLoginLaunchError, .temporaryFileFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.path))
        let captured = await opener.captured()
        XCTAssertTrue(captured.isEmpty)
    }

    private var hostID: UUID { UUID(uuidString: "11111111-1111-1111-1111-111111111111")! }
}

private struct CapturedLoginFiles: Sendable {
    let url: URL
    let script: String
    let knownHosts: String
    let directoryMode: Int
    let knownHostsMode: Int
    let scriptMode: Int
}

private actor RecordingLoginOpener: HostLoginTerminalOpening {
    private let shouldThrow: Bool
    private var files: [CapturedLoginFiles] = []

    init(shouldThrow: Bool = false) { self.shouldThrow = shouldThrow }

    func open(script: URL) async throws {
        let directory = script.deletingLastPathComponent()
        let knownHosts = directory.appendingPathComponent("known_hosts")
        func mode(_ url: URL) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
        }
        files.append(try CapturedLoginFiles(url: script,
                                          script: String(contentsOf: script, encoding: .utf8),
                                          knownHosts: String(contentsOf: knownHosts, encoding: .utf8),
                                          directoryMode: mode(directory), knownHostsMode: mode(knownHosts), scriptMode: mode(script)))
        if shouldThrow { throw CocoaError(.fileReadUnknown) }
    }

    func captured() -> [CapturedLoginFiles] { files }
}

private final class LoginLaunchFixture {
    let root: URL
    let request: HostLoginLaunchRequest

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HostLoginFilesTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let key = root.appendingPathComponent("fake key'quoted")
        try Data("FAKE-KEY-CONTENT".utf8).write(to: key)
        guard chmod(key.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        func sshString(_ data: Data) -> Data {
            var length = UInt32(data.count).bigEndian
            return withUnsafeBytes(of: &length) { Data($0) } + data
        }
        let blob = sshString(Data("ssh-ed25519".utf8)) + sshString(Data(repeating: 4, count: 32))
        request = HostLoginLaunchRequest(hostID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                         host: "host.example.com", sshUser: "pinemeter", keyPath: key.path,
                                         pinnedHostKeyRecord: "ssh-ed25519 \(blob.base64EncodedString())",
                                         loginWord: "codex", accountID: "user-fixture")
    }

    func request(host: String? = nil, user: String? = nil, key: String? = nil,
                 pin: String? = nil, word: String? = nil, account: String? = nil) -> HostLoginLaunchRequest {
        HostLoginLaunchRequest(hostID: request.hostID, host: host ?? request.host, sshUser: user ?? request.sshUser,
                               keyPath: key ?? request.keyPath, pinnedHostKeyRecord: pin ?? request.pinnedHostKeyRecord,
                               loginWord: word ?? request.loginWord, accountID: account ?? request.accountID)
    }

    func loginDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("pinemeter-login-") }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class LoginShellFixture {
    let root: URL
    let operation: URL
    private let executable: URL
    private let argumentsURL: URL
    private let outputURL: URL

    init(readInput: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HostLoginLauncherTests-\(UUID())")
        operation = root.appendingPathComponent("session 'quoted'")
        executable = root.appendingPathComponent("fixture ssh'quoted")
        argumentsURL = root.appendingPathComponent("arguments")
        outputURL = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let inputStep = readInput ? "read -r input; printf '%s\\n' \"$input\" > \(HostLoginScript.shellQuote(root.appendingPathComponent("input").path))" : ""
        let fake = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \(HostLoginScript.shellQuote(argumentsURL.path))\n\(inputStep)\nexit 0\n"
        try Data(fake.utf8).write(to: executable)
        guard chmod(executable.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }

    func script(options: [String], keyPath: String, banner: String = "Fixture login") -> String {
        HostLoginScript.build(sshExecutable: executable.path, options: options, keyPath: keyPath,
                             user: "pinemeter", host: "host.example.com",
                             remoteCommand: "pinemeterd login codex --account user-fixture",
                             operationDirectory: operation.path, banner: banner)
    }

    func run(_ script: String, input: String? = nil) throws {
        let scriptURL = operation.appendingPathComponent("login.command")
        try Data(script.utf8).write(to: scriptURL)
        let inputURL = root.appendingPathComponent("stdin")
        if let input { try Data(input.utf8).write(to: inputURL) }
        let stdin = try FileHandle(forReadingFrom: input == nil ? URL(fileURLWithPath: "/dev/null") : inputURL)
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: outputURL)
        defer { try? stdin.close(); try? stdout.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = root
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        process.waitUntilExit()
        let capturedOutput = try output()
        XCTAssertEqual(process.terminationStatus, 0, capturedOutput)
    }

    func arguments() throws -> [String] {
        try String(contentsOf: argumentsURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func output() throws -> String { try String(contentsOf: outputURL, encoding: .utf8) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
