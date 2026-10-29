# Input and microphone recovery — October 29, 2026

The reported build detected a DualShock but did not advance the game's title screen. Enabling the microphone timed out waiting for an SDP response.

## Changes

The initial negotiation now advertises `chatStream` version 1, in addition to the legacy chat channel. It reserves audio send/receive and video receive-only media sections, matching Xbox's current web client. The reserved audio sender has its encoding disabled; no capture source is attached at startup. Microphone permission/capture still starts only after explicit enable. The microphone offer advertises the media-stream renegotiation flag. A response without an optional request ID is accepted only when its SDP differs from the prior answer; explicitly mismatched or stale responses remain rejected.

Input authorization now waits for all required channels and the message handshake, before announcing the merged controller and sending gamepad reports. Channel creation follows the web client's order. Controller profiles are sampled at the input cadence as well as through change callbacks, and background controller monitoring is explicit. The Guide sends neutral input and pauses gameplay input while open. Sanitized diagnostics distinguish samples, queued reports, send rejection, and input-channel server replies; credentials, SDP, candidates, and voice content are excluded.

Independent binary fixtures were generated with a fixed clock and controller state using Xbox's web-client serializer. They match the Swift encoder across input versions 1, 2, 6, 7, 8, and 10, including physical/virtual activity and release states. The application contains its own Swift implementation and does not bundle that JavaScript.

App quit was also corrected to enter AppKit termination from the main dispatch queue after the stream-cleanup Swift task finishes. Entering a nested termination loop while holding MainActor could otherwise prevent the delegate's asynchronous termination cleanup from running.

## Live evidence and limits

The native Star Wars Outlaws session decoded 2560×1440 video. After the revised handshake, Xbox returned input metadata and vibration messages, and a keyboard A-button press advanced past the title screen. The user subsequently confirmed: **“Controller works now.”** This is stronger evidence than packet tests alone.

The repaired microphone reached its live state and produced outgoing RTP packets without the previous signaling timeout. The reserved sender's outgoing packet count stayed at zero while the mic was off. Remote voice-chat audibility, input-device routing changes, and acoustic processing quality still require a voice-chat acceptance check; packet transmission alone is not that check.

These observations establish the tested private-protocol behavior, not a supported Microsoft consumer integration or a guarantee for every title/account/region.
