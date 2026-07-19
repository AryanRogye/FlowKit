
FlowKit will provide a nice Swift API, but each developer would create and own their own GitHub App

```
App developer
    ↓
Creates GitHub App
    ↓
Chooses permissions
    ↓
Supplies configuration to FlowKit
    ↓
FlowKit handles authentication + REST requests
```

## GitHub device authentication

Enable device flow for your GitHub OAuth app, then provide its client ID:

```swift
let flow = GitHubFlow(
    configuration: GitHubConfiguration(clientID: "your-client-id")
)

let challenge = try await flow.authenticate(scopes: ["repo"])

// Display challenge.userCode and open challenge.verificationURL.
let accessToken = try await flow.waitForAuthentication(
    challenge: challenge
)

let user = try await flow.getUser(accessToken: accessToken)
print(user.login)
```

The consuming app is responsible for storing the access token securely, such
as in Keychain. Device challenges are temporary and should remain in memory.
