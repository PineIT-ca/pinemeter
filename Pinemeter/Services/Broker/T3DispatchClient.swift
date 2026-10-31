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
    struct Option: Codable, Equatable, Sendable {
        let id: String
        let value: String
    }

    let instanceId: String
    let model: String
    let options: [Option]

    init(instanceId: String, model: String, options: [Option] = []) {
        self.instanceId = instanceId
        self.model = model
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case instanceId, model, options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try container.decode(String.self, forKey: .instanceId)
        model = try container.decode(String.self, forKey: .model)
        options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
    }
}

struct T3Project: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let workspaceRoot: String
    let defaultModelSelection: T3ModelSelection?
    let deletedAt: String?

    private struct DefaultModelIdentity: Decodable {
        let instanceId: String
        let model: String
    }

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
        // Project options can contain provider-specific Boolean values. They
        // are metadata only; dispatch always uses the broker's own options.
        defaultModelSelection = try container.decodeIfPresent(
            DefaultModelIdentity.self,
            forKey: .defaultModelSelection
        ).map { T3ModelSelection(instanceId: $0.instanceId, model: $0.model) }
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

/// Protocol-v2 commands: create the thread before dispatching its message.
/// The message inherits the thread's runtime and interaction modes.
struct T3DispatchCommand: Encodable, Equatable, Sendable {
    let type = "message.dispatch"
    let commandId: String
    let threadId: String
    let message: Message
    let modelSelection: T3ModelSelection
    let threadCreate: ThreadCreate

    private enum CodingKeys: String, CodingKey {
        case type, commandId, threadId, messageId, text, attachments
        case modelSelection, createdBy, creationSource, dispatchMode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(commandId, forKey: .commandId)
        try container.encode(threadId, forKey: .threadId)
        try container.encode(message.messageId, forKey: .messageId)
        try container.encode(message.text, forKey: .text)
        try container.encode(message.attachments, forKey: .attachments)
        try container.encode(modelSelection, forKey: .modelSelection)
        try container.encode("agent", forKey: .createdBy)
        try container.encode("mcp", forKey: .creationSource)
        try container.encode(["type": "start_immediately"], forKey: .dispatchMode)
    }

    struct Message: Encodable, Equatable, Sendable {
        let messageId: String
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
        let runtimeMode: String
        let interactionMode = "default"

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
            case createdBy
            case creationSource
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
            try container.encode("agent", forKey: .createdBy)
            try container.encode("mcp", forKey: .creationSource)
        }
    }

    static func instructionCheck(
        projectID: String,
        modelSelection: T3ModelSelection,
        port: Int,
        now: Date,
        threadID: String = UUID().uuidString.lowercased(),
        fullAccess: Bool = false
    ) -> Self {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        let title = "Pinemeter instruction check — \(dateFormatter.string(from: now))"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let runtimeMode = fullAccess ? "full-access" : "approval-required"
        return Self(
            commandId: UUID().uuidString.lowercased(),
            threadId: threadID,
            message: Message(
                messageId: UUID().uuidString.lowercased(),
                text: BrokerSetupPrompt.text(port: port, origin: .pasteboard)
                    + "\n\nFor this instruction check, pass `run_id`: `\(threadID)` on every `audit` call."
            ),
            modelSelection: modelSelection,
            threadCreate: ThreadCreate(
                commandId: UUID().uuidString.lowercased(),
                threadId: threadID,
                projectId: projectID,
                title: title,
                modelSelection: modelSelection,
                runtimeMode: runtimeMode
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
    typealias WebSocketTransport = @Sendable (URLRequest, Data) async throws -> Data
    private let transport: Transport
    private let webSocketTransport: WebSocketTransport

    init(transport: @escaping Transport = { request in
        try await T3DispatchClient.defaultTransport(request)
    }, webSocketTransport: @escaping WebSocketTransport = { request, payload in
        try await T3DispatchClient.defaultWebSocketTransport(request, payload: payload)
    }) {
        self.transport = transport
        self.webSocketTransport = webSocketTransport
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
        let request = try Self.projectListRequest(origin: origin, token: token, path: "/api/projects")
        let result = try await receive(request)
        // A malformed project request is not an instruction-check command failure.
        if result.response.statusCode == 400 { throw T3DispatchClientError.invalidResponse }
        let data = try Self.classify(result.response, data: result.data)
        let envelope: ProjectEnvelope
        do {
            envelope = try JSONDecoder().decode(ProjectEnvelope.self, from: data)
        } catch {
            throw T3DispatchClientError.invalidResponse
        }
        return Array(envelope.projects.lazy.filter { $0.deletedAt == nil }.prefix(Self.maxProjectCount))
    }

    /// The thread snapshot uses orchestration:read, already requested at pairing.
    func threadFinished(origin: String, token: String, threadID: String) async throws -> Bool {
        guard T3LivenessChecker.isValidLoopbackOrigin(origin) else {
            throw T3DispatchClientError.invalidOrigin
        }
        guard !threadID.isEmpty,
              let component = threadID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw T3DispatchClientError.invalidResponse
        }
        let request = try Self.projectListRequest(
            origin: origin, token: token, path: "/api/orchestration/threads/" + component
        )
        let result = try await receive(request)
        if result.response.statusCode == 404 { return true }
        let data = try Self.classify(result.response, data: result.data)
        guard let snapshot = try? JSONDecoder().decode(ThreadSnapshot.self, from: data),
              snapshot.thread.id == threadID else { throw T3DispatchClientError.invalidResponse }
        let thread = snapshot.thread
        return thread.deletedAt != nil
            || ["completed", "interrupted", "error"].contains(thread.latestTurn?.state ?? "")
            || ["stopped", "interrupted", "error"].contains(thread.session?.status ?? "")
    }

    private struct ThreadSnapshot: Decodable {
        struct Thread: Decodable {
            struct Turn: Decodable { let state: String }
            struct Session: Decodable { let status: String }
            let id: String
            let deletedAt: String?
            let latestTurn: Turn?
            let session: Session?
        }
        let thread: Thread
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
        var ticketRequest = try Self.projectListRequest(origin: origin, token: token, path: "/api/auth/websocket-ticket")
        ticketRequest.httpMethod = "POST"
        ticketRequest.setValue("2", forHTTPHeaderField: "x-t3-orchestration-protocol")
        let ticketData = try await send(ticketRequest)
        guard let ticket = try? JSONDecoder().decode(WebSocketTicket.self, from: ticketData),
              !ticket.ticket.isEmpty else { throw T3DispatchClientError.invalidResponse }
        var components = URLComponents(string: origin + "/ws")!
        components.scheme = "ws"
        components.queryItems = [
            URLQueryItem(name: "orchestrationProtocol", value: "2"),
            URLQueryItem(name: "wsTicket", value: ticket.ticket),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Self.dispatchTimeout
        let data = try await webSocketTransport(request, JSONEncoder().encode(command))
        guard data.count <= Self.maxResponseBytes else { throw T3DispatchClientError.tooLarge }
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

    private struct WebSocketTicket: Decodable { let ticket: String }

    static func rpcRequest(payload: Data) throws -> Data {
        let command = try JSONSerialization.jsonObject(with: payload)
        return try JSONSerialization.data(withJSONObject: [
            "_tag": "Request", "id": "1", "tag": "orchestration.dispatchCommand",
            "payload": command, "headers": [],
        ])
    }

    /// Ignore unrelated frames; never expose provider error bodies or ticket URLs.
    static func rpcResult(frame: Data) throws -> Data? {
        guard frame.count <= maxResponseBytes else { throw T3DispatchClientError.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            throw T3DispatchClientError.invalidResponse
        }
        if root["_tag"] as? String == "Defect" { throw T3DispatchClientError.invalidResponse }
        guard root["_tag"] as? String == "Exit", root["requestId"] as? String == "1" else { return nil }
        guard let exit = root["exit"] as? [String: Any] else { throw T3DispatchClientError.invalidResponse }
        if exit["_tag"] as? String == "Success", let value = exit["value"] as? [String: Any] {
            return try JSONSerialization.data(withJSONObject: value)
        }
        let causes = exit["cause"] as? [[String: Any]] ?? []
        if let failure = causes.first(where: { $0["_tag"] as? String == "Fail" })?["error"] as? [String: Any],
           let scope = failure["requiredScope"] as? String {
            throw T3DispatchClientError.insufficientScope(scope)
        }
        throw T3DispatchClientError.invalidCommand
    }

    static func defaultWebSocketTransport(_ request: URLRequest, payload: Data) async throws -> Data {
        let session = URLSession(configuration: defaultSessionConfiguration(), delegate: T3RedirectRefuser(), delegateQueue: nil)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = maxResponseBytes
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    socket.resume()
                    try await socket.send(.string(String(decoding: try rpcRequest(payload: payload), as: UTF8.self)))
                    while true {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: throw T3DispatchClientError.invalidResponse
                        }
                        if let result = try rpcResult(frame: data) { return result }
                        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           root["_tag"] as? String == "Ping" {
                            try await socket.send(.string(#"{"_tag":"Pong"}"#))
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(dispatchTimeout))
                    socket.cancel(with: .goingAway, reason: nil)
                    throw T3DispatchClientError.transport("T3 command timed out")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
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

private class T3RedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class T3BoundedResponseLoader: T3RedirectRefuser, URLSessionDataDelegate, @unchecked Sendable {
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
