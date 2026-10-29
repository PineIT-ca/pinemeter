import Foundation

enum T3DispatchModelResolution {
    enum Outcome: Equatable, Sendable {
        case broker(T3ModelSelection)
        case projectDefault(T3ModelSelection)
        case unresolved
    }

    static func resolve(
        decision: BrokerDecision?,
        projectDefault: T3ModelSelection?
    ) -> Outcome {
        if let decision,
           !decision.degraded,
           case .t3Dispatch(let model, let instanceID, _) = decision.invocation,
           isAcceptableInstanceID(instanceID),
           !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .broker(T3ModelSelection(instanceId: instanceID, model: model))
        }
        guard let projectDefault,
              isAcceptableInstanceID(projectDefault.instanceId),
              !projectDefault.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unresolved
        }
        return .projectDefault(projectDefault)
    }

    static func isAcceptableInstanceID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard let first = bytes.first,
              bytes.count <= 64,
              first >= 65 && first <= 90 || first >= 97 && first <= 122 else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            $0 >= 65 && $0 <= 90
                || $0 >= 97 && $0 <= 122
                || $0 >= 48 && $0 <= 57
                || $0 == 95
                || $0 == 45
        }
    }
}
