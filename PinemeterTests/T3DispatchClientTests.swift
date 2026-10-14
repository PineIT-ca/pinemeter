import XCTest
@testable import Pinemeter

final class T3DispatchClientTests: XCTestCase {
    private let origin = "http://127.0.0.1:3773"

    func test_tokenExchangeRequest_carriesTheThreeURNsAndRequestedScope() throws {
        let request = try T3DispatchClient.tokenExchangeRequest(
            origin: origin,
            credential: "pair+&=?/:;",
            clientLabel: "Pinemeter Mac"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, origin + "/oauth/token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self),
            "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange"
                + "&subject_token=pair%2B%26%3D%3F%2F%3A%3B"
                + "&subject_token_type=urn%3At3%3Aparams%3Aoauth%3Atoken-type%3Aenvironment-bootstrap"
                + "&requested_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token"
                + "&scope=orchestration%3Aread%20orchestration%3Aoperate"
                + "&client_label=Pinemeter%20Mac&client_device_type=desktop&client_os=macOS"
        )
    }

    func test_exchange_rejectsOriginsOutsideTheExactLoopbackOriginShapeWithoutTransport() async {
        let recorder = RequestRecorder()
        let client = T3DispatchClient(transport: { request in
            await recorder.append(request)
            return (Data(), Self.response(status: 200, url: request.url!))
        })

        for refused in [
            "http://evil:3773",
            "http://127.0.0.1:3773/path",
            "https://127.0.0.1:3773",
        ] {
            do {
                _ = try await client.exchangePairingCredential(
                    origin: refused,
                    credential: "pair",
                    clientLabel: "Pinemeter"
                )
                XCTFail("Expected \(refused) to be rejected")
            } catch {
                XCTAssertEqual(error as? T3DispatchClientError, .invalidOrigin)
            }
        }

        let requestCount = await recorder.count
        XCTAssertEqual(requestCount, 0)
    }

    func test_exchange_rejectsNonBearerTokenType() async {
        let client = T3DispatchClient(transport: { request in
            let data = Data(#"{"access_token":"bound","token_type":"DPoP","expires_in":3600,"scope":"orchestration:read orchestration:operate"}"#.utf8)
            return (data, Self.response(status: 200, url: request.url!))
        })

        do {
            _ = try await client.exchangePairingCredential(
                origin: origin,
                credential: "pair",
                clientLabel: "Pinemeter"
            )
            XCTFail("Expected DPoP token to be refused")
        } catch {
            XCTAssertEqual(error as? T3DispatchClientError, .dpopTokenIssued)
        }
    }

    func test_exchange_acceptsCaseInsensitiveBearerAndRejectsUnknownTokenType() async throws {
        let bearerClient = T3DispatchClient(transport: { request in
            let data = Data(#"{"access_token":"token","token_type":"bearer","expires_in":3600,"scope":"scope"}"#.utf8)
            return (data, Self.response(status: 200, url: request.url!))
        })
        let credential = try await bearerClient.exchangePairingCredential(
            origin: origin,
            credential: "pair",
            clientLabel: "Pinemeter"
        )
        XCTAssertEqual(credential.accessToken, "token")

        let unknownClient = T3DispatchClient(transport: { request in
            let data = Data(#"{"access_token":"token","token_type":"MAC","expires_in":3600,"scope":"scope"}"#.utf8)
            return (data, Self.response(status: 200, url: request.url!))
        })
        do {
            _ = try await unknownClient.exchangePairingCredential(
                origin: origin,
                credential: "pair",
                clientLabel: "Pinemeter"
            )
            XCTFail("Expected unknown token type to be refused")
        } catch {
            XCTAssertEqual(error as? T3DispatchClientError, .unsupportedTokenType)
        }
    }

    func test_exchange_rejectsResponseAboveFourMiB() async {
        let client = T3DispatchClient(transport: { request in
            (
                Data(repeating: 0, count: T3DispatchClient.maxResponseBytes + 1),
                Self.response(status: 200, url: request.url!)
            )
        })

        do {
            _ = try await client.exchangePairingCredential(
                origin: origin,
                credential: "pair",
                clientLabel: "Pinemeter"
            )
            XCTFail("Expected oversized response to be refused")
        } catch {
            XCTAssertEqual(error as? T3DispatchClientError, .tooLarge)
        }
    }

    func test_defaultTransport_rejectsDeclaredResponseAboveFourMiB() async {
        let transport = T3DispatchClient.defaultTransport(
            configuration: Self.oversizedResponseConfiguration()
        )

        do {
            _ = try await transport(URLRequest(url: URL(string: origin + "/declared")!))
            XCTFail("Expected declared oversized response to be refused")
        } catch {
            XCTAssertEqual(error as? T3DispatchClientError, .tooLarge)
        }
    }

    func test_defaultTransport_rejectsUnknownLengthStreamAboveFourMiB() async {
        let transport = T3DispatchClient.defaultTransport(
            configuration: Self.oversizedResponseConfiguration()
        )

        do {
            _ = try await transport(URLRequest(url: URL(string: origin + "/streamed")!))
            XCTFail("Expected streamed oversized response to be refused")
        } catch {
            XCTAssertEqual(error as? T3DispatchClientError, .tooLarge)
        }
    }

    func test_defaultTransport_accumulatesResponseChunks() async throws {
        let transport = T3DispatchClient.defaultTransport(
            configuration: Self.oversizedResponseConfiguration()
        )

        let result = try await transport(URLRequest(url: URL(string: origin + "/chunked")!))

        XCTAssertEqual(result.0, Data("first-second".utf8))
    }

    func test_defaultTransport_rejectsAccumulatedChunksAboveFourMiB() async {
        let transport = T3DispatchClient.defaultTransport(
            configuration: Self.oversizedResponseConfiguration()
        )

        do {
            _ = try await transport(URLRequest(url: URL(string: origin + "/accumulated")!))
            XCTFail("Expected accumulated oversized response to be refused")
        } catch {
            XCTAssertEqual(error as? T3DispatchClientError, .tooLarge)
        }
    }

    func test_defaultSessionConfiguration_disablesCachesAndCookies() {
        let configuration = T3DispatchClient.defaultSessionConfiguration()

        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    }

    func test_classify_maps4004014032xxAndOtherStatuses() throws {
        let ok = Data("ok".utf8)
        XCTAssertEqual(
            try T3DispatchClient.classify(Self.response(status: 200), data: ok),
            ok
        )
        XCTAssertThrowsError(try T3DispatchClient.classify(Self.response(status: 400), data: Data())) {
            XCTAssertEqual($0 as? T3DispatchClientError, .invalidCommand)
        }
        XCTAssertThrowsError(try T3DispatchClient.classify(Self.response(status: 401), data: Data())) {
            XCTAssertEqual($0 as? T3DispatchClientError, .unauthorized)
        }
        XCTAssertThrowsError(
            try T3DispatchClient.classify(
                Self.response(status: 403),
                data: Data(#"{"requiredScope":"orchestration:operate"}"#.utf8)
            )
        ) {
            XCTAssertEqual($0 as? T3DispatchClientError, .insufficientScope("orchestration:operate"))
        }
        XCTAssertThrowsError(try T3DispatchClient.classify(Self.response(status: 500), data: Data())) {
            XCTAssertEqual($0 as? T3DispatchClientError, .badStatus(500))
        }
    }

    func test_dispatchCommand_encodesRequiredNullsEmptyAttachmentsAndDistinctLowercaseIDs() throws {
        let now = Date(timeIntervalSince1970: 1_758_476_700.125)
        let command = T3DispatchCommand.instructionCheck(
            projectID: "project-1",
            modelSelection: T3ModelSelection(instanceId: "claudeAgent", model: "claude-fable-5"),
            port: 43117,
            now: now
        )
        let data = try JSONEncoder().encode(command)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try XCTUnwrap(root["message"] as? [String: Any])
        let createThread = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(command.threadCreate)) as? [String: Any]
        )

        XCTAssertEqual(root["type"] as? String, "thread.turn.start")
        XCTAssertNil(root["bootstrap"])
        XCTAssertEqual(createThread["type"] as? String, "thread.create")
        XCTAssertEqual(createThread["threadId"] as? String, root["threadId"] as? String)
        XCTAssertEqual(createThread["createdAt"] as? String, root["createdAt"] as? String)
        XCTAssertTrue(
            (createThread["title"] as? String)?.hasPrefix("Pinemeter instruction check — ") == true
        )
        XCTAssertEqual(root["runtimeMode"] as? String, "approval-required")
        XCTAssertEqual(root["interactionMode"] as? String, "default")
        XCTAssertEqual(message["role"] as? String, "user")
        XCTAssertEqual(message["text"] as? String, BrokerSetupPrompt.text(port: 43117, origin: .pasteboard))
        XCTAssertEqual((message["attachments"] as? [Any])?.count, 0)
        XCTAssertTrue(createThread.keys.contains("branch"))
        XCTAssertTrue(createThread["branch"] is NSNull)
        XCTAssertTrue(createThread.keys.contains("worktreePath"))
        XCTAssertTrue(createThread["worktreePath"] is NSNull)
        XCTAssertEqual(createThread["projectId"] as? String, "project-1")
        XCTAssertEqual(createThread["runtimeMode"] as? String, "approval-required")

        let ids = try [
            XCTUnwrap(root["commandId"] as? String),
            XCTUnwrap(root["threadId"] as? String),
            XCTUnwrap(message["messageId"] as? String),
            XCTUnwrap(createThread["commandId"] as? String),
        ]
        XCTAssertEqual(Set(ids).count, 4)
        for id in ids {
            XCTAssertEqual(id, id.lowercased())
            XCTAssertNotNil(UUID(uuidString: id))
        }
    }

    func test_instructionCheck_fullAccessAppliesToThreadAndTurn() throws {
        let command = T3DispatchCommand.instructionCheck(
            projectID: "project-1",
            modelSelection: T3ModelSelection(instanceId: "claudeAgent", model: "claude-sonnet-5"),
            port: 43117,
            now: Date(timeIntervalSince1970: 1_758_476_700),
            fullAccess: true
        )
        for data in [try JSONEncoder().encode(command.threadCreate), try JSONEncoder().encode(command)] {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["runtimeMode"] as? String, "full-access")
        }
    }

    func test_resolvedSelection_encodesExactlyInstanceIDAndModelForBrokerAndProjectDefault() throws {
        let brokerExpected = T3ModelSelection(instanceId: "claudeAgent", model: "claude-fable-5")
        let projectDefaultExpected = T3ModelSelection(instanceId: "codex", model: "gpt-5.6-terra")
        let brokerOutcome = T3DispatchModelResolution.resolve(
            decision: Self.decision(
                invocation: .t3Dispatch(
                    model: brokerExpected.model,
                    instanceId: brokerExpected.instanceId
                ),
                route: .t3
            ),
            projectDefault: nil
        )
        let projectDefaultOutcome = T3DispatchModelResolution.resolve(
            decision: Self.decision(invocation: .agent(model: "fable"), route: .native),
            projectDefault: projectDefaultExpected
        )

        let brokerSelection = try XCTUnwrap(Self.selection(from: brokerOutcome))
        let projectDefaultSelection = try XCTUnwrap(Self.selection(from: projectDefaultOutcome))
        XCTAssertEqual(brokerSelection, brokerExpected)
        XCTAssertEqual(projectDefaultSelection, projectDefaultExpected)

        let encoder = JSONEncoder()
        for selection in [brokerSelection, projectDefaultSelection] {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoder.encode(selection)) as? [String: Any]
            )
            XCTAssertEqual(Set(object.keys), Set(["instanceId", "model"]))
            XCTAssertNil(object["options"])
        }
    }

    func test_dispatchCommand_encodesTheSameModelSelectionTwice() throws {
        let outcome = T3DispatchModelResolution.resolve(
            decision: Self.decision(
                invocation: .t3Dispatch(model: "claude-fable-5", instanceId: "claudeAgent"),
                route: .t3
            ),
            projectDefault: nil
        )
        let selection = try XCTUnwrap(Self.selection(from: outcome))
        let command = T3DispatchCommand.instructionCheck(
            projectID: "project-1",
            modelSelection: selection,
            port: 43117,
            now: Date(timeIntervalSince1970: 1_758_476_700)
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any]
        )
        let createThread = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(command.threadCreate)) as? [String: Any]
        )
        let topLevelSelection = try XCTUnwrap(root["modelSelection"] as? [String: Any])
        let bootstrapSelection = try XCTUnwrap(createThread["modelSelection"] as? [String: Any])

        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: topLevelSelection, options: .sortedKeys),
            try JSONSerialization.data(withJSONObject: bootstrapSelection, options: .sortedKeys)
        )
    }

    func test_dispatchRequest_carriesBearerAndOneTurnStart() throws {
        let command = T3DispatchCommand.instructionCheck(
            projectID: "project-1",
            modelSelection: T3ModelSelection(instanceId: "claudeAgent", model: "claude-fable-5"),
            port: 43117,
            now: Date(timeIntervalSince1970: 1_758_476_700)
        )

        let request = try T3DispatchClient.dispatchRequest(
            origin: origin,
            token: "access-token",
            command: command
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/orchestration/dispatch")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(request.timeoutInterval, T3DispatchClient.dispatchTimeout)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(root["type"] as? String, "thread.turn.start")
    }

    func test_dispatch_createsTheThreadThenStartsTheTurnOnIt() async throws {
        let recorder = ClientCommandRecorder()
        let client = T3DispatchClient(transport: { request in
            await recorder.append(request)
            return (Data(#"{"sequence":7}"#.utf8), Self.response(status: 200))
        })
        let command = T3DispatchCommand.instructionCheck(
            projectID: "project-1",
            modelSelection: T3ModelSelection(instanceId: "claudeAgent", model: "claude-fable-5"),
            port: 43117,
            now: Date(timeIntervalSince1970: 1_758_476_700)
        )

        let sequence = try await client.dispatch(origin: origin, token: "access-token", command: command)

        let bodies = await recorder.bodies
        XCTAssertEqual(bodies.map { $0["type"] as? String }, ["thread.create", "thread.turn.start"])
        XCTAssertEqual(bodies.map { $0["threadId"] as? String }, [command.threadId, command.threadId])
        XCTAssertEqual(bodies.first?["projectId"] as? String, "project-1")
        XCTAssertEqual(sequence, 7)
    }

    func test_dispatch_failedCreateStartsNoTurn() async throws {
        let recorder = ClientCommandRecorder()
        let client = T3DispatchClient(transport: { request in
            await recorder.append(request)
            return (Data(#"{"code":"internal_error"}"#.utf8), Self.response(status: 500))
        })
        let command = T3DispatchCommand.instructionCheck(
            projectID: "project-1",
            modelSelection: T3ModelSelection(instanceId: "claudeAgent", model: "claude-fable-5"),
            port: 43117,
            now: Date(timeIntervalSince1970: 1_758_476_700)
        )

        do {
            _ = try await client.dispatch(origin: origin, token: "access-token", command: command)
            XCTFail("A rejected create must fail the dispatch")
        } catch {
            XCTAssertEqual(error as? T3DispatchClientError, .badStatus(500))
        }
        let bodies = await recorder.bodies
        XCTAssertEqual(bodies.map { $0["type"] as? String }, ["thread.create"])
    }

    func test_dispatch_failedTurnAfterCreateThrowsAndDeletesNothing() async throws {
        let recorder = ClientCommandRecorder()
        let client = T3DispatchClient(transport: { request in
            await recorder.append(request)
            let isTurn = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                .contains(#""type":"thread.turn.start""#)
            return isTurn
                ? (Data(#"{"code":"internal_error"}"#.utf8), Self.response(status: 500))
                : (Data(#"{"sequence":7}"#.utf8), Self.response(status: 200))
        })
        let command = T3DispatchCommand.instructionCheck(
            projectID: "project-1",
            modelSelection: T3ModelSelection(instanceId: "claudeAgent", model: "claude-fable-5"),
            port: 43117,
            now: Date(timeIntervalSince1970: 1_758_476_700)
        )

        do {
            _ = try await client.dispatch(origin: origin, token: "access-token", command: command)
            XCTFail("A rejected turn must fail the dispatch")
        } catch {
            XCTAssertEqual(error as? T3DispatchClientError, .badStatus(500))
        }
        // A timeout can hide a turn T3 did start, so the thread is never deleted.
        let bodies = await recorder.bodies
        XCTAssertEqual(bodies.map { $0["type"] as? String }, ["thread.create", "thread.turn.start"])
    }

    func test_listProjects_decodesOnlyProjectFieldsSanitizesTitlesAndDropsDeletedRows() async throws {
        let client = T3DispatchClient(transport: { request in
            let data = Data(#"""
            {
                "projects":[
                    {"id":"keep","title":"  Safe\u202e title  ","workspaceRoot":"/tmp/keep","defaultModelSelection":{"instanceId":"claudeAgent","model":"claude-fable-5"},"deletedAt":null,"auth":{"secret":"ignored"}},
                    {"id":"gone","title":"Gone","workspaceRoot":"/tmp/gone","defaultModelSelection":null,"deletedAt":"2026-09-21T00:00:00Z"}
                ],
                "threads":[{"message":"must not decode"}],
                "auth":{"secret":"must not decode"}
            }
            """#.utf8)
            return (data, Self.response(status: 200, url: request.url!))
        })

        let projects = try await client.listProjects(origin: origin, token: "access-token")

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].id, "keep")
        XCTAssertEqual(projects[0].title, "Safe title")
        XCTAssertEqual(projects[0].workspaceRoot, "/tmp/keep")
        XCTAssertEqual(
            projects[0].defaultModelSelection,
            T3ModelSelection(instanceId: "claudeAgent", model: "claude-fable-5")
        )
    }

    func test_listProjects_capsRowsBeforeTheyReachTheMenu() async throws {
        let rows: [[String: Any]] = (0...T3DispatchClient.maxProjectCount).map {
            [
                "id": "project-\($0)",
                "title": "Project \($0)",
                "workspaceRoot": "/tmp/project-\($0)",
                "defaultModelSelection": NSNull(),
                "deletedAt": NSNull(),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["projects": rows])
        let client = T3DispatchClient(transport: { request in
            (data, Self.response(status: 200, url: request.url!))
        })

        let projects = try await client.listProjects(origin: origin, token: "access-token")

        XCTAssertEqual(projects.count, T3DispatchClient.maxProjectCount)
    }

    private static func response(status: Int, url: URL = URL(string: "http://127.0.0.1:3773/test")!) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func oversizedResponseConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedResponseURLProtocol.self]
        return configuration
    }

    private static func decision(
        invocation: BrokerInvocation,
        route: BrokerPolicy.Route
    ) -> BrokerDecision {
        BrokerDecision(
            role: "standard",
            caller: "claude-code",
            model: invocation.model,
            route: route,
            agentModel: route == .native ? invocation.model : nil,
            invocation: invocation,
            reason: "configured",
            source: .policy,
            oracle: .absent,
            degraded: false,
            candidatesTried: []
        )
    }

    private static func selection(
        from outcome: T3DispatchModelResolution.Outcome
    ) -> T3ModelSelection? {
        switch outcome {
        case .broker(let selection), .projectDefault(let selection):
            return selection
        case .unresolved:
            return nil
        }
    }
}

private final class OversizedResponseURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let declaredLength = request.url?.path == "/declared"
        let headers = declaredLength
            ? ["Content-Length": String(T3DispatchClient.maxResponseBytes + 1)]
            : nil
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url?.path == "/chunked" {
            client?.urlProtocol(self, didLoad: Data("first-".utf8))
            client?.urlProtocol(self, didLoad: Data("second".utf8))
        } else if request.url?.path == "/accumulated" {
            for _ in 0..<3 {
                client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 2 * 1_048_576))
            }
        } else if !declaredLength {
            client?.urlProtocol(
                self,
                didLoad: Data(repeating: 0, count: T3DispatchClient.maxResponseBytes + 1)
            )
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor RequestRecorder {
    private var requests: [URLRequest] = []

    var count: Int { requests.count }

    func append(_ request: URLRequest) {
        requests.append(request)
    }
}

private actor ClientCommandRecorder {
    private(set) var bodies: [[String: Any]] = []

    func append(_ request: URLRequest) {
        guard let body = request.httpBody,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        bodies.append(root)
    }
}
