//
//  YouTubeAuthentication.swift
//  FlowKit
//

import CryptoKit
import Foundation

public enum YouTubeScope: String, Sendable {
    case upload = "https://www.googleapis.com/auth/youtube.upload"
}

public enum YouTubeAccessType: String, Sendable {
    case online
    case offline
}

public struct YouTubeAuthorizationRequest: Sendable, Equatable {
    public let authorizationURL: URL
    public let redirectURI: URL

    let state: String
    let codeVerifier: String
}

public struct YouTubeToken: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let scope: String?
    public let expiresIn: Duration
}

public enum YouTubeAuthenticationError: LocalizedError, Sendable, Equatable {
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
            "Could not construct the YouTube authorization URL."
        case .missingScopes:
            "At least one YouTube authorization scope is required."
        case .invalidCallback:
            "Google returned an invalid authorization callback."
        case .stateMismatch:
            "The YouTube authorization callback did not match the request."
        case .accessDenied(let description):
            description ?? "The user denied YouTube access."
        case let .provider(code, description):
            description ?? "YouTube authorization failed (\(code))."
        case .invalidTokenResponse:
            "Google returned an invalid token response."
        }
    }
}

// MARK: - Create Authorization Request
/// ```text
/// ┌──────────────────────────────┐
/// │ 1. Prepare OAuth request     │
/// │                              │
/// │ Generate:                    │
/// │ - PKCE verifier + challenge  │
/// │ - random callback state      │
/// │                              │
/// │ Include developer-supplied:  │
/// │ - iOS OAuth client ID        │
/// │ - registered redirect URI    │
/// │ - explicitly chosen scopes   │
/// └───────────────┬──────────────┘
///                 │
///                 ▼
/// ┌──────────────────────────────┐
/// │ 2. Consuming app presents    │
/// │    authorizationURL in an    │
/// │    approved system browser   │
/// │                              │
/// │ Google authenticates the     │
/// │ user and requests consent.   │
/// └───────────────┬──────────────┘
///                 │
///                 ▼
/// ┌──────────────────────────────┐
/// │ Google redirects to the      │
/// │ configured callback URI with │
/// │ either a code or an error.    │
/// └──────────────────────────────┘
/// ```
extension YouTubeFlow {
    /// Creates the URL and temporary PKCE values needed to begin authorization.
    ///
    /// FlowKit constructs the request, while the consuming app remains
    /// responsible for presenting the URL in a secure system browser.
    public func makeAuthorizationRequest(
        scopes: [YouTubeScope],
        accessType: YouTubeAccessType = .online
    ) throws -> YouTubeAuthorizationRequest {
        guard !scopes.isEmpty else {
            throw YouTubeAuthenticationError.missingScopes
        }

        let verifier = Self.randomBase64URLString(byteCount: 32)
        let state = Self.randomBase64URLString(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.map(\.rawValue).joined(separator: " ")),
            URLQueryItem(name: "access_type", value: accessType.rawValue),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        guard let authorizationURL = components?.url else {
            throw YouTubeAuthenticationError.invalidAuthorizationURL
        }

        return YouTubeAuthorizationRequest(
            authorizationURL: authorizationURL,
            redirectURI: config.redirectURI,
            state: state,
            codeVerifier: verifier
        )
    }

    // MARK: - Exchange Authorization Callback
    /// ```text
    /// Registered callback URL
    ///          │
    ///          ▼
    /// ┌──────────────────────────────┐
    /// │ Validate:                    │
    /// │ - callback scheme/host/path  │
    /// │ - anti-forgery state         │
    /// │ - provider error or code     │
    /// └───────────────┬──────────────┘
    ///                 │ authorization code
    ///                 ▼
    /// ┌──────────────────────────────┐
    /// │ POST Google token endpoint   │
    /// │                              │
    /// │ Send:                        │
    /// │ - public client ID           │
    /// │ - authorization code         │
    /// │ - original PKCE verifier     │
    /// │ - registered redirect URI    │
    /// │                              │
    /// │ Never send a client secret.  │
    /// └───────────────┬──────────────┘
    ///                 │
    ///                 ▼
    ///      access token + optional
    ///             refresh token
    /// ```
    public func exchangeAuthorizationCallback(
        _ callbackURL: URL,
        for authorizationRequest: YouTubeAuthorizationRequest
    ) async throws -> YouTubeToken {
        guard callbackURL.scheme == authorizationRequest.redirectURI.scheme,
              callbackURL.host == authorizationRequest.redirectURI.host,
              callbackURL.path == authorizationRequest.redirectURI.path,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw YouTubeAuthenticationError.invalidCallback
        }

        let values = components.queryItems?.reduce(into: [String: String]()) {
            $0[$1.name] = $1.value ?? ""
        } ?? [:]

        guard values["state"] == authorizationRequest.state else {
            throw YouTubeAuthenticationError.stateMismatch
        }

        if let error = values["error"] {
            if error == "access_denied" {
                throw YouTubeAuthenticationError.accessDenied(
                    description: values["error_description"]
                )
            }
            throw YouTubeAuthenticationError.provider(
                code: error,
                description: values["error_description"]
            )
        }

        guard let code = values["code"], !code.isEmpty else {
            throw YouTubeAuthenticationError.invalidCallback
        }

        return try await requestToken(form: [
            "client_id": config.clientID,
            "code": code,
            "code_verifier": authorizationRequest.codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI.absoluteString,
        ])
    }

    // MARK: - Refresh Access Token
    /// Exchanges a user-owned refresh token for a new short-lived access token.
    /// Persistent token storage remains the consuming app's responsibility.
    public func refreshAccessToken(_ refreshToken: String) async throws -> YouTubeToken {
        try await requestToken(form: [
            "client_id": config.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
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

    /// Sends both authorization-code and refresh-token grants through the same
    /// decoded and error-mapped token endpoint.
    private func requestToken(form: [String: String]) async throws -> YouTubeToken {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form.formEncodedData

        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeAuthenticationError.invalidTokenResponse
        }

        let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw YouTubeAuthenticationError.provider(
                code: decoded?.error ?? "http_\(httpResponse.statusCode)",
                description: decoded?.errorDescription
            )
        }

        guard let decoded,
              let accessToken = decoded.accessToken,
              !accessToken.isEmpty,
              let expiresIn = decoded.expiresIn,
              let tokenType = decoded.tokenType else {
            throw YouTubeAuthenticationError.invalidTokenResponse
        }

        return YouTubeToken(
            accessToken: accessToken,
            refreshToken: decoded.refreshToken,
            tokenType: tokenType,
            scope: decoded.scope,
            expiresIn: .seconds(expiresIn)
        )
    }

    private static func randomBase64URLString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Dictionary where Key == String, Value == String {
    var formEncodedData: Data? {
        var components = URLComponents()
        components.queryItems = sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}
