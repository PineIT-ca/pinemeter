//
//  WebViewNetworkServiceTests.swift
//  PinemeterTests
//

import XCTest
@testable import Pinemeter

final class WebViewNetworkServiceTests: XCTestCase {
    func test_lateCallbackAfterTimeoutCannotCompleteNextRequest() {
        var state = WebViewRequestState()
        let firstWebView = NSObject()
        let secondWebView = NSObject()

        let firstGeneration = state.begin(owner: ObjectIdentifier(firstWebView))
        XCTAssertTrue(state.finish(firstGeneration)) // Timeout.

        let secondGeneration = state.begin(owner: ObjectIdentifier(secondWebView))

        XCTAssertNil(state.generation(for: ObjectIdentifier(firstWebView)))
        XCTAssertNil(state.nextChallengeRetry(for: firstGeneration))
        XCTAssertFalse(state.finish(firstGeneration))
        XCTAssertEqual(state.generation(for: ObjectIdentifier(secondWebView)), secondGeneration)
        XCTAssertEqual(state.challengeRetryCount, 0)
    }
}
