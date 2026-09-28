import Foundation
import os

enum T3DispatchClientError: Error, Equatable {
    case invalidOrigin
    case unauthorized
    case insufficientScope(String)
    case invalidCommand
    case badStatus(Int)
    case tooLarge
    case transport(String)
    case dpopTokenIssued
    case unsupportedTokenType
    case invalidResponse
}

struct T3ModelSelection: Codable, Equatable, Sendable {
    let instanceId: String
    let model: String
}

struct T3Project: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let workspaceRoot: String
    let defaultModelSelection: T3ModelSelection?
    let deletedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case workspaceRoot
        case defaultModelSelection
        case deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let rawTitle = try container.decode(String.self, forKey: .title)
        title = T3InstanceDiscoveryService.sanitizedDisplayName(rawTitle) ?? "Untitled project"
        workspaceRoot = try container.decode(String.self, forKey: .workspaceRoot)
        defaultModelSelection = try container.decodeIfPresent(
            T3ModelSelection.self,
            forKey: .defaultModelSelection
        )
        deletedAt = try container.decodeIfPresent(String.self, forKey: .deletedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(workspaceRoot, forKey: .workspaceRoot)
        try container.encodeIfPresent(defaultModelSelection, forKey: .defaultModelSelection)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}

/// A `thread.turn.start` and the `thread.create` that must precede it.
///
/// T3's HTTP dispatch endpoint hands each command straight to the
/// orchestration engine, which requires the thread to exist. Only T3's own
/// websocket path expands `bootstrap.createThread` into a create, so over HTTP
/// the create is sent first as its own command and the turn carries no
/// bootstrap.
struct T3DispatchCommand: Encodable, Equatable, Sendable {
    let type = "thread.turn.start"
    let commandId: String
    let threadId: String
    let message: Message
    let modelSelection: T3ModelSelection
    let runtimeMode = "approval-required"
    let interactionMode = "default"
    let createdAt: String
    let threadCreate: ThreadCreate

    private enum CodingKeys: String, CodingKey {
        case type
        case commandId
        case threadId
        case message
        case modelSelection
        case runtimeMode
        case interactionMode
        case createdAt
    }

    struct Message: Encodable, Equatable, Sendable {
        let messageId: String
        let role = "user"
        let text: String
        let attachments: [String] = []
    }

    struct ThreadCreate: Encodable, Equatable, Sendable {
        let type = "thread.create"
        let commandId: String
        let threadId: String
        let projectId: String
        let title: String
        let modelSelection: T3ModelSelection
        let runtimeMode = "approval-required"
        let interactionMode = "default"
        let createdAt: String

        private enum CodingKeys: String, CodingKey {
            case type
            case commandId
            case threadId
            case projectId
            case title
            case modelSelection
            case runtimeMode
            case interactionMode
            case branch
            case worktreePath
            case createdAt
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(commandId, forKey: .commandId)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(projectId, forKey: .projectId)
            try container.encode(title, forKey: .title)
            try container.encode(modelSelection, forKey: .modelSelection)
            try container.encode(runtimeMode, forKey: .runtimeMode)
            try container.encode(interactionMode, forKey: .interactionMode)
            try container.encodeNil(forKey: .branch)
            try container.encodeNil(forKey: .worktreePath)
            try container.encode(createdAt, forKey: .createdAt)
        }
    }

    static func instructionCheck(
        projectID: String,
        modelSelection: T3ModelSelection,
        port: Int,
        now: Date
    ) -> Self {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let createdAt = isoFormatter.string(from: now)
        let title = "Pinemeter instruction check — \(dateFormatter.string(from: now))"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let threadID = UUID().uuidString.lowercased()
        return Self(
            commandId: UUID().uuidString.lowercased(),
            threadId: threadID,
            message: Message(
                messageId: UUID().uuidString.lowercased(),
                text: BrokerSetupPrompt.text(port: port, origin: .pasteboard)
            ),
            modelSelection: modelSelection,
            createdAt: createdAt,
            threadCreate: ThreadCreate(
                commandId: UUID().uuidString.lowercased(),
                threadId: threadID,
                projectId: projectID,
                title: title,
                modelSelection: modelSelection,
                createdAt: createdAt
            )
        )
    }
}

actor T3DispatchClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let requestTimeout: TimeInterval = 10
    static let dispatchTimeout: TimeInterval = 20
    static let maxResponseBytes = 4 * 1_048_576
    static let maxProjectCount = 100

    private static let logger = Logger(subsystem: "com.pinemeter", category: "T3DispatchClient")
    private let transport: Transport

    init(transport: @escaping Transport = { request in
        try await T3DispatchClient.defaultTransport(request)
    }) {
        self.transport = transport
    }

    static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = dispatchTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return configuration
    }

    func exchangePairingCredential(
        origin: String,
        credential: String,
        clientLabel: String
    ) async throws -> T3DispatchCredential {
        guard T3LivenessChecker.isValidLoopbackOrigin(origin) else {
            throw T3DispatchClientError.invalidOrigin
        }
        let request = try Self.tokenExchangeRequest(
            origin: origin,
            credential: credential,
            clientLabel: clientLabel
        )
        let data = try await send(request)
        let result: TokenExchangeResponse
        do {
            result = try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
        } catch {
            throw T3DispatchClientError.invalidResponse
        }
        if result.tokenType.caseInsensitiveCompare("DPoP") == .orderedSame {
            throw T3DispatchClientError.dpopTokenIssued
        }
        guard result.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw T3DispatchClientError.unsupportedTokenType
        }
        return T3DispatchCredential(
            accessToken: result.accessToken,
            expiresAt: Date().addingTimeInterval(result.expiresIn - 60),
            scope: result.scope
        )
    }

    func listProjects(origin: String, token: String) async throws -> [T3Project] {
        guard T3LivenessChecker.isValidLoopbackOrigin(origin) else {
            throw T3DispatchClientError.invalidOrigin
        }
        var request = try Self.projectListRequest(
            origin: origin,
            token: token,
            path: "/api/orchestration/shell"
        )
        var result = try await receive(request)
        if result.response.statusCode == 404 {
            request = try Self.projectListRequest(
                origin: origin,
                token: token,
                path: "/api/orchestration/snapshot"
            )
            result = try await receive(request)
        }
        let data = try Self.classify(result.response, data: result.data)
        let envelope: ProjectEnvelope
        do {
            envelope = try JSONDecoder().decode(ProjectEnvelope.self, from: data)
        } catch {
            throw T3DispatchClientError.invalidResponse
        }
        return Array(envelope.projects.lazy.filter { $0.deletedAt == nil }.prefix(Self.maxProjectCount))
    }

    func dispatch(origin: String, token: String, command: T3DispatchCommand) async throws -> Int {
        guard T3LivenessChecker.isValidLoopbackOrigin(origin) else {
            throw T3DispatchClientError.invalidOrigin
        }
        // No cleanup if the turn fails after the create: a timeout can hide a
        // turn T3 did start, and deleting the thread would end that run.
        _ = try await sendCommand(origin: origin, token: token, command: command.threadCreate)
        return try await sendCommand(origin: origin, token: token, command: command)
    }

    private func sendCommand(origin: String, token: String, command: some Encodable) async throws -> Int {
        let request = try Self.dispatchRequest(origin: origin, token: token, command: command)
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(DispatchResponse.self, from: data).sequence
        } catch {
            throw T3DispatchClientError.invalidResponse
        }
    }

    static func tokenExchangeRequest(
        origin: String,
        credential: String,
        clientLabel: String
    ) throws -> URLRequest {
        guard let url = URL(string: origin + "/oauth/token") else {
            throw T3DispatchClientError.invalidOrigin
        }
        let fields = [
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("subject_token", credential),
            ("subject_token_type", "urn:t3:params:oauth:token-type:environment-bootstrap"),
            ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
            ("scope", "orchestration:read orchestration:operate"),
            ("client_label", clientLabel),
            ("client_device_type", "desktop"),
            ("client_os", "macOS"),
        ]
        let body = fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.utf8)
        return request
    }

    static func projectListRequest(origin: String, token: String, path: String) throws -> URLRequest {
        guard let url = URL(string: origin + path) else { throw T3DispatchClientError.invalidOrigin }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func dispatchRequest(
        origin: String,
        token: String,
        command: some Encodable
    ) throws -> URLRequest {
        guard let url = URL(string: origin + "/api/orchestration/dispatch") else {
            throw T3DispatchClientError.invalidOrigin
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = dispatchTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(command)
        return request
    }

    @discardableResult
    static func classify(_ response: HTTPURLResponse, data: Data) throws -> Data {
        switch response.statusCode {
        case 200..<300:
            return data
        case 400:
            throw T3DispatchClientError.invalidCommand
        case 401:
            throw T3DispatchClientError.unauthorized
        case 403:
            let rawScope = try? JSONDecoder().decode(ScopeErrorResponse.self, from: data).requiredScope
            let scope = T3InstanceDiscoveryService.sanitizedDisplayName(rawScope) ?? "unknown"
            throw T3DispatchClientError.insufficientScope(scope)
        default:
            throw T3DispatchClientError.badStatus(response.statusCode)
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let result = try await receive(request)
        return try Self.classify(result.response, data: result.data)
    }

    private func receive(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as T3DispatchClientError {
            throw error
        } catch {
            throw T3DispatchClientError.transport(error.localizedDescription)
        }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        Self.logger.info("request \(method, privacy: .public) \(path, privacy: .public) status \(response.statusCode, privacy: .public)")
        if response.statusCode == 401 { throw T3DispatchClientError.unauthorized }
        guard data.count <= Self.maxResponseBytes else { throw T3DispatchClientError.tooLarge }
        return (data, response)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?/:;")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private struct TokenExchangeResponse: Decodable {
        let accessToken: String
        let tokenType: String
        let expiresIn: TimeInterval
        let scope: String

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case scope
        }
    }

    private struct ScopeErrorResponse: Decodable {
        let requiredScope: String
    }

    private struct ProjectEnvelope: Decodable {
        let projects: [T3Project]

        private enum CodingKeys: String, CodingKey {
            case projects
        }
    }

    private struct DispatchResponse: Decodable {
        let sequence: Int
    }

    static func defaultTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await T3BoundedResponseLoader(
            configuration: defaultSessionConfiguration(),
            maximumBytes: maxResponseBytes
        ).load(request)
    }

    static func defaultTransport(configuration: URLSessionConfiguration) -> Transport {
        return { request in
            try await T3BoundedResponseLoader(
                configuration: configuration,
                maximumBytes: maxResponseBytes
            ).load(request)
        }
    }

    func pointerOrigin() -> String? {
        T3LivenessChecker.pointerOrigin(
            at: T3LivenessChecker.defaultPointerFileURL(fileManager: .default)
        )
    }
}

private final class T3BoundedResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var isCancelled = false

    init(configuration: URLSessionConfiguration, maximumBytes: Int) {
        self.configuration = configuration
        self.maximumBytes = maximumBytes
    }

    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: queue
                )
                let task = session.dataTask(with: request)
                lock.lock()
                guard !isCancelled, !Task.isCancelled else {
                    lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.session = session
                self.task = task
                lock.unlock()
                data.reserveCapacity(min(maximumBytes, 64 * 1024))
                task.resume()
            }
        } onCancel: {
            self.cancelTask()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            fail(T3DispatchClientError.invalidResponse)
            return
        }
        guard response.expectedContentLength < 0
                || response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            fail(T3DispatchClientError.tooLarge)
            return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= maximumBytes - data.count else {
            fail(T3DispatchClientError.tooLarge)
            return
        }
        data.append(chunk)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            fail(error)
            return
        }
        guard let response else {
            fail(T3DispatchClientError.invalidResponse)
            return
        }
        finish(.success((data, response)))
    }

    private func fail(_ error: Error) {
        cancelTask()
        finish(.failure(error))
    }

    private func cancelTask() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        task = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        switch result {
        case .success(let value):
            session?.finishTasksAndInvalidate()
            continuation.resume(returning: value)
        case .failure(let error):
            session?.invalidateAndCancel()
            continuation.resume(throwing: error)
        }
    }
}
