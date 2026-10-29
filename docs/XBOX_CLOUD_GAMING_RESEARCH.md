# Xbox Cloud Gaming: native-client research

**Research date:** 2026-10-28  
**Project:** PixelCloudX, native macOS / Apple silicon concept  
**Scope:** consumer Xbox Cloud Gaming on `play.xbox.com`, with emphasis on gameplay launch, video/audio, microphone, and controller input.

## Executive summary

Xbox Cloud Gaming is exposed to Mac users through Xbox’s web experience. Microsoft publishes user-facing browser support and game-streaming guidance, plus Game Development Kit (GDK) APIs for Xbox game titles and developer kits. The sources reviewed do not provide a supported consumer macOS client SDK or a public contract for the web client’s private session service.

The current Xbox web client contains source-level evidence for Xbox identity and service tokens, cloud-session creation, WebRTC offer/ICE exchange, input/media configuration, keepalive, and session deletion. These are **private, versioned client implementation details**, not an approved or stable public API. PixelCloudX now has independently implemented native code for a subset of that flow. The catalog endpoints were rechecked live on 2026-10-28; no game was launched, so Xbox session acceptance, SDP/ICE exchange, gameplay video/audio, and controller delivery remain unverified.

This document records behavior read from Xbox's web client and maps it to PixelCloudX's independent implementation. The app contains no copied Xbox web-client or third-party cloud-gaming client source. Its native stream code compiles, but it has not completed a live Xbox game session in this checkout.

## Evidence and limits

### Evidence labels

- **Official:** Microsoft or Apple documentation/product announcements.
- **Client source:** URL templates, operation names, configuration fields, and event names found in the currently served Xbox web-client JavaScript.
- **Observed UI:** visible state from the already-open Xbox page in Chrome.
- **Inference:** a likely architectural interpretation of source-level evidence. It is not a documented service guarantee.
- **Unknown:** the current evidence does not establish the behavior or payload.

### Inspection method

The signed-in `play.xbox.com` page was inspected without starting a game. The loaded public JavaScript assets were fetched by their hashed names and searched locally. The page showed the Xbox navigation and a “Controller not detected” status. Source files inspected included the application entry, `PlayService`, stream-session request/configuration, game-stream adapter/bootstrapper, GameStreaming bridge, gamepad navigation, microphone UI/helper, and controller scan modules.

The browser inspection did not retain or copy cookies, access tokens, authorization headers, request bodies, account identifiers, or query values. The endpoint inventory below contains only service host templates and paths. The paths are from client code; unless labeled otherwise, they were **not called as part of this inspection**.

## What Microsoft documents

Microsoft describes Cloud Gaming as available through browsers and Xbox apps on supported devices ([Cloud Gaming](https://www.xbox.com/en-US/cloud-gaming), [getting-started guide](https://news.xbox.com/en-us/2025/12/19/getting-started-with-xbox-cloud-gaming/)). Its getting-started material describes gamepad use and says some titles also support mouse/keyboard or touch. Support is title- and device-dependent. Microsoft’s [May 2024 announcement](https://news.xbox.com/en-us/2024/05/15/xbox-may-update-2024/) described mouse/keyboard on Edge and Chrome and switching input modes during a game.

The GDK documentation is aimed at game developers and Xbox development kits. It describes how a game can detect streaming clients, inspect client/display properties, adapt resolution, and receive connection-state changes ([Cloud Aware APIs](https://learn.microsoft.com/en-us/gaming/gdk/docs/features/common/game-streaming/game-streaming-am-i-streaming?view=gdk-2604), [XGameStreaming reference](https://learn.microsoft.com/en-us/gaming/gdk/docs/reference/system/xgamestreaming/xgamestreaming_members?view=gdk-2604)). The setup guide discusses a **developer-kit streaming server** and protocol selection. These are server/title APIs and development tools; they do not constitute a consumer Mac client SDK ([dev-kit streaming setup](https://learn.microsoft.com/en-us/gaming/gdk/docs/features/common/game-streaming/game-streaming-setup-xbox-developer-kit?view=gdk-2604)).

Microsoft documents OAuth authorization-code with PKCE for desktop/native apps through the [identity platform](https://learn.microsoft.com/en-us/entra/identity-platform/v2-app-types) and its [authorization-code flow](https://learn.microsoft.com/en-us/azure/active-directory/develop/v1-protocols-oauth-code). That generic sign-in path does not by itself grant access to Xbox Cloud Gaming’s private service audience, catalog, or stream endpoints. The Xbox web client performs additional Xbox-specific token and service setup.

## Source-derived service map

### Service host and authentication

The web client has configuration for production, test, and integration environments. Its game-stream play service uses a host template equivalent to:

```text
https://[optional-prefix.]gssv-play-{httpEnvironment}.xboxlive.com
```

The source also names Xbox identity services (`user.auth.xboxlive.com`, `xsts.auth.xboxlive.com`, and `sisu.xboxlive.com`) and GSSV relying-party/audience identifiers for Xbox Live and stream connection services. Those audience identifiers are token configuration values, not endpoint URLs for direct media traffic. PixelCloudX currently calls Xbox user authentication, XSTS, and GSSV user-login endpoints; calls to GSSV do not establish that the private contract is stable or supported for third-party clients.

The stream auth helper contains `POST /v2/login/user` and `POST /v1/offerings/user`. The latter posts an Xbox authentication token to the configured service. Microsoft’s generic native OAuth endpoints are documented, but the complete Xbox token exchange, required claims, entitlement checks, and service-token contracts are not public client APIs. PixelCloudX's current Microsoft OAuth setup uses a public client ID in `App/Info.plist`; it does not read Chrome cookies or reuse browser tokens. The ID is configuration, not source code, and should be replaced with a PixelCloudX-owned registration before distribution.

### URL-template inventory from the Xbox web-client source

`{service}` means the configured game-stream service domain. `{sessionPath}` is an opaque value supplied by the service response. Request bodies and response DTOs are intentionally omitted where the contract is private.

| Method | Path template | Source-level purpose | Evidence / caveat |
|---|---|---|---|
| POST | `/v2/login/user` | Exchange Xbox identity input for a service user/session credential | Client source; payload omitted |
| POST | `/v1/offerings/user` | Fetch user offerings using Xbox authentication | Client source; entitlement contract unknown |
| GET | `/v1/titles` or `/v2/titles` | Query title metadata/catalog | Client source; query/filter contract varies |
| POST | `/v1/titles` or `/v2/titles` | Fetch title metadata by alternate IDs | Client source |
| GET | `/v1/titles/mru` or `/v2/titles/mru` | Fetch recently played titles | Client source |
| GET | `/v5/sessions/cloud/active` | Fetch active cloud sessions | Client source |
| POST | `/v5/sessions/cloud/play` | Request a cloud-play session | Client source; no live call observed |
| GET | `/v1/waittime/{titleId}` | Fetch title wait-time information | Client source |
| POST | `/v2/titles/inputconfigs` | Fetch per-title input configuration; source body has `titleIds` and `titleIdType` | Client source |
| GET | `/{sessionPath}/state` | Poll session state / provisioning progress | Client source |
| POST | `/{sessionPath}/connect` | Request session connection | Client source |
| POST | `/{sessionPath}/join` | Join an allocated session | Client source |
| GET | `/{sessionPath}/configuration` | Fetch stream configuration and optional client overrides | Client source |
| POST / GET | `/{sessionPath}/sdp` | Send local SDP and retrieve exchange response | Client source; payload/sequence only partly visible |
| POST / GET | `/{sessionPath}/ice` | Send and retrieve ICE candidate exchange data | Client source; payload/sequence only partly visible |
| POST | `/{sessionPath}/keepalive` | Keep a session alive and read its response | Client source |
| DELETE | `/{sessionPath}` | Delete/end a session | Client source |
| GET | `/v6/servers/home?mr=…&ct=…` | Find home-console servers for remote console streaming | Client source; distinct from cloud-play |
| POST | `/v5/sessions/home/play` | Request a home-console play session | Client source; distinct from cloud-play |
| GET | `/v1/sessions/tabs/{tabId}/download?noRedirect=true` | Resolve/download touch-adaptation bundle data | Client source |
| GET | `/v1/usercontent` | Fetch user content records | Client source; exact meaning/schema unknown |
| DELETE | `/v1/usercontent/{key}/{value}` | Delete a user-content record | Client source; identifiers are opaque |
| POST | `/v1/client/cte` | Send client telemetry events | Client source |
| POST | `/{sessionPath}/fileabug` | Submit stream-session diagnostics | Client source |

The client also has managed-developer-kit routes. They are not included above as consumer Cloud Gaming APIs.

**Do not build against these routes as if they were stable.** Host selection, authentication, anti-abuse/challenge handling, headers, queue rules, payload versions, session transitions, and service-side enforcement can change without notice. The source tree shows method/path construction, not a supported contract.

## Gameplay and transport flow

### Likely lifecycle from source

The `PlayService` and stream-session modules expose this lifecycle surface:

1. Resolve an eligible offering/title and title-specific input settings.
2. Request a cloud session through `/v5/sessions/cloud/play`.
3. Poll the opaque session path for state and wait/provisioning updates.
4. Fetch stream configuration, then connect/join the session.
5. Negotiate WebRTC using an SDP offer/answer exchange and ICE candidate exchange.
6. Open the stream, input, and control paths; report title-specific input capabilities.
7. Keep the session alive; respond to reconnect, state, or configuration events.
8. Stop and delete the session, then show post-stream feedback or diagnostics.

**This ordering is an inference from the client’s separate request methods and session state machine.** Exact order and retry semantics depend on the service response and were not verified with a live game.

The site source tests for `RTCPeerConnection` and selects a `WebRTCV1` stream type in its browser streaming path. It contains separate SDP and ICE request methods. This supports a WebRTC-based signaling/transport interpretation, but the public page alone does not establish the actual codecs, packetization, congestion-control tuning, or media channel layout used for a given session.

The web client also includes an internal `GameStreaming` bridge interface, version `1.0`, with operations such as `streaming.session.start/stop/queryState`, `streaming.signaling.createOffer/setRemoteDescription/addIceCandidates/cancel`, `streaming.input.updateConfiguration`, `streaming.video.updateConfiguration`, and game-mode/correlation-vector calls. It emits state, first-frame, ICE-candidate, cursor-mode, statistics, and game-mode events. This optional bridge is source evidence only; it is not documented as a public macOS API and may belong to a host Xbox app integration.

### Video

Source-level video controls include a requested resolution alias, software-rendering selection, HEVC enablement, and decoder modes named `MSE`, `Software`, `WebCodecs`, and `Auto`. Stream statistics include frame, decode, jitter, ping, packet-loss, and buffer-related fields. The client can report first-frame-rendered and video-size changes.

What is **not established**: the live session codec, stream resolution/bitrate limits for a Mac, HDR behavior, exact RTP payload/packetization, decoder fallback policy, frame pacing, or whether a particular title/session receives HEVC. These require a real session and the private service’s negotiated configuration.

For a native macOS renderer, Apple provides [VideoToolbox hardware decode](https://developer.apple.com/documentation/videotoolbox) and CoreVideo pixel buffers, which can feed a Metal renderer. That covers a possible native decode/display stage; it does not replace Xbox signaling, transport, stream keys, or the Xbox-specific media framing.

### Game audio and microphone

The client’s audio configuration has fields for stereo/mono mode, output-device selection, input-device selection, game volume, hardware audio decoding, `enableGameChat`, and `enableMicrophone`. The stream session has microphone enabled/muted state and capture-state events; the client UI exposes a microphone toggle and chat/party controls.

The source separately implements a **local microphone test** with `getUserMedia`, mono capture, 24 kHz, 16-bit, and echo cancellation. That test is not evidence that the gameplay microphone transport uses the same format. The in-session mic packet format, voice codec, channel, mute synchronization, echo/noise processing, and party-vs-game chat routing remain unknown.

macOS requires a microphone purpose string, audio-input entitlement, and user consent before capture ([Apple authorization guide](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)). PixelCloudX has not requested microphone access or opened an audio input. A future implementation should request access only after the player deliberately enables voice chat and should honor system mute, selected input device, and session mute state.

PixelCloudX includes incoming WebRTC audio playback through the native WebRTC audio device module. Live synchronization, output-device changes, and audio quality have not been exercised in a game session. Voice capture and chat are separate work; native input/output can use [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine), but the private Xbox chat framing and mute/session behavior still need implementation.

### Controller and other gameplay input

The Xbox site’s input/session configuration includes:

- Gamepad enablement, gamepad channel version, gamepad transformer, polling interval, and minimum input-frame interval.
- Vibration/input-feedback handling, controller add/remove events, and queued controller connection changes while the control channel is unavailable.
- Keyboard input, mouse movement/buttons, relative or absolute pointer mode, cursor changes, and client-rendered cursor support.
- Touch input and downloadable touch-adaptation bundles.
- Optional sensor input and sensor polling rate.
- Virtual mouse/keyboard, fullscreen state, and an unreliable-input/retransmission option.

The stream adapter routes gamepad snapshots to an `inputChannel`; keyboard, pointer, mouse, and sensor events have separate send methods. A `controlChannel` reports gamepad connection changes and accepts input-feedback callbacks. PixelCloudX implements the source-derived legacy gamepad report format, including button masks, sequence numbers, axes, triggers, and negotiated version fields. The server’s acceptance, frame timing, input acknowledgments, and vibration payload remain unverified in a live game.

Microsoft says most games require a wired or wireless gamepad; some games support mouse/keyboard and some support touch. The web client fetches title-specific input configuration, so a native UI should not assume every game accepts every device. Microsoft’s browser announcement also says players can switch between supported keyboard/mouse and controller input during a game.

## Native implementation currently present in PixelCloudX

### Native gameplay path

PixelCloudX independently implements Microsoft device-code sign-in, Xbox user/XSTS exchange, GSSV offering login, catalog loading, cloud-session allocation, HTTP SDP/ICE signaling, a WebRTC peer connection, native video rendering, incoming game audio, and legacy gamepad reports over the input data channel. The app UI keeps gameplay in its own window. The session and signaling contract remains private and has not been accepted by Xbox in a live gameplay attempt from this checkout.

Apple's Game Controller framework supplies controller snapshots. PixelCloudX serializes controller state into the source-derived input report format and sends connection changes over the control data channel. This code is independently authored; no third-party Xbox streaming client implementation is included. The native WebRTC engine is a separately declared package dependency.

Microphone capture, voice chat, mouse/keyboard forwarding, haptics, touch adaptation, reconnection/resume, and stream telemetry are not currently implemented. The existing guide supports ⌘G, audio mute, controller status, resume, and end-stream actions. ⌘Q prompts before ending an active session.

## Source index

### Xbox web client modules inspected

These hashed asset names identify the files inspected from the current `play.xbox.com` deployment. Hashes and behavior may change:

- `assets/entry.client-ozcu9736.js`
- `assets/PlayService-mlq8q0aq.js`
- `assets/gamestream-auth-service-jf1wog0n.js`
- `assets/StreamSessionRequest-kz1a471s.js`
- `assets/StreamSessionConfiguration-dt4dv0vl.js`
- `assets/GameStreamingApi-hmuizdnf.js`
- `assets/StreamClient-bh0j7shu.js`
- `assets/gameStreamAdapter-d4ofgdmd.js`
- `assets/GameStreamBootstrapper-d82rtzb9.js`
- `assets/GameStreamDialog-oo4rmdco.js`
- `assets/useMicrophone-htyg0q4s.js`
- `assets/pinnedControllerScanner-g4s36me2.js`
- `assets/gamepad-i0463kfv.js`

### Official references

- [Xbox Cloud Gaming](https://www.xbox.com/en-US/cloud-gaming)
- [Getting Started with Xbox Cloud Gaming](https://news.xbox.com/en-us/2025/12/19/getting-started-with-xbox-cloud-gaming/)
- [Xbox May Update: mouse and keyboard support for Cloud Gaming](https://news.xbox.com/en-us/2024/05/15/xbox-may-update-2024/)
- [Microsoft identity platform app types](https://learn.microsoft.com/en-us/entra/identity-platform/v2-app-types)
- [Microsoft identity platform authorization-code flow](https://learn.microsoft.com/en-us/azure/active-directory/develop/v1-protocols-oauth-code)
- [GDK Cloud Aware APIs](https://learn.microsoft.com/en-us/gaming/gdk/docs/features/common/game-streaming/game-streaming-am-i-streaming?view=gdk-2604)
- [Setting up an Xbox Development Kit for streaming](https://learn.microsoft.com/en-us/gaming/gdk/docs/features/common/game-streaming/game-streaming-setup-xbox-developer-kit?view=gdk-2604)
- [GDK XGameStreaming API reference](https://learn.microsoft.com/en-us/gaming/gdk/docs/reference/system/xgamestreaming/xgamestreaming_members?view=gdk-2604)
- [Apple Game Controller: GCController](https://developer.apple.com/documentation/gamecontroller/gccontroller)
- [Apple Game Controller: extended gamepad profile](https://developer.apple.com/documentation/gamecontroller/gcextendedgamepad)
- [Apple VideoToolbox](https://developer.apple.com/documentation/videotoolbox)
- [Apple AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- [Apple microphone authorization and entitlements](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)

## Current PixelCloudX implementation status

**Updated:** 2026-10-28

### Microsoft account sign-in

PixelCloudX independently implements Microsoft device-code authorization with Foundation `URLSession`. It requests `xboxlive.signin openid profile offline_access`, shows the code in the app, polls Microsoft's token endpoint, refreshes expiring access tokens, and stores OAuth values in `Application Support/PixelCloudX/microsoft-auth.json`. The JSON is unencrypted; the directory is set to mode `0700` and the file to `0600`. No Keychain API is used.

After OAuth, `XboxCloudAccountService` exchanges the Microsoft token with `user.auth.xboxlive.com`, requests an XSTS token for the GSSV relying party, then logs in to the `xgpuweb` and `xgpuwebf2p` offerings through `/v2/login/user`. The GSSV `gsToken` authenticates HTTP service requests. The `/connect` body requires a separate Microsoft cloud-transfer token, acquired through `login.live.com/oauth20_token.srf` with scope `service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN`. The earlier claim that GSSV should also fill the `/connect` body was incorrect. Account-title enrichment is best-effort and does not discard a valid offering session if `/v2/titles` fails.

The configured client ID in `App/Info.plist` is a public app-registration value. It is not source code or a secret, but it is not owned by PixelCloudX; replace it with a project-owned registration before distribution.

### Public catalog

The app requests the public “All games” feed from:

```text
GET https://catalog.gamepass.com/sigls/v2?id=29a81209-df6f-41fd-a528-2ae6b91f719c&language={language}&market={market}
```

The list returns product IDs without requiring a user token. The app hydrates IDs in bounded batches using:

```text
POST https://catalog.gamepass.com/v3/products?market={market}&language={language}&hydration=RemoteHighSapphire0
Content-Type: application/json
ms-cv: 0.0

{"Products":["<product-id>", ...]}
```

The current catalog implementation hydrates product metadata and filters to cloud-playable products. It also requests account-title data through private `/v2/titles` when the account service succeeds. Account entitlements can filter the “My Xbox games” view, but catalog results and account-title data are not a complete entitlement guarantee.

#### Live endpoint check (2026-10-28)

- The public SIGL feed returned HTTP 200 with 565 entries for `US` / `en-US` (one metadata record plus product IDs).
- Product hydration returned HTTP 200 with eight product records for an eight-ID sample when `ms-cv: 0.0` and the Xbox calling-app headers were present.
- The endpoint check validates the public catalog request shape only. It does not validate private account service or gameplay calls.

These are public web-client catalog feeds, not a documented stable third-party contract. A catalog result does not confirm entitlement.

### Cloud session, media, and input

The native stream path in `Features/Streaming/XboxCloudPlayService.swift` requests `/v5/sessions/cloud/play` with `nanoVersion` `V3;WebrtcTransport.dll`, polls session state, obtains and posts the Microsoft cloud-transfer token to `/connect`, and reads `/configuration`. GSSV remains the HTTP bearer credential. It posts an SDP offer and polls the answer through `/{sessionPath}/sdp`. It sends the SDP offer and ICE candidate object directly as JSON HTTP bodies; the Xbox client's `Data` property is an internal wrapper and is not serialized again on the wire. It then applies remote ICE records to WebRTC. A keepalive task maintains the session; stopping or failed/cancelled provisioning sends `DELETE /{sessionPath}`.

`Features/Streaming/XboxCloudStreamController.swift` negotiates the current source-observed control/input/message/chat data channels. The input path serializes gamepad buttons, D-pad, sticks, triggers, sequence numbers, and negotiated version fields. Controller input is polled from Apple GameController and sent in-app over WebRTC; it is not simulated with keyboard events. The renderer uses `RTCMTLNSVideoView`; incoming WebRTC audio is handled by the WebRTC audio device module. This is source-derived and compile-validated, not live-session validated.

The Xbox client’s source also indicates more extensive input, microphone, reconnect, telemetry, haptic, touch, and game-chat paths. PixelCloudX does not currently implement microphone capture/voice chat, keyboard/mouse forwarding, touch adaptation, haptics, reconnect/resume, or stream telemetry. No microphone permission is requested.

### Source provenance and implementation boundary

The earlier imported RayxCloud-derived app code and package tree were removed. The current Xbox account/session/client implementation in PixelCloudX was independently written from endpoint and protocol observations; no Xbox web client or third-party cloud-gaming client source is included. The app has one third-party runtime dependency: the `stasel/WebRTC` 155.0.0 binary package, which contains the Google WebRTC engine. Its BSD notices are bundled with the app; see [third-party notices](THIRD_PARTY_NOTICES.md).

### Remaining live-playback gates

- Complete a Microsoft sign-in inside PixelCloudX and verify the resulting OAuth refresh lifecycle.
- Confirm Xbox accepts the XSTS/GSSV account flow and the Microsoft cloud-transfer-token `/connect` exchange.
- Launch a game and observe provisioning, SDP/ICE completion, a video frame, game audio, and controller movement/buttons in the game.
- Verify session cleanup on user exit and ⌘Q, and reconnect behavior after network interruptions.
- Implement and validate microphone/party voice, haptics, keyboard/mouse, touch adaptation, and session telemetry if needed.
- Replace the public client ID with a PixelCloudX-owned registration before distribution.

## Supported-contract audit

**Updated:** 2026-10-28

The current app includes native implementations of Microsoft OAuth, Xbox identity/GSSV calls, public catalog hydration, cloud session provisioning, HTTP signaling, WebRTC media, and controller forwarding. However, Microsoft’s published developer documentation does not expose a supported consumer macOS API for Cloud Gaming launch or stream negotiation. PixelCloudX’s GSSV/session/signaling path is reverse-engineered, private, and may stop working as Xbox changes its web client or service enforcement. A successful compile or public catalog response is not evidence of live gameplay acceptance.

| Surface | Current implementation | Contract status |
| --- | --- | --- |
| Microsoft identity | Independently implemented device-code OAuth; tokens stored as local plaintext JSON | Device-code OAuth is documented for desktop apps. PixelCloudX should use its own app registration before distribution; Microsoft recommends MSAL for native applications ([MSAL for iOS/macOS](https://github.com/AzureAD/microsoft-authentication-library-for-objc), [MSAL flows](https://learn.microsoft.com/en-us/entra/identity-platform/msal-authentication-flows)). |
| Xbox identity and offering login | Implemented with Xbox user/XSTS and GSSV requests | Calls use private service behavior; published Xbox services authentication docs do not establish a supported third-party Mac consumer-client contract ([Xbox services authentication](https://learn.microsoft.com/en-us/gaming/gdk/docs/services/fundamentals/s2s-auth-calls/service-authentication/live-xbox-live-authentication?view=gdk-2510)). |
| Game catalog and account titles | Public SIGL/product hydration plus best-effort GSSV `/v2/titles` | Public feeds are not a stable consumer catalog API. Private title/account shapes may change; catalog presence does not guarantee launch entitlement. |
| Cloud launch and gameplay | Native cloud session, HTTP signaling, WebRTC media, and controller input implemented | No supported consumer macOS client SDK or public launch/stream contract was found. Live gameplay is not yet verified. Microsoft’s streaming docs cover the game/title and developer-kit side, not a consumer client implementation ([game-streaming overview](https://learn.microsoft.com/en-us/gaming/gdk/docs/features/common/game-streaming/game-streaming-overview?view=gdk-2604)). |

The documented Store APIs do not provide a drop-in replacement for the cloud catalog. `XStoreQueryAssociatedProductsAsync` returns products associated with the current title and is supported on Windows and Xbox consoles. The Store Collections APIs query ownership for a publisher's products; Game Pass checks require publisher authorization. The UWP Collections flow also requires a Microsoft Store ID key generated through UWP client code. These contracts do not enumerate all Cloud Gaming titles for an unrelated macOS client ([XStore query reference](https://learn.microsoft.com/en-us/xbox/gdk/docs/reference/system/xstore/functions/xstorequeryassociatedproductsasync?view=gdk-2604), [publisher Store services](https://learn.microsoft.com/en-us/xbox/gdk/docs/store/commerce/service-to-service/service-to-service-nav?view=gdk-2510), [UWP collections query](https://learn.microsoft.com/en-us/windows/uwp/monetize/query-for-products), [Store ID key requirements](https://learn.microsoft.com/en-us/windows/uwp/monetize/view-and-grant-products-from-a-service)).

An app-owned MSAL registration can make Microsoft's personal-account sign-in standards-based. It does not grant access to Xbox's private GSSV catalog or Cloud Gaming launch services. PixelCloudX has an independently implemented private-service path, but its current account authorization and gameplay acceptance remain unverified in a live session.
