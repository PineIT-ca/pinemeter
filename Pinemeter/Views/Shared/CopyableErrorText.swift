import SwiftUI
import AppKit

/// User-facing error text that can be selected and copied.
///
/// SwiftUI text selection is the primary affordance; the explicit copy button is
/// kept as a reliable fallback for short menu bar popovers and setup panels.
struct CopyableErrorText: View {
    let message: String
    var font: Font = .callout
    var foregroundStyle: Color = .primary
    var lineLimit: Int? = nil

    @State private var didCopy = false

    init(_ message: String, font: Font = .callout, foregroundStyle: Color = .primary, lineLimit: Int? = nil) {
        self.message = message
        self.font = font
        self.foregroundStyle = foregroundStyle
        self.lineLimit = lineLimit
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(message)
                .font(font)
                .foregroundStyle(foregroundStyle)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copyMessage()
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(didCopy ? "Copied" : "Copy error")
            .accessibilityLabel(didCopy ? "Copied error" : "Copy error")
        }
    }

    private func copyMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message, forType: .string)
        didCopy = true
    }
}
