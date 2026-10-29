# Microphone input

During a connected stream, **Command-M** toggles the microphone. The same control appears in the stream HUD, its compact overlay after the HUD hides, and the Guide. The mic indicator stays visible while the HUD is hidden. Game-audio mute is independent.

The microphone starts off for every stream. First use requests macOS microphone permission. Denied permission or a missing input device produces an inline explanation and, for permission denial, a link to the system microphone settings. The microphone uses the system's default audio input.

## Native path

The initial stream offer advertises RTP voice chat (`chatStream` version 1), reserves a send/receive audio section with an inactive encoding and no capture track, and checks the server capability before enabling the microphone control. See [the subsequent recovery and live evidence](INPUT_AND_MIC_RECOVERY.md).

1. The UI records user intent and requests audio authorization through `AVCaptureDevice` only on an explicit enable.
2. Native WebRTC creates an initially disabled audio source/track with echo cancellation, noise suppression, and automatic gain control requested. It adds the track to the existing peer and disables the outgoing encoding during setup.
3. The first enable sends a new SDP offer with an incremented request ID and `configuration.isMediaStreamsChatRenegotiation = true`, matching the current Xbox web client's microphone negotiation. HTTP polling ignores answers belonging to older request IDs.
4. After the matching answer is applied, the transport verifies that the audio transceiver negotiated a sending direction. It then enables the outgoing encoding and track if the user still wants the mic on. Native WebRTC owns Core Audio capture, Opus encoding, and RTP transport.
5. Muting revokes the transmission-intent gate, disables the RTP encoding, disables and detaches the capture track, and releases the source. The negotiated sender slot remains available, allowing later enables without another SDP exchange.

Microphone audio uses the peer's RTP audio sender. The legacy `chatV1` data channel does not carry captured microphone bytes in this implementation. No browser engine, media recorder, external encoder, audio file, or microphone recording log is used.

The app declares `NSMicrophoneUsageDescription` and the sandbox `com.apple.security.device.audio-input` entitlement. Capture remains off until the user enables it. The app does not request permission at startup or restore an enabled microphone from a previous session.

## Races and cleanup

Permission results and negotiation callbacks are tied to a stream session token. Muting during permission or SDP setup cannot activate a microphone afterward. Rapid off/on toggles reconcile the latest intent. Ending a stream cancels the mic worker, disables capture, and releases the sender before peer teardown. App quit does not wait for an unanswered system permission sheet.

A microphone negotiation failure rolls the local offer back when needed and reports a mic-specific error. It does not deliberately end the game stream. A disconnected input device with no replacement clears microphone intent and offers retry.

Command-M is registered in the app's Window menu. The native Minimize action remains available, with its conflicting Command-M equivalent removed. The Guide scrolls its settings so microphone error messages cannot hide Resume or End stream.

## Verification

Regression tests cover default-off behavior, permission denial and retry, no input device, mute during permission/setup, repeated toggles, canceled/replaced streams, mic-specific failure cleanup, and shortcut reservation. Mocked HTTP tests cover the renegotiation envelope and stale SDP answers. Native SDK tests generate an Opus send/receive offer with an initially disabled outgoing encoding and verify rollback using a separate data-only peer.

Tests do not request microphone permission, install an audio offer, capture room audio, or transmit voice to Xbox. Remote audibility, hardware routing, acoustic echo cancellation, and actual recording-device release still require a live voice-chat check. A successful build or generated offer is not remote audio acceptance. Sanitized outgoing RTP packet/byte counters are available in diagnostics for that check.

Protocol research used Xbox's current streaming JavaScript retrieved in the preceding playback investigation and the [xbox-xcloud-player microphone implementation](https://github.com/unknownskl/xbox-xcloud-player/blob/main/src/channel/chat.ts). Native sender behavior was checked against [WebRTC RTP sender source](https://webrtc.googlesource.com/src/+/refs/heads/main/pc/rtp_sender.cc) and [voice engine source](https://webrtc.googlesource.com/src/+/refs/heads/main/media/engine/webrtc_voice_engine.cc). Permission setup follows [Apple's microphone usage-description documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription).

## Build and restart record

Release arm64 build **3** passed and was installed at `~/Applications/PixelCloudX.app`. Strict deep signature validation passed, the signed audio-input entitlement and microphone purpose string were verified, and the installed executable hash matched the Release output. The app was restarted at the user's request with microphone capture off. The Window menu contains the microphone command; Command-M outside a stream leaves the catalogue open and does not minimize the window or request permission.

The existing DerivedData path was reused: `~/Library/Developer/Xcode/DerivedData/PixelCloudX-benbkxshihsrbsfurutctuzqjtpy`. It grew from **859692 KiB to 862136 KiB** (**+2444 KiB**, about **2.4 MiB**) across this implementation and its tests. No build tree or shared cache was cleaned.
