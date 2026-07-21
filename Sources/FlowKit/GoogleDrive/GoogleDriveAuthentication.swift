//
//  GoogleDriveAuthentication.swift
//  FlowKit
//

import CryptoKit
import Foundation

public enum GoogleDriveScope: String, Sendable {
    /// Create and access files opened with or created by this app.
    case file = "https://www.googleapis.com/auth/drive.file"
    /// Read and write the app-specific data folder.
    case appData = "https://www.googleapis.com/auth/drive.appdata"
    /// Read all files in the user's Drive.
    case readOnly = "https://www.googleapis.com/auth/drive.readonly"
    /// Read and write all files in the user's Drive.
    case fullAccess = "https://www.googleapis.com/auth/drive"
}

public enum GoogleDriveAccessType: String, Sendable {
    case online
    case offline
}

public struct GoogleDriveAuthorizationRequest: Sendable, Equatable {
    public let authorizationURL: URL
    public let redirectURI: URL

    let state: String
    let codeVerifier: String
}

public struct GoogleDriveToken: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let scope: String?
    public let expiresIn: Duration
}

public enum GoogleDriveAuthenticationError: LocalizedError, Sendable, Equatable {
    case invalidAuthorizationURL
    case missingScopes
    case invalidCallback
    case stateMismatch
    case accessDenied(description: String?)
    case provider(code: String, description: String?)
    case invalidTokenResponse

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL: "Could not construct the Google Drive authorization URL."
        case .missingScopes: "At least one Google Drive authorization scope is required."
        case .invalidCallback: "Google returned an invalid authorization callback."
        case .stateMismatch: "The Google Drive authorization callback did not match the request."
        case .accessDenied(let description): description ?? "The user denied Google Drive access."
        case let .provider(code, description): description ?? "Google Drive authorization failed (\(code))."
        case .invalidTokenResponse: "Google returned an invalid token response."
        }
    }
}

extension GoogleDriveFlow {
    /// Creates an installed-app OAuth request with PKCE and callback state.
    /// The consuming app presents the URL in a secure system browser.
    public func makeAuthorizationRequest(
        scopes: [GoogleDriveScope],
        accessType: GoogleDriveAccessType = .online
    ) throws -> GoogleDriveAuthorizationRequest {
        guard !scopes.isEmpty else { throw GoogleDriveAuthenticationError.missingScopes }

        let verifier = Self.randomBase64URLString(byteCount: 32)
        let state = Self.randomBase64URLString(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).driveBase64URLEncodedString()
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.map(\.rawValue).joined(separator: " ")),
            .init(name: "access_type", value: accessType.rawValue),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        guard let url = components?.url else {
            throw GoogleDriveAuthenticationError.invalidAuthorizationURL
        }
        return .init(authorizationURL: url, redirectURI: config.redirectURI, state: state, codeVerifier: verifier)
    }

    public func exchangeAuthorizationCallback(
        _ callbackURL: URL,
        for authorizationRequest: GoogleDriveAuthorizationRequest
    ) async throws -> GoogleDriveToken {
        guard callbackURL.scheme == authorizationRequest.redirectURI.scheme,
              callbackURL.host == authorizationRequest.redirectURI.host,
              callbackURL.path == authorizationRequest.redirectURI.path,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw GoogleDriveAuthenticationError.invalidCallback
        }
        let values = components.queryItems?.reduce(into: [String: String]()) {
            $0[$1.name] = $1.value ?? ""
        } ?? [:]
        guard values["state"] == authorizationRequest.state else {
            throw GoogleDriveAuthenticationError.stateMismatch
        }
        if let error = values["error"] {
            if error == "access_denied" {
                throw GoogleDriveAuthenticationError.accessDenied(description: values["error_description"])
            }
            throw GoogleDriveAuthenticationError.provider(code: error, description: values["error_description"])
        }
        guard let code = values["code"], !code.isEmpty else {
            throw GoogleDriveAuthenticationError.invalidCallback
        }
        return try await requestToken(form: [
            "client_id": config.clientID,
            "code": code,
            "code_verifier": authorizationRequest.codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI.absoluteString,
        ])
    }

    /// Persistent storage of the user-owned refresh token remains the app's responsibility.
    public func refreshAccessToken(_ refreshToken: String) async throws -> GoogleDriveToken {
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

    private func requestToken(form: [String: String]) async throws -> GoogleDriveToken {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form.formEncodedData

        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else {
            throw GoogleDriveAuthenticationError.invalidTokenResponse
        }
        let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard (200...299).contains(response.statusCode) else {
            throw GoogleDriveAuthenticationError.provider(
                code: decoded?.error ?? "http_\(response.statusCode)",
                description: decoded?.errorDescription
            )
        }
        guard let decoded, let accessToken = decoded.accessToken, !accessToken.isEmpty,
              let expiresIn = decoded.expiresIn, let tokenType = decoded.tokenType else {
            throw GoogleDriveAuthenticationError.invalidTokenResponse
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
        return Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            .driveBase64URLEncodedString()
    }
}

private extension Data {
    func driveBase64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
