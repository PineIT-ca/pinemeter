//
//  BrokerAgentProfileTests.swift
//  PinemeterTests
//
//  Agent rule profiles: what a profile carries, what it must never carry, and
//  the save/load/import mutations behind the profile bar.
//
//  The load-time invariant is the one that matters most: applying a profile
//  rewrites routing rules and nothing else. A profile exported on one Mac and
//  imported on another must not delete that Mac's T3 instances, unbind its
//  accounts, or resurrect rows it deleted.
//

import XCTest
@testable import Pinemeter

final class BrokerAgentProfileTests: XCTestCase {
    // MARK: - Fixtures

    /// A policy carrying machine-local state that no profile may touch.
    private func makePolicyWithMachineState() -> BrokerPolicy {
        var policy = BrokerPolicy.bundledDefault
        policy.t3Instances = [
            T3InstanceConfig(
                id: "claudeAgent",
                name: "Renamed By User",
                boundAccountId: "account-1",
                origin: .detected,
                driver: "claudeAgent",
                detectedModels: ["claude-fable-5"],
                lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            T3InstanceConfig(id: "codex", name: "Codex", origin: .detected, driver: "codex"),
        ]
        policy.t3.ignoredInstances = ["deleted-by-user"]
        policy.usageLanes = ["t3/claude-fable-5": .claudeAccount(
            accountId: "account-1", labelContains: nil, isPrimary: nil
        )]
        return policy
    }

    private func makeSettings() -> BrokerSettings {
        BrokerSettings(isEnabled: true, port: 43117, policy: makePolicyWithMachineState())
    }

    // MARK: - What a rule set carries

    func test_ruleSet_carriesRulesAndNotMachineState() {
        let policy = makePolicyWithMachineState()
        let rules = policy.ruleSet

        XCTAssertEqual(rules.roles, policy.roles)
        XCTAssertEqual(rules.thresholds, policy.thresholds)
        XCTAssertEqual(rules.callers, policy.callers)
        XCTAssertEqual(rules.agentModelAliases, policy.agentModelAliases)
        XCTAssertEqual(rules.instanceByModel, policy.t3.instanceByModel)
        XCTAssertEqual(rules.defaultInstance, policy.t3.defaultInstance)

        // The exclusions are the point of the type, so they are asserted on
        // the encoded form: a future field added to the struct without a
        // decision about portability shows up here.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try! encoder.encode(rules), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("t3_instances"))
        XCTAssertFalse(json.contains("ignored_instances"))
        XCTAssertFalse(json.contains("usage_lanes"))
        XCTAssertFalse(json.contains("account-1"))
    }

    func test_applyRules_leavesInstancesIgnoreListAndUsageLanesUntouched() {
        var policy = makePolicyWithMachineState()
        let instancesBefore = policy.t3Instances
        let ignoredBefore = policy.t3.ignoredInstances
        let lanesBefore = policy.usageLanes

        policy.apply(BrokerAgentProfile.conserveQuota.rules)

        XCTAssertEqual(policy.t3Instances, instancesBefore)
        XCTAssertEqual(policy.t3.ignoredInstances, ignoredBefore)
        XCTAssertEqual(policy.usageLanes, lanesBefore)
        XCTAssertEqual(policy.roles, BrokerAgentProfile.conserveQuota.rules.roles)
        XCTAssertEqual(policy.thresholds, BrokerAgentProfile.conserveQuota.rules.thresholds)
    }

    func test_applyProfile_throughSettings_preservesUserRenamedInstanceAndBinding() {
        var settings = makeSettings()

        settings.applyProfile(id: BrokerAgentProfile.maxQualityID)

        XCTAssertEqual(settings.activeProfileID, BrokerAgentProfile.maxQualityID)
        XCTAssertEqual(settings.policy.t3Instances.first?.name, "Renamed By User")
        XCTAssertEqual(settings.policy.t3Instances.first?.boundAccountId, "account-1")
        XCTAssertEqual(settings.policy.usageLanes.count, 1)
    }

    func test_applyProfile_unknownId_changesNothing() {
        var settings = makeSettings()
        let before = settings

        settings.applyProfile(id: UUID())

        XCTAssertEqual(before.policy, settings.policy)
        XCTAssertEqual(before.activeProfileID, settings.activeProfileID)
    }

    // MARK: - Edited state

    func test_hasUnsavedProfileEdits_isFalseUntilTheRulesActuallyDiverge() {
        var settings = makeSettings()
        settings.applyProfile(id: BrokerAgentProfile.balancedID)
        XCTAssertFalse(settings.hasUnsavedProfileEdits)

        // A machine-state change is not a rule change: renaming an instance
        // must not make the profile look edited.
        settings.policy.t3Instances[0].name = "Another Name"
        XCTAssertFalse(settings.hasUnsavedProfileEdits)

        settings.policy.thresholds.sessionPct = 61
        XCTAssertTrue(settings.hasUnsavedProfileEdits)
    }

    func test_revertToActiveProfile_restoresRulesAndKeepsMachineState() {
        var settings = makeSettings()
        settings.applyProfile(id: BrokerAgentProfile.balancedID)
        settings.policy.thresholds.sessionPct = 61
        settings.policy.roles["review"] = [BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001")]
        settings.policy.t3Instances[0].boundAccountId = "account-9"

        settings.revertToActiveProfile()

        XCTAssertFalse(settings.hasUnsavedProfileEdits)
        XCTAssertEqual(settings.policy.thresholds, BrokerAgentProfile.balanced.rules.thresholds)
        XCTAssertEqual(settings.policy.t3Instances[0].boundAccountId, "account-9")
    }

    // MARK: - Saving

    func test_saveActiveProfile_builtIn_refusesAndLeavesTheShippedRulesIntact() {
        var settings = makeSettings()
        settings.applyProfile(id: BrokerAgentProfile.balancedID)
        settings.policy.thresholds.sessionPct = 61

        XCTAssertFalse(settings.saveActiveProfile())
        XCTAssertTrue(settings.hasUnsavedProfileEdits)
        XCTAssertEqual(BrokerAgentProfile.balanced.rules.thresholds.sessionPct, 90)
    }

    func test_createProfile_capturesTheLiveRulesAndBecomesActive() {
        var settings = makeSettings()
        settings.policy.thresholds.sessionPct = 61

        let id = settings.createProfile(named: "Crunch Week")

        XCTAssertEqual(settings.activeProfileID, id)
        XCTAssertEqual(settings.activeProfile?.name, "Crunch Week")
        XCTAssertFalse(settings.hasUnsavedProfileEdits)
        XCTAssertEqual(settings.profiles.first?.rules.thresholds.sessionPct, 61)
        XCTAssertFalse(settings.profiles.first?.isBuiltIn ?? true)
    }

    func test_saveActiveProfile_userProfile_writesTheLiveRulesBack() {
        var settings = makeSettings()
        settings.createProfile(named: "Mine")
        settings.policy.thresholds.weeklyPct = 55
        XCTAssertTrue(settings.hasUnsavedProfileEdits)

        XCTAssertTrue(settings.saveActiveProfile())

        XCTAssertFalse(settings.hasUnsavedProfileEdits)
        XCTAssertEqual(settings.profiles.first?.rules.thresholds.weeklyPct, 55)
    }

    // MARK: - Naming

    func test_uniqueProfileName_suffixesCollisionsCaseInsensitively() {
        var settings = makeSettings()
        settings.createProfile(named: "Crunch")

        XCTAssertEqual(settings.uniqueProfileName("crunch"), "crunch 2")
        // Built-in names are taken too: two rows both reading "Balanced" would
        // make the menu unusable.
        XCTAssertEqual(settings.uniqueProfileName("Balanced"), "Balanced 2")
        XCTAssertEqual(settings.uniqueProfileName("  "), "Untitled Profile")
    }

    func test_renameProfile_appliesUniquenessAndIgnoresBlankNames() {
        var settings = makeSettings()
        let id = settings.createProfile(named: "Crunch")
        settings.createProfile(named: "Other")

        settings.renameProfile(id: id, to: "   ")
        XCTAssertEqual(settings.profiles.first { $0.id == id }?.name, "Crunch")

        settings.renameProfile(id: id, to: "Other")
        XCTAssertEqual(settings.profiles.first { $0.id == id }?.name, "Other 2")
    }

    // MARK: - Deleting

    func test_deleteProfile_keepsTheRulesLoadedAndClearsTheAssociation() {
        var settings = makeSettings()
        settings.policy.thresholds.sessionPct = 61
        let id = settings.createProfile(named: "Mine")
        let rulesBefore = settings.policy.ruleSet

        settings.deleteProfile(id: id)

        XCTAssertNil(settings.activeProfileID)
        XCTAssertNil(settings.activeProfile)
        XCTAssertEqual(settings.policy.ruleSet, rulesBefore, "deleting a profile must not re-route anything")
        XCTAssertFalse(settings.hasUnsavedProfileEdits, "no profile is active, so nothing can be edited")
    }

    // MARK: - Import / export

    func test_importProfile_regeneratesACollidingIdAndDeduplicatesTheName() {
        var settings = makeSettings()
        let mine = BrokerAgentProfile(name: "Shared", rules: .default)
        settings.profiles = [mine]

        let storedID = settings.importProfile(mine)

        XCTAssertNotEqual(storedID, mine.id, "a colliding id must not overwrite the existing profile")
        XCTAssertEqual(settings.profiles.count, 2)
        XCTAssertEqual(settings.profiles.last?.name, "Shared 2")
    }

    func test_importProfile_regeneratesAnIdCollidingWithARemotePreset() {
        var settings = makeSettings()
        let preset = BrokerAgentProfile(name: "Remote", rules: .default)
        settings.remotePresets = [preset]

        let storedID = settings.importProfile(preset)

        XCTAssertNotEqual(storedID, preset.id)
        XCTAssertEqual(settings.profiles.last?.id, storedID)
    }

    func test_importProfile_neverGrantsBuiltInStatus() throws {
        var settings = makeSettings()
        // A hand-edited file claiming to be built-in: honouring it would make
        // a user-owned profile that can never be renamed, saved or deleted.
        let hostile = """
        {"id":"\(UUID().uuidString)","name":"Trojan","detail":"","symbol_name":"leaf",
         "is_built_in":true,"rules":{"default_instance":"claudeAgent"}}
        """
        let decoded = try JSONDecoder().decode(BrokerAgentProfile.self, from: Data(hostile.utf8))
        XCTAssertFalse(decoded.isBuiltIn)

        let id = settings.importProfile(decoded)
        XCTAssertFalse(settings.profiles.first { $0.id == id }?.isBuiltIn ?? true)
    }

    func test_importProfile_doesNotApplyTheImportedRules() {
        var settings = makeSettings()
        settings.applyProfile(id: BrokerAgentProfile.balancedID)
        var imported = BrokerAgentProfile(name: "Imported", rules: .default)
        imported.rules.thresholds.sessionPct = 51

        settings.importProfile(imported)

        XCTAssertEqual(settings.activeProfileID, BrokerAgentProfile.balancedID)
        XCTAssertEqual(settings.policy.thresholds.sessionPct, 90)
    }

    func test_exportableProfile_carriesTheRulesOnScreenNotTheSavedOnes() {
        var settings = makeSettings()
        settings.applyProfile(id: BrokerAgentProfile.balancedID)
        settings.policy.thresholds.sessionPct = 61

        XCTAssertEqual(settings.exportableProfile(named: "Snapshot").rules.thresholds.sessionPct, 61)
    }

    func test_profile_encodeDecodeRoundTripsEveryRule() throws {
        var profile = BrokerAgentProfile(name: "Round Trip", rules: BrokerAgentProfile.conserveQuota.rules)
        profile.detail = "detail"

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(BrokerAgentProfile.self, from: data)

        XCTAssertEqual(decoded.name, profile.name)
        XCTAssertEqual(decoded.detail, profile.detail)
        XCTAssertEqual(decoded.rules, profile.rules)
    }

    // MARK: - Missing instance references

    func test_unknownInstanceReferences_listsEveryIdWithNoRowFromAllThreeSources() {
        var settings = makeSettings()
        // Candidate qualifier, `instance_by_model` value and `default_instance`
        // are the three places a rule can name an instance; all three are
        // covered here because a caption that misses one is worse than none.
        var rules = BrokerRuleSet(
            roles: [
                "review": [
                    BrokerCandidate(route: .t3, instance: "claudeAgent", model: "claude-fable-5"),
                    BrokerCandidate(route: .t3, instance: "nowhere", model: "claude-fable-5"),
                    // Route-qualifier only: a native candidate carries no
                    // instance even if one is passed, so it contributes nothing.
                    BrokerCandidate(route: .native, instance: "ignored", model: "claude-opus-5"),
                ]
            ],
            instanceByModel: ["gpt-5.6-sol": "codex", "other": "also-nowhere"],
            defaultInstance: "claudeAgent"
        )

        XCTAssertEqual(settings.unknownInstanceReferences(in: rules), ["also-nowhere", "nowhere"])

        rules.defaultInstance = "gone"
        XCTAssertEqual(settings.unknownInstanceReferences(in: rules), ["also-nowhere", "gone", "nowhere"])

        settings.policy.t3Instances = []
        XCTAssertTrue(settings.unknownInstanceReferences(in: rules).contains("claudeAgent"))
    }

    /// The shipped seed routes judgment work to `t3:*`, which names no instance
    /// at all — so the caption can only ever report the ids the seed's wiring
    /// really needs, and never the sentinel.
    func test_unknownInstanceReferences_neverNamesTheAnyInstanceSentinel() {
        var settings = BrokerSettings.default
        settings.policy.t3Instances = [T3InstanceConfig(id: "claudeAgent", name: "Claude Agent")]

        XCTAssertEqual(
            settings.unknownInstanceReferences(in: settings.policy.ruleSet),
            ["codex"],
            "only `instance_by_model`'s codex row is missing; `t3:*` contributes nothing"
        )

        settings.policy.t3Instances.append(T3InstanceConfig(id: "codex", name: "Codex"))
        XCTAssertEqual(
            settings.unknownInstanceReferences(in: settings.policy.ruleSet), [],
            "a Mac with both wired rows gets no caption from the shipped rules"
        )
    }

    func test_unknownInstanceReferences_ignoresTheSentinelInEveryRulePosition() {
        var settings = makeSettings()
        settings.policy.t3Instances = [T3InstanceConfig(id: "claudeAgent", name: "Claude Agent")]
        let rules = BrokerRuleSet(
            roles: [
                "review": [
                    BrokerCandidate(
                        route: .t3, instance: BrokerCandidate.anyInstance, model: "claude-fable-5"
                    )
                ]
            ],
            instanceByModel: [:],
            defaultInstance: "claudeAgent"
        )

        XCTAssertEqual(settings.unknownInstanceReferences(in: rules), [])
    }

    // MARK: - Built-ins

    func test_builtIns_haveStableUniqueIdsAndNames() {
        let ids = BrokerAgentProfile.builtIns.map(\.id)
        let names = BrokerAgentProfile.builtIns.map(\.name)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(BrokerAgentProfile.builtIn(id: BrokerAgentProfile.conserveID)?.name, "Conserve Quota")
        XCTAssertNil(BrokerAgentProfile.builtIn(id: UUID()))
    }

    func test_builtIns_areAllMarkedBuiltInAndCarryEveryShippedRole() {
        let shippedRoles = Set(BrokerPolicy.bundledDefault.roles.keys)
        for profile in BrokerAgentProfile.builtIns {
            XCTAssertTrue(profile.isBuiltIn, "\(profile.name) must be built-in")
            XCTAssertFalse(profile.detail.isEmpty, "\(profile.name) needs a one-line description")
            XCTAssertEqual(
                Set(profile.rules.roles.keys), shippedRoles,
                "\(profile.name) must answer every role the shipped policy defines"
            )
            for (role, chain) in profile.rules.roles {
                XCTAssertFalse(chain.isEmpty, "\(profile.name)/\(role) has an empty chain")
            }
        }
    }

    /// D-03, applied to every shipped profile rather than only the seed: a
    /// built-in must never introduce the (effort-free model, stored effort)
    /// pair the editor's clamp exists to prevent.
    func test_builtIns_noCandidateCarriesEffortOnAnEffortFreeModel() {
        for profile in BrokerAgentProfile.builtIns {
            for (role, chain) in profile.rules.roles {
                for candidate in chain where candidate.effort != nil {
                    XCTAssertTrue(
                        BrokerEffort.support(forModel: candidate.model).supportsEffort,
                        "\(profile.name)/\(role): \(candidate.id) carries an effort its model has no parameter for"
                    )
                }
            }
        }
    }

    func test_balanced_isExactlyTheBundledSeed() {
        XCTAssertEqual(BrokerAgentProfile.balanced.rules, BrokerPolicy.bundledDefault.ruleSet)
    }

    func test_conserve_gatesEarlierThanBalancedAndMaxQualityGatesLater() {
        XCTAssertLessThan(
            BrokerAgentProfile.conserveQuota.rules.thresholds.sessionPct,
            BrokerAgentProfile.balanced.rules.thresholds.sessionPct
        )
        XCTAssertGreaterThan(
            BrokerAgentProfile.maxQuality.rules.thresholds.sessionPct,
            BrokerAgentProfile.balanced.rules.thresholds.sessionPct
        )
    }

    func test_maxQuality_refusesDegradedFallbackForJudgmentRoles() {
        let rules = BrokerAgentProfile.maxQuality.rules
        for role in BrokerAgentProfile.judgmentRoles {
            XCTAssertEqual(rules.allowForcedDegraded[role], false, "\(role) must not silently downgrade")
        }
        XCTAssertNil(rules.allowForcedDegraded["execution"], "execution keeps the default, which allows it")
    }

    // MARK: - Decode safety

    func test_decode_settingsWithNoProfileKeys_associatesOnlyWhenTheRulesMatchAShippedProfile() throws {
        // A save written before profiles existed, carrying the untouched seed.
        var json = try encodedSettingsDictionary(BrokerSettings(
            isEnabled: true, port: 43117, policy: .bundledDefault
        ))
        json.removeValue(forKey: "profiles")
        json.removeValue(forKey: "active_profile_id")
        let matching = try decodeSettings(json)
        XCTAssertEqual(matching.activeProfileID, BrokerAgentProfile.balancedID)
        XCTAssertFalse(matching.hasUnsavedProfileEdits)

        // The same save, but the user had hand-edited a threshold. Claiming
        // that is "Balanced" would put an Edited badge on rules that were
        // never loaded from a profile, and Revert would overwrite them.
        var edited = BrokerPolicy.bundledDefault
        edited.thresholds.sessionPct = 61
        var editedJSON = try encodedSettingsDictionary(BrokerSettings(
            isEnabled: true, port: 43117, policy: edited
        ))
        editedJSON.removeValue(forKey: "profiles")
        editedJSON.removeValue(forKey: "active_profile_id")
        let custom = try decodeSettings(editedJSON)
        XCTAssertNil(custom.activeProfileID)
        XCTAssertFalse(custom.hasUnsavedProfileEdits)
    }

    func test_decode_settingsRoundTripsProfilesAndActiveSelection() throws {
        var settings = makeSettings()
        settings.createProfile(named: "Crunch Week")

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BrokerSettings.self, from: data)

        XCTAssertEqual(decoded.profiles.map(\.name), ["Crunch Week"])
        XCTAssertEqual(decoded.activeProfileID, settings.activeProfileID)
        XCTAssertFalse(decoded.hasUnsavedProfileEdits)
    }

    func test_decode_ruleSetWithMissingKeys_fallsBackPerKey() throws {
        let partial = Data(#"{"default_instance":"codex"}"#.utf8)
        let rules = try JSONDecoder().decode(BrokerRuleSet.self, from: partial)

        XCTAssertEqual(rules.defaultInstance, "codex")
        XCTAssertEqual(rules.roles, BrokerRuleSet.default.roles)
        XCTAssertEqual(rules.thresholds, BrokerThresholds.default)
    }

    // MARK: - Review regressions
    //
    // Each of these covers a defect found in review of the settings redesign.
    // They are grouped so the failure message says which one came back.

    /// The rules on screen belong to no profile after a delete, or after a
    /// hand-edited pre-profiles save decodes. `hasUnsavedProfileEdits` is
    /// `false` there (nothing to be edited relative to), so gating the
    /// "you will lose these" confirmation on it let one menu click destroy
    /// rules that existed nowhere else and had no revert path.
    func test_hasUnsavedRuleChanges_isTrueWhenNoProfileIsActive() {
        var settings = makeSettings()
        settings.policy.thresholds.sessionPct = 61
        let id = settings.createProfile(named: "Mine")
        settings.deleteProfile(id: id)

        XCTAssertNil(settings.activeProfile)
        XCTAssertFalse(settings.hasUnsavedProfileEdits, "no profile, so no Edited badge")
        XCTAssertTrue(
            settings.hasUnsavedRuleChanges,
            "the rules are stored nowhere: replacing them must be confirmed"
        )
    }

    func test_hasUnsavedRuleChanges_tracksTheActiveProfileOnceThereIsOne() {
        var settings = makeSettings()
        settings.applyProfile(id: BrokerAgentProfile.balancedID)
        XCTAssertFalse(settings.hasUnsavedRuleChanges)

        settings.policy.thresholds.sessionPct = 61
        XCTAssertTrue(settings.hasUnsavedRuleChanges)
    }

    /// A severed association has to survive a relaunch. Encoding the key only
    /// when non-nil made "Custom" indistinguishable from a pre-profiles save,
    /// so the migration re-attached the profile the user had just left.
    func test_encode_customState_roundTripsInsteadOfReMigrating() throws {
        var settings = BrokerSettings.default
        let id = settings.createProfile(named: "Mine")
        settings.deleteProfile(id: id)
        XCTAssertNil(settings.activeProfileID)
        // The rules still equal Balanced's, which is exactly what would make
        // the migration re-associate them.
        XCTAssertEqual(settings.policy.ruleSet, BrokerAgentProfile.balanced.rules)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BrokerSettings.self, from: data)

        XCTAssertNil(decoded.activeProfileID, "an explicit Custom must not be re-migrated")
    }

    /// D-03 applies to every candidate the editor CREATES, and a duplicate is
    /// a created candidate. Copying a row verbatim minted a second candidate
    /// carrying an effort on a model with no effort parameter.
    @MainActor
    func test_duplicateCandidate_clampsTheCopyWithoutTouchingItsSource() {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "not used"))),
            notificationService: NotificationServiceSpy(),
            brokerService: nil
        )
        // A stale pair that arrived from disk, as an older build or a
        // hand-edited file can leave it.
        appModel.settings.broker.policy.roles["execution"] = [
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001", effort: .high)
        ]
        let view = BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "execution")

        view.duplicateCandidate(role: "execution", index: 0)

        let chain = appModel.settings.broker.policy.roles["execution"]
        XCTAssertEqual(chain?.count, 2)
        XCTAssertEqual(chain?[0].effort, .high, "the untouched source row must not be rewritten")
        XCTAssertNil(chain?[1].effort, "the created copy must be clamped")
    }

    /// The import panel must recognise the file before decoding it. Per-key
    /// fallback is right for a settings file on disk; here it turned any JSON
    /// object into a profile carrying the bundled default rules, so the wrong
    /// file imported "successfully" and later replaced the user's routing.
    func test_decodeExported_rejectsJSONThatIsNotAProfile() {
        let notProfiles = [
            "{}",
            #"{"name":"Trojan"}"#,
            #"{"rules":{}}"#,
            // An eslint config: has a "rules" object, but none of its keys.
            #"{"rules":{"no-console":"error"},"extends":"eslint:recommended"}"#,
            "[]",
            "not json at all",
        ]
        for json in notProfiles {
            XCTAssertThrowsError(
                try BrokerAgentProfile.decodeExported(from: Data(json.utf8)),
                "should have refused: \(json)"
            ) { error in
                XCTAssertEqual(error as? BrokerProfileImportError, .notAProfile)
            }
        }
    }

    func test_decodeExported_acceptsAFileThisAppExported() throws {
        var settings = makeSettings()
        settings.policy.thresholds.sessionPct = 61
        let exported = settings.exportableProfile(named: "Round Trip")
        let data = try JSONEncoder().encode(exported)

        let decoded = try BrokerAgentProfile.decodeExported(from: data)

        XCTAssertEqual(decoded.name, "Round Trip")
        XCTAssertEqual(decoded.rules.thresholds.sessionPct, 61)
    }

    /// A rename collided with the profile's own current name, so changing
    /// only the casing produced a " 2" suffix.
    func test_renameProfile_caseOnlyChangeKeepsTheName() {
        var settings = makeSettings()
        let id = settings.createProfile(named: "conserve week")

        settings.renameProfile(id: id, to: "Conserve Week")

        XCTAssertEqual(settings.profiles.first { $0.id == id }?.name, "Conserve Week")
    }

    /// `addCandidate` seeds whichever known model id sorts first. The comment
    /// justifying its clamp claimed that is a Haiku id; it is Fable. Pinning
    /// it here means the seed changing is a test failure, not a stale comment.
    func test_knownModelIDs_firstSortedIdInTheShippedPolicy() {
        XCTAssertEqual(
            BrokerPolicyEditorView.knownModelIDs(in: .bundledDefault).first,
            "claude-fable-5"
        )
    }

    // MARK: - Pinned rules (profile drift)
    //
    // A profile's stored rules can move under the user: an app update
    // improving a built-in, or the same profile saved elsewhere. The pin
    // taken at apply time is what keeps that from being blamed on them.
    //
    // Built-in rules are `static let` and cannot be mutated in a test, so
    // drift is simulated on a user profile — the same code path, since
    // neither `hasUnsavedProfileEdits` nor `revertToActiveProfile` branches
    // on `isBuiltIn`.

    /// Mutates the active profile's stored rules behind the user's back,
    /// standing in for "an app update shipped better rules for this profile".
    private func simulateProfileUpdate(_ settings: inout BrokerSettings, sessionPct: Double) {
        guard let index = settings.profiles.firstIndex(where: { $0.id == settings.activeProfileID })
        else { return XCTFail("no active user profile to update") }
        settings.profiles[index].rules.thresholds.sessionPct = sessionPct
    }

    func test_profileUpdatedUnderUser_doesNotReadAsTheirEdit() {
        var settings = makeSettings()
        settings.createProfile(named: "Mine")
        XCTAssertFalse(settings.hasUnsavedProfileEdits)

        simulateProfileUpdate(&settings, sessionPct: 44)

        XCTAssertFalse(
            settings.hasUnsavedProfileEdits,
            "the user changed nothing; an Edited badge here blames them for an app update"
        )
        XCTAssertTrue(settings.activeProfileHasUpdatedRules)
        XCTAssertFalse(
            settings.hasUnsavedRuleChanges,
            "the loaded rules are still stored in the profile, so switching away loses nothing"
        )
    }

    func test_revert_afterAProfileUpdate_restoresWhatWasLoadedNotTheNewRules() {
        var settings = makeSettings()
        let loadedSessionPct = settings.policy.thresholds.sessionPct
        settings.createProfile(named: "Mine")
        simulateProfileUpdate(&settings, sessionPct: 44)

        // The user then makes an edit of their own, and reverts it.
        settings.policy.thresholds.weeklyPct = 51
        XCTAssertTrue(settings.hasUnsavedProfileEdits)
        settings.revertToActiveProfile()

        XCTAssertEqual(settings.policy.thresholds.weeklyPct, BrokerThresholds.default.weeklyPct)
        XCTAssertEqual(
            settings.policy.thresholds.sessionPct, loadedSessionPct,
            "Revert discards the user's edits; it must not also swap in rules they never loaded"
        )
        XCTAssertTrue(settings.activeProfileHasUpdatedRules, "the update is still waiting to be taken")
    }

    func test_reapplyingTheProfile_adoptsTheUpdateAndClearsTheFlag() {
        var settings = makeSettings()
        let id = settings.createProfile(named: "Mine")
        simulateProfileUpdate(&settings, sessionPct: 44)

        settings.applyProfile(id: id)

        XCTAssertEqual(settings.policy.thresholds.sessionPct, 44)
        XCTAssertFalse(settings.activeProfileHasUpdatedRules)
        XCTAssertFalse(settings.hasUnsavedProfileEdits)
    }

    func test_saveActiveProfile_rePinsSoTheSavedRulesStopReadingAsEdited() {
        var settings = makeSettings()
        settings.createProfile(named: "Mine")
        settings.policy.thresholds.sessionPct = 61
        XCTAssertTrue(settings.hasUnsavedProfileEdits)

        settings.saveActiveProfile()

        XCTAssertFalse(settings.hasUnsavedProfileEdits)
        XCTAssertFalse(settings.activeProfileHasUpdatedRules)
        XCTAssertEqual(settings.activeProfileRules?.thresholds.sessionPct, 61)
    }

    /// A save written before pinning existed must acquire a pin AT DECODE, not
    /// merely fall back to the profile's current rules.
    ///
    /// Falling back is not a one-decode bridge: `encodeIfPresent` re-omits the
    /// key on every save, so a user who never touches the profile bar would
    /// stay unpinned forever, and the first app update to change a built-in
    /// would hand them a false "Edited" badge and a Revert that re-routes them
    /// — the pin's whole purpose, defeated for exactly the migrated users who
    /// never asked for any of it.
    func test_pinnedRules_settingsSavedBeforePinningAcquireAPinAtDecode() throws {
        var json = try encodedSettingsDictionary(BrokerSettings.default)
        json.removeValue(forKey: "active_profile_rules")
        let decoded = try decodeSettings(json)

        XCTAssertEqual(decoded.activeProfileID, BrokerAgentProfile.balancedID)
        XCTAssertEqual(
            decoded.activeProfileRules, BrokerAgentProfile.balanced.rules,
            "the pin must be attached, not left to the fallback"
        )
        XCTAssertFalse(decoded.hasUnsavedProfileEdits)
        XCTAssertFalse(decoded.activeProfileHasUpdatedRules)

        // And it must survive the next save, which is the half that was broken.
        let resaved = try JSONDecoder().decode(
            BrokerSettings.self, from: JSONEncoder().encode(decoded)
        )
        XCTAssertEqual(resaved.activeProfileRules, BrokerAgentProfile.balanced.rules)
    }

    /// The same migrated user, after an app update changes their built-in's
    /// rules: they must see "Updated", not "Edited", and Revert must not move
    /// their routing.
    func test_pinnedRules_migratedUser_survivesAShippedProfileChange() throws {
        var json = try encodedSettingsDictionary(BrokerSettings.default)
        json.removeValue(forKey: "active_profile_rules")
        var decoded = try decodeSettings(json)

        // Stand in for "the next app version ships different Balanced rules"
        // by pointing the association at a user profile and moving it.
        var shipped = BrokerAgentProfile(name: "Shipped", rules: .default)
        decoded.profiles = [shipped]
        decoded.activeProfileID = shipped.id
        decoded.activeProfileRules = shipped.rules
        shipped.rules.thresholds.sessionPct = 44
        decoded.profiles = [shipped]

        XCTAssertFalse(decoded.hasUnsavedProfileEdits, "the user changed nothing")
        XCTAssertTrue(decoded.activeProfileHasUpdatedRules)
        decoded.revertToActiveProfile()
        XCTAssertNotEqual(
            decoded.policy.thresholds.sessionPct, 44,
            "Revert must restore what was loaded, not adopt the new rules"
        )
    }

    /// `activeProfileID` naming a profile that no longer exists: the bar reads
    /// "Custom", so a leftover pin must not answer for it and suppress the
    /// confirmation that protects rules stored nowhere else.
    func test_pinnedRules_staleIdWithNoMatchingProfile_readsAsCustom() {
        var settings = makeSettings()
        settings.activeProfileID = UUID()
        settings.activeProfileRules = settings.policy.ruleSet

        XCTAssertNil(settings.activeProfile)
        XCTAssertNil(settings.pinnedProfileRules)
        XCTAssertFalse(settings.hasUnsavedProfileEdits)
        XCTAssertTrue(
            settings.hasUnsavedRuleChanges,
            "no reachable profile means switching away must still be confirmed"
        )
        XCTAssertFalse(settings.activeProfileHasUpdatedRules)
    }

    /// The memberwise init defaults `activeProfileID` to Balanced, so it must
    /// pin Balanced too. Claiming a profile is active with no baseline reads as
    /// an edit the caller never made.
    func test_init_derivesThePinFromWhicheverProfileItClaimsIsActive() {
        let fromParts = BrokerSettings(isEnabled: true, port: 43117, policy: .bundledDefault)
        XCTAssertEqual(fromParts.activeProfileRules, BrokerAgentProfile.balanced.rules)
        XCTAssertFalse(fromParts.hasUnsavedProfileEdits)

        let custom = BrokerAgentProfile(name: "Mine", rules: BrokerAgentProfile.conserveQuota.rules)
        let named = BrokerSettings(
            isEnabled: true,
            port: 43117,
            policy: .bundledDefault,
            profiles: [custom],
            activeProfileID: custom.id
        )
        XCTAssertEqual(named.activeProfileRules, custom.rules)

        let unassociated = BrokerSettings(
            isEnabled: true, port: 43117, policy: .bundledDefault, activeProfileID: nil
        )
        XCTAssertNil(unassociated.activeProfileRules)
        XCTAssertTrue(unassociated.hasUnsavedRuleChanges)
    }

    func test_pinnedRules_roundTripAndDeleteClearsThePin() throws {
        var settings = makeSettings()
        settings.policy.thresholds.sessionPct = 61
        let id = settings.createProfile(named: "Mine")

        let decoded = try JSONDecoder().decode(
            BrokerSettings.self, from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.activeProfileRules?.thresholds.sessionPct, 61)

        settings.deleteProfile(id: id)
        XCTAssertNil(settings.activeProfileRules)
        XCTAssertNil(settings.pinnedProfileRules)
        XCTAssertTrue(settings.hasUnsavedRuleChanges)
    }

    // MARK: - Helpers

    private func encodedSettingsDictionary(_ settings: BrokerSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodeSettings(_ dictionary: [String: Any]) throws -> BrokerSettings {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try JSONDecoder().decode(BrokerSettings.self, from: data)
    }
}
