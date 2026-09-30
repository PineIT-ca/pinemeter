import XCTest
@testable import Pinemeter

final class T3DispatchModelResolutionTests: XCTestCase {
    private let projectDefault = T3ModelSelection(
        instanceId: "projectDefault",
        model: "fallback-model"
    )

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

    func test_resolve_blankBrokerModelUsesProjectDefault() {
        let result = T3DispatchModelResolution.resolve(
            decision: decision(
                invocation: .t3Dispatch(model: " \n", instanceId: "brokerInstance"),
                route: .t3
            ),
            projectDefault: projectDefault
        )

        XCTAssertEqual(result, .projectDefault(projectDefault))
    }

    func test_resolve_degradedBrokerPickUsesProjectDefault() {
        let result = T3DispatchModelResolution.resolve(
            decision: decision(
                invocation: .t3Dispatch(model: "broker-model", instanceId: "brokerInstance"),
                route: .t3,
                degraded: true
            ),
            projectDefault: projectDefault
        )

        XCTAssertEqual(result, .projectDefault(projectDefault))
    }

    func test_resolve_nonT3InvocationUsesProjectDefault() {
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
                .projectDefault(projectDefault)
            )
        }
    }

    func test_resolve_T3RejectedInstanceIDUsesProjectDefault() {
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
                .projectDefault(projectDefault)
            )
        }
    }

    func test_resolve_instanceIDLongerThanSixtyFourCharactersUsesProjectDefault() {
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
            .projectDefault(projectDefault)
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

    func test_resolve_nilDecisionUsesProjectDefault() {
        let result = T3DispatchModelResolution.resolve(
            decision: nil,
            projectDefault: projectDefault
        )

        XCTAssertEqual(result, .projectDefault(projectDefault))
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
