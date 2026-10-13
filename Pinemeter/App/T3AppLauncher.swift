import AppKit
import Foundation

/// Brings T3 forward so the user can create a pairing link.
///
/// T3 has no deep link to its pairing screen: its only `open-url` handler is
/// the sign-in callback, and it ignores any other `t3code://` URL without
/// activating a window. So this opens the application itself, and the card's
/// copy names the screen (Settings → Connections).
@MainActor
enum T3AppLauncher {
    static let bundleIdentifier = "com.t3tools.t3code"
    nonisolated static let pairingLocation = "Settings → Connections"

    static func open(workspace: NSWorkspace = .shared) {
        guard let applicationURL = workspace.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: applicationURL, configuration: configuration)
    }
}
