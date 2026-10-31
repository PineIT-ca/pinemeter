import XCTest
@testable import Pinemeter

final class ChatGPTPollFailureRunTests: XCTestCase {
    func test_isFault_requiresErrorEvenWithRejectedCredentialOrPersistentRun() {
        let run = ChatGPTPollFailureRun(kind: .missingSession, consecutivePolls: 3)
        XCTAssertFalse(ChatGPTPollFailureRun.isFault(hasError: false, run: run, providerRejected: true))
        XCTAssertFalse(ChatGPTPollFailureRun.isFault(hasError: true, run: nil, providerRejected: false))
        XCTAssertTrue(ChatGPTPollFailureRun.isFault(hasError: true, run: nil, providerRejected: true))
    }

    func test_isFault_missingSessionIsImmediate_otherKindsNeedThreePolls() {
        let kinds: [UsageTelemetryChatGPTFailure] = [
            .missingSession, .invalidSession, .invalidResponse, .httpError,
            .transport, .secureStorage, .unknown,
        ]
        for kind in kinds {
            for count in 1...3 {
                XCTAssertEqual(
                    ChatGPTPollFailureRun.isFault(
                        hasError: true,
                        run: ChatGPTPollFailureRun(kind: kind, consecutivePolls: count),
                        providerRejected: false
                    ),
                    kind == .missingSession || count == 3,
                    "\(kind) at \(count) polls"
                )
            }
        }
    }

    func test_recording_countsRegularPollsAndReplacesKindWithoutResetting() {
        let first = ChatGPTPollFailureRun.recording(.transport, after: nil)
        XCTAssertEqual(first, ChatGPTPollFailureRun(kind: .transport, consecutivePolls: 1))
        let second = ChatGPTPollFailureRun.recording(.httpError, after: first)
        XCTAssertEqual(second, ChatGPTPollFailureRun(kind: .httpError, consecutivePolls: 2))
        let retry = ChatGPTPollFailureRun.recording(.secureStorage, after: second, countsTowardPersistence: false)
        XCTAssertEqual(retry, ChatGPTPollFailureRun(kind: .secureStorage, consecutivePolls: 2))
        let uncountedFirst = ChatGPTPollFailureRun.recording(.unknown, after: nil, countsTowardPersistence: false)
        XCTAssertEqual(uncountedFirst.consecutivePolls, 0)
        XCTAssertEqual(ChatGPTPollFailureRun.recording(.transport, after: retry).consecutivePolls, 3)
    }

    func test_isRetryable_excludesOnlyMissingAndInvalidSession() {
        XCTAssertTrue(ChatGPTPollFailureRun.isRetryable(nil))
        for kind: UsageTelemetryChatGPTFailure in [
            .missingSession, .invalidSession, .invalidResponse, .httpError,
            .transport, .secureStorage, .unknown,
        ] {
            XCTAssertEqual(ChatGPTPollFailureRun.isRetryable(kind), kind != .missingSession && kind != .invalidSession)
        }
    }
}
