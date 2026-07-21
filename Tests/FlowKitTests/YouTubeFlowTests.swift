import Foundation
import Testing
@testable import FlowKit

@Suite("YouTube flow")
struct YouTubeFlowTests {
    @Test("Authorization uses explicit scopes, PKCE, state, and developer configuration")
    func authorizationRequest() throws {
        let flow = makeYouTubeFlow(transport: YouTubeStubTransport(responses: []))

        let request = try flow.makeAuthorizationRequest(scopes: [.upload], accessType: .offline)
        let values = queryValues(in: request.authorizationURL)

        #expect(request.authorizationURL.host == "accounts.google.com")
        #expect(values["client_id"] == "test-client")
        #expect(values["redirect_uri"] == "com.example.app:/oauth2redirect")
        #expect(values["response_type"] == "code")
        #expect(values["scope"] == YouTubeScope.upload.rawValue)
        #expect(values["access_type"] == "offline")
        #expect(values["code_challenge_method"] == "S256")
        #expect(values["code_challenge"]?.isEmpty == false)
        #expect(values["state"] == request.state)
        #expect(request.codeVerifier.count >= 43)
    }

    @Test("Authorization requires the caller to choose scopes")
    func authorizationRequiresScopes() {
        let flow = makeYouTubeFlow(transport: YouTubeStubTransport(responses: []))
        #expect(throws: YouTubeAuthenticationError.missingScopes) {
            try flow.makeAuthorizationRequest(scopes: [])
        }
    }

    @Test("Authorization callback exchanges the code without a client secret")
    func exchangeCallback() async throws {
        let transport = YouTubeStubTransport(responses: [
            .success(youtubeHTTPResponse(
                statusCode: 200,
                json: #"{"access_token":"access-token","expires_in":3600,"refresh_token":"refresh-token","scope":"https://www.googleapis.com/auth/youtube.upload","token_type":"Bearer"}"#
            )),
        ])
        let flow = makeYouTubeFlow(transport: transport)
        let authorization = try flow.makeAuthorizationRequest(scopes: [.upload], accessType: .offline)
        let callback = URL(string: "com.example.app:/oauth2redirect?code=auth-code&state=\(authorization.state)")!

        let token = try await flow.exchangeAuthorizationCallback(callback, for: authorization)

        #expect(token.accessToken == "access-token")
        #expect(token.refreshToken == "refresh-token")
        #expect(token.expiresIn == .seconds(3600))

        let request = try #require(await transport.requests.first)
        #expect(request.url == URL(string: "https://oauth2.googleapis.com/token"))
        #expect(request.httpMethod == "POST")
        let form = youtubeFormValues(in: request)
        #expect(form["client_id"] == "test-client")
        #expect(form["code"] == "auth-code")
        #expect(form["code_verifier"] == authorization.codeVerifier)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["redirect_uri"] == "com.example.app:/oauth2redirect")
        #expect(form["client_secret"] == nil)
    }

    @Test("Authorization rejects a callback with the wrong state")
    func stateMismatch() async throws {
        let flow = makeYouTubeFlow(transport: YouTubeStubTransport(responses: []))
        let authorization = try flow.makeAuthorizationRequest(scopes: [.upload])
        let callback = URL(string: "com.example.app:/oauth2redirect?code=auth-code&state=wrong")!

        await #expect(throws: YouTubeAuthenticationError.stateMismatch) {
            _ = try await flow.exchangeAuthorizationCallback(callback, for: authorization)
        }
    }

    @Test("Refresh uses the public client ID and refresh token")
    func refreshToken() async throws {
        let transport = YouTubeStubTransport(responses: [
            .success(youtubeHTTPResponse(
                statusCode: 200,
                json: #"{"access_token":"new-token","expires_in":3600,"scope":"upload","token_type":"Bearer"}"#
            )),
        ])
        let flow = makeYouTubeFlow(transport: transport)

        let token = try await flow.refreshAccessToken("refresh-token")

        #expect(token.accessToken == "new-token")
        #expect(token.refreshToken == nil)
        let request = try #require(await transport.requests.first)
        #expect(youtubeFormValues(in: request) == [
            "client_id": "test-client",
            "refresh_token": "refresh-token",
            "grant_type": "refresh_token",
        ])
    }

    @Test("Upload creates a resumable session and sends bounded chunks")
    func resumableUpload() async throws {
        let chunkSize = 256 * 1024
        let fileData = Data(repeating: 0x2A, count: chunkSize + 10)
        let fileURL = try temporaryVideo(containing: fileData)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let uploadURL = "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=test"
        let transport = YouTubeStubTransport(responses: [
            .success(youtubeHTTPResponse(
                statusCode: 200,
                json: "",
                headers: ["Location": uploadURL]
            )),
            .success(youtubeHTTPResponse(
                statusCode: 308,
                json: "",
                headers: ["Range": "bytes=0-262143"]
            )),
            .success(youtubeHTTPResponse(
                statusCode: 201,
                json: #"{"id":"video-id","snippet":{"title":"A title","description":"A description","channelId":"channel-id"},"status":{"uploadStatus":"uploaded","privacyStatus":"private"}}"#
            )),
        ])
        let progress = YouTubeProgressRecorder()
        let flow = makeYouTubeFlow(transport: transport, chunkSize: chunkSize)
        let upload = YouTubeVideoUpload(
            fileURL: fileURL,
            mimeType: "video/mp4",
            title: "A title",
            description: "A description",
            categoryID: "22",
            privacy: .private,
            madeForKids: false,
            notifySubscribers: false
        )

        let video = try await flow.uploadVideo(upload, accessToken: "access-token") {
            await progress.record($0)
        }

        #expect(video.id == "video-id")
        #expect(video.snippet?.channelID == "channel-id")
        let requests = await transport.requests
        #expect(requests.count == 3)

        let sessionRequest = requests[0]
        #expect(sessionRequest.httpMethod == "POST")
        #expect(sessionRequest.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(sessionRequest.value(forHTTPHeaderField: "X-Upload-Content-Length") == String(fileData.count))
        #expect(sessionRequest.value(forHTTPHeaderField: "X-Upload-Content-Type") == "video/mp4")
        #expect(queryValues(in: try #require(sessionRequest.url))["uploadType"] == "resumable")
        #expect(queryValues(in: try #require(sessionRequest.url))["part"] == "snippet,status")
        #expect(queryValues(in: try #require(sessionRequest.url))["notifySubscribers"] == "false")

        let metadata = try #require(sessionRequest.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        let snippet = try #require(json["snippet"] as? [String: Any])
        #expect(snippet["title"] as? String == "A title")
        #expect(snippet["tags"] == nil)

        #expect(requests[1].httpMethod == "PUT")
        #expect(requests[1].value(forHTTPHeaderField: "Content-Range") == "bytes 0-262143/262154")
        #expect(requests[1].httpBody?.count == chunkSize)
        #expect(requests[2].value(forHTTPHeaderField: "Content-Range") == "bytes 262144-262153/262154")
        #expect(requests[2].httpBody?.count == 10)
        #expect(await progress.values == [
            .init(bytesSent: Int64(chunkSize), totalBytes: Int64(fileData.count)),
            .init(bytesSent: Int64(fileData.count), totalBytes: Int64(fileData.count)),
        ])
    }

    @Test("Upload maps YouTube's structured API error")
    func uploadError() async throws {
        let fileURL = try temporaryVideo(containing: Data([0x01]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let transport = YouTubeStubTransport(responses: [
            .success(youtubeHTTPResponse(
                statusCode: 403,
                json: #"{"error":{"message":"Quota exceeded","errors":[{"reason":"quotaExceeded"}]}}"#
            )),
        ])
        let upload = YouTubeVideoUpload(
            fileURL: fileURL,
            mimeType: "video/mp4",
            title: "Title",
            description: "Description",
            categoryID: "22",
            privacy: .private,
            madeForKids: false
        )

        do {
            _ = try await makeYouTubeFlow(transport: transport).uploadVideo(
                upload,
                accessToken: "access-token"
            )
            Issue.record("Expected upload to fail")
        } catch let error as YouTubeUploadError {
            #expect(error == .requestFailed(
                statusCode: 403,
                reason: "quotaExceeded",
                message: "Quota exceeded"
            ))
        }
    }

    @Test("Upload checks server progress and resumes after a retryable failure")
    func uploadRecovery() async throws {
        let fileURL = try temporaryVideo(containing: Data([0x01]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let transport = YouTubeStubTransport(responses: [
            .success(youtubeHTTPResponse(
                statusCode: 200,
                json: "",
                headers: ["Location": "https://www.googleapis.com/upload/youtube/v3/videos?upload_id=test"]
            )),
            .success(youtubeHTTPResponse(
                statusCode: 503,
                json: #"{"error":{"message":"Try again","errors":[{"reason":"backendError"}]}}"#,
                headers: ["Retry-After": "2"]
            )),
            .success(youtubeHTTPResponse(statusCode: 308, json: "")),
            .success(youtubeHTTPResponse(statusCode: 201, json: #"{"id":"video-id"}"#)),
        ])
        let sleeps = YouTubeSleepRecorder()
        let flow = makeYouTubeFlow(transport: transport, sleepRecorder: sleeps)
        let upload = YouTubeVideoUpload(
            fileURL: fileURL,
            mimeType: "video/mp4",
            title: "Title",
            description: "Description",
            categoryID: "22",
            privacy: .private,
            madeForKids: false
        )

        let video = try await flow.uploadVideo(upload, accessToken: "access-token")

        #expect(video.id == "video-id")
        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests[2].value(forHTTPHeaderField: "Content-Length") == "0")
        #expect(requests[2].value(forHTTPHeaderField: "Content-Range") == "bytes */1")
        #expect(await sleeps.durations == [.seconds(2)])
    }
}

private actor YouTubeStubTransport {
    private var responses: [Result<(Data, URLResponse), any Error>]
    private(set) var requests: [URLRequest] = []

    init(responses: [Result<(Data, URLResponse), any Error>]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw YouTubeTestError.missingResponse }
        return try responses.removeFirst().get()
    }
}

private actor YouTubeProgressRecorder {
    private(set) var values: [YouTubeUploadProgress] = []

    func record(_ progress: YouTubeUploadProgress) {
        values.append(progress)
    }
}

private actor YouTubeSleepRecorder {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

private enum YouTubeTestError: Error {
    case missingResponse
}

private func makeYouTubeFlow(
    transport: YouTubeStubTransport,
    chunkSize: Int = 256 * 1024,
    sleepRecorder: YouTubeSleepRecorder? = nil
) -> YouTubeFlow {
    YouTubeFlow(
        configuration: .init(
            clientID: "test-client",
            redirectURI: URL(string: "com.example.app:/oauth2redirect")!
        ),
        send: { try await transport.send($0) },
        sleep: { duration in await sleepRecorder?.record(duration) },
        uploadChunkSize: chunkSize
    )
}

private func youtubeHTTPResponse(
    statusCode: Int,
    json: String,
    headers: [String: String]? = nil
) -> (Data, URLResponse) {
    let response = HTTPURLResponse(
        url: URL(string: "https://youtube.test")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: headers
    )!
    return (Data(json.utf8), response)
}

private func queryValues(in url: URL) -> [String: String] {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.reduce(into: [:]) {
        $0[$1.name] = $1.value
    } ?? [:]
}

private func youtubeFormValues(in request: URLRequest) -> [String: String] {
    guard let body = request.httpBody,
          let encoded = String(data: body, encoding: .utf8) else { return [:] }
    var components = URLComponents()
    components.percentEncodedQuery = encoded
    return components.queryItems?.reduce(into: [:]) {
        $0[$1.name] = $1.value
    } ?? [:]
}

private func temporaryVideo(containing data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowkit-\(UUID().uuidString).mp4")
    try data.write(to: url)
    return url
}
