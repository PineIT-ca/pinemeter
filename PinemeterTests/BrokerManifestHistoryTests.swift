//
//  BrokerManifestHistoryTests.swift
//  PinemeterTests
//

import Foundation
import XCTest
@testable import Pinemeter

final class BrokerManifestHistoryTests: XCTestCase {
    private let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let profileID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let sourceURL = "https://example.com/presets.json"
    private let baseDate = Date(timeIntervalSince1970: 1_760_000_000)

    func testCanonicalDigestIgnoresDictionaryOrderAndDisplayMetadata() throws {
        let first = profile(model: "model-a", aliases: ["z": "last", "a": "first"])
        let second = profile(model: "model-a", aliases: ["a": "first", "z": "last"])

        let firstDigest = try BrokerManifestHistoryStore.contentDigest(
            presets: [first],
            agentSetup: BrokerAgentSetupNotice(revision: 3, changedAt: nil, summary: "setup")
        )
        let secondDigest = try BrokerManifestHistoryStore.contentDigest(
            presets: [second],
            agentSetup: BrokerAgentSetupNotice(revision: 3, changedAt: nil, summary: "setup")
        )

        XCTAssertEqual(firstDigest, secondDigest)
        XCTAssertEqual(
            try BrokerManifestHistoryStore.contentDigest(
                presets: [renamed(second)],
                agentSetup: BrokerAgentSetupNotice(revision: 3, changedAt: nil, summary: "setup")
            ),
            secondDigest,
            "manifest display metadata must not create a revision"
        )
    }

    func testAppendSkipsAdjacentDuplicateButRecordsReturnToPriorContent() async throws {
        let directory = try temporaryDirectory()
        let store = BrokerManifestHistoryStore(storeDirectory: directory)

        _ = try await store.append(
            manifest(model: "model-a", revision: 1),
            sourceID: sourceID,
            urlString: "  \(sourceURL)  ",
            recordedAt: baseDate
        )
        _ = try await store.append(
            manifest(model: "model-a", revision: 99, summary: "display only"),
            sourceID: sourceID,
            urlString: sourceURL,
            recordedAt: baseDate.addingTimeInterval(1)
        )
        _ = try await store.append(
            manifest(model: "model-b", revision: 2),
            sourceID: sourceID,
            urlString: sourceURL,
            recordedAt: baseDate.addingTimeInterval(2)
        )
        let history = try await store.append(
            manifest(model: "model-a", revision: 3),
            sourceID: sourceID,
            urlString: sourceURL,
            recordedAt: baseDate.addingTimeInterval(3)
        )

        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.map(\.manifestRevision), [1, 2, 3])
    }

    func testRetentionKeepsTenNewestAcrossRestart() async throws {
        let directory = try temporaryDirectory()
        let store = BrokerManifestHistoryStore(storeDirectory: directory)

        for index in 0...10 {
            _ = try await store.append(
                manifest(model: "model-\(index)", revision: index),
                sourceID: sourceID,
                urlString: sourceURL,
                recordedAt: baseDate.addingTimeInterval(Double(index))
            )
        }

        let restarted = BrokerManifestHistoryStore(storeDirectory: directory)
        let loaded = await restarted.load(sourceID: sourceID, urlString: sourceURL)
        guard case .loaded(let history) = loaded else {
            return XCTFail("Expected readable history after restart")
        }
        XCTAssertEqual(history.count, BrokerManifestHistoryStore.capacity)
        XCTAssertEqual(history.map(\.manifestRevision), Array(1...10))
    }

    func testSourceIDAndTrimmedURLFormIndependentNamespaces() async throws {
        let directory = try temporaryDirectory()
        let store = BrokerManifestHistoryStore(storeDirectory: directory)
        let otherSourceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        _ = try await store.append(
            manifest(model: "first", revision: 1),
            sourceID: sourceID,
            urlString: sourceURL,
            recordedAt: baseDate
        )
        _ = try await store.append(
            manifest(model: "other-url", revision: 2),
            sourceID: sourceID,
            urlString: "https://example.com/other.json",
            recordedAt: baseDate
        )
        _ = try await store.append(
            manifest(model: "other-source", revision: 3),
            sourceID: otherSourceID,
            urlString: sourceURL,
            recordedAt: baseDate
        )

        let original = await store.load(sourceID: sourceID, urlString: " \(sourceURL) ")
        let otherURL = await store.load(
            sourceID: sourceID,
            urlString: "https://example.com/other.json"
        )
        let otherSource = await store.load(sourceID: otherSourceID, urlString: sourceURL)

        XCTAssertEqual(original.revisions.map(\.manifestRevision), [1])
        XCTAssertEqual(otherURL.revisions.map(\.manifestRevision), [2])
        XCTAssertEqual(otherSource.revisions.map(\.manifestRevision), [3])
    }

    func testSeedRunsOnceEvenWhenInitialCacheIsEmpty() async throws {
        let directory = try temporaryDirectory()
        let first = BrokerManifestHistoryStore(storeDirectory: directory)

        let initial = try await first.seedIfNeeded(
            sourceID: sourceID,
            urlString: sourceURL,
            presets: [],
            agentSetup: nil,
            recordedAt: baseDate
        )
        XCTAssertTrue(initial.isEmpty)

        let restarted = BrokerManifestHistoryStore(storeDirectory: directory)
        let second = try await restarted.seedIfNeeded(
            sourceID: sourceID,
            urlString: sourceURL,
            presets: [profile(model: "bundled-later")],
            agentSetup: nil,
            recordedAt: baseDate.addingTimeInterval(1)
        )

        XCTAssertTrue(second.isEmpty, "a later bundled cache must not become a fetched revision")
    }

    func testCorruptNamespaceDoesNotHideAnotherAndNextChangedFetchRepairsIt() async throws {
        let directory = try temporaryDirectory()
        let store = BrokerManifestHistoryStore(storeDirectory: directory)
        let otherSourceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        _ = try await store.append(
            manifest(model: "good", revision: 1),
            sourceID: otherSourceID,
            urlString: sourceURL,
            recordedAt: baseDate
        )
        let corruptURL = await store.resolvedStoreURL(sourceID: sourceID, urlString: sourceURL)
        try Data("not-json".utf8).write(to: corruptURL, options: .atomic)

        let corrupt = await store.load(sourceID: sourceID, urlString: sourceURL)
        let unaffected = await store.load(sourceID: otherSourceID, urlString: sourceURL)
        XCTAssertEqual(corrupt, .readError)
        XCTAssertEqual(unaffected.revisions.count, 1)

        let repaired = try await store.append(
            manifest(model: "repaired", revision: 2),
            sourceID: sourceID,
            urlString: sourceURL,
            recordedAt: baseDate.addingTimeInterval(1)
        )
        XCTAssertEqual(repaired.map(\.manifestRevision), [2])
    }

    func testWriteFailurePreservesLastReadableFile() async throws {
        let directory = try temporaryDirectory()
        let store = BrokerManifestHistoryStore(storeDirectory: directory)
        _ = try await store.append(
            manifest(model: "kept", revision: 1),
            sourceID: sourceID,
            urlString: sourceURL,
            recordedAt: baseDate
        )
        let failing = BrokerManifestHistoryStore(
            storeDirectory: directory,
            writer: { _, _ in throw HistoryTestError.writeFailed }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await failing.append(
                self.manifest(model: "lost", revision: 2),
                sourceID: self.sourceID,
                urlString: self.sourceURL,
                recordedAt: self.baseDate.addingTimeInterval(1)
            )
        }

        let restarted = BrokerManifestHistoryStore(storeDirectory: directory)
        let persisted = await restarted.load(sourceID: sourceID, urlString: sourceURL)
        XCTAssertEqual(persisted.revisions.map(\.manifestRevision), [1])
    }

    private func manifest(
        model: String,
        revision: Int,
        summary: String? = nil
    ) -> BrokerPresetManifest {
        BrokerPresetManifest(
            schemaVersion: 1,
            presets: [profile(model: model)],
            agentSetup: BrokerAgentSetupNotice(revision: 7, changedAt: "2026-09-20", summary: "setup"),
            manifestRevision: revision,
            publishedAt: baseDate,
            summary: summary
        )
    }

    private func profile(
        model: String,
        aliases: [String: String] = [:]
    ) -> BrokerAgentProfile {
        var rules = BrokerRuleSet.default
        rules.roles["planning"] = [BrokerCandidate(route: .auto, model: model)]
        rules.agentModelAliases = aliases
        return BrokerAgentProfile(
            id: profileID,
            name: "Profile",
            detail: "History fixture",
            symbolName: "leaf",
            rules: rules
        )
    }

    private func renamed(_ profile: BrokerAgentProfile) -> BrokerAgentProfile {
        var copy = profile
        copy.name = "Display-only rename"
        copy.detail = "Display-only detail"
        copy.symbolName = "bolt"
        return copy
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerManifestHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private enum HistoryTestError: Error {
    case writeFailed
}

private extension BrokerManifestHistoryLoadResult {
    var revisions: [BrokerManifestHistorySnapshot] {
        guard case .loaded(let revisions) = self else { return [] }
        return revisions
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
