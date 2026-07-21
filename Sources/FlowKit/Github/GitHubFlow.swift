//
//  GitHubFlow.swift
//  FlowKit
//
//  Created by Aryan Rogye on 7/17/26.
//

import Foundation

public struct GitHubConfiguration: Sendable {
    public let clientID: String

    public init(clientID: String) {
        self.clientID = clientID
    }
}

public struct GitHubFlow: Sendable {
    let config: GitHubConfiguration
    let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let sleep: @Sendable (Duration) async throws -> Void

    public init(configuration config: GitHubConfiguration) {
        self.config = config
        self.send = { request in
            try await URLSession.shared.data(for: request)
        }
        self.sleep = { duration in
            try await Task.sleep(for: duration)
        }
    }

    init(
        configuration config: GitHubConfiguration,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) {
        self.config = config
        self.send = send
        self.sleep = sleep
    }
}
