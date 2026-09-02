import Foundation

struct AvailableUpdate: Equatable, Sendable {
    let version: String

    func isNewer(than currentVersion: String) -> Bool {
        let candidate = version.split(separator: "-", maxSplits: 1)
        let current = currentVersion.split(separator: "-", maxSplits: 1)
        let releaseComparison = candidate[0].compare(current[0], options: .numeric)

        if releaseComparison != .orderedSame {
            return releaseComparison == .orderedDescending
        }
        if candidate.count != current.count {
            return candidate.count < current.count
        }
        guard candidate.count == 2 else { return false }
        return candidate[1].compare(current[1], options: .numeric) == .orderedDescending
    }
}

protocol ReleaseCheckServiceProtocol: Actor {
    func latestRelease() async throws -> AvailableUpdate
}
