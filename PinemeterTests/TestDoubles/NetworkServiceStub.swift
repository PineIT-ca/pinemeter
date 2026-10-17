//
//  NetworkServiceStub.swift
//  PinemeterTests
//
//  Created by Edd on 2026-01-09.
//

import Foundation
@testable import Pinemeter

actor NetworkServiceStub: NetworkServiceProtocol {
    private let responseData: Data
    private let error: Error?
    private(set) var requestCount: Int = 0
    private(set) var lastEndpoint: String?

    init(responseData: Data, error: Error? = nil) {
        self.responseData = responseData
        self.error = error
    }

    func request<T: Decodable>(
        _ endpoint: String,
        method: HTTPMethod,
        sessionKey: String
    ) async throws -> T {
        requestCount += 1
        lastEndpoint = endpoint

        if let error {
            throw error
        }

        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: responseData)
    }
}
