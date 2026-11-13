import Foundation

enum HealthFetchOutcome: Equatable, Sendable {
    case notModified
    case updated(body: Data, etag: String?)
}

/// Transport only. The store verifies every body against the pinned keys.
actor HealthDocumentService {
    enum FetchError: String, Error, Sendable {
        case fetchFailed = "fetch_failed"
        case tooLarge = "too_large"
    }

    static let timeoutInterval: TimeInterval = 10
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(etag: String?) async throws -> HealthFetchOutcome {
        let url = URL(string: BrokerHealthDocument.officialURL)!
        var request = URLRequest(url: url, timeoutInterval: Self.timeoutInterval)
        request.setValue("Pinemeter", forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (bytes, response) = try await session.bytes(
                for: request, delegate: HealthRedirectDelegate()
            )
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse,
                  response.url?.scheme == "https",
                  response.url?.host == url.host else { throw FetchError.fetchFailed }
            if response.statusCode == 304 { return .notModified }
            guard response.statusCode == 200 else { throw FetchError.fetchFailed }
            guard response.expectedContentLength <= Int64(BrokerHealthDocument.maxBytes) else {
                throw FetchError.tooLarge
            }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                guard body.count <= BrokerHealthDocument.maxBytes else { throw FetchError.tooLarge }
            }
            return .updated(body: body, etag: response.value(forHTTPHeaderField: "ETag"))
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.fetchFailed
        }
    }
}

private final class HealthRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let official = URL(string: BrokerHealthDocument.officialURL)!
        completionHandler(request.url?.scheme == "https" && request.url?.host == official.host ? request : nil)
    }
}
