//
//  EmailFlow.swift
//  FlowKit
//

import Foundation

public enum EmailConfiguration: Sendable {
    /// Gmail OAuth for IMAP access.
    ///
    /// The client ID is public application configuration. The redirect URI
    /// must be registered for the consuming app's OAuth client.
    case gmail(clientID: String, redirectURI: URL)
}

public struct EmailFlow: Sendable {
    let config: EmailConfiguration
    let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(configuration config: EmailConfiguration) {
        self.config = config
        self.send = { try await URLSession.shared.data(for: $0) }
    }

    init(
        configuration config: EmailConfiguration,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.config = config
        self.send = send
    }
}
