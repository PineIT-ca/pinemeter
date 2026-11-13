import Foundation

/// A single transient failure is stale data, not a disconnect (OP-1).
/// Credential `.missing` is deliberately not an input because CLI cycles reset it.
/// invalidSession is not an immediate fault: invariant D escalates it to
/// `.providerRejected` on the second consecutive rejection.
struct ChatGPTPollFailureRun: Equatable, Sendable {
    let kind: UsageTelemetryChatGPTFailure
    let consecutivePolls: Int

    static let persistentPollCount = 3

    static func recording(
        _ kind: UsageTelemetryChatGPTFailure,
        after previous: ChatGPTPollFailureRun?,
        countsTowardPersistence: Bool = true
    ) -> ChatGPTPollFailureRun {
        ChatGPTPollFailureRun(
            kind: kind,
            consecutivePolls: (previous?.consecutivePolls ?? 0) + (countsTowardPersistence ? 1 : 0)
        )
    }

    static func isFault(
        hasError: Bool,
        run: ChatGPTPollFailureRun?,
        providerRejected: Bool
    ) -> Bool {
        hasError && (providerRejected || run?.kind == .missingSession
            || (run?.consecutivePolls ?? 0) >= persistentPollCount)
    }

    static func isRetryable(_ kind: UsageTelemetryChatGPTFailure?) -> Bool {
        kind != .missingSession && kind != .invalidSession
    }
}

/// Bounded backoff after a transient poll failure; the next full refresh cycle supersedes it.
struct ChatGPTPollRetryPolicy: Equatable, Sendable {
    let delays: [Duration]

    static let standard = ChatGPTPollRetryPolicy(delays: [.seconds(30), .seconds(60), .seconds(120)])
}
