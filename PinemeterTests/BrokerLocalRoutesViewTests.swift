import XCTest
@testable import Pinemeter

final class BrokerLocalRoutesViewTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static func route() -> BrokerLocalRoute {
        .init(candidate: "t3:pi/lab/qwen-27b", host: "gpu-a", probeURL: "http://gpu-a.example:11434",
              preset: "qwen-27b", residency: .controlled, enabled: true, roles: ["explore", "verification"])
    }
    static func fixtureLoad(status: String = "loaded", busy: Int = 0, pending: Int = 0) -> BrokerLocalLoad {
        .init(hosts: [.init(host: "gpu-a", state: "ok", observedAt: now,
            presets: ["qwen-27b": .init(status: status, aliases: [], slotsTotal: 1, slotsBusy: busy)], pending: pending)])
    }
    func test_idleRowUsesEngineLevel() {
        let route = Self.route(), load = Self.fixtureLoad()
        let row = BrokerLocalRouteRow(route: route, load: load, now: Self.now, brokerEnabled: true)
        XCTAssertEqual(row.state, .idle)
        XCTAssertEqual(row.priceLevel, 0)
        XCTAssertEqual(row.priceLevel, BrokerLocalRouting.level(route: route, load: load, now: Self.now))
        XCTAssertTrue(row.isControlled)
        XCTAssertEqual(row.roles, ["explore", "verification"])
    }
    func test_rowIdentitySurvivesEditsAndNeverEntersJSON() throws {
        var route = Self.route(); let key = route.rowKey
        route.candidate = "t3:pi/lab/other"
        XCTAssertEqual(route.rowKey, key)
        let data = try JSONEncoder().encode(route)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("rowKey"))
        XCTAssertEqual(try JSONDecoder().decode(BrokerLocalRoute.self, from: data), route)
    }

    private func assertState(_ expected: BrokerLocalRouteRow.State, route: BrokerLocalRoute = BrokerLocalRoutesViewTests.route(),
                             load: BrokerLocalLoad? = BrokerLocalRoutesViewTests.fixtureLoad(), enabled: Bool = true,
                             now: Date = BrokerLocalRoutesViewTests.now, file: StaticString = #filePath, line: UInt = #line) {
        let row = BrokerLocalRouteRow(route: route, load: load, now: now, brokerEnabled: enabled)
        XCTAssertEqual(row.state, expected, file: file, line: line)
        if let level = row.priceLevel {
            XCTAssertEqual(level, BrokerLocalRouting.level(route: route, load: load, now: now), file: file, line: line)
        } else {
            XCTAssertFalse([.loading, .replacesIdle, .notLoaded, .idle, .busy].contains(expected), file: file, line: line)
        }
    }
    func test_stateOffWinsBeforeBrokerOff() {
        var route = Self.route(); route.enabled = false
        assertState(.off, route: route, enabled: false)
    }
    func test_stateBrokerOff() { assertState(.brokerOff, enabled: false) }
    func test_stateUnknownWithoutSnapshot() { assertState(.unknown, load: nil) }
    func test_stateUnknownAfter61Seconds() { assertState(.unknown, now: Self.now.addingTimeInterval(61)) }
    func test_stateUnknownForFutureReading() { assertState(.unknown, now: Self.now.addingTimeInterval(-1)) }
    func test_stateUnknownForHostError() {
        var load = Self.fixtureLoad(); load.hosts[0].state = "error"; assertState(.unknown, load: load)
    }
    func test_stateUnreachable() {
        var load = Self.fixtureLoad(); load.hosts[0].state = "unreachable"; assertState(.unreachable, load: load)
    }
    func test_stateStaleWinsBeforeUnreachable() {
        var load = Self.fixtureLoad(); load.hosts[0].state = "unreachable"
        assertState(.unknown, load: load, now: Self.now.addingTimeInterval(61))
    }
    func test_stateBusyWithAnotherModel() {
        var load = Self.fixtureLoad()
        load.hosts[0].presets["other"] = .init(status: "loaded", aliases: [], slotsTotal: 1, slotsBusy: 1)
        assertState(.busyOther, load: load)
    }
    func test_stateOtherLoadingWinsBeforeTargetFailed() {
        var load = Self.fixtureLoad(status: "failed")
        load.hosts[0].presets["other"] = .init(status: "loading", aliases: [], slotsTotal: 0, slotsBusy: 0)
        assertState(.busyOther, load: load)
    }
    func test_stateFailed() { assertState(.failed, load: Self.fixtureLoad(status: "failed")) }
    func test_stateMissingPresetFails() {
        var load = Self.fixtureLoad(); load.hosts[0].presets = [:]; assertState(.failed, load: load)
    }
    func test_stateLoading() { assertState(.loading, load: Self.fixtureLoad(status: "loading")) }
    func test_stateReplacesIdleModel() {
        var load = Self.fixtureLoad(status: "sleeping")
        load.hosts[0].presets["other"] = .init(status: "loaded", aliases: [], slotsTotal: 1, slotsBusy: 0)
        assertState(.replacesIdle, load: load)
    }
    func test_stateNotLoaded() { assertState(.notLoaded, load: Self.fixtureLoad(status: "unloaded")) }
    func test_stateSleepingIsNotLoaded() { assertState(.notLoaded, load: Self.fixtureLoad(status: "sleeping")) }
    func test_stateIdleAt60Seconds() { assertState(.idle, now: Self.now.addingTimeInterval(60)) }
    func test_stateBusyUsesEngineLevel3() { assertState(.busy, load: Self.fixtureLoad(busy: 1)) }
    func test_stateBusyUsesPendingPressure() { assertState(.busy, load: Self.fixtureLoad(pending: 3)) }
    func test_stateAliasUsesEngineTarget() {
        var load = Self.fixtureLoad(); let preset = load.hosts[0].presets.removeValue(forKey: "qwen-27b")!
        load.hosts[0].presets["loaded-id"] = .init(status: preset.status, aliases: ["qwen-27b"], slotsTotal: 1, slotsBusy: 0)
        assertState(.idle, load: load)
    }

    private func assertValidation(_ field: BrokerLocalRoutesSection.Field, _ value: String, _ message: String,
                                  existing: [BrokerLocalRoute] = [], file: StaticString = #filePath, line: UInt = #line) {
        var route = Self.route(); let original = route
        XCTAssertEqual(BrokerLocalRoutesSection.setField(field, value: value, route: &route, existing: existing), message, file: file, line: line)
        XCTAssertEqual(route, original, file: file, line: line)
        var invalid = route; invalid[keyPath: field.path] = value
        XCTAssertEqual(BrokerLocalRoutesSection.validation(invalid, existing: existing)?.message, message, file: file, line: line)
    }
    func test_validationCandidateFormat() {
        for value in ["", "native/qwen-27b", "t3:*/lab/qwen-27b", "t3:pi/lab/*"] {
            assertValidation(.candidate, value, "Use t3:instance/model, for example t3:pi/lab/qwen-27b.")
        }
    }
    func test_validationDefaultModel() { assertValidation(.candidate, "t3:pi/default", "Use an explicit model. default can point to any provider, including a cloud one.") }
    func test_validationDuplicate() { assertValidation(.candidate, Self.route().candidate, "This route is already declared.", existing: [Self.route()]) }
    func test_validationHostCharsetAndBounds() {
        for value in ["", "gpu/a", "gpu:a", String(repeating: "a", count: 65)] {
            assertValidation(.host, value, "Use letters, digits, dots, dashes or underscores.")
        }
    }
    func test_validationFifthHost() {
        let routes = (1...4).map { index in
            BrokerLocalRoute(candidate: "t3:pi/lab/model-\(index)", host: "gpu-\(index)", probeURL: "http://gpu-a.example:11434", preset: "model-\(index)")
        }
        assertValidation(.host, "gpu-b", "Up to 4 hosts.", existing: routes)
    }
    func test_validationProbeAddressShape() {
        for value in ["", "ftp://gpu-a.example:11434", "http://gpu-a.example", "http://gpu-a.example:11434/models", "http://user@gpu-a.example:11434", "http://gpu-a.example:11434?x=1"] {
            assertValidation(.probeURL, value, "Use http:// or https:// with a host and port only.")
        }
    }
    func test_validationHostProbeConflict() {
        var other = Self.route(); other.candidate = "t3:pi/lab/other"
        assertValidation(.probeURL, "http://gpu-b.example:11434", "Use http:// or https:// with a host and port only.", existing: [other])
    }
    func test_validationChangingHostCannotCreateProbeConflict() {
        var route = Self.route(); let original = route
        var other = Self.route(); other.host = "gpu-b"; other.candidate = "t3:pi/lab/other"; other.probeURL = "http://gpu-b.example:11434"
        XCTAssertEqual(BrokerLocalRoutesSection.setField(.host, value: "gpu-b", route: &route, existing: [other]), "Use http:// or https:// with a host and port only.")
        XCTAssertEqual(route, original)
    }
    func test_validationPreset() {
        for value in ["", "lab/model", String(repeating: "x", count: 129)] {
            assertValidation(.preset, value, "Enter the model name the host's server uses.")
        }
    }
    func test_validationFirstFailureOnlyAndEnableGate() {
        var route = Self.route(); route.host = ""; route.preset = ""; route.probeURL = ""
        XCTAssertEqual(BrokerLocalRoutesSection.validation(route, existing: [])?.field, .host)
        XCTAssertNil(BrokerLocalRoutesSection.validation(Self.route(), existing: []))
    }
    func test_validationCanonicalOriginAcceptsTrailingSlash() {
        var other = Self.route(); other.candidate = "t3:pi/lab/other"; other.probeURL += "/"
        XCTAssertNil(BrokerLocalRoutesSection.validation(Self.route(), existing: [other]))
    }
    func test_acceptedFieldEditKeepsRowIdentity() {
        var route = Self.route(); let key = route.rowKey
        XCTAssertNil(BrokerLocalRoutesSection.setField(.preset, value: "qwen:27b", route: &route, existing: []))
        XCTAssertEqual(route.preset, "qwen:27b"); XCTAssertEqual(route.rowKey, key)
    }
    func test_detectedMenuFiltersDefaultBareAndDeclaredModels() {
        let instance = DiscoveredT3Instance(instanceId: "pi", driver: "pi", displayName: "Lab", modelSlugs: ["default", "bare", "lab/qwen-27b", "gpu-b/qwen:27b", "gpu-b/qwen:27b"])
        let items = BrokerLocalRoutesSection.detectedRoutes([instance], existing: [Self.route()])
        XCTAssertEqual(items.map(\.candidate), ["t3:pi/gpu-b/qwen:27b"])
        XCTAssertEqual(items.first?.label, "Lab: gpu-b/qwen:27b")
    }
    func test_addMenuStopsAtEight() {
        XCTAssertTrue(BrokerLocalRoutesSection.canAddRoute(count: 7))
        XCTAssertFalse(BrokerLocalRoutesSection.canAddRoute(count: 8))
        XCTAssertFalse(BrokerLocalRoutesSection.canAddRoute(count: 9))
    }
    func test_newRouteDefaultsAndPrefill() {
        let route = BrokerLocalRoutesSection.newRoute(candidate: "t3:pi/gpu-a/qwen:27b")
        XCTAssertEqual(route.host, "gpu-a"); XCTAssertEqual(route.preset, "qwen:27b")
        XCTAssertFalse(route.enabled); XCTAssertNil(route.residency)
        XCTAssertEqual(route.roles, ["explore", "verification"]); XCTAssertEqual(route.probeURL, "")
    }
    func test_manualRouteStartsIncompleteAndDisabled() {
        let route = BrokerLocalRoutesSection.newRoute(candidate: "")
        XCTAssertEqual(route.candidate, ""); XCTAssertFalse(route.enabled)
        XCTAssertEqual(BrokerLocalRoutesSection.validation(route, existing: [])?.field, .candidate)
    }
    func test_roleSwitchVisibilityIncludesSavedForbiddenRole() {
        var policy = BrokerPolicy.default
        for role in BrokerLocalRoute.allowedRoles { XCTAssertTrue(BrokerPolicyEditorView.showsControlledOnly(role: role, policy: policy)) }
        XCTAssertFalse(BrokerPolicyEditorView.showsControlledOnly(role: "review", policy: policy))
        policy.residencyRoles["review"] = .controlled
        XCTAssertTrue(BrokerPolicyEditorView.showsControlledOnly(role: "review", policy: policy))
    }
    func test_roleSwitchOffDescription() {
        let description = BrokerPolicyEditorView.controlledOnlyDescription(role: "explore", policy: .default)
        XCTAssertEqual(description.text, "Prompts and code stay on hosts you control."); XCTAssertFalse(description.warning)
    }
    func test_roleSwitchForbiddenDescription() {
        var policy = BrokerPolicy.default; policy.residencyRoles["review"] = .controlled
        let description = BrokerPolicyEditorView.controlledOnlyDescription(role: "review", policy: policy)
        XCTAssertEqual(description.text, "Every pick for this role fails: local models are never used for review."); XCTAssertTrue(description.warning)
    }
    func test_roleSwitchNoRouteDescription() {
        var policy = BrokerPolicy.default; policy.residencyRoles["verification"] = .controlled
        policy.localRoutes = [Self.route()]; policy.localRoutes[0].enabled = false
        let description = BrokerPolicyEditorView.controlledOnlyDescription(role: "verification", policy: policy)
        XCTAssertEqual(description.text, "Every pick for this role fails until a controlled route serves it. Add one under Local and controlled routes in Instances."); XCTAssertTrue(description.warning)
    }
    func test_roleSwitchOneRouteDescription() {
        var policy = BrokerPolicy.default; policy.localRoutes = [Self.route()]; policy.residencyRoles["verification"] = .controlled
        let description = BrokerPolicyEditorView.controlledOnlyDescription(role: "verification", policy: policy)
        XCTAssertEqual(description.text, "Prompts and code stay on hosts you control. Picks use only 1 local route and fail instead of using a vendor model."); XCTAssertFalse(description.warning)
    }
    func test_roleSwitchManyRoutesExcludesUncontrolledAndWrongRole() {
        var policy = BrokerPolicy.default; policy.residencyRoles["verification"] = .controlled
        var other = Self.route(); other.candidate = "t3:pi/lab/other"
        var vendor = Self.route(); vendor.residency = nil
        var wrong = Self.route(); wrong.roles = ["execution"]
        policy.localRoutes = [Self.route(), other, vendor, wrong]
        let description = BrokerPolicyEditorView.controlledOnlyDescription(role: "verification", policy: policy)
        XCTAssertEqual(description.text, "Prompts and code stay on hosts you control. Picks use only 2 local routes and fail instead of using a vendor model.")
    }
    func test_roleSwitchWritesAndRemovesMachineLocalEntry() {
        var policy = BrokerPolicy.default; let rules = BrokerRuleSet(policy: policy)
        BrokerPolicyEditorView.setControlledOnly(true, role: "execution", policy: &policy)
        XCTAssertEqual(policy.residencyRoles["execution"], .controlled)
        XCTAssertEqual(BrokerRuleSet(policy: policy), rules)
        BrokerPolicyEditorView.setControlledOnly(false, role: "execution", policy: &policy)
        XCTAssertNil(policy.residencyRoles["execution"])
    }
    func test_rowSummaryContainsNoProbeAddress() {
        let route = Self.route(); let row = BrokerLocalRouteRow(route: route, load: Self.fixtureLoad(), now: Self.now, brokerEnabled: true)
        let label = BrokerLocalRoutesSection.rowAccessibilityLabel(route: route, row: row)
        XCTAssertEqual(label, "t3:pi/lab/qwen-27b on gpu-a, Idle, price level 0")
        XCTAssertFalse(label.contains(route.probeURL))
    }
    func test_helpCopyMatchesContractAndContainsNoImplementationKeys() {
        XCTAssertEqual(BrokerHelpTopic.localRoutes.title, "Local and controlled routes")
        XCTAssertEqual(BrokerHelpTopic.localRoutes.summary, "Models that run on machines you control, and the option to keep sensitive work on them.")
        XCTAssertEqual(BrokerHelpTopic.localRoutes.terms.map(\.name), ["Local route", "Price level", "Controlled infrastructure", "Controlled infrastructure only", "Allowed roles"])
        XCTAssertEqual(BrokerHelpTopic.localRoutes.terms[3].definition, "A role setting for sensitive work. Prompts and code stay on hosts you control. If no controlled route can take the pick, it fails instead of using a vendor model. It covers the model endpoint only; tools the agent runs can still reach the network.")
        let copy = ([BrokerHelpTopic.localRoutes.title, BrokerHelpTopic.localRoutes.summary ?? ""] + BrokerHelpTopic.localRoutes.terms.flatMap { [$0.name, $0.definition] }).joined(separator: " ")
        for key in ["local_routes", "residency_roles", "residency", "autoload", "secure", "http://"] { XCTAssertFalse(copy.contains(key)) }
    }

    func test_allLocalHelpDefinitionsMatchContract() {
        XCTAssertEqual(BrokerHelpTopic.localRoutes.terms.map(\.definition), [
            "A model on a machine you run, reached through a T3 instance. It has no quota; the broker prices it from the host's current load instead. It runs only after every cloud model in the chain unless load makes it the cheaper equal choice.",
            "0 when the model is loaded and free, rising as work queues. Unknown, unreachable or busy-with-another-model hosts are skipped, so a pick never interrupts another model.",
            "A route you mark as running on a host you control. Only you can mark it, and only on this Mac: profiles, routing updates and detected T3 data can never mark a route controlled.",
            "A role setting for sensitive work. Prompts and code stay on hosts you control. If no controlled route can take the pick, it fails instead of using a vendor model. It covers the model endpoint only; tools the agent runs can still reach the network.",
            "explore, verification and, if you tick it, execution. Local models never run review, legal-review, planning, design, research or heavy work."
        ])
    }

    @MainActor
    func test_appModelEditsPersistAndAccessorUsesBrokerOffState() async throws {
        let suite = "local-route-app-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = BrokerService(cooldownStore: BrokerCooldownStore(storeDirectory: directory, cliCooldownsURL: directory.appendingPathComponent("cli.json")),
            auditStore: BrokerAuditStore(storeDirectory: directory), outcomeStore: BrokerOutcomeStore(storeDirectory: directory),
            instructionCheckStore: InstructionCheckStore(storeDirectory: directory), livenessChecker: LocalRoutesViewLiveness())
        let model = AppModel(settingsRepository: repository, keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "not used"))),
            notificationService: NotificationServiceSpy(), brokerService: broker, t3InstanceDiscovery: T3InstanceDiscoveryFake())
        await model.bootstrap()
        model.settings.broker.policy.localRoutes = [Self.route()]
        model.settings.broker.policy.localRoutes[0].roles = ["verification"]
        BrokerPolicyEditorView.setControlledOnly(true, role: "verification", policy: &model.settings.broker.policy)
        await model.applyBrokerSettingsChange()
        await broker.setLocalLoad(Self.fixtureLoad())
        let rows = await model.brokerLocalRouteRows(now: Self.now)
        XCTAssertEqual(rows.first?.state, .brokerOff)
        XCTAssertNil(rows.first?.priceLevel)
        var saved = await repository.load()
        for _ in 0..<100 where saved.broker.policy.localRoutes.first?.roles != ["verification"] {
            try await Task.sleep(for: .milliseconds(10)); saved = await repository.load()
        }
        XCTAssertEqual(saved.broker.policy.localRoutes.first?.roles, ["verification"])
        XCTAssertEqual(saved.broker.policy.residencyRoles, ["verification": .controlled])
        XCTAssertNil(model.brokerLocalRouteSaveError)
    }
    func test_roleEditPersistsAndProfileSwapKeepsLocalState() async throws {
        let suite = "local-route-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SettingsRepository(userDefaults: defaults)
        var settings = AppSettings.default
        var route = Self.route(); route.roles = ["verification"]
        settings.broker.policy.localRoutes = [route]
        settings.broker.policy.residencyRoles = ["verification": .controlled]
        try await repository.save(settings)
        var restored = await repository.load()
        XCTAssertEqual(restored.broker.policy.localRoutes, [route])
        let rules = BrokerRuleSet(policy: restored.broker.policy)
        let json = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
        XCTAssertFalse(json.contains("local_routes")); XCTAssertFalse(json.contains("residency_roles"))
        let export = String(decoding: try JSONEncoder().encode(restored.broker.exportableProfile(named: "Test")), as: UTF8.self)
        XCTAssertFalse(export.contains("local_routes")); XCTAssertFalse(export.contains("residency_roles"))
        restored.broker.applyProfile(id: BrokerAgentProfile.builtIns[0].id)
        XCTAssertEqual(restored.broker.policy.localRoutes, [route])
        XCTAssertEqual(restored.broker.policy.residencyRoles, ["verification": .controlled])
    }
}

actor LocalRoutesViewLiveness: T3LivenessCheckerProtocol {
    func checkLiveness(instances: [T3InstanceConfig]) async -> [String: T3Liveness] { [:] }
}
