import XCTest
@testable import Pinemeter

@MainActor
final class T3AppLauncherTests: XCTestCase {
    func test_pairingLocation_namesTheT3ScreenThatCreatesPairingLinks() {
        XCTAssertEqual(T3AppLauncher.pairingLocation, "Settings → Connections")
    }

    func test_bundleIdentifier_isAFixedLiteralWithNoAppendableURLParts() {
        XCTAssertEqual(T3AppLauncher.bundleIdentifier, "com.t3tools.t3code")
        XCTAssertFalse(T3AppLauncher.bundleIdentifier.contains("://"))
        XCTAssertFalse(T3AppLauncher.bundleIdentifier.contains("?"))
        XCTAssertFalse(T3AppLauncher.bundleIdentifier.contains("#"))
    }
}
