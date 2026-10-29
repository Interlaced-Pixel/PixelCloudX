# Product and UI scope

## Product direction

PixelCloudX is a native macOS client for Apple silicon. It uses SwiftUI, AppKit, GameController, and native WebRTC. Gameplay renders inside the app; Microsoft device-code verification is the only flow that opens a browser. The app does not embed WebKit, Chromium, CEF, or another browser engine.

## Current flow

1. **Welcome:** start Microsoft sign-in or browse the Xbox catalog as a guest.
2. **Microsoft authorization:** PixelCloudX requests a consumer device code. The user completes verification with Microsoft in a browser. The app stores OAuth access and refresh tokens as unencrypted JSON at `Application Support/PixelCloudX/microsoft-auth.json`; the directory is mode `0700` and the file is mode `0600`. No Keychain APIs are used.
3. **Xbox account setup:** exchange the Microsoft access token for Xbox user and XSTS tokens, then request per-offering GSSV service tokens. Account-title details enrich the catalog but are optional for launching a stream.
4. **Catalog:** load Xbox’s public SIGL feed, hydrate products with artwork, descriptions, offering information, and cloud title IDs, and merge account-title information when available. “My list” is stored locally on this Mac.
5. **Game details and play:** request a cloud session with the GSSV bearer token, obtain a purpose-scoped Microsoft cloud-transfer token for the `/connect` body, negotiate SDP and ICE over the session’s HTTP signaling endpoints, then receive WebRTC media and forward controller state over the input data channel. Xbox failure messages and codes are shown when the service supplies them.
6. **In-game controls:** ⌘G opens the Xbox Guide. The Guide can mute game audio or end the stream. ⌘Q offers “End Stream and Quit” or “Keep Playing”. Closing the main window terminates the app after cancelling startup and releasing the cloud session.
7. **Next app launch:** restore the saved Microsoft login and silently refresh expired access tokens. Temporary network, server, and response failures retain the login for reconnection. Revoked or expired authorization can require interactive sign-in; explicit sign-out removes the saved login.

## Integration status and limits

- Microsoft device-code OAuth, Xbox identity exchange, GSSV offering login, public catalog hydration, private account-title lookup, cloud-session provisioning, WebRTC signaling, stream rendering, and controller forwarding are implemented in PixelCloudX source.
- The GSSV session/signaling contract is reverse-engineered from the current Xbox web client and may change without notice. A successful build and successful public catalog requests do not prove that Xbox will accept a live session. The current checkout has not completed a live game session.
- Catalog availability and account entitlement are separate. An Xbox product feed record alone does not prove a user can launch that game.
- OAuth token JSON is plaintext. Directory and file permissions limit access by other local users but do not encrypt the data or protect it from same-user processes. Signing out removes the file.
- Microphone capture and game/party voice chat are not implemented. Incoming game audio and controller input are implemented.
- The configured Microsoft client ID is public, but it is not owned by PixelCloudX. Replace it with an app registration controlled by the project before distribution.

## Native implementation

- SwiftUI and AppKit: navigation, catalog, details, stream overlay, and Guide.
- Foundation `URLSession`: Microsoft/Xbox service requests and catalog calls.
- GameController: native controller discovery and input snapshots.
- WebRTC package: peer connection, media tracks, data channels, and Metal-backed video view.
- App-private JSON file: local OAuth token storage without Keychain.

No Xbox web-client or other third-party cloud-gaming client source code is included in the app target. The app-side service and protocol code is maintained in PixelCloudX; WebRTC is a separate upstream runtime dependency. See [third-party notices](THIRD_PARTY_NOTICES.md).
