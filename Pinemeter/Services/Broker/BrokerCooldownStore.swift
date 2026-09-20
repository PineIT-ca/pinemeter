//
//  BrokerCooldownStore.swift
//  Pinemeter
//
//  Persisted cooldown map for the `down`/`up` tools, read-merged with the
//  reference broker CLI's own exhaustion cooldowns
//  (`~/.model-broker/cooldowns.json`) so a lane that CLI marked down over a
//  hidden quota wall is not recommended by Pinemeter either (RESEARCH Open
//  Questions 1 and 3). The file is optional: absent on any machine that never
//  ran that CLI, which is the normal case.
//
//  Follows the CacheRepository disk-persistence convention: an actor,
//  JSONEncoder/Decoder with the `.iso8601` date strategy, atomic file writes,
//  and decode-failure-returns-empty (never throws) per the SettingsRepository
//  decode-safety convention. In-app state writes only its own file; a reset
//  snapshots the CLI cooldown key/expiry pairs it is meant to forget, so
//  later CLI cooldowns remain authoritative.
//

import Foundation
import Darwin

enum BrokerCooldownError: Error, Equatable {
    case invalidTarget
    case capacityExceeded
}

actor BrokerCooldownStore {
    typealias Writer = @Sendable (_ data: Data, _ url: URL) throws -> Void

    /// Guidance constant surfaced in the `down` tool's description text: the
    /// reference broker CLI's own T3 credit-wall exhaustion cooldown length.
    static let defaultT3ExhaustionSeconds: TimeInterval = 21600

    static let defaultDownMinutes = 60
    static let minDownMinutes = 1
    static let maxDownMinutes = 10080
    static let maxTargetScalars = 256
    static let maxEntries = 64
    static let maxFileSizeBytes = 1_024 * 1_024

    private static let cliResetMarker = "__pinemeter_cli_reset__"

    private let storeURL: URL
    private let cliCooldownsURL: URL
    private let now: @Sendable () -> Date
    private let writer: Writer

    /// The reset marker stays at the top level for backward compatibility,
    /// but its current value is a nested key-to-expiry-millisecond snapshot.
    /// Older builds ignore that non-string value while still decoding every
    /// normal cooldown entry. Milliseconds preserve the reference CLI's exact
    /// `Date.toISOString()` expiry so an extension, even within the same
    /// second, is distinguishable from the entry reset suppressed.
    private struct InAppFile: Codable {
        var cooldowns: [String: Date] = [:]
        var suppressedCLIExpiryMilliseconds: [String: Int64] = [:]
        var legacyCLISuppressUntil: Date?

        init(
            cooldowns: [String: Date] = [:],
            suppressedCLIExpiryMilliseconds: [String: Int64] = [:],
            legacyCLISuppressUntil: Date? = nil
        ) {
            self.cooldowns = cooldowns
            self.suppressedCLIExpiryMilliseconds = suppressedCLIExpiryMilliseconds
            self.legacyCLISuppressUntil = legacyCLISuppressUntil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FileKey.self)
            let hasResetMarker = container.allKeys.contains {
                $0.stringValue == BrokerCooldownStore.cliResetMarker
            }
            guard container.allKeys.count <= BrokerCooldownStore.maxEntries
                    || (container.allKeys.count == BrokerCooldownStore.maxEntries + 1 && hasResetMarker)
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Too many cooldown entries")
                )
            }

            for key in container.allKeys {
                if key.stringValue == BrokerCooldownStore.cliResetMarker {
                    if let legacyUntil = try? container.decode(Date.self, forKey: key) {
                        legacyCLISuppressUntil = legacyUntil
                    } else {
                        // A marker that is neither shape is corruption in
                        // bookkeeping, not in the cooldowns themselves. Drop it
                        // alone, matching the one-entry-at-a-time convention the
                        // CLI reader follows: losing every real cooldown here
                        // would silently re-enable exhausted candidates.
                        suppressedCLIExpiryMilliseconds = (try? container.decode(
                            SuppressionMap.self,
                            forKey: key
                        ))?.values ?? [:]
                    }
                    continue
                }
                guard !key.stringValue.isEmpty,
                      key.stringValue.unicodeScalars.count <= BrokerCooldownStore.maxTargetScalars,
                      let date = try? container.decode(Date.self, forKey: key) else { continue }
                cooldowns[key.stringValue] = date
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: FileKey.self)
            for (key, date) in cooldowns {
                try container.encode(date, forKey: FileKey(key))
            }
            let resetKey = FileKey(BrokerCooldownStore.cliResetMarker)
            if !suppressedCLIExpiryMilliseconds.isEmpty {
                try container.encode(
                    SuppressionMap(values: suppressedCLIExpiryMilliseconds),
                    forKey: resetKey
                )
            } else if let legacyCLISuppressUntil {
                try container.encode(legacyCLISuppressUntil, forKey: resetKey)
            }
        }
    }

    private struct SuppressionMap: Codable {
        var values: [String: Int64]

        init(values: [String: Int64]) {
            self.values = values
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FileKey.self)
            guard container.allKeys.count <= BrokerCooldownStore.maxEntries else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Too many CLI suppressions")
                )
            }
            values = [:]
            for key in container.allKeys {
                guard !key.stringValue.isEmpty,
                      key.stringValue.unicodeScalars.count <= BrokerCooldownStore.maxTargetScalars,
                      let expiry = try? container.decode(Int64.self, forKey: key) else { continue }
                values[key.stringValue] = expiry
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: FileKey.self)
            for (key, expiry) in values {
                try container.encode(expiry, forKey: FileKey(key))
            }
        }
    }

    private struct FileKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            return nil
        }
    }

    /// - Parameters:
    ///   - fileManager: Injectable for tests.
    ///   - storeDirectory: Directory the in-app cooldown file lives in. Defaults
    ///     to `Application Support/Pinemeter`. Injectable so tests use a temp dir.
    ///   - cliCooldownsURL: The reference broker CLI's cooldown file. Defaults to
    ///     `~/.model-broker/cooldowns.json`. Injectable so tests use a temp file.
    ///   - now: Injected clock; the only time source this store reads.
    init(
        fileManager: FileManager = .default,
        storeDirectory: URL? = nil,
        cliCooldownsURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        writer: @escaping Writer = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        let baseDirectory = BrokerStorePaths.applicationSupportDirectory(
            fileManager: fileManager,
            requestedDirectory: storeDirectory
        )
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        self.storeURL = baseDirectory.appendingPathComponent("broker-cooldowns.json")
        let defaultCLICooldownsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".model-broker", isDirectory: true)
            .appendingPathComponent("cooldowns.json")
        let requestedCLICooldownsURL = cliCooldownsURL ?? defaultCLICooldownsURL
        if BrokerStorePaths.isRunningTests,
           requestedCLICooldownsURL.standardizedFileURL == defaultCLICooldownsURL.standardizedFileURL {
            self.cliCooldownsURL = baseDirectory.appendingPathComponent("cli-cooldowns.json")
        } else {
            self.cliCooldownsURL = requestedCLICooldownsURL
        }
        self.now = now
        self.writer = writer
    }

    var resolvedStoreURL: URL { storeURL }
    var resolvedCLICooldownsURL: URL { cliCooldownsURL }

    /// Marks `target` unavailable until `now + minutes`. `minutes` clamps to
    /// 1...10080 (one week) and defaults to 60. Persists to the in-app file only.
    @discardableResult
    func down(target: String, minutes: Int? = nil) throws -> Date {
        // `target` is external input on the MCP surface. The reset marker is a
        // reserved key in this file, so accepting it as a cooldown target would
        // let one entry collide with the CLI-suppression bookkeeping.
        guard !target.isEmpty,
              target.unicodeScalars.count <= Self.maxTargetScalars,
              target != Self.cliResetMarker else {
            throw BrokerCooldownError.invalidTarget
        }
        let clampedMinutes = min(
            max(minutes ?? Self.defaultDownMinutes, Self.minDownMinutes),
            Self.maxDownMinutes
        )
        let currentNow = now()
        let availableAt = currentNow.addingTimeInterval(TimeInterval(clampedMinutes) * 60)
        var inApp = activeInAppFile(at: currentNow)
        guard inApp.cooldowns[target] != nil || inApp.cooldowns.count < Self.maxEntries else {
            throw BrokerCooldownError.capacityExceeded
        }
        inApp.cooldowns[target] = availableAt
        try writeInAppFile(inApp)
        return availableAt
    }

    /// Restores `target` to immediate availability. Persists to the in-app
    /// file only — this can never touch the CLI's exhaustion signal.
    func up(target: String) throws {
        guard !target.isEmpty,
              target.unicodeScalars.count <= Self.maxTargetScalars,
              target != Self.cliResetMarker else {
            throw BrokerCooldownError.invalidTarget
        }
        var inApp = activeInAppFile(at: now())
        inApp.cooldowns.removeValue(forKey: target)
        try writeInAppFile(inApp)
    }

    /// Clears every cooldown source the broker merges.
    func reset() throws {
        let currentNow = now()
        let suppressions = readCLIFile().compactMapValues { availableAt in
            availableAt > currentNow ? Self.expiryMilliseconds(for: availableAt) : nil
        }
        try writeInAppFile(InAppFile(suppressedCLIExpiryMilliseconds: suppressions))
    }

    /// The merged view `BrokerEngine.decide` reads: in-app entries union the
    /// CLI's cooldowns, the LATER `availableAt` wins on a shared key (most
    /// restrictive), and entries whose `availableAt` is already past are
    /// dropped. Expired reset suppressions are also removed from disk so
    /// internal bookkeeping stays bounded.
    func mergedSnapshot() -> [String: Date] {
        let currentNow = now()
        var inApp = readInAppFile()
        let suppressionCount = inApp.suppressedCLIExpiryMilliseconds.count
        let hadLegacySuppression = inApp.legacyCLISuppressUntil != nil
        inApp.suppressedCLIExpiryMilliseconds = inApp.suppressedCLIExpiryMilliseconds.filter {
            Self.date(forExpiryMilliseconds: $0.value) > currentNow
        }
        if let legacyUntil = inApp.legacyCLISuppressUntil, legacyUntil <= currentNow {
            inApp.legacyCLISuppressUntil = nil
        }
        if suppressionCount != inApp.suppressedCLIExpiryMilliseconds.count
            || (hadLegacySuppression && inApp.legacyCLISuppressUntil == nil) {
            // Snapshot reads cannot fail because stale bookkeeping cleanup is
            // maintenance, not a reason to make the broker unavailable.
            try? writeInAppFile(inApp)
        }

        var merged = inApp.cooldowns
        for (key, date) in readCLIFile() {
            if inApp.suppressedCLIExpiryMilliseconds[key] == Self.expiryMilliseconds(for: date) {
                continue
            }
            if let legacyUntil = inApp.legacyCLISuppressUntil,
               legacyUntil > currentNow,
               date <= legacyUntil {
                continue
            }
            if let existing = merged[key], existing >= date { continue }
            merged[key] = date
        }
        return merged.filter { $0.value > currentNow }
    }

    // MARK: - In-app file (read/write)

    private func readInAppFile() -> InAppFile {
        guard let data = Self.readBoundedRegularFile(at: storeURL) else { return InAppFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(InAppFile.self, from: data)) ?? InAppFile()
    }

    private func activeInAppFile(at date: Date) -> InAppFile {
        var inApp = readInAppFile()
        inApp.cooldowns = inApp.cooldowns.filter { $0.value > date }
        inApp.suppressedCLIExpiryMilliseconds = inApp.suppressedCLIExpiryMilliseconds.filter {
            Self.date(forExpiryMilliseconds: $0.value) > date
        }
        if let legacyUntil = inApp.legacyCLISuppressUntil, legacyUntil <= date {
            inApp.legacyCLISuppressUntil = nil
        }
        return inApp
    }

    private func writeInAppFile(_ inApp: InAppFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(inApp)
        try writer(data, storeURL)
    }

    private static func expiryMilliseconds(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func date(forExpiryMilliseconds milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    // MARK: - CLI file (read-only)

    private func readCLIFile() -> [String: Date] {
        Self.decodeCooldownMap(from: cliCooldownsURL)
    }

    /// Parses a `{ key: ISO-8601 }` map. Missing file, unparseable JSON, or a
    /// non-object payload all merge as empty — never throws. Individual
    /// entries whose value is not a string, or not a valid ISO-8601 date, are
    /// dropped rather than failing the whole file (mirrors the CLI's
    /// `loadCooldowns`, which drops non-string values one at a time).
    private static func decodeCooldownMap(from url: URL) -> [String: Date] {
        guard let data = readBoundedRegularFile(at: url) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        guard object.count <= maxEntries else { return [:] }
        // The reference broker CLI writes this file with JS `Date.toISOString()`,
        // which always emits fractional seconds; the in-app file never does.
        // Try fractional first, then fall back to whole seconds, so both
        // shapes decode.
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = ISO8601DateFormatter()
        var result: [String: Date] = [:]
        for (key, value) in object {
            guard !key.isEmpty, key.unicodeScalars.count <= maxTargetScalars else { continue }
            guard let iso = value as? String else { continue }
            guard let date = fractionalFormatter.date(from: iso) ?? formatter.date(from: iso) else { continue }
            result[key] = date
        }
        return result
    }

    private static func readBoundedRegularFile(at url: URL) -> Data? {
        let directoryDescriptor = url.deletingLastPathComponent().withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else { return nil }
        defer { Darwin.close(directoryDescriptor) }

        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_nlink == 1,
              fileStatus.st_size > 0,
              fileStatus.st_size <= Int64(maxFileSizeBytes),
              let data = try? handle.read(upToCount: maxFileSizeBytes + 1),
              data.count <= maxFileSizeBytes else {
            return nil
        }
        return data
    }
}
