//
//  InstructionAuditWire.swift
//  Pinemeter
//
//  The JSON an agent reads back from the `audit` MCP tool.
//
//  The tool exists because of a split in what each side can do. An agent can
//  read the *effective* instruction stack — project files, skills, agent
//  definitions, whatever its own precedence rules pull in — which Pinemeter
//  cannot see. Pinemeter owns the matcher, which is deterministic and tested,
//  and which a model asked to "check the files" is not. So the agent collects
//  and the app grades.
//
//  Wire names are `rawValue` on the audit enums themselves, so a display
//  reword cannot silently rename a field other people's harnesses match on.
//

import Foundation

/// The `audit` tool result.
///
/// It carries the contract as well as the findings: a finding names a
/// directive, and a session that has never seen Pinemeter cannot act on a
/// name alone. It carries `boundaries` for the same reason the setup prompt
/// does — a tool result that lists gaps in a user's own instruction files must
/// say, in the result itself, that closing them is the user's call.
struct InstructionAuditWireReport: Encodable {
    struct Finding: Encodable {
        let kind: String
        let message: String
    }

    struct Source: Encodable {
        let path: String
        let status: String
        let findings: [Finding]
    }

    struct Counts: Encodable {
        let pass: Int
        let warning: Int
        let conflict: Int
        let unavailable: Int
    }

    struct Contract: Encodable {
        let instructionRoot: [String]
        let agentDefinition: String

        enum CodingKeys: String, CodingKey {
            case instructionRoot = "instruction_root"
            case agentDefinition = "agent_definition"
        }
    }

    let endpoint: String
    let pinemeterVersion: String
    let status: String
    let counts: Counts
    let sources: [Source]
    let contract: Contract
    let boundaries: [String]

    enum CodingKeys: String, CodingKey {
        case endpoint
        case pinemeterVersion = "pinemeter_version"
        case status, counts, sources, contract, boundaries
    }

    static let boundaries = [
        "Pinemeter grades instruction files. It never writes one.",
        "The listed paths are the user's own files: show the exact proposed edits and wait for the user's "
            + "approval before writing any of them.",
        "Submitted content is graded and discarded. Pinemeter neither stores nor logs it; only the path, the "
            + "verdict, and the finding text are kept, so the app can show when this machine was last checked.",
        "The audit matches wording, not intent, so a file that implies a rule still fails. State each rule "
            + "plainly, in that file's own voice.",
        "Never weaken the contract to make a check pass: no second broker client, policy layer, endpoint, or "
            + "fallback, and no bypass.",
        "Pinemeter grades only what you send. Collect the whole effective instruction stack, including the "
            + "project, skill, profile, and hook-injected files it cannot see, or the verdict is a subset.",
    ]
}

extension InstructionAuditReport {
    func wireReport(
        endpoint: String,
        appVersion: String = BrokerMCPServer.appVersion
    ) -> InstructionAuditWireReport {
        InstructionAuditWireReport(
            endpoint: endpoint,
            pinemeterVersion: appVersion,
            status: status.rawValue,
            counts: InstructionAuditWireReport.Counts(
                pass: count(of: .pass),
                warning: count(of: .warning),
                conflict: count(of: .conflict),
                unavailable: count(of: .unavailable)
            ),
            sources: sources.map { source in
                InstructionAuditWireReport.Source(
                    path: source.path,
                    status: source.status.rawValue,
                    findings: source.findings.map {
                        InstructionAuditWireReport.Finding(kind: $0.kind.rawValue, message: $0.message)
                    }
                )
            },
            contract: InstructionAuditWireReport.Contract(
                instructionRoot: InstructionAuditService.contractChecklist(endpoint: endpoint),
                agentDefinition: InstructionAuditService.nestedContractLine
            ),
            boundaries: InstructionAuditWireReport.boundaries
        )
    }

    /// The audit JSON returned in the `audit` tool result. Slashes stay
    /// unescaped so paths and endpoints read normally, matching `pick`.
    func wireJSONString(
        endpoint: String,
        appVersion: String = BrokerMCPServer.appVersion
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(wireReport(endpoint: endpoint, appVersion: appVersion))
        return String(decoding: data, as: UTF8.self)
    }

    func count(of status: InstructionAuditStatus) -> Int {
        sources.filter { $0.status == status }.count
    }
}
