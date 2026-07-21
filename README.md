# FlowKit

FlowKit is a Swift package for connecting apps to third-party services with
credentials and configuration supplied by the app developer—or, when the app
supports it, by the user.

The goal is to make integrations portable instead of tying FlowKit to one
developer account, one hosted backend, or a set of credentials owned by the
package. A consuming app can register its own OAuth application, choose the
permissions it needs, and pass only the configuration required by that
integration to FlowKit. Apps may also offer a **Bring Your Own Credentials**
experience so users can connect their own API project or self-hosted service.

```text
Developer or user
        ↓
Creates or selects an API/OAuth project
        ↓
Chooses permissions and redirect settings
        ↓
Supplies provider configuration to the app
        ↓
FlowKit handles authentication and API requests
```

## Why FlowKit?

Integrating a service usually means repeatedly implementing OAuth flows,
request construction, response decoding, polling, error handling, and token
management. FlowKit aims to provide a consistent Swift API for those pieces
while keeping ownership and control of credentials with the consuming app and
its users.

The intended model is:

- **No FlowKit-owned credentials.** The package does not require every app to
  share a central client ID or developer account.
- **Public configuration stays public.** Non-secret values such as client IDs,
  scopes, redirect URLs, and API base URLs can remain in app configuration or
  source code when the provider permits it.
- **Developer-supplied configuration.** App developers can register their own
  provider applications and select the scopes their product requires.
- **User-supplied configuration.** Apps can optionally let advanced users load
  their own API credentials or connect compatible self-hosted endpoints.
- **Provider-specific behavior behind a consistent API.** FlowKit handles the
  differences between authentication flows and service APIs without hiding
  which permissions are being requested.
- **Portable integrations.** The same approach should work across Apple
  platforms and across many providers.

## Project status

FlowKit is in early development. It currently supports GitHub device
authentication and authenticated user lookup, YouTube OAuth and resumable
video uploads, and Google Drive OAuth and resumable file uploads. The
longer-term direction is to support services such as Google Keep, Instagram,
and Facebook, along with other OAuth, API-key, and self-hosted integrations
where their platforms permit third-party access.

Provider availability and authentication methods depend on each service's API,
terms, app-review requirements, and supported platforms. The list above
describes the direction of the project, not a guarantee that every integration
is currently available.

## GitHub device authentication

Create a GitHub OAuth App, enable its device flow, and provide its client ID.
GitHub's device flow does not require the app's client secret, so that secret is
not part of FlowKit's GitHub configuration:

```swift
let flow = GitHubFlow(
    configuration: GitHubConfiguration(clientID: "your-client-id")
)

let challenge = try await flow.authenticate(scopes: ["repo"])

// Show challenge.userCode and open challenge.verificationURL for the user.
let accessToken = try await flow.waitForAuthentication(
    challenge: challenge
)

let user = try await flow.getUser(accessToken: accessToken)
print(user.login)
```

The consuming app is responsible for storing the access token securely, such
as in Keychain. Device challenges are temporary and should remain in memory.

## YouTube video uploads

Each consuming app creates its own Google Cloud project, enables the YouTube
Data API v3, configures its OAuth consent screen, and creates an iOS OAuth
client for its bundle identifier. Pass that client's public ID and registered
redirect URI to FlowKit; a client secret is not required by Google's installed
app flow.

```swift
let flow = YouTubeFlow(
    configuration: YouTubeConfiguration(
        clientID: "your-ios-client-id",
        redirectURI: URL(string: "com.example.app:/oauth2redirect")!
    )
)

let authorization = try flow.makeAuthorizationRequest(
    scopes: [.upload],
    accessType: .offline
)

// Present authorization.authorizationURL in a secure system browser and
// return the registered callback URL to FlowKit.
let callbackURL = try await presentAuthorization(authorization.authorizationURL)
let token = try await flow.exchangeAuthorizationCallback(
    callbackURL,
    for: authorization
)

let video = try await flow.uploadVideo(
    YouTubeVideoUpload(
        fileURL: localVideoURL,
        mimeType: "video/mp4",
        title: "My video",
        description: "Uploaded from my app",
        categoryID: "22",
        privacy: .unlisted,
        madeForKids: false
    ),
    accessToken: token.accessToken
) { progress in
    print(progress.fractionCompleted)
}

print(video.id)
```

The upload goes to the channel associated with the Google account that grants
consent. FlowKit uses the narrow `youtube.upload` scope, PKCE, callback state
validation, and bounded resumable chunks. The app remains responsible for:

- presenting Google's authorization page in an approved system browser;
- storing access and refresh tokens in Keychain;
- refreshing an expired access token with `refreshAccessToken(_:)`;
- letting the user explicitly choose title, description, privacy, and
  made-for-kids status and confirm compliance with YouTube's Community
  Guidelines;
- meeting Google's consent-screen, privacy-policy, branding, verification,
  quota, and YouTube API compliance requirements.

Google restricts uploads from unverified API projects created after July 28,
2020 to private viewing. The consuming developer must complete YouTube's API
compliance audit to lift that restriction. Google also requires credentials to
belong to the API client using them, so FlowKit does not ship or pool a shared
Google project or client ID.

## Google Drive file uploads

Create an appropriate Google OAuth client for the consuming app, enable the
Google Drive API, and pass the public client ID and registered redirect URI to
FlowKit. Request only the scope the app needs; `drive.file` limits access to
files the user opens with or creates through the app.

```swift
let flow = GoogleDriveFlow(
    configuration: GoogleDriveConfiguration(
        clientID: "your-ios-client-id",
        redirectURI: URL(string: "com.example.app:/oauth2redirect")!
    )
)

let authorization = try flow.makeAuthorizationRequest(
    scopes: [.file],
    accessType: .offline
)
let callbackURL = try await presentAuthorization(authorization.authorizationURL)
let token = try await flow.exchangeAuthorizationCallback(callbackURL, for: authorization)

let file = try await flow.uploadFile(
    GoogleDriveFileUpload(
        fileURL: localFileURL,
        name: "Report.pdf",
        mimeType: "application/pdf"
    ),
    accessToken: token.accessToken
)
print(file.id)
```

FlowKit validates OAuth callback state, uses PKCE without a client secret, and
uploads local files in bounded resumable chunks. The consuming app presents the
authorization URL, securely stores user tokens, refreshes access when needed,
and complies with Google's consent-screen, verification, and data-use rules.

## Public configuration and private secrets

FlowKit keeps public configuration public. Values that a provider documents as
non-secret—commonly OAuth client IDs, requested scopes, redirect URLs, and API
base URLs—can be stored alongside the app's normal configuration. FlowKit does
not hide those values or require a backend merely because they identify an API
project.

Private credentials are separate. A provider's client secret has no place in
this repository or in a distributed client app unless that provider explicitly
requires and permits it for the chosen flow. For example, FlowKit's GitHub
device authentication uses a client ID and never needs the GitHub client
secret.

FlowKit's YouTube integration uses Google's installed-app authorization-code
flow with PKCE and does not request a client secret.

- Never commit secrets or tokens to source control.
- Pass only the values required by a provider's chosen authentication flow.
- Store user tokens in Keychain and request only the scopes the app needs.
- Use a backend for flows that require a secret to remain confidential.
- Follow each provider's OAuth, app-review, branding, and data-use policies.

## Direction

FlowKit is being designed so a provider integration can describe:

- its developer- or user-supplied configuration;
- its supported authentication flow;
- the scopes and permissions requested by the app;
- optional API base URLs for compatible or self-hosted services;
- token refresh, revocation, and service-specific requests.

The aim is a package that makes adding a new service feel familiar while still
respecting the security rules and capabilities of that provider.
