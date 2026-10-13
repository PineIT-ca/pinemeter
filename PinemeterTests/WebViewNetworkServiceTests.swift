//
//  WebViewNetworkServiceTests.swift
//  PinemeterTests
//

import XCTest
@testable import Pinemeter

final class WebViewNetworkServiceTests: XCTestCase {
    func test_terminalMainFrame403JSONIsAuthenticationFailure() {
        var state = WebViewRequestState()
        let generation = state.begin(owner: ObjectIdentifier(NSObject()))

        XCTAssertTrue(state.recordHTTPStatus(403, isForMainFrame: true, for: generation))

        guard case .authenticationFailed? = state.terminalJSONError(for: generation) else {
            return XCTFail("Expected terminal 403 JSON to fail authentication")
        }
    }

    func test_mainFrame200ReplacesIntermediate403() {
        var state = WebViewRequestState()
        let generation = state.begin(owner: ObjectIdentifier(NSObject()))

        XCTAssertTrue(state.recordHTTPStatus(403, isForMainFrame: true, for: generation))
        XCTAssertTrue(state.recordHTTPStatus(200, isForMainFrame: true, for: generation))

        XCTAssertNil(state.terminalJSONError(for: generation))
    }

    func test_subframe403CannotPoisonSuccessfulMainFrame() {
        var state = WebViewRequestState()
        let generation = state.begin(owner: ObjectIdentifier(NSObject()))

        XCTAssertFalse(state.recordHTTPStatus(403, isForMainFrame: false, for: generation))
        XCTAssertTrue(state.recordHTTPStatus(200, isForMainFrame: true, for: generation))

        XCTAssertNil(state.terminalJSONError(for: generation))
    }

    func test_requestReuseClearsStatusAndRejectsObsoleteGeneration() {
        var state = WebViewRequestState()
        let firstGeneration = state.begin(owner: ObjectIdentifier(NSObject()))
        XCTAssertTrue(state.recordHTTPStatus(403, isForMainFrame: true, for: firstGeneration))
        XCTAssertTrue(state.finish(firstGeneration))

        let secondGeneration = state.begin(owner: ObjectIdentifier(NSObject()))

        XCTAssertFalse(state.recordHTTPStatus(403, isForMainFrame: true, for: firstGeneration))
        XCTAssertNil(state.terminalJSONError(for: firstGeneration))
        XCTAssertNil(state.terminalJSONError(for: secondGeneration))
    }

    func test_terminalMainFrame401RemainsAuthenticationFailure() {
        var state = WebViewRequestState()
        let generation = state.begin(owner: ObjectIdentifier(NSObject()))

        XCTAssertTrue(state.recordHTTPStatus(401, isForMainFrame: true, for: generation))

        guard case .authenticationFailed? = state.terminalJSONError(for: generation) else {
            return XCTFail("Expected 401 to fail authentication")
        }
    }

    func test_terminalMainFrame429RemainsRateLimited() {
        var state = WebViewRequestState()
        let generation = state.begin(owner: ObjectIdentifier(NSObject()))

        XCTAssertTrue(state.recordHTTPStatus(429, isForMainFrame: true, for: generation))

        guard case .rateLimitExceeded? = state.terminalJSONError(for: generation) else {
            return XCTFail("Expected 429 to remain rate limited")
        }
    }

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
