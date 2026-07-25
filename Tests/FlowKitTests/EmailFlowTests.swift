import Foundation
import Testing
@testable import FlowKit

@Suite("Email flow")
struct EmailFlowTests {
    @Test("Gmail authorization uses its mail scope, PKCE, and no client secret")
    func gmailAuthorizationAndExchange() async throws {
        let transport = EmailStub(responses: [
            emailResponse(
                200,
                #"{"access_token":"access-token","expires_in":3600,"refresh_token":"refresh-token","scope":"https://mail.google.com/","token_type":"Bearer"}"#
            ),
        ])
        let flow = emailFlow(transport)

        let authorization = try flow.makeAuthorizationRequest(
            scopes: [.gmailMail],
            accessType: .offline
        )
        let query = emailQuery(authorization.authorizationURL)
        #expect(query["client_id"] == "test-client")
        #expect(query["redirect_uri"] == "com.example.app:/oauth2redirect")
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == "https://mail.google.com/")
        #expect(query["access_type"] == "offline")
        #expect(query["code_challenge_method"] == "S256")
        #expect(authorization.codeVerifier.count >= 43)

        let callback = URL(
            string: "com.example.app:/oauth2redirect?code=auth-code&state=\(authorization.state)"
        )!
        let token = try await flow.exchangeAuthorizationCallback(callback, for: authorization)
        #expect(token.accessToken == "access-token")
        #expect(token.refreshToken == "refresh-token")

        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let form = emailForm(request)
        #expect(form["client_id"] == "test-client")
        #expect(form["code"] == "auth-code")
        #expect(form["code_verifier"] == authorization.codeVerifier)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["redirect_uri"] == "com.example.app:/oauth2redirect")
        #expect(form["client_secret"] == nil)
    }

    @Test("Authorization validates callback state and provider denial")
    func authorizationValidation() async throws {
        let flow = emailFlow(EmailStub(responses: []))
        #expect(throws: EmailAuthenticationError.missingScopes) {
            _ = try flow.makeAuthorizationRequest(scopes: [])
        }
        let request = try flow.makeAuthorizationRequest(scopes: [.gmailMail])

        await #expect(throws: EmailAuthenticationError.stateMismatch) {
            _ = try await flow.exchangeAuthorizationCallback(
                URL(string: "com.example.app:/oauth2redirect?code=x&state=wrong")!,
                for: request
            )
        }

        await #expect(
            throws: EmailAuthenticationError.accessDenied(description: "No thanks")
        ) {
            _ = try await flow.exchangeAuthorizationCallback(
                URL(
                    string: "com.example.app:/oauth2redirect?error=access_denied&error_description=No%20thanks&state=\(request.state)"
                )!,
                for: request
            )
        }
    }

    @Test("Refresh uses only public client ID and user refresh token")
    func refresh() async throws {
        let transport = EmailStub(responses: [
            emailResponse(
                200,
                #"{"access_token":"new-token","expires_in":3600,"token_type":"Bearer"}"#
            ),
        ])

        _ = try await emailFlow(transport).refreshAccessToken("refresh-token")

        let request = try #require(await transport.requests.first)
        #expect(emailForm(request) == [
            "client_id": "test-client",
            "refresh_token": "refresh-token",
            "grant_type": "refresh_token",
        ])
    }

    @Test("Token endpoint errors and malformed success payloads are mapped")
    func tokenErrors() async throws {
        let deniedTransport = EmailStub(responses: [
            emailResponse(
                400,
                #"{"error":"invalid_grant","error_description":"Authorization code expired"}"#
            ),
        ])
        let deniedFlow = emailFlow(deniedTransport)
        let deniedRequest = try deniedFlow.makeAuthorizationRequest(scopes: [.gmailMail])
        await #expect(
            throws: EmailAuthenticationError.provider(
                code: "invalid_grant",
                description: "Authorization code expired"
            )
        ) {
            _ = try await deniedFlow.exchangeAuthorizationCallback(
                URL(
                    string: "com.example.app:/oauth2redirect?code=expired&state=\(deniedRequest.state)"
                )!,
                for: deniedRequest
            )
        }

        let malformedTransport = EmailStub(responses: [
            emailResponse(200, #"{"expires_in":3600,"token_type":"Bearer"}"#),
        ])
        let malformedFlow = emailFlow(malformedTransport)
        let malformedRequest = try malformedFlow.makeAuthorizationRequest(scopes: [.gmailMail])
        await #expect(throws: EmailAuthenticationError.invalidTokenResponse) {
            _ = try await malformedFlow.exchangeAuthorizationCallback(
                URL(
                    string: "com.example.app:/oauth2redirect?code=x&state=\(malformedRequest.state)"
                )!,
                for: malformedRequest
            )
        }
    }

    @Test("Gmail IMAP authentication uses TLS and the XOAUTH2 wire format")
    func gmailIMAPAuthentication() throws {
        let flow = emailFlow(EmailStub(responses: []))
        let authentication = try flow.makeIMAPAuthentication(
            username: "person@example.com",
            accessToken: "access-token"
        )

        #expect(authentication.host == "imap.gmail.com")
        #expect(authentication.port == 993)
        #expect(authentication.security == .tls)
        #expect(authentication.mechanism == .xoauth2)

        let decoded = try #require(Data(base64Encoded: authentication.initialClientResponse))
        #expect(
            String(decoding: decoded, as: UTF8.self)
                == "user=person@example.com\u{01}auth=Bearer access-token\u{01}\u{01}"
        )
    }

    @Test("IMAP authentication rejects empty and control-character values")
    func imapValidation() {
        let flow = emailFlow(EmailStub(responses: []))
        #expect(throws: EmailIMAPAuthenticationError.invalidUsername) {
            _ = try flow.makeIMAPAuthentication(username: "", accessToken: "access-token")
        }
        #expect(throws: EmailIMAPAuthenticationError.invalidUsername) {
            _ = try flow.makeIMAPAuthentication(
                username: "person@example.com\r\nA01 LOGOUT",
                accessToken: "access-token"
            )
        }
        #expect(throws: EmailIMAPAuthenticationError.invalidAccessToken) {
            _ = try flow.makeIMAPAuthentication(
                username: "person@example.com",
                accessToken: "token\u{01}injection"
            )
        }
        #expect(throws: EmailIMAPAuthenticationError.invalidAccessToken) {
            _ = try flow.makeIMAPAuthentication(
                username: "person@example.com",
                accessToken: "token injection"
            )
        }
    }
}

private actor EmailStub {
    var responses: [(Data, URLResponse)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(Data, URLResponse)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

private func emailFlow(_ transport: EmailStub) -> EmailFlow {
    EmailFlow(
        configuration: .gmail(
            clientID: "test-client",
            redirectURI: URL(string: "com.example.app:/oauth2redirect")!
        ),
        send: { try await transport.send($0) }
    )
}

private func emailResponse(_ status: Int, _ json: String) -> (Data, URLResponse) {
    (
        Data(json.utf8),
        HTTPURLResponse(
            url: URL(string: "https://oauth2.googleapis.com/token")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    )
}

private func emailQuery(_ url: URL) -> [String: String] {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .reduce(into: [:]) { $0[$1.name] = $1.value } ?? [:]
}

private func emailForm(_ request: URLRequest) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = request.httpBody.flatMap {
        String(data: $0, encoding: .utf8)
    }
    return components.queryItems?.reduce(into: [:]) {
        $0[$1.name] = $1.value
    } ?? [:]
}
