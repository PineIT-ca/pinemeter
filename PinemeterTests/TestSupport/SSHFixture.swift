import Darwin
import Foundation
#if !PINEMETER_SSH_PREFLIGHT_MAIN
@testable import Pinemeter
#endif

enum SSHFixture {
    enum Mode: String, Codable {
        case standalone
        case proxyCommand = "proxy-command"
    }

    enum Status: String, Codable {
        case pass = "PASS"
        case blocked = "BLOCKED"
        case error = "ERROR"
    }

    struct Attempt: Codable {
        let status: Status
        let mode: Mode
        let command: String
        let exitStatus: Int32
        let authenticated: Bool
        let wrongPinRefused: Bool
        let wrongClientKeyRefused: Bool
        let reason: String

        var passed: Bool {
            status == .pass
        }

        init(
            mode: Mode,
            command: String,
            exitStatus: Int32,
            authenticated: Bool,
            wrongPinRefused: Bool,
            wrongClientKeyRefused: Bool,
            reason: String,
            harnessError: Bool = false
        ) {
            self.status = harnessError
                ? .error
                : authenticated && wrongPinRefused && wrongClientKeyRefused ? .pass
                : authenticated ? .error
                : .blocked
            self.mode = mode
            self.command = command
            self.exitStatus = exitStatus
            self.authenticated = authenticated
            self.wrongPinRefused = wrongPinRefused
            self.wrongClientKeyRefused = wrongClientKeyRefused
            self.reason = reason
        }
    }

    struct Report: Codable {
        let status: Status
        let selectedMode: Mode?
        let command: String
        let exitStatus: Int32
        let reason: String
        let attempts: [Attempt]

        func writeIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
            guard let path = environment["PINEMETER_SSH_PREFLIGHT_RESULT"], !path.isEmpty else {
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    struct Configuration {
        enum Fault {
            case none
            case setupFailure
            case authenticationTimeout
            case earlyServerExit
        }

        var ssh = URL(fileURLWithPath: "/usr/bin/ssh")
        var sshd = URL(fileURLWithPath: "/usr/sbin/sshd")
        var sshKeygen = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        var commandTimeout: TimeInterval = 5
        var startupTimeout: TimeInterval = 3
        var modes: [Mode] = [.standalone, .proxyCommand]
        var fault: Fault = .none
        var onFixtureCreated: ((URL) -> Void)?
        var onProcessStarted: ((pid_t) -> Void)?

        static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
            var configuration = Self()
            if let ssh = environment["PINEMETER_SSH_PREFLIGHT_SSH"] {
                configuration.ssh = URL(fileURLWithPath: ssh)
            }
            if let sshd = environment["PINEMETER_SSH_PREFLIGHT_SSHD"] {
                configuration.sshd = URL(fileURLWithPath: sshd)
            }
            if let keygen = environment["PINEMETER_SSH_PREFLIGHT_SSH_KEYGEN"] {
                configuration.sshKeygen = URL(fileURLWithPath: keygen)
            }
            return configuration
        }
    }

    static func runPreflight(configuration: Configuration = Configuration()) -> Report {
        var attempts: [Attempt] = []

        for mode in configuration.modes {
            let attempt = runAttempt(mode: mode, configuration: configuration)
            attempts.append(attempt)
            if attempt.status != .blocked {
                break
            }
        }
        return report(for: attempts)
    }

    static func report(for attempts: [Attempt]) -> Report {
        if let passed = attempts.first(where: { $0.passed }) {
            return Report(
                status: .pass,
                selectedMode: passed.mode,
                command: passed.command,
                exitStatus: passed.exitStatus,
                reason: passed.reason,
                attempts: attempts
            )
        }
        if let failed = attempts.first(where: { $0.status == .error }) {
            return Report(
                status: .error,
                selectedMode: nil,
                command: failed.command,
                exitStatus: failed.exitStatus,
                reason: failed.reason,
                attempts: attempts
            )
        }
        return Report(
            status: .blocked,
            selectedMode: nil,
            command: "/usr/bin/ssh + /usr/sbin/sshd",
            exitStatus: attempts.last?.exitStatus ?? 1,
            reason: attempts.map { "\($0.mode.rawValue): \($0.reason)" }.joined(separator: "; "),
            attempts: attempts
        )
    }

    private static func runAttempt(mode: Mode, configuration: Configuration) -> Attempt {
        let command = mode == .standalone
            ? "/usr/sbin/sshd -D -e -f <fixture>/sshd_config"
            : "/usr/bin/ssh -o ProxyCommand=/usr/sbin/sshd -i -e -f <fixture>/sshd_config"

        for executable in [configuration.ssh, configuration.sshd, configuration.sshKeygen]
        where !FileManager.default.isExecutableFile(atPath: executable.path) {
            return Attempt(
                mode: mode,
                command: command,
                exitStatus: 127,
                authenticated: false,
                wrongPinRefused: false,
                wrongClientKeyRefused: false,
                reason: "required executable unavailable: \(executable.path)"
            )
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PinemeterSSHFixture-\(UUID().uuidString)", isDirectory: true)
        var server: Process?
        var serverLog: URL?
        defer {
            if let server {
                stop(server)
            }
            try? FileManager.default.removeItem(at: root)
        }

        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            configuration.onFixtureCreated?(root)
            if configuration.fault == .setupFailure {
                throw FixtureError.setupFailure
            }

            let hostKey = root.appendingPathComponent("host_key")
            let wrongHostKey = root.appendingPathComponent("wrong_host_key")
            let clientKey = root.appendingPathComponent("client_key")
            let wrongClientKey = root.appendingPathComponent("wrong_client_key")
            for key in [hostKey, wrongHostKey, clientKey, wrongClientKey] {
                let generated = try run(
                    executable: configuration.sshKeygen,
                    arguments: ["-q", "-t", "ed25519", "-N", "", "-f", key.path],
                    input: Data(),
                    timeout: configuration.commandTimeout,
                    root: root,
                    onProcessStarted: configuration.onProcessStarted
                )
                guard generated.exitStatus == 0 else {
                    return blocked(mode, command, generated.exitStatus, "synthetic key generation failed")
                }
            }

            let wrapper = root.appendingPathComponent("authorized-command")
            try write(
                """
                #!/bin/sh
                set -eu
                case "${SSH_ORIGINAL_COMMAND-}" in
                  'pinemeter-preflight probe')
                    IFS= read -r value || exit 65
                    [ "$value" = 'pinemeter-preflight-input' ] || exit 66
                    printf '%s\\n' 'pinemeter-preflight-output'
                    ;;
                  *) exit 126 ;;
                esac
                """,
                to: wrapper,
                permissions: 0o700
            )

            let clientPublicKey = try publicKey(at: clientKey.appendingPathExtension("pub"))
            let authorizedKeys = root.appendingPathComponent("authorized_keys")
            try write(
                "restrict,command=\"\(escapeAuthorizedCommand(wrapper.path))\" \(clientPublicKey)\n",
                to: authorizedKeys,
                permissions: 0o600
            )

            let knownHosts = root.appendingPathComponent("known_hosts")
            let wrongKnownHosts = root.appendingPathComponent("wrong_known_hosts")
            try write(
                "pinemeter-fixture \(try publicKey(at: hostKey.appendingPathExtension("pub")))\n",
                to: knownHosts,
                permissions: 0o600
            )
            try write(
                "pinemeter-fixture \(try publicKey(at: wrongHostKey.appendingPathExtension("pub")))\n",
                to: wrongKnownHosts,
                permissions: 0o600
            )

            let port = try unusedLoopbackPort()
            let config = root.appendingPathComponent("sshd_config")
            try write(
                sshdConfiguration(
                    root: root,
                    hostKey: hostKey,
                    authorizedKeys: authorizedKeys,
                    port: port
                ),
                to: config,
                permissions: 0o600
            )

            if mode == .standalone {
                let log = root.appendingPathComponent("server.log")
                serverLog = log
                let process = try launch(
                    executable: configuration.fault == .earlyServerExit
                        ? URL(fileURLWithPath: "/usr/bin/false")
                        : configuration.sshd,
                    arguments: ["-D", "-e", "-f", config.path],
                    standardError: log,
                    onProcessStarted: configuration.onProcessStarted
                )
                server = process
                Thread.sleep(forTimeInterval: min(configuration.startupTimeout, 0.15))
                guard process.isRunning else {
                    return blocked(
                        mode,
                        command,
                        process.terminationStatus,
                        "sshd exited before authentication: \(sanitized(read(log), root: root))"
                    )
                }
            }

            if configuration.fault == .authenticationTimeout {
                let timeout = try run(
                    executable: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["10"],
                    input: Data(),
                    timeout: 0.05,
                    root: root,
                    onProcessStarted: configuration.onProcessStarted
                )
                return blocked(mode, command, timeout.exitStatus, timeout.standardError)
            }

            let positive = try ssh(
                mode: mode,
                configuration: configuration,
                config: config,
                root: root,
                port: port,
                identity: clientKey,
                knownHosts: knownHosts
            )
            guard positive.exitStatus == 0,
                  positive.standardOutput == "pinemeter-preflight-output\n" else {
                let serverDiagnostic = serverLog.map { sanitized(read($0), root: root) } ?? ""
                return blocked(
                    mode,
                    command,
                    positive.exitStatus,
                    "authentication failed: \(sanitized(positive.standardError, root: root))" +
                        (serverDiagnostic.isEmpty ? "" : " | server: \(serverDiagnostic)")
                )
            }

            let wrongPin = try ssh(
                mode: mode,
                configuration: configuration,
                config: config,
                root: root,
                port: port,
                identity: clientKey,
                knownHosts: wrongKnownHosts
            )
            let wrongClient = try ssh(
                mode: mode,
                configuration: configuration,
                config: config,
                root: root,
                port: port,
                identity: wrongClientKey,
                knownHosts: knownHosts
            )
            let wrongPinRefused = wrongPin.exitStatus != 0
            let wrongClientRefused = wrongClient.exitStatus != 0
            let reason = wrongPinRefused && wrongClientRefused
                ? "real authentication and both refusal controls passed"
                : "security control failed: wrongPinRefused=\(wrongPinRefused) wrongClientKeyRefused=\(wrongClientRefused)"

            return Attempt(
                mode: mode,
                command: command,
                exitStatus: positive.exitStatus,
                authenticated: true,
                wrongPinRefused: wrongPinRefused,
                wrongClientKeyRefused: wrongClientRefused,
                reason: reason
            )
        } catch {
            return Attempt(
                mode: mode,
                command: command,
                exitStatus: 1,
                authenticated: false,
                wrongPinRefused: false,
                wrongClientKeyRefused: false,
                reason: sanitized(error.localizedDescription, root: root),
                harnessError: configuration.fault == .setupFailure
            )
        }
    }

    private struct CommandResult {
        let exitStatus: Int32
        let standardOutput: String
        let standardError: String
    }

    private static func ssh(
        mode: Mode,
        configuration: Configuration,
        config: URL,
        root: URL,
        port: UInt16,
        identity: URL,
        knownHosts: URL
    ) throws -> CommandResult {
        var arguments = [
            "-F", "/dev/null",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHosts.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "KnownHostsCommand=none",
            "-o", "VerifyHostKeyDNS=no",
            "-o", "UpdateHostKeys=no",
            "-o", "HostKeyAlias=pinemeter-fixture",
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
            "-o", "ConnectTimeout=2",
            "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=1",
            "-o", "ServerAliveCountMax=1",
            "-i", identity.path,
            "-l", NSUserName(),
        ]
        if mode == .standalone {
            arguments += ["-p", String(port)]
        } else {
            arguments += [
                "-o",
                "ProxyCommand=exec \(shellQuote(configuration.sshd.path)) -i -e -f \(shellQuote(config.path))",
            ]
        }
        arguments += ["--", "127.0.0.1", "pinemeter-preflight probe"]
        return try run(
            executable: configuration.ssh,
            arguments: arguments,
            input: Data("pinemeter-preflight-input\n".utf8),
            timeout: configuration.commandTimeout,
            root: root,
            onProcessStarted: configuration.onProcessStarted
        )
    }

    private static func run(
        executable: URL,
        arguments: [String],
        input: Data,
        timeout: TimeInterval,
        root: URL,
        onProcessStarted: ((pid_t) -> Void)? = nil
    ) throws -> CommandResult {
        let stdout = root.appendingPathComponent("stdout-\(UUID().uuidString)")
        let stderr = root.appendingPathComponent("stderr-\(UUID().uuidString)")
        try write("", to: stdout, permissions: 0o600)
        try write("", to: stderr, permissions: 0o600)
        let stdoutHandle = try FileHandle(forWritingTo: stdout)
        let stderrHandle = try FileHandle(forWritingTo: stderr)
        let inputPipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw error
        }
        onProcessStarted?(process.processIdentifier)
        try? inputPipe.fileHandleForWriting.write(contentsOf: input)
        try? inputPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let timedOut = process.isRunning
        if timedOut {
            stop(process)
        } else {
            process.waitUntilExit()
        }
        try? stdoutHandle.close()
        try? stderrHandle.close()

        return CommandResult(
            exitStatus: timedOut ? 124 : process.terminationStatus,
            standardOutput: read(stdout),
            standardError: timedOut ? "authentication timeout" : read(stderr)
        )
    }

    private static func launch(
        executable: URL,
        arguments: [String],
        standardError: URL,
        onProcessStarted: ((pid_t) -> Void)? = nil
    ) throws -> Process {
        try write("", to: standardError, permissions: 0o600)
        let errorHandle = try FileHandle(forWritingTo: standardError)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        process.terminationHandler = { _ in try? errorHandle.close() }
        try process.run()
        onProcessStarted?(process.processIdentifier)
        return process
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func unusedLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func sshdConfiguration(
        root: URL,
        hostKey: URL,
        authorizedKeys: URL,
        port: UInt16
    ) -> String {
        """
        AddressFamily inet
        ListenAddress 127.0.0.1:\(port)
        HostKey \(quotedConfig(hostKey.path))
        AuthorizedKeysFile \(quotedConfig(authorizedKeys.path))
        PidFile \(quotedConfig(root.appendingPathComponent("sshd.pid").path))
        AllowUsers \(NSUserName())
        AuthenticationMethods publickey
        PubkeyAuthentication yes
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        AllowAgentForwarding no
        AllowTcpForwarding no
        AllowStreamLocalForwarding no
        X11Forwarding no
        PermitUserRC no
        PermitTTY no
        PermitTunnel no
        PermitRootLogin no
        StrictModes yes
        PrintMotd no
        PrintLastLog no
        LogLevel VERBOSE
        """
    }

    private static func publicKey(at url: URL) throws -> String {
        let fields = try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard fields.count >= 2 else { throw CocoaError(.fileReadCorruptFile) }
        return "\(fields[0]) \(fields[1])"
    }

    private static func write(_ string: String, to url: URL, permissions: Int) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(string.utf8),
            attributes: [.posixPermissions: permissions]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func read(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        return String(decoding: (try? handle.read(upToCount: 65_536)) ?? Data(), as: UTF8.self)
    }

    private static func blocked(_ mode: Mode, _ command: String, _ exitStatus: Int32, _ reason: String) -> Attempt {
        Attempt(
            mode: mode,
            command: command,
            exitStatus: exitStatus,
            authenticated: false,
            wrongPinRefused: false,
            wrongClientKeyRefused: false,
            reason: reason.isEmpty ? "OpenSSH attempt failed without diagnostic output" : reason
        )
    }

    private enum FixtureError: LocalizedError {
        case setupFailure

        var errorDescription: String? {
            "injected setup failure"
        }
    }

    private static func sanitized(_ text: String, root: URL) -> String {
        let collapsed = text
            .replacingOccurrences(of: root.path, with: "<fixture>")
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " | ")
        return String(collapsed.prefix(1_024))
    }

    private static func quotedConfig(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func escapeAuthorizedCommand(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

#if !PINEMETER_SSH_PREFLIGHT_MAIN
extension SSHFixture {
    enum IntegrationError: LocalizedError {
        case blocked(String)
        case invalidHarness(String)

        var errorDescription: String? {
            switch self {
            case .blocked(let reason): "BLOCKED: \(reason)"
            case .invalidHarness(let reason): reason
            }
        }
    }

    final class Integration: @unchecked Sendable {
        let root: URL
        let stateDirectory: URL
        let daemonPID: pid_t
        let host: RemoteHost
        let secret: RemoteHostSecret
        let transportConfiguration: RemoteSSHTransportTestConfiguration
        let daemonAddress: String

        private let daemon: Process
        private let sshd: Process?

        fileprivate init(
            root: URL,
            stateDirectory: URL,
            daemon: Process,
            sshd: Process?,
            host: RemoteHost,
            secret: RemoteHostSecret,
            transportConfiguration: RemoteSSHTransportTestConfiguration,
            daemonAddress: String
        ) {
            self.root = root
            self.stateDirectory = stateDirectory
            self.daemon = daemon
            self.sshd = sshd
            daemonPID = daemon.processIdentifier
            self.host = host
            self.secret = secret
            self.transportConfiguration = transportConfiguration
            self.daemonAddress = daemonAddress
        }

        func cleanup() {
            if let sshd { SSHFixture.stop(sshd) }
            SSHFixture.stop(daemon)
            try? FileManager.default.removeItem(at: root)
        }

        func pick(role: String = "execution", caller: String = "codex") async throws -> [String: Any] {
            let value = try await callTool("pick", arguments: ["role": role, "caller": caller])
            guard let decision = value as? [String: Any] else {
                throw IntegrationError.invalidHarness("daemon pick response invalid")
            }
            return decision
        }

        func callTool(_ name: String, arguments: [String: Any] = [:]) async throws -> Any {
            let body: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": name, "arguments": arguments],
            ]
            var request = URLRequest(url: URL(string: "http://\(daemonAddress)/mcp")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = envelope["result"] as? [String: Any],
                  let content = result["content"] as? [[String: Any]],
                  result["isError"] as? Bool != true,
                  let text = content.first?["text"] as? String
            else { throw IntegrationError.invalidHarness("daemon tool response invalid") }
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? text
        }

        func armFault(_ name: String) throws {
            guard ["import-before", "import-after", "malicious-stdout", "malicious-stderr"].contains(name) else {
                throw IntegrationError.invalidHarness("unknown integration fault")
            }
            guard FileManager.default.createFile(
                atPath: root.appendingPathComponent(name).path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else { throw IntegrationError.invalidHarness("integration fault could not be armed") }
        }
    }

    static func makeIntegration(
        daemon executable: URL,
        mode: Mode = ProcessInfo.processInfo.environment["PINEMETER_SSH_INTEGRATION_MODE"] == Mode.proxyCommand.rawValue
            ? .proxyCommand : .standalone
    ) throws -> Integration {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw IntegrationError.blocked("pinemeterd integration binary unavailable")
        }
        let base = ProcessInfo.processInfo.environment["PINEMETER_SSH_INTEGRATION_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let unresolvedRoot = base.appendingPathComponent("PinemeterSSHIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unresolvedRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        // pinemeterd's state-directory validation rejects any symlink path
        // component (it defends the credential store against symlink-swap
        // attacks). macOS temp roots (/tmp, $TMPDIR under /var/folders) are
        // themselves symlinks, so resolve to the real path here -- the
        // production deployment target (a real Linux host) never has this
        // indirection, so this is purely a macOS test-harness accommodation.
        // URL.resolvingSymlinksInPath() deliberately leaves /tmp and /var
        // unresolved for legacy compatibility, so use realpath(3) directly.
        guard let resolved = realpath(unresolvedRoot.path, nil) else {
            throw IntegrationError.invalidHarness("fixture root could not be resolved")
        }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        var daemon: Process?
        var server: Process?
        do {
            let state = root.appendingPathComponent("state", isDirectory: true)
            try FileManager.default.createDirectory(
                at: state,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let daemonLog = root.appendingPathComponent("daemon.log")
            let daemonProcess = try launch(
                executable: executable,
                arguments: [
                    "serve", "--state-dir", state.path,
                    "--listen", "127.0.0.1:0",
                    "--api-key-mode", "none",
                    "--live-polling=false",
                    "--poll-interval=0s",
                    "--poll-jitter=0s",
                ],
                standardError: daemonLog
            )
            daemon = daemonProcess
            let runtime = state.appendingPathComponent("runtime.json")
            let runtimeDeadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: runtime.path),
                  daemonProcess.isRunning,
                  Date() < runtimeDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard daemonProcess.isRunning,
                  let runtimeData = try? Data(contentsOf: runtime),
                  let runtimeObject = try? JSONSerialization.jsonObject(with: runtimeData) as? [String: Any],
                  let address = runtimeObject["address"] as? String
            else {
                throw IntegrationError.invalidHarness("pinemeterd serve did not become ready")
            }

            let hostKey = root.appendingPathComponent("host_key")
            let clientKey = root.appendingPathComponent("client_key")
            for key in [hostKey, clientKey] {
                let generated = try run(
                    executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                    arguments: ["-q", "-t", "ed25519", "-N", "", "-f", key.path],
                    input: Data(),
                    timeout: 5,
                    root: root
                )
                guard generated.exitStatus == 0 else {
                    throw IntegrationError.blocked("synthetic SSH key generation failed")
                }
            }

            let wrapper = root.appendingPathComponent("authorized-command")
            try write(
                """
                #!/bin/sh
                set -eu
                case "${SSH_ORIGINAL_COMMAND-}" in
                  'pinemeterd import --stdin')
                    if [ -f \(shellQuote(root.appendingPathComponent("import-before").path)) ]; then
                      rm -f \(shellQuote(root.appendingPathComponent("import-before").path))
                      exit 137
                    fi
                    if [ -f \(shellQuote(root.appendingPathComponent("import-after").path)) ]; then
                      rm -f \(shellQuote(root.appendingPathComponent("import-after").path))
                      \(shellQuote(executable.path)) import --stdin --state-dir \(shellQuote(state.path))
                      exit 137
                    fi
                    exec \(shellQuote(executable.path)) import --stdin --state-dir \(shellQuote(state.path))
                    ;;
                  'pinemeterd status')
                    if [ -f \(shellQuote(root.appendingPathComponent("malicious-stdout").path)) ]; then
                      rm -f \(shellQuote(root.appendingPathComponent("malicious-stdout").path))
                      printf '%s\\n' '{"schemaVersion":1,"acceptedGeneration":1,"observedGeneration":1,"accounts":[],"credential":"synthetic-secret-value"}'
                      exit 0
                    fi
                    if [ -f \(shellQuote(root.appendingPathComponent("malicious-stderr").path)) ]; then
                      rm -f \(shellQuote(root.appendingPathComponent("malicious-stderr").path))
                      printf '%s\\n' 'synthetic-secret-value' >&2
                      exit 65
                    fi
                    exec \(shellQuote(executable.path)) status --state-dir \(shellQuote(state.path))
                    ;;
                  *) exit 126 ;;
                esac
                """,
                to: wrapper,
                permissions: 0o700
            )
            let authorizedKeys = root.appendingPathComponent("authorized_keys")
            try write(
                "restrict,command=\"\(escapeAuthorizedCommand(wrapper.path))\" \(try publicKey(at: clientKey.appendingPathExtension("pub")))\n",
                to: authorizedKeys,
                permissions: 0o600
            )
            let port = try unusedLoopbackPort()
            let sshdConfig = root.appendingPathComponent("sshd_config")
            try write(
                sshdConfiguration(root: root, hostKey: hostKey, authorizedKeys: authorizedKeys, port: port),
                to: sshdConfig,
                permissions: 0o600
            )
            if mode == .standalone {
                let serverLog = root.appendingPathComponent("sshd.log")
                let process = try launch(
                    executable: URL(fileURLWithPath: "/usr/sbin/sshd"),
                    arguments: ["-D", "-e", "-f", sshdConfig.path],
                    standardError: serverLog
                )
                server = process
                Thread.sleep(forTimeInterval: 0.15)
                guard process.isRunning else {
                    throw IntegrationError.blocked("sshd exited before integration authentication: \(sanitized(read(serverLog), root: root))")
                }
            }

            let id = UUID(uuidString: "14140714-0714-0714-0714-071407140714")!
            let host = RemoteHost(
                id: id,
                host: "127.0.0.1",
                sshUser: NSUserName(),
                keyPath: clientKey.path,
                secretReference: "integration",
                pinnedHostKeyFingerprint: "fixture"
            )
            let secret = RemoteHostSecret(
                identity: try Data(contentsOf: clientKey),
                pinnedHostKey: try publicKey(at: hostKey.appendingPathExtension("pub"))
            )
            let quotedSSHD = shellQuote("/usr/sbin/sshd")
            let proxy = mode == .proxyCommand
                ? "exec \(quotedSSHD) -i -e -f \(shellQuote(sshdConfig.path))"
                : nil
            let transport = RemoteSSHTransportTestConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                operationRoot: root,
                timeoutNanoseconds: 10_000_000_000,
                terminationGraceNanoseconds: 100_000_000,
                maxOutputBytes: 65_536,
                port: mode == .standalone ? port : nil,
                proxyCommand: proxy,
                commandWrapper: nil
            )
            return Integration(
                root: root,
                stateDirectory: state,
                daemon: daemonProcess,
                sshd: server,
                host: host,
                secret: secret,
                transportConfiguration: transport,
                daemonAddress: address
            )
        } catch {
            if let server { stop(server) }
            if let daemon { stop(daemon) }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
#endif

#if PINEMETER_SSH_PREFLIGHT_MAIN
@main
private struct SSHPreflightMain {
    static func main() {
        let report = SSHFixture.runPreflight(configuration: .fromEnvironment())
        do {
            try report.writeIfRequested()
        } catch {
            FileHandle.standardError.write(Data("failed to write preflight result\n".utf8))
            exit(1)
        }
    }
}
#endif
