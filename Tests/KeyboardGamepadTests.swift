import Foundation

@main private enum KeyboardGamepadTests {
    static func main() {
        var connection = StreamGamepadAnnouncer()
        var announcements: [Bool] = []
        connection.update(hasController: true, channelIsOpen: false) { announcements.append($0); return true }
        precondition(announcements.isEmpty && !connection.isAdded, "Pre-open polling must preserve the pending announcement")
        connection.update(hasController: true, channelIsOpen: true) { _ in false }
        precondition(!connection.isAdded, "Failed sends must not advance connection state")
        connection.update(hasController: true, channelIsOpen: true) { announcements.append($0); return true }
        for _ in 0..<100 {
            connection.update(hasController: true, channelIsOpen: true) { announcements.append($0); return true }
        }
        precondition(announcements == [true], "Merged physical and keyboard controllers must not repeatedly reconnect")
        connection.update(hasController: false, channelIsOpen: true) { announcements.append($0); return true }
        precondition(announcements == [true, false] && !connection.isAdded)
        connection.reset()
        var state = KeyboardGamepadState()
        precondition(!state.set(55, down: true))
        precondition(state.set(49, down: true))
        precondition(state.set(38, down: true))
        precondition(state.snapshot.pressedButtons == ["A"])
        _ = state.set(49, down: false)
        precondition(state.snapshot.pressedButtons == ["A"], "Alternate A key remains held")
        _ = state.set(38, down: false)
        precondition(state.snapshot.pressedButtons.isEmpty)
        _ = state.set(0, down: true)
        _ = state.set(13, down: true)
        precondition(state.snapshot.leftStick == ControllerStickState(x: -1, y: 1))
        _ = state.set(2, down: true)
        precondition(state.snapshot.leftStick.x == 0, "Opposing directions cancel")
        _ = state.set(124, down: true)
        _ = state.set(125, down: true)
        precondition(state.snapshot.dpad == ControllerStickState(x: 1, y: -1))
        _ = state.set(6, down: true)
        _ = state.set(8, down: true)
        precondition(state.snapshot.leftTrigger == 1 && state.snapshot.rightTrigger == 1)
        state = KeyboardGamepadState()
        precondition(state.snapshot.leftTrigger == 0 && state.snapshot.leftStick.x == 0 && state.snapshot.pressedButtons.isEmpty)
        print("PASS: pre-open controller announcement, failed-send retry, single merged gamepad, keyboard buttons, release, axes, triggers and reset")
    }
}
