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

    static func presentBrowserLoginRequired(providerNames: [String]) {
        presentAlert(
            title: "Browser Login Required",
            message: "Pinemeter could not restore your \(providerNames.joined(separator: " and ")) browser session. Log in again in Chrome, Safari, or Firefox. Pinemeter will rescan automatically."
        )
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

    /// Same XCTest guard the broker stores use. A modal alert raised from a
    /// unit test never gets dismissed, so the whole run hangs rather than
    /// failing -- any test that drives a credential into a failed state
    /// reaches this path unless it stubs `browserLoginPrompt`.
    private static var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    private static func presentAlert(title: String, message: String) {
        guard !isRunningTests else { return }

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
