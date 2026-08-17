//
//  T3InstanceReconciliationTests.swift
//  PinemeterTests
//
//  Pure tests (no IO) for BrokerPolicy.reconcileDiscoveredT3Instances and
//  T3InstanceConfig.status(now:stalenessSeconds:). All fixtures are literal
//  values constructed in-test — no real T3 data is read.
//

import XCTest
@testable import Pinemeter

final class T3InstanceReconciliationTests: XCTestCase {
    // MARK: - Preserving user-owned fields (R-02, D-02)

    func test_reconcile_existingRow_nameBaseURLOverrideAndBoundAccountId_stayByteIdentical() {
        var policy = BrokerPolicy(
            roles: [:],
            t3Instances: [
                T3InstanceConfig(
                    id: "claudeAgent",
                    name: "My Custom Name",
                    baseURLOverride: "http://127.0.0.1:9999",
                    boundAccountId: "acct-123"
                )
            ]
        )

        let discovered = [
            DiscoveredT3Instance(
                instanceId: "claudeAgent",
                driver: "claudeAgent",
                displayName: "WS",
                installed: true,
                checkedAt: Date(),
                modelSlugs: ["claude-fable-5"]
            )
        ]

        _ = policy.reconcileDiscoveredT3Instances(discovered)

        let row = policy.t3Instances.first { $0.id == "claudeAgent" }
        XCTAssertEqual(row?.name, "My Custom Name")
        XCTAssertEqual(row?.baseURLOverride, "http://127.0.0.1:9999")
        XCTAssertEqual(row?.boundAccountId, "acct-123")
    }

    func test_reconcile_bundledSeeds_keepTheirDisplayNamesAfterATersDiscoveryScan() {
        var policy = BrokerPolicy.bundledDefault

        let discovered = [
            DiscoveredT3Instance(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "WS", installed: true),
            DiscoveredT3Instance(instanceId: "claude_autimo", driver: "claudeAgent", displayName: "AU", installed: true),
            DiscoveredT3Instance(instanceId: "codex", driver: "codex", displayName: "Codex", installed: true),
        ]

        _ = policy.reconcileDiscoveredT3Instances(discovered)

        XCTAssertEqual(policy.t3Instances.first { $0.id == "claudeAgent" }?.name, "Claude Agent")
        XCTAssertEqual(policy.t3Instances.first { $0.id == "claude_autimo" }?.name, "Claude (autimo)")
        XCTAssertEqual(policy.t3Instances.first { $0.id == "codex" }?.name, "Codex")
    }

    // MARK: - New rows

    func test_reconcile_newInstalledInstanceWithNoExistingRow_appendsDetectedRowWithSeededName() {
        var policy = BrokerPolicy(roles: [:], t3Instances: [])

        let discovered = [
            DiscoveredT3Instance(instanceId: "cursor", driver: "cursor", displayName: "Cursor", installed: true)
        ]

        let changed = policy.reconcileDiscoveredT3Instances(discovered)

        XCTAssertTrue(changed)
        let row = policy.t3Instances.first { $0.id == "cursor" }
        XCTAssertEqual(row?.origin, .detected)
        XCTAssertEqual(row?.name, "Cursor")
    }

    func test_reconcile_newInstanceWithNoDisplayName_seedsNameFromInstanceId() {
        var policy = BrokerPolicy(roles: [:], t3Instances: [])

        let discovered = [
            DiscoveredT3Instance(instanceId: "cursor", driver: "cursor", displayName: nil, installed: true)
        ]

        _ = policy.reconcileDiscoveredT3Instances(discovered)

        XCTAssertEqual(policy.t3Instances.first { $0.id == "cursor" }?.name, "cursor")
    }

    func test_reconcile_uninstalledInstanceWithNoExistingRow_appendsNothing() {
        var policy = BrokerPolicy(roles: [:], t3Instances: [])

        let discovered = [
            DiscoveredT3Instance(instanceId: "grok", driver: "grok", displayName: "Grok", installed: false)
        ]

        let changed = policy.reconcileDiscoveredT3Instances(discovered)

        XCTAssertFalse(changed)
        XCTAssertTrue(policy.t3Instances.isEmpty)
    }

    func test_reconcile_uninstalledInstanceWithExistingRow_stillRefreshesDriverModelsAndLastSeen() {
        var policy = BrokerPolicy(
            roles: [:],
            t3Instances: [T3InstanceConfig(id: "grok", name: "Grok", origin: .manual)]
        )
        let checkedAt = Date()

        let discovered = [
            DiscoveredT3Instance(
                instanceId: "grok",
                driver: "grok",
                displayName: "Grok",
                installed: false,
                checkedAt: checkedAt,
                modelSlugs: ["grok-build"]
            )
        ]

        let changed = policy.reconcileDiscoveredT3Instances(discovered)

        XCTAssertTrue(changed)
        let row = policy.t3Instances.first { $0.id == "grok" }
        XCTAssertEqual(row?.driver, "grok")
        XCTAssertEqual(row?.detectedModels, ["grok-build"])
        XCTAssertEqual(row?.lastSeenAt, checkedAt)
    }

    // MARK: - Never removing (R-02)

    func test_reconcile_existingRowAbsentFromScan_isRetainedUnchanged() {
        var policy = BrokerPolicy(
            roles: [:],
            t3Instances: [T3InstanceConfig(id: "manual-only", name: "Manual Only", origin: .manual)]
        )

        let changed = policy.reconcileDiscoveredT3Instances([])

        XCTAssertFalse(changed)
        XCTAssertEqual(policy.t3Instances.count, 1)
        XCTAssertEqual(policy.t3Instances.first?.id, "manual-only")
    }

    func test_reconcile_neverDecreasesInstanceCount() {
        var policy = BrokerPolicy(
            roles: [:],
            t3Instances: [
                T3InstanceConfig(id: "claudeAgent", name: "Claude Agent"),
                T3InstanceConfig(id: "manual-only", name: "Manual Only"),
            ]
        )
        let before = policy.t3Instances.count

        _ = policy.reconcileDiscoveredT3Instances([
            DiscoveredT3Instance(instanceId: "codex", driver: "codex", installed: true)
        ])

        XCTAssertGreaterThanOrEqual(policy.t3Instances.count, before)
    }

    // MARK: - Origin promotion (never demoted)

    func test_reconcile_manualRowThatTurnsUpInScan_isPromotedToDetected() {
        var policy = BrokerPolicy(
            roles: [:],
            t3Instances: [T3InstanceConfig(id: "codex", name: "Codex", origin: .manual)]
        )

        _ = policy.reconcileDiscoveredT3Instances([
            DiscoveredT3Instance(instanceId: "codex", driver: "codex", installed: true)
        ])

        XCTAssertEqual(policy.t3Instances.first { $0.id == "codex" }?.origin, .detected)
    }

    func test_reconcile_detectedRow_isNeverDemotedToManual() {
        var policy = BrokerPolicy(
            roles: [:],
            t3Instances: [T3InstanceConfig(id: "codex", name: "Codex", origin: .detected)]
        )

        // The instance is absent from this scan (e.g. T3 briefly closed).
        _ = policy.reconcileDiscoveredT3Instances([])

        XCTAssertEqual(policy.t3Instances.first { $0.id == "codex" }?.origin, .detected)
    }

    // MARK: - Routing is never written from discovery (review CR-02/CR-03)

    func test_reconcile_neverWritesInstanceByModel_evenForASlugUniqueToOneInstalledInstance() {
        var policy = BrokerPolicy(roles: [:], t3: BrokerT3Config(instanceByModel: [:], defaultInstance: "claudeAgent"))

        _ = policy.reconcileDiscoveredT3Instances([
            DiscoveredT3Instance(instanceId: "codex", driver: "codex", installed: true, modelSlugs: ["gpt-5.6-sol"])
        ])

        XCTAssertTrue(
            policy.t3.instanceByModel.isEmpty,
            "untrusted cache data must never write instance_by_model — resolution stays on default_instance"
        )
        let candidate = BrokerCandidate(route: .t3, model: "gpt-5.6-sol")
        XCTAssertEqual(policy.resolvedInstance(for: candidate), "claudeAgent")
    }

    func test_reconcile_seedFableLaneResolution_neverChangesWhenOnlySecondaryClaudeInstanceIsInstalled() {
        // The CR-03 blowout scenario: only claude_autimo (the secondary
        // account's instance) is installed and offers claude-fable-5. The
        // seed's bare `t3/claude-fable-5` candidate must keep resolving to
        // default_instance, whose quota lane it is gated by — never silently
        // re-point at the secondary instance.
        var policy = BrokerPolicy.bundledDefault
        let bareFableCandidate = BrokerCandidate(route: .t3, model: "claude-fable-5")
        let resolutionBefore = policy.resolvedInstance(for: bareFableCandidate)

        _ = policy.reconcileDiscoveredT3Instances([
            DiscoveredT3Instance(instanceId: "claude_autimo", driver: "claudeAgent", installed: true, modelSlugs: ["claude-fable-5"])
        ])

        XCTAssertEqual(policy.resolvedInstance(for: bareFableCandidate), resolutionBefore)
        XCTAssertNil(policy.t3.instanceByModel["claude-fable-5"])
    }

    func test_reconcile_existingInstanceByModelEntry_isNeverTouched() {
        var policy = BrokerPolicy(
            roles: [:],
            t3: BrokerT3Config(instanceByModel: ["gpt-5.6-sol": "claudeAgent"], defaultInstance: "claudeAgent")
        )

        _ = policy.reconcileDiscoveredT3Instances([
            DiscoveredT3Instance(instanceId: "codex", driver: "codex", installed: true, modelSlugs: ["gpt-5.6-sol"])
        ])

        XCTAssertEqual(policy.t3.instanceByModel, ["gpt-5.6-sol": "claudeAgent"])
    }

    // MARK: - Durable deletion via the ignore list (review WR-01)

    func test_removeT3Instance_detectedRow_recordsIgnoreSoNextReconcileDoesNotResurrectIt() {
        var policy = BrokerPolicy(roles: [:], t3: BrokerT3Config(instanceByModel: [:], defaultInstance: "claudeAgent"))
        let discovered = [
            DiscoveredT3Instance(instanceId: "cursor", driver: "cursor", displayName: "Cursor", installed: true)
        ]
        _ = policy.reconcileDiscoveredT3Instances(discovered)
        XCTAssertTrue(policy.t3Instances.contains { $0.id == "cursor" })

        let error = policy.removeT3Instance(id: "cursor")
        XCTAssertNil(error)

        let changed = policy.reconcileDiscoveredT3Instances(discovered)

        XCTAssertFalse(changed, "a scan that only re-reports an ignored instance must be a no-op")
        XCTAssertFalse(
            policy.t3Instances.contains { $0.id == "cursor" },
            "a deleted detected row must not resurrect on the next scan"
        )
        XCTAssertTrue(policy.t3.ignoredInstances.contains("cursor"))
    }

    func test_removeT3Instance_manualRow_recordsIgnoreSoDiscoveryCannotResurrectIt() {
        var policy = BrokerPolicy(
            roles: [:],
            t3: BrokerT3Config(instanceByModel: [:], defaultInstance: "claudeAgent"),
            t3Instances: [T3InstanceConfig(id: "manual-only", name: "Manual Only", origin: .manual)]
        )

        let error = policy.removeT3Instance(id: "manual-only")

        XCTAssertNil(error)
        XCTAssertTrue(policy.t3Instances.isEmpty)
        XCTAssertEqual(policy.t3.ignoredInstances, ["manual-only"])
    }

    func test_removeT3Instance_withLegacyDuplicateIds_removesOnlyTheFirstRow() {
        // Duplicate ids can only come from legacy persisted state (the id
        // binding rejects them); one delete must never destroy both rows'
        // user data (review WR-03).
        var policy = BrokerPolicy(
            roles: [:],
            t3: BrokerT3Config(instanceByModel: [:], defaultInstance: "claudeAgent"),
            t3Instances: [
                T3InstanceConfig(id: "dup", name: "First", origin: .manual),
                T3InstanceConfig(id: "dup", name: "Second", baseURLOverride: "http://127.0.0.1:9999", origin: .manual),
            ]
        )

        let error = policy.removeT3Instance(id: "dup")

        XCTAssertNil(error)
        XCTAssertEqual(policy.t3Instances.map(\.name), ["Second"])
    }

    // MARK: - addDetectedT3Instance (mutation boundary, review IN-10)

    func test_addDetectedT3Instance_clearsIgnoreEntry_soReconcileRefreshesItAgain() {
        var policy = BrokerPolicy(
            roles: [:],
            t3: BrokerT3Config(instanceByModel: [:], defaultInstance: "claudeAgent", ignoredInstances: ["cursor"])
        )
        let discovered = DiscoveredT3Instance(
            instanceId: "cursor", driver: "cursor", displayName: "Cursor", installed: true
        )

        let added = policy.addDetectedT3Instance(discovered)

        XCTAssertTrue(added)
        XCTAssertTrue(policy.t3Instances.contains { $0.id == "cursor" && $0.origin == .detected })
        XCTAssertFalse(policy.t3.ignoredInstances.contains("cursor"))
    }

    func test_addDetectedT3Instance_rejectsDuplicateAndInvalidIds() {
        var policy = BrokerPolicy(
            roles: [:],
            t3Instances: [T3InstanceConfig(id: "cursor", name: "Cursor")]
        )

        let duplicate = policy.addDetectedT3Instance(
            DiscoveredT3Instance(instanceId: "cursor", driver: "cursor", installed: true)
        )
        let invalid = policy.addDetectedT3Instance(
            DiscoveredT3Instance(instanceId: "bad:id", driver: "cursor", installed: true)
        )

        XCTAssertFalse(duplicate)
        XCTAssertFalse(invalid)
        XCTAssertEqual(policy.t3Instances.count, 1)
    }

    func test_reconcile_invalidInstanceId_neverReachesTheInstanceList() {
        var policy = BrokerPolicy(roles: [:], t3Instances: [])

        let changed = policy.reconcileDiscoveredT3Instances([
            DiscoveredT3Instance(instanceId: "bad:id", driver: "cursor", installed: true)
        ])

        XCTAssertFalse(changed)
        XCTAssertTrue(policy.t3Instances.isEmpty)
    }

    // MARK: - Editable row identity and safe renaming

    func test_configCodableRoundTrip_regeneratesRowKeyWithoutChangingEquality() throws {
        let original = T3InstanceConfig(id: "manual", name: "Manual")
        let decoded = try JSONDecoder().decode(
            T3InstanceConfig.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertNotEqual(decoded.rowKey, original.rowKey)
        XCTAssertEqual(decoded, original)
    }

    func test_renameT3Instance_rejectsReferencedIdWithoutMutatingPolicy() {
        var policy = BrokerPolicy(
            roles: ["execution": [BrokerCandidate(route: .t3, instance: "manual", model: "model")]],
            t3Instances: [T3InstanceConfig(id: "manual", name: "Manual")]
        )
        let rowKey = policy.t3Instances[0].rowKey

        let error = policy.renameT3Instance(rowKey: rowKey, to: "renamed")

        XCTAssertNotNil(error)
        XCTAssertEqual(policy.t3Instances[0].id, "manual")
    }

    func test_renameT3Instance_unreferencedRowChangesIdAndClearsIgnore() {
        var policy = BrokerPolicy(
            roles: [:],
            t3: BrokerT3Config(
                instanceByModel: [:],
                defaultInstance: "claudeAgent",
                ignoredInstances: ["renamed"]
            ),
            t3Instances: [T3InstanceConfig(id: "manual", name: "Manual")]
        )
        let rowKey = policy.t3Instances[0].rowKey

        let error = policy.renameT3Instance(rowKey: rowKey, to: "renamed")

        XCTAssertNil(error)
        XCTAssertEqual(policy.t3Instances[0].id, "renamed")
        XCTAssertFalse(policy.t3.ignoredInstances.contains("renamed"))
    }

    // MARK: - Idempotence

    func test_reconcile_sameScanTwice_returnsFalseOnTheSecondRun() {
        var policy = BrokerPolicy(roles: [:], t3Instances: [])
        let discovered = [
            DiscoveredT3Instance(
                instanceId: "codex", driver: "codex", displayName: "Codex",
                installed: true, checkedAt: Date(), modelSlugs: ["gpt-5.6-sol"]
            )
        ]

        let firstRun = policy.reconcileDiscoveredT3Instances(discovered)
        let secondRun = policy.reconcileDiscoveredT3Instances(discovered)

        XCTAssertTrue(firstRun)
        XCTAssertFalse(secondRun)
    }

    // MARK: - boundAccountId ownership (D-02)

    func test_reconcile_everyCreatedRow_hasNilBoundAccountId() {
        var policy = BrokerPolicy(roles: [:], t3Instances: [])

        _ = policy.reconcileDiscoveredT3Instances([
            DiscoveredT3Instance(instanceId: "claude_autimo", driver: "claudeAgent", installed: true)
        ])

        XCTAssertNil(policy.t3Instances.first { $0.id == "claude_autimo" }?.boundAccountId)
    }

    // MARK: - Untouched fields (RESEARCH Q-1)

    func test_reconcile_neverTouchesRolesUsageLanesOrDefaultInstance() {
        var policy = BrokerPolicy.bundledDefault
        let rolesBefore = policy.roles
        let usageLanesBefore = policy.usageLanes
        let defaultInstanceBefore = policy.t3.defaultInstance

        _ = policy.reconcileDiscoveredT3Instances([
            DiscoveredT3Instance(instanceId: "cursor", driver: "cursor", installed: true, modelSlugs: ["cursor-model"])
        ])

        XCTAssertEqual(policy.roles, rolesBefore)
        XCTAssertEqual(policy.usageLanes, usageLanesBefore)
        XCTAssertEqual(policy.t3.defaultInstance, defaultInstanceBefore)
    }

    // MARK: - T3InstanceConfig.status(now:stalenessSeconds:)

    func test_status_manualOrigin_isAlwaysManual() {
        let instance = T3InstanceConfig(id: "manual", name: "Manual", origin: .manual, lastSeenAt: Date())
        XCTAssertEqual(instance.status(now: Date(), stalenessSeconds: 1200), .manual)
    }

    func test_status_detectedOriginWithinStaleness_isDetected() {
        let instance = T3InstanceConfig(
            id: "codex", name: "Codex", origin: .detected, lastSeenAt: Date().addingTimeInterval(-60)
        )
        XCTAssertEqual(instance.status(now: Date(), stalenessSeconds: 1200), .detected)
    }

    func test_status_detectedOriginPastStaleness_isStale() {
        let instance = T3InstanceConfig(
            id: "codex", name: "Codex", origin: .detected, lastSeenAt: Date().addingTimeInterval(-3600)
        )
        XCTAssertEqual(instance.status(now: Date(), stalenessSeconds: 1200), .stale)
    }

    func test_status_detectedOriginWithNilLastSeenAt_isStale() {
        let instance = T3InstanceConfig(id: "codex", name: "Codex", origin: .detected, lastSeenAt: nil)
        XCTAssertEqual(instance.status(now: Date(), stalenessSeconds: 1200), .stale)
    }

    func test_status_slightlyFutureLastSeenAt_clampsToZeroAgeInsteadOfNegative() {
        // Small clock skew survives the discovery boundary's future-timestamp
        // rejection; a negative age must clamp to zero (review IN-04).
        let instance = T3InstanceConfig(
            id: "codex", name: "Codex", origin: .detected, lastSeenAt: Date().addingTimeInterval(60)
        )
        XCTAssertEqual(instance.status(now: Date(), stalenessSeconds: 1200), .detected)
    }
}
