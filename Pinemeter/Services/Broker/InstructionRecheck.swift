//
//  InstructionRecheck.swift
//  Pinemeter
//
//  When a recorded instruction check stops being evidence about this machine.
//
//  A check grades the instruction stack an agent had at one instant, against
//  the contract one build of Pinemeter shipped. Both sides move: instruction
//  files are edited by hand and by every agent that proposes an edit, and an
//  app update can change the contract the grader applies. A stored "all pass"
//  therefore decays into a claim about a stack and a contract that no longer
//  exist, and nothing about the record itself says so.
//
//  The rule is pure and lives apart from the pane and the reminder, so both
//  say the same thing about the same record.
//

import Foundation

enum InstructionRecheck {
    /// How long a check stands as current evidence. Long enough not to nag
    /// through a normal working fortnight, short enough that drift is caught
    /// while the edits that caused it are still recent.
    static let interval: TimeInterval = 14 * 24 * 60 * 60

    /// Why a re-check is due, or nothing when the record is current.
    enum Reason: String, Equatable, Sendable {
        case neverChecked
        case contractMayHaveChanged
        case setupContractChanged
        case stale
    }

    /// Precedence runs from least to most recoverable: a machine with no
    /// record needs a first check before anything else can be said about it,
    /// and a record graded by another build is questionable regardless of its
    /// age, so its age is not worth reporting.
    static func reason(
        for check: InstructionCheck?,
        currentVersion: String,
        currentSetupRevision: Int? = nil,
        now: Date
    ) -> Reason? {
        guard let check else { return .neverChecked }
        guard let gradedBy = check.gradedBy, gradedBy == currentVersion else {
            return .contractMayHaveChanged
        }
        if let currentSetupRevision,
           (check.setupRevision ?? 0) < currentSetupRevision {
            return .setupContractChanged
        }
        return now.timeIntervalSince(check.checkedAt) > interval ? .stale : nil
    }
}
