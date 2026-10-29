import Combine
import Foundation
import GameController
@preconcurrency import WebRTC

enum XboxCloudStreamPhase: Equatable {
    case idle
    case provisioning
    case connecting
    case playing
    case failed

    var label: String {
        switch self {
        case .idle: "Ready"
        case .provisioning: "Starting game"
        case .connecting: "Connecting stream"
        case .playing: "Playing"
        case .failed: "Stream unavailable"
        }
    }
}

@MainActor
final class XboxCloudStreamController: NSObject, ObservableObject {
    @Published private(set) var phase: XboxCloudStreamPhase = .idle
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var videoTrack: RTCVideoTrack?
    @Published var isGuideVisible = false
    @Published private(set) var isMuted = false
    @Published private(set) var inputReportsSent: UInt64 = 0
    @Published private(set) var videoDimensions = CGSize(width: 1920, height: 1080)
    @Published private(set) var statisticsSummary = "Waiting for stream statistics"
    private var settingsSubscription: AnyCancellable?
    private var preferences = AppSettings.shared.values
    let microphone = StreamMicrophoneController()

    private let service = XboxCloudPlayService()
    private var account: XboxCloudAccountSession?
    private var offering: XboxCloudOfferingSession?
    private var cloudSession: XboxCloudPlaySession?
    private var peerConnection: RTCPeerConnection?
    private var controlChannel: RTCDataChannel?
    private var inputChannel: RTCDataChannel?
    private var messageChannel: RTCDataChannel?
    private var chatChannel: RTCDataChannel?
    private weak var controllerInput: ControllerInputService?
    private var startupTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private var frameObserver: StreamFrameObserver?
    private var mediaReadyAt: TimeInterval?
    private var openChannels: Set<ObjectIdentifier> = []
    private var localICECandidates: [[String: Any]] = []
    private var inputVersion = 1
    private var sdpRequestID = 1
    private var inputSequence: UInt32 = 0
    private var didSendClientMetadata = false
    private var didSendMessageHandshake = false
    private var didConfigureMessageChannel = false
    private var didAuthorizeControlChannel = false
    private var isClosing = false
    private var gamepadAnnouncer = StreamGamepadAnnouncer()
    private var lastGamepadState: Data?
    private var inputPacketsReceived = 0

    override init() {
        super.init()
        settingsSubscription = AppSettings.shared.$values.sink { [weak self] in self?.applyPreferences($0) }
    }

    private func applyPreferences(_ values: AppPreferences) {
        let resolutionChanged = preferences.resolution != values.resolution
        preferences = values
        isMuted = values.muted
        controllerInput?.configure(keyboard: values.keyboardEnabled, background: values.backgroundController, deadzone: values.deadzone)
        if let peerConnection {
            NativeRTCExecutor.shared.enqueue {
                for receiver in peerConnection.receivers {
                    guard let track = receiver.track as? RTCAudioTrack else { continue }
                    track.source.volume = values.volume
                    track.isEnabled = !values.muted
                }
            }
        }
        if resolutionChanged { sendVideoPreferences() }
    }

    private func sendVideoPreferences() {
        if let controlChannel, didAuthorizeControlChannel {
            sendJSON(["message": "userRequestedResolutionUpdate", "resolutionAlias": preferences.resolution.rawValue], on: controlChannel)
        }
        guard let messageChannel, didConfigureMessageChannel else { return }
        let size = preferences.resolution.dimensions
        sendMessage(target: "/streaming/characteristics/dimensionschanged", content: [
            "horizontal": 286, "vertical": 161, "preferredWidth": Int(size.width), "preferredHeight": Int(size.height),
            "safeAreaLeft": 0, "safeAreaTop": 0, "safeAreaRight": Int(size.width), "safeAreaBottom": Int(size.height),
            "supportsCustomResolution": true
        ], on: messageChannel)
    }

    var isActive: Bool {
        startupTask != nil || cloudSession != nil
    }

    func start(game: CloudGame, account: XboxCloudAccountSession, controllerInput: ControllerInputService,
               connectTokenProvider: @escaping @Sendable () async throws -> String) {
        guard !isClosing, stoppingTask == nil, startupTask == nil, cloudSession == nil else { return }
        self.account = account
        offering = account.offering(for: game)
        self.controllerInput = controllerInput
        controllerInput.configure(keyboard: preferences.keyboardEnabled, background: preferences.backgroundController, deadzone: preferences.deadzone)
        controllerInput.startStreamInput()
        isClosing = false
        errorMessage = nil
        inputSequence = 0
        inputReportsSent = 0
        inputPacketsReceived = 0
        sdpRequestID = 1
        mediaReadyAt = nil
        lastGamepadState = nil
        didSendMessageHandshake = false
        didConfigureMessageChannel = false
        didAuthorizeControlChannel = false
        isGuideVisible = false
        statusMessage = "Preparing \(game.title)…"
        phase = .provisioning
        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.launch(game: game, connectTokenProvider: connectTokenProvider)
        }
    }

    func stop() async {
        if let stoppingTask {
            await stoppingTask.value
            return
        }
        let task = Task { await performStop() }
        stoppingTask = task
        await task.value
        stoppingTask = nil
    }

    private func performStop() async {
        guard !isClosing else { return }
        isClosing = true
        await microphone.disconnect()
        let pendingStartup = startupTask
        pendingStartup?.cancel()
        startupTask = nil
        inputTask?.cancel()
        inputTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        updateGamepadConnection(hasController: false)
        sendInputNeutralState()
        closeDataChannels()
        if let peerConnection { NativeRTCExecutor.shared.enqueue { peerConnection.close() } }
        peerConnection = nil
        detachFrameObserver()
        statisticsTask?.cancel()
        statisticsTask = nil
        videoTrack = nil

        // Closing the peer also releases pending negotiation callbacks.
        // Provisioning owns its allocation until its cancellation cleanup ends.
        await pendingStartup?.value

        // Native creation may finish while cancellation is waiting. Drain and
        // release anything published after the initial teardown pass.
        closeDataChannels()
        detachFrameObserver()
        if let peerConnection { NativeRTCExecutor.shared.enqueue { peerConnection.close() } }
        peerConnection = nil
        videoTrack = nil
        statisticsTask?.cancel()
        statisticsTask = nil
        await NativeRTCExecutor.shared.perform {}

        if let cloudSession, let offering {
            await service.end(cloudSession, offering: offering)
        }
        cloudSession = nil
        account = nil
        offering = nil
        controllerInput?.stopStreamInput()
        controllerInput = nil
        statusMessage = ""
        errorMessage = nil
        phase = .idle
        isClosing = false
    }

    func toggleGuide() {
        isGuideVisible.toggle()
        controllerInput?.pauseKeyboardGamepad(isGuideVisible)
        if isGuideVisible { sendInputNeutralState() }
    }

    func toggleMute() {
        AppSettings.shared.values.muted.toggle()
    }

    private func launch(game: CloudGame, connectTokenProvider: @escaping @Sendable () async throws -> String) async {
        guard let offering else {
            startupTask = nil
            fail("Xbox Cloud Gaming is not connected for this account.")
            return
        }

        do {
            let allocatedSession = try await service.createSession(
                for: game, offering: offering, preferences: preferences.xbox, connectTokenProvider: connectTokenProvider
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, !self.isClosing, self.phase == .provisioning else { return }
                    self.statusMessage = progress
                }
            }
            guard !Task.isCancelled, !isClosing else {
                await service.end(allocatedSession, offering: offering)
                return
            }
            cloudSession = allocatedSession
            statusMessage = "Opening native WebRTC media"
            phase = .connecting
            startKeepAlive(for: allocatedSession, offering: offering)
            try await connectMedia(for: allocatedSession, offering: offering)
            guard !Task.isCancelled, !isClosing else { return }
            startupTask = nil
            inputTask = Task { [weak self] in await self?.pollControllerInput() }
        } catch is CancellationError {
            startupTask = nil
        } catch {
            startupTask = nil
            if let cloudSession {
                await service.end(cloudSession, offering: offering)
                self.cloudSession = nil
            }
            fail(error.localizedDescription)
        }
    }

    private func connectMedia(
        for cloudSession: XboxCloudPlaySession,
        offering: XboxCloudOfferingSession
    ) async throws {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceServers = (cloudSession.serverDetails.stunServerAddresses ?? [])
            .filter { $0.hasPrefix("stun:") || $0.hasPrefix("stuns:") }
            .map { RTCIceServer(urlStrings: [$0]) }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
            ],
            optionalConstraints: nil
        )
        guard let peer = await NativeRTCExecutor.shared.makePeer(configuration: configuration, constraints: constraints, delegate: self) else {
            throw XboxCloudPlayError.malformedResponse("WebRTC could not create a native peer connection.")
        }
        guard !Task.isCancelled, !isClosing else {
            await NativeRTCExecutor.shared.perform { peer.close() }
            throw CancellationError()
        }
        peerConnection = peer
        // Reserve the same media sections as Xbox's client, without creating a
        // microphone source or asking for capture permission at startup.
        await NativeRTCExecutor.shared.perform {
            let audio = RTCRtpTransceiverInit()
            audio.direction = .sendRecv
            if let reservedAudio = peer.addTransceiver(of: .audio, init: audio) {
                _ = NativeRTCMicrophoneTransport.setEncodingActive(false, on: reservedAudio.sender)
            }
            let video = RTCRtpTransceiverInit()
            video.direction = .recvOnly
            _ = peer.addTransceiver(of: .video, init: video)
        }
        await createRequiredDataChannels(on: peer)
        try Task.checkCancellation()
        startStatistics(on: peer)

        statusMessage = "Creating the native video and audio offer"
        let offer = try await makeOffer(from: peer, constraints: constraints)
        try Task.checkCancellation()
        try await setLocalDescription(offer, on: peer)
        try Task.checkCancellation()
        guard let localDescription = await NativeRTCExecutor.shared.perform({ peer.localDescription }) else {
            throw XboxCloudPlayError.malformedResponse("WebRTC did not produce a local offer.")
        }

        let offerMessage: [String: Any] = [
            "messageType": "offer",
            "requestId": 1,
            "sdp": localDescription.sdp,
            "cv": cloudSession.correlationVector.current(),
            "configuration": Self.webRTCNegotiationConfiguration
        ]
        statusMessage = "Sending the stream offer to Xbox"
        try await service.sendLocalSDP(offerMessage, for: cloudSession, offering: offering)
        statusMessage = "Waiting for Xbox to answer the stream offer"
        let answer = try await service.waitForRemoteSDP(for: cloudSession, offering: offering)
        inputVersion = Self.protocolVersion(answer.input)

        let remoteDescription = RTCSessionDescription(
            type: RTCSessionDescription.type(for: answer.sdpType),
            sdp: answer.sdp
        )
        try await setRemoteDescription(remoteDescription, on: peer)
        try Task.checkCancellation()

        await waitForLocalICE(on: peer)
        statusMessage = "Exchanging network routes with Xbox"
        await Task.yield()
        let localCandidates = localICECandidates
        let remoteCandidates = try await service.exchangeLocalICE(
            localCandidates,
            includesEndOfCandidates: await NativeRTCExecutor.shared.perform { peer.iceGatheringState == .complete },
            for: cloudSession,
            offering: offering
        )
        for candidateText in remoteCandidates {
            try addRemoteCandidate(candidateText, to: peer)
        }

        try Task.checkCancellation()
        guard !isClosing, peerConnection === peer else { throw CancellationError() }

        sendClientMetadataIfReady()
        mediaReadyAt = ProcessInfo.processInfo.systemUptime
        if phase != .playing { statusMessage = "Waiting for the first game video frame" }
        guard (answer.chatStream ?? 0) > 0 else { return }
        microphone.bind(NativeRTCMicrophoneTransport(peer: peer) { [weak self, weak peer] in
            guard let self, let peer else { throw NativeMicrophoneError.unavailable }
            try await self.renegotiateMicrophone(on: peer)
        })
    }

    private func renegotiateMicrophone(on peer: RTCPeerConnection) async throws {
        guard !isClosing, peerConnection === peer, let cloudSession, let offering else { throw NativeMicrophoneError.unavailable }
        sdpRequestID += 1
        let requestID = sdpRequestID
        do {
            let previousSDP = await NativeRTCExecutor.shared.perform { peer.remoteDescription?.sdp }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let offer = try await makeOffer(from: peer, constraints: constraints)
            try Task.checkCancellation()
            guard !isClosing, peerConnection === peer else { throw CancellationError() }
            try await setLocalDescription(offer, on: peer)
            try await service.sendLocalSDP(Self.microphoneOffer(sdp: offer.sdp, requestID: requestID,
                                                               correlationVector: cloudSession.correlationVector.increment()),
                                           for: cloudSession, offering: offering)
            let answer = try await service.waitForRemoteSDP(for: cloudSession, offering: offering,
                                                          expectedRequestID: requestID, previousSDP: previousSDP)
            try Task.checkCancellation()
            guard !isClosing, peerConnection === peer else { throw CancellationError() }
            try await setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer.sdp), on: peer)
        } catch {
            // A microphone error must not strand the video peer in have-local-offer.
            if await NativeRTCExecutor.shared.perform({ peer.signalingState == .haveLocalOffer }) {
                try? await setLocalDescription(RTCSessionDescription(type: .rollback, sdp: ""), on: peer)
            }
            throw error
        }
    }

    nonisolated static func microphoneOffer(sdp: String, requestID: Int, correlationVector: String) -> [String: Any] {
        ["messageType": "offer", "requestId": requestID, "sdp": sdp, "cv": correlationVector,
         "configuration": ["isMediaStreamsChatRenegotiation": true]]
    }

    private func createRequiredDataChannels(on peer: RTCPeerConnection) async {
        let channels = await NativeRTCExecutor.shared.perform {
            [("input", "1.0"), ("chat", "chatV1"), ("control", "controlV1"), ("message", "messageV1")].map {
                Self.createDataChannel(on: peer, label: $0.0, protocol: $0.1)
            }
        }
        inputChannel = channels[0]
        chatChannel = channels[1]
        controlChannel = channels[2]
        messageChannel = channels[3]

        if let controlChannel {
            controlChannel.delegate = self
        }
        if let inputChannel {
            inputChannel.delegate = self
        }
        if let messageChannel {
            messageChannel.delegate = self
        }
        if let chatChannel {
            chatChannel.delegate = self
        }
    }

    nonisolated static let webRTCNegotiationConfiguration: [String: Any] = [
        "chatStream": ["minVersion": 1, "maxVersion": 1],
        "control": ["minVersion": 1, "maxVersion": 3],
        "input": ["minVersion": 1, "maxVersion": 10],
        "unreliableinput": ["minVersion": 9, "maxVersion": 10],
        "useUnreliableInput": false,
        "reliableinput": ["minVersion": 9, "maxVersion": 10],
        "message": ["minVersion": 1, "maxVersion": 1],
        "chatConfiguration": [
            "bytesPerSample": 2,
            "format": ["codec": "opus", "container": "webm"],
            "numChannels": 1,
            "sampleFrequencyHz": 24_000
        ],
        "chat": ["minVersion": 1, "maxVersion": 1]
    ]

    nonisolated private static func createDataChannel(on peer: RTCPeerConnection, label: String, protocol channelProtocol: String) -> RTCDataChannel? {
        let channelConfiguration = RTCDataChannelConfiguration()
        channelConfiguration.isOrdered = true
        channelConfiguration.maxRetransmits = -1
        channelConfiguration.maxPacketLifeTime = -1
        channelConfiguration.protocol = channelProtocol
        return peer.dataChannel(forLabel: label, configuration: channelConfiguration)
    }

    private func makeOffer(
        from peer: RTCPeerConnection,
        constraints: RTCMediaConstraints
    ) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            NativeRTCExecutor.shared.enqueue { peer.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: XboxCloudPlayError.malformedResponse("WebRTC returned no local offer."))
                }
            } }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, on peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NativeRTCExecutor.shared.enqueue { peer.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            } }
        }
    }

    private func setRemoteDescription(_ description: RTCSessionDescription, on peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NativeRTCExecutor.shared.enqueue { peer.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            } }
        }
    }

    private func waitForLocalICE(on peer: RTCPeerConnection) async {
        let deadline = Date().addingTimeInterval(5)
        while await NativeRTCExecutor.shared.perform({ peer.iceGatheringState != .complete }), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func addRemoteCandidate(_ json: String, to peer: RTCPeerConnection) throws {
        guard let iceCandidate = try NativeICECandidate.decode(json) else { return }
        NativeRTCExecutor.shared.enqueue { peer.add(iceCandidate) { error in
            if let error {
                NSLog("PixelCloudX ICE candidate rejected: %@", error.localizedDescription)
            }
        } }
    }

    private func startKeepAlive(for cloudSession: XboxCloudPlaySession, offering: XboxCloudOfferingSession) {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(cloudSession.keepAliveInterval))
                guard !Task.isCancelled else { break }
                do {
                    try await self?.service.keepAlive(cloudSession, offering: offering)
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, !self.isClosing else { return }
                        self.statusMessage = "Reconnecting to Xbox session"
                    }
                }
            }
        }
    }

    private func pollControllerInput() async {
        var polls = 0
        while !Task.isCancelled, !isClosing {
            polls += 1
            controllerInput?.sampleControllers()
            if polls == 1 || polls % 625 == 0 {
                NSLog("PixelCloudX input sampling: polls=%ld devices=%ld reports=%llu channels=%ld", polls,
                      controllerInput?.controllers.count ?? 0, inputReportsSent, openChannels.count)
            }
            updateGamepadConnection(hasController: controllerInput?.controllers.isEmpty == false)
            if !isGuideVisible, let snapshot = controllerInput?.streamSnapshot {
                sendInputReport(snapshot: snapshot)
            }
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    private func updateGamepadConnection(hasController: Bool) {
        let ready = didAuthorizeControlChannel && (controlChannel.map { openChannels.contains(ObjectIdentifier($0)) } ?? false)
        gamepadAnnouncer.update(hasController: hasController, channelIsOpen: ready) {
            sendGamepadChanged(index: 0, added: $0)
        }
    }

    @discardableResult private func sendGamepadChanged(index: Int, added: Bool) -> Bool {
        guard let controlChannel, openChannels.contains(ObjectIdentifier(controlChannel)) else { return false }
        let message: [String: Any] = [
            "message": "gamepadChanged",
            "gamepadIndex": index,
            "wasAdded": added
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        send(data, binary: false, on: controlChannel)
        return true
    }

    private func sendInputReport(snapshot: ControllerInputSnapshot) {
        guard didAuthorizeControlChannel, gamepadAnnouncer.isAdded,
              let inputChannel, openChannels.contains(ObjectIdentifier(inputChannel)) else { return }
        sendClientMetadataIfReady()
        let state = Self.gamepadReport(snapshot: snapshot, sequence: 0, version: min(inputVersion, 6))
        guard state != lastGamepadState else { return }
        lastGamepadState = state
        inputSequence &+= 1
        let report = Self.gamepadReport(snapshot: snapshot, sequence: inputSequence, version: inputVersion)
        if inputSequence < 12 { NSLog("PixelCloudX input report: version=%ld sequence=%u bytes=%ld", inputVersion, inputSequence, report.count) }
        send(report, binary: true, on: inputChannel)
        inputReportsSent &+= 1
    }

    private func sendInputNeutralState() {
        guard let inputChannel, openChannels.contains(ObjectIdentifier(inputChannel)) else { return }
        let neutral = ControllerInputSnapshot(
            id: "neutral",
            name: "Game Controller",
            profile: "Extended gamepad",
            pressedButtons: [],
            leftStick: ControllerStickState(x: 0, y: 0),
            rightStick: ControllerStickState(x: 0, y: 0),
            dpad: ControllerStickState(x: 0, y: 0),
            leftTrigger: 0,
            rightTrigger: 0,
            otherAxes: []
        )
        inputSequence &+= 1
        let report = Self.gamepadReport(snapshot: neutral, sequence: inputSequence, version: inputVersion)
        send(report, binary: true, on: inputChannel)
        lastGamepadState = nil
    }

    private func sendClientMetadataIfReady() {
        guard !didSendClientMetadata,
              inputVersion >= 3,
              let inputChannel,
              openChannels.contains(ObjectIdentifier(inputChannel)) else { return }
        inputSequence &+= 1
        let report = Self.clientMetadataReport(sequence: inputSequence, version: inputVersion)
        send(report, binary: true, on: inputChannel)
        didSendClientMetadata = true
    }

    private func closeDataChannels() {
        let channels = [controlChannel, inputChannel, messageChannel, chatChannel].compactMap { $0 }
        NativeRTCExecutor.shared.enqueue {
            channels.forEach { $0.delegate = nil; $0.close() }
        }
        openChannels.removeAll()
        gamepadAnnouncer.reset()
        controlChannel = nil
        inputChannel = nil
        messageChannel = nil
        chatChannel = nil
        localICECandidates.removeAll()
        lastGamepadState = nil
        didSendClientMetadata = false
        didSendMessageHandshake = false
        didConfigureMessageChannel = false
        didAuthorizeControlChannel = false
    }

    private func send(_ data: Data, binary: Bool, on channel: RTCDataChannel) {
        NativeRTCExecutor.shared.enqueue {
            guard channel.readyState == .open else { return }
            if !channel.sendData(RTCDataBuffer(data: data, isBinary: binary)) {
                NSLog("PixelCloudX data send rejected: channel=%@ buffered=%llu", channel.label, channel.bufferedAmount)
            }
        }
    }

    private func receiveVideoTrack(_ track: RTCVideoTrack) {
        guard videoTrack !== track else { return }
        detachFrameObserver()
        let observer = StreamFrameObserver { [weak self, weak track] width, height in
            DispatchQueue.main.async { [weak self, weak track] in
                guard let self, let track, self.videoTrack === track, !self.isClosing else { return }
                NSLog("PixelCloudX first decoded video frame: %ld x %ld", width, height)
                self.phase = .playing
                self.videoDimensions = CGSize(width: Int(width), height: Int(height))
                self.statusMessage = ""
            }
        }
        frameObserver = observer
        videoTrack = track
        NativeRTCExecutor.shared.enqueue { track.add(observer) }
    }

    private func detachFrameObserver() {
        if let videoTrack, let frameObserver {
            NativeRTCExecutor.shared.enqueue { videoTrack.remove(frameObserver) }
        }
        frameObserver = nil
    }

    private func startStatistics(on peer: RTCPeerConnection) {
        statisticsTask?.cancel()
        statisticsTask = Task { [weak self] in
            var lastKeyframeRequest: TimeInterval = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.peerConnection === peer, !self.isClosing else { return }
                self.statisticsSummary = "\(Int(self.videoDimensions.width)) × \(Int(self.videoDimensions.height)) · \(self.inputReportsSent) input reports"
                let now = ProcessInfo.processInfo.systemUptime
                if self.phase == .connecting, let ready = self.mediaReadyAt, now - ready > 45 {
                    self.fail("Xbox connected, but no video frame arrived. Return to the catalog and try launching again.")
                    return
                }
                let lastFrame = self.frameObserver?.lastFrameTime ?? 0
                if self.phase == .playing, lastFrame > 0, now - lastFrame > 8 {
                    if now - lastKeyframeRequest >= 5, let control = self.controlChannel,
                       self.openChannels.contains(ObjectIdentifier(control)) {
                        self.sendJSON(["message": "videoKeyframeRequested", "ifrRequested": true], on: control)
                        lastKeyframeRequest = now
                        self.statusMessage = "Recovering game video…"
                    }
                } else if self.statusMessage == "Recovering game video…" { self.statusMessage = "" }
                NativeRTCExecutor.shared.enqueue {
                    peer.statistics { report in
                        for stat in report.statistics.values where stat.type == "outbound-rtp" {
                            let v = stat.values
                            guard (v["kind"] as? String ?? v["mediaType"] as? String) == "audio" else { continue }
                            NSLog("PixelCloudX microphone RTP: packets=%@ bytes=%@",
                                  String(describing: v["packetsSent"] ?? 0 as NSNumber),
                                  String(describing: v["bytesSent"] ?? 0 as NSNumber))
                        }
                        for stat in report.statistics.values where stat.type == "inbound-rtp" {
                            let v = stat.values
                            NSLog("PixelCloudX inbound %@: bytes=%@ packets=%@ decoded=%@ dropped=%@ size=%@x%@",
                                  String(describing: v["kind"] ?? v["mediaType"] ?? "unknown" as NSString),
                                  String(describing: v["bytesReceived"] ?? 0 as NSNumber),
                                  String(describing: v["packetsReceived"] ?? 0 as NSNumber),
                                  String(describing: v["framesDecoded"] ?? 0 as NSNumber),
                                  String(describing: v["framesDropped"] ?? 0 as NSNumber),
                                  String(describing: v["frameWidth"] ?? 0 as NSNumber),
                                  String(describing: v["frameHeight"] ?? 0 as NSNumber))
                        }
                    }
                }
            }
        }
    }

    private func fail(_ message: String) {
        guard !isClosing, phase != .failed else { return }
        microphone.disconnectImmediately()
        startupTask?.cancel()
        startupTask = nil
        errorMessage = message
        statusMessage = ""
        phase = .failed
        inputTask?.cancel()
        inputTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        updateGamepadConnection(hasController: false)
        sendInputNeutralState()
        closeDataChannels()
        if let peerConnection { NativeRTCExecutor.shared.enqueue { peerConnection.close() } }
        peerConnection = nil
        detachFrameObserver()
        statisticsTask?.cancel()
        statisticsTask = nil
        videoTrack = nil
        controllerInput?.stopStreamInput()
        if let cloudSession, let offering {
            self.cloudSession = nil
            Task { await service.end(cloudSession, offering: offering) }
        }
    }

    private static func protocolVersion(_ value: Int?) -> Int { max(1, value ?? 1) }

    nonisolated static func gamepadReport(snapshot: ControllerInputSnapshot, sequence: UInt32, version: Int,
                                         timestampMilliseconds: Double = ProcessInfo.processInfo.systemUptime * 1_000) -> Data {
        let gamepadFlag: UInt16 = 2
        var bytes: [UInt8] = []
        if version >= 8 {
            append(gamepadFlag, to: &bytes)
        } else {
            bytes.append(UInt8(gamepadFlag & 0xFF))
        }
        append(sequence, to: &bytes)
        if version >= 7 {
            append(timestampMilliseconds, to: &bytes)
        }

        bytes.append(1) // One active gamepad report follows.
        bytes.append(0) // Xbox gamepad index.

        let pressed = Set(snapshot.pressedButtons)
        var buttons: UInt16 = 0
        if pressed.contains("Nexus") || pressed.contains("Home") { buttons |= 2 }
        if pressed.contains("Menu") { buttons |= 4 }
        if pressed.contains("View") || pressed.contains("Options") { buttons |= 8 }
        if pressed.contains("A") { buttons |= 16 }
        if pressed.contains("B") { buttons |= 32 }
        if pressed.contains("X") { buttons |= 64 }
        if pressed.contains("Y") { buttons |= 128 }
        if snapshot.dpad.y > 0.5 || pressed.contains("D-pad up") { buttons |= 256 }
        if snapshot.dpad.y < -0.5 || pressed.contains("D-pad down") { buttons |= 512 }
        if snapshot.dpad.x < -0.5 || pressed.contains("D-pad left") { buttons |= 1024 }
        if snapshot.dpad.x > 0.5 || pressed.contains("D-pad right") { buttons |= 2048 }
        if pressed.contains("LB") { buttons |= 4096 }
        if pressed.contains("RB") { buttons |= 8192 }
        if pressed.contains("LS") { buttons |= 16384 }
        if pressed.contains("RS") { buttons |= 32768 }
        append(buttons, to: &bytes)

        append(axis(snapshot.leftStick.x), to: &bytes)
        append(axis(snapshot.leftStick.y), to: &bytes)
        append(axis(snapshot.rightStick.x), to: &bytes)
        append(axis(snapshot.rightStick.y), to: &bytes)
        append(trigger(snapshot.leftTrigger), to: &bytes)
        append(trigger(snapshot.rightTrigger), to: &bytes)
        if version >= 2 {
            // Per-control activity masks use different bits from button flags.
            var activity: UInt32 = 0
            let map: [(String, UInt32)] = [("Menu", 16), ("View", 32), ("LS", 64), ("RS", 128),
                ("LB", 256), ("RB", 512), ("Nexus", 1024), ("A", 4096), ("B", 8192), ("X", 16384), ("Y", 32768)]
            for (name, bit) in map where pressed.contains(name) { activity |= bit }
            if buttons & 256 != 0 { activity |= 1 }
            if buttons & 512 != 0 { activity |= 2 }
            if buttons & 1024 != 0 { activity |= 4 }
            if buttons & 2048 != 0 { activity |= 8 }
            if snapshot.leftTrigger > 0 { activity |= 65536 }
            if snapshot.rightTrigger > 0 { activity |= 131072 }
            if snapshot.leftStick.x != 0 { activity |= 262144 }
            if snapshot.leftStick.y != 0 { activity |= 524288 }
            if snapshot.rightStick.x != 0 { activity |= 1048576 }
            if snapshot.rightStick.y != 0 { activity |= 2097152 }
            append(snapshot.id == "keyboard-gamepad" ? UInt32(0) : activity, to: &bytes)
            append(snapshot.id == "keyboard-gamepad" ? activity : UInt32(0), to: &bytes)
        }
        return Data(bytes)
    }

    nonisolated static func clientMetadataReport(sequence: UInt32, version: Int) -> Data {
        var bytes: [UInt8] = []
        if version >= 8 { append(UInt16(8), to: &bytes) }
        else { bytes.append(8) }
        append(sequence, to: &bytes)
        if version >= 7 { append(Double(ProcessInfo.processInfo.systemUptime * 1_000), to: &bytes) }
        bytes.append(0) // This client advertises no touch controls.
        return Data(bytes)
    }

    nonisolated private static func axis(_ value: Float) -> Int16 {
        let clamped = max(-1, min(1, value))
        return Int16((clamped * 32767).rounded())
    }

    nonisolated private static func trigger(_ value: Float) -> UInt16 {
        let clamped = max(0, min(1, value))
        return UInt16((clamped * 65535).rounded())
    }

    nonisolated private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
    }

    nonisolated private static func append(_ value: Double, to bytes: inout [UInt8]) {
        append(value.bitPattern, to: &bytes)
    }
}

/// A track announcement does not prove that a decoder produced any video.
/// This sink observes the first nonempty decoded frame independently of Metal.
private final class StreamFrameObserver: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var delivered = false
    private var lastWidth: Int32 = 0
    private var lastHeight: Int32 = 0
    private var latestFrame: TimeInterval = 0
    private let firstFrame: (Int32, Int32) -> Void

    init(firstFrame: @escaping (Int32, Int32) -> Void) { self.firstFrame = firstFrame }
    func setSize(_ size: CGSize) {}
    var lastFrameTime: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return latestFrame
    }
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, frame.width > 0, frame.height > 0 else { return }
        lock.lock()
        let notify = !delivered || lastWidth != frame.width || lastHeight != frame.height
        delivered = true
        lastWidth = frame.width
        lastHeight = frame.height
        latestFrame = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        if notify { firstFrame(frame.width, frame.height) }
    }
}

extension XboxCloudStreamController: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let track = stream.videoTracks.first
        DispatchQueue.main.async { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosing, let track else { return }
            self.receiveVideoTrack(track)
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceConnectionState) {
        NSLog("PixelCloudX ICE state: %ld", stateChanged.rawValue)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosing else { return }
            if self.phase != .playing {
                if stateChanged == .checking { self.statusMessage = "Finding the best route to Xbox" }
                if stateChanged == .connected || stateChanged == .completed {
                    self.statusMessage = "Waiting for the first game video frame"
                }
            }
            if stateChanged == .failed { self.fail("The native WebRTC connection to Xbox failed.") }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let record: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex,
            "sdpMid": candidate.sdpMid as Any? ?? NSNull()
        ]
        DispatchQueue.main.async { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosing else { return }
            self.localICECandidates.append(record)
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        DispatchQueue.main.async { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosing else { return }
            self.didOpen(dataChannel, state: state)
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        let track = rtpReceiver.track
        DispatchQueue.main.async { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosing else { return }
            if let audioTrack = track as? RTCAudioTrack {
                let enabled = !self.isMuted
                let volume = self.preferences.volume
                NativeRTCExecutor.shared.enqueue { audioTrack.source.volume = volume; audioTrack.isEnabled = enabled }
            } else if let videoTrack = track as? RTCVideoTrack { self.receiveVideoTrack(videoTrack) }
        }
    }
}

extension XboxCloudStreamController: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        NSLog("PixelCloudX channel %@ state: %ld", dataChannel.label, state.rawValue)
        DispatchQueue.main.async { [weak self] in self?.didOpen(dataChannel, state: state) }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if dataChannel.label == "input" {
            let data = buffer.data
            DispatchQueue.main.async { [weak self] in
                guard let self, self.inputChannel === dataChannel else { return }
                self.inputPacketsReceived += 1
                if self.inputPacketsReceived <= 3 {
                    NSLog("PixelCloudX input response: bytes=%ld flags=%u", data.count, data.first.map(UInt32.init) ?? 0)
                }
            }
            return
        }
        if dataChannel.label == "control", !buffer.isBinary,
           let object = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any] {
            NSLog("PixelCloudX control response: type=%@ status=%@", object["message"] as? String ?? "unknown",
                  String(describing: object["status"] ?? "unspecified"))
            return
        }
        guard dataChannel.label == "message", !buffer.isBinary,
              let rawText = String(data: buffer.data, encoding: .utf8),
              let data = rawText.replacingOccurrences(of: "\u{0000}", with: "").data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.messageChannel === dataChannel, !self.isClosing else { return }
            self.handleMessageChannel(message, channel: dataChannel)
        }
    }

    private func didOpen(_ channel: RTCDataChannel, state: RTCDataChannelState) {
        guard !isClosing, [controlChannel, inputChannel, messageChannel, chatChannel].contains(where: { $0 === channel }) else { return }
        guard state == .open else { openChannels.remove(ObjectIdentifier(channel)); return }
        openChannels.insert(ObjectIdentifier(channel))
        switch channel.label {
        case "control":
            break
        case "input":
            sendClientMetadataIfReady()
        case "message":
            guard !didSendMessageHandshake else { return }
            let handshake: [String: Any] = [
                "type": "Handshake",
                "version": "messageV1",
                "id": UUID().uuidString,
                "cv": cloudSession?.correlationVector.increment() ?? "0.0"
            ]
            guard let payload = try? JSONSerialization.data(withJSONObject: handshake) else { return }
            send(payload, binary: false, on: channel)
            didSendMessageHandshake = true
        default:
            break
        }
        authorizeInputIfReady()
    }

    private func authorizeInputIfReady() {
        guard !didAuthorizeControlChannel, didConfigureMessageChannel,
              let controlChannel, let inputChannel, let messageChannel,
              [controlChannel, inputChannel, messageChannel].allSatisfy({ openChannels.contains(ObjectIdentifier($0)) }) else { return }
        sendJSON(["message": "authorizationRequest", "accessKey": "4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E"], on: controlChannel)
        didAuthorizeControlChannel = true
        gamepadAnnouncer.reset()
        lastGamepadState = nil
        NSLog("PixelCloudX input authorization queued after message handshake")
        updateGamepadConnection(hasController: controllerInput?.streamSnapshot != nil)
        sendVideoPreferences()
    }

    private func handleMessageChannel(_ message: [String: Any], channel: RTCDataChannel) {
        let type = message["type"] as? String ?? "unknown"
        let target = message["target"] as? String ?? ""
        NSLog("PixelCloudX message: %@ %@", type, target)
        if type == "HandshakeAck", !didConfigureMessageChannel {
            didConfigureMessageChannel = true
            sendMessage(target: "/streaming/systemUi/configuration", content: ["version": [0, 2, 0], "systemUis": []], on: channel)
            let defaults = UserDefaults.standard
            let installID = defaults.string(forKey: "PixelCloudX.sdkInstallId") ?? UUID().uuidString
            defaults.set(installID, forKey: "PixelCloudX.sdkInstallId")
            sendMessage(target: "/streaming/properties/clientappinstallidchanged", content: ["clientAppInstallId": installID], on: channel)
            sendMessage(target: "/streaming/characteristics/orientationchanged", content: ["orientation": 0], on: channel)
            sendMessage(target: "/streaming/characteristics/touchinputenabledchanged", content: ["touchInputEnabled": false], on: channel)
            sendMessage(target: "/streaming/characteristics/clientdevicecapabilities", content: [:], on: channel)
            sendMessage(target: "/streaming/title/constrain", content: ["constrain": false], on: channel, transaction: true)
            authorizeInputIfReady()
        }
        if target == "/streaming/sessionLifetimeManagement/serverInitiatedDisconnect" {
            if let id = message["id"] as? String {
                sendJSON(["type": "TransactionComplete", "id": id, "content": "", "cv": ""], on: channel)
            }
            var reason = "Xbox ended the cloud session."
            if let content = message["content"] as? String {
                if content.contains("KickByNewSession") { reason = "Another Xbox session replaced this stream. Close it before launching here again." }
                else if content.contains("KickForBeingIdle") { reason = "Xbox ended the session because it was idle." }
                else if content.contains("KickForNoClientConnection") { reason = "Xbox could not confirm the stream connection." }
            }
            fail(reason)
        }
        if let type = message["type"] as? String, type == "Handshake",
           let version = message["version"] as? String {
            if version != "messageV1" {
                statusMessage = "Xbox message-channel version mismatch"
            }
        }
    }

    private func sendJSON(_ object: [String: Any], on channel: RTCDataChannel) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(data, binary: false, on: channel)
    }

    private func sendMessage(target: String, content: [String: Any], on channel: RTCDataChannel, transaction: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: content), let text = String(data: data, encoding: .utf8) else { return }
        sendJSON(["type": transaction ? "TransactionStart" : "Message", "target": target, "content": text,
                  "id": UUID().uuidString, "cv": cloudSession?.correlationVector.increment() ?? ""], on: channel)
    }
}
