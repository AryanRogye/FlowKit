# AGENTS.md

## Project purpose

FlowKit is a Swift package for integrating third-party services without tying
consuming apps to credentials, infrastructure, or developer accounts owned by
FlowKit.

The central product idea is **Bring Your Own Provider Configuration**:

- An app developer can register their own OAuth/API application with a provider
  and pass the required configuration to FlowKit.
- A consuming app can optionally let its users supply their own API project,
  supported credentials, or compatible self-hosted endpoint.
- FlowKit implements the repetitive integration work: authentication flows,
  request construction, polling, response decoding, error mapping, token
  refresh/revocation where applicable, and provider-specific API operations.
- FlowKit must not require a shared FlowKit-owned client ID, developer account,
  hosted authentication service, or credential vault.

GitHub device authentication and YouTube video uploads are the first
implementations. The intended scope eventually includes providers such as
Google Drive, Google Keep, Instagram, Facebook, and other OAuth, API-key, or
self-hosted services where their APIs and policies allow third-party
integrations.

## Public configuration versus secrets

Do not treat every value called a “credential” as a secret.

Values a provider documents as public or non-secret should remain easy to
supply in normal app configuration or source code. Depending on the provider,
these can include:

- OAuth client IDs
- requested scopes
- redirect URLs or callback schemes
- API base URLs
- public application identifiers

Only ask for values that the selected provider flow actually requires. Do not
add a client secret to a configuration type preemptively.

Private values require different handling:

- Never commit client secrets, API keys documented as private, access tokens,
  or refresh tokens.
- Never embed a confidential client secret in a distributed iOS or macOS app.
- If a provider requires a confidential secret, keep that secret on a backend
  controlled by the consuming developer—not in FlowKit or the client app.
- Access and refresh tokens belong to the consuming app/user. FlowKit may
  return or operate with them, but persistent secure storage is the consuming
  app's responsibility (normally Keychain on Apple platforms).

For the current GitHub device flow, the required application value is the
GitHub OAuth client ID. The GitHub client secret is not used and has nothing to
do with this repository or `GitHubConfiguration`.

For YouTube, the consuming developer supplies an iOS OAuth client ID and its
registered redirect URI. Google's installed-app authorization-code flow uses
PKCE and does not require FlowKit to request a client secret. Each consuming
app must use a Google Cloud project and OAuth client appropriate for that API
client and comply with Google's verification and YouTube API policies.

Always verify a provider's current official documentation before deciding
whether a value is public, whether a flow needs a secret, and whether the flow
is permitted for a native/public client.

## Product and API design principles

- Keep credential ownership with the app developer or user.
- Prefer provider-specific configuration types with only the fields that are
  truly required, such as `GitHubConfiguration(clientID:)`.
- Make requested permissions explicit at the call site. Do not silently widen
  scopes.
- Keep provider-specific differences visible where they matter; a common API
  must not pretend all OAuth or API-key flows have identical security rules.
- Do not introduce a mandatory FlowKit backend or central account.
- Support configurable API base URLs when a service has compatible self-hosted
  implementations, but validate URLs and avoid weakening transport security by
  default.
- Keep public API models `Sendable` where appropriate and use Swift concurrency
  for asynchronous work.
- Prefer focused provider namespaces/directories under `Sources/FlowKit/`.
- Do not advertise a provider as supported until its implementation and tests
  exist. The README may identify unimplemented providers as direction or
  planned work only.

## Current repository state

- Swift package: `FlowKit`
- Platforms: macOS 14+ and iOS 17+
- Swift tools version: 6.4
- Implemented providers: GitHub and YouTube
- Implemented GitHub behavior:
  - request a device authorization challenge;
  - poll while authorization is pending;
  - respect GitHub's `slow_down` response;
  - return the access token after authorization;
  - map expiration, denial, and provider errors;
  - fetch the authenticated GitHub user.
- Implemented YouTube behavior:
  - construct installed-app OAuth authorization requests with PKCE and state;
  - exchange authorization callbacks and refresh access tokens;
  - upload local video files with bounded resumable chunks and progress;
  - map structured YouTube API errors.
- The consuming app stores returned access tokens securely.

Relevant paths:

- `Sources/FlowKit/Github/GitHubFlow.swift`
- `Sources/FlowKit/Github/GitHubAuthentication.swift`
- `Sources/FlowKit/Github/GitHubUser.swift`
- `Sources/FlowKit/YouTube/YouTubeFlow.swift`
- `Sources/FlowKit/YouTube/YouTubeAuthentication.swift`
- `Sources/FlowKit/YouTube/YouTubeUpload.swift`
- `Tests/FlowKitTests/GitHubFlowTests.swift`
- `Tests/FlowKitTests/YouTubeFlowTests.swift`
- `README.md`

## Implementation conventions

- Use `Foundation` networking and async/await unless the project deliberately
  adopts another dependency.
- Preserve testability by injecting side effects internally. `GitHubFlow`
  injects a request sender and sleep function so tests do not make live network
  calls or wait in real time; use a comparable approach for new providers.
- Keep the ordinary public initializer simple and use production defaults such
  as `URLSession.shared` and `Task.sleep` there.
- Decode provider wire formats with private response models, then expose clear
  public FlowKit models.
- Check HTTP status codes before decoding successful responses.
- Preserve cancellation in polling and other long-running asynchronous work.
- Follow provider polling intervals, rate limits, error responses, and refresh
  rules exactly; cover important state transitions with tests.
- Use the Swift Testing framework (`import Testing`) for new tests.
- Keep tests deterministic. Stub transports and time rather than contacting
  real provider APIs or relying on real credentials.
- Never add working credentials or tokens to examples, fixtures, snapshots, or
  logs. Use unmistakably fake values such as `test-client` and `access-token`.

## Verification

For code changes, run:

```sh
swift test
```

For documentation-only changes, at minimum run:

```sh
git diff --check
```

When adding a provider, test at least:

- exact request URL, method, headers, and encoded parameters;
- omission of optional or empty parameters;
- successful response decoding;
- non-success HTTP responses and malformed payloads;
- provider-specific error mapping;
- polling, rate-limit, refresh, expiry, denial, and cancellation behavior when
  applicable;
- proof that secrets not required by the chosen flow are never requested or
  transmitted.

## Documentation language

Describe FlowKit as a package that accepts developer- or user-supplied provider
configuration. Avoid language suggesting that FlowKit supplies shared
credentials or that all configuration is secret.

Be precise:

- “Public/non-secret provider configuration” means the provider explicitly
  permits the value to appear in a public/native client.
- “Bring Your Own Credentials” does not authorize publishing actual secrets.
- A provider name in the project direction is not the same as implemented
  support.
- Provider capabilities and restrictions should be stated conditionally when
  they depend on external APIs, app review, or platform policies.

## Working in this repository

- Preserve unrelated user changes in the worktree.
- Make the smallest coherent change that advances the requested integration.
- Do not redesign existing public APIs without explaining the compatibility
  impact.
- Update the README and this file when the product model, supported providers,
  security boundary, platform requirements, or verification commands change.
