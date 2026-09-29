import XCTest
@testable import Pinemeter

@MainActor
final class T3DispatchControllerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func test_connect_treatsAPairingURLAndItsTokenIdentically() async throws {
        let recorder = ControllerRequestRecorder()
        let client = tokenClient(recorder: recorder)
        let controller = makeController(client: client)

        await controller.connect(pastedText: "pair+value")
        await controller.connect(pastedText: "t3code://app/pair#token=pair%2Bvalue")

        let requests = await recorder.requests(path: "/oauth/token")
        XCTAssertEqual(requests.count, 2)
        let bareBody = try XCTUnwrap(requests.first?.httpBody)
        let urlBody = try XCTUnwrap(requests.last?.httpBody)
        XCTAssertEqual(bareBody, urlBody)
        let form = String(decoding: bareBody, as: UTF8.self).split(separator: "&")
        XCTAssertTrue(form.contains("client_label=\(T3DispatchController.clientLabel)"))
        XCTAssertEqual(T3DispatchController.clientLabel, "Pinemeter")
        XCTAssertNil(controller.lastFailure)
    }

    func test_connect_rejectsUnusablePasteWithoutRequest() async {
        let recorder = ControllerRequestRecorder()
        let controller = makeController(client: tokenClient(recorder: recorder))

        await controller.connect(pastedText: "two words")

        let requestCount = await recorder.count
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(controller.lastFailure, .unusablePairingInput)
    }

    func test_connect_publishesProofKeyAndMissingServerFailures() async {
        let client = T3DispatchClient(transport: { request in
            let data = Data(#"{"access_token":"bound","token_type":"DPoP","expires_in":3600,"scope":"orchestration:read orchestration:operate"}"#.utf8)
            return (data, ControllerRequestRecorder.response(status: 200, request: request))
        })
        let controller = makeController(client: client)

        await controller.connect(pastedText: "pair-token")
        XCTAssertEqual(controller.lastFailure, .proofKeyBoundPairingToken)

        let noServer = makeController(client: client, pointerOrigin: { nil })
        await noServer.connect(pastedText: "pair-token")
        XCTAssertEqual(noServer.lastFailure, .t3NotRunning)
    }

    func test_dispatch_usesBrokerPickAndPublishesItsSource() async throws {
        let recorder = ControllerRequestRecorder()
        let broker = ControllerBrokerSpy(result: .decision(brokerDecision()))
        let controller = try await connectedController(
            recorder: recorder,
            broker: broker,
            projectDefault: T3ModelSelection(instanceId: "projectDefault", model: "fallback-model")
        )

        let stamps = await dispatch(controller)

        let body = try await dispatchBody(recorder)
        let model = try XCTUnwrap(body["modelSelection"] as? [String: Any])
        XCTAssertEqual(model["instanceId"] as? String, "brokerInstance")
        XCTAssertEqual(model["model"] as? String, "broker-model")
        XCTAssertEqual(controller.lastModelSource, .broker)
        XCTAssertEqual(controller.lastDispatchThreadID, stamps.lastDispatchThreadID)
        XCTAssertNil(stamps.lastDispatchFailure)
        let pickCount = await broker.pickCallCount
        XCTAssertEqual(pickCount, 1)
        let pickedRole = await broker.lastPickedRole
        XCTAssertEqual(pickedRole, "review")
    }

    func test_dispatch_fullAccessOnlyForExplicitManualRun() async throws {
        let recorder = ControllerRequestRecorder()
        let broker = ControllerBrokerSpy(result: .decision(brokerDecision()))
        let controller = try await connectedController(
            recorder: recorder,
            broker: broker,
            projectDefault: nil
        )
        var settings = BrokerInstructionDispatchSettings.default
        settings.t3ProjectID = "project-1"

        _ = await controller.dispatchInstructionRecheck(
            brokerEnabled: true,
            port: 43117,
            settings: settings,
            trigger: .manual,
            now: now,
            latestCheck: nil,
            fullAccess: true,
            isAutomaticDispatchEnabled: { true }
        )

        let commands = await recorder.requests(path: "/api/orchestration/dispatch")
        XCTAssertEqual(commands.count, 2)
        for request in commands {
            let data = try XCTUnwrap(request.httpBody)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["runtimeMode"] as? String, "full-access")
        }

        _ = await controller.dispatchInstructionRecheck(
            brokerEnabled: true,
            port: 43117,
            settings: settings,
            trigger: .automatic,
            now: now,
            latestCheck: nil,
            fullAccess: true,
            isAutomaticDispatchEnabled: { true }
        )
        let allCommands = await recorder.requests(path: "/api/orchestration/dispatch")
        XCTAssertEqual(allCommands.count, 4)
        for request in allCommands.suffix(2) {
            let data = try XCTUnwrap(request.httpBody)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["runtimeMode"] as? String, "approval-required")
        }
    }

    func test_dispatch_failingBrokerPickUsesFreshProjectDefault() async throws {
        let recorder = ControllerRequestRecorder()
        let broker = ControllerBrokerSpy(result: .failure)
        let controller = try await connectedController(
            recorder: recorder,
            broker: broker,
            projectDefault: T3ModelSelection(instanceId: "projectDefault", model: "fallback-model")
        )

        _ = await dispatch(controller)

        let body = try await dispatchBody(recorder)
        let model = try XCTUnwrap(body["modelSelection"] as? [String: Any])
        XCTAssertEqual(model["instanceId"] as? String, "projectDefault")
        XCTAssertEqual(model["model"] as? String, "fallback-model")
        XCTAssertEqual(controller.lastModelSource, .projectDefault)
        let pickCount = await broker.pickCallCount
        XCTAssertEqual(pickCount, 1)
    }

    func test_dispatch_nonT3PickUsesFreshProjectDefault() async throws {
        let recorder = ControllerRequestRecorder()
        let broker = ControllerBrokerSpy(result: .decision(nonT3Decision()))
        let controller = try await connectedController(
            recorder: recorder,
            broker: broker,
            projectDefault: T3ModelSelection(instanceId: "projectDefault", model: "fallback-model")
        )

        _ = await dispatch(controller)

        let requestCount = await recorder.commands(type: "thread.turn.start").count
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(controller.lastModelSource, .projectDefault)
        let pickCount = await broker.pickCallCount
        XCTAssertEqual(pickCount, 1)
    }

    func test_dispatch_sendsNothingWhenNoModelResolves() async throws {
        let recorder = ControllerRequestRecorder()
        let broker = ControllerBrokerSpy(result: .decision(nonT3Decision()))
        let controller = try await connectedController(
            recorder: recorder,
            broker: broker,
            projectDefault: nil
        )

        let stamps = await dispatch(controller)

        let dispatchCount = await recorder.count(path: "/api/orchestration/dispatch")
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertEqual(controller.lastFailure, .noModelResolvable)
        XCTAssertNil(controller.lastModelSource)
        XCTAssertEqual(
            stamps.lastDispatchFailure,
            BrokerLifecycleText.sanitizedFailureReason(T3DispatchFailure.noModelResolvable.message)
        )
        let pickCount = await broker.pickCallCount
        XCTAssertEqual(pickCount, 1)
    }

    func test_dispatch_missingStoredCredentialReplacesStaleFailure() async throws {
        let recorder = ControllerRequestRecorder()
        let keychain = try await connectedKeychain()
        let controller = try await connectedController(
            recorder: recorder,
            broker: ControllerBrokerSpy(result: .decision(nonT3Decision())),
            projectDefault: nil,
            keychain: keychain
        )

        _ = await dispatch(controller)
        XCTAssertEqual(controller.lastFailure, .noModelResolvable)
        try await keychain.delete(account: T3DispatchCredential.keychainAccount)
        await controller.loadStoredConnection()

        let stamps = await dispatch(controller)

        XCTAssertEqual(controller.lastFailure, .notConnected)
        XCTAssertEqual(
            stamps.lastDispatchFailure,
            BrokerLifecycleText.sanitizedFailureReason(T3DispatchFailure.notConnected.message)
        )
    }

    func test_dispatch_missingFreshProjectPublishesProjectGoneAndSendsNothing() async throws {
        let recorder = ControllerRequestRecorder()
        let broker = ControllerBrokerSpy(result: .decision(brokerDecision()))
        let controller = try await connectedController(
            recorder: recorder,
            broker: broker,
            projectID: "different-project",
            projectDefault: nil
        )

        let stamps = await dispatch(controller)

        let dispatchCount = await recorder.count(path: "/api/orchestration/dispatch")
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertEqual(controller.lastFailure, .projectGone)
        XCTAssertEqual(
            stamps.lastDispatchFailure,
            BrokerLifecycleText.sanitizedFailureReason(T3DispatchFailure.projectGone.message)
        )
        // A pick is audited, so a missing project must be found before one is requested.
        let pickCount = await broker.pickCallCount
        XCTAssertEqual(pickCount, 0)
    }

    func test_dispatch_classifiesClientFailureBeforePersistingIt() async throws {
        let recorder = ControllerRequestRecorder()
        let broker = ControllerBrokerSpy(result: .decision(brokerDecision()))
        let controller = try await connectedController(
            recorder: recorder,
            broker: broker,
            projectDefault: nil,
            dispatchStatus: 403
        )

        let stamps = await dispatch(controller)

        XCTAssertEqual(controller.lastFailure, .insufficientScope("orchestration:operate"))
        XCTAssertEqual(
            stamps.lastDispatchFailure,
            BrokerLifecycleText.sanitizedFailureReason(
                T3DispatchFailure.insufficientScope("orchestration:operate").message
            )
        )
    }

    func test_refreshProjects_publishesEmptyAsItsOwnState() async throws {
        let keychain = try await connectedKeychain()
        let client = T3DispatchClient(transport: { request in
            let data = Data(#"{"projects":[]}"#.utf8)
            return (data, ControllerRequestRecorder.response(status: 200, request: request))
        })
        let controller = makeController(client: client, keychain: keychain)
        await controller.loadStoredConnection()

        await controller.refreshProjects()

        XCTAssertEqual(controller.projectListState, .empty)
        XCTAssertTrue(controller.hasLoadedProjects)
        XCTAssertTrue(controller.projects.isEmpty)
    }

    func test_refreshProjects_earlyReturnPublishesLoadFailedNotLoading() async throws {
        let keychain = try await connectedKeychain()
        let recorder = ControllerRequestRecorder()
        let controller = makeController(
            client: tokenClient(recorder: recorder),
            keychain: keychain,
            pointerOrigin: { nil }
        )
        await controller.loadStoredConnection()

        await controller.refreshProjects()

        XCTAssertEqual(controller.projectListState, .loadFailed)
        XCTAssertEqual(controller.lastFailure, .t3NotRunning)
        let requestCount = await recorder.count
        XCTAssertEqual(requestCount, 0)
    }

    func test_refreshProjects_keepsALoadedListAvailableWhileRefreshing() async throws {
        let keychain = try await connectedKeychain()
        let gate = SecondRequestGate()
        let client = T3DispatchClient(transport: { request in
            await gate.enter()
            let data = Data(#"{"projects":[{"id":"project-1","title":"Project One","workspaceRoot":"/tmp/project","defaultModelSelection":null,"deletedAt":null}]}"#.utf8)
            return (data, ControllerRequestRecorder.response(status: 200, request: request))
        })
        let controller = makeController(client: client, keychain: keychain)
        await controller.loadStoredConnection()
        await controller.refreshProjects()

        let refresh = Task { await controller.refreshProjects() }
        await gate.waitForSecondRequest()
        XCTAssertTrue(controller.isLoadingProjects)
        XCTAssertEqual(controller.projectListState, .available)
        await gate.release()
        await refresh.value

        XCTAssertFalse(controller.isLoadingProjects)
        XCTAssertEqual(controller.projectListState, .available)
    }

    func test_refreshProjects_failedFirstLoadCanRetrySuccessfully() async throws {
        let keychain = try await connectedKeychain()
        let recorder = ControllerRequestRecorder()
        let client = T3DispatchClient(transport: { request in
            await recorder.append(request)
            let attempt = await recorder.count
            let data = attempt == 1
                ? Data(#"{"code":"internal_error"}"#.utf8)
                : Data(#"{"projects":[{"id":"project-1","title":"Project One","workspaceRoot":"/tmp/project","defaultModelSelection":null,"deletedAt":null}]}"#.utf8)
            return (
                data,
                ControllerRequestRecorder.response(status: attempt == 1 ? 500 : 200, request: request)
            )
        })
        let controller = makeController(client: client, keychain: keychain)
        await controller.loadStoredConnection()

        await controller.refreshProjects()
        XCTAssertEqual(controller.projectListState, .loadFailed)
        XCTAssertFalse(controller.hasLoadedProjects)

        await controller.refreshProjects()
        XCTAssertEqual(controller.projectListState, .available)
        XCTAssertEqual(controller.projects.map(\.id), ["project-1"])
        let requestCount = await recorder.count
        XCTAssertEqual(requestCount, 2)
    }

    func test_connectionStateDerivesConnectedExpiringAndExpiredFromPublishedConnection() async throws {
        let expiresAt = now.addingTimeInterval(T3DispatchCredential.expiringSoonInterval + 1)
        let keychain = KeychainRepositoryFake()
        try await keychain.save(
            sessionKey: try T3DispatchCredential(
                accessToken: "test-token",
                expiresAt: expiresAt,
                scope: "orchestration:read orchestration:operate"
            ).encoded(),
            account: T3DispatchCredential.keychainAccount
        )
        let controller = makeController(client: T3DispatchClient(), keychain: keychain)
        await controller.loadStoredConnection()

        XCTAssertEqual(controller.connectionState(at: now), .connected)
        XCTAssertEqual(controller.connectionState(at: now.addingTimeInterval(2)), .expiringSoon)
        XCTAssertEqual(controller.connectionState(at: expiresAt), .expired)
    }

    func test_outstandingRunStateWaitsStallsAndClearsForANewerCheck() {
        var settings = BrokerInstructionDispatchSettings.default
        settings.lastDispatchedAt = now
        settings.lastDispatchThreadID = "thread-1"
        let controller = makeController(client: T3DispatchClient())

        controller.updateOutstandingRun(settings: settings, latestCheck: nil)
        XCTAssertEqual(controller.lastDispatchThreadID, "thread-1")
        XCTAssertEqual(
            controller.outstandingRunState(at: now.addingTimeInterval(Self.stallOffset - 1)),
            .waiting
        )
        XCTAssertEqual(
            controller.outstandingRunState(at: now.addingTimeInterval(Self.stallOffset)),
            .stalled
        )

        controller.updateOutstandingRun(
            settings: settings,
            latestCheck: instructionCheck(at: now)
        )
        XCTAssertEqual(controller.outstandingRunState(at: now), .waiting)

        controller.updateOutstandingRun(
            settings: settings,
            latestCheck: instructionCheck(at: now.addingTimeInterval(1))
        )
        XCTAssertEqual(controller.outstandingRunState(at: now), .none)
    }

    private static let stallOffset = T3DispatchController.stalledRunInterval

    private func makeController(
        client: T3DispatchClient,
        keychain: KeychainRepositoryFake = KeychainRepositoryFake(),
        broker: ControllerBrokerSpy = ControllerBrokerSpy(result: .failure),
        pointerOrigin: @escaping @Sendable () async -> String? = { "http://127.0.0.1:3773" }
    ) -> T3DispatchController {
        let fixedNow = now
        return T3DispatchController(
            client: client,
            keychainRepository: keychain,
            brokerService: broker,
            now: { fixedNow },
            pointerOrigin: pointerOrigin
        )
    }

    private func tokenClient(recorder: ControllerRequestRecorder) -> T3DispatchClient {
        T3DispatchClient(transport: { request in
            await recorder.append(request)
            let data = Data(#"{"access_token":"token","token_type":"Bearer","expires_in":3600,"scope":"orchestration:read orchestration:operate"}"#.utf8)
            return (data, ControllerRequestRecorder.response(status: 200, request: request))
        })
    }

    private func connectedController(
        recorder: ControllerRequestRecorder,
        broker: ControllerBrokerSpy,
        projectID: String = "project-1",
        projectDefault: T3ModelSelection?,
        dispatchStatus: Int = 200,
        keychain: KeychainRepositoryFake? = nil
    ) async throws -> T3DispatchController {
        let resolvedKeychain: KeychainRepositoryFake
        if let suppliedKeychain = keychain {
            resolvedKeychain = suppliedKeychain
        } else {
            resolvedKeychain = try await connectedKeychain()
        }
        let projectDefaultJSON = projectDefault.map {
            #"{"instanceId":"\#($0.instanceId)","model":"\#($0.model)"}"#
        } ?? "null"
        let client = T3DispatchClient(transport: { request in
            await recorder.append(request)
            let data: Data
            if request.url?.path == "/api/orchestration/dispatch" {
                data = dispatchStatus == 403
                    ? Data(#"{"requiredScope":"orchestration:operate"}"#.utf8)
                    : Data(#"{"sequence":1}"#.utf8)
            } else {
                data = Data(#"{"projects":[{"id":"\#(projectID)","title":"Current project","workspaceRoot":"/tmp/project","defaultModelSelection":\#(projectDefaultJSON),"deletedAt":null}]}"#.utf8)
            }
            let status = request.url?.path == "/api/orchestration/dispatch" ? dispatchStatus : 200
            return (data, ControllerRequestRecorder.response(status: status, request: request))
        })
        let controller = makeController(client: client, keychain: resolvedKeychain, broker: broker)
        await controller.loadStoredConnection()
        return controller
    }

    private func connectedKeychain() async throws -> KeychainRepositoryFake {
        let keychain = KeychainRepositoryFake()
        try await keychain.save(
            sessionKey: try T3DispatchCredential(
                accessToken: "test-token",
                expiresAt: now.addingTimeInterval(3_600),
                scope: "orchestration:read orchestration:operate"
            ).encoded(),
            account: T3DispatchCredential.keychainAccount
        )
        return keychain
    }

    private func dispatch(_ controller: T3DispatchController) async -> T3DispatchStamps {
        var settings = BrokerInstructionDispatchSettings.default
        settings.t3ProjectID = "project-1"
        return await controller.dispatchInstructionRecheck(
            brokerEnabled: true,
            port: 43_117,
            settings: settings,
            trigger: .manual,
            now: now,
            latestCheck: nil,
            isAutomaticDispatchEnabled: { true }
        )
    }

    private func dispatchBody(_ recorder: ControllerRequestRecorder) async throws -> [String: Any] {
        let requests = await recorder.commands(type: "thread.turn.start")
        let request = try XCTUnwrap(requests.first)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func brokerDecision() -> BrokerDecision {
        BrokerDecision(
            role: "standard",
            caller: "claude-code",
            model: "t3:brokerInstance/broker-model",
            route: .t3,
            agentModel: nil,
            invocation: .t3Dispatch(model: "broker-model", instanceId: "brokerInstance"),
            reason: "configured",
            source: .policy,
            oracle: .absent,
            degraded: false,
            candidatesTried: []
        )
    }

    private func nonT3Decision() -> BrokerDecision {
        BrokerDecision(
            role: "standard",
            caller: "claude-code",
            model: "native-model",
            route: .native,
            agentModel: "native-model",
            invocation: .agent(model: "native-model"),
            reason: "configured",
            source: .policy,
            oracle: .absent,
            degraded: false,
            candidatesTried: []
        )
    }

    private func instructionCheck(at date: Date) -> InstructionCheck {
        InstructionCheck(
            runID: "run-1",
            caller: "claude-code",
            checkedAt: date,
            gradedBy: BrokerMCPServer.appVersion,
            sources: [InstructionCheckSource(path: "a.md", status: .pass, findings: [])]
        )
    }
}

private actor ControllerRequestRecorder {
    private var recorded: [URLRequest] = []

    var count: Int { recorded.count }

    func append(_ request: URLRequest) {
        recorded.append(request)
    }

    func requests(path: String) -> [URLRequest] {
        recorded.filter { $0.url?.path == path }
    }

    func count(path: String) -> Int {
        recorded.filter { $0.url?.path == path }.count
    }

    /// Dispatch-path requests whose JSON body names this command type. A run
    /// posts a `thread.create` and then a `thread.turn.start`.
    func commands(type: String) -> [URLRequest] {
        recorded.filter { request in
            guard request.url?.path == "/api/orchestration/dispatch",
                  let body = request.httpBody,
                  let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return false
            }
            return root["type"] as? String == type
        }
    }

    nonisolated static func response(status: Int, request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

private actor ControllerBrokerSpy: BrokerLifecycleProtocol {
    enum Result: Sendable {
        case decision(BrokerDecision)
        case failure
    }

    private let result: Result
    private(set) var pickCallCount = 0
    private(set) var lastPickedRole: String?

    init(result: Result) {
        self.result = result
    }

    func pick(role: String, caller: String?) async throws -> BrokerDecision {
        pickCallCount += 1
        lastPickedRole = role
        switch result {
        case .decision(let decision):
            return decision
        case .failure:
            throw BrokerError.configError("synthetic pick failure")
        }
    }

    func status() async -> BrokerStatus {
        BrokerStatus(
            running: false,
            port: nil,
            oracle: BrokerStatus.OracleFreshness(
                present: false,
                stale: false,
                ageSeconds: nil,
                accounts: []
            ),
            cooldowns: [],
            t3: [],
            roles: [],
            recentPicksCount: 0
        )
    }

    func down(target: String, minutes: Int?) async throws {}
    func up(target: String) async throws {}
    func refresh() async throws {}
    func updatePolicy(_ policy: BrokerPolicy) async {}
    func updateOracleSnapshot(_ oracle: OracleSnapshot?) async {}
    func updateT3Liveness(_ liveness: [String: T3Liveness]) async {}
    func updateServerState(_ state: BrokerUIState.ServerState) async {}
    func setRefreshHandler(_ handler: @escaping @Sendable () async throws -> Void) async {}
    func uiStateUpdates() async -> AsyncStream<BrokerUIState> { AsyncStream { $0.finish() } }
}

/// Suspends the second request until released, so a test can observe the
/// state published while a refresh of an already-loaded list is in flight.
private actor SecondRequestGate {
    private var requestCount = 0
    private var secondRequestArrived = false
    private var arrivalContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enter() async {
        requestCount += 1
        guard requestCount == 2 else { return }
        secondRequestArrived = true
        arrivalContinuation?.resume()
        arrivalContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitForSecondRequest() async {
        if secondRequestArrived { return }
        await withCheckedContinuation { arrivalContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
