# Native playback crash and controller startup

## Confirmed crash trigger

The Apple reports show a later failure in `swift_task_isCurrentExecutorWithFlagsImpl`, SwiftUI hover routing, or MenuBarClientCore. Disabling the video surface, removing hover handlers, changing launch mode, and AddressSanitizer did not resolve it.

LLDB exposed the earlier failure on October 28 at 20:59:42: `RTCIceCandidate.initWithSdp` raised `NSInternalInconsistencyException`, `Invalid parameter not satisfying: sdp.length`. PixelCloudX converted Xbox's `a=end-of-candidates` marker into an empty candidate. The native API requires nonempty SDP; see [WebRTC's candidate initializer](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/api/peerconnection/RTCIceCandidate.mm).

The exception escaped the Swift asynchronous startup task and was caught by AppKit. The same reproduction subsequently failed in the Swift executor check at address `0x7c8`. The visible executor crash was downstream of the invalid native candidate.

`NativeICECandidate.decode` now discards raw and JSON-wrapped end markers, empty strings, and empty `a=` values before constructing a native candidate. Malformed JSON remains a Swift error. Tests call the actual native initializer for valid candidates and verify all sentinel cases.

## Native lifecycle

- Factory creation, negotiation, data sends, renderer attachment, and peer shutdown run through one serial native execution queue.
- Delegate callbacks return to the main dispatch queue and verify the active peer/channel identity.
- The track and renderer remain strongly owned through explicit detachment. Late native creation is cleaned up during cancellation, and shutdown drains queued native work.
- A decoded-frame sink establishes readiness. Receiving a track alone no longer marks playback as running.
- Sanitized transport counters distinguish received bytes, decoded frames, and dropped frames without logging tokens, SDP, candidate addresses, or message payloads.
- A first-frame deadline prevents an endless post-signaling spinner. A stalled active video track requests a fresh keyframe.

## Channel and input corrections

Protocol research included the current Xbox web client's native streaming bundle, inspected locally after retrieval from Xbox, plus native WebRTC source and reference client implementations. The app keeps its own Swift implementation and embeds no browser.

The control channel now sends its startup authorization message. After `HandshakeAck`, the message channel sends client configuration, installation identity, orientation, touch capabilities, preferred dimensions, and the title-unconstrain transaction. NUL padding is removed before decoding JSON. Server disconnect messages become a visible reason, including replacement by another session.

Gamepad reports now contain the physical or virtual activity masks corresponding to their active controls. Packet tests cover versions 1, 2, 6, 7, 8, and 10, including sequence fields, button masks, activity masks, releases, and metadata.

Two connection bookkeeping bugs were corrected:

1. Polling before the control channel opened could advance the connected state despite sending no announcement. `StreamGamepadAnnouncer` advances only when the channel is open and the announcement is queued successfully.
2. Multiple local devices could repeatedly disconnect/reconnect the one streamed gamepad. Physical and keyboard state now feed one connection state.

The optional keyboard gamepad uses local AppKit events. It releases keyboard state on focus loss, pauses for the Guide, preserves Command shortcuts, and combines with the first physical controller. Keyboard mappings are visible in the Guide. It does not install global event taps or require Input Monitoring permissions.

## Validation and remaining acceptance

- The corrected native debug run decoded 1920×1080 video at approximately 60 fps without the Objective-C exception.
- The subsequently installed Release process streamed for more than three minutes, delivered over 11,000 decoded frames with zero reported drops, and kept the Guide responsive. Ending the stream and closing the main window terminated the process.
- The most recent user-supplied crash report identified the older installed executable, UUID `A94748FE-A96A-39A6-9719-883149D2DBB7`; it preceded replacement of that installed copy with the candidate fix.
- The user reported that input did not work in the earlier run. The announcement race and activity-mask changes have isolated regression coverage, but controller-driven gameplay after the final changes still needs live acceptance.
- Live UI, audio, and gameplay testing stopped when the user asked to watch their show without interruption. Subsequent work used source inspection, mocked requests, and background builds. The final app is installed without being launched.

These observations establish a repaired startup path and sustained native video in the tested runs. They do not establish a supported Xbox consumer integration or verified end-to-end controller gameplay for the final build.

## Final build record

Release arm64 build **2** passed. The installed app at `~/Applications/PixelCloudX.app` passed strict deep signature verification, and its executable SHA-256 matched the built Release executable. It was left closed.

All regression suites passed, including pre-open controller announcements and packet versions 1/2/6/7/8/10. The final 501-title catalogue fixture benchmark was 91 ms.

The final build reused `~/Library/Developer/Xcode/DerivedData/PixelCloudX-benbkxshihsrbsfurutctuzqjtpy`, growing from **859628 KiB to 859692 KiB** (**+64 KiB**, final size **839.5 MiB**). No shared cache or build tree was cleaned.
