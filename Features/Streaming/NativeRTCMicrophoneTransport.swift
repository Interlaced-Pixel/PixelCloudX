import Foundation
@preconcurrency import WebRTC

enum NativeMicrophoneError: LocalizedError {
    case unavailable, rejected
    var errorDescription: String? {
        switch self {
        case .unavailable: "The microphone connection is no longer available. Try again after the stream connects."
        case .rejected: "Xbox did not accept microphone audio for this session. Game audio remains available."
        }
    }
}

/// Native WebRTC owns Core Audio capture, processing, Opus encoding, and RTP.
/// All peer/sender/track access is serialized with the rest of the native peer.
final class NativeRTCMicrophoneTransport: StreamMicrophoneTransport, @unchecked Sendable {
    private let peer: RTCPeerConnection
    private let negotiate: @Sendable () async throws -> Void
    private let intentLock = NSLock()
    private var enabledIntent = false
    // NativeRTCExecutor queue only:
    private var sender: RTCRtpSender?
    private var track: RTCAudioTrack?
    private var negotiated = false
    private var closed = false

    init(peer: RTCPeerConnection, negotiate: @escaping @Sendable () async throws -> Void) {
        self.peer = peer
        self.negotiate = negotiate
    }

    func setEnabledIntent(_ enabled: Bool) {
        intentLock.lock(); enabledIntent = enabled; intentLock.unlock()
        if !enabled { NativeRTCExecutor.shared.enqueue { self.detachCapture() } }
    }
    private func mayTransmit() -> Bool {
        intentLock.lock(); defer { intentLock.unlock() }
        return enabledIntent
    }

    func prepare() async throws {
        let processing = await MainActor.run { AppSettings.shared.values }
        let candidate = await NativeRTCExecutor.shared.makeMicrophoneTrack(echoCancellation: processing.echoCancellation,
            noiseSuppression: processing.noiseSuppression, automaticGain: processing.automaticGain)
        let needsNegotiation = try await NativeRTCExecutor.shared.performThrowing {
            guard !self.closed, self.peer.signalingState != .closed, let candidate else { throw NativeMicrophoneError.unavailable }
            // A canceled enable must not attach a capture source later.
            guard self.mayTransmit() else { return false }
            candidate.isEnabled = false
            self.track = candidate
            if let sender = self.sender { sender.track = candidate }
            else { self.sender = self.peer.add(candidate, streamIds: ["pixelcloudx-microphone"]) }
            guard let sender = self.sender, sender.track?.isEqual(candidate) == true else {
                self.detachCapture(); throw NativeMicrophoneError.unavailable
            }
            guard Self.setEncodingActive(false, on: sender) else {
                self.detachCapture(); throw NativeMicrophoneError.unavailable
            }
            return !self.negotiated
        }
        guard needsNegotiation else { return }
        do {
            try await negotiate()
            try await NativeRTCExecutor.shared.performThrowing {
                guard !self.closed, let sender = self.sender,
                      let transceiver = self.peer.transceivers.first(where: { $0.sender.senderId == sender.senderId }) else {
                    throw NativeMicrophoneError.unavailable
                }
                var direction = RTCRtpTransceiverDirection.inactive
                guard transceiver.currentDirection(&direction), direction == .sendRecv || direction == .sendOnly else {
                    throw NativeMicrophoneError.rejected
                }
                self.negotiated = true
                if !self.mayTransmit() { self.detachCapture() }
            }
        } catch {
            await NativeRTCExecutor.shared.perform { self.detachCapture() }
            throw error
        }
    }

    func activate() async throws -> Bool {
        try await NativeRTCExecutor.shared.performThrowing {
            guard !self.closed, self.negotiated else { throw NativeMicrophoneError.unavailable }
            guard self.mayTransmit() else { self.detachCapture(); return false }
            guard let track = self.track, self.sender?.track?.isEqual(track) == true else { throw NativeMicrophoneError.unavailable }
            guard let sender = self.sender, Self.setEncodingActive(true, on: sender) else { throw NativeMicrophoneError.unavailable }
            guard self.mayTransmit() else { self.detachCapture(); return false }
            track.isEnabled = true
            return true
        }
    }

    private func detachCapture() {
        track?.isEnabled = false
        // A disabled track alone can still leave the audio device recording.
        // Stop the RTP encoding as well as releasing the capture source.
        if let sender { _ = Self.setEncodingActive(false, on: sender) }
        sender?.track = nil
        track = nil
    }

    static func setEncodingActive(_ active: Bool, on sender: RTCRtpSender) -> Bool {
        let parameters = sender.parameters
        guard !parameters.encodings.isEmpty else { return false }
        for encoding in parameters.encodings { encoding.isActive = active }
        sender.parameters = parameters
        return sender.parameters.encodings.allSatisfy { $0.isActive == active }
    }
    func shutdown() async {
        setEnabledIntent(false)
        await NativeRTCExecutor.shared.perform {
            self.closed = true
            self.detachCapture()
            self.sender = nil
            self.negotiated = false
        }
    }
}
