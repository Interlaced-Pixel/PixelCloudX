import Combine
import GameController
import Foundation
import AppKit

struct ControllerStickState: Equatable {
    let x: Float
    let y: Float
}

struct ControllerAxisValue: Identifiable, Equatable {
    let name: String
    let value: Float

    var id: String { name }
}

struct ControllerInputSnapshot: Identifiable, Equatable {
    let id: String
    let name: String
    let profile: String
    let pressedButtons: [String]
    let leftStick: ControllerStickState
    let rightStick: ControllerStickState
    let dpad: ControllerStickState
    let leftTrigger: Float
    let rightTrigger: Float
    let otherAxes: [ControllerAxisValue]
}

/// Announce the single merged gamepad only after its control channel is ready.
/// Sampling input before channel open must not consume the pending connection.
struct StreamGamepadAnnouncer {
    private(set) var isAdded = false
    mutating func update(hasController: Bool, channelIsOpen: Bool, send: (Bool) -> Bool) {
        guard channelIsOpen, hasController != isAdded, send(hasController) else { return }
        isAdded = hasController
    }
    mutating func reset() { isAdded = false }
}

@MainActor
final class ControllerInputService: ObservableObject {
    @Published private(set) var controllers: [ControllerInputSnapshot] = []

    private var connectedControllers: [ObjectIdentifier: GCController] = [:]
    private var notificationObservers: [NSObjectProtocol] = []
    private var discoveryStopWorkItem: DispatchWorkItem?
    private var keyboardMonitor: Any?
    private var keyboardState = KeyboardGamepadState()
    private var keyboardPaused = false
    private var streaming = false
    private var keyboardEnabled = true
    private var monitorsBackground = true
    private var deadzone: Float = 0

    var streamSnapshot: ControllerInputSnapshot? {
        if !monitorsBackground && !NSApp.isActive {
            return ControllerInputSnapshot(id: "inactive", name: "Inactive window", profile: "Neutral",
                pressedButtons: [], leftStick: .init(x: 0, y: 0), rightStick: .init(x: 0, y: 0),
                dpad: .init(x: 0, y: 0), leftTrigger: 0, rightTrigger: 0, otherAxes: [])
        }
        guard let physical = controllers.first(where: { $0.id != "keyboard-gamepad" }) else { return controllers.first }
        guard keyboardMonitor != nil, !keyboardPaused else { return physical }
        let keyboard = keyboardState.snapshot
        func combined(_ a: ControllerStickState, _ b: ControllerStickState) -> ControllerStickState {
            ControllerStickState(x: max(-1, min(1, a.x + b.x)), y: max(-1, min(1, a.y + b.y)))
        }
        return ControllerInputSnapshot(id: physical.id, name: physical.name, profile: physical.profile,
            pressedButtons: Set(physical.pressedButtons + keyboard.pressedButtons).sorted(),
            leftStick: combined(physical.leftStick, keyboard.leftStick), rightStick: physical.rightStick,
            dpad: combined(physical.dpad, keyboard.dpad), leftTrigger: max(physical.leftTrigger, keyboard.leftTrigger),
            rightTrigger: max(physical.rightTrigger, keyboard.rightTrigger), otherAxes: physical.otherAxes)
    }

    init() {
        GCController.shouldMonitorBackgroundEvents = true
        let notificationCenter = NotificationCenter.default
        notificationObservers.append(
            notificationCenter.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                Task { @MainActor [weak self] in
                    self?.attach(controller)
                }
            }
        )
        notificationObservers.append(
            notificationCenter.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                Task { @MainActor [weak self] in
                    self?.detach(controller)
                }
            }
        )

        GCController.controllers().forEach(attach)
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            notificationObservers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.resetKeyboard() }
            })
        }
    }

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        discoveryStopWorkItem?.cancel()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    }

    func startKeyboardGamepad() {
        guard keyboardMonitor == nil else { return }
        keyboardPaused = false
        keyboardState = KeyboardGamepadState()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, !self.keyboardPaused, NSApp.isActive,
                  !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
                  self.keyboardState.set(event.keyCode, down: event.type == .keyDown) else { return event }
            self.refreshSnapshots()
            NSLog("PixelCloudX mapped keyboard input: down=%d", event.type == .keyDown)
            return nil
        }
        refreshSnapshots()
    }

    func configure(keyboard: Bool, background: Bool, deadzone: Double) {
        keyboardEnabled = keyboard
        monitorsBackground = background
        self.deadzone = Float(deadzone)
        GCController.shouldMonitorBackgroundEvents = background
        if streaming {
            if keyboard { startKeyboardGamepad() } else { stopKeyboardGamepad() }
        }
    }
    func startStreamInput() {
        streaming = true
        if keyboardEnabled { startKeyboardGamepad() }
    }
    func stopStreamInput() {
        streaming = false
        stopKeyboardGamepad()
    }

    func pauseKeyboardGamepad(_ paused: Bool) {
        keyboardPaused = paused
        resetKeyboard()
    }

    func stopKeyboardGamepad() {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        resetKeyboard()
    }

    private func resetKeyboard() {
        keyboardState = KeyboardGamepadState()
        refreshSnapshots()
    }

    func scanForWirelessControllers() {
        discoveryStopWorkItem?.cancel()
        GCController.startWirelessControllerDiscovery(completionHandler: nil)

        let stopWorkItem = DispatchWorkItem {
            GCController.stopWirelessControllerDiscovery()
        }
        discoveryStopWorkItem = stopWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: stopWorkItem)
    }

    private func attach(_ controller: GCController) {
        let identifier = ObjectIdentifier(controller)
        connectedControllers[identifier] = controller

        controller.physicalInputProfile.valueDidChangeHandler = { [weak self, weak controller] _, _ in
            guard let controller else { return }
            Task { @MainActor [weak self] in
                self?.refreshSnapshot(for: controller)
            }
        }

        refreshSnapshot(for: controller)
    }

    private func detach(_ controller: GCController) {
        connectedControllers.removeValue(forKey: ObjectIdentifier(controller))
        controller.physicalInputProfile.valueDidChangeHandler = nil
        refreshSnapshots()
    }

    private func refreshSnapshot(for controller: GCController) {
        guard connectedControllers[ObjectIdentifier(controller)] != nil else { return }
        refreshSnapshots()
    }

    private func refreshSnapshots() {
        var snapshots = connectedControllers
            .map { makeSnapshot(controller: $0.value, identifier: $0.key) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if keyboardMonitor != nil { snapshots.append(keyboardState.snapshot) }
        if controllers != snapshots { controllers = snapshots }
    }

    /// Read the current native profile at the stream's sampling cadence too.
    /// A missed/coalesced value-change callback must not strand a held input.
    func sampleControllers() { refreshSnapshots() }

    private func makeSnapshot(
        controller: GCController,
        identifier: ObjectIdentifier
    ) -> ControllerInputSnapshot {
        var pressedButtons: [String] = []
        var leftStick = ControllerStickState(x: 0, y: 0)
        var rightStick = ControllerStickState(x: 0, y: 0)
        var dpad = ControllerStickState(x: 0, y: 0)
        var leftTrigger: Float = 0
        var rightTrigger: Float = 0
        var otherAxes: [ControllerAxisValue] = []
        var profile = "Controller"

        if let gamepad = controller.extendedGamepad {
            profile = "Extended gamepad"
            let buttons: [(String, GCControllerButtonInput?)] = [
                ("A", gamepad.buttonA), ("B", gamepad.buttonB),
                ("X", gamepad.buttonX), ("Y", gamepad.buttonY),
                ("LB", gamepad.leftShoulder), ("RB", gamepad.rightShoulder),
                ("LS", gamepad.leftThumbstickButton), ("RS", gamepad.rightThumbstickButton),
                ("Menu", gamepad.buttonMenu), ("View", gamepad.buttonOptions),
                ("Nexus", gamepad.buttonHome),
                ("D-pad up", gamepad.dpad.up), ("D-pad down", gamepad.dpad.down),
                ("D-pad left", gamepad.dpad.left), ("D-pad right", gamepad.dpad.right)
            ]
            pressedButtons = buttons.compactMap { label, button in
                button?.isPressed == true ? label : nil
            }
            leftStick = ControllerStickState(
                x: gamepad.leftThumbstick.xAxis.value,
                y: gamepad.leftThumbstick.yAxis.value
            )
            rightStick = ControllerStickState(
                x: gamepad.rightThumbstick.xAxis.value,
                y: gamepad.rightThumbstick.yAxis.value
            )
            dpad = ControllerStickState(x: gamepad.dpad.xAxis.value, y: gamepad.dpad.yAxis.value)
            leftTrigger = gamepad.leftTrigger.value
            rightTrigger = gamepad.rightTrigger.value
        } else if let gamepad = controller.microGamepad {
            profile = "Compact gamepad"
            if gamepad.buttonA.isPressed { pressedButtons.append("A") }
            if gamepad.buttonX.isPressed { pressedButtons.append("X") }
            dpad = ControllerStickState(x: gamepad.dpad.xAxis.value, y: gamepad.dpad.yAxis.value)
        } else {
            let physicalProfile = controller.physicalInputProfile
            profile = "Standard gamepad profile"
            pressedButtons = physicalProfile.buttons.compactMap { name, button in
                button.isPressed ? Self.displayName(forInput: name) : nil
            }
            otherAxes = physicalProfile.axes.map { name, axis in
                ControllerAxisValue(name: Self.displayName(forInput: name), value: axis.value)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if let directionalPad = physicalProfile.dpads.first(where: {
                $0.key.localizedCaseInsensitiveContains("dpad")
                    || $0.key.localizedCaseInsensitiveContains("direction")
            })?.value {
                dpad = ControllerStickState(x: directionalPad.xAxis.value, y: directionalPad.yAxis.value)
            }
        }

        func filtered(_ stick: ControllerStickState) -> ControllerStickState {
            func axis(_ value: Float) -> Float {
                guard abs(value) > deadzone else { return 0 }
                return (value < 0 ? -1 : 1) * (abs(value) - deadzone) / (1 - deadzone)
            }
            return ControllerStickState(x: axis(stick.x), y: axis(stick.y))
        }
        return ControllerInputSnapshot(
            id: String(describing: identifier),
            name: controller.vendorName ?? "Game Controller",
            profile: profile,
            pressedButtons: pressedButtons.sorted(),
            leftStick: filtered(leftStick),
            rightStick: filtered(rightStick),
            dpad: dpad,
            leftTrigger: leftTrigger,
            rightTrigger: rightTrigger,
            otherAxes: otherAxes
        )
    }

    private static func displayName(forInput name: String) -> String {
        let normalized = name.replacingOccurrences(of: "GCInput", with: "")
        let aliases: [(String, String)] = [
            ("ButtonA", "A"), ("ButtonB", "B"), ("ButtonX", "X"), ("ButtonY", "Y"),
            ("LeftShoulder", "LB"), ("RightShoulder", "RB"),
            ("LeftTrigger", "LT"), ("RightTrigger", "RT"),
            ("LeftThumbstick", "Left stick"), ("RightThumbstick", "Right stick"),
            ("ButtonMenu", "Menu"), ("ButtonOptions", "View"),
            ("ButtonHome", "Nexus"), ("ButtonShare", "Share")
        ]
        return aliases.first { normalized.localizedCaseInsensitiveContains($0.0) }?.1 ?? normalized
    }
}

/// Physical key codes keep controls consistent across keyboard layouts.
struct KeyboardGamepadState {
    private var keys: Set<UInt16> = []
    private static let buttons: [UInt16: String] = [
        49: "A", 38: "A", 40: "B", 51: "B", 32: "X", 34: "Y",
        12: "LB", 14: "RB", 36: "Menu", 9: "View", 3: "LS", 5: "RS"
    ]

    mutating func set(_ key: UInt16, down: Bool) -> Bool {
        guard Self.buttons[key] != nil || [0, 1, 2, 13, 6, 8, 123, 124, 125, 126].contains(key) else { return false }
        if down { keys.insert(key) } else { keys.remove(key) }
        return true
    }

    var snapshot: ControllerInputSnapshot {
        func axis(_ negative: UInt16, _ positive: UInt16) -> Float {
            (keys.contains(positive) ? 1 : 0) - (keys.contains(negative) ? 1 : 0)
        }
        return ControllerInputSnapshot(
            id: "keyboard-gamepad", name: "Keyboard gamepad", profile: "Keyboard gamepad",
            pressedButtons: Set(keys.compactMap { Self.buttons[$0] }).sorted(),
            leftStick: ControllerStickState(x: axis(0, 2), y: axis(1, 13)),
            rightStick: ControllerStickState(x: 0, y: 0),
            dpad: ControllerStickState(x: axis(123, 124), y: axis(125, 126)),
            leftTrigger: keys.contains(6) ? 1 : 0, rightTrigger: keys.contains(8) ? 1 : 0, otherAxes: []
        )
    }
}
