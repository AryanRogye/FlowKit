//
//  FlowKitProviding.swift
//  FlowKit
//
//  Created by Aryan Rogye on 7/17/26.
//

import Foundation

public enum GitHubAuthenticationError: LocalizedError, Sendable {
    case invalidResponse
    case deviceCodeExpired
    case accessDenied
    case requestFailed(code: String, description: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "GitHub returned an invalid authentication response."
        case let .requestFailed(code, description):
            "GitHub authentication failed (\(code)): \(description)"
        case .deviceCodeExpired:
            "The GitHub device code has expired."
        case .accessDenied:
            "Access was denied by GitHub."
        }
    }
}

public struct GitHubConfiguration: Sendable {
    public let clientID: String

    public init(clientID: String) {
        self.clientID = clientID
    }
}

public struct GitHubDeviceChallenge: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresIn: Duration
    public let pollingInterval: Duration
}

public enum DeviceAuthorizationState: Sendable, Equatable {
    case pending
    case authenticated(accessToken: String)
    case slowDown
    case expired
    case denied

    public var display: String {
        switch self {
        case .pending:
            "Pending"
        case .authenticated:
            "Authenticated"
        case .slowDown:
            "Slow Down"
        case .expired:
            "Expired"
        case .denied:
            "Denied"
        }
    }
}

public struct GitHubFlow: Sendable {
    private let config: GitHubConfiguration

    public init(configuration config: GitHubConfiguration) {
        self.config = config
    }
}

// MARK: - First Authentication Step
/// ```text
/// ┌─────────────────────────────┐
/// │ 1. Request device codes     │
/// │                             │
/// │ POST /login/device/code     │
/// │                             │
/// │ Send:                       │
/// │ - client_id                 │
/// │ - scope                     │
/// └──────────────┬──────────────┘
///                │
///                ▼
/// ┌─────────────────────────────┐
/// │ GitHub returns              │
/// │                             │
/// │ - device_code               │
/// │ - user_code                 │
/// │ - verification_uri          │
/// │ - expires_in                │
/// │ - interval                  │
/// └──────────────┬──────────────┘
///                │
///                ▼
/// ┌─────────────────────────────┐
/// │ 2. Show user instructions   │
/// │                             │
/// │ Display user_code           │
/// │ Open verification_uri       │
/// │                             │
/// │ User authorizes in browser  │
/// └──────────────┬──────────────┘
/// ```
extension GitHubFlow {
    private struct DeviceCodeResponse: Decodable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURI: URL
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    public func authenticate(
        scopes: [String] = []
    ) async throws -> GitHubDeviceChallenge {
        let response = try await sendAuthenticationRequest(scopes: scopes)
        return .init(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURL: response.verificationURI,
            expiresIn: .seconds(response.expiresIn),
            pollingInterval: .seconds(response.interval)
        )
    }

    private func sendAuthenticationRequest(
        scopes: [String]
    ) async throws -> DeviceCodeResponse {
        guard let url = URL(string: "https://github.com/login/device/code") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )

        var components = URLComponents()
        var queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID)
        ]
        if !scopes.isEmpty {
            queryItems.append(
                URLQueryItem(name: "scope", value: scopes.joined(separator: " "))
            )
        }
        components.queryItems = queryItems

        request.httpBody = components
            .percentEncodedQuery?
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(
            DeviceCodeResponse.self,
            from: data
        )
    }
}
///                │
///                ▼
// MARK: - Check Authentication
/// ```swift
/// ┌─────────────────────────────┐
/// │ 3. Poll for access token    │◄──────────────┐
/// │                             │               │
/// │ POST /login/oauth/access_token              │
/// │                             │               │
/// │ Send:                       │               │
/// │ - client_id                 │               │
/// │ - device_code               │               │
/// │ - grant_type                │               │
/// └──────────────┬──────────────┘               │
///                │                              │
///                ▼                              │
///        ┌───────────────┐                      │
///        │ Response type │                      │
///        └───────┬───────┘                      │
///                │                              │
///        ┌───────┼──────────────┐               │
///        ▼       ▼              ▼               │
/// authorization  access_token   terminal error  │
/// _pending       returned       expired/denied  │
///        │       │              │               │
///        │       ▼              ▼               │
///        │    SUCCESS         STOP              │
///        │                                      │
///        └──── wait interval seconds ───────────┘
/// ```
extension GitHubFlow {
    private struct IsAuthenticatedResponse: Decodable {
        let accessToken: String?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case errorDescription = "error_description"
        }
    }

    /// Function polls authentication
    public func waitForAuthentication(
        challenge: GitHubDeviceChallenge
    ) async throws -> String {
        var interval = challenge.pollingInterval

        while !Task.isCancelled {
            try await Task.sleep(for: interval)

            let state = try await sendIsAuthenticatedRequest(
                with: challenge.deviceCode
            )

            switch state {
            case .pending:
                continue

            case .slowDown:
                interval += .seconds(5)

            case .authenticated(let accessToken):
                return accessToken

            case .expired:
                throw GitHubAuthenticationError.deviceCodeExpired

            case .denied:
                throw GitHubAuthenticationError.accessDenied
            }
        }

        throw CancellationError()
    }

    private func sendIsAuthenticatedRequest(
        with deviceCode: String
    ) async throws -> DeviceAuthorizationState {

        guard let url = URL(string: "https://github.com/login/oauth/access_token") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "device_code", value: deviceCode),
            URLQueryItem(
                name: "grant_type",
                value: "urn:ietf:params:oauth:grant-type:device_code"
            ),
        ]
        request.httpBody = components
            .percentEncodedQuery?
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let result = try JSONDecoder().decode(IsAuthenticatedResponse.self, from: data)

        if let accessToken = result.accessToken, !accessToken.isEmpty {
            return .authenticated(accessToken: accessToken)
        }

        switch result.error {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown
        case "expired_token":
            return .expired
        case "access_denied":
            return .denied
        case let errorCode?:
            throw GitHubAuthenticationError.requestFailed(
                code: errorCode,
                description: result.errorDescription ?? "Unknown GitHub error"
            )
        case nil:
            throw GitHubAuthenticationError.invalidResponse
        }
    }
}


// MARK: - Get User
public struct GitHubUser: Decodable, Sendable, Identifiable {
    public let login: String
    public let id: Int64
    public let nodeID: String
    public let avatarURL: URL
    public let gravatarID: String?
    public let apiURL: URL
    public let htmlURL: URL
    public let followersURL: URL
    public let followingURLTemplate: String
    public let gistsURLTemplate: String
    public let starredURLTemplate: String
    public let subscriptionsURL: URL
    public let organizationsURL: URL
    public let reposURL: URL
    public let eventsURLTemplate: String
    public let receivedEventsURL: URL
    public let type: String
    public let userViewType: String?
    public let siteAdmin: Bool
    public let name: String?
    public let company: String?
    public let blog: String?
    public let location: String?
    public let email: String?
    public let hireable: Bool?
    public let bio: String?
    public let twitterUsername: String?
    public let notificationEmail: String?
    public let publicRepos: Int
    public let publicGists: Int
    public let followers: Int
    public let following: Int
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case login
        case id
        case nodeID = "node_id"
        case avatarURL = "avatar_url"
        case gravatarID = "gravatar_id"
        case apiURL = "url"
        case htmlURL = "html_url"
        case followersURL = "followers_url"
        case followingURLTemplate = "following_url"
        case gistsURLTemplate = "gists_url"
        case starredURLTemplate = "starred_url"
        case subscriptionsURL = "subscriptions_url"
        case organizationsURL = "organizations_url"
        case reposURL = "repos_url"
        case eventsURLTemplate = "events_url"
        case receivedEventsURL = "received_events_url"
        case type
        case userViewType = "user_view_type"
        case siteAdmin = "site_admin"
        case name
        case company
        case blog
        case location
        case email
        case hireable
        case bio
        case twitterUsername = "twitter_username"
        case notificationEmail = "notification_email"
        case publicRepos = "public_repos"
        case publicGists = "public_gists"
        case followers
        case following
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

extension GitHubFlow {
    public func getUser(accessToken: String) async throws -> GitHubUser {
        guard let url = URL(string: "https://api.github.com/user") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )

        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "FlowKit",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubUser.self, from: data)
    }
}
