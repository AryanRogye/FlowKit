//
//  GoogleDriveFlow.swift
//  FlowKit
//

import Foundation

public struct GoogleDriveConfiguration: Sendable {
    /// Public identifier for the consuming app's Google OAuth client.
    public let clientID: String

    /// Callback URI registered for that OAuth client in Google Cloud.
    public let redirectURI: URL

    public init(clientID: String, redirectURI: URL) {
        self.clientID = clientID
        self.redirectURI = redirectURI
    }
}

public struct GoogleDriveFlow: Sendable {
    let config: GoogleDriveConfiguration
    let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let sleep: @Sendable (Duration) async throws -> Void
    let uploadChunkSize: Int

    public init(configuration config: GoogleDriveConfiguration) {
        self.config = config
        self.send = { try await URLSession.shared.data(for: $0) }
        self.sleep = { try await Task.sleep(for: $0) }
        self.uploadChunkSize = 8 * 1024 * 1024
    }

    init(
        configuration config: GoogleDriveConfiguration,
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
