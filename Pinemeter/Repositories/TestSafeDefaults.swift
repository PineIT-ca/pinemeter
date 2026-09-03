//
//  TestSafeDefaults.swift
//  Pinemeter
//

import Foundation

/// Resolves the `UserDefaults` a repository persists into, keeping test runs
/// out of the real `ca.pineit.Pinemeter` domain.
///
/// Two distinct hazards live here. The credential repositories persist a
/// sanitized status keyed by account, and the tests key accounts by a fresh
/// UUID per run, so writes to the real domain accumulate permanently: a live
/// install had collected 1458 of them. `SettingsRepository` writes a fixed
/// pair of keys instead, so it cannot accumulate, but a test that reaches the
/// real domain overwrites the developer's live settings.
///
/// This is the same guard `BrokerStorePaths.isRunningTests` applies to the
/// file-backed stores. Under XCTest an app-domain `UserDefaults` is redirected
/// to a suite private to this process; an explicitly injected suite is passed
/// through untouched. A shipped build never sees `XCTestCase`, so production
/// always gets exactly what it asked for.
///
/// The suite name carries the process id because the scheme runs the bundle
/// parallelized: several host-app workers run at once, and a fixed name plus
/// a per-process wipe means one worker's wipe can delete a value another
/// worker just wrote and is about to read back.
enum TestSafeDefaults {
    static let suiteNamePrefix = "PinemeterTests.IsolatedDefaults"
    static let testSuiteName = "\(suiteNamePrefix).\(ProcessInfo.processInfo.processIdentifier)"

    static var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    /// The value repository initializers use as their default argument, so the
    /// uninjected path does not depend on recognizing `.standard` at all.
    static var standardOrIsolated: UserDefaults {
        isRunningTests ? (isolatedTestDefaults ?? .standard) : .standard
    }

    /// Safety net for an explicitly passed app-domain `UserDefaults`. Tests do
    /// pass `.standard` directly (`userDefaults ?? .standard` fallbacks), and
    /// those writes have to be redirected too.
    static func resolve(_ requested: UserDefaults) -> UserDefaults {
        guard isRunningTests, writesToApplicationDomain(requested) else { return requested }
        return isolatedTestDefaults ?? requested
    }

    /// Identity against `.standard` catches the common case. It cannot catch
    /// `UserDefaults()`, a separate instance over the same domain, because
    /// `UserDefaults` does not override equality and exposes no suite name, so
    /// that case is settled by writing a probe key and seeing whether the real
    /// domain shows it. (The other route in is already closed: Foundation's
    /// `init(suiteName:)` returns nil for the app's own bundle id.) Only ever
    /// runs under XCTest, and the probe is removed from both domains either
    /// way.
    private static func writesToApplicationDomain(_ defaults: UserDefaults) -> Bool {
        if defaults == .standard { return true }
        // The key carries the pid so cleanup can preserve probes owned by
        // live parallel workers, plus a UUID so one process can probe safely
        // from concurrent callers.
        let probeKey = "\(probeKeyPrefix)\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        defaults.set(true, forKey: probeKey)
        let reachesApplicationDomain = UserDefaults.standard.object(forKey: probeKey) != nil
        defaults.removeObject(forKey: probeKey)
        // Only when it actually landed there. The removal is otherwise a write
        // against the developer's real domain for no reason, once per resolve.
        if reachesApplicationDomain {
            UserDefaults.standard.removeObject(forKey: probeKey)
        }
        return reachesApplicationDomain
    }

    static let probeKeyPrefix = "\(suiteNamePrefix).domainProbe."

    /// `static let` is initialized once per process, so the setup happens on
    /// first use rather than on every repository init. The opening wipe covers
    /// a recycled process id; the `atexit` wipe keeps the suite from being
    /// left behind in `~/Library/Preferences` after the run.
    private static let isolatedTestDefaults: UserDefaults? = {
        guard let defaults = UserDefaults(suiteName: testSuiteName) else { return nil }
        defaults.removePersistentDomain(forName: testSuiteName)
#if DEBUG
        sweepSuiteFilesOfDeadProcesses()
        sweepAbandonedProbeKeys()
        atexit { TestSafeDefaults.discardTestSuite() }
#endif
        return defaults
    }()

#if DEBUG
    /// `cfprefsd` can rewrite a suite's plist after the `atexit` removal, so a
    /// run can still leave an empty file behind. Sweeping on the way in keeps
    /// that bounded. Files whose process is still alive belong to sibling
    /// workers of this run and are left alone.
    private static func sweepSuiteFilesOfDeadProcesses() {
        guard let preferences = preferencesDirectory,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: preferences.path)
        else { return }
        let prefix = "\(suiteNamePrefix)."
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(".plist") {
            let pidText = entry.dropFirst(prefix.count).dropLast(".plist".count)
            guard let pid = pid_t(pidText), pid != ProcessInfo.processInfo.processIdentifier else {
                continue
            }
            if isProcessAlive(pid) { continue }
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent(entry))
        }
    }

    /// `cfprefsd` is a separate process, so a probe write it has already
    /// committed survives the writer being killed between the write and its
    /// removal (an `xcodebuild` timeout, a crashing runner). The keys are
    /// UUID-suffixed, so without this they would accumulate in the real domain
    /// exactly like the status keys this file exists to stop. Sweeping on the
    /// way in bounds that to a single run.
    static func sweepAbandonedProbeKeys() {
        let standard = UserDefaults.standard
        for key in standard.dictionaryRepresentation().keys where key.hasPrefix(probeKeyPrefix) {
            if let pid = probeOwnerPID(key), isProcessAlive(pid) { continue }
            standard.removeObject(forKey: key)
        }
    }

    private static func probeOwnerPID(_ key: String) -> pid_t? {
        let suffix = key.dropFirst(probeKeyPrefix.count)
        guard let separator = suffix.firstIndex(of: ".") else { return nil }
        return pid_t(suffix[..<separator])
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        // ESRCH means no such process; EPERM means it exists but is not ours.
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static var preferencesDirectory: URL? {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences", isDirectory: true)
    }

    /// Removes this process's suite, including the plist `cfprefsd` writes for
    /// it. Only ever touches this process's own file: sibling workers of the
    /// same run hold their own live suites, so sweeping by prefix would
    /// recreate the cross-worker deletion this design exists to avoid.
    private static func discardTestSuite() {
        let name = testSuiteName
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
        guard let preferences = preferencesDirectory else { return }
        try? FileManager.default.removeItem(
            at: preferences.appendingPathComponent("\(name).plist")
        )
    }
#endif
}
