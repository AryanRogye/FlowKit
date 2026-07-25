//
//  EmailAuthentication.swift
//  FlowKit
//

import CryptoKit
import Foundation

public enum EmailOAuthAccessType: String, Sendable {
    case online
    case offline
}

public enum EmailScope: String, Sendable {
    /// Read, compose, send, and permanently delete Gmail mail over
    /// IMAP/POP/SMTP. Google classifies this as a restricted scope.
    case gmailMail = "https://mail.google.com/"
}

public struct EmailAuthorizationRequest: Sendable, Equatable {
    public let authorizationURL: URL
    public let redirectURI: URL

    let state: String
    let codeVerifier: String
}

public struct EmailToken: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let scope: String?
    public let expiresIn: Duration
}

public enum EmailAuthenticationError: LocalizedError, Sendable, Equatable {
    case invalidAuthorizationURL
    case missingScopes
    case invalidCallback
    case stateMismatch
    case accessDenied(description: String?)
    case provider(code: String, description: String?)
    case invalidTokenResponse

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL:
            "Could not construct the email authorization URL."
        case .missingScopes:
            "At least one email authorization scope is required."
        case .invalidCallback:
            "The email provider returned an invalid authorization callback."
        case .stateMismatch:
            "The email authorization callback did not match the request."
        case .accessDenied(let description):
            description ?? "The user denied email access."
        case let .provider(code, description):
            description ?? "Email authorization failed (\(code))."
        case .invalidTokenResponse:
            "The email provider returned an invalid token response."
        }
    }
}

extension EmailFlow {
    /// Creates an installed-app OAuth request for the configured email
    /// provider. Gmail IMAP requires the explicit `.gmailMail` scope; this
    /// does not use the Gmail REST API.
    public func makeAuthorizationRequest(
        scopes: [EmailScope],
        accessType: EmailOAuthAccessType = .online
    ) throws -> EmailAuthorizationRequest {
        guard !scopes.isEmpty else {
            throw EmailAuthenticationError.missingScopes
        }

        let oauth = oauthConfiguration
        let verifier = Self.randomBase64URLString(byteCount: 32)
        let state = Self.randomBase64URLString(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).emailBase64URLEncodedString()

        var components = URLComponents(string: oauth.authorizationEndpoint)
        components?.queryItems = [
            .init(name: "client_id", value: oauth.clientID),
            .init(name: "redirect_uri", value: oauth.redirectURI.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.map(\.rawValue).joined(separator: " ")),
            .init(name: "access_type", value: accessType.rawValue),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]

        guard let authorizationURL = components?.url else {
            throw EmailAuthenticationError.invalidAuthorizationURL
        }

        return .init(
            authorizationURL: authorizationURL,
            redirectURI: oauth.redirectURI,
            state: state,
            codeVerifier: verifier
        )
    }

    public func exchangeAuthorizationCallback(
        _ callbackURL: URL,
        for authorizationRequest: EmailAuthorizationRequest
    ) async throws -> EmailToken {
        guard callbackURL.scheme == authorizationRequest.redirectURI.scheme,
              callbackURL.host == authorizationRequest.redirectURI.host,
              callbackURL.path == authorizationRequest.redirectURI.path,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw EmailAuthenticationError.invalidCallback
        }

        let values = components.queryItems?.reduce(into: [String: String]()) {
            $0[$1.name] = $1.value ?? ""
        } ?? [:]

        guard values["state"] == authorizationRequest.state else {
            throw EmailAuthenticationError.stateMismatch
        }

        if let error = values["error"] {
            if error == "access_denied" {
                throw EmailAuthenticationError.accessDenied(
                    description: values["error_description"]
                )
            }
            throw EmailAuthenticationError.provider(
                code: error,
                description: values["error_description"]
            )
        }

        guard let code = values["code"], !code.isEmpty else {
            throw EmailAuthenticationError.invalidCallback
        }

        let oauth = oauthConfiguration
        return try await requestToken(form: [
            "client_id": oauth.clientID,
            "code": code,
            "code_verifier": authorizationRequest.codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": oauth.redirectURI.absoluteString,
        ])
    }

    /// Persistent storage of the user-owned refresh token remains the
    /// consuming app's responsibility.
    public func refreshAccessToken(_ refreshToken: String) async throws -> EmailToken {
        try await requestToken(form: [
            "client_id": oauthConfiguration.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    private struct OAuthConfiguration {
        let clientID: String
        let redirectURI: URL
        let authorizationEndpoint: String
        let tokenEndpoint: URL
    }

    private var oauthConfiguration: OAuthConfiguration {
        switch config {
        case let .gmail(clientID, redirectURI):
            .init(
                clientID: clientID,
                redirectURI: redirectURI,
                authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
            )
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let expiresIn: Int?
        let refreshToken: String?
        let scope: String?
        let tokenType: String?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
            case tokenType = "token_type"
            case error
            case errorDescription = "error_description"
        }
    }

    private func requestToken(form: [String: String]) async throws -> EmailToken {
        var request = URLRequest(url: oauthConfiguration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form.formEncodedData

        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else {
            throw EmailAuthenticationError.invalidTokenResponse
        }

        let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard (200...299).contains(response.statusCode) else {
            throw EmailAuthenticationError.provider(
                code: decoded?.error ?? "http_\(response.statusCode)",
                description: decoded?.errorDescription
            )
        }

        guard let decoded,
              let accessToken = decoded.accessToken,
              !accessToken.isEmpty,
              let expiresIn = decoded.expiresIn,
              let tokenType = decoded.tokenType else {
            throw EmailAuthenticationError.invalidTokenResponse
        }

        return .init(
            accessToken: accessToken,
            refreshToken: decoded.refreshToken,
            tokenType: tokenType,
            scope: decoded.scope,
            expiresIn: .seconds(expiresIn)
        )
    }

    private static func randomBase64URLString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<byteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }).emailBase64URLEncodedString()
    }
}

private extension Data {
    func emailBase64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
