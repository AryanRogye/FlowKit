//
//  EmailIMAP.swift
//  FlowKit
//

import Foundation

public enum EmailIMAPSecurity: Sendable, Equatable {
    case tls
}

public enum EmailIMAPAuthenticationMechanism: String, Sendable, Equatable {
    case xoauth2 = "XOAUTH2"
}

/// Connection and SASL values for authenticating an IMAP client.
///
/// `initialClientResponse` contains the access token and must be handled as a
/// secret. It is intended for IMAP `AUTHENTICATE XOAUTH2`, not persistence or
/// logging.
public struct EmailIMAPAuthentication: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let security: EmailIMAPSecurity
    public let username: String
    public let mechanism: EmailIMAPAuthenticationMechanism
    public let initialClientResponse: String
}

public enum EmailIMAPAuthenticationError: LocalizedError, Sendable, Equatable {
    case invalidUsername
    case invalidAccessToken

    public var errorDescription: String? {
        switch self {
        case .invalidUsername:
            "A valid email username is required for IMAP authentication."
        case .invalidAccessToken:
            "A valid OAuth access token is required for IMAP authentication."
        }
    }
}

extension EmailFlow {
    /// Converts an OAuth access token into the SASL XOAUTH2 initial client
    /// response expected by the configured provider's IMAP server.
    public func makeIMAPAuthentication(
        username: String,
        accessToken: String
    ) throws -> EmailIMAPAuthentication {
        guard Self.isValidSASLValue(username) else {
            throw EmailIMAPAuthenticationError.invalidUsername
        }
        guard Self.isValidSASLValue(accessToken) else {
            throw EmailIMAPAuthenticationError.invalidAccessToken
        }

        switch config {
        case .gmail:
            let saslValue = "user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
            return .init(
                host: "imap.gmail.com",
                port: 993,
                security: .tls,
                username: username,
                mechanism: .xoauth2,
                initialClientResponse: Data(saslValue.utf8).base64EncodedString()
            )
        }
    }

    private static func isValidSASLValue(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || $0.value < 0x20
                || $0.value == 0x7F
        }
    }
}
