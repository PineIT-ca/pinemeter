import Foundation

enum BrokerReviewVerdict: String, Codable, CaseIterable, Sendable {
    case pass
    case passWithNits = "pass-with-nits"
    case fail
    case inconclusive
}

/// Additive run detail, kept outside the strict lifecycle report contract.
struct BrokerOutcomeDetail: Codable, Equatable, Sendable {
    var backupIndex: Int? = nil
    var harnessVersion: String? = nil
    var servedModel: String? = nil
    var reviewVerdict: BrokerReviewVerdict? = nil
    var reviewedDecisionIDs: [String]? = nil
    var totalTokens: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case backupIndex = "backup_index"
        case harnessVersion = "harness_version"
        case servedModel = "served_model"
        case reviewVerdict = "review_verdict"
        case reviewedDecisionIDs = "reviewed_decision_ids"
        case totalTokens = "total_tokens"
    }

    var isEmpty: Bool {
        backupIndex == nil && harnessVersion == nil && servedModel == nil && reviewVerdict == nil && reviewedDecisionIDs == nil && totalTokens == nil
    }

    func normalized(status: BrokerLifecycleStatus, backupCount: Int) throws -> BrokerOutcomeDetail? {
        guard !isEmpty else { return nil }
        guard status != .started,
              backupIndex.map({ 0...backupCount ~= $0 }) ?? true,
              totalTokens.map({ 0...2_147_483_647 ~= $0 }) ?? true else {
            throw BrokerAuditStoreError.invalidLifecycleReport
        }
        guard reviewVerdict == nil || status == .completed,
              reviewedDecisionIDs == nil || reviewVerdict != nil else {
            throw BrokerAuditStoreError.invalidLifecycleReport
        }
        var result = self
        if let reviewedDecisionIDs {
            guard reviewedDecisionIDs.count <= 8 else {
                throw BrokerAuditStoreError.invalidLifecycleReport
            }
            let ids = try reviewedDecisionIDs.map { id in
                guard let normalized = BrokerLifecycleText.normalizedIdentifier(id) else {
                    throw BrokerAuditStoreError.invalidLifecycleReport
                }
                return normalized
            }
            result.reviewedDecisionIDs = ids.isEmpty ? nil : ids
        }
        if let harnessVersion {
            guard let value = BrokerOutcomeText.normalizedHarnessVersion(harnessVersion) else {
                throw BrokerAuditStoreError.invalidLifecycleReport
            }
            result.harnessVersion = value
        }
        if let servedModel {
            guard let value = BrokerOutcomeText.normalizedServedModel(servedModel) else {
                throw BrokerAuditStoreError.invalidLifecycleReport
            }
            result.servedModel = value
        }
        return result
    }
    func resolvingReviewedIDs(decisionID: String, isKnown: (String) -> Bool) -> BrokerOutcomeDetail {
        var result = self
        var seen: Set<String> = []
        let ids = (reviewedDecisionIDs ?? []).filter {
            $0 != decisionID && isKnown($0) && seen.insert($0).inserted
        }
        result.reviewedDecisionIDs = ids.isEmpty ? nil : ids
        return result
    }
}

enum BrokerOutcomeText {
    static let credentialMarkers = [
        "sk-ant-", "sessionKey=", "__Secure-", "next-auth", "Bearer ", "Cookie:",
        "Set-Cookie", "Authorization:", "X-API-Key", "pm_", "AIza",
    ]

    static func trimmedASCII(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
    }

    static func normalizedHarnessVersion(_ value: String) -> String? {
        normalized(value, pattern: #"\A[a-z0-9][a-z0-9-]{0,31}/[0-9A-Za-z.+-]{1,31}\z"#)
    }

    static func normalizedServedModel(_ value: String) -> String? {
        normalized(value, pattern: #"\A[A-Za-z0-9][A-Za-z0-9._:/@\[\]-]{0,95}\z"#)
    }

    private static func normalized(_ value: String, pattern: String) -> String? {
        let trimmed = trimmedASCII(value)
        guard trimmed.range(of: pattern, options: .regularExpression) != nil,
              !credentialMarkers.contains(where: { trimmed.contains($0) }) else { return nil }
        return trimmed
    }
}
