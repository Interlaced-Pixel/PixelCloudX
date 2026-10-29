import AVFoundation
import Combine
import Foundation

enum StreamMicrophoneState: Equatable {
    case unavailable, muted, requestingPermission, connecting, live, denied
    case failed(String)

    var label: String {
        switch self {
        case .unavailable: "Microphone unavailable"
        case .muted: "Microphone off"
        case .requestingPermission: "Allow microphone access…"
        case .connecting: "Connecting microphone…"
        case .live: "Microphone on"
        case .denied: "Microphone permission denied"
        case .failed: "Microphone unavailable"
        }
    }
    var detail: String? {
        switch self {
        case .denied: "Allow PixelCloudX in System Settings → Privacy & Security → Microphone, then try again."
        case .failed(let message): message
        default: nil
        }
    }
}

enum MicrophoneAuthorization: Sendable { case granted, denied, noDevice }
protocol MicrophoneAuthorizing: Sendable {
    func requestAuthorization() async -> MicrophoneAuthorization
}
struct SystemMicrophoneAuthorization: MicrophoneAuthorizing {
    func requestAuthorization() async -> MicrophoneAuthorization {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
        default: granted = false
        }
        guard granted else { return .denied }
        return AVCaptureDevice.default(for: .audio) == nil ? .noDevice : .granted
    }
}

protocol StreamMicrophoneTransport: AnyObject, Sendable {
    /// Synchronously revokes permission to transmit, even while async setup is pending.
    func setEnabledIntent(_ enabled: Bool)
    func prepare() async throws
    func activate() async throws -> Bool
    func shutdown() async
}

/// User intent and permission belong to the UI; native capture and negotiation
/// belong to the transport. A session token prevents late permission/SDP results
/// from opening a microphone after mute, stop, or a different game launch.
@MainActor final class StreamMicrophoneController: ObservableObject {
    @Published private(set) var state: StreamMicrophoneState = .unavailable
    @Published private(set) var wantsEnabled = false
    @Published private(set) var isAvailable = false
    private let authorization: any MicrophoneAuthorizing
    private var transport: (any StreamMicrophoneTransport)?
    private var worker: Task<Void, Never>?
    private var sessionID = UUID()
    private var intentRevision: UInt64 = 0
    private var deviceObserver: NSObjectProtocol?

    init(authorization: any MicrophoneAuthorizing = SystemMicrophoneAuthorization(), observeDevices: Bool = true) {
        self.authorization = authorization
        if observeDevices {
            deviceObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.wantsEnabled, AVCaptureDevice.default(for: .audio) == nil else { return }
                    self.wantsEnabled = false
                    self.transport?.setEnabledIntent(false)
                    self.state = .failed("No microphone is connected. Connect an input device and try again.")
                }
            }
        }
    }
    deinit { if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) } }

    func bind(_ newTransport: any StreamMicrophoneTransport) {
        disconnectImmediately()
        transport = newTransport
        newTransport.setEnabledIntent(false)
        isAvailable = true
        state = .muted
    }

    func toggle() {
        guard let transport, isAvailable else { return }
        wantsEnabled.toggle()
        intentRevision &+= 1
        transport.setEnabledIntent(wantsEnabled)
        if !wantsEnabled { state = .muted }
        guard worker == nil else { return }
        let token = sessionID
        worker = Task { [weak self] in await self?.reconcile(token: token) }
    }

    private func reconcile(token: UUID) async {
        defer { if token == sessionID { worker = nil } }
        while token == sessionID, !Task.isCancelled, let transport {
            guard wantsEnabled else { return }
            let revision = intentRevision
            state = .requestingPermission
            let permission = await authorization.requestAuthorization()
            guard token == sessionID, !Task.isCancelled else { return }
            guard wantsEnabled else { return }
            switch permission {
            case .denied:
                wantsEnabled = false; transport.setEnabledIntent(false); state = .denied; return
            case .noDevice:
                wantsEnabled = false; transport.setEnabledIntent(false)
                state = .failed("No microphone is connected. Connect an input device and try again."); return
            case .granted: break
            }
            state = .connecting
            do {
                // Muting does not cancel an offer halfway through negotiation.
                // The intent gate prevents activation while that offer completes.
                try await transport.prepare()
                guard token == sessionID, !Task.isCancelled else { return }
                guard wantsEnabled else { return }
                let activated = try await transport.activate()
                guard token == sessionID, !Task.isCancelled else { return }
                if wantsEnabled && activated { state = .live; return }
            } catch {
                guard token == sessionID, !Task.isCancelled else { return }
                if wantsEnabled && revision != intentRevision { continue }
                transport.setEnabledIntent(false)
                guard wantsEnabled else { return }
                wantsEnabled = false
                state = .failed(error.localizedDescription)
                return
            }
        }
    }

    private func detach() -> (any StreamMicrophoneTransport)? {
        sessionID = UUID()
        worker?.cancel(); worker = nil
        let previous = transport
        previous?.setEnabledIntent(false)
        transport = nil
        wantsEnabled = false
        isAvailable = false
        state = .unavailable
        return previous
    }
    func disconnectImmediately() {
        let previous = detach()
        Task { await previous?.shutdown() }
    }
    func disconnect() async {
        // Do not await an outstanding system permission sheet during app quit.
        let previous = detach()
        await previous?.shutdown()
    }
}
