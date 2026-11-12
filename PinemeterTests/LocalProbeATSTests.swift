import Foundation
import XCTest
@testable import Pinemeter

final class LocalProbeATSTests: XCTestCase {
    static let expectedATSCode = NSURLErrorAppTransportSecurityRequiresSecureConnection

    func test_reservedDomainDefaultTransportATSCode() async throws {
        try XCTSkipUnless(Bundle.main.bundleURL.pathExtension == "app", "ATS determination requires the app-hosted runner.")
        let request = URLRequest(url: URL(string: "http://gpu-a.example:11434/models")!, timeoutInterval: 2)
        do {
            _ = try await LocalModelLoadService.defaultTransport(request)
            XCTFail("Reserved domain must not serve a probe.")
        } catch {
            let error = error as NSError
            XCTAssertEqual(error.code, Self.expectedATSCode)
            XCTAssertEqual(error.domain, NSURLErrorDomain)
        }
    }
}
