# Browser OAuth Login Design

## Overview

Add browser-based OAuth login to the macOS menubar app as an alternative to reading local Claude Code keychain credentials. On first launch, prompt the user to choose between the two methods.

## Auth Mode

`AuthMode` enum stored in `UserDefaults`:
- `.notConfigured` — first launch, no choice made yet
- `.localCredentials` — use Claude Code's keychain entry (existing behavior)
- `.browserOAuth` — use tokens from browser login

`UsageManager` changes:
- `@Published var authMode: AuthMode` read from UserDefaults on init
- `getAccessToken()` branches on authMode: `.localCredentials` uses existing `readOAuthCredentials()`, `.browserOAuth` uses `OAuthService.getToken()`
- `setAuthMode(_:)` writes to UserDefaults, clears stale state, triggers refresh
- `signOut()` clears browser OAuth tokens and resets to `.notConfigured`

## OAuthService

New file `OAuthService.swift` handling browser OAuth flow and token storage.

### Login Flow

1. Generate PKCE `code_verifier` (random 43-128 chars) and `code_challenge` (SHA256 + base64url)
2. Open `ASWebAuthenticationSession` with `https://platform.claude.com/oauth/authorize` params: `client_id`, `response_type=code`, `code_challenge`, `code_challenge_method=S256`, `redirect_uri=claudeusage://callback`
3. If custom scheme redirect works: extract `code` from callback URL
4. If it fails: fall back to `redirect_uri=https://platform.claude.com/oauth/code/callback`, show text field for user to paste code
5. Exchange code for tokens via POST to `https://platform.claude.com/v1/oauth/token` with `code_verifier`
6. Store `access_token`, `refresh_token`, `expires_at` in Keychain under service `ClaudeUsage`

### Token Management

- `getToken() async throws -> String` — reads from Keychain, refreshes if expired/expiring
- `deleteTokens()` — removes Keychain entry
- Keychain access via native `SecItem*` APIs (not `security` CLI)
- URL scheme `claudeusage` registered in `Info.plist` under `CFBundleURLTypes`

### Endpoints (from Claude Code binary)

- Authorize: `https://platform.claude.com/oauth/authorize`
- Token: `https://platform.claude.com/v1/oauth/token`
- Client ID: `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- Manual redirect: `https://platform.claude.com/oauth/code/callback`

## UI Changes

### Auth Picker (popover, shown when `authMode == .notConfigured`)

- Replaces content area between header and footer
- Icon: `person.crop.circle`
- Title: "Choose Sign-in Method"
- Two stacked buttons:
  - "Sign in with Anthropic" (`.borderedProminent`) — triggers OAuthService.login()
  - "Use Claude Code Credentials" (`.bordered`) — sets mode to .localCredentials
- Brief caption under each button

### Manual Code Fallback View

- Shown if ASWebAuthenticationSession with custom scheme fails
- "Paste the code from your browser" + TextField + Submit button
- Dismissable/cancellable

### Footer Addition

- "Switch Account" button (small, icon-based) next to existing controls
- Calls signOut() which resets to .notConfigured and clears browser tokens

### Error View Updates

- `.localCredentials` mode: existing "run `claude` in Terminal" message
- `.browserOAuth` mode: "Session expired. Sign in again." with Sign In button

## Data Flow

```
App Launch → Read authMode from UserDefaults
  ├── .notConfigured → Show auth picker
  │     ├── "Sign in with Anthropic" → OAuthService.login() → store tokens → .browserOAuth → refresh()
  │     └── "Use Claude Code" → .localCredentials → refresh()
  ├── .localCredentials → existing readOAuthCredentials() path
  └── .browserOAuth → OAuthService.getToken() (refresh if expired) → fetchUsage()
```

"Switch Account" → clear tokens → reset to .notConfigured → show picker
