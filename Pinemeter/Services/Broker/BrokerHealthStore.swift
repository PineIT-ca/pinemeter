import CryptoKit
import Foundation

struct BrokerHealthState: Equatable, Sendable {
    var payload: BrokerHealthPayload? = nil
    var line: Data? = nil
    var etag: String? = nil
    var lastCheck: BrokerHealthCheck? = nil

    func snapshot(now: Date) -> BrokerHealthSnapshot? { payload?.snapshot(now: now) }

    func status(now: Date, useModelHealth: Bool) -> BrokerHealthStatus {
        BrokerHealthDocument.status(stored: payload, now: now, useModelHealth: useModelHealth, lastCheck: lastCheck)
    }
}

/// Acceptance and atomic persistence share an actor turn, including the rollback guard.
actor BrokerHealthStore {
    typealias Writer = @Sendable (Data, URL) throws -> Void
    static let maxBytes = 65536

    private struct Envelope: Codable {
        let version: Int
        let document: String?
        let etag: String?
        let lastCheck: BrokerHealthCheck?
        enum CodingKeys: String, CodingKey { case version, document, etag; case lastCheck = "last_check" }
    }

    private let fileManager: FileManager
    private let storeURL: URL
    private let writer: Writer
    private var keys = BrokerHealthKeys.trusted
    private var state = BrokerHealthState()

    init(
        fileManager: FileManager = .default, storeDirectory: URL? = nil,
        writer: @escaping Writer = { data, url in try data.write(to: url, options: .atomic) }
    ) {
        self.fileManager = fileManager
        let directory = BrokerStorePaths.applicationSupportDirectory(
            fileManager: fileManager, requestedDirectory: storeDirectory
        )
        storeURL = directory.appendingPathComponent("broker-model-health.json")
        self.writer = writer
    }

    func load(keys: [String: Curve25519.Signing.PublicKey] = BrokerHealthKeys.trusted, now: Date) -> BrokerHealthState {
        self.keys = keys
        state = BrokerHealthState()
        guard let attributes = try? fileManager.attributesOfItem(atPath: storeURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maxBytes,
              let file = try? FileHandle(forReadingFrom: storeURL) else { return state }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: Self.maxBytes + 1), data.count <= Self.maxBytes,
              let envelope = try? BrokerHealthDocument.decoder().decode(Envelope.self, from: data),
              envelope.version == 1 else { return state }
        if let document = envelope.document {
            let line = Data(document.utf8)
            let accepted = BrokerHealthDocument.accept(body: line, stored: nil, keys: keys, now: now)
            guard accepted.outcome == .accepted else { return state }
            state.payload = accepted.payload
            state.line = line
        }
        state.etag = envelope.etag
        // The signed line is trusted; local check metadata is not signed.
        state.lastCheck = envelope.lastCheck.flatMap { Self.validCheckResult($0.result) ? $0 : nil }
        return state
    }

    /// Recheck at commit time so an acceptance computed before a suspension cannot roll back newer state.
    @discardableResult
    func record(acceptance: BrokerHealthAcceptance, etag: String?, checkedAt: Date) throws -> BrokerHealthState {
        let result: BrokerHealthAcceptance
        if acceptance.outcome != .staleCopy, let line = acceptance.line {
            result = BrokerHealthDocument.accept(body: line, stored: state.line, keys: keys, now: checkedAt)
        } else {
            result = acceptance
        }
        var next = state
        if result.outcome == .accepted || result.outcome == .unchanged, let line = result.line {
            next.payload = result.payload
            next.line = line
            next.etag = etag
        }
        next.lastCheck = BrokerHealthCheck(at: checkedAt, result: result.category?.rawValue ?? result.outcome.rawValue)
        try persist(next)
        state = next
        return state
    }

    @discardableResult
    func recordCheck(result: String, checkedAt: Date) throws -> BrokerHealthState {
        var next = state
        next.lastCheck = BrokerHealthCheck(at: checkedAt, result: result)
        try persist(next)
        state = next
        return state
    }

    func snapshot() -> BrokerHealthState { state }

    private static func validCheckResult(_ result: String) -> Bool {
        ["accepted", "unchanged", "rejected", "stale_copy", "fetch_failed", "store_failed"].contains(result)
            || BrokerHealthDocument.Rejection(rawValue: result) != nil
    }

    private func persist(_ next: BrokerHealthState) throws {
        let envelope = Envelope(version: 1, document: next.line.map { String(decoding: $0, as: UTF8.self) },
                                etag: next.etag, lastCheck: next.lastCheck)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maxBytes else { throw HealthDocumentService.FetchError.tooLarge }
        try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer(data, storeURL)
    }
}
