//
//  BrokerThresholdsCard.swift
//  Pinemeter
//
//  The quota ceilings every candidate is gated on. These were six terse
//  steppers ("Session", "Weekly", "Sonnet Weekly", …) with no statement of
//  what they do; a percentage with no sentence attached is unusable, because
//  the user cannot tell whether raising it is more aggressive or less.
//
//  Sliders, not steppers: these are proportions across a wide range, and
//  1%-per-click steppers made a 50→90 change forty clicks. The numeric readout
//  keeps the exact value visible, which is the one thing a slider alone loses.
//

import SwiftUI

struct BrokerThresholdsCard: View {
    @Bindable var appModel: AppModel

    private var thresholds: Binding<BrokerThresholds> {
        $appModel.settings.broker.policy.thresholds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "Quota Ceilings",
                systemImage: "gauge.with.dots.needle.33percent",
                subtitle: "A lane stops being offered once its usage passes its ceiling. "
                    + "Lower is more cautious: the broker moves off that lane sooner and saves the rest.",
                help: .ceilings
            )

            VStack(spacing: 6) {
                thresholdRow(
                    "Claude session",
                    value: thresholds.sessionPct,
                    help: "Claude's rolling 5-hour session window."
                )
                thresholdRow(
                    "Claude weekly",
                    value: thresholds.weeklyPct,
                    help: "Claude's all-model weekly window."
                )
                thresholdRow(
                    "Sonnet weekly",
                    value: thresholds.sonnetWeeklyPct,
                    help: "Sonnet's own weekly window, which caps separately from the all-model one."
                )
                thresholdRow(
                    "Fable weekly",
                    value: thresholds.fableWeeklyPct,
                    help: "Fable's own weekly window, which caps separately from the all-model one."
                )
                thresholdRow(
                    "ChatGPT weekly",
                    value: thresholds.chatgptWeeklyPct,
                    help: "The ChatGPT plan window that gates the Codex and GPT lanes."
                )
            }

            Divider()
                .padding(.vertical, 2)

            stalenessRow
        }
        .brokerCard()
    }

    private func thresholdRow(_ title: String, value: Binding<Double>, help: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .frame(width: 116, alignment: .leading)

            Slider(value: value, in: 50...100, step: 1)

            Text("\(Int(value.wrappedValue))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) ceiling")
        .accessibilityValue("\(Int(value.wrappedValue)) percent")
    }

    // MARK: - Staleness

    /// Presets rather than a free stepper: the value only matters as "how long
    /// before Pinemeter stops trusting its own usage reading", and every
    /// useful answer is a round number of minutes.
    private static let stalenessPresets: [TimeInterval] = [300, 600, 1200, 1800, 3600, 7200]

    private var stalenessRow: some View {
        let current = appModel.settings.broker.policy.thresholds.stalenessSeconds
        // A hand-edited or imported policy can carry a value off the preset
        // list; offering it as its own row keeps the picker from silently
        // rewriting it the moment this card renders.
        let options = Self.stalenessPresets.contains(current)
            ? Self.stalenessPresets
            : (Self.stalenessPresets + [current]).sorted()

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage data goes stale after")
                    .font(.callout)
                Text("Past this age the broker treats a reading as unknown and stops gating on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Picker("", selection: thresholds.stalenessSeconds) {
                ForEach(options, id: \.self) { seconds in
                    Text(Self.stalenessLabel(seconds)).tag(seconds)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 118)
            .accessibilityLabel("Usage data staleness")
        }
    }

    static func stalenessLabel(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) sec" }
        if whole % 3600 == 0 {
            let hours = whole / 3600
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return "\(whole / 60) min"
    }
}
