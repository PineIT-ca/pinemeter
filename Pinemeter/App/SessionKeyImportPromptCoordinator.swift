import AppKit
import SweetCookieKit

/// Presents Pinemeter-owned context before macOS shows browser Safe Storage prompts.
enum SessionKeyImportPromptCoordinator {
    private static let promptLock = NSLock()

    static func install() {
        BrowserCookieKeychainPromptHandler.handler = { context in
            presentBrowserCookiePrompt(context)
        }
    }

    private static func presentBrowserCookiePrompt(_ context: BrowserCookieKeychainPromptContext) {
        let message = [
            "Pinemeter will ask macOS Keychain for \"\(context.label)\" so it can decrypt your AI browser session cookie.",
            "Click OK to continue, then allow the macOS Keychain prompt.",
        ].joined(separator: " ")

        presentAlert(
            title: "Keychain Access Required",
            message: message
        )
    }

    private static func presentAlert(title: String, message: String) {
        promptLock.lock()
        defer { promptLock.unlock() }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                showAlert(title: title, message: message)
            }
            return
        }

        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                showAlert(title: title, message: message)
            }
        }
    }

    @MainActor
    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = ""
        alert.accessoryView = selectableMessageView(message)
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    @MainActor
    private static func selectableMessageView(_ message: String) -> NSView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 54))
        textView.string = message
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 420, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        return textView
    }
}

