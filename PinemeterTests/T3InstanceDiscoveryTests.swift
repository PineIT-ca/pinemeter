//
//  T3InstanceDiscoveryTests.swift
//  PinemeterTests
//
//  T3InstanceDiscoveryService scans `<t3Base>/caches/*.json` into validated
//  DiscoveredT3Instance DTOs. Every fixture here is written by the test to a
//  temp directory — never the real home directory — and contains only
//  synthetic values (security constraint: no copies of real cache files).
//

import XCTest
@testable import Pinemeter

final class T3InstanceDiscoveryTests: XCTestCase {
    // MARK: - Fixture helpers

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("T3InstanceDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
    }

    private func fixtureJSON(
        instanceId: String,
        driver: String,
        displayName: String = "Display Name",
        enabled: Bool = true,
        installed: Bool = true,
        status: String = "ready",
        checkedAt: String = "2026-08-01T01:42:30.729Z",
        modelSlugs: [String] = ["model-a", "model-b"],
        includeSyntheticAuthBlock: Bool = false
    ) -> String {
        let modelsJSON = modelSlugs.map { "{\"slug\":\"\($0)\",\"name\":\"\($0)\"}" }.joined(separator: ",")
        let authJSON = includeSyntheticAuthBlock
            ? """
              , "auth": {"status":"authenticated","type":"synthetic","label":"Synthetic Subscription","email":"synthetic-fixture-user@example-nonexistent.test"}
              """
            : ""
        return """
        {
          "displayName": "\(displayName)",
          "enabled": \(enabled),
          "installed": \(installed),
          "status": "\(status)",
          "checkedAt": "\(checkedAt)",
          "instanceId": "\(instanceId)",
          "driver": "\(driver)",
          "models": [\(modelsJSON)]\(authJSON)
        }
        """
    }

    // MARK: - Six well-formed fixtures decode to six DTOs

    func test_scan_sixWellFormedFixtures_decodeToSixMatchingDTOs() async throws {
        let dir = try makeTempDirectory()
        let expected: [(id: String, driver: String, name: String, slugs: [String])] = [
            ("claudeAgent", "claudeAgent", "WS", ["claude-fable-5", "claude-opus-5"]),
            ("claude_autimo", "claudeAgent", "AU", ["claude-fable-5", "claude-opus-5"]),
            ("codex", "codex", "Codex", ["gpt-5.6-sol", "gpt-5.6-terra"]),
            ("cursor", "cursor", "Cursor", []),
            ("grok", "grok", "Grok", ["grok-build"]),
            ("opencode", "opencode", "OpenCode", []),
        ]
        for fixture in expected {
            try write(
                fixtureJSON(
                    instanceId: fixture.id,
                    driver: fixture.driver,
                    displayName: fixture.name,
                    modelSlugs: fixture.slugs
                ),
                named: "\(fixture.id).json",
                in: dir
            )
        }

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()

        let result = try XCTUnwrap(scanResult)

        XCTAssertEqual(result.count, 6)
        for fixture in expected {
            let discovered = try XCTUnwrap(result.first { $0.instanceId == fixture.id })
            XCTAssertEqual(discovered.driver, fixture.driver)
            XCTAssertEqual(discovered.displayName, fixture.name)
            XCTAssertEqual(discovered.installed, true)
            XCTAssertNotNil(discovered.checkedAt)
            XCTAssertEqual(discovered.modelSlugs, fixture.slugs)
        }
    }

    // MARK: - Missing / empty directory

    func test_scan_missingCachesDirectory_returnsNilNotEmptyArray() async throws {
        let dir = try makeTempDirectory()
        let missing = dir.appendingPathComponent("does-not-exist", isDirectory: true)
        let service = T3InstanceDiscoveryService(cachesDirectoryURL: missing)

        let result = await service.scan()

        XCTAssertNil(result, "a missing caches directory must be 'no information,' not an empty result")
    }

    func test_scan_emptyCachesDirectory_returnsEmptyArray() async throws {
        let dir = try makeTempDirectory()
        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)

        let result = await service.scan()

        XCTAssertEqual(result, [], "an existing, readable, empty directory is an authoritative empty result")
    }

    // MARK: - Malformed siblings are skipped; well-formed siblings still decode

    func test_scan_malformedSiblings_areSkippedWhileWellFormedSiblingsStillDecode() async throws {
        let dir = try makeTempDirectory()
        try write("{ not valid json ", named: "broken.json", in: dir)
        try write("[1, 2, 3]", named: "array.json", in: dir)
        try write("{\"driver\":\"codex\"}", named: "no-instance-id.json", in: dir)
        try write(fixtureJSON(instanceId: "codex", driver: "codex"), named: "codex.json", in: dir)

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()

        let result = try XCTUnwrap(scanResult)

        XCTAssertEqual(result.map(\.instanceId), ["codex"])
    }

    // MARK: - Hostile instanceId / driver rejected

    func test_scan_invalidInstanceId_causesFileToBeSkippedEntirely() async throws {
        let dir = try makeTempDirectory()
        try write(fixtureJSON(instanceId: "", driver: "codex"), named: "empty-id.json", in: dir)
        try write(
            fixtureJSON(instanceId: String(repeating: "a", count: 65), driver: "codex"),
            named: "too-long-id.json",
            in: dir
        )
        try write(fixtureJSON(instanceId: "bad:colon", driver: "codex"), named: "colon-id.json", in: dir)
        try write(fixtureJSON(instanceId: "bad/slash", driver: "codex"), named: "slash-id.json", in: dir)
        try write(fixtureJSON(instanceId: "codex", driver: "codex"), named: "codex.json", in: dir)

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()

        let result = try XCTUnwrap(scanResult)

        XCTAssertEqual(result.map(\.instanceId), ["codex"])
    }

    func test_scan_invalidDriver_causesFileToBeSkipped() async throws {
        let dir = try makeTempDirectory()
        try write(fixtureJSON(instanceId: "bad-driver", driver: "bad:driver"), named: "bad-driver.json", in: dir)
        try write(fixtureJSON(instanceId: "codex", driver: "codex"), named: "codex.json", in: dir)

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()

        let result = try XCTUnwrap(scanResult)

        XCTAssertEqual(result.map(\.instanceId), ["codex"])
    }

    // MARK: - Hostile model slugs dropped, valid slugs survive

    func test_scan_invalidModelSlug_droppedWhileValidSlugsSurvive() async throws {
        let dir = try makeTempDirectory()
        try write(
            fixtureJSON(
                instanceId: "codex",
                driver: "codex",
                modelSlugs: ["gpt-5.6-sol", "bad:slug", String(repeating: "x", count: 129)]
            ),
            named: "codex.json",
            in: dir
        )

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()

        let result = try XCTUnwrap(scanResult)

        XCTAssertEqual(result.map(\.instanceId), ["codex"])
        XCTAssertEqual(result.first?.modelSlugs, ["gpt-5.6-sol"])
    }

    // MARK: - Size cap and file-count cap

    func test_scan_oversizedFile_skippedWithoutBeingDecoded() async throws {
        let dir = try makeTempDirectory()
        let paddingValue = String(repeating: "x", count: 2_000_000)
        try write(
            fixtureJSON(instanceId: "oversized", driver: "codex", displayName: paddingValue),
            named: "oversized.json",
            in: dir
        )
        try write(fixtureJSON(instanceId: "codex", driver: "codex"), named: "codex.json", in: dir)

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()

        let result = try XCTUnwrap(scanResult)

        XCTAssertEqual(result.map(\.instanceId), ["codex"])
    }

    func test_scan_directoryWithMoreThan64JSONFiles_scansExactlyTheFirst64ByName() async throws {
        let dir = try makeTempDirectory()
        for index in 0..<80 {
            let id = String(format: "inst%03d", index)
            try write(fixtureJSON(instanceId: id, driver: "codex"), named: "\(id).json", in: dir)
        }

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()

        let result = try XCTUnwrap(scanResult)

        // Exactly 64, and pinned to name-sort order: `<=` alone could not
        // distinguish "capped correctly" from "scan broken" (review IN-06),
        // and the retained-identity assertions document the starvation
        // behavior an attacker-named `0*.json` flood would exploit (WR-07).
        XCTAssertEqual(result.count, 64)
        let ids = Set(result.map(\.instanceId))
        XCTAssertTrue(ids.contains("inst000"))
        XCTAssertTrue(ids.contains("inst063"))
        XCTAssertFalse(ids.contains("inst064"))
    }

    // MARK: - Symlinks and non-regular files (review CR-01)

    func test_scan_symlinkToOversizedFile_isSkippedNotFollowed() async throws {
        let dir = try makeTempDirectory()
        let targetDir = try makeTempDirectory()
        // A well-formed but oversized target: if the symlink were followed,
        // the stat of the link itself (tiny) would pass the size cap while
        // the read pulled the whole target in.
        let oversizedTarget = targetDir.appendingPathComponent("target.json")
        let padding = String(repeating: "x", count: 2_000_000)
        try Data(fixtureJSON(instanceId: "linked", driver: "codex", displayName: padding).utf8)
            .write(to: oversizedTarget)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("linked.json"),
            withDestinationURL: oversizedTarget
        )
        try write(fixtureJSON(instanceId: "codex", driver: "codex"), named: "codex.json", in: dir)

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()
        let result = try XCTUnwrap(scanResult)

        XCTAssertEqual(result.map(\.instanceId), ["codex"])
    }

    func test_scan_symlinkToWellFormedFile_isStillSkipped_onlyRegularFilesAreEverOpened() async throws {
        // The invariant is "never open through a link" — not "links to big
        // files are skipped." A link to a perfectly valid small cache file
        // must be skipped too, because the same mechanism could point at a
        // credential-bearing file instead (T-pz4-02).
        let dir = try makeTempDirectory()
        let targetDir = try makeTempDirectory()
        let target = targetDir.appendingPathComponent("linked.json")
        try Data(fixtureJSON(instanceId: "linked", driver: "codex").utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("linked.json"),
            withDestinationURL: target
        )

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()
        let result = try XCTUnwrap(scanResult)

        XCTAssertTrue(result.isEmpty)
    }

    func test_scan_symlinkedCachesDirectory_returnsNilWithoutReadingTarget() async throws {
        let parent = try makeTempDirectory()
        let target = try makeTempDirectory()
        try write(fixtureJSON(instanceId: "codex", driver: "codex"), named: "codex.json", in: target)
        let linkedCaches = parent.appendingPathComponent("caches", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedCaches, withDestinationURL: target)

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: linkedCaches)

        let result = await service.scan()
        XCTAssertNil(result)
    }

    func test_scan_hardLinkedCacheFile_isSkipped() async throws {
        let dir = try makeTempDirectory()
        let targetDir = try makeTempDirectory()
        let target = targetDir.appendingPathComponent("codex.json")
        try Data(fixtureJSON(instanceId: "codex", driver: "codex").utf8).write(to: target)
        try FileManager.default.linkItem(at: target, to: dir.appendingPathComponent("codex.json"))

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanned = await service.scan()
        let result = try XCTUnwrap(scanned)

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Filename identity (review WR-07)

    func test_scan_fileWhoseNameDoesNotMatchItsInstanceId_isSkipped() async throws {
        let dir = try makeTempDirectory()
        // A planted file claiming another instance's id.
        try write(fixtureJSON(instanceId: "codex", driver: "codex"), named: "impostor.json", in: dir)
        try write(fixtureJSON(instanceId: "codex", driver: "codex"), named: "codex.json", in: dir)

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()
        let result = try XCTUnwrap(scanResult)

        XCTAssertEqual(result.map(\.instanceId), ["codex"])
    }

    // MARK: - displayName sanitization (review WR-05)

    func test_scan_displayNameControlAndBidiCharacters_areStrippedAndLengthIsCapped() async throws {
        let dir = try makeTempDirectory()
        let hostile = "Claude\u{202E} (autimo)\nline2\ttab" + String(repeating: "y", count: 200)
        try write(
            fixtureJSON(instanceId: "codex", driver: "codex", displayName: hostile.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")),
            named: "codex.json",
            in: dir
        )

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()
        let result = try XCTUnwrap(scanResult)

        let displayName = try XCTUnwrap(result.first?.displayName)
        XCTAssertFalse(displayName.contains("\u{202E}"), "bidi override must be stripped")
        XCTAssertFalse(displayName.contains("\n"))
        XCTAssertFalse(displayName.contains("\t"))
        XCTAssertLessThanOrEqual(displayName.count, T3InstanceDiscoveryService.maxDisplayNameLength)
    }

    func test_sanitizedDisplayName_whitespaceOnlyOrEmpty_becomesNil() {
        XCTAssertNil(T3InstanceDiscoveryService.sanitizedDisplayName(nil))
        XCTAssertNil(T3InstanceDiscoveryService.sanitizedDisplayName(""))
        XCTAssertNil(T3InstanceDiscoveryService.sanitizedDisplayName("   "))
        XCTAssertNil(T3InstanceDiscoveryService.sanitizedDisplayName("\u{202E}\u{200D}"))
        XCTAssertEqual(T3InstanceDiscoveryService.sanitizedDisplayName("  Codex  "), "Codex")
    }

    // MARK: - checkedAt parsing

    func test_scan_checkedAtWithFractionalSeconds_parses() async throws {
        let dir = try makeTempDirectory()
        try write(
            fixtureJSON(instanceId: "codex", driver: "codex", checkedAt: "2026-08-15T01:42:30.729Z"),
            named: "codex.json",
            in: dir
        )

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()

        let result = try XCTUnwrap(scanResult)

        XCTAssertNotNil(result.first?.checkedAt)
    }

    func test_scan_checkedAtAbsentOrUnparseable_yieldsNilWithoutFailingFile() async throws {
        let dir = try makeTempDirectory()
        let noCheckedAt = """
        {
          "displayName": "No Checked At",
          "enabled": true,
          "installed": true,
          "status": "ready",
          "instanceId": "no-checked-at",
          "driver": "codex",
          "models": []
        }
        """
        try write(noCheckedAt, named: "no-checked-at.json", in: dir)
        try write(
            fixtureJSON(instanceId: "unparseable", driver: "codex", checkedAt: "not-a-date"),
            named: "unparseable.json",
            in: dir
        )

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()

        let result = try XCTUnwrap(scanResult)

        let noCheckedAtResult = try XCTUnwrap(result.first { $0.instanceId == "no-checked-at" })
        XCTAssertNil(noCheckedAtResult.checkedAt)
        let unparseableResult = try XCTUnwrap(result.first { $0.instanceId == "unparseable" })
        XCTAssertNil(unparseableResult.checkedAt)
    }

    func test_scan_checkedAtFarInTheFuture_isDiscarded() async throws {
        // A forged future timestamp would pin the staleness badge at
        // "Detected" indefinitely (review IN-04); beyond the small skew
        // allowance it is treated as absent.
        let dir = try makeTempDirectory()
        let iso = ISO8601DateFormatter()
        let future = iso.string(from: Date().addingTimeInterval(3600))
        try write(
            fixtureJSON(instanceId: "codex", driver: "codex", checkedAt: future),
            named: "codex.json",
            in: dir
        )

        let service = T3InstanceDiscoveryService(cachesDirectoryURL: dir)
        let scanResult = await service.scan()
        let result = try XCTUnwrap(scanResult)

        XCTAssertEqual(result.map(\.instanceId), ["codex"])
        XCTAssertNil(result.first?.checkedAt)
    }

    func test_checkedAt_fractionalSeconds_areTruncatedToWholeSeconds() throws {
        // Whole-second truncation keeps `lastSeenAt` byte-identical across
        // SettingsRepository's `.iso8601` save/load round trip, so the first
        // reconcile after a relaunch is not a phantom change (review IN-09).
        let json = fixtureJSON(instanceId: "codex", driver: "codex", checkedAt: "2026-08-01T01:42:30.729Z")
        let decoded = try JSONDecoder().decode(DiscoveredT3Instance.self, from: Data(json.utf8))

        let checkedAt = try XCTUnwrap(decoded.checkedAt)
        let whole = ISO8601DateFormatter()
        XCTAssertEqual(checkedAt, whole.date(from: "2026-08-01T01:42:30Z"))
    }

    // MARK: - Round-trip secrecy (T-pz4-02)

    func test_roundTripSecrecy_authBlockWithEmailNeverSurvivesReencode() throws {
        let json = fixtureJSON(instanceId: "codex", driver: "codex", includeSyntheticAuthBlock: true)
        let data = Data(json.utf8)

        let decoded = try JSONDecoder().decode(DiscoveredT3Instance.self, from: data)
        let reencoded = try JSONEncoder().encode(decoded)
        let reencodedText = try XCTUnwrap(String(data: reencoded, encoding: .utf8)).lowercased()

        XCTAssertFalse(reencodedText.contains("auth"))
        XCTAssertFalse(reencodedText.contains("email"))
        XCTAssertFalse(reencodedText.contains("synthetic-fixture-user"))
    }
}
