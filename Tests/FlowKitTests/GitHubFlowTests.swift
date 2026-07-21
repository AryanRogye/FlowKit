import Foundation
import Testing
@testable import FlowKit

@Suite("GitHub flow")
struct GitHubFlowTests {
    @Test("Authentication request includes the client ID and scopes")
    func authenticationRequest() async throws {
        let transport = StubTransport(responses: [
            .success(httpResponse(
                statusCode: 200,
                json: """
                {
                  "device_code": "device-123",
                  "user_code": "ABCD-EFGH",
                  "verification_uri": "https://github.com/login/device",
                  "expires_in": 900,
                  "interval": 5
                }
                """
            )),
        ])
        let flow = makeFlow(transport: transport, clientID: "client id")

        let challenge = try await flow.authenticate(scopes: ["repo", "read:user"])

        #expect(challenge.deviceCode == "device-123")
        #expect(challenge.userCode == "ABCD-EFGH")
        #expect(challenge.verificationURL == URL(string: "https://github.com/login/device"))
        #expect(challenge.expiresIn == .seconds(900))
        #expect(challenge.pollingInterval == .seconds(5))

        let request = try #require(await transport.requests.first)
        #expect(request.url == URL(string: "https://github.com/login/device/code"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(formValues(in: request) == [
            "client_id": "client id",
            "scope": "repo read:user",
        ])
    }

    @Test("Authentication omits an empty scope")
    func authenticationWithoutScopes() async throws {
        let transport = StubTransport(responses: [
            .success(httpResponse(
                statusCode: 200,
                json: """
                {
                  "device_code": "device",
                  "user_code": "code",
                  "verification_uri": "https://github.com/login/device",
                  "expires_in": 1,
                  "interval": 1
                }
                """
            )),
        ])

        _ = try await makeFlow(transport: transport).authenticate()

        let request = try #require(await transport.requests.first)
        #expect(formValues(in: request) == ["client_id": "test-client"])
    }

    @Test("Authentication rejects non-success HTTP responses")
    func authenticationHTTPError() async {
        let transport = StubTransport(responses: [
            .success(httpResponse(statusCode: 500, json: "{}")),
        ])

        await #expect(throws: URLError.self) {
            _ = try await makeFlow(transport: transport).authenticate()
        }
    }

    @Test("Authentication rejects malformed JSON")
    func authenticationMalformedResponse() async {
        let transport = StubTransport(responses: [
            .success(httpResponse(statusCode: 200, json: "{}")),
        ])

        await #expect(throws: DecodingError.self) {
            _ = try await makeFlow(transport: transport).authenticate()
        }
    }

    @Test("Polling continues while pending and returns the access token")
    func pendingThenAuthenticated() async throws {
        let transport = StubTransport(responses: [
            .success(httpResponse(statusCode: 200, json: #"{"error":"authorization_pending"}"#)),
            .success(httpResponse(statusCode: 200, json: #"{"access_token":"secret-token"}"#)),
        ])
        let sleepRecorder = SleepRecorder()
        let flow = GitHubFlow(
            configuration: .init(clientID: "test-client"),
            send: { request in try await transport.send(request) },
            sleep: { duration in await sleepRecorder.record(duration) }
        )

        let token = try await flow.waitForAuthentication(challenge: challenge(interval: 2))

        #expect(token == "secret-token")
        #expect(await sleepRecorder.durations == [.seconds(2), .seconds(2)])
        #expect(await transport.requests.count == 2)

        let request = try #require(await transport.requests.first)
        #expect(request.url == URL(string: "https://github.com/login/oauth/access_token"))
        #expect(request.httpMethod == "POST")
        #expect(formValues(in: request) == [
            "client_id": "test-client",
            "device_code": "device-code",
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
    }

    @Test("Slow-down increases subsequent polling intervals")
    func slowDown() async throws {
        let transport = StubTransport(responses: [
            .success(httpResponse(statusCode: 200, json: #"{"error":"slow_down"}"#)),
            .success(httpResponse(statusCode: 200, json: #"{"access_token":"token"}"#)),
        ])
        let sleepRecorder = SleepRecorder()
        let flow = GitHubFlow(
            configuration: .init(clientID: "test-client"),
            send: { request in try await transport.send(request) },
            sleep: { duration in await sleepRecorder.record(duration) }
        )

        _ = try await flow.waitForAuthentication(challenge: challenge(interval: 3))

        #expect(await sleepRecorder.durations == [.seconds(3), .seconds(8)])
    }

    @Test(
        "Terminal polling errors map to public errors",
        arguments: [
            ("expired_token", "The GitHub device code has expired."),
            ("access_denied", "Access was denied by GitHub."),
        ]
    )
    func terminalPollingErrors(errorCode: String, expectedDescription: String) async {
        let transport = StubTransport(responses: [
            .success(httpResponse(statusCode: 200, json: #"{"error":"\#(errorCode)"}"#)),
        ])

        do {
            _ = try await makeFlow(transport: transport)
                .waitForAuthentication(challenge: challenge())
            Issue.record("Expected polling to throw")
        } catch let error as GitHubAuthenticationError {
            #expect(error.errorDescription == expectedDescription)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Unknown polling errors retain GitHub's details")
    func unknownPollingError() async {
        let transport = StubTransport(responses: [
            .success(httpResponse(
                statusCode: 200,
                json: #"{"error":"incorrect_client_credentials","error_description":"Bad credentials"}"#
            )),
        ])

        do {
            _ = try await makeFlow(transport: transport)
                .waitForAuthentication(challenge: challenge())
            Issue.record("Expected polling to throw")
        } catch let error as GitHubAuthenticationError {
            #expect(error.errorDescription == "GitHub authentication failed (incorrect_client_credentials): Bad credentials")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Polling rejects a response with neither token nor error")
    func invalidPollingResponse() async {
        let transport = StubTransport(responses: [
            .success(httpResponse(statusCode: 200, json: "{}")),
        ])

        do {
            _ = try await makeFlow(transport: transport)
                .waitForAuthentication(challenge: challenge())
            Issue.record("Expected polling to throw")
        } catch let error as GitHubAuthenticationError {
            #expect(error.errorDescription == "GitHub returned an invalid authentication response.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Get user sends GitHub headers and decodes the profile")
    func getUser() async throws {
        let transport = StubTransport(responses: [
            .success(httpResponse(statusCode: 200, json: userJSON)),
        ])

        let user = try await makeFlow(transport: transport).getUser(accessToken: "access-token")

        #expect(user.login == "octocat")
        #expect(user.id == 1)
        #expect(user.nodeID == "MDQ6VXNlcjE=")
        #expect(user.name == "The Octocat")
        #expect(user.email == nil)
        #expect(user.publicRepos == 8)
        #expect(user.siteAdmin == false)
        #expect(user.createdAt == ISO8601DateFormatter().date(from: "2011-01-25T18:44:36Z"))

        let request = try #require(await transport.requests.first)
        #expect(request.url == URL(string: "https://api.github.com/user"))
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "FlowKit")
    }

    @Test("Get user rejects non-success HTTP responses")
    func getUserHTTPError() async {
        let transport = StubTransport(responses: [
            .success(httpResponse(statusCode: 401, json: #"{"message":"Bad credentials"}"#)),
        ])

        await #expect(throws: URLError.self) {
            _ = try await makeFlow(transport: transport).getUser(accessToken: "bad-token")
        }
    }

    @Test(
        "Authorization states have user-facing labels",
        arguments: [
            (DeviceAuthorizationState.pending, "Pending"),
            (.authenticated(accessToken: "token"), "Authenticated"),
            (.slowDown, "Slow Down"),
            (.expired, "Expired"),
            (.denied, "Denied"),
        ]
    )
    func stateDisplay(state: DeviceAuthorizationState, expected: String) {
        #expect(state.display == expected)
    }
}

private actor StubTransport {
    private var responses: [Result<(Data, URLResponse), any Error>]
    private(set) var requests: [URLRequest] = []

    init(responses: [Result<(Data, URLResponse), any Error>]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw StubError.missingResponse
        }
        return try responses.removeFirst().get()
    }
}

private actor SleepRecorder {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

private enum StubError: Error {
    case missingResponse
}

private func makeFlow(
    transport: StubTransport,
    clientID: String = "test-client"
) -> GitHubFlow {
    GitHubFlow(
        configuration: .init(clientID: clientID),
        send: { request in try await transport.send(request) }
    )
}

private func challenge(interval: Int = 0) -> GitHubDeviceChallenge {
    GitHubDeviceChallenge(
        deviceCode: "device-code",
        userCode: "user-code",
        verificationURL: URL(string: "https://github.com/login/device")!,
        expiresIn: .seconds(900),
        pollingInterval: .seconds(interval)
    )
}

private func httpResponse(statusCode: Int, json: String) -> (Data, URLResponse) {
    let url = URL(string: "https://github.test")!
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
    return (Data(json.utf8), response)
}

private func formValues(in request: URLRequest) -> [String: String] {
    guard let body = request.httpBody,
          let encoded = String(data: body, encoding: .utf8) else {
        return [:]
    }

    var components = URLComponents()
    components.percentEncodedQuery = encoded
    return Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        }
    )
}

private let userJSON = """
{
  "login": "octocat",
  "id": 1,
  "node_id": "MDQ6VXNlcjE=",
  "avatar_url": "https://github.com/images/error/octocat_happy.gif",
  "gravatar_id": "",
  "url": "https://api.github.com/users/octocat",
  "html_url": "https://github.com/octocat",
  "followers_url": "https://api.github.com/users/octocat/followers",
  "following_url": "https://api.github.com/users/octocat/following{/other_user}",
  "gists_url": "https://api.github.com/users/octocat/gists{/gist_id}",
  "starred_url": "https://api.github.com/users/octocat/starred{/owner}{/repo}",
  "subscriptions_url": "https://api.github.com/users/octocat/subscriptions",
  "organizations_url": "https://api.github.com/users/octocat/orgs",
  "repos_url": "https://api.github.com/users/octocat/repos",
  "events_url": "https://api.github.com/users/octocat/events{/privacy}",
  "received_events_url": "https://api.github.com/users/octocat/received_events",
  "type": "User",
  "user_view_type": "public",
  "site_admin": false,
  "name": "The Octocat",
  "company": "@github",
  "blog": "https://github.blog",
  "location": "San Francisco",
  "email": null,
  "hireable": null,
  "bio": "GitHub mascot",
  "twitter_username": null,
  "notification_email": null,
  "public_repos": 8,
  "public_gists": 8,
  "followers": 100,
  "following": 9,
  "created_at": "2011-01-25T18:44:36Z",
  "updated_at": "2026-07-20T12:34:56Z"
}
"""
