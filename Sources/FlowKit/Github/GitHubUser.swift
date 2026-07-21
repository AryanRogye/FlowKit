//
//  GitHubUser.swift
//  FlowKit
//
//  Created by Aryan Rogye on 7/17/26.
//

import Foundation

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

        let (data, response) = try await send(request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubUser.self, from: data)
    }
}
