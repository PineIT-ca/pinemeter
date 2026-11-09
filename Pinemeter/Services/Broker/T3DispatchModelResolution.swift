import Foundation

enum T3DispatchModelResolution {
    enum Outcome: Equatable, Sendable {
        case broker(T3ModelSelection)
        case projectDefault(T3ModelSelection)
        case unresolved
    }

    static func resolve(
        decision: BrokerDecision?,
        projectDefault: T3ModelSelection?,
        instances: [T3InstanceConfig] = []
    ) -> Outcome {
        if let decision,
           !decision.degraded,
           decision.route == .t3,
           case .t3Dispatch(let model, let instanceID, let effort) = decision.invocation,
           isAcceptableInstanceID(instanceID),
           !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let options: [T3ModelSelection.Option]
            if let effort {
                let optionID: String
                switch instances.first(where: { $0.id == instanceID })?.driver {
                case "codex": optionID = "reasoningEffort"
                case "claudeAgent": optionID = "effort"
                case "cursor": optionID = "reasoning"
                default: return .unresolved
                }
                options = [.init(id: optionID, value: effort.rawValue)]
            } else {
                options = []
            }
            return .broker(T3ModelSelection(instanceId: instanceID, model: model, options: options))
        }
        return .unresolved
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
