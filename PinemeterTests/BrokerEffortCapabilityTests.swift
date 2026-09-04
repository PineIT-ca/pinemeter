//
//  BrokerEffortCapabilityTests.swift
//  PinemeterTests
//
//  D-02/D-03: per-model effort capability, the clamp that keeps an
//  effort-unsupported model from ever carrying a stored effort, and the
//  single shared mutation path in BrokerPolicyEditorView that enforces it.
//

import XCTest
@testable import Pinemeter

final class BrokerEffortCapabilityTests: XCTestCase {
    // MARK: - BrokerEffort.support(forModel:)

    func test_support_haikuBareAndDatedIds_reportsNoEffortSupport() {
        XCTAssertFalse(BrokerEffort.support(forModel: "claude-haiku-4-5").supportsEffort)
        XCTAssertFalse(BrokerEffort.support(forModel: "claude-haiku-4-5-20251001").supportsEffort)
    }

    func test_support_haikuSpellings_areAllUnsupported() {
        // The bare alias is what `agentModelAliases` hands Claude Code, and is
        // a model string a user can type into the Custom Model alert.
        XCTAssertEqual(BrokerEffort.support(forModel: "haiku"), .unsupported)
        // Matching is case-insensitive.
        XCTAssertEqual(BrokerEffort.support(forModel: "Claude-Haiku-4-5"), .unsupported)
        XCTAssertEqual(BrokerEffort.support(forModel: "CLAUDE-HAIKU-4-5-20251001"), .unsupported)
        // A provider-namespaced id still resolves to the family.
        XCTAssertEqual(
            BrokerEffort.support(forModel: "us.anthropic.claude-haiku-4-5-20251001-v1:0"),
            .unsupported
        )
    }

    func test_support_haiku_pinsTheUnsupportedLabelAndOffersNoLevels() {
        let support = BrokerEffort.support(forModel: "claude-haiku-4-5-20251001")
        XCTAssertEqual(support.nilLabel, "Unsupported")
        XCTAssertEqual(support, .unsupported)
        // The editor's effort control is disabled off `supportsEffort` and
        // fills its level rows from `selectableLevels`, so an unsupported
        // model offers nothing to pick — asserted here, not only in a snapshot.
        XCTAssertFalse(support.supportsEffort)
        XCTAssertEqual(support.selectableLevels, [])
    }

    func test_support_supportedModel_offersEveryLevel() {
        let support = BrokerEffort.support(forModel: "claude-opus-5")
        XCTAssertTrue(support.supportsEffort)
        XCTAssertEqual(support.selectableLevels, BrokerEffort.allCases)
    }

    func test_support_supportedModel_isEquatableOnItsLabel() {
        XCTAssertEqual(BrokerEffort.support(forModel: "claude-fable-5-1"), .supported(nilLabel: "Adaptive (high)"))
        XCTAssertNotEqual(BrokerEffort.support(forModel: "claude-fable-5"), .unsupported)
    }

    func test_support_opusAndUnrecognisedModel_reportsEffortSupport() {
        XCTAssertTrue(BrokerEffort.support(forModel: "claude-opus-5").supportsEffort)
        // Fail soft: an unrecognised id must never be treated as unsupported.
        XCTAssertTrue(BrokerEffort.support(forModel: "vendor/mystery-model").supportsEffort)
    }

    func test_nilLabel_fable_readsAdaptiveHigh() {
        XCTAssertEqual(BrokerEffort.support(forModel: "claude-fable-5-1").nilLabel, "Adaptive (high)")
    }

    func test_nilLabel_opusAndSonnet_readDefaultHigh() {
        XCTAssertEqual(BrokerEffort.support(forModel: "claude-opus-5").nilLabel, "Default (high)")
        XCTAssertEqual(BrokerEffort.support(forModel: "claude-sonnet-5").nilLabel, "Default (high)")
    }

    func test_nilLabel_gptSol_readsDefaultMedium() {
        XCTAssertEqual(BrokerEffort.support(forModel: "gpt-5.6-sol").nilLabel, "Default (medium)")
    }

    func test_nilLabel_gptTerraAndLuna_readDefaultMedium() {
        XCTAssertEqual(BrokerEffort.support(forModel: "gpt-5.6-terra").nilLabel, "Default (medium)")
        XCTAssertEqual(BrokerEffort.support(forModel: "gpt-5.6-luna").nilLabel, "Default (medium)")
    }

    func test_nilLabel_unrecognisedModel_readsProviderDefault() {
        XCTAssertEqual(BrokerEffort.support(forModel: "vendor/mystery-model").nilLabel, "Provider default")
    }

    // MARK: - effortAccessibilityValue(for:)

    func test_effortAccessibilityValue_noEffort_returnsModelNilLabel() {
        let candidate = BrokerCandidate(route: .native, model: "claude-opus-5")
        XCTAssertEqual(BrokerPolicyEditorView.effortAccessibilityValue(for: candidate), "Default (high)")
    }

    func test_effortAccessibilityValue_withEffort_returnsLevelDisplayLabel() {
        let candidate = BrokerCandidate(route: .native, model: "claude-opus-5", effort: .xhigh)
        XCTAssertEqual(BrokerPolicyEditorView.effortAccessibilityValue(for: candidate), "XHigh")
    }

    func test_effortAccessibilityValue_staleEffortOnAnUnsupportedModel_readsUnsupported() {
        // A policy this editor never wrote (hand-edited, imported, or written
        // by a build from before the clamp) can carry this pair. The control
        // shows "Unsupported" and the engine drops the value at dispatch, so
        // VoiceOver must not announce "High" for it.
        let candidate = BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001", effort: .high)
        XCTAssertEqual(BrokerPolicyEditorView.effortAccessibilityValue(for: candidate), "Unsupported")

        let bareAlias = BrokerCandidate(route: .native, model: "haiku", effort: .xhigh)
        XCTAssertEqual(BrokerPolicyEditorView.effortAccessibilityValue(for: bareAlias), "Unsupported")
    }

    // MARK: - Seed invariant (D-04)

    func test_bundledDefault_noCandidateCarriesEffortOnAnEffortFreeModel() {
        for (_, chain) in BrokerPolicy.bundledDefault.roles {
            for candidate in chain {
                if candidate.effort != nil {
                    XCTAssertTrue(
                        BrokerEffort.support(forModel: candidate.model).supportsEffort,
                        "\(candidate.id) carries an effort on a model that does not support one"
                    )
                }
            }
        }
    }

    // MARK: - BrokerCandidate.clampingEffortToModelSupport()

    func test_clampingEffortToModelSupport_haikuCandidate_dropsEffort() {
        let candidate = BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001", effort: .high)
        XCTAssertNil(candidate.clampingEffortToModelSupport().effort)
    }

    func test_clampingEffortToModelSupport_opusCandidate_keepsEffort() {
        let candidate = BrokerCandidate(route: .native, model: "claude-opus-5", effort: .xhigh)
        XCTAssertEqual(candidate.clampingEffortToModelSupport().effort, .xhigh)
    }

    func test_clampingEffortToModelSupport_unrecognisedModel_keepsEffort() {
        let candidate = BrokerCandidate(route: .native, model: "vendor/mystery-model", effort: .low)
        XCTAssertEqual(candidate.clampingEffortToModelSupport().effort, .low)
    }

    // MARK: - BrokerPolicyEditorView.updateCandidate shared path

    @MainActor
    private func makeEditorTestAppModel() -> AppModel {
        AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "not used"))),
            notificationService: NotificationServiceSpy(),
            brokerService: nil
        )
    }

    @MainActor
    func test_updateCandidate_modelOnlyEditOntoHaiku_clearsStoredEffortAndRouteDetails() {
        let appModel = makeEditorTestAppModel()
        appModel.settings.broker.policy.roles["planning"] = [
            BrokerCandidate(route: .t3, instance: "claude_secondary", model: "claude-opus-5", effort: .high)
        ]
        let view = BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "planning")

        view.updateCandidate(role: "planning", index: 0) { current in
            BrokerCandidate(
                route: current.route,
                instance: current.instance,
                model: "claude-haiku-4-5-20251001",
                effort: current.effort
            )
        }

        let updated = appModel.settings.broker.policy.roles["planning"]?[0]
        XCTAssertEqual(updated?.model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(updated?.route, .auto)
        XCTAssertNil(updated?.instance)
        XCTAssertNil(updated?.effort)
    }

    @MainActor
    func test_updateCandidate_normalizesLegacyRouteAndLeavesHaikuEffortNil() {
        let appModel = makeEditorTestAppModel()
        appModel.settings.broker.policy.roles["execution"] = [
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001")
        ]
        let view = BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "execution")

        view.updateCandidate(role: "execution", index: 0) { current in
            BrokerCandidate(route: .t3, instance: current.instance, model: current.model, effort: current.effort)
        }

        let updated = appModel.settings.broker.policy.roles["execution"]?[0]
        XCTAssertEqual(updated?.route, .auto)
        XCTAssertNil(updated?.effort)
    }

    @MainActor
    func test_updateCandidate_effortOnlyEditOnOpusRow_storesChosenLevelUnchanged() {
        let appModel = makeEditorTestAppModel()
        appModel.settings.broker.policy.roles["heavy"] = [
            BrokerCandidate(route: .native, model: "claude-opus-5")
        ]
        let view = BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "heavy")

        view.updateCandidate(role: "heavy", index: 0) { current in
            BrokerCandidate(route: current.route, instance: current.instance, model: current.model, effort: .xhigh)
        }

        XCTAssertEqual(appModel.settings.broker.policy.roles["heavy"]?[0].effort, .xhigh)
    }

    // MARK: - The row's visible bindings route through the shared path
    //
    // These drive the exact `Binding`s the row's controls are constructed
    // from, so an inline write reintroduced in `candidateRow` (bypassing
    // `updateCandidate`, and therefore the clamp) fails here rather than
    // passing silently because the seam itself still works.

    @MainActor
    private func makeOpusEditorWithStoredEffort(role: String) -> (AppModel, BrokerPolicyEditorView) {
        let appModel = makeEditorTestAppModel()
        appModel.settings.broker.policy.roles[role] = [
            BrokerCandidate(route: .t3, instance: "claude_secondary", model: "claude-opus-5", effort: .high)
        ]
        return (appModel, BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: role))
    }

    @MainActor
    func test_modelBinding_setToHaiku_clearsStoredEffort() {
        let (appModel, view) = makeOpusEditorWithStoredEffort(role: "planning")

        view.candidateModelBinding(role: "planning", index: 0).wrappedValue = "claude-haiku-4-5-20251001"

        let updated = appModel.settings.broker.policy.roles["planning"]?[0]
        XCTAssertEqual(updated?.model, "claude-haiku-4-5-20251001")
        XCTAssertNil(updated?.effort)
    }

    @MainActor
    func test_effortBinding_onASupportedRow_storesTheChosenLevel() {
        let (appModel, view) = makeOpusEditorWithStoredEffort(role: "heavy")

        view.candidateEffortBinding(role: "heavy", index: 0).wrappedValue = .low

        XCTAssertEqual(appModel.settings.broker.policy.roles["heavy"]?[0].effort, .low)
    }

    @MainActor
    func test_effortBinding_onAnUnsupportedRow_cannotStoreALevel() {
        // The control is disabled for an unsupported model, but the binding
        // itself must also refuse the write: the clamp, not the disabled
        // state, is the guarantee.
        let appModel = makeEditorTestAppModel()
        appModel.settings.broker.policy.roles["execution"] = [
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001")
        ]
        let view = BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "execution")

        view.candidateEffortBinding(role: "execution", index: 0).wrappedValue = .high

        XCTAssertNil(appModel.settings.broker.policy.roles["execution"]?[0].effort)
    }

    // MARK: - Chain writes clamp what they produce, and only that

    @MainActor
    func test_addCandidate_clampsTheAppendedCandidateAndLeavesOthersAlone() {
        let appModel = makeEditorTestAppModel()
        // A stale pair that arrived from disk: add must not rewrite it
        // (T-pzh-01 — the dispatch boundary drops it, the editor does not
        // silently edit rows the user never touched).
        appModel.settings.broker.policy.roles["planning"] = [
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001", effort: .high)
        ]
        let view = BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "planning")

        view.addCandidate(role: "planning")

        let chain = appModel.settings.broker.policy.roles["planning"]
        XCTAssertEqual(chain?.count, 2)
        XCTAssertEqual(chain?[0].effort, .high, "an untouched row must not be rewritten")
        // The seeded model is whichever known id sorts first — a Haiku id in
        // the shipped policy — so the appended candidate must carry no effort.
        XCTAssertNil(chain?[1].effort)
    }

    @MainActor
    func test_removeCandidate_removesTheRowAndLeavesOthersUntouched() {
        let appModel = makeEditorTestAppModel()
        appModel.settings.broker.policy.roles["planning"] = [
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .xhigh),
            BrokerCandidate(route: .native, model: "claude-haiku-4-5-20251001", effort: .high),
        ]
        let view = BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "planning")

        view.removeCandidate(role: "planning", index: 0)

        let chain = appModel.settings.broker.policy.roles["planning"]
        XCTAssertEqual(chain?.count, 1)
        XCTAssertEqual(chain?[0].model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(chain?[0].effort, .high, "an untouched row must not be rewritten")
    }

    @MainActor
    func test_writeChain_isNonDestructive_aReorderDoesNotRewriteUntouchedRows() {
        // `.onMove` reorders through `roleChainBinding` -> `writeChain`. A
        // reorder edits no candidate, so it must not rewrite one — even a
        // stale (haiku, effort) pair survives until a real edit or dispatch.
        let appModel = makeEditorTestAppModel()
        let view = BrokerPolicyEditorView(appModel: appModel, initialSelectedRole: "planning")

        view.writeChain(role: "planning", [
            BrokerCandidate(route: .native, model: "haiku", effort: .high),
            BrokerCandidate(route: .native, model: "claude-opus-5", effort: .xhigh),
        ])

        XCTAssertEqual(
            appModel.settings.broker.policy.roles["planning"]?.map(\.effort),
            [.high, .xhigh]
        )
    }
}
