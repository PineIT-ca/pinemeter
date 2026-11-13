import CryptoKit
import Foundation

struct BrokerOfficialPresetState: Equatable, Sendable {
    var payload: BrokerPresetPayload? = nil
    var manifest: BrokerPresetManifest? = nil
    var line: Data? = nil
    var etag: String? = nil
    var lastCheck: BrokerHealthCheck? = nil
}

/// Signature acceptance, sequence comparison and atomic persistence never suspend.
actor BrokerOfficialPresetStore {
    typealias Writer = @Sendable (Data, URL) throws -> Void
    static let maxBytes = 1 << 20

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
    private let decodeManifest: @Sendable (Data) throws -> BrokerPresetManifest
    private var keys = BrokerPresetKeys.trusted
    private var state = BrokerOfficialPresetState()

    init(fileManager: FileManager = .default, storeDirectory: URL? = nil,
         writer: @escaping Writer = { data, url in try data.write(to: url, options: .atomic) },
         decodeManifest: @escaping @Sendable (Data) throws -> BrokerPresetManifest = BrokerPresetManifest.decode(from:)) {
        self.fileManager = fileManager
        storeURL = BrokerStorePaths.applicationSupportDirectory(fileManager: fileManager, requestedDirectory: storeDirectory)
            .appendingPathComponent("broker-official-presets.json")
        self.writer = writer
        self.decodeManifest = decodeManifest
    }

    func load(keys: [String: Curve25519.Signing.PublicKey] = BrokerPresetKeys.trusted, now: Date) -> BrokerOfficialPresetState {
        self.keys = keys
        state = BrokerOfficialPresetState()
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
            let accepted = BrokerPresetSignature.accept(line: line, stored: nil, keys: keys, now: now)
            guard accepted.outcome == .accepted, let payload = accepted.payload,
                  let manifest = try? decodeManifest(payload.manifest) else { return state }
            state.payload = payload
            state.manifest = manifest
            state.line = line
        }
        state.etag = envelope.etag
        state.lastCheck = envelope.lastCheck.flatMap { Self.validCheckResult($0.result) ? $0 : nil }
        return state
    }

    @discardableResult
    func accept(line: Data, etag: String?, checkedAt: Date) throws -> BrokerOfficialPresetState {
        try record(acceptance: BrokerPresetSignature.accept(line: line, stored: state.line, keys: keys, now: checkedAt),
                   etag: etag, checkedAt: checkedAt)
    }

    /// Also recheck caller-computed acceptances against the latest actor state.
    @discardableResult
    func record(acceptance: BrokerPresetAcceptance, etag: String?, checkedAt: Date) throws -> BrokerOfficialPresetState {
        let result: BrokerPresetAcceptance
        if acceptance.outcome != .staleCopy, let line = acceptance.line {
            result = BrokerPresetSignature.accept(line: line, stored: state.line, keys: keys, now: checkedAt)
        } else {
            // A stale result carries the retained line, not the fetched line or its ETag.
            result = acceptance
        }
        var next = state
        var check = result.category?.rawValue ?? result.outcome.rawValue
        if result.outcome == .accepted || result.outcome == .unchanged,
           let payload = result.payload, let line = result.line {
            if let manifest = try? decodeManifest(payload.manifest) {
                next.payload = payload
                next.manifest = manifest
                next.line = line
                next.etag = etag
            } else {
                check = BrokerPresetSignature.Rejection.undecodable.rawValue
            }
        }
        next.lastCheck = BrokerHealthCheck(at: checkedAt, result: check)
        try persist(next)
        state = next
        return state
    }

    @discardableResult
    func recordCheck(result: String, checkedAt: Date) throws -> BrokerOfficialPresetState {
        var next = state
        next.lastCheck = BrokerHealthCheck(at: checkedAt, result: Self.validCheckResult(result) ? result : "fetch_failed")
        try persist(next)
        state = next
        return state
    }

    func snapshot() -> BrokerOfficialPresetState { state }

    private static func validCheckResult(_ result: String) -> Bool {
        ["accepted", "unchanged", "rejected", "stale_copy", "fetch_failed", "store_failed"].contains(result)
            || BrokerPresetSignature.Rejection(rawValue: result) != nil
    }

    private func persist(_ next: BrokerOfficialPresetState) throws {
        let envelope = Envelope(version: 1, document: next.line.map { String(decoding: $0, as: UTF8.self) },
                                etag: next.etag, lastCheck: next.lastCheck)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maxBytes else { throw BrokerPresetSignature.Rejection.tooLarge }
        try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer(data, storeURL)
    }
}
