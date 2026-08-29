//
//  BrokerPresetManifest.swift
//  Pinemeter
//
//  The remote broker preset manifest: a small GitHub-hosted JSON file listing
//  extra named rule profiles (``BrokerAgentProfile``) the user may explicitly
//  apply. Fetched frequently by ``PresetManifestService`` and never routes
//  anything by itself — see ``BrokerSettings/updateRemotePresets(_:)``.
//
//  Decoding this is a TRUST BOUNDARY: the payload is attacker-reachable
//  (anyone who can answer for the configured URL controls it), its contents
//  are rendered straight into the profile bar's menu, and applying an entry
//  rewrites live routing. Every entry is validated independently — a
//  malformed or hostile preset is skipped, never allowed to fail the whole
//  manifest, and never allowed to smuggle an unbounded string or a spoofed
//  identity into the UI or the routing table.
//

import Foundation

/// Why a preset manifest payload could not be read at all. Per-entry
/// problems never reach this — see ``BrokerPresetManifest/decode(from:)``.
enum BrokerPresetManifestError: LocalizedError {
    case malformed

    var errorDescription: String? {
        switch self {
        case .malformed:
            return "That is not a Pinemeter preset manifest."
        }
    }
}

/// A validated remote preset manifest: a schema version (informational —
/// decoding is forward-compatible regardless of its value) and the presets
/// that survived per-entry validation, in manifest order.
struct BrokerPresetManifest: Equatable, Sendable {
    var schemaVersion: Int
    var presets: [BrokerAgentProfile]

    /// Hard cap on how many presets one manifest may contribute. Extras are
    /// dropped, not an error — a manifest that grows past this is a scaling
    /// problem for the profile menu, not a corruption.
    static let maxPresets = 32

    /// Hard cap on the raw payload a fetch will even attempt to decode.
    /// Enforced by ``PresetManifestService`` before this type ever sees the
    /// bytes; kept here too so the limit has exactly one source of truth.
    static let maxPayloadBytes = 512 * 1024

    static let maxNameScalars = 60
    static let maxDetailScalars = 140

    /// SF Symbol used when an entry's `symbol_name` is missing or invalid.
    static let fallbackSymbolName = "shippingbox"

    /// Parses and validates a manifest payload.
    ///
    /// Only throws when the top-level payload is not a JSON object at all —
    /// there is nothing to salvage from that. Everything below the top level
    /// degrades entry-by-entry: an unreadable `presets` array decodes to no
    /// presets, and a bad individual entry is skipped rather than failing the
    /// batch (mirrors ``BrokerAgentProfile/decodeExported(from:)``'s
    /// recognise-before-decode posture, applied per entry instead of once).
    static func decode(from data: Data) throws -> BrokerPresetManifest {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any]
        else {
            throw BrokerPresetManifestError.malformed
        }

        let schemaVersion = (object["schema_version"] as? Int) ?? 1
        let rawPresets = (object["presets"] as? [[String: Any]]) ?? []

        // Seeded with the built-in ids so a manifest can never shadow a
        // compiled profile — the profile bar's "Built-in" section would
        // otherwise silently start pointing at attacker-controlled rules.
        var takenIDs = Set(BrokerAgentProfile.builtIns.map(\.id))
        var accepted: [BrokerAgentProfile] = []

        for raw in rawPresets {
            guard accepted.count < maxPresets else { break }
            guard let profile = decodeEntry(raw, excluding: takenIDs) else { continue }
            takenIDs.insert(profile.id)
            accepted.append(profile)
        }

        return BrokerPresetManifest(schemaVersion: schemaVersion, presets: accepted)
    }

    /// Strict per-entry recognition and sanitisation. Returns `nil` — never
    /// throws — for anything that fails a check, so one bad preset costs
    /// exactly one preset.
    ///
    /// Order matters only for cost: id and rules-shape are checked first
    /// because they are the cheapest ways to reject a non-preset object
    /// before spending effort sanitising text nobody will use.
    private static func decodeEntry(
        _ object: [String: Any], excluding takenIDs: Set<UUID>
    ) -> BrokerAgentProfile? {
        // An explicit, unique, non-colliding id is what makes the active-
        // profile pin and the "Updated" chip work across refreshes — an
        // entry that can't offer one is not a stable preset.
        guard let idString = object["id"] as? String,
              let id = UUID(uuidString: idString),
              !takenIDs.contains(id)
        else { return nil }

        // Recognise before decoding, exactly like the file-import boundary:
        // any JSON object at all would otherwise decode to a profile
        // carrying the bundled default rules, which is a trap here too.
        guard BrokerAgentProfile.hasRecognizedRules(object),
              let rulesObject = object["rules"] as? [String: Any],
              let rulesData = try? JSONSerialization.data(withJSONObject: rulesObject),
              let ruleSet = try? JSONDecoder().decode(BrokerRuleSet.self, from: rulesData)
        else { return nil }

        let name = sanitize(object["name"] as? String ?? "", maxScalars: maxNameScalars)
        guard !name.isEmpty else { return nil }
        let detail = sanitize(object["detail"] as? String ?? "", maxScalars: maxDetailScalars)

        let requestedSymbol = object["symbol_name"] as? String ?? ""
        let symbolName = T3InstanceConfig.isValidIdentifier(requestedSymbol, maxLength: 64)
            ? requestedSymbol
            : fallbackSymbolName

        // `isBuiltIn` stays false: remote-preset identity (and the edit
        // restrictions that follow from it) is tracked separately by
        // `BrokerSettings.isRemotePreset(id:)`, keyed on manifest membership
        // rather than a flag carried on the profile itself.
        return BrokerAgentProfile(
            id: id, name: name, detail: detail, symbolName: symbolName,
            isBuiltIn: false, rules: ruleSet
        )
    }

    /// Strips control characters, newlines, and default-ignorable code
    /// points, then caps at `maxScalars` SCALARS.
    ///
    /// Mirrors ``BrokerPolicy/redactedCaller(_:)`` minus its `?`
    /// substitution: a caller id is logged and needs a fixed-width
    /// placeholder for the unsafe run; a preset name renders straight into a
    /// menu, where dropping the unsafe scalar reads better than a string
    /// full of question marks. Counting scalars rather than `Character`s is
    /// the same defence `redactedCaller` uses: a single `Character` can carry
    /// thousands of combining marks, none of them control, newline, or
    /// default-ignorable, so a grapheme-counted cap would not actually bound
    /// the string.
    private static func sanitize(_ raw: String, maxScalars: Int) -> String {
        let safeScalars = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.newlines.contains(scalar)
                && !scalar.properties.isDefaultIgnorableCodePoint
        }
        let capped = String(String.UnicodeScalarView(safeScalars.prefix(maxScalars)))
        return capped.trimmingCharacters(in: .whitespaces)
    }
}
