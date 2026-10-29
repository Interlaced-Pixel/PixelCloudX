# PixelCloudX

PixelCloudX is a native macOS Xbox Cloud Gaming client for Apple silicon. SwiftUI and AppKit provide the interface, Apple’s Game Controller framework supplies controller input, and a native WebRTC framework handles the cloud media connection. Gameplay stays inside the app; the browser is used only for Microsoft device-code sign-in.

The app currently implements Microsoft device-code authorization, Xbox user/XSTS and GSSV sign-in, the public Xbox catalog and product hydration, account-title enrichment, cloud-session provisioning, Microsoft cloud-transfer authorization, HTTP SDP/ICE signaling, WebRTC audio/video, and gamepad input. The in-game Xbox Guide opens with **⌘G**. **⌘Q** asks whether to end the stream before quitting. Closing the main window terminates the app after session cleanup.

**⌘M** toggles native microphone input during a connected stream, with a persistent overlay indicator and a Guide control. The microphone starts off and requests macOS permission on first enable. See [microphone setup, transport, and validation](docs/MICROPHONE.md); live voice-chat audibility remains to be verified.

Xbox’s cloud-session and streaming endpoints are private, versioned web-client contracts. A native Madden session sustained 1080p video after correcting an invalid ICE end marker. Controller startup now has live acceptance in Star Wars Outlaws, including confirmation from the user. Voice-chat audibility, audio quality, and reconnect still need live acceptance. This does not establish a supported consumer integration. Service changes may require protocol updates. See [playback diagnosis and validation](docs/PLAYBACK_CRASH_AND_INPUT_FIX.md).

Microsoft OAuth access and refresh tokens are stored as unencrypted JSON at `Application Support/PixelCloudX/microsoft-auth.json`, with directory mode `0700` and file mode `0600`. Startup restores this login, renews expired access tokens, and preserves the saved credentials on temporary connection failures. Microsoft can still require sign-in after revocation or refresh-token expiration. PixelCloudX does not use Keychain. The Microsoft client ID in `App/Info.plist` is a public client-registration value; use a PixelCloudX-owned registration before distributing the app.

PixelCloudX app code is independently implemented. It does not embed WebKit, Chromium, CEF, or another browser engine. Its third-party runtime dependencies are the native WebRTC binary package and the Sparkle updater. See [Xbox Cloud Gaming research](docs/XBOX_CLOUD_GAMING_RESEARCH.md), [product scope](docs/PRODUCT.md), and [third-party notices](docs/THIRD_PARTY_NOTICES.md).

The catalog uses portrait covers, grouped navigation, discovery tiles, local recently opened games, search/filter/sort controls, and a native account menu. Open the account avatar to connect Gravatar for an avatar and public profile. See [Gravatar and catalog](docs/GRAVATAR_AND_CATALOG.md) for setup, privacy, and validation details.

Catalogue metadata and artwork persist between launches. Saved titles appear before silent refreshes, with NEW/UPDATED markers, an updates filter, and Mark seen controls. See [cache behavior and limits](docs/CATALOG_CACHE.md).


Native **Settings…** (Command-comma) provides persistent display ratios/scaling, Xbox resolution requests, game volume/mute, keyboard/controller preferences, microphone processing, Xbox accessibility/language, catalogue refresh/cache maintenance, account/Gravatar, and signed Sparkle updates. See [settings and updates](docs/SETTINGS_AND_UPDATES.md) and [input/microphone recovery](docs/INPUT_AND_MIC_RECOVERY.md).

Build with Xcode 27, the PixelCloudX scheme, macOS destination, and arm64. Swift Package Manager resolves the pinned native WebRTC and Sparkle dependencies. Use Xcode's existing default DerivedData directory. Run `bash Tests/run-regressions.sh` for isolated checks. [Release packaging](docs/SETTINGS_AND_UPDATES.md) requires an explicit local signing-key file; credentials and release keys never use Keychain.
