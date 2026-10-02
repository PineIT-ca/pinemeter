import Darwin
import Foundation

struct ImportAck: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let acceptedGeneration: UInt64
}

enum HostStatusProvider: String, Decodable, Equatable, Sendable {
    case claude
    case chatgpt
    case gemini
}

enum HostStatusVerdict: String, Decodable, Equatable, Sendable {
    case unpolled
    case ok
    case challenged
    case sessionKeyInvalid
    case rateLimited
    case error
}

struct HostAccountStatusDTO: Decodable, Equatable, Sendable {
    let provider: HostStatusProvider
    let id: String
    let verdict: HostStatusVerdict
    let observedAt: Date?
}

struct HostStatusDTO: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let acceptedGeneration: UInt64
    let observedGeneration: UInt64
    let observedAt: Date?
    let accounts: [HostAccountStatusDTO]
}

enum RemoteSSHTransportError: LocalizedError, Equatable {
    case invalidConfiguration
    case bundleTooLarge
    case invalidBundle
    case launchFailed
    case transportFailed
    case hostKeyMismatch
    case timedOut
    case cancelled
    case outputTooLarge
    case invalidResponse
    case generationMismatch
    case temporaryFileFailure

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Push failed: the remote host configuration is invalid."
        case .bundleTooLarge: "Push failed: the credential bundle is too large."
        case .invalidBundle: "Push failed: the credential bundle is invalid."
        case .launchFailed: "Push failed: SSH could not be started."
        case .transportFailed: "Push failed: SSH did not complete successfully."
        case .hostKeyMismatch: "Push failed: the host key does not match the pinned key. Verify the host key before configuring this host again."
        case .timedOut: "Push failed: SSH timed out."
        case .cancelled: "Push cancelled."
        case .outputTooLarge: "Push failed: the remote response was too large."
        case .invalidResponse: "Push failed: the remote response was invalid."
        case .generationMismatch: "Push failed: the remote host accepted an unexpected generation."
        case .temporaryFileFailure: "Push failed: secure temporary SSH files could not be created."
        }
    }
}

#if DEBUG
struct RemoteSSHTransportTestConfiguration: Sendable {
    var executableURL: URL
    var operationRoot: URL
    var timeoutNanoseconds: UInt64 = 2_000_000_000
    var terminationGraceNanoseconds: UInt64 = 100_000_000
    var maxOutputBytes: Int = 65_536
    var port: UInt16?
    var proxyCommand: String?
    var commandWrapper: String?
}
#endif

actor RemoteSSHTransport {
    private static let operationDirectoryPrefix = "pinemeter-ssh-"
    private static let importCommand = "pinemeterd import --stdin"
    private static let statusCommand = "pinemeterd status"
    private static let maxBundleBytes = 4 * 1_024 * 1_024

    private let secretRepository: RemoteHostSecretRepository
    private let configuration: Configuration

    init(secretRepository: RemoteHostSecretRepository = RemoteHostSecretRepository()) {
        self.secretRepository = secretRepository
        configuration = .production
    }

    static func removeStaleOperationDirectories(
        at operationRoot: URL = FileManager.default.temporaryDirectory
    ) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: operationRoot,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(operationDirectoryPrefix),
                  UUID(uuidString: String(name.dropFirst(operationDirectoryPrefix.count))) != nil,
                  let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

#if DEBUG
    init(
        secretRepository: RemoteHostSecretRepository = RemoteHostSecretRepository(),
        testing: RemoteSSHTransportTestConfiguration
    ) {
        self.secretRepository = secretRepository
        configuration = Configuration(
            executableURL: testing.executableURL,
            operationRoot: testing.operationRoot,
            timeoutNanoseconds: testing.timeoutNanoseconds,
            terminationGraceNanoseconds: testing.terminationGraceNanoseconds,
            maxOutputBytes: testing.maxOutputBytes,
            port: testing.port,
            proxyCommand: testing.proxyCommand,
            commandWrapper: testing.commandWrapper
        )
    }
#endif

    func importBundle(_ bundle: Data, host: RemoteHost) async throws -> ImportAck {
        let secret = try await secretRepository.load(reference: host.secretReference)
        return try await importBundle(bundle, host: host, secret: secret)
    }

    func importBundle(_ bundle: Data, host: RemoteHost, secret: RemoteHostSecret) async throws -> ImportAck {
        guard bundle.count <= Self.maxBundleBytes else { throw RemoteSSHTransportError.bundleTooLarge }
        let generation = try Self.bundleGeneration(bundle)
        let output = try await run(command: Self.importCommand, input: bundle, host: host, secret: secret)
        let acknowledgement: ImportAck = try Self.decodeClosedJSON(
            output,
            topLevelKeys: ["schemaVersion", "acceptedGeneration"]
        )
        guard acknowledgement.schemaVersion == 1 else { throw RemoteSSHTransportError.invalidResponse }
        guard acknowledgement.acceptedGeneration == generation else {
            throw RemoteSSHTransportError.generationMismatch
        }
        return acknowledgement
    }

    func fetchStatus(host: RemoteHost) async throws -> HostStatusDTO {
        let secret = try await secretRepository.load(reference: host.secretReference)
        return try await fetchStatus(host: host, secret: secret)
    }

    func fetchStatus(host: RemoteHost, secret: RemoteHostSecret) async throws -> HostStatusDTO {
        let output = try await run(command: Self.statusCommand, input: nil, host: host, secret: secret)
        let status: HostStatusDTO = try Self.decodeClosedJSON(
            output,
            topLevelKeys: ["schemaVersion", "acceptedGeneration", "observedGeneration", "observedAt", "accounts"],
            accountKeys: ["provider", "id", "verdict", "observedAt"]
        )
        guard status.schemaVersion == 1,
              status.accounts.count <= 256,
              status.accounts.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 })
        else { throw RemoteSSHTransportError.invalidResponse }
        return status
    }

    private func run(
        command: String,
        input: Data?,
        host: RemoteHost,
        secret: RemoteHostSecret
    ) async throws -> Data {
        try Task.checkCancellation()
        let normalizedHost: String
        let normalizedUser: String
        let pin: ParsedHostKey
        do {
            normalizedHost = try RemoteHostValidator.normalizedHost(host.host)
            normalizedUser = try RemoteHostValidator.normalizedSSHUser(host.sshUser)
            pin = try RemoteHostValidator.parsePinnedHostKey(secret.pinnedHostKey)
        } catch {
            throw RemoteSSHTransportError.invalidConfiguration
        }
        guard !secret.identity.isEmpty, secret.identity.count <= 1_048_576 else {
            throw RemoteSSHTransportError.invalidConfiguration
        }

        let operation = try makeOperationFiles(
            identity: secret.identity,
            pin: pin.record,
            alias: "pinemeter-\(host.id.uuidString.lowercased())"
        )
        defer { try? FileManager.default.removeItem(at: operation.directory) }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let termination = ProcessTermination()
        process.executableURL = configuration.executableURL
        process.arguments = arguments(
            host: normalizedHost,
            user: normalizedUser,
            identityPath: operation.identity.path,
            knownHostsPath: operation.knownHosts.path,
            alias: operation.alias,
            command: command
        )
        process.environment = [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin",
            "SSH_ASKPASS_REQUIRE": "never",
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { task in
            termination.finish(status: task.terminationStatus, reason: task.terminationReason)
        }

        let stdoutTask = Task.detached(priority: .utility) {
            try Self.drain(outputPipe.fileHandleForReading, limit: self.configuration.maxOutputBytes, process: process)
        }
        let stderrTask = Task.detached(priority: .utility) {
            try Self.drain(errorPipe.fileHandleForReading, limit: self.configuration.maxOutputBytes, process: process)
        }

        do {
            try process.run()
        } catch {
            Self.closePipesAfterLaunchFailure(inputPipe: inputPipe, outputPipe: outputPipe, errorPipe: errorPipe)
            _ = try? await stdoutTask.value
            _ = try? await stderrTask.value
            throw RemoteSSHTransportError.launchFailed
        }
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        let stdinTask = Task.detached(priority: .utility) {
            try Self.write(input, to: inputPipe.fileHandleForWriting, process: process)
        }

        do {
            let exit = try await waitForExit(process, termination: termination)
            let stdout = try await stdoutTask.value
            let stderr = try await stderrTask.value
            do {
                try await stdinTask.value
            } catch {
                guard exit.status != 0 else { throw error }
            }
            guard exit.reason == .exit, exit.status == 0 else {
                if Self.isHostKeyFailure(stderr) { throw RemoteSSHTransportError.hostKeyMismatch }
                throw RemoteSSHTransportError.transportFailed
            }
            return stdout
        } catch {
            await stop(process)
            if process.isRunning == false { _ = await termination.wait() }
            _ = try? await stdinTask.value
            _ = try? await stdoutTask.value
            _ = try? await stderrTask.value
            if error is CancellationError { throw RemoteSSHTransportError.cancelled }
            throw error
        }
    }

    private func waitForExit(_ process: Process, termination: ProcessTermination) async throws -> ProcessExit {
        let started = DispatchTime.now().uptimeNanoseconds
        while process.isRunning {
            if Task.isCancelled { throw CancellationError() }
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            if elapsed >= configuration.timeoutNanoseconds {
                throw RemoteSSHTransportError.timedOut
            }
            try await Task.sleep(nanoseconds: min(20_000_000, configuration.timeoutNanoseconds - elapsed))
        }
        return await termination.wait()
    }

    private func stop(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        let grace = configuration.terminationGraceNanoseconds
        await Task.detached(priority: .utility) {
            if grace > 0 { usleep(useconds_t(min(grace / 1_000, UInt64(useconds_t.max)))) }
        }.value
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func arguments(
        host: String,
        user: String,
        identityPath: String,
        knownHostsPath: String,
        alias: String,
        command: String
    ) -> [String] {
        var arguments = [
            "-F", "/dev/null",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "KnownHostsCommand=none",
            "-o", "VerifyHostKeyDNS=no",
            "-o", "UpdateHostKeys=no",
            "-o", "HostKeyAlias=\(alias)",
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
        ]
        if let port = configuration.port { arguments += ["-p", String(port)] }
        if let proxyCommand = configuration.proxyCommand {
            arguments += ["-o", "ProxyCommand=\(proxyCommand)"]
        }
        arguments += ["-i", identityPath, "-l", user, "--", host]
        if let wrapper = configuration.commandWrapper {
            arguments.append("\(wrapper) \(command)")
        } else {
            arguments.append(command)
        }
        return arguments
    }

    private func makeOperationFiles(identity: Data, pin: String, alias: String) throws -> OperationFiles {
        let directory = configuration.operationRoot.appendingPathComponent("\(Self.operationDirectoryPrefix)\(UUID().uuidString)")
        guard mkdir(directory.path, S_IRWXU) == 0, chmod(directory.path, S_IRWXU) == 0 else {
            throw RemoteSSHTransportError.temporaryFileFailure
        }
        do {
            let identityURL = directory.appendingPathComponent("identity")
            let knownHostsURL = directory.appendingPathComponent("known_hosts")
            try Self.writeExclusive(identity, to: identityURL)
            try Self.writeExclusive(Data("\(alias) \(pin)\n".utf8), to: knownHostsURL)
            return OperationFiles(
                directory: directory,
                identity: identityURL,
                knownHosts: knownHostsURL,
                alias: alias
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw RemoteSSHTransportError.temporaryFileFailure
        }
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw RemoteSSHTransportError.temporaryFileFailure }
        defer { close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw RemoteSSHTransportError.temporaryFileFailure
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), rawBuffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw RemoteSSHTransportError.temporaryFileFailure
                }
                written += count
            }
        }
    }

    private static func drain(_ handle: FileHandle, limit: Int, process: Process) throws -> Data {
        var output = Data()
        while let chunk = try handle.read(upToCount: 8_192), !chunk.isEmpty {
            guard output.count <= limit - chunk.count else {
                process.terminate()
                throw RemoteSSHTransportError.outputTooLarge
            }
            output.append(chunk)
        }
        return output
    }

    private static func write(_ input: Data?, to handle: FileHandle, process: Process) throws {
        defer { try? handle.close() }
        guard let input, !input.isEmpty else { return }
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try handle.write(contentsOf: input)
        } catch {
            process.terminate()
            throw RemoteSSHTransportError.transportFailed
        }
    }

    private static func closePipesAfterLaunchFailure(inputPipe: Pipe, outputPipe: Pipe, errorPipe: Pipe) {
        try? inputPipe.fileHandleForReading.close()
        try? inputPipe.fileHandleForWriting.close()
        try? outputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForWriting.close()
    }

    private static func bundleGeneration(_ data: Data) throws -> UInt64 {
        struct Header: Decodable { let generation: UInt64 }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.generation > 0 else {
            throw RemoteSSHTransportError.invalidBundle
        }
        return header.generation
    }

    private static func decodeClosedJSON<T: Decodable>(
        _ data: Data,
        topLevelKeys: Set<String>,
        accountKeys: Set<String>? = nil
    ) throws -> T {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: topLevelKeys),
              Set(dictionary.keys) == topLevelKeys.subtracting(["observedAt"])
                || Set(dictionary.keys) == topLevelKeys
        else { throw RemoteSSHTransportError.invalidResponse }
        if let accountKeys {
            guard let accounts = dictionary["accounts"] as? [[String: Any]],
                  accounts.allSatisfy({ account in
                      let keys = Set(account.keys)
                      return keys.isSubset(of: accountKeys)
                          && (keys == accountKeys || keys == accountKeys.subtracting(["observedAt"]))
                  })
            else { throw RemoteSSHTransportError.invalidResponse }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(T.self, from: data) else {
            throw RemoteSSHTransportError.invalidResponse
        }
        return decoded
    }

    private static func isHostKeyFailure(_ stderr: Data) -> Bool {
        guard let text = String(data: stderr, encoding: .utf8) else { return false }
        return text.contains("Host key verification failed")
            || text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
    }
}

private struct Configuration: Sendable {
    let executableURL: URL
    let operationRoot: URL
    let timeoutNanoseconds: UInt64
    let terminationGraceNanoseconds: UInt64
    let maxOutputBytes: Int
    let port: UInt16?
    let proxyCommand: String?
    let commandWrapper: String?

    static let production = Configuration(
        executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
        operationRoot: FileManager.default.temporaryDirectory,
        timeoutNanoseconds: 30_000_000_000,
        terminationGraceNanoseconds: 1_000_000_000,
        maxOutputBytes: 65_536,
        port: nil,
        proxyCommand: nil,
        commandWrapper: nil
    )
}

private struct OperationFiles {
    let directory: URL
    let identity: URL
    let knownHosts: URL
    let alias: String
}

private struct ProcessExit: Sendable {
    let status: Int32
    let reason: Process.TerminationReason
}

private final class ProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ProcessExit?
    private var continuation: CheckedContinuation<ProcessExit, Never>?

    func finish(status: Int32, reason: Process.TerminationReason) {
        let exit = ProcessExit(status: status, reason: reason)
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = exit
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: exit)
    }

    func wait() async -> ProcessExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
