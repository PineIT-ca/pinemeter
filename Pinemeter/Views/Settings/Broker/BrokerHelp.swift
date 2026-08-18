//
//  BrokerHelp.swift
//  Pinemeter
//
//  The Broker tab's vocabulary, in one place.
//
//  Tooltips alone cannot carry this screen. A tooltip is only found by
//  someone who already suspects a control is confusing, which is exactly not
//  the new user's situation — they do not know that "t3" is a place, that a
//  chain is ordered, or that rank 1 is what they will normally get. So the
//  concepts get a visible affordance (the standard macOS circled question
//  mark in a section header, opening a popover), and the individual controls
//  get tooltips on top of that for the reader who is already oriented.
//
//  Every string here is written for someone who has never seen the broker.
//  No decision-record ids, no field names, no "candidate chain" without
//  saying what a candidate is.
//

import SwiftUI

/// One popover's worth of explanation: a title and ordered term/definition
/// pairs. Modelled as data rather than views so the copy is reviewable in one
/// file and cannot drift between the places that show it.
struct BrokerHelpTopic {
    struct Term: Identifiable {
        let name: String
        let definition: String
        var id: String { name }
    }

    let title: String
    /// Optional lead sentence shown above the terms.
    var summary: String?
    let terms: [Term]
}

extension BrokerHelpTopic {
    static let rolesAndChains = BrokerHelpTopic(
        title: "How a pick is made",
        summary: "Your agent asks Pinemeter which model to use. It sends a role name. "
            + "Pinemeter answers with one model and one way to run it.",
        terms: [
            Term(
                name: "Role",
                definition: "The kind of work, named by your agent: review, execution, planning. "
                    + "The agent chooses the name. You decide what it means here."
            ),
            Term(
                name: "Chain",
                definition: "The ranked list under a role. Pinemeter starts at 1 and takes the "
                    + "first candidate that still has quota left. Rank 1 is what you normally get."
            ),
            Term(
                name: "Candidate",
                definition: "One row: a way to run the work, plus the model to run it with."
            ),
            Term(
                name: "Route",
                definition: "Where the work runs. native means Claude Code runs it itself. "
                    + "t3 means the T3 desktop app runs it, on another of your accounts. "
                    + "codex means the Codex CLI runs it."
            ),
            Term(
                name: "Effort",
                definition: "How hard to tell the model to think. Some models have no such "
                    + "setting, and those rows read Unsupported."
            ),
            Term(
                name: "Degraded",
                definition: "Every candidate is out of quota, and Pinemeter routed anyway. "
                    + "The pick is flagged so you know the answer came from a weaker model."
            ),
        ]
    )

    static let profiles = BrokerHelpTopic(
        title: "Rule profiles",
        summary: "A profile is a saved copy of your routing rules that you can switch back to.",
        terms: [
            Term(
                name: "What it saves",
                definition: "Roles, chains, quota ceilings, instance mappings and caller rules."
            ),
            Term(
                name: "What it never saves",
                definition: "Your T3 instances and which account each one uses. Those describe "
                    + "this Mac, so loading a profile leaves them exactly as they are."
            ),
            Term(
                name: "Edited",
                definition: "The rules on screen no longer match the saved profile. Save keeps "
                    + "them, Revert throws them away. Built-in profiles cannot be overwritten, "
                    + "so they offer Duplicate instead."
            ),
            Term(
                name: "Sharing",
                definition: "Export writes a plain JSON file you can check into a repo or send "
                    + "to another Mac. Import adds it without loading it."
            ),
        ]
    )

    static let instances = BrokerHelpTopic(
        title: "T3 instances",
        summary: "T3 is a separate app on this Mac. It runs one server holding several "
            + "signed-in lanes. Each lane is an instance.",
        terms: [
            Term(
                name: "Why they matter",
                definition: "Each instance is a different account, so each has its own quota. "
                    + "That is how the broker keeps working after your main account runs low."
            ),
            Term(
                name: "Account",
                definition: "Which of your Pinemeter accounts pays for this lane. Nothing in T3 "
                    + "says which, so you have to pick it. Left as None, this lane has no quota "
                    + "to check and cannot be paced. It appears on Claude lanes only: a Codex "
                    + "lane is paced by your ChatGPT usage instead, and needs nothing here."
            ),
            Term(
                name: "Detected, Manual, Stale",
                definition: "Detected means T3 confirmed this lane recently. Manual means you "
                    + "typed it and T3 has never confirmed it. Stale means T3 confirmed it once, "
                    + "but not lately."
            ),
            Term(
                name: "Reachable",
                definition: "The T3 server answered a ping just now. Unreachable usually means "
                    + "the T3 app is not running."
            ),
        ]
    )

    static let ceilings = BrokerHelpTopic(
        title: "Quota ceilings",
        summary: "A ceiling is the point where Pinemeter stops offering a lane, so it has "
            + "something left to fall back to.",
        terms: [
            Term(
                name: "Lower",
                definition: "More cautious. Pinemeter moves off your best model sooner and keeps "
                    + "more in reserve."
            ),
            Term(
                name: "Higher",
                definition: "Use more of the good model, and risk having nothing left later in "
                    + "the window."
            ),
            Term(
                name: "Stale usage data",
                definition: "Pinemeter reads your usage every few minutes. Past this age it "
                    + "stops trusting the reading rather than gating on a stale number."
            ),
        ]
    )

    static let instanceResolution = BrokerHelpTopic(
        title: "Which instance a t3 candidate reaches",
        summary: "A t3 candidate has to end up at one specific lane inside T3. "
            + "These are the two rules that decide, when the candidate does not say.",
        terms: [
            Term(
                name: "1. The candidate itself",
                definition: "If a chain row picks an instance by name, that wins and nothing "
                    + "below applies."
            ),
            Term(
                name: "2. Model mapping",
                definition: "Otherwise, if the model is mapped here, it goes to that instance."
            ),
            Term(
                name: "3. Fallback",
                definition: "Otherwise it goes to the fallback instance."
            ),
        ]
    )

    static let activity = BrokerHelpTopic(
        title: "Recent picks",
        summary: "Every decision the broker handed out since the app started, newest first.",
        terms: [
            Term(
                name: "Reason",
                definition: "Why this candidate won. \"top of chain\" means nothing was capped. "
                    + "Anything else names what ruled the higher-ranked rows out."
            ),
            Term(
                name: "Caller",
                definition: "Which harness asked: claude-code or codex. Callers can be allowed "
                    + "different routes, because Codex cannot run a native subagent."
            ),
            Term(
                name: "Degraded",
                definition: "Nothing had quota left and this role allows falling back anyway. "
                    + "Frequent degraded picks mean your ceilings or chains need attention."
            ),
        ]
    )
}

/// The standard macOS help affordance: a small circled question mark that
/// opens a popover. Visible, unlike a tooltip, which is the point.
struct BrokerHelpButton: View {
    let topic: BrokerHelpTopic

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("What do these mean?")
        .accessibilityLabel("Help: \(topic.title)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            BrokerHelpPopover(topic: topic)
        }
    }
}

private struct BrokerHelpPopover: View {
    let topic: BrokerHelpTopic

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text(topic.title)
                    .font(.headline)

                if let summary = topic.summary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(topic.terms) { term in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(term.name)
                            .font(.callout.weight(.semibold))
                        Text(term.definition)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(width: 340)
        // Tall topics scroll rather than growing a popover past the window.
        .frame(maxHeight: 460)
    }
}

// MARK: - Control tooltips

/// Per-value tooltips for the vocabulary that appears on individual controls.
/// Kept beside the popover copy so the two cannot contradict each other.
enum BrokerHelpText {
    static func route(_ route: BrokerPolicy.Route) -> String {
        switch route {
        case .native:
            return "native: Claude Code runs the subagent itself, on your Claude subscription."
        case .t3:
            return "t3: the T3 desktop app runs it, on the instance resolved below."
        case .codex:
            return "codex: the Codex CLI runs it, on your ChatGPT plan."
        }
    }

    static func rank(_ rank: Int, of count: Int) -> String {
        guard rank > 1 else {
            return "Tried first. This is the model you normally get for this role."
        }
        return rank == count
            ? "Last resort. Used only when all \(count - 1) rows above are out of quota."
            : "Tried \(ordinal(rank)), only when the \(rank - 1) rows above are out of quota."
    }

    static func model(_ model: String) -> String {
        "Model: \(model). Choose another, or Custom\u{2026} for an id that is not listed."
    }

    static func role(_ role: String, firstChoice: String) -> String {
        "Agents ask for \u{201C}\(role)\u{201D} by name. It currently routes to \(firstChoice) first."
    }

    private static func ordinal(_ value: Int) -> String {
        switch value {
        case 2: return "second"
        case 3: return "third"
        case 4: return "fourth"
        case 5: return "fifth"
        default: return "\(value)th"
        }
    }
}
