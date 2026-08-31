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
//  masks current CLI cooldowns until they would have expired.
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
        guard !target.isEmpty, target.unicodeScalars.count <= Self.maxTargetScalars else {
            throw BrokerCooldownError.invalidTarget
        }
        let clampedMinutes = min(
            max(minutes ?? Self.defaultDownMinutes, Self.minDownMinutes),
            Self.maxDownMinutes
        )
        let currentNow = now()
        let availableAt = currentNow.addingTimeInterval(TimeInterval(clampedMinutes) * 60)
        var inApp = activeInAppCooldowns(at: currentNow)
        let cooldownCount = inApp.keys.lazy.filter { $0 != Self.cliResetMarker }.count
        guard inApp[target] != nil || cooldownCount < Self.maxEntries else {
            throw BrokerCooldownError.capacityExceeded
        }
        inApp[target] = availableAt
        try writeInAppFile(inApp)
        return availableAt
    }

    /// Restores `target` to immediate availability. Persists to the in-app
    /// file only — this can never touch the CLI's exhaustion signal.
    func up(target: String) throws {
        guard !target.isEmpty, target.unicodeScalars.count <= Self.maxTargetScalars else {
            throw BrokerCooldownError.invalidTarget
        }
        var inApp = activeInAppCooldowns(at: now())
        inApp.removeValue(forKey: target)
        try writeInAppFile(inApp)
    }

    /// Clears every cooldown source the broker merges.
    func reset() throws {
        let currentNow = now()
        let suppressUntil = readCLIFile().values.filter { $0 > currentNow }.max()
        try writeInAppFile(suppressUntil.map { [Self.cliResetMarker: $0] } ?? [:])
    }

    /// The merged view `BrokerEngine.decide` reads: in-app entries union the
    /// CLI's cooldowns, the LATER `availableAt` wins on a shared key (most
    /// restrictive), and entries whose `availableAt` is already past are
    /// dropped (self-expiry — there is no cleanup pass).
    func mergedSnapshot() -> [String: Date] {
        let currentNow = now()
        var merged = readInAppFile()
        let suppressesCLI = merged.removeValue(forKey: Self.cliResetMarker).map { $0 > currentNow } ?? false
        if !suppressesCLI {
            for (key, date) in readCLIFile() {
                if let existing = merged[key], existing >= date { continue }
                merged[key] = date
            }
        }
        return merged.filter { $0.value > currentNow }
    }

    // MARK: - In-app file (read/write)

    private func readInAppFile() -> [String: Date] {
        Self.decodeCooldownMap(from: storeURL)
    }

    private func activeInAppCooldowns(at date: Date) -> [String: Date] {
        readInAppFile().filter { $0.value > date }
    }

    private func writeInAppFile(_ cooldowns: [String: Date]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cooldowns)
        try writer(data, storeURL)
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
        guard object.count <= maxEntries
                || (object.count == maxEntries + 1 && object[cliResetMarker] != nil)
        else { return [:] }
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
