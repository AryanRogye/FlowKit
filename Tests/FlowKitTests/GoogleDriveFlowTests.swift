import Foundation
import Testing
@testable import FlowKit

@Suite("Google Drive flow")
struct GoogleDriveFlowTests {
    @Test("Authorization uses explicit scopes, PKCE, and no client secret")
    func authorizationAndExchange() async throws {
        let transport = DriveStub(responses: [driveResponse(200, #"{"access_token":"access-token","expires_in":3600,"refresh_token":"refresh-token","token_type":"Bearer"}"#)])
        let flow = driveFlow(transport)
        let authorization = try flow.makeAuthorizationRequest(scopes: [.file], accessType: .offline)
        let query = driveQuery(authorization.authorizationURL)
        #expect(query["client_id"] == "test-client")
        #expect(query["scope"] == GoogleDriveScope.file.rawValue)
        #expect(query["access_type"] == "offline")
        #expect(query["code_challenge_method"] == "S256")
        #expect(authorization.codeVerifier.count >= 43)
        let callback = URL(string: "com.example.app:/oauth2redirect?code=auth-code&state=\(authorization.state)")!
        #expect(try await flow.exchangeAuthorizationCallback(callback, for: authorization).accessToken == "access-token")
        let form = driveForm(try #require(await transport.requests.first))
        #expect(form["code_verifier"] == authorization.codeVerifier)
        #expect(form["client_secret"] == nil)
    }

    @Test("Authorization rejects empty scopes and mismatched state")
    func authorizationValidation() async throws {
        let flow = driveFlow(DriveStub(responses: []))
        #expect(throws: GoogleDriveAuthenticationError.missingScopes) { try flow.makeAuthorizationRequest(scopes: []) }
        let request = try flow.makeAuthorizationRequest(scopes: [.file])
        await #expect(throws: GoogleDriveAuthenticationError.stateMismatch) {
            _ = try await flow.exchangeAuthorizationCallback(URL(string: "com.example.app:/oauth2redirect?code=x&state=wrong")!, for: request)
        }
    }

    @Test("Refresh sends only the public client ID and refresh token")
    func refresh() async throws {
        let transport = DriveStub(responses: [driveResponse(200, #"{"access_token":"new-token","expires_in":3600,"token_type":"Bearer"}"#)])
        _ = try await driveFlow(transport).refreshAccessToken("refresh-token")
        #expect(driveForm(try #require(await transport.requests.first)) == [
            "client_id": "test-client", "refresh_token": "refresh-token", "grant_type": "refresh_token",
        ])
    }

    @Test("Upload starts a resumable session and sends bounded chunks")
    func resumableUpload() async throws {
        let chunkSize = 256 * 1024
        let bytes = Data(repeating: 7, count: chunkSize + 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drive-\(UUID()).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = DriveStub(responses: [
            driveResponse(200, "", ["Location": "https://upload.test/session"]),
            driveResponse(308, "", ["Range": "bytes=0-262143"]),
            driveResponse(201, #"{"id":"file-id","name":"archive.bin","mimeType":"application/octet-stream","size":"262147"}"#),
        ])
        let progress = DriveProgress()
        let file = try await driveFlow(transport, chunkSize: chunkSize).uploadFile(
            .init(fileURL: url, name: "archive.bin", mimeType: "application/octet-stream", parentFolderID: "folder-id"),
            accessToken: "access-token"
        ) { await progress.record($0) }
        #expect(file.id == "file-id")
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(driveQuery(try #require(requests[0].url))["uploadType"] == "resumable")
        let metadataData = try #require(requests[0].httpBody)
        let metadata = try #require(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        #expect(metadata["parents"] as? [String] == ["folder-id"])
        #expect(requests[1].value(forHTTPHeaderField: "Content-Range") == "bytes 0-262143/262147")
        #expect(requests[2].value(forHTTPHeaderField: "Content-Range") == "bytes 262144-262146/262147")
        #expect(await progress.values.last?.fractionCompleted == 1)
    }

    @Test("Upload maps structured Drive errors")
    func uploadError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drive-\(UUID()).txt")
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = DriveStub(responses: [driveResponse(403, #"{"error":{"code":403,"message":"Quota exceeded","errors":[{"reason":"dailyLimitExceeded"}]}}"#)])
        await #expect(throws: GoogleDriveUploadError.requestFailed(statusCode: 403, reason: "dailyLimitExceeded", message: "Quota exceeded")) {
            _ = try await driveFlow(transport).uploadFile(.init(fileURL: url, name: "x.txt", mimeType: "text/plain"), accessToken: "access-token")
        }
    }
}

private actor DriveStub {
    var responses: [(Data, URLResponse)]
    private(set) var requests: [URLRequest] = []
    init(responses: [(Data, URLResponse)]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

private actor DriveProgress {
    private(set) var values: [GoogleDriveUploadProgress] = []
    func record(_ value: GoogleDriveUploadProgress) { values.append(value) }
}

private func driveFlow(_ transport: DriveStub, chunkSize: Int = 256 * 1024) -> GoogleDriveFlow {
    GoogleDriveFlow(configuration: .init(clientID: "test-client", redirectURI: URL(string: "com.example.app:/oauth2redirect")!), send: { try await transport.send($0) }, uploadChunkSize: chunkSize)
}

private func driveResponse(_ status: Int, _ json: String, _ headers: [String: String]? = nil) -> (Data, URLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: URL(string: "https://drive.test")!, statusCode: status, httpVersion: nil, headerFields: headers)!)
}

private func driveQuery(_ url: URL) -> [String: String] {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.reduce(into: [:]) { $0[$1.name] = $1.value } ?? [:]
}

private func driveForm(_ request: URLRequest) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
    return components.queryItems?.reduce(into: [:]) { $0[$1.name] = $1.value } ?? [:]
}
