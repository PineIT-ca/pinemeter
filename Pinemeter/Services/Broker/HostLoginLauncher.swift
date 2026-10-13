import AppKit
import Darwin
import Foundation
import os

struct HostLoginLaunchRequest: Equatable, Sendable {
    let hostID: UUID
    let host: String
    let sshUser: String
    let keyPath: String
    let pinnedHostKeyRecord: String
    let loginWord: String
    let accountID: String
}

enum HostLoginLaunchError: LocalizedError, Equatable {
    case invalidHost
    case invalidUser
    case invalidAccount
    case invalidPinnedHostKey
    case invalidKeyPath
    case keyUnreadable(path: String)
    case unsafeTemporaryDirectory
    case temporaryFileFailure
    case terminalUnavailable
    case openFailed

    var errorDescription: String? {
        switch self {
        case .invalidHost: "The remote host is invalid."
        case .invalidUser: "The SSH user is invalid."
        case .invalidAccount: "The account cannot use host login."
        case .invalidPinnedHostKey: "The pinned SSH host key is invalid. Remove and add the host again."
        case .invalidKeyPath: "The SSH key path is invalid."
        case let .keyUnreadable(path):
            "The SSH key at \(path) is missing or unreadable. Restore it, or remove and add the host again."
        case .unsafeTemporaryDirectory: "The temporary directory path is unsafe."
        case .temporaryFileFailure: "The login session files could not be created."
        case .terminalUnavailable: "Terminal could not be found."
        case .openFailed: "Terminal could not open the login session."
        }
    }
}

protocol HostLoginTerminalOpening: Sendable {
    func open(script: URL) async throws
}

protocol HostLoginLaunching: Sendable {
    func launch(_ request: HostLoginLaunchRequest) async throws
}

struct TerminalAppOpener: HostLoginTerminalOpening {
    static let bundleIdentifier = "com.apple.Terminal"

    func open(script: URL) async throws {
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }
        try await Self.openInTerminal(script: script)
    }

    @MainActor
    private static func openInTerminal(script: URL) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { throw HostLoginLaunchError.terminalUnavailable }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration)
    }
}

struct NullHostLoginLauncher: HostLoginLaunching {
    func launch(_ request: HostLoginLaunchRequest) async throws {}
}

actor HostLoginLauncher: HostLoginLaunching {
    private let opener: any HostLoginTerminalOpening
    private let operationRoot: URL
    private let sshExecutable: String
    private let logger = Logger(subsystem: "com.pinemeter", category: "HostLogin")
    private static let directoryPrefix = "pinemeter-login-"

    init(opener: any HostLoginTerminalOpening, operationRoot: URL = FileManager.default.temporaryDirectory,
         sshExecutable: String = "/usr/bin/ssh") {
        self.opener = opener
        self.operationRoot = operationRoot
        self.sshExecutable = sshExecutable
    }

    func launch(_ request: HostLoginLaunchRequest) async throws {
        guard let host = try? RemoteHostValidator.normalizedHost(request.host)
        else { throw HostLoginLaunchError.invalidHost }
        guard let user = try? RemoteHostValidator.normalizedSSHUser(request.sshUser)
        else { throw HostLoginLaunchError.invalidUser }
        guard let pin = try? RemoteHostValidator.parsePinnedHostKey(request.pinnedHostKeyRecord)
        else { throw HostLoginLaunchError.invalidPinnedHostKey }
        guard let command = HostLoginGrammar.remoteCommand(loginWord: request.loginWord, accountID: request.accountID)
        else { throw HostLoginLaunchError.invalidAccount }
        let fileManager = FileManager.default
        guard let keyPath = Self.expandedKeyPath(request.keyPath, home: fileManager.homeDirectoryForCurrentUser)
        else { throw HostLoginLaunchError.invalidKeyPath }
        guard fileManager.isReadableFile(atPath: keyPath),
              let keyValues = try? URL(fileURLWithPath: keyPath).resourceValues(forKeys: [.isRegularFileKey]),
              keyValues.isRegularFile == true
        else { throw HostLoginLaunchError.keyUnreadable(path: keyPath) }
        guard !operationRoot.path.contains("%"), !operationRoot.path.contains("$"),
              operationRoot.path.unicodeScalars.allSatisfy({
                  !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
              })
        else { throw HostLoginLaunchError.unsafeTemporaryDirectory }

        let directory = operationRoot.appendingPathComponent("\(Self.directoryPrefix)\(UUID().uuidString)")
        guard mkdir(directory.path, S_IRWXU) == 0 else { throw HostLoginLaunchError.temporaryFileFailure }
        do {
            guard chmod(directory.path, S_IRWXU) == 0 else { throw HostLoginLaunchError.temporaryFileFailure }
            let alias = RemoteSSHPinnedOptions.alias(for: request.hostID)
            let knownHosts = directory.appendingPathComponent("known_hosts")
            let script = directory.appendingPathComponent("login.command")
            try Self.writeExclusive(Data(RemoteSSHPinnedOptions.knownHostsLine(alias: alias, record: pin.record).utf8),
                                    to: knownHosts, mode: S_IRUSR | S_IWUSR)
            let contents = HostLoginScript.build(
                sshExecutable: sshExecutable,
                options: RemoteSSHPinnedOptions.arguments(knownHostsPath: knownHosts.path, alias: alias),
                keyPath: keyPath, user: user, host: host, remoteCommand: command,
                operationDirectory: directory.path,
                banner: "Pinemeter: logging in \(request.loginWord == "claude" ? "Claude" : "Codex") account \(request.accountID) on \(host)."
            )
            try Self.writeExclusive(Data(contents.utf8), to: script, mode: S_IRWXU)
            guard removexattr(script.path, "com.apple.quarantine", 0) == 0 || errno == ENOATTR
            else { throw HostLoginLaunchError.temporaryFileFailure }
            do {
                try await opener.open(script: script)
            } catch HostLoginLaunchError.terminalUnavailable {
                throw HostLoginLaunchError.terminalUnavailable
            } catch {
                throw HostLoginLaunchError.openFailed
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        logger.info("Opened login session: host=\(request.hostID.uuidString, privacy: .public) provider=\(request.loginWord, privacy: .public) account=\(request.accountID, privacy: .private)")
    }

    static func expandedKeyPath(_ path: String, home: URL) -> String? {
        guard path.hasPrefix("/") || path.hasPrefix("~/"),
              !path.contains("%"), !path.contains("$"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        let expanded = path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    static func removeStaleLoginDirectories(at root: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))
        else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(directoryPrefix),
                  UUID(uuidString: String(name.dropFirst(directoryPrefix.count))) != nil,
                  let values = try? entry.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > 3600
            else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func writeExclusive(_ data: Data, to url: URL, mode: mode_t) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw HostLoginLaunchError.temporaryFileFailure }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode) == 0 else { throw HostLoginLaunchError.temporaryFileFailure }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                if count <= 0 {
                    if count < 0 && errno == EINTR { continue }
                    throw HostLoginLaunchError.temporaryFileFailure
                }
                written += count
            }
        }
    }
}

enum HostLoginGrammar {
    private static let uuid = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    private static let account = "\(uuid)|user-[A-Za-z0-9_-]{1,64}|legacy-chatgpt"

    static func remoteCommand(loginWord: String, accountID: String) -> String? {
        guard loginWord == "claude" || loginWord == "codex",
              accountID.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }),
              accountID != "legacy-chatgpt",
              accountID.range(of: "\\A(?:\(loginWord == "claude" ? uuid : account))\\z", options: .regularExpression) != nil
        else { return nil }
        let command = "pinemeterd login \(loginWord) --account \(accountID)"
        guard command.utf8.count <= 256,
              command.range(of: "\\Apinemeterd login (claude|codex)(?: --account (\(account)))?\\z", options: .regularExpression) != nil
        else { return nil }
        return command
    }
}

enum HostLoginScript {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func build(sshExecutable: String, options: [String], keyPath: String, user: String,
                      host: String, remoteCommand: String, operationDirectory: String, banner: String) -> String {
        let arguments = [sshExecutable] + options + ["-i", keyPath, "-l", user, "--", host, remoteCommand]
        return [
            "#!/bin/sh",
            "# Pinemeter host login. Holds no secret. Deletes its own directory on exit.",
            "dir=\(shellQuote(operationDirectory))",
            "trap '/bin/rm -rf -- \"$dir\"' EXIT",
            "trap 'exit 130' HUP INT TERM",
            "printf '%s\\n' \(shellQuote(banner))",
            arguments.map(shellQuote).joined(separator: " "),
            "status=$?",
            "printf '\\nLogin session ended (exit %s). Press Return to close this window.\\n' \"$status\"",
            "read -r _ || true",
            "",
        ].joined(separator: "\n")
    }
}
