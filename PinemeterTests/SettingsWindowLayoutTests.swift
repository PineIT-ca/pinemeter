//
//  SettingsWindowLayoutTests.swift
//  PinemeterTests
//
//  The Settings window is one fixed width and fits the selected tab. That
//  contract lives in three places that can drift apart: the scene's
//  resizability, `SettingsView`'s fixed frame, and each tab's content
//  reporting a definite height. These tests pin all three without a pixel
//  snapshot: the fitting size of the hosted view is what the scene turns
//  into the window's size under `.windowResizability(.contentSize)`.
//

import XCTest
import SwiftUI
@testable import Pinemeter

@MainActor
final class SettingsWindowLayoutTests: XCTestCase {
    private var previousTab: Any?

    override func setUp() {
        super.setUp()
        previousTab = TestSafeDefaults.standardOrIsolated.object(forKey: SettingsView.selectedTabDefaultsKey)
    }

    override func tearDown() {
        TestSafeDefaults.standardOrIsolated.set(previousTab, forKey: SettingsView.selectedTabDefaultsKey)
        super.tearDown()
    }

    private func makeAppModel() -> AppModel {
        let appModel = AppModel(
            settingsRepository: SettingsRepositoryFake(),
            keychainRepository: KeychainRepositoryFake(),
            usageService: UsageServiceStub(fetchUsageResult: .failure(TestError(message: "not used"))),
            notificationService: NotificationServiceSpy()
        )
        DemoDataFactory.configure(appModel, for: .multiProvider)
        return appModel
    }

    private func fittingSize(for tab: SettingsView.Tab, appModel: AppModel) -> CGSize {
        SettingsView.selectTab(tab)
        let host = NSHostingView(rootView: SettingsView(appModel: appModel))
        return host.fittingSize
    }

    /// Every tab reports the one window width and a definite height, so the
    /// scene can fix the window at the tab's size.
    func test_everyTabFitsTheFixedWidthWithADefiniteHeight() {
        let appModel = makeAppModel()
        for tab in [SettingsView.Tab.general, .accounts, .notifications, .broker, .about] {
            let size = fittingSize(for: tab, appModel: appModel)
            XCTAssertEqual(size.width, SettingsLayout.windowWidth, accuracy: 0.5, "\(tab) width")
            XCTAssertGreaterThan(size.height, 200, "\(tab) must report its content height, not collapse")
            XCTAssertLessThan(size.height, 800, "\(tab) must fit a laptop display without scrolling: \(size.height)")
        }
    }

    /// The window resizes per tab only if the tab view's fitting height
    /// follows the selected tab. Broker is the shortest tab and General the
    /// tallest with demo data; if they ever report the same height the tab
    /// view has started sizing to its largest child.
    func test_fittingHeightFollowsTheSelectedTab() {
        let appModel = makeAppModel()
        let general = fittingSize(for: .general, appModel: appModel).height
        let broker = fittingSize(for: .broker, appModel: appModel).height
        XCTAssertGreaterThan(general, broker + 100, "general \(general) vs broker \(broker)")
    }

    /// Only the account grid scrolls, and only past its cap: a long account
    /// list must not grow the window past the cap plus the rows around it.
    func test_accountsGridCapsItsHeightAndScrolls() {
        let appModel = makeAppModel()
        let fewAccounts = fittingSize(for: .accounts, appModel: appModel).height

        appModel.settings.claudeAccounts = (0..<12).map { index in
            ClaudeAccount(
                id: "account-\(index)",
                label: "Account \(index)",
                organizationId: UUID(),
                keychainAccount: index == 0 ? ClaudeAccount.primaryKeychainAccount : "account-\(index)",
                profileLabel: "Chrome Profile \(index)"
            )
        }
        let manyAccounts = fittingSize(for: .accounts, appModel: appModel).height

        XCTAssertGreaterThan(manyAccounts, fewAccounts, "more cards should grow the tab up to the cap")
        // Header row, Gemini key row, pane padding and the tab bar sit
        // outside the grid; 220pt is a generous allowance for them.
        XCTAssertLessThanOrEqual(
            manyAccounts,
            SettingsView.accountGridMaxHeight + 220,
            "the grid must stop growing at \(SettingsView.accountGridMaxHeight) and scroll instead"
        )
    }

    /// The healthy and off tones render as one quiet line; a problem keeps
    /// the full strip, so a card with a problem is visibly taller and
    /// stands out from its healthy neighbours.
    func test_connectionStatusStripIsCompactForHealthyAndOff() {
        func height(_ status: ConnectionStatus) -> CGFloat {
            NSHostingView(rootView: ConnectionStatusStrip(status) { Button("Act") {} }.frame(width: 280)).fittingSize.height
        }
        let healthy = height(.forAccount(
            health: .valid, usageAge: 30, monitoringOff: false,
            error: nil, recoverySuggestion: nil, hasRepairAction: false
        ))
        let off = height(.forAccount(
            health: .valid, usageAge: 30, monitoringOff: true,
            error: nil, recoverySuggestion: nil, hasRepairAction: false
        ))
        let waiting = height(.forAccount(
            health: .unknown, usageAge: nil, monitoringOff: false,
            error: nil, recoverySuggestion: nil, hasRepairAction: false
        ))
        let failure = height(.forAccount(
            health: .expired, usageAge: nil, monitoringOff: false,
            error: "401 from provider", recoverySuggestion: nil, hasRepairAction: false
        ))
        XCTAssertLessThan(healthy, 24, "healthy is one caption line: \(healthy)")
        XCTAssertLessThan(healthy, waiting, "waiting keeps the padded strip")
        XCTAssertLessThan(off, waiting, "off is compact even with its action")
        XCTAssertLessThan(healthy, failure, "failure keeps the padded strip")
    }

    /// The scene side of the contract, read from source: the Settings
    /// scene fits its content and the Broker window opens at the size its
    /// sidebar layout was designed for.
    func test_windowScenesDeclareTheDesignedSizes() throws {
        let source = try sourceContents(relativePath: "Pinemeter/App/PinemeterApp.swift")
        let settingsScene = try XCTUnwrap(source.range(of: "Window(\"Settings\""))
        let brokerScene = try XCTUnwrap(source.range(of: "Window(\"Broker\""))
        let settingsBlock = String(source[settingsScene.lowerBound..<brokerScene.lowerBound])
        let brokerBlock = String(source[brokerScene.lowerBound...])

        XCTAssertTrue(settingsBlock.contains(".windowResizability(.contentSize)"))
        XCTAssertFalse(settingsBlock.contains(".defaultSize("), "the Settings window takes its size from the selected tab")

        XCTAssertTrue(brokerBlock.contains(".defaultSize(width: 1040, height: 780)"))
        XCTAssertTrue(brokerBlock.contains("minWidth: 900, maxWidth: .infinity, minHeight: 640"))

        let settingsView = try sourceContents(relativePath: "Pinemeter/Views/Settings/SettingsView.swift")
        XCTAssertTrue(settingsView.contains(".frame(width: SettingsLayout.windowWidth)"))
        XCTAssertFalse(settingsView.contains("minWidth: 540"), "the old resizable frame must not come back")
    }

    private func sourceContents(relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = relativePath.split(separator: "/").reduce(repositoryRoot) { url, component in
            url.appendingPathComponent(String(component))
        }
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
