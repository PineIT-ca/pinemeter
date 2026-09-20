import Foundation
@testable import Pinemeter

actor SessionKeyImportServiceStub: SessionKeyImportServiceProtocol {
    let result: Result<ImportedSessionKey, Error>
    let chatGPTResult: Result<ImportedChatGPTSessionCookie, Error>
    /// Every ChatGPT cookie a scan finds. Empty means "just the one in
    /// `chatGPTResult`", which is what the single-account tests expect.
    let allChatGPTResults: [ImportedChatGPTSessionCookie]
    let repairState: CredentialState
    private(set) var requestedSources: [BrowserImportSource] = []

    init(
        result: Result<ImportedSessionKey, Error>,
        chatGPTResult: Result<ImportedChatGPTSessionCookie, Error> = .failure(SessionKeyImportError.noChatGPTSessionCookieFound),
        allChatGPTResults: [ImportedChatGPTSessionCookie] = [],
        repairState: CredentialState = CredentialState(
            identity: CredentialIdentity(provider: .claude, kind: .sessionKey),
            health: .valid
        )
    ) {
        self.result = result
        self.chatGPTResult = chatGPTResult
        self.allChatGPTResults = allChatGPTResults
        self.repairState = repairState
    }

    func importAllChatGPTSessionCookies(
        from source: BrowserImportSource
    ) async throws -> [ImportedChatGPTSessionCookie] {
        requestedSources.append(source)
        guard allChatGPTResults.isEmpty else { return allChatGPTResults }
        switch chatGPTResult {
        case .success(let imported):
            return [imported]
        case .failure(let error):
            throw error
        }
    }

    func importSessionKey() async throws -> ImportedSessionKey {
        try await importSessionKey(from: .defaultBrowser)
    }

    func importSessionKey(from source: BrowserImportSource) async throws -> ImportedSessionKey {
        requestedSources.append(source)
        switch result {
        case .success(let imported):
            return imported
        case .failure(let error):
            throw error
        }
    }

    func importChatGPTSessionCookie() async throws -> ImportedChatGPTSessionCookie {
        try await importChatGPTSessionCookie(from: .defaultBrowser)
    }

    func importChatGPTSessionCookie(from source: BrowserImportSource) async throws -> ImportedChatGPTSessionCookie {
        requestedSources.append(source)
        switch chatGPTResult {
        case .success(let imported):
            return imported
        case .failure(let error):
            throw error
        }
    }

    func repairSavedSessionKey(account: String) async -> CredentialState {
        repairState
    }
}
