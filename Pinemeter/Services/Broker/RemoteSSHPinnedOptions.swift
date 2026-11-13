import Foundation

enum RemoteSSHPinnedOptions {
    static func alias(for hostID: UUID) -> String {
        "pinemeter-\(hostID.uuidString.lowercased())"
    }

    static func arguments(knownHostsPath: String, alias: String) -> [String] {
        [
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
    }

    static func knownHostsLine(alias: String, record: String) -> String {
        "\(alias) \(record)\n"
    }
}
