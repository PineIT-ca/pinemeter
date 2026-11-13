import XCTest
@testable import Pinemeter

final class T3DispatchModelResolutionTests: XCTestCase {
    private let projectDefault = T3ModelSelection(
        instanceId: "projectDefault",
        model: "fallback-model"
    )

    func test_resolve_preservesBrokerEffortInBothCommands() throws {
        for (model, instance, driver, optionID) in [
            ("gpt-6.1-sol", "codeInstance", "codex", "reasoningEffort"),
            ("claude-sonnet-5", "reviewInstance", "claudeAgent", "effort"),
            ("gpt-6.1-sol", "renamedCursor", "cursor", "reasoning"),
            ("custom-code-model", "renamedCodex", "codex", "reasoningEffort"),
        ] {
            let outcome = T3DispatchModelResolution.resolve(
                decision: decision(invocation: .t3Dispatch(model: model, instanceId: instance, effort: .high), route: .t3),
                projectDefault: projectDefault,
                instances: [T3InstanceConfig(id: instance, name: "Review", driver: driver)]
            )
            guard case .broker(let selection) = outcome else { return XCTFail("Expected broker selection") }
            let command = T3DispatchCommand.instructionCheck(projectID: "project", modelSelection: selection, port: 43117, now: Date())
            for data in [try JSONEncoder().encode(command.threadCreate), try JSONEncoder().encode(command)] {
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let selected = try XCTUnwrap(root["modelSelection"] as? [String: Any])
                XCTAssertEqual(selected["instanceId"] as? String, instance)
                XCTAssertEqual(selected["model"] as? String, model)
                XCTAssertEqual(selected["options"] as? [[String: String]], [["id": optionID, "value": "high"]])
            }
        }
    }

    func test_resolve_rejectsExplicitEffortForUnknownOrUnsupportedDriver() {
        for driver in [nil, "unknown", "pi"] as [String?] {
            let outcome = T3DispatchModelResolution.resolve(
                decision: decision(invocation: .t3Dispatch(model: "gpt-6.1-sol", instanceId: "reviewInstance", effort: .high), route: .t3),
                projectDefault: projectDefault,
                instances: [T3InstanceConfig(id: "reviewInstance", name: "Review", driver: driver)]
            )
            XCTAssertEqual(outcome, .unresolved)
        }
    }

    func test_resolve_rejectsRouteInvocationMismatch() {
        XCTAssertEqual(T3DispatchModelResolution.resolve(
            decision: decision(invocation: .t3Dispatch(model: "claude-sonnet-5", instanceId: "reviewInstance"), route: .native),
            projectDefault: projectDefault), .unresolved)
    }

    func test_resolve_nilEffortClearsProjectDefaultOptionsInBothCommands() throws {
        let defaultData = Data(#"{"instanceId":"codex","model":"gpt-6.1-sol","options":[{"id":"reasoningEffort","value":"low"}]}"#.utf8)
        let outcome = T3DispatchModelResolution.resolve(
            decision: decision(invocation: .t3Dispatch(model: "gpt-6.1-sol", instanceId: "codex"), route: .t3),
            projectDefault: try JSONDecoder().decode(T3ModelSelection.self, from: defaultData))
        guard case .broker(let selection) = outcome else { return XCTFail("Expected broker selection") }
        let command = T3DispatchCommand.instructionCheck(projectID: "project", modelSelection: selection, port: 43117, now: Date())
        for data in [try JSONEncoder().encode(command.threadCreate), try JSONEncoder().encode(command)] {
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let selected = try XCTUnwrap(root["modelSelection"] as? [String: Any])
            XCTAssertEqual(selected["options"] as? [[String: String]], [])
        }
    }

    func test_resolve_usesTheBrokerPickWhenItTargetsAnAcceptableT3Instance() {
        let result = T3DispatchModelResolution.resolve(
            decision: decision(
                invocation: .t3Dispatch(model: "broker-model", instanceId: "broker_instance-1"),
                route: .t3
            ),
            projectDefault: projectDefault
        )

        XCTAssertEqual(
            result,
            .broker(T3ModelSelection(instanceId: "broker_instance-1", model: "broker-model"))
        )
    }

    func test_resolve_blankBrokerModelIsUnresolved() {
        let result = T3DispatchModelResolution.resolve(
            decision: decision(
                invocation: .t3Dispatch(model: " \n", instanceId: "brokerInstance"),
                route: .t3
            ),
            projectDefault: projectDefault
        )

        XCTAssertEqual(result, .unresolved)
    }

    func test_resolve_degradedBrokerPickIsUnresolved() {
        let result = T3DispatchModelResolution.resolve(
            decision: decision(
                invocation: .t3Dispatch(model: "broker-model", instanceId: "brokerInstance"),
                route: .t3,
                degraded: true
            ),
            projectDefault: projectDefault
        )

        XCTAssertEqual(result, .unresolved)
    }

    func test_resolve_nonT3InvocationIsUnresolved() {
        let decisions = [
            decision(invocation: .agent(model: "native-model"), route: .native),
            decision(invocation: .codexExec(model: "codex-model"), route: .codex),
        ]

        for decision in decisions {
            XCTAssertEqual(
                T3DispatchModelResolution.resolve(
                    decision: decision,
                    projectDefault: projectDefault
                ),
                .unresolved
            )
        }
    }

    func test_resolve_T3RejectedInstanceIDIsUnresolved() {
        for instanceID in ["1leadingDigit", "contains.dot", "nonASCII-é"] {
            XCTAssertFalse(T3DispatchModelResolution.isAcceptableInstanceID(instanceID))
            XCTAssertEqual(
                T3DispatchModelResolution.resolve(
                    decision: decision(
                        invocation: .t3Dispatch(model: "broker-model", instanceId: instanceID),
                        route: .t3
                    ),
                    projectDefault: projectDefault
                ),
                .unresolved
            )
        }
    }

    func test_resolve_instanceIDLongerThanSixtyFourCharactersIsUnresolved() {
        let sixtyFourCharacters = "a" + String(repeating: "1", count: 63)
        let sixtyFiveCharacters = "a" + String(repeating: "1", count: 64)

        XCTAssertTrue(T3DispatchModelResolution.isAcceptableInstanceID(sixtyFourCharacters))
        XCTAssertFalse(T3DispatchModelResolution.isAcceptableInstanceID(sixtyFiveCharacters))
        XCTAssertEqual(
            T3DispatchModelResolution.resolve(
                decision: decision(
                    invocation: .t3Dispatch(model: "broker-model", instanceId: sixtyFiveCharacters),
                    route: .t3
                ),
                projectDefault: projectDefault
            ),
            .unresolved
        )
    }

    func test_resolve_withoutProjectDefaultIsUnresolved() {
        let result = T3DispatchModelResolution.resolve(
            decision: decision(invocation: .agent(model: "native-model"), route: .native),
            projectDefault: nil
        )

        XCTAssertEqual(result, .unresolved)
    }

    func test_resolve_unacceptableProjectDefaultInstanceIDIsUnresolved() {
        let result = T3DispatchModelResolution.resolve(
            decision: decision(invocation: .agent(model: "native-model"), route: .native),
            projectDefault: T3ModelSelection(instanceId: "invalid.instance", model: "fallback-model")
        )

        XCTAssertEqual(result, .unresolved)
    }

    func test_resolve_blankProjectDefaultModelIsUnresolved() {
        let result = T3DispatchModelResolution.resolve(
            decision: nil,
            projectDefault: T3ModelSelection(instanceId: "projectDefault", model: " \t")
        )

        XCTAssertEqual(result, .unresolved)
    }

    func test_resolve_nilDecisionIsUnresolved() {
        let result = T3DispatchModelResolution.resolve(
            decision: nil,
            projectDefault: projectDefault
        )

        XCTAssertEqual(result, .unresolved)
    }

    func test_resolve_nilDecisionWithoutProjectDefaultIsUnresolved() {
        let result = T3DispatchModelResolution.resolve(
            decision: nil,
            projectDefault: nil
        )

        XCTAssertEqual(result, .unresolved)
    }

    private func decision(
        invocation: BrokerInvocation,
        route: BrokerPolicy.Route,
        degraded: Bool = false
    ) -> BrokerDecision {
        BrokerDecision(
            role: "standard",
            caller: "claude-code",
            model: invocation.model,
            route: route,
            agentModel: route == .native ? invocation.model : nil,
            invocation: invocation,
            reason: degraded ? "degraded" : "configured",
            source: degraded ? .forcedDegraded : .policy,
            oracle: .absent,
            degraded: degraded,
            candidatesTried: []
        )
    }
}
