import Foundation
@preconcurrency import WebRTC

/// Native WebRTC calls can synchronously enter its signaling/worker threads.
/// Keep those calls out of Swift tasks running on the application's main actor.
final class NativeRTCExecutor: @unchecked Sendable {
    static let shared = NativeRTCExecutor()
    private let queue = DispatchQueue(label: "com.jayian.pixelcloudx.webrtc", qos: .userInteractive)
    private var factory: RTCPeerConnectionFactory?

    func enqueue(_ operation: @escaping () -> Void) {
        queue.async(execute: DispatchWorkItem(block: operation))
    }

    func perform<T>(_ operation: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            enqueue { continuation.resume(returning: operation()) }
        }
    }

    func performThrowing<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func makeMicrophoneTrack(echoCancellation: Bool = true, noiseSuppression: Bool = true, automaticGain: Bool = true) async -> RTCAudioTrack? {
        await perform {
            guard let factory = self.factory else { return nil }
            let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: [
                "googEchoCancellation": String(echoCancellation), "googNoiseSuppression": String(noiseSuppression), "googAutoGainControl": String(automaticGain)
            ]))
            let track = factory.audioTrack(with: source, trackId: "microphone-\(UUID().uuidString)")
            track.isEnabled = false
            return track
        }
    }

    func makePeer(configuration: RTCConfiguration, constraints: RTCMediaConstraints,
                  delegate: RTCPeerConnectionDelegate) async -> RTCPeerConnection? {
        await perform {
            if self.factory == nil {
                RTCInitializeSSL()
                self.factory = RTCPeerConnectionFactory()
            }
            return self.factory?.peerConnection(with: configuration, constraints: constraints, delegate: delegate)
        }
    }
}

enum NativeICECandidate {
    static func decode(_ json: String) throws -> RTCIceCandidate? {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "a=end-of-candidates", text != "end-of-candidates" else { return nil }
        guard let data = json.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "PixelCloudX.NativeICE", code: 1, userInfo: [NSLocalizedDescriptionKey: "Xbox returned an unreadable ICE candidate."])
        }
        guard let raw = value["candidate"] as? String else { return nil }
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The browser's end-of-candidates sentinel is not an ICE candidate.
        // RTCIceCandidate asserts on empty SDP. An Objective-C exception here
        // escapes the Swift async task and leaves executor tracking corrupted.
        guard candidate != "a=end-of-candidates", candidate != "end-of-candidates" else { return nil }
        if candidate.hasPrefix("a=") {
            candidate.removeFirst(2)
        }
        guard !candidate.isEmpty else { return nil }
        let mid = value["sdpMid"] as? String
        let index = (value["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
        return RTCIceCandidate(sdp: candidate, sdpMLineIndex: index, sdpMid: mid)
    }
}
