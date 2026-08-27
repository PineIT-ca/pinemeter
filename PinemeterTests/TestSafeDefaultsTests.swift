//
//  TestSafeDefaultsTests.swift
//  PinemeterTests
//

import XCTest
@testable import Pinemeter

/// Pins the guard that keeps test runs out of the real `ca.pineit.Pinemeter`
/// domain. Without it, every repository built without an injected suite writes
/// there: a permanent status key per test account for the credential
/// repositories, and the developer's live settings for `SettingsRepository`.
final class TestSafeDefaultsTests: XCTestCase {
    private static let appStorageCall = try! NSRegularExpression(
        pattern: #"(?m)^[\t ]*@AppStorage\s*\((?:[^()]|\([^()]*\))*\)"#
    )

    func test_uninjectedRepositoriesNeverWriteStatusToStandardDefaults() async throws {
        let chatGPTAccount = "TestSafeDefaultsTests.\(UUID().uuidString)"
        let geminiAccount = "TestSafeDefaultsTests.\(UUID().uuidString)"

        _ = await ChatGPTSessionRepository().validate(account: chatGPTAccount)
        _ = await GeminiAPIKeyRepository().validate(account: geminiAccount)

        let standardDomain = UserDefaults.standard
        XCTAssertNil(standardDomain.object(forKey: "ChatGPTSessionRepository.status.\(chatGPTAccount)"))
        XCTAssertNil(standardDomain.object(forKey: "GeminiAPIKeyRepository.status.\(geminiAccount)"))

        let isolated = try XCTUnwrap(UserDefaults(suiteName: TestSafeDefaults.testSuiteName))
        XCTAssertNotNil(isolated.object(forKey: "ChatGPTSessionRepository.status.\(chatGPTAccount)"))
        XCTAssertNotNil(isolated.object(forKey: "GeminiAPIKeyRepository.status.\(geminiAccount)"))
    }

    /// The settings keys are fixed, so they cannot accumulate. The damage is
    /// different: an uninjected `SettingsRepository` in a test would overwrite
    /// whatever the developer has configured in the real app.
    func test_uninjectedSettingsRepositoryNeverOverwritesLiveSettings() async throws {
        let liveSettings = UserDefaults.standard.data(forKey: "app_settings")

        var settings = AppSettings.default
        settings.refreshInterval = 599
        try await SettingsRepository().save(settings)

        XCTAssertEqual(UserDefaults.standard.data(forKey: "app_settings"), liveSettings)

        // Decoding the value rather than asserting a blob exists: the isolated
        // suite is process-wide, so a neighbouring test class in this worker
        // can have written `app_settings` too.
        let isolated = try XCTUnwrap(UserDefaults(suiteName: TestSafeDefaults.testSuiteName))
        let persisted = try XCTUnwrap(isolated.data(forKey: "app_settings"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(AppSettings.self, from: persisted).refreshInterval, 599)
    }

    func test_injectedSuiteIsNeverRedirected() throws {
        let suiteName = "TestSafeDefaultsTests.\(UUID().uuidString)"
        let injected = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { injected.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(TestSafeDefaults.resolve(injected), injected)
        XCTAssertNotEqual(TestSafeDefaults.resolve(.standard), UserDefaults.standard)
    }

    /// `UserDefaults` does not override equality, so an instance opened over
    /// the app's own domain is not `==` to `.standard`. Identity alone would
    /// let it through to the real domain; the probe is what catches it.
    func test_separateInstanceOverTheApplicationDomainIsAlsoRedirected() throws {
        let sameDomainByInit = UserDefaults()
        XCTAssertNotEqual(sameDomainByInit, UserDefaults.standard, "precondition: not the singleton")
        XCTAssertNotEqual(TestSafeDefaults.resolve(sameDomainByInit), sameDomainByInit)

        // The other route to the same domain is closed by Foundation itself:
        // `init(suiteName:)` returns nil for the app's own bundle id.
        let bundleIdentifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertNil(UserDefaults(suiteName: bundleIdentifier))
    }

    /// The probe writes a key to decide the question above. It must never
    /// survive in the real domain.
    func test_domainProbeLeavesNoKeyBehind() throws {
        let before = Set(UserDefaults.standard.dictionaryRepresentation().keys)
        _ = TestSafeDefaults.resolve(UserDefaults())
        let added = Set(UserDefaults.standard.dictionaryRepresentation().keys)
            .subtracting(before)
            // Restricted to probe keys: the real domain is shared by every
            // parallel worker, so an unrelated key can appear mid-test.
            .filter { $0.hasPrefix(TestSafeDefaults.probeKeyPrefix) }
        XCTAssertTrue(added.isEmpty, "probe keys leaked into the real domain: \(added)")
    }

    func test_probeSweepPreservesKeysOwnedByALiveProcess() {
        let key = "\(TestSafeDefaults.probeKeyPrefix)\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        let standard = UserDefaults.standard
        standard.set(true, forKey: key)
        defer { standard.removeObject(forKey: key) }

        TestSafeDefaults.sweepAbandonedProbeKeys()

        XCTAssertNotNil(standard.object(forKey: key))
    }

    func test_probeSweepRemovesKeysOwnedByAStaleProcess() {
        let key = "\(TestSafeDefaults.probeKeyPrefix)\(pid_t.max).\(UUID().uuidString)"
        let standard = UserDefaults.standard
        standard.set(true, forKey: key)
        defer { standard.removeObject(forKey: key) }

        TestSafeDefaults.sweepAbandonedProbeKeys()

        XCTAssertNil(standard.object(forKey: key))
    }

    func test_sourceScanRejectsBareUserDefaults() {
        XCTAssertEqual(Self.unsafeDefaultsUses(in: "let defaults = UserDefaults()"), ["UserDefaults()"])
    }

    func test_sourceScanAcceptsMultilineAppStorageWithStore() {
        let source = """
        @AppStorage(
            "settingsSelectedTab",
            store: TestSafeDefaults.standardOrIsolated
        )
        private var selectedTab = "general"
        """

        XCTAssertEqual(Self.unsafeDefaultsUses(in: source), [])
    }

    /// The guard is only as good as its coverage: a `UserDefaults.standard`
    /// call or a bare `@AppStorage` added later would reopen the hole silently.
    func test_noProductionSourceWritesToStandardDefaultsDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pinemeter", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path))
        var offenders: [String] = []

        for case let path as String in enumerator where path.hasSuffix(".swift") {
            let relativePath = "Pinemeter/\(path)"
            guard !relativePath.hasSuffix("Repositories/TestSafeDefaults.swift") else { continue }
            let contents = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            for use in Self.unsafeDefaultsUses(in: contents) {
                offenders.append("\(relativePath): \(use)")
            }
        }

        XCTAssertEqual(
            offenders, [],
            "route these through TestSafeDefaults so test runs cannot write the real domain"
        )
    }

    private static func unsafeDefaultsUses(in source: String) -> [String] {
        var uses: [String] = []
        if source.contains("UserDefaults.standard") {
            uses.append("UserDefaults.standard")
        }
        if source.range(of: #"\bUserDefaults\s*\(\s*\)"#, options: .regularExpression) != nil {
            uses.append("UserDefaults()")
        }

        let range = NSRange(source.startIndex..., in: source)
        if appStorageCall.matches(in: source, range: range).contains(where: { match in
            guard let range = Range(match.range, in: source) else { return false }
            return source[range].range(of: #"\bstore\s*:"#, options: .regularExpression) == nil
        }) {
            uses.append("@AppStorage without store:")
        }
        return uses
    }
}
