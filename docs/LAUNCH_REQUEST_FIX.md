# Cloud launch request serialization

The launch error “Missing or malformed request content. Failed to deserialize to expected request type.” had a concrete request-type mismatch: `settings.highContrast` was encoded as JSON `false`. Xbox's currently served client defines `HighContrastMode` as `Off=0`, `White=1`, and `Black=2`, and forwards that numeric value in the play request. PixelCloudX now sends numeric `0`.

The timezone value now follows the same client convention: minutes east of UTC. For example, Chicago daylight time is `-300`, and India is `330`.

Source observations on 2026-10-28:

- [Xbox client enum](https://play.xbox.com/assets/entry.client-ozcu9736.js): exported `Km` / `HighContrastMode` has numeric values.
- [Stream configuration](https://play.xbox.com/assets/StreamSessionConfiguration-dt4dv0vl.js): defaults `highContrastMode` to `Off` and timezone to `-new Date().getTimezoneOffset()`.
- [Session request](https://play.xbox.com/assets/StreamSessionRequest-kz1a471s.js): forwards `highContrastMode` as `settings.highContrast` to `/v5/sessions/cloud/play`.

These are private, versioned client contracts; the source observations do not establish a supported consumer integration or prove live playback.

## Regression verification

`Tests/XboxCloudPlayServiceRequestTests.swift` intercepts the production service's URLSession requests with URLProtocol. It checks the actual serialized field types, timezone direction, endpoint, title ID, and successful mocked provisioning/configuration flow. It uses synthetic credentials and never contacts Xbox. The test failed against the previous code because `highContrast` was a JSON boolean.

Run from the project root, reusing the project's existing default DerivedData tree. The script resolves the existing location from Xcode build settings and also exercises authentication restoration:

```sh
Tests/run-regressions.sh
xcodebuild -project PixelCloudX.xcodeproj -scheme PixelCloudX -configuration Release -destination 'platform=macOS,arch=arm64' build
```

## Console authorization and session failures

The subsequent screenshot showed the generic failed-state fallback. That response path discarded Xbox's nested `errorDetails.message` and `errorDetails.code`; those are now displayed. The screenshot alone does not reveal the server's original failure code.

The `/connect` implementation also used the wrong credential: it placed the GSSV service bearer token in `userToken`. The cloud console requires a separate Microsoft transfer token. PixelCloudX now requests that token when the session reaches `ReadyToConnect`, retains GSSV in the HTTP authorization header, persists any rotated refresh token, and sends the transfer credential in the body. Repeated `ReadyToConnect` states do not repeat the handshake. Failed and cancelled allocations are released even when cancellation would otherwise prevent the cleanup HTTP call.

This protocol distinction is also observable in the primary implementation sources for [Greenlight's connect request](https://github.com/unknownskl/greenlight/blob/main-v2/packages/desktop/main/helpers/xcloudapi.ts) and [XStreaming's transfer-token acquisition](https://github.com/Geocld/XStreaming/blob/main/src/xal/msal.ts). PixelCloudX implements the exchange independently with Foundation; no source from those applications is included.

Microsoft OAuth refresh and acquisition of a purpose-scoped transfer token succeeded using the saved login during this investigation. Requests to Xbox identity and the Xbox web-client asset host were reset by the remote connection, so the corrected console handshake and gameplay could not be accepted in a live session. The automated tests use synthetic credentials and mocked HTTP responses.

## Login and app lifecycle

Startup restores saved tokens and refreshes expired access tokens. A refresh network failure, HTTP 503, or malformed response no longer erases the saved login. Reconnect retries the refresh and saves rotated credentials. Microsoft revocation/interactive-login errors still require sign-in, following [Microsoft's refresh-token lifecycle](https://learn.microsoft.com/en-us/entra/identity-platform/refresh-tokens). Form encoding now escapes literal plus signs so refresh-token contents survive decoding. Explicit sign-out removes the file.

The app has one main window. AppKit requests application termination when it closes, waits for stream cancellation/cleanup, and then exits. The existing Command-Q confirmation for an active stream is retained.

Authentication tests exercise a new coordinator and token-store instance to represent a fresh launch, temporary refresh failures, recovery, rotation, transfer-token separation, file/directory permissions, revoked authorization, and explicit sign-out. They isolate media with a test stub; UI close-to-exit and actual login restoration are checked separately in the installed app.

Installed-app verification on 2026-10-28 confirmed that clicking the main window's close button removed the PixelCloudX process. The saved token file remained with mode `0600`, its expired OAuth access token had been silently renewed, and reopening the app showed the signed-in catalog without a device-code prompt. Xbox identity and catalog connections displayed a TLS failure, preventing a live launch retry. The arm64 Release build, signature verification, and both regression executables passed.
