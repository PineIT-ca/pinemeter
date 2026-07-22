import Foundation

struct AvailableUpdate: Equatable, Sendable {
    let version: String

    func isNewer(than currentVersion: String) -> Bool {
        version.compare(currentVersion, options: .numeric) == .orderedDescending
    }
}

protocol ReleaseCheckServiceProtocol: Actor {
    func latestRelease() async throws -> AvailableUpdate
}
