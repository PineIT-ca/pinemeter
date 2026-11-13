//
//  SettingsForm.swift
//  Pinemeter
//
//  The grouped form that macOS System Settings uses, rebuilt as three small
//  views so a Settings tab can lay out its rows without a `Form`. SwiftUI's
//  grouped `Form` brings its own scroll view, which fights a window that is
//  meant to fit its content; these views bring none.
//
//  `SettingsSection` is an optional header, a `SettingsGroup`, and an
//  optional footer. `SettingsGroup` is the rounded container and draws the
//  hairline between each pair of rows. `SettingsRow` is one row: a leading
//  title with an optional caption and a trailing control. Every trailing
//  control shares one trailing edge because every row pads by the same
//  amount and places the control last.
//

import AppKit
import SwiftUI

/// Dimensions shared by the Settings window and its tabs.
enum SettingsLayout {
    /// The Settings window's one width. Tabs are laid out for it and the
    /// window is not user-resizable.
    static let windowWidth: CGFloat = 640
    /// Padding between the window edge and a tab's content.
    static let panePadding: CGFloat = 24
    /// Horizontal inset of a row inside its group.
    static let rowHorizontalPadding: CGFloat = 16
    /// Vertical inset of a row inside its group.
    static let rowVerticalPadding: CGFloat = 10
    /// Extra leading inset for a sub-row that depends on the row above it.
    static let rowIndent: CGFloat = 20
    /// One width for every trailing picker, so their leading edges line up
    /// as well as their trailing ones.
    static let pickerWidth: CGFloat = 160
    static let groupCornerRadius: CGFloat = 8
}

/// A titled group of rows with optional footer text.
struct SettingsSection<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            SettingsGroup { content }
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The rounded container. Children are laid out top to bottom with a
/// hairline between each pair; a `ForEach` child contributes one row per
/// element, so dynamic lists get dividers too.
struct SettingsGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        _VariadicView.Tree(SettingsGroupLayout()) { content }
            .background(
                RoundedRectangle(cornerRadius: SettingsLayout.groupCornerRadius, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.groupCornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.groupCornerRadius, style: .continuous))
    }
}

/// Inserts the divider between rows. The divider starts at the row's text
/// inset, as System Settings draws it, so it reads as a separator between
/// rows rather than a border of the container.
private struct SettingsGroupLayout: _VariadicView_UnaryViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Divider()
                        .padding(.leading, SettingsLayout.rowHorizontalPadding)
                }
            }
        }
    }
}

/// One row: leading title and optional caption, trailing control.
struct SettingsRow<Control: View>: View {
    private let title: String
    private let caption: String?
    private let indented: Bool
    private let control: Control

    /// - Parameters:
    ///   - title: The setting's name, in sentence case.
    ///   - caption: One line explaining the setting, when the title alone is
    ///     not enough.
    ///   - indented: True for a sub-row that only applies while the row above
    ///     it is on. The caller disables it; this only moves it in.
    init(
        _ title: String,
        caption: String? = nil,
        indented: Bool = false,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.caption = caption
        self.indented = indented
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
        }
        .settingsRowPadding()
        .padding(.leading, indented ? SettingsLayout.rowIndent : 0)
    }
}

extension SettingsRow where Control == EmptyView {
    /// A row with no control: a value line or a notice.
    init(_ title: String, caption: String? = nil, indented: Bool = false) {
        self.init(title, caption: caption, indented: indented) { EmptyView() }
    }
}

extension View {
    /// The inset every row in a `SettingsGroup` uses. Apply it to custom row
    /// content (a slider with its caption, a card grid) so its edges line up
    /// with the `SettingsRow`s around it.
    func settingsRowPadding() -> some View {
        self
            .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
            .padding(.vertical, SettingsLayout.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A settings tab's body: the window's fixed width, padded on every
    /// side. The window is not user-resizable, so the tab decides its own
    /// height and the window fits it.
    func settingsPane() -> some View {
        self
            .padding(SettingsLayout.panePadding)
            .frame(width: SettingsLayout.windowWidth, alignment: .topLeading)
    }

    /// A switch in the small size, the control every boolean row uses.
    func settingsSwitch() -> some View {
        self
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }

    /// The one width every trailing picker uses.
    func settingsPicker() -> some View {
        self
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: SettingsLayout.pickerWidth)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        SettingsSection("Menu bar and popover", footer: "Sub-rows apply only while the row above is on.") {
            SettingsRow("Show ChatGPT usage", caption: "Show ChatGPT plan quota in the popover.") {
                Toggle("", isOn: .constant(true)).settingsSwitch()
            }
            SettingsRow("Codex Spark", indented: true) {
                Toggle("", isOn: .constant(false)).settingsSwitch()
            }
            SettingsRow("Reset time shows as") {
                Picker("", selection: .constant(0)) { Text("Time remaining").tag(0) }.settingsPicker()
            }
        }
        SettingsSection("System") {
            SettingsRow("Start at login") {
                Toggle("", isOn: .constant(true)).settingsSwitch()
            }
        }
    }
    .settingsPane()
}

// MARK: - Unticked sliders

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    /// This value rounded to the nearest `step` and clamped to `range`.
    func snapped(toStep step: Double, in range: ClosedRange<Double>) -> Double {
        ((self / step).rounded() * step).clamped(to: range)
    }
}

/// A slider that stores only whole steps without drawing a tick per step,
/// which a SwiftUI `Slider(step:)` does on macOS: forty or fifty ticks read
/// as a dotted band under the track.
///
/// A drag rounds each raw value to the nearest step, which stays put while
/// the pointer moves between two steps. The arrow keys and VoiceOver's
/// increment and decrement are overridden on the `NSSlider` itself to move
/// one whole step: the control's own increment is smaller than a step, and
/// rounding would swallow it.
struct UntickedSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var tint: Color?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SteppedSlider {
        let slider = SteppedSlider()
        slider.sliderType = .linear
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: SteppedSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.step = step
        if slider.doubleValue != value {
            slider.doubleValue = value
        }
        slider.trackFillColor = tint.map { NSColor($0) }
    }

    final class Coordinator: NSObject {
        var parent: UntickedSlider

        init(_ parent: UntickedSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let snapped = sender.doubleValue.snapped(
                toStep: parent.step,
                in: sender.minValue...sender.maxValue
            )
            sender.doubleValue = snapped
            if parent.value != snapped {
                parent.value = snapped
            }
        }
    }
}

/// An `NSSlider` whose keyboard and accessibility adjustments move one
/// `step` at a time.
final class SteppedSlider: NSSlider {
    var step: Double = 1

    override func moveRight(_ sender: Any?) { nudge(1) }
    override func moveUp(_ sender: Any?) { nudge(1) }
    override func moveLeft(_ sender: Any?) { nudge(-1) }
    override func moveDown(_ sender: Any?) { nudge(-1) }

    override func accessibilityPerformIncrement() -> Bool {
        nudge(1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        nudge(-1)
        return true
    }

    /// Moves one step from the current value and reports it through the
    /// slider's action, exactly as a drag would.
    func nudge(_ direction: Double) {
        guard isEnabled else { return }
        doubleValue = (doubleValue + direction * step).snapped(toStep: step, in: minValue...maxValue)
        sendAction(action, to: target)
    }
}
