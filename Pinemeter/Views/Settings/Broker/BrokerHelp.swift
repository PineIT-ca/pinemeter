//
//  BrokerHelp.swift
//  Pinemeter
//
//  The Broker window's vocabulary, in one place.
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
                    + "first model that still has quota left. Rank 1 is what you normally get."
            ),
            Term(
                name: "Account and route",
                definition: "Pinemeter checks every confirmed way to run the selected model and "
                    + "uses the available account with the most quota to spend. With \"Spend "
                    + "expiring quota first\" on, an account whose window resets sooner is "
                    + "preferred over one holding more that keeps for longer. "
                    + "Quota price can also move a model ahead of one of nearly the same quality, so "
                    + "quota that would otherwise expire unused is spent first. "
                    + "Quality and order, under each chain, shows the result."
            ),
            Term(
                name: "Effort",
                definition: "How hard to tell the model to think. Some models have no such "
                    + "setting, and those rows read Unsupported."
            ),
            Term(
                name: "Degraded",
                definition: "Every model is out of quota, and Pinemeter routed anyway. "
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
                definition: "Roles, model rankings, effort, quota ceilings and caller rules."
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

    static let localRoutes = BrokerHelpTopic(
        title: "Local and controlled routes",
        summary: "Models that run on machines you control, and the option to keep sensitive work on them.",
        terms: [
            Term(name: "Local route", definition: "A model on a machine you run, reached through a T3 instance. It has no quota; the broker prices it from the host's current load instead. It runs only after every cloud model in the chain unless load makes it the cheaper equal choice."),
            Term(name: "Price level", definition: "0 when the model is loaded and free, rising as work queues. Unknown, unreachable or busy-with-another-model hosts are skipped, so a pick never interrupts another model."),
            Term(name: "Controlled infrastructure", definition: "A route you mark as running on a host you control. Only you can mark it, and only on this Mac: profiles, routing updates and detected T3 data can never mark a route controlled."),
            Term(name: "Controlled infrastructure only", definition: "A role setting for sensitive work. Prompts and code stay on hosts you control. If no controlled route can take the pick, it fails instead of using a vendor model. It covers the model endpoint only; tools the agent runs can still reach the network."),
            Term(name: "Allowed roles", definition: "explore, verification and, if you tick it, execution. Local models never run review, legal-review, planning, design, research or heavy work.")
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
            Term(
                name: "Avoid reported quality drops",
                definition: "Pinemeter receives a signed model health summary. When two independent "
                    + "methods agree that a model's quality dropped, that model runs only after the "
                    + "others for a few days. Off ignores the summary."
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
                    + "different routes. Codex runs its own route as a native child agent; other "
                    + "harnesses start a separate Codex execution."
            ),
            Term(
                name: "Degraded",
                definition: "Nothing had quota left and this role allows falling back anyway. "
                    + "Frequent degraded picks mean your ceilings or chains need attention."
            ),
            Term(
                name: "Pick reason",
                definition: "Shown when a pick did not win on quality alone: Quota, Override or "
                    + "Drift. No chip means the best-ranked model that could run was picked."
            ),
            Term(name: "Controlled only", definition: "The agent or the role required controlled infrastructure, and the pick stayed on a host you control."),
            Term(name: "Controlled", definition: "The pick landed on a host you control without being required to."),
        ]
    )

    static let qualityAndOrder = BrokerHelpTopic(
        title: "Quality and order",
        summary: "How Pinemeter ranks the models in this role when quota prices change.",
        terms: [
            Term(
                name: "Quality",
                definition: "An estimate of how capable a model is at one effort, on the Artificial "
                    + "Analysis Intelligence Index. Higher is better."
            ),
            Term(
                name: "Effective",
                definition: "The quality used for ranking. It is never higher than the model above "
                    + "it in the chain, so the chain order holds when quota prices are equal."
            ),
            Term(
                name: "Floor",
                definition: "The lowest effective quality quota price may pick for this role."
            ),
            Term(
                name: "Latency limit",
                definition: "The slowest model and effort this role may use, in seconds. A raise "
                    + "never goes past it."
            ),
            Term(
                name: "Raise",
                definition: "When the chosen model's quota would otherwise expire unused, Pinemeter "
                    + "can send a higher effort from this table instead of switching model."
            ),
            Term(
                name: "Price",
                definition: "How much Pinemeter wants to keep a quota pool, from 0 (spend now) to 4 "
                    + "(keep)."
            ),
            Term(
                name: "Score",
                definition: "Effective quality minus the quota price. The current order sorts by "
                    + "score, highest first."
            ),
            Term(
                name: "Demoted",
                definition: "Model health reports a quality drop for this model, so it moved to the "
                    + "end of this role's order. Every report expires within three days unless it is "
                    + "renewed."
            ),
            Term(
                name: "Sources",
                definition: "Where the model health summary comes from, and when each last had new "
                    + "data. A stale, broken or paused source has no vote."
            ),
            Term(
                name: "Derived from chain order",
                definition: "A role saved before quality tables existed. It keeps the chain order."
            ),
        ]
    )

    static let outcomes = BrokerHelpTopic(
        title: "Outcomes",
        summary: "How each model has done in one role, measured from the reports your agents send back.",
        terms: [
            Term(
                name: "Own history only",
                definition: "Each model is compared only with its own earlier results in the same "
                    + "role. Models are never ranked against each other here."
            ),
            Term(
                name: "Windows",
                definition: "\u{201C}Last 7 days\u{201D} is compared with the 28 days before it. "
                    + "Days are in UTC."
            ),
            Term(
                name: "Quality picks",
                definition: "By default only picks that won on quality are counted. Picks held "
                    + "back for quota or chosen by an override are hidden, because they were not "
                    + "the model's normal work."
            ),
            Term(
                name: "Reported",
                definition: "The share of picks whose agent reported back that the work finished "
                    + "or failed. Low numbers mean the other rows rest on few tasks."
            ),
            Term(
                name: "Review passed",
                definition: "The share of reviews of this model's work that passed, with or "
                    + "without nits."
            ),
            Term(
                name: "Tokens per task",
                definition: "Mean tokens used by a finished task. A change can mean the model or "
                    + "the harness changed."
            ),
            Term(
                name: "Served model",
                definition: "The model name the provider reported. A change here can mean a "
                    + "silent fallback."
            ),
            Term(
                name: "\u{2014}",
                definition: "Fewer than 5 samples in that window, so no value is shown."
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
        case .auto:
            return "auto: the broker chooses the available route with the most quota to spend, "
                + "preferring quota that expires sooner unless that preference is switched off."
        case .native:
            return "native: Claude Code runs the subagent itself, on your Claude subscription."
        case .t3:
            return "t3: the T3 desktop app runs it, on the instance resolved below."
        case .codex:
            return "codex: Codex runs a native child agent when it asks; other harnesses start a separate Codex execution."
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
