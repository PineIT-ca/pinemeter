//
//  T3InstanceDiscoveryProtocol.swift
//  Pinemeter
//

import Foundation

/// Enumerates the local T3 desktop app's provider instances from its per-instance
/// cache files (`<t3Base>/caches/<instanceId>.json`). Read-only: this protocol
/// never mutates T3 state, and its conformers never read the T3 user settings
/// file or any credential-bearing source (see `T3InstanceDiscoveryService`).
protocol T3InstanceDiscoveryProtocol: Sendable {
    /// Scans the local T3 caches directory.
    ///
    /// `nil` means "no information" — the source was missing, unreadable, or
    /// could not be enumerated. `[]` means "the source was readable and
    /// reported nothing" — an authoritative empty set.
    ///
    /// Callers MUST skip reconciliation entirely on `nil`, so a transient
    /// unreadable state (T3 not installed, disk hiccup, permissions change)
    /// can never be mistaken for "the user has no instances" and prune saved
    /// configuration (R-05).
    func scan() async -> [DiscoveredT3Instance]?
}

/// A discovery that always answers "no information." Used as `AppModel`'s
/// default under XCTest so no test can accidentally scan the developer's real
/// `~/.t3/caches` (review WR-08); tests that exercise discovery inject
/// `T3InstanceDiscoveryFake` explicitly.
struct T3NullInstanceDiscovery: T3InstanceDiscoveryProtocol {
    func scan() async -> [DiscoveredT3Instance]? { nil }
}
