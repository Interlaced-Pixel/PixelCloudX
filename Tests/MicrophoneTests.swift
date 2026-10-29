import AppKit
import Foundation

private actor PermissionFixture: MicrophoneAuthorizing {
    var result: MicrophoneAuthorization?
    private(set) var requests = 0
    private var waiters: [CheckedContinuation<MicrophoneAuthorization, Never>] = []
    init(_ result: MicrophoneAuthorization? = .granted) { self.result = result }
    func requestAuthorization() async -> MicrophoneAuthorization {
        requests += 1
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func resolve(_ result: MicrophoneAuthorization) {
        self.result = result
        let pending = waiters; waiters = []
        pending.forEach { $0.resume(returning: result) }
    }
}
private actor NegotiationGate {
    private var open: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(open: Bool = true) { self.open = open }
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
private final class TransportFixture: StreamMicrophoneTransport, @unchecked Sendable {
    struct Snapshot {
        var wanted = false, capture = false, track = false, closed = false
        var prepares = 0, activations = 0, shutdowns = 0
    }
    private let lock = NSLock()
    private var value = Snapshot()
    let gate: NegotiationGate
    let fails: Bool
    init(gate: NegotiationGate = NegotiationGate(), fails: Bool = false) { self.gate = gate; self.fails = fails }
    var snapshot: Snapshot { lock.withLock { value } }
    func setEnabledIntent(_ enabled: Bool) {
        lock.withLock {
            value.wanted = enabled
            if !enabled { value.capture = false; value.track = false }
        }
    }
    func prepare() async throws {
        lock.withLock { value.prepares += 1; value.track = value.wanted }
        await gate.wait()
        if fails { throw NSError(domain: "MicrophoneTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test SDP rejection"]) }
    }
    func activate() async throws -> Bool {
        try lock.withLock {
            value.activations += 1
            guard value.wanted, !value.closed else { return false }
            guard value.track else { throw NSError(domain: "MicrophoneTest", code: 2) }
            value.capture = true
            return true
        }
    }
    func shutdown() async { lock.withLock { value.closed = true; value.capture = false; value.track = false; value.shutdowns += 1 } }
}

private func check(_ condition: Bool, _ message: String = "Microphone assertion failed") { precondition(condition, message) }

@main @MainActor private enum MicrophoneTests {
    static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        check(condition(), "Timed out waiting for microphone state")
    }
    static func main() async throws {
        let permission = PermissionFixture()
        let transport = TransportFixture()
        let mic = StreamMicrophoneController(authorization: permission, observeDevices: false)
        mic.toggle()
        check(!mic.isAvailable && !mic.wantsEnabled)
        mic.bind(transport)
        check(mic.state == .muted && !transport.snapshot.capture)
        check(await permission.requests == 0, "Binding a stream must not request microphone permission")
        mic.toggle()
        try await wait { mic.state == .live }
        check(transport.snapshot.capture && transport.snapshot.prepares == 1)
        mic.toggle()
        check(mic.state == .muted && !transport.snapshot.capture && !transport.snapshot.track)
        mic.toggle()
        try await wait { mic.state == .live }
        check(transport.snapshot.prepares == 2)
        await mic.disconnect()
        check(!mic.isAvailable && mic.state == .unavailable && transport.snapshot.closed && !transport.snapshot.capture)

        for result in [MicrophoneAuthorization.denied, .noDevice] {
            let deniedPermission = PermissionFixture(result)
            let deniedTransport = TransportFixture()
            let deniedMic = StreamMicrophoneController(authorization: deniedPermission, observeDevices: false)
            deniedMic.bind(deniedTransport); deniedMic.toggle()
            try await wait { !deniedMic.wantsEnabled }
            check(deniedMic.state.detail != nil && deniedTransport.snapshot.prepares == 0 && !deniedTransport.snapshot.capture)
            await deniedPermission.resolve(.granted)
            deniedMic.toggle()
            try await wait { deniedMic.state == .live }
            await deniedMic.disconnect()
        }

        let delayedPermission = PermissionFixture(nil)
        let delayedTransport = TransportFixture()
        let delayedMic = StreamMicrophoneController(authorization: delayedPermission, observeDevices: false)
        delayedMic.bind(delayedTransport); delayedMic.toggle()
        try await wait { delayedMic.state == .requestingPermission }
        delayedMic.toggle()
        await delayedPermission.resolve(.granted)
        try await Task.sleep(for: .milliseconds(20))
        check(delayedMic.state == .muted && delayedTransport.snapshot.prepares == 0)
        await delayedMic.disconnect()

        let stoppedPermission = PermissionFixture(nil)
        let stoppedTransport = TransportFixture()
        let stoppedMic = StreamMicrophoneController(authorization: stoppedPermission, observeDevices: false)
        stoppedMic.bind(stoppedTransport); stoppedMic.toggle()
        try await wait { stoppedMic.state == .requestingPermission }
        await stoppedMic.disconnect()
        check(!stoppedMic.isAvailable && stoppedTransport.snapshot.closed, "Quit must not wait for a permission sheet")
        let replacement = TransportFixture()
        stoppedMic.bind(replacement)
        await stoppedPermission.resolve(.granted)
        try await Task.sleep(for: .milliseconds(20))
        check(stoppedMic.state == .muted && !replacement.snapshot.capture && stoppedTransport.snapshot.prepares == 0)
        await stoppedMic.disconnect()

        for rapidReenable in [false, true] {
            let gate = NegotiationGate(open: false)
            let pendingTransport = TransportFixture(gate: gate)
            let pendingMic = StreamMicrophoneController(authorization: PermissionFixture(), observeDevices: false)
            pendingMic.bind(pendingTransport); pendingMic.toggle()
            try await wait { pendingTransport.snapshot.prepares == 1 }
            pendingMic.toggle()
            check(!pendingTransport.snapshot.capture && !pendingTransport.snapshot.track)
            if rapidReenable { pendingMic.toggle() }
            await gate.release()
            if rapidReenable { try await wait { pendingMic.state == .live } }
            else {
                try await Task.sleep(for: .milliseconds(20))
                check(pendingMic.state == .muted && pendingTransport.snapshot.activations == 0)
            }
            await pendingMic.disconnect()
            check(!pendingTransport.snapshot.capture)
        }

        let failure = TransportFixture(fails: true)
        let failedMic = StreamMicrophoneController(authorization: PermissionFixture(), observeDevices: false)
        failedMic.bind(failure); failedMic.toggle()
        try await wait { failedMic.state.detail != nil }
        check(!failedMic.wantsEnabled && !failure.snapshot.capture && !failure.snapshot.track)
        await failedMic.disconnect()

        let menu = NSMenu()
        let minimize = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        minimize.keyEquivalentModifierMask = .command
        let toggle = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "m")
        toggle.keyEquivalentModifierMask = .command
        menu.addItem(minimize); menu.addItem(toggle)
        StreamMicrophoneShortcut.reserve(in: menu)
        check(minimize.keyEquivalent.isEmpty && toggle.keyEquivalent == "m", "Command-M must not minimize the game")
        print("PASS: mic off by default, permission/no-device failures, retry, native-intent mute gate, re-enable, mute during permission/SDP, rapid toggles, stop/rebind safety, independent mic errors, Command-M reservation")
    }
}
