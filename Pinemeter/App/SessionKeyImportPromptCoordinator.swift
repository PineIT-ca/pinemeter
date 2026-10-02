import AppKit
import SweetCookieKit

/// Presents Pinemeter-owned context before macOS shows browser Safe Storage prompts.
enum SessionKeyImportPromptCoordinator {
    static func install() {
        BrowserCookieKeychainPromptHandler.handler = { context in
            presentBrowserCookiePrompt(context)
        }
    }

    /// Per-provider actionable login prompt (D-03): names the site(s), which
    /// routes depend on the account, and the real recheck window the
    /// recovery watch runs, with an "Open <site>" button per provider.
    static func presentBrowserLoginRequired(providers: [CredentialProvider]) {
        let copy = BrowserLoginPromptCopy(providers: providers)
        presentActionableAlert(
            title: copy.title,
            message: copy.message,
            signInButtons: copy.signInButtons,
            dismissButtonTitle: copy.dismissButtonTitle
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
        present { showAlert(title: title, message: message) }
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

    /// Same XCTest-guard/main-thread handling as `presentAlert`, but with one
    /// button per sign-in site plus a dismiss button, and a response that
    /// opens the chosen site instead of just dismissing.
    private static func presentActionableAlert(
        title: String,
        message: String,
        signInButtons: [BrowserSignInButton],
        dismissButtonTitle: String
    ) {
        guard !isRunningTests else { return }
        present {
            showActionableAlert(
                title: title, message: message,
                signInButtons: signInButtons, dismissButtonTitle: dismissButtonTitle
            )
        }
    }

    /// Routes a presentation attempt to the main thread and gates it through
    /// `beginPresentingIfIdle`, replacing the `NSLock` this coordinator used
    /// to hold across `DispatchQueue.main.sync`.
    ///
    /// That lock was an ABBA deadlock waiting to happen: a background
    /// Keychain-context prompt (`presentBrowserCookiePrompt`, called from
    /// SweetCookieKit's own background queue) would acquire the lock, then
    /// block inside `DispatchQueue.main.sync` waiting for the main thread.
    /// While that call's modal pumps the main run loop, main-thread work
    /// queued elsewhere (a Task resuming on `MainActor`, a notification
    /// delivered on the main queue -- e.g. the degraded-pick alert's
    /// "Reconnect" action failing and calling back into this coordinator)
    /// can still run. If that reentrant call then blocked on the SAME lock,
    /// the main thread would never finish the first modal, so the
    /// background thread's `DispatchQueue.main.sync` would never return,
    /// so the lock would never be released -- neither side can ever
    /// progress (pinemeter-private review, quick task 261001-ckk).
    ///
    /// The fix removes the cross-thread lock entirely. `beginPresentingIfIdle`
    /// / `endPresenting` are plain `@MainActor` state, so they are only ever
    /// read or written from the main thread -- directly for a main-thread
    /// caller, or from inside the `DispatchQueue.main.sync` block for a
    /// background caller. Nothing is ever held across a thread hop, so there
    /// is nothing left to deadlock on. A presentation attempt that finds one
    /// already showing is simply dropped rather than queued or blocked: the
    /// prompt already on screen already carries the operator-facing remedy.
    private static func present(onMainThread: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard beginPresentingIfIdle() else { return }
                defer { endPresenting() }
                onMainThread()
            }
            return
        }

        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                guard beginPresentingIfIdle() else { return }
                defer { endPresenting() }
                onMainThread()
            }
        }
    }

    /// Whether anything presented through this coordinator is currently on
    /// screen. Main-actor-isolated so every read and write happens on the
    /// main thread, by construction -- see `present(onMainThread:)`.
    @MainActor private static var isPresenting = false

    /// Begins a presentation if nothing else is showing, atomically with the
    /// check (both happen on the main thread with no intervening suspension
    /// point). Internal, not private, and free of AppKit so a test can drive
    /// the whole single-prompt-at-a-time policy without opening a real modal.
    @MainActor
    static func beginPresentingIfIdle() -> Bool {
        guard !isPresenting else { return false }
        isPresenting = true
        return true
    }

    @MainActor
    static func endPresenting() {
        isPresenting = false
    }

    @MainActor
    private static func showActionableAlert(
        title: String,
        message: String,
        signInButtons: [BrowserSignInButton],
        dismissButtonTitle: String
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = ""
        alert.accessoryView = selectableMessageView(message)
        for button in signInButtons {
            alert.addButton(withTitle: button.title)
        }
        alert.addButton(withTitle: dismissButtonTitle)

        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0, Int(index) < signInButtons.count else { return }
        NSWorkspace.shared.open(signInButtons[Int(index)].url)
    }

    @MainActor
    private static func selectableMessageView(_ message: String) -> NSView {
        let width: CGFloat = 420
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        textView.string = message
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        // The fixed 54 pt starting height clips any message longer than
        // about two lines -- routine for the longer D-03 login prompts.
        // Force layout, then read the laid-out text's real height from the
        // layout manager so both the short keychain prompt and the longer
        // login prompt render in full rather than clipping invisibly inside
        // a non-scrolling text view.
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            textView.frame = NSRect(x: 0, y: 0, width: width, height: max(54, ceil(usedHeight)))
        }
        return textView
    }
}
