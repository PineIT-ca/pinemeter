import XCTest

final class CopyableErrorPresentationTests: XCTestCase {
    func test_userFacingErrorSurfacesUseCopyableErrorText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

        let componentSource = try readSource("Pinemeter/Views/Shared/CopyableErrorText.swift", root: root)
        XCTAssertTrue(componentSource.contains(".textSelection(.enabled)"), "CopyableErrorText must make error text selectable.")
        XCTAssertTrue(componentSource.contains("NSPasteboard.general"), "CopyableErrorText must provide an explicit clipboard fallback.")

        let expectedUsages = [
            "Pinemeter/Views/MenuBar/UsagePopoverView.swift": [
                "CopyableErrorText(errorMessage",
                "CopyableErrorText(\"\\(provider): \\(message)\"",
                "providerErrorRow(provider: \"ChatGPT\", message: chatGPTErrorMessage)",
                "providerErrorRow(provider: \"Gemini\", message: geminiErrorMessage)",
            ],
            "Pinemeter/Views/Setup/SetupWizardView.swift": [
                "CopyableErrorText(errorMessage",
                "CopyableErrorText(lastFailureTitle",
            ],
            "Pinemeter/Views/Settings/SettingsView.swift": [
                "CopyableErrorText(accountsFeedback.message",
                "CopyableErrorText(lastFailureTitle",
            ],
            "Pinemeter/App/SessionKeyImportPromptCoordinator.swift": [
                "accessoryView",
                "isSelectable = true",
            ],
        ]

        for (path, snippets) in expectedUsages {
            let source = try readSource(path, root: root)
            for snippet in snippets {
                XCTAssertTrue(source.contains(snippet), "Expected \(path) to contain \(snippet)")
            }
        }
    }

    private func readSource(_ relativePath: String, root: URL) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
