import Foundation

@main private enum StreamProtocolTests {
    static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
    static func main() {
        let configuration = XboxCloudStreamController.webRTCNegotiationConfiguration
        precondition(configuration["chatStream"] as? [String: Int] == ["minVersion": 1, "maxVersion": 1],
                     "RTP microphone renegotiation requires chatStream capability in the initial offer")
        let micOffer = XboxCloudStreamController.microphoneOffer(sdp: "test-sdp", requestID: 4, correlationVector: "test.4")
        precondition(micOffer["requestId"] as? Int == 4 && micOffer["sdp"] as? String == "test-sdp")
        precondition(micOffer["cv"] as? String == "test.4")
        precondition(micOffer["configuration"] as? [String: Bool] == ["isMediaStreamsChatRenegotiation": true])
        let physical = ControllerInputSnapshot(id: "test-controller", name: "Test", profile: "Extended gamepad",
            pressedButtons: ["A", "Menu"], leftStick: ControllerStickState(x: 1, y: -1),
            rightStick: ControllerStickState(x: 0, y: 0), dpad: ControllerStickState(x: -1, y: 1),
            leftTrigger: 1, rightTrigger: 0, otherAxes: [])
        for (version, size) in [(1, 21), (2, 29), (6, 29), (7, 37), (8, 38), (10, 38)] {
            let bytes = Array(XboxCloudStreamController.gamepadReport(snapshot: physical, sequence: 0x11223344, version: version,
                                                                      timestampMilliseconds: 1234.5))
            // Independent fixtures produced by Xbox's published web-client
            // serializer, with a fixed clock, sequence and controller snapshot.
            let fixtures = [1: "024433221101001405ff7f018000000000ffff0000",
                2: "024433221101001405ff7f018000000000ffff000015100d0000000000",
                6: "024433221101001405ff7f018000000000ffff000015100d0000000000",
                7: "024433221100000000004a934001001405ff7f018000000000ffff000015100d0000000000",
                8: "02004433221100000000004a934001001405ff7f018000000000ffff000015100d0000000000",
                10: "02004433221100000000004a934001001405ff7f018000000000ffff000015100d0000000000"]
            precondition(bytes.map { String(format: "%02x", $0) }.joined() == fixtures[version])
            precondition(bytes.count == size)
            precondition(bytes[0] == 2)
            precondition(read32(bytes, version >= 8 ? 2 : 1) == 0x11223344)
            let header = version >= 8 ? 14 : (version == 7 ? 13 : 5)
            precondition(bytes[header] == 1 && bytes[header + 1] == 0)
            precondition(UInt16(bytes[header + 2]) | UInt16(bytes[header + 3]) << 8 == 1300)
            if version >= 2 {
                precondition(read32(bytes, bytes.count - 8) == 856085, "Active controls must have matching activity bits")
                precondition(read32(bytes, bytes.count - 4) == 0)
            }
        }
        var keys = KeyboardGamepadState()
        _ = keys.set(49, down: true)
        var bytes = Array(XboxCloudStreamController.gamepadReport(snapshot: keys.snapshot, sequence: 1, version: 10))
        precondition(read32(bytes, 30) == 0 && read32(bytes, 34) == 4096, "Keyboard controls use virtual activity flags")
        _ = keys.set(49, down: false)
        bytes = Array(XboxCloudStreamController.gamepadReport(snapshot: keys.snapshot, sequence: 2, version: 10))
        precondition(read32(bytes, 30) == 0 && read32(bytes, 34) == 0 && bytes[16] == 0)
        let metadata = Array(XboxCloudStreamController.clientMetadataReport(sequence: 1, version: 10))
        precondition(metadata.count == 15 && metadata[0] == 8 && metadata[14] == 0)
        print("PASS: input v1/v2/v6/v7/v8/v10 wire sizes, sequence, button mask, physical/virtual activity, release and client metadata")
    }
}
