import AppKit
import Foundation
import WebRTC

@main @MainActor
private enum StreamVideoSurfaceTests {
    static func main() async {
        _ = NSApplication.shared
        for marker in ["a=end-of-candidates", "end-of-candidates", "", "  ", "a="] {
            let json = String(data: try! JSONSerialization.data(withJSONObject: ["candidate": marker]), encoding: .utf8)!
            precondition(try! NativeICECandidate.decode(json) == nil, "End markers must never create an empty native candidate")
        }
        precondition(try! NativeICECandidate.decode("{}") == nil)
        let candidate = try! NativeICECandidate.decode(#"{"candidate":"a=candidate:1 1 UDP 2122260223 192.0.2.1 50000 typ host","sdpMLineIndex":1,"sdpMid":"video"}"#)
        precondition(candidate?.sdp.hasPrefix("candidate:") == true)
        precondition(candidate?.sdpMLineIndex == 1 && candidate?.sdpMid == "video")
        do { _ = try NativeICECandidate.decode("not-json"); preconditionFailure("Malformed JSON must throw") } catch {}
        let coordinator = StreamVideoView.Coordinator()
        weak var retainedView: PassiveMetalVideoView?
        weak var retainedTrack: RTCVideoTrack?
        autoreleasepool {
            let factory = RTCPeerConnectionFactory()
            let track = factory.videoTrack(with: factory.videoSource(), trackId: "surface-test")
            let view = PassiveMetalVideoView(frame: NSRect(x: 0, y: 0, width: 128, height: 72))
            precondition(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
            precondition(!view.acceptsFirstResponder)
            coordinator.attach(track, to: view)
            coordinator.attach(track, to: view)
            retainedView = view
            retainedTrack = track
        }
        await NativeRTCExecutor.shared.perform { precondition(!Thread.isMainThread) }
        precondition(retainedView != nil && retainedTrack != nil, "Registered renderer and track must stay alive until detach")
        coordinator.attach(nil, to: nil)
        await NativeRTCExecutor.shared.perform { precondition(!Thread.isMainThread) }
        precondition(retainedTrack == nil, "Detached track must be released")
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let delegate = MicrophoneOfferDelegate()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let peer = await NativeRTCExecutor.shared.makePeer(configuration: configuration, constraints: constraints, delegate: delegate)!
        let microphone = await NativeRTCExecutor.shared.makeMicrophoneTrack()!
        precondition(!microphone.isEnabled, "A microphone track must start disabled")
        let sender = await NativeRTCExecutor.shared.perform { peer.add(microphone, streamIds: ["microphone-offer-test"]) }!
        let inactive = await NativeRTCExecutor.shared.perform { NativeRTCMicrophoneTransport.setEncodingActive(false, on: sender) }
        precondition(inactive, "A microphone sender must be able to disable its capture encoding before negotiation")
        // Generate SDP only. No local/remote description is installed on this
        // audio peer, so this test does not start a capture session or RTP.
        let offer: RTCSessionDescription = try! await withCheckedThrowingContinuation { continuation in
            NativeRTCExecutor.shared.enqueue {
                peer.offer(for: constraints) { offer, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: offer!) }
                }
            }
        }
        precondition(offer.sdp.contains("m=audio") && offer.sdp.contains("a=sendrecv") && offer.sdp.lowercased().contains("opus/48000"))
        await NativeRTCExecutor.shared.perform { sender.track = nil; peer.close() }

        // A separate data-only peer exercises rollback without an audio track.
        let rollbackPeer = await NativeRTCExecutor.shared.makePeer(configuration: configuration, constraints: constraints, delegate: delegate)!
        let dataChannel = await NativeRTCExecutor.shared.perform {
            rollbackPeer.dataChannel(forLabel: "rollback-test", configuration: RTCDataChannelConfiguration())
        }
        let dataOffer: RTCSessionDescription = try! await withCheckedThrowingContinuation { continuation in
            NativeRTCExecutor.shared.enqueue {
                rollbackPeer.offer(for: constraints) { offer, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: offer!) }
                }
            }
        }
        for description in [dataOffer, RTCSessionDescription(type: .rollback, sdp: "")] {
            try! await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NativeRTCExecutor.shared.enqueue {
                    rollbackPeer.setLocalDescription(description) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
        }
        let stable = await NativeRTCExecutor.shared.perform { rollbackPeer.signalingState == .stable }
        precondition(stable)
        await NativeRTCExecutor.shared.perform { dataChannel?.close(); rollbackPeer.close() }
        print("PASS: native ICE end-marker/empty handling, candidate fields, malformed input, serial native execution, renderer ownership and detachment")
        print("PASS: native disabled microphone track produces an Opus send/receive offer; failed negotiation can roll back to stable (no capture/RTP started)")
    }
}

private final class MicrophoneOfferDelegate: NSObject, RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
