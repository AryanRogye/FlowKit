//
//  YouTubeFlow.swift
//  FlowKit
//

import Foundation

public struct YouTubeConfiguration: Sendable {
    /// Public identifier for the consuming app's Google iOS OAuth client.
    public let clientID: String

    /// Callback URI registered for that OAuth client in Google Cloud.
    public let redirectURI: URL

    public init(clientID: String, redirectURI: URL) {
        self.clientID = clientID
        self.redirectURI = redirectURI
    }
}

public struct YouTubeFlow: Sendable {
    // Production uses URLSession and Task.sleep. Internal injection keeps OAuth,
    // upload recovery, and timing tests deterministic and credential-free.
    let config: YouTubeConfiguration
    let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let sleep: @Sendable (Duration) async throws -> Void
    let uploadChunkSize: Int

    public init(configuration config: YouTubeConfiguration) {
        self.config = config
        self.send = { request in
            try await URLSession.shared.data(for: request)
        }
        self.sleep = { duration in
            try await Task.sleep(for: duration)
        }
        self.uploadChunkSize = 8 * 1024 * 1024
    }

    init(
        configuration config: YouTubeConfiguration,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in },
        uploadChunkSize: Int = 8 * 1024 * 1024
    ) {
        self.config = config
        self.send = send
        self.sleep = sleep
        self.uploadChunkSize = uploadChunkSize
    }
}
