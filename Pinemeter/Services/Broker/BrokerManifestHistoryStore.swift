//
//  BrokerManifestHistoryStore.swift
//  Pinemeter
//
//  Actor-owned, restart-durable history for validated preset manifests.
//

import CryptoKit
import Foundation

struct BrokerManifestHistoryNamespace: Codable, Hashable, Sendable {
    let sourceID: UUID
    let urlString: String

    init(sourceID: UUID, urlString: String) {
        self.sourceID = sourceID
        self.urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct BrokerManifestHistorySnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordedAt: Date
    let contentDigest: String
    let presets: [BrokerAgentProfile]
    let agentSetup: BrokerAgentSetupNotice?
    let manifestRevision: Int?
    let publishedAt: Date?
    let summary: String?

    func profile(id: UUID) -> BrokerAgentProfile? {
        presets.first { $0.id == id }
    }
}

enum BrokerManifestHistoryLoadResult: Equatable, Sendable {
    case loaded([BrokerManifestHistorySnapshot])
    case readError
}

enum BrokerManifestHistoryError: Error {
    case invalidSnapshot
    case unreadableHistory
}

actor BrokerManifestHistoryStore {
    typealias Writer = @Sendable (Data, URL) throws -> Void

    static let capacity = 10

    private struct Envelope: Codable, Sendable {
        let version: Int
        let namespace: BrokerManifestHistoryNamespace
        let snapshots: [BrokerManifestHistorySnapshot]
    }

    private struct CanonicalProfile: Encodable {
        let id: UUID
        let rules: BrokerRuleSet
    }

    private struct CanonicalContent: Encodable {
        let profiles: [CanonicalProfile]
        let agentSetup: BrokerAgentSetupNotice?
    }

    private let fileManager: FileManager
    private let storeDirectory: URL
    private let writer: Writer

    init(
        fileManager: FileManager = .default,
        storeDirectory: URL? = nil,
        writer: @escaping Writer = { data, url in try data.write(to: url, options: .atomic) }
    ) {
        self.fileManager = fileManager
        self.storeDirectory = BrokerStorePaths.applicationSupportDirectory(
            fileManager: fileManager,
            requestedDirectory: storeDirectory
        )
        self.writer = writer
        try? fileManager.createDirectory(at: self.storeDirectory, withIntermediateDirectories: true)
    }

    func load(sourceID: UUID, urlString: String) -> BrokerManifestHistoryLoadResult {
        let namespace = BrokerManifestHistoryNamespace(sourceID: sourceID, urlString: urlString)
        let url = storeURL(for: namespace)
        guard fileManager.fileExists(atPath: url.path) else { return .loaded([]) }
        guard let envelope = Self.readEnvelope(from: url, namespace: namespace) else {
            return .readError
        }
        return .loaded(envelope.snapshots)
    }

    func seedIfNeeded(
        sourceID: UUID,
        urlString: String,
        presets: [BrokerAgentProfile],
        agentSetup: BrokerAgentSetupNotice?,
        recordedAt: Date
    ) throws -> [BrokerManifestHistorySnapshot] {
        let namespace = BrokerManifestHistoryNamespace(sourceID: sourceID, urlString: urlString)
        let url = storeURL(for: namespace)
        if fileManager.fileExists(atPath: url.path) {
            guard let envelope = Self.readEnvelope(from: url, namespace: namespace) else {
                throw BrokerManifestHistoryError.unreadableHistory
            }
            return envelope.snapshots
        }

        let snapshots: [BrokerManifestHistorySnapshot]
        if presets.isEmpty, agentSetup == nil {
            snapshots = []
        } else {
            guard Self.isValid(presets: presets, agentSetup: agentSetup) else {
                throw BrokerManifestHistoryError.invalidSnapshot
            }
            snapshots = [try Self.snapshot(
                presets: presets,
                agentSetup: agentSetup,
                manifestRevision: nil,
                publishedAt: nil,
                summary: nil,
                recordedAt: recordedAt
            )]
        }
        try persist(Envelope(version: 1, namespace: namespace, snapshots: snapshots), to: url)
        return snapshots
    }

    func append(
        _ manifest: BrokerPresetManifest,
        sourceID: UUID,
        urlString: String,
        recordedAt: Date
    ) throws -> [BrokerManifestHistorySnapshot] {
        guard Self.isValid(presets: manifest.presets, agentSetup: manifest.agentSetup),
              Self.isValid(
                  manifestRevision: manifest.manifestRevision,
                  summary: manifest.summary
              ) else {
            throw BrokerManifestHistoryError.invalidSnapshot
        }
        let namespace = BrokerManifestHistoryNamespace(sourceID: sourceID, urlString: urlString)
        let url = storeURL(for: namespace)
        let existing = Self.readEnvelope(from: url, namespace: namespace)?.snapshots ?? []
        let incoming = try Self.snapshot(
            presets: manifest.presets,
            agentSetup: manifest.agentSetup,
            manifestRevision: manifest.manifestRevision,
            publishedAt: manifest.publishedAt,
            summary: manifest.summary,
            recordedAt: recordedAt
        )
        guard existing.last?.contentDigest != incoming.contentDigest else { return existing }

        let retained = Array((existing + [incoming]).suffix(Self.capacity))
        try persist(Envelope(version: 1, namespace: namespace, snapshots: retained), to: url)
        return retained
    }

    func resolvedStoreURL(sourceID: UUID, urlString: String) -> URL {
        storeURL(for: BrokerManifestHistoryNamespace(sourceID: sourceID, urlString: urlString))
    }

    static func contentDigest(
        presets: [BrokerAgentProfile],
        agentSetup: BrokerAgentSetupNotice?
    ) throws -> String {
        let canonical = CanonicalContent(
            profiles: presets
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .map { CanonicalProfile(id: $0.id, rules: $0.rules) },
            agentSetup: agentSetup
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(canonical)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func storeURL(for namespace: BrokerManifestHistoryNamespace) -> URL {
        let key = "\(namespace.sourceID.uuidString.lowercased())\n\(namespace.urlString)"
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return storeDirectory.appendingPathComponent("broker-manifest-history-\(digest).json")
    }

    private func persist(_ envelope: Envelope, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try writer(encoder.encode(envelope), url)
    }

    private static func snapshot(
        presets: [BrokerAgentProfile],
        agentSetup: BrokerAgentSetupNotice?,
        manifestRevision: Int?,
        publishedAt: Date?,
        summary: String?,
        recordedAt: Date
    ) throws -> BrokerManifestHistorySnapshot {
        BrokerManifestHistorySnapshot(
            id: UUID(),
            recordedAt: recordedAt,
            contentDigest: try contentDigest(presets: presets, agentSetup: agentSetup),
            presets: presets,
            agentSetup: agentSetup,
            manifestRevision: manifestRevision,
            publishedAt: publishedAt,
            summary: summary
        )
    }

    private static func readEnvelope(
        from url: URL,
        namespace: BrokerManifestHistoryNamespace
    ) -> Envelope? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.version == 1,
              envelope.namespace == namespace,
              envelope.snapshots.count <= capacity,
              Set(envelope.snapshots.map(\.id)).count == envelope.snapshots.count,
              envelope.snapshots.allSatisfy({ isValid(snapshot: $0) }) else {
            return nil
        }
        return envelope
    }

    private static func isValid(snapshot: BrokerManifestHistorySnapshot) -> Bool {
        guard isValid(
                  manifestRevision: snapshot.manifestRevision,
                  summary: snapshot.summary
              ),
              isValid(presets: snapshot.presets, agentSetup: snapshot.agentSetup),
              let digest = try? contentDigest(
                  presets: snapshot.presets,
                  agentSetup: snapshot.agentSetup
              ) else { return false }
        return digest == snapshot.contentDigest
    }

    private static func isValid(manifestRevision: Int?, summary: String?) -> Bool {
        (manifestRevision.map { $0 >= 0 } ?? true)
            && (summary.map {
                !$0.isEmpty && $0 == BrokerPresetManifest.sanitize(
                    $0, maxScalars: BrokerPresetManifest.maxSummaryScalars
                )
            } ?? true)
    }

    private static func isValid(
        presets: [BrokerAgentProfile],
        agentSetup: BrokerAgentSetupNotice?
    ) -> Bool {
        guard presets.count <= BrokerPresetManifest.maxPresets,
              Set(presets.map(\.id)).count == presets.count else { return false }
        if let agentSetup {
            guard agentSetup.revision >= 0,
                  agentSetup.changedAt.map({ BrokerPresetManifest.validAgentSetupDate($0) }) ?? true,
                  agentSetup.summary.map({
                      !$0.isEmpty && $0 == BrokerPresetManifest.sanitize(
                          $0, maxScalars: BrokerPresetManifest.maxSetupSummaryScalars
                      )
                  }) ?? true else { return false }
        }
        return presets.allSatisfy { profile in
            !profile.name.isEmpty
                && profile.name == BrokerPresetManifest.sanitize(
                    profile.name, maxScalars: BrokerPresetManifest.maxNameScalars
                )
                && profile.detail == BrokerPresetManifest.sanitize(
                    profile.detail, maxScalars: BrokerPresetManifest.maxDetailScalars
                )
                && T3InstanceConfig.isValidIdentifier(profile.symbolName, maxLength: 64)
        }
    }
}
