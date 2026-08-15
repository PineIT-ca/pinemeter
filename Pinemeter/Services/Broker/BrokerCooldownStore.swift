//
//  BrokerCooldownStore.swift
//  Pinemeter
//
//  Persisted cooldown map for the `down`/`up` tools, read-merged with the
//  trixie-box CLI's own exhaustion cooldowns (~/.model-broker/cooldowns.json)
//  so a lane the CLI marked down over a hidden quota wall is not recommended
//  by Pinemeter either (RESEARCH Open Questions 1 and 3).
//
//  Follows the CacheRepository disk-persistence convention: an actor,
//  JSONEncoder/Decoder with the `.iso8601` date strategy, atomic file writes,
//  and decode-failure-returns-empty (never throws) per the SettingsRepository
//  decode-safety convention. In-app state writes only its own file; the CLI
//  file is read-only from this process.
//

import Foundation

actor BrokerCooldownStore {
    /// Guidance constant surfaced in the `down` tool's description text: the
    /// trixie-box CLI's own T3 credit-wall exhaustion cooldown length.
    static let defaultT3ExhaustionSeconds: TimeInterval = 21600

    static let defaultDownMinutes = 60
    static let minDownMinutes = 1
    static let maxDownMinutes = 10080

    private let storeURL: URL
    private let cliCooldownsURL: URL
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - fileManager: Injectable for tests.
    ///   - storeDirectory: Directory the in-app cooldown file lives in. Defaults
    ///     to `Application Support/Pinemeter`. Injectable so tests use a temp dir.
    ///   - cliCooldownsURL: The trixie-box CLI's cooldown file. Defaults to
    ///     `~/.model-broker/cooldowns.json`. Injectable so tests use a temp file.
    ///   - now: Injected clock; the only time source this store reads.
    init(
        fileManager: FileManager = .default,
        storeDirectory: URL? = nil,
        cliCooldownsURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let baseDirectory: URL
        if let storeDirectory {
            baseDirectory = storeDirectory
        } else {
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            baseDirectory = appSupport.appendingPathComponent("Pinemeter", isDirectory: true)
        }
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        self.storeURL = baseDirectory.appendingPathComponent("broker-cooldowns.json")
        self.cliCooldownsURL = cliCooldownsURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".model-broker", isDirectory: true)
            .appendingPathComponent("cooldowns.json")
        self.now = now
    }

    /// Marks `target` unavailable until `now + minutes`. `minutes` clamps to
    /// 1...10080 (one week) and defaults to 60. Persists to the in-app file only.
    @discardableResult
    func down(target: String, minutes: Int? = nil) -> Date {
        let clampedMinutes = min(
            max(minutes ?? Self.defaultDownMinutes, Self.minDownMinutes),
            Self.maxDownMinutes
        )
        let availableAt = now().addingTimeInterval(TimeInterval(clampedMinutes) * 60)
        var inApp = readInAppFile()
        inApp[target] = availableAt
        writeInAppFile(inApp)
        return availableAt
    }

    /// Restores `target` to immediate availability. Persists to the in-app
    /// file only — this can never touch the CLI's exhaustion signal.
    func up(target: String) {
        var inApp = readInAppFile()
        inApp.removeValue(forKey: target)
        writeInAppFile(inApp)
    }

    /// The merged view `BrokerEngine.decide` reads: in-app entries union the
    /// CLI's cooldowns, the LATER `availableAt` wins on a shared key (most
    /// restrictive), and entries whose `availableAt` is already past are
    /// dropped (self-expiry — there is no cleanup pass).
    func mergedSnapshot() -> [String: Date] {
        let currentNow = now()
        var merged = readInAppFile()
        for (key, date) in readCLIFile() {
            if let existing = merged[key], existing >= date { continue }
            merged[key] = date
        }
        return merged.filter { $0.value > currentNow }
    }

    // MARK: - In-app file (read/write)

    private func readInAppFile() -> [String: Date] {
        Self.decodeCooldownMap(from: storeURL)
    }

    private func writeInAppFile(_ cooldowns: [String: Date]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cooldowns) else { return }
        try? data.write(to: storeURL, options: .atomic)
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
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        // The trixie-box CLI writes this file with JS `Date.toISOString()`,
        // which always emits fractional seconds; the in-app file never does.
        // Try fractional first, then fall back to whole seconds, so both
        // shapes decode.
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = ISO8601DateFormatter()
        var result: [String: Date] = [:]
        for (key, value) in object {
            guard let iso = value as? String else { continue }
            guard let date = fractionalFormatter.date(from: iso) ?? formatter.date(from: iso) else { continue }
            result[key] = date
        }
        return result
    }
}
